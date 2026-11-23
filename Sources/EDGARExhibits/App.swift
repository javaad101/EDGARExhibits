import Foundation
import GoogleCloudStorage
import HTTPTypes
import Hummingbird

/// Coordinates batch scraping so live progress is observable and pagination persists per query across runs.
actor ScrapeCoordinator {
    private let store: any ObjectStore
    private let prefix: String
    private let workerServiceURL: URL?
    private let logger: ActivityLogger
    private let stateObjectPath = "state.json"

    private var cachedState: CorpusState?
    private var isRunning = false
    private var batchStart: ContinuousClock.Instant?
    private var completedInBatch = 0
    private var targetInBatch = 0
    private var exhibitsInBatch = 0

    init(
        store: any ObjectStore,
        prefix: String,
        logger: ActivityLogger,
        workerServiceURL: URL? = nil
    ) {
        self.store = store
        self.prefix = prefix
        self.logger = logger
        self.workerServiceURL = workerServiceURL
    }

    func status() async -> LiveStatusResponse {
        let state = await loadState()
        let elapsed: Double
        if let start = batchStart, isRunning {
            let duration = ContinuousClock.now - start
            elapsed = Self.seconds(from: duration)
        } else {
            elapsed = 0
        }
        let offsets = state.offsetsByQuery ?? [state.query: state.nextOffset]
        return LiveStatusResponse(
            bucket: store.bucket,
            query: state.query,
            isRunning: isRunning,
            completedInCurrentBatch: completedInBatch,
            targetInCurrentBatch: targetInBatch,
            exhibitsInCurrentBatch: exhibitsInBatch,
            elapsedSeconds: elapsed,
            totalFilingsInBucket: state.totalFilingsSaved,
            totalExhibitsInBucket: state.totalExhibitsSaved,
            nextOffset: state.offset(for: state.query),
            offsetsByQuery: offsets,
            recentRuns: state.recentRuns
        )
    }

    func runNextBatch(
        query: String,
        targetCount: Int,
        apiKey: String
    ) async throws -> ScrapeResponse {
        guard !isRunning else {
            throw CoordinatorError.batchAlreadyRunning
        }

        var state = await loadState()
        isRunning = true
        let clock = ContinuousClock()
        let startedAt = clock.now
        batchStart = startedAt
        completedInBatch = 0
        targetInBatch = targetCount
        exhibitsInBatch = 0
        defer {
            isRunning = false
            batchStart = nil
        }

        var seen = Set(state.savedAccessionNumbers)
        var cursor = state.offset(for: query)
        var batchFilings: [Filing] = []

        // Page forward until we collect `targetCount` unseen registration statements (or exhaust matches).
        while batchFilings.count < targetCount {
            let pageSize = 50
            let secQuery = SECAPIQuery(
                query: query,
                from: String(cursor),
                size: String(pageSize)
            )
            let fetched = try await queryFilings(secQuery, apiKey: apiKey)
            if fetched.isEmpty { break }

            var consumed = 0
            for filing in fetched {
                consumed += 1
                if seen.insert(filing.accessionNo).inserted {
                    batchFilings.append(filing)
                    if batchFilings.count == targetCount { break }
                }
            }
            cursor += consumed
            if batchFilings.count < targetCount && fetched.count < pageSize { break }
        }

        targetInBatch = batchFilings.count
        let headers = ["Authorization": apiKey]
        let store = self.store
        let prefix = self.prefix
        let workerURL = self.workerServiceURL
        let fanOutLimit = (workerURL != nil) ? max(batchFilings.count, 1) : 16

        let results = try await ConcurrentJobs.run(batchFilings, limit: fanOutLimit) { [weak self] filing -> FilingScrapeResult in
            let result: FilingScrapeResult
            if let workerURL,
               let remote = try? await dispatchFilingToWorker(
                   WorkerFilingRequest(filing: filing, prefix: prefix),
                   workerServiceURL: workerURL,
                   apiKey: apiKey
               ) {
                result = remote
            } else {
                guard let filingURL = URL(string: filing.linkToFilingDetails) else {
                    throw URLError(.badURL)
                }
                let scraper = ExhibitScraper(
                    filing: filing,
                    filingURL: filingURL,
                    prefix: prefix,
                    store: store,
                    headers: headers
                )
                result = try await scraper.scrape()
            }
            await self?.recordFilingCompleted(exhibitsSaved: result.savedExhibits.count)
            return result
        }

        let durationSeconds = Self.seconds(from: clock.now - startedAt)
        let filingsAdded = results.count
        let exhibitsAdded = results.reduce(0) { $0 + $1.savedExhibits.count }
        let exhibitsFailed = results.reduce(0) { $0 + $1.failedExhibits.count }

        state.setOffset(cursor, for: query)
        state.totalFilingsSaved += filingsAdded
        state.totalExhibitsSaved += exhibitsAdded
        state.savedAccessionNumbers.append(contentsOf: results.map(\.accessionNo))

        let runSummary = BatchRunSummary(
            id: UUID().uuidString,
            completedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            query: query,
            filingsAdded: filingsAdded,
            exhibitsAdded: exhibitsAdded,
            exhibitsFailed: exhibitsFailed,
            durationSeconds: durationSeconds
        )
        state.recentRuns.insert(runSummary, at: 0)
        if state.recentRuns.count > 25 {
            state.recentRuns = Array(state.recentRuns.prefix(25))
        }

        await saveState(state)
        await logger.record(
            operation: "scrape-batch",
            message: "Saved +\(filingsAdded) filings and +\(exhibitsAdded) exhibits (failed: \(exhibitsFailed)) for query '\(query)'.",
            durationSeconds: durationSeconds,
            metadata: [
                "query": query,
                "filingsAdded": "\(filingsAdded)",
                "exhibitsAdded": "\(exhibitsAdded)",
                "nextOffset": "\(cursor)",
                "totalFilings": "\(state.totalFilingsSaved)"
            ]
        )

        let offsets = state.offsetsByQuery ?? [state.query: state.nextOffset]
        return ScrapeResponse(
            bucket: store.bucket,
            query: query,
            filingsAdded: filingsAdded,
            exhibitsAdded: exhibitsAdded,
            exhibitsFailed: exhibitsFailed,
            durationSeconds: durationSeconds,
            totalFilingsInBucket: state.totalFilingsSaved,
            totalExhibitsInBucket: state.totalExhibitsSaved,
            nextOffset: state.nextOffset,
            offsetsByQuery: offsets,
            recentRuns: state.recentRuns
        )
    }

    func reconcileGroundTruth(accessionNumbers: [String], totalExhibits: Int) async {
        var state = await loadState()
        let uniqueAccessions = Array(Set(accessionNumbers)).sorted()
        state.savedAccessionNumbers = uniqueAccessions
        state.totalFilingsSaved = uniqueAccessions.count
        state.totalExhibitsSaved = totalExhibits
        let modernDefaultQuery = #"entities.sic:"6770" AND formType:"S-1" AND filedAt:[2020-01-01 TO 2026-12-31]"#
        if state.offsetsByQuery?[modernDefaultQuery] == nil {
            state.setOffset(0, for: modernDefaultQuery)
        }
        await saveState(state)
    }

    private func recordFilingCompleted(exhibitsSaved: Int) {
        completedInBatch += 1
        exhibitsInBatch += exhibitsSaved
    }

    private func loadState() async -> CorpusState {
        if let cachedState { return cachedState }
        if let (data, _) = try? await store.read(stateObjectPath),
           let decoded = try? JSONDecoder().decode(CorpusState.self, from: data) {
            cachedState = decoded
            return decoded
        }
        let fresh = CorpusState()
        cachedState = fresh
        return fresh
    }

    private func saveState(_ state: CorpusState) async {
        cachedState = state
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? await store.write(data, to: stateObjectPath, contentType: "application/json")
        }
    }

    private static func seconds(from duration: Duration) -> Double {
        let c = duration.components
        let raw = Double(c.seconds) + (Double(c.attoseconds) / 1e18)
        return (raw * 100).rounded() / 100
    }

    enum CoordinatorError: LocalizedError {
        case batchAlreadyRunning

        var errorDescription: String? {
            switch self {
            case .batchAlreadyRunning:
                return "A batch scrape is already in progress."
            }
        }
    }
}

