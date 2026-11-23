import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owns the exhibit-scraping lifecycle for a single SEC filing.
actor ExhibitScraper {
    private let filing: Filing
    private let filingURL: URL
    private let baseObjectPrefix: String
    private let store: any ObjectStore
    private let headers: [String: String]
    private let session: URLSession

    init(
        filing: Filing,
        filingURL: URL,
        prefix: String,
        store: any ObjectStore,
        headers: [String: String],
        session: URLSession = edgarURLSession
    ) {
        self.filing = filing
        self.filingURL = filingURL
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = trimmed.isEmpty ? "" : "\(trimmed)/"
        // Keyed by `<accessionNo>_<cik>` so 50 filings always produce 50 distinct folders in GCS.
        self.baseObjectPrefix = "\(root)\(filing.folderKey)"
        self.store = store
        self.headers = headers
        self.session = session
    }

    /// Extracts canonical, deduplicated EDGAR exhibit links from raw UTF-8/ASCII filing bytes with zero DOM allocation.
    func attachments(in htmlData: Data) -> [Attachment] {
        let scanned = HTMLLinkScanner.scan(htmlData)
        let trimmedBase = scanned.baseHref?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = trimmedBase.flatMap { $0.isEmpty ? nil : URL(string: $0, relativeTo: filingURL)?.absoluteURL }
            ?? filingURL

        let canonicalFilingPath = canonicalURL(filingURL)?.path ?? filingURL.path
        var seen: Set<String> = []
        var attachments: [Attachment] = []
        attachments.reserveCapacity(scanned.links.count)

        for link in scanned.links {
            let href = link.href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty, !href.hasPrefix("#"),
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let url = canonicalURL(resolved),
                  url.path != canonicalFilingPath,
                  !Self.isNonExhibitWrapperOrGraphic(filename: url.lastPathComponent, accessionNo: filing.accessionNo),
                  seen.insert(url.absoluteString).inserted else { continue }

            attachments.append(Attachment(
                docName: link.text.isEmpty ? url.lastPathComponent : link.text,
                docURL: url.absoluteString
            ))
        }
        return attachments
    }

    func attachments(in html: String) -> [Attachment] {
        attachments(in: Data(html.utf8))
    }

    /// Converts structured `documentFormatFiles` (from `sec-api.io` or `{accessionNo}-index.htm`) into canonical exhibit attachments.
    func attachments(from formatFiles: [Filing.DocumentFormatFile]) -> [Attachment] {
        let canonicalFilingPath = canonicalURL(filingURL)?.path ?? filingURL.path
        let primaryForms: Set<String> = ["S-1", "S-1/A", "F-1", "F-1/A", "S-4", "S-4/A", "F-4", "F-4/A", "POS AM", "424B4"]
        let skippedTypes: Set<String> = ["GRAPHIC", "XML", "JSON", "ZIP", "EXCEL", "EX-101.INS", "EX-101.SCH", "EX-101.CAL", "EX-101.DEF", "EX-101.LAB", "EX-101.PRE"]

        var seen: Set<String> = []
        var out: [Attachment] = []
        for entry in formatFiles {
            let rawType = (entry.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let upperType = rawType.uppercased()
            if primaryForms.contains(upperType) || skippedTypes.contains(upperType) || upperType.hasPrefix("EX-101") {
                continue
            }
            guard let rawURL = entry.documentUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawURL.isEmpty,
                  let parsed = URL(string: rawURL),
                  let url = canonicalURL(parsed),
                  url.path != canonicalFilingPath,
                  !Self.isNonExhibitWrapperOrGraphic(filename: url.lastPathComponent, accessionNo: filing.accessionNo),
                  seen.insert(url.absoluteString).inserted else {
                continue
            }

            let desc = (entry.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let docName: String
            if !desc.isEmpty && !rawType.isEmpty {
                if desc.uppercased().hasPrefix(upperType) {
                    docName = desc
                } else {
                    docName = "\(rawType): \(desc)"
                }
            } else if !desc.isEmpty {
                docName = desc
            } else if !rawType.isEmpty {
                docName = "\(rawType) (\(url.lastPathComponent))"
            } else {
                docName = url.lastPathComponent
            }

            out.append(Attachment(docName: docName, docURL: url.absoluteString))
        }
        return out
    }

    /// Downloads the primary filing and all linked exhibits, persisting them and a manifest to Cloud Storage.
    func scrape() async throws -> FilingScrapeResult {
        try Task.checkCancellation()
        let filingData = try await downloadDocument(at: filing.linkToFilingDetails)
        let filingObjectPath = "\(baseObjectPrefix)/document.html"

        // Overlap writing the primary registration statement to GCS with scanning & downloading its exhibits.
        async let persistPrimary: Void = store.write(
            filingData,
            to: filingObjectPath,
            contentType: "text/html; charset=utf-8"
        )
        async let exhibitResult = scrape(htmlData: filingData, filingObjectPath: filingObjectPath)
        let (_, result) = try await (persistPrimary, exhibitResult)
        return result
    }

    /// Scrapes exhibits by combining `filing.documentFormatFiles` / `{accessionNo}-index.htm` with S-1 prose hyperlinks.
    func scrape(htmlData: Data, filingObjectPath: String) async throws -> FilingScrapeResult {
        try Task.checkCancellation()
        let proseAttachments = attachments(in: htmlData)

        var structuredAttachments: [Attachment] = []
        if let files = filing.documentFormatFiles, !files.isEmpty {
            structuredAttachments = attachments(from: files)
        } else if proseAttachments.isEmpty, !headers.isEmpty,
                  let indexURL = Self.secIndexURL(cik: filing.cik, accessionNo: filing.accessionNo, override: filing.linkToHtml),
                  let indexData = try? await downloadDocument(at: indexURL) {
            let parsed = EDGARIndexParser.parseDocumentFormatFiles(indexData)
            structuredAttachments = attachments(from: parsed)
        }

        let discovered = Self.mergeAttachments(primary: structuredAttachments, prose: proseAttachments)
        let indexed = Array(discovered.enumerated()).map { (index: $0.offset + 1, attachment: $0.element) }

        enum Outcome: Sendable {
            case saved(SavedExhibit)
            case failed(FailedExhibit)
        }

        let prefix = self.baseObjectPrefix
        let store = self.store
        let headers = self.headers
        let session = self.session

        let outcomes = try await ConcurrentJobs.run(indexed, limit: 16) { item -> Outcome in
            do {
                let url = try mirrorURL(for: item.attachment.docURL)
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.allHTTPHeaderFields = headers
                request.timeoutInterval = 60

                let data = try await getData(request: request, session: session)
                try Task.checkCancellation()
                guard let docURL = URL(string: item.attachment.docURL) else {
                    throw URLError(.badURL)
                }

                let safeName = docURL.lastPathComponent
                    .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted)
                    .joined(separator: "_")
                let filename = "\(item.index)-\(safeName.isEmpty ? "exhibit" : safeName)"
                let objectPath = "\(prefix)/exhibits/\(filename)"

                try await store.write(
                    data,
                    to: objectPath,
                    contentType: Self.contentType(for: filename)
                )
                return .saved(SavedExhibit(
                    attachment: item.attachment,
                    filename: filename,
                    objectPath: objectPath
                ))
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                return .failed(FailedExhibit(
                    attachment: item.attachment,
                    message: error.localizedDescription
                ))
            }
        }

        var records: [SavedExhibit] = []
        var failures: [FailedExhibit] = []
        for outcome in outcomes {
            switch outcome {
            case .saved(let saved): records.append(saved)
            case .failed(let failed): failures.append(failed)
            }
        }

        try Task.checkCancellation()
        await writeReport(records, named: "manifest.json")
        if !failures.isEmpty {
            await writeReport(failures, named: "failures.json")
        }

        return FilingScrapeResult(
            folderKey: filing.folderKey,
            cik: filing.cik,
            accessionNo: filing.accessionNo,
            companyName: filing.companyName,
            ticker: filing.ticker,
            formType: filing.formType,
            filedAt: filing.filedAt,
            filingObjectPath: filingObjectPath,
            savedExhibits: records,
            failedExhibits: failures
        )
    }

    /// Backfills missing exhibits for an existing GCS package directly from official `www.sec.gov` `{accessionNo}-index.htm`
    /// (zero `sec-api.io` calls, polite `< 10 req/s` SEC pacing).
    static func backfillExhibitsDirectFromSEC(
        folderKey: String,
        accessionNo: String,
        cik: String,
        primaryDocument: String,
        prefix: String,
        store: any ObjectStore,
        secUserAgent: String
    ) async -> [SavedExhibit] {
        let digitsCIK = cik.filter(\.isNumber).drop(while: { $0 == "0" })
        let cleanCIK = digitsCIK.isEmpty ? cik.filter(\.isNumber) : String(digitsCIK)
        let accNoHyphens = accessionNo.replacingOccurrences(of: "-", with: "")
        guard !cleanCIK.isEmpty, !accNoHyphens.isEmpty,
              let indexURL = URL(string: "https://www.sec.gov/Archives/edgar/data/\(cleanCIK)/\(accNoHyphens)/\(accessionNo)-index.htm") else {
            return []
        }

        var indexReq = URLRequest(url: indexURL)
        indexReq.httpMethod = "GET"
        indexReq.setValue(secUserAgent, forHTTPHeaderField: "User-Agent")
        indexReq.timeoutInterval = 30
        try? await Task.sleep(for: .milliseconds(120))
        guard let indexData = try? await getData(request: indexReq) else {
            return []
        }

        let formatFiles = EDGARIndexParser.parseDocumentFormatFiles(indexData)
        guard !formatFiles.isEmpty else { return [] }

        let fallbackPrimary = primaryDocument.isEmpty ? "document.htm" : primaryDocument
        let primaryURLStr = "https://www.sec.gov/Archives/edgar/data/\(cleanCIK)/\(accNoHyphens)/\(fallbackPrimary)"
        guard let primaryURL = URL(string: primaryURLStr) else { return [] }

        let filing = Filing(
            accessionNo: accessionNo,
            cik: cleanCIK,
            linkToFilingDetails: primaryURLStr,
            documentFormatFiles: formatFiles
        )
        let helper = ExhibitScraper(
            filing: filing,
            filingURL: primaryURL,
            prefix: prefix,
            store: store,
            headers: [:]
        )
        let discovered = await helper.attachments(from: formatFiles)
        guard !discovered.isEmpty else { return [] }

        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePrefix = trimmed.isEmpty ? folderKey : "\(trimmed)/\(folderKey)"
        let indexed = Array(discovered.enumerated()).map { (index: $0.offset + 1, attachment: $0.element) }

        let saved = (try? await ConcurrentJobs.run(indexed, limit: 4) { item -> SavedExhibit? in
            guard let url = URL(string: item.attachment.docURL) else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(secUserAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 60
            try? await Task.sleep(for: .milliseconds(140))
            guard let data = try? await getData(request: req) else { return nil }

            let safeName = url.lastPathComponent
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted)
                .joined(separator: "_")
            let filename = "\(item.index)-\(safeName.isEmpty ? "exhibit" : safeName)"
            let objectPath = "\(basePrefix)/exhibits/\(filename)"
            try? await store.write(data, to: objectPath, contentType: Self.contentType(for: filename))
            return SavedExhibit(attachment: item.attachment, filename: filename, objectPath: objectPath)
        }) ?? []

        let nonNil = saved.compactMap { $0 }
        if !nonNil.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let mData = try? encoder.encode(nonNil) {
                try? await store.write(mData, to: "\(basePrefix)/exhibits/manifest.json", contentType: "application/json")
            }
        }
        return nonNil
    }

    private static func mergeAttachments(primary: [Attachment], prose: [Attachment]) -> [Attachment] {
        guard !primary.isEmpty else { return prose }
        guard !prose.isEmpty else { return primary }

        var proseByURL: [String: String] = [:]
        for p in prose {
            proseByURL[p.docURL] = p.docName
        }

        var seen: Set<String> = []
        var merged: [Attachment] = []
        for item in primary {
            seen.insert(item.docURL)
            if let proseDesc = proseByURL[item.docURL],
               Self.isRicherDescription(proseDesc, than: item.docName) {
                merged.append(Attachment(docName: proseDesc, docURL: item.docURL))
            } else {
                merged.append(item)
            }
        }
        for p in prose where seen.insert(p.docURL).inserted {
            merged.append(p)
        }
        return merged
    }

    private static func isRicherDescription(_ candidate: String, than baseline: String) -> Bool {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = baseline.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bare exhibit numbers like "10.2" or "4.1*" are shorter than ~8 chars and have no letters.
        let cLetters = c.filter(\.isLetter).count
        let bLetters = b.filter(\.isLetter).count
        return cLetters > bLetters + 6
    }

    private static func secIndexURL(cik: String, accessionNo: String, override: String?) -> String? {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        let digitsCIK = cik.filter(\.isNumber).drop(while: { $0 == "0" })
        let cleanCIK = digitsCIK.isEmpty ? cik.filter(\.isNumber) : String(digitsCIK)
        let accNoHyphens = accessionNo.replacingOccurrences(of: "-", with: "")
        guard !cleanCIK.isEmpty, !accNoHyphens.isEmpty else { return nil }
        return "https://www.sec.gov/Archives/edgar/data/\(cleanCIK)/\(accNoHyphens)/\(accessionNo)-index.htm"
    }

    static func isNonExhibitWrapperOrGraphic(filename: String, accessionNo: String) -> Bool {
        let lower = filename.lowercased()
        if lower.hasSuffix("-index.htm") || lower.hasSuffix("-index.html") || lower.hasSuffix("-index-headers.html") {
            return true
        }
        if !accessionNo.isEmpty && lower == "\(accessionNo.lowercased()).txt" {
            return true
        }
        let ext = URL(fileURLWithPath: lower).pathExtension
        let ignoredExtensions: Set<String> = ["jpg", "jpeg", "gif", "png", "svg", "ico", "zip", "xsd", "xml", "json", "css", "js", "xlsx"]
        return ignoredExtensions.contains(ext)
    }

    private func downloadDocument(at documentURL: String) async throws -> Data {
        let url = try mirrorURL(for: documentURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = headers
        request.timeoutInterval = 60
        return try await getData(request: request, session: session)
    }

    private func writeReport<T: Encodable>(_ report: T, named filename: String) async {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try await store.write(
                data,
                to: "\(baseObjectPrefix)/exhibits/\(filename)",
                contentType: "application/json"
            )
        } catch {
            print("Warning: Could not write \(filename) for \(filing.accessionNo): \(error.localizedDescription)")
        }
    }

    /// Normalizes EDGAR URLs and unwraps Inline XBRL (`/ix?doc=...`) viewer links to raw archive files.
    private func canonicalURL(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              ["www.sec.gov", "sec.gov", "edgar-mirror.sec-api.io"].contains(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var path = normalizedPath(components.path)
        if ["/ix", "/ixviewer/doc/action", "/ixviewer/ix.html"].contains(path) {
            guard let document = components.queryItems?.first(where: { $0.name == "doc" })?.value,
                  document.hasPrefix("/Archives/edgar/data/") else { return nil }
            path = normalizedPath(document)
        }
        if host == "edgar-mirror.sec-api.io", !path.hasPrefix("/Archives/edgar/data/") {
            path = "/Archives/edgar/data" + path
        }
        guard path.hasPrefix("/Archives/edgar/data/") else { return nil }

        let parts = path.dropFirst("/Archives/edgar/data/".count).split(separator: "/")
        guard parts.count == 3,
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              parts[1].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }),
              parts[2].contains(".") else {
            return nil
        }

        components.path = path
        components.scheme = "https"
        components.host = "www.sec.gov"
        components.port = nil
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func normalizedPath(_ path: String) -> String {
        var segments: [Substring] = []
        for segment in path.split(separator: "/") {
            if segment == ".." {
                if !segments.isEmpty { segments.removeLast() }
            } else if segment != "." {
                segments.append(segment)
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    private static func contentType(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "htm", "html": return "text/html; charset=utf-8"
        case "xml", "xsd": return "application/xml"
        case "json": return "application/json"
        case "txt": return "text/plain; charset=utf-8"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        default: return "application/octet-stream"
        }
    }
}