@main
struct EDGARExhibitsApp {
    private static let workerKeyHeader = HTTPField.Name("X-Worker-Key")!

    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = Int(env["PORT"] ?? "8080") ?? 8080
        let bucket = env["GCS_BUCKET"] ?? ""
        let rawPrefix = (env["GCS_PREFIX"] ?? "filings")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = rawPrefix.isEmpty ? "filings" : rawPrefix
        let scrapeToken = env["SCRAPE_BEARER_TOKEN"]
        let workerServiceURL = env["WORKER_SERVICE_URL"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }

        let sharedStore: GCSObjectStore? = if !bucket.isEmpty,
            let client = try? StorageClient(),
            let controlClient = try? StorageControlClient() {
            GCSObjectStore(bucket: bucket, client: client, controlClient: controlClient)
        } else {
            nil
        }
        let logger = ActivityLogger(store: sharedStore)
        let coordinator = sharedStore.map {
            ScrapeCoordinator(store: $0, prefix: prefix, logger: logger, workerServiceURL: workerServiceURL)
        }
        let catalog = sharedStore.map {
            CorpusCatalog(store: $0, filingsPrefix: prefix, logger: logger)
        }
        let trendsAnalyzer: TrendsAnalyzer? = if let sharedStore, let catalog {
            TrendsAnalyzer(store: sharedStore, filingsPrefix: prefix, catalog: catalog, logger: logger)
        } else {
            nil
        }
        let webRoot = env["WEB_ROOT"] ?? (
            FileManager.default.fileExists(atPath: "/app/Public/index.html") ? "/app/Public" : "Public"
        )

        let router = Router()

        // MARK: - Public Interactive Web Observatory (`/` & `/assets/*`)

        router.get("/") { _, _ -> Response in
            Self.serveStaticFile(at: "\(webRoot)/index.html", contentType: "text/html; charset=utf-8")
        }

        router.get("/trends") { _, _ -> Response in
            Self.serveStaticFile(at: "\(webRoot)/index.html", contentType: "text/html; charset=utf-8")
        }

        router.get("/favicon.svg") { _, _ -> Response in
            Self.serveStaticFile(at: "\(webRoot)/favicon.svg", contentType: "image/svg+xml")
        }

        router.get("/assets/:assetFile") { _, context -> Response in
            guard let asset = Self.safeSegment(context.parameters.get("assetFile")) else {
                return jsonError(.badRequest, message: "Invalid asset path.")
            }
            return Self.serveStaticFile(
                at: "\(webRoot)/assets/\(asset)",
                contentType: Self.mimeType(for: asset),
                cacheImmutable: true
            )
        }

        // MARK: - Market Trends & Schema.org Dataset Endpoints

        router.get("/trends/dashboard") { _, _ -> Response in
            guard let trendsAnalyzer else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            return compactJSONResponse(.ok, await trendsAnalyzer.dashboard())
        }

        router.get("/trends/status") { _, _ -> Response in
            guard let trendsAnalyzer else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            return jsonResponse(.ok, await trendsAnalyzer.status())
        }

        router.get("/trends/deals/:dealKey") { _, context -> Response in
            guard let trendsAnalyzer else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            guard let rawKey = context.parameters.get("dealKey"),
                  let decodedKey = rawKey.removingPercentEncoding,
                  let safeKey = Self.safeSegment(decodedKey) else {
                return jsonError(.badRequest, message: "Invalid dealKey.")
            }
            guard let proof = await trendsAnalyzer.dealProof(for: safeKey) else {
                return jsonError(.notFound, message: "Deal \(safeKey) not found in trends index.")
            }
            return compactJSONResponse(.ok, proof)
        }

        router.post("/ops/extract-trends") { request, _ -> Response in
            if let expected = scrapeToken, !expected.isEmpty {
                let auth = request.headers[.authorization] ?? ""
                guard auth == "Bearer \(expected)" else {
                    return jsonError(.unauthorized, message: "Valid Bearer token required.")
                }
            }
            guard let trendsAnalyzer else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let started = await trendsAnalyzer.startExtractionIfNeeded()
            return jsonResponse(.accepted, started)
        }

        router.get("/schema/dataset.jsonld") { _, _ -> Response in
            guard let trendsAnalyzer else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let dash = await trendsAnalyzer.dashboard()
            let jsonLD = Self.buildSchemaOrgDataset(dash: dash)
            return Response(
                status: .ok,
                headers: [
                    .contentType: "application/ld+json; charset=utf-8",
                    HTTPField.Name("Access-Control-Allow-Origin")!: "*"
                ],
                body: .init(byteBuffer: .init(data: jsonLD))
            )
        }

        router.get("/health") { _, _ -> Response in
            jsonResponse(.ok, [
                "status": "ok",
                "service": "EDGARExhibits",
                "bucket": bucket
            ])
        }

        router.get("/status") { _, _ -> Response in
            guard let coordinator else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured (set GCS_BUCKET).")
            }
            let live = await coordinator.status()
            return jsonResponse(.ok, live)
        }

        router.get("/logs") { _, _ -> Response in
            let entries = await logger.recentEntries()
            return jsonResponse(.ok, entries)
        }

        // MARK: - Catalog & Official SEC `submissions` Endpoints

        router.get("/catalog/overview") { _, _ -> Response in
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            return jsonResponse(.ok, await catalog.overview())
        }

        router.post("/ops/sync-catalog") { request, _ -> Response in
            if let expected = scrapeToken, !expected.isEmpty {
                let auth = request.headers[.authorization] ?? ""
                guard auth == "Bearer \(expected)" else {
                    return jsonError(.unauthorized, message: "Valid Bearer token required.")
                }
            }
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let force = request.uri.queryParameters.get("forceSEC") == "true"
            let upgradeRules = request.uri.queryParameters.get("upgradeRules") == "true"
            let started = await catalog.startSyncIfNeeded(
                forceRefreshSEC: force,
                upgradeDefaultRules: upgradeRules
            ) { accessions, totalExhibits in
                await coordinator?.reconcileGroundTruth(
                    accessionNumbers: accessions,
                    totalExhibits: totalExhibits
                )
            }
            return jsonResponse(.accepted, started)
        }

        router.post("/ops/clean-2020-corpus") { request, _ -> Response in
            if let expected = scrapeToken, !expected.isEmpty {
                let auth = request.headers[.authorization] ?? ""
                guard auth == "Bearer \(expected)" else {
                    return jsonError(.unauthorized, message: "Valid Bearer token required.")
                }
            }
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let started = await catalog.startClean2020Corpus { accessions, totalExhibits in
                await coordinator?.reconcileGroundTruth(
                    accessionNumbers: accessions,
                    totalExhibits: totalExhibits
                )
            }
            return jsonResponse(.accepted, started)
        }

        router.get("/catalog/submissions") { request, _ -> Response in
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let q = request.uri.queryParameters.get("q")
            let form = request.uri.queryParameters.get("form")
            let onlySIC6770 = request.uri.queryParameters.get("sic6770") == "true"
            let offset = Int(request.uri.queryParameters.get("offset") ?? "0") ?? 0
            let limit = Int(request.uri.queryParameters.get("limit") ?? "150") ?? 150
            let result = await catalog.querySubmissions(
                search: q,
                form: form,
                onlySIC6770: onlySIC6770,
                offset: offset,
                limit: limit
            )
            return jsonResponse(.ok, result)
        }

        router.get("/catalog/deals") { request, _ -> Response in
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let q = request.uri.queryParameters.get("q")
            let offset = Int(request.uri.queryParameters.get("offset") ?? "0") ?? 0
            let limit = Int(request.uri.queryParameters.get("limit") ?? "100") ?? 100
            let result = await catalog.queryDeals(search: q, offset: offset, limit: limit)
            return jsonResponse(.ok, result)
        }

        router.get("/catalog/exhibits") { request, _ -> Response in
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let qp = request.uri.queryParameters
            let result = await catalog.queryExhibits(
                status: qp.get("status"),
                canonicalType: qp.get("type"),
                ruleID: qp.get("ruleId"),
                folderKey: qp.get("folderKey"),
                search: qp.get("q"),
                offset: Int(qp.get("offset") ?? "0") ?? 0,
                limit: Int(qp.get("limit") ?? "200") ?? 200
            )
            return jsonResponse(.ok, result)
        }

        router.get("/rules") { _, _ -> Response in
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            return jsonResponse(.ok, await catalog.currentRules())
        }

        router.put("/rules") { request, _ -> Response in
            if let expected = scrapeToken, !expected.isEmpty {
                let auth = request.headers[.authorization] ?? ""
                guard auth == "Bearer \(expected)" else {
                    return jsonError(.unauthorized, message: "Valid Bearer token required.")
                }
            }
            guard let catalog else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured.")
            }
            let buffer = try await request.body.collect(upTo: 512 * 1024)
            do {
                let incoming = try JSONDecoder().decode([ExhibitTypeRule].self, from: Data(buffer: buffer))
                let updatedOverview = try await catalog.updateRules(incoming)
                return jsonResponse(.ok, updatedOverview)
            } catch {
                return jsonError(.badRequest, message: "Invalid rule or regular expression: \(error.localizedDescription)")
            }
        }

        // MARK: - Package & Exhibit Retrieval

        router.get("/filings/:folderKey") { _, context -> Response in
            guard let store = sharedStore else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured (set GCS_BUCKET).")
            }
            guard let folderKey = Self.safeSegment(context.parameters.get("folderKey")) else {
                return jsonError(.badRequest, message: "Invalid filing folder key.")
            }
            do {
                let (data, _) = try await store.read("\(prefix)/\(folderKey)/exhibits/manifest.json")
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: .init(data: data))
                )
            } catch {
                return jsonError(.notFound, message: "Manifest not found for \(folderKey).")
            }
        }

        router.get("/filings/:folderKey/document") { _, context -> Response in
            guard let store = sharedStore else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured (set GCS_BUCKET).")
            }
            guard let folderKey = Self.safeSegment(context.parameters.get("folderKey")) else {
                return jsonError(.badRequest, message: "Invalid filing folder key.")
            }
            do {
                let (data, contentType) = try await store.read("\(prefix)/\(folderKey)/document.html")
                return Response(
                    status: .ok,
                    headers: [.contentType: contentType],
                    body: .init(byteBuffer: .init(data: data))
                )
            } catch {
                return jsonError(.notFound, message: "Primary document not found for \(folderKey).")
            }
        }

        router.get("/filings/:folderKey/exhibits/:filename") { _, context -> Response in
            guard let store = sharedStore else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured (set GCS_BUCKET).")
            }
            guard let folderKey = Self.safeSegment(context.parameters.get("folderKey")),
                  let filename = Self.safeSegment(context.parameters.get("filename")) else {
                return jsonError(.badRequest, message: "Invalid exhibit path parameter.")
            }
            do {
                let (data, contentType) = try await store.read("\(prefix)/\(folderKey)/exhibits/\(filename)")
                return Response(
                    status: .ok,
                    headers: [.contentType: contentType],
                    body: .init(byteBuffer: .init(data: data))
                )
            } catch {
                return jsonError(.notFound, message: "Exhibit \(filename) not found.")
            }
        }

        // MARK: - Ingestion Endpoints

        router.post("/scrape-filing") { request, _ -> Response in
            guard let apiKey = env["SEC_API_KEY"], !apiKey.isEmpty else {
                return jsonError(.internalServerError, message: "Missing SEC_API_KEY environment variable.")
            }
            guard request.headers[Self.workerKeyHeader] == apiKey else {
                return jsonError(.unauthorized, message: "Unauthorized worker request.")
            }
            guard let store = sharedStore else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured (set GCS_BUCKET).")
            }

            let buffer = try await request.body.collect(upTo: 256 * 1024)
            let job: WorkerFilingRequest
            do {
                job = try JSONDecoder().decode(WorkerFilingRequest.self, from: Data(buffer: buffer))
            } catch {
                return jsonError(.badRequest, message: "Invalid WorkerFilingRequest JSON.")
            }
            guard let filingURL = URL(string: job.filing.linkToFilingDetails) else {
                return jsonError(.badRequest, message: "Invalid filing URL.")
            }

            do {
                let scraper = ExhibitScraper(
                    filing: job.filing,
                    filingURL: filingURL,
                    prefix: job.prefix,
                    store: store,
                    headers: ["Authorization": apiKey]
                )
                let result = try await scraper.scrape()
                return jsonResponse(.ok, result)
            } catch {
                return jsonError(.badGateway, message: "Worker scrape failed: \(error.localizedDescription)")
            }
        }

        router.post("/scrape") { request, _ -> Response in
            if let expected = scrapeToken, !expected.isEmpty {
                let auth = request.headers[.authorization] ?? ""
                guard auth == "Bearer \(expected)" else {
                    return jsonError(.unauthorized, message: "Valid Bearer token required for /scrape.")
                }
            }
            guard let apiKey = env["SEC_API_KEY"], !apiKey.isEmpty else {
                return jsonError(.internalServerError, message: "Missing SEC_API_KEY environment variable.")
            }
            guard let coordinator else {
                return jsonError(.serviceUnavailable, message: "Cloud Storage is not configured (set GCS_BUCKET).")
            }

            let buffer = try await request.body.collect(upTo: 64 * 1024)
            let incoming: ScrapeRequest?
            if buffer.readableBytes > 0 {
                do {
                    incoming = try JSONDecoder().decode(ScrapeRequest.self, from: Data(buffer: buffer))
                } catch {
                    return jsonError(.badRequest, message: "Invalid JSON request body: \(error.localizedDescription)")
                }
            } else {
                incoming = nil
            }

            let targetCount = min(max(incoming?.count ?? 50, 1), 50)
            let trimmedQuery = incoming?.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let query = trimmedQuery.isEmpty
                ? #"entities.sic:"6770" AND formType:"S-1" AND filedAt:[2020-01-01 TO 2026-12-31]"#
                : trimmedQuery

            do {
                let summary = try await coordinator.runNextBatch(
                    query: query,
                    targetCount: targetCount,
                    apiKey: apiKey
                )
                return jsonResponse(.ok, summary)
            } catch ScrapeCoordinator.CoordinatorError.batchAlreadyRunning {
                return jsonError(.conflict, message: "A batch of filings is already downloading.")
            } catch {
                await logger.record(
                    severity: "ERROR",
                    operation: "scrape-batch",
                    message: "Scrape failed for query '\(query)': \(error.localizedDescription)"
                )
                return jsonError(.badGateway, message: "Scrape failed: \(error.localizedDescription)")
            }
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: port))
        )
        try await app.runService()
    }

    private static let corsOriginHeader = HTTPField.Name("Access-Control-Allow-Origin")!

    private static func safeSegment(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
              !raw.contains("/"), !raw.contains(".."), !raw.contains("\\") else {
            return nil
        }
        return raw
    }

    private static func mimeType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".js") || lower.hasSuffix(".mjs") { return "application/javascript; charset=utf-8" }
        if lower.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if lower.hasSuffix(".svg") { return "image/svg+xml" }
        if lower.hasSuffix(".json") { return "application/json; charset=utf-8" }
        if lower.hasSuffix(".woff2") { return "font/woff2" }
        if lower.hasSuffix(".png") { return "image/png" }
        return "application/octet-stream"
    }

    private static func serveStaticFile(
        at path: String,
        contentType: String,
        cacheImmutable: Bool = false
    ) -> Response {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return jsonError(.notFound, message: "Static asset not found: \(path)")
        }
        var headers: HTTPFields = [.contentType: contentType]
        if cacheImmutable {
            headers[.cacheControl] = "public, max-age=31536000, immutable"
        } else {
            headers[.cacheControl] = "no-cache"
        }
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: .init(data: data))
        )
    }

    private static func jsonResponse<T: Encodable>(_ status: HTTPResponse.Status, _ value: T) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [
                .contentType: "application/json",
                corsOriginHeader: "*"
            ],
            body: .init(byteBuffer: .init(data: payload))
        )
    }

    private static func compactJSONResponse<T: Encodable>(_ status: HTTPResponse.Status, _ value: T) -> Response {
        let encoder = JSONEncoder()
        let payload = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [
                .contentType: "application/json",
                corsOriginHeader: "*"
            ],
            body: .init(byteBuffer: .init(data: payload))
        )
    }

    private static func jsonError(_ status: HTTPResponse.Status, message: String) -> Response {
        jsonResponse(status, ["error": message])
    }

    private static func buildSchemaOrgDataset(dash: TrendsDashboardResponse) -> Data {
        let doc: [String: Any] = [
            "@context": "https://schema.org",
            "@type": "Dataset",
            "name": "EDGAR Form S-1 & S-1/A Cover-Page Deal Terms & Typed Exhibit Corpus (2020–2026)",
            "description": "Empirically extracted cover-page deal economics, bookrunning underwriters, issuer and underwriter legal counsel, named partners, unit/warrant coverage, trust overfunding, and deterministically classified SEC exhibits across \(dash.totalDeals) registration deal chains (\(dash.totalPackagesInCorpus) Form S-1/S-1A filings and \(dash.totalExhibitsInCorpus) exhibits, 2020–2026).",
            "temporalCoverage": "2020-01-01/2026-12-31",
            "license": "https://www.sec.gov/privacy#dissemination",
            "isAccessibleForFree": true,
            "keywords": [
                "SEC Form S-1",
                "SPAC IPO Market Trends",
                "SIC 6770 Blank Checks",
                "Capital Markets League Tables",
                "Underwriting Agreements",
                "Warrant Coverage",
                "Trust Overfunding",
                "Legal Counsel",
                "EDGAR Exhibits"
            ],
            "creator": [
                "@type": "Organization",
                "name": "Advocates Close",
                "url": "https://spac.advocatesclose.nyc"
            ],
            "variableMeasured": [
                "IPO Gross Proceeds (USD)",
                "Unit Count & Offering Price",
                "Bookrunning Underwriters",
                "Issuer & Underwriter Legal Counsel",
                "Named Deal Partners",
                "Unit Warrant / Share-Right Coverage",
                "Trust Account Deposit per Unit (USD)",
                "Business Combination Completion Window (Months)",
                "Listing Exchange & Ticker"
            ],
            "distribution": [
                [
                    "@type": "DataDownload",
                    "encodingFormat": "application/json",
                    "contentUrl": "/trends/dashboard"
                ]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}
