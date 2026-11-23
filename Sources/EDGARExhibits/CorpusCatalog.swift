import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds and queries the bucket-wide submission & exhibit catalog, joining GCS packages against
/// official SEC `CIK##########.json` (`submissions.zip` / `data.sec.gov/submissions`) and applying
/// deterministic "one-triggers-all" regular expression rules across every exhibit.
actor CorpusCatalog {
    private let store: any ObjectStore
    private let filingsPrefix: String
    private let logger: ActivityLogger
    private let secUserAgent: String

    private let overviewPath = "corpus/catalog_overview.json"
    private let submissionsPath = "corpus/submissions.json"
    private let submissionsJSONLPath = "corpus/submissions.jsonl"
    private let exhibitsPath = "corpus/exhibits.json"
    private let exhibitsJSONLPath = "corpus/exhibits.jsonl"
    private let rulesPath = "corpus/type_rules.json"
    private let secCachePrefix = "sec-submissions"

    private var didLoadFromStore = false
    private var syncedAtISO8601: String?
    private var isSyncing = false
    private var syncPhase = "Idle"
    private var syncCompleted = 0
    private var syncTotal = 0

    private var submissions: [SubmissionRecord] = []
    private var exhibits: [CatalogExhibit] = []
    private var rules: [ExhibitTypeRule] = CorpusCatalog.defaultRules

    init(
        store: any ObjectStore,
        filingsPrefix: String,
        logger: ActivityLogger,
        secUserAgent: String = "AdvocatesClose CorpusIndexer ops@advocatesclose.nyc"
    ) {
        self.store = store
        self.filingsPrefix = filingsPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.logger = logger
        self.secUserAgent = secUserAgent
    }

    // MARK: - Default SPAC Registration Statement Exhibit Rulebook

    static let defaultRules: [ExhibitTypeRule] = [
        ExhibitTypeRule(
            id: "ex3-charter-amended",
            priority: 10,
            canonicalName: "Amended and Restated Memorandum and Articles of Association",
            filenamePattern: #"(?i)ex[-_.x]?0?3([-_.x]?0?[1234a-d])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(amended\s+and\s+restated|restated\s+(certificate|memorandum|articles|charter)|second\s+amended)"#,
            notes: "Post-IPO SPAC charter / M&A (commonly Ex. 3.2 or Ex. 3.1 depending on filer)."
        ),
        ExhibitTypeRule(
            id: "ex3-charter-initial",
            priority: 20,
            canonicalName: "Initial Charter / Memorandum and Articles of Association",
            filenamePattern: #"(?i)ex[-_.x]?0?3([-_.x]?0?[1234a-d])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Incorporation Memorandum, Articles, Certificate of Incorporation, or Bylaws."
        ),
        ExhibitTypeRule(
            id: "ex1-underwriting",
            priority: 30,
            canonicalName: "Form of Underwriting Agreement",
            filenamePattern: #"(?i)ex[-_.x]?(1([-_.x]0?1|1)?|01([-_.x]?01)?)(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Underwriting agreement with lead bookrunner(s)."
        ),
        ExhibitTypeRule(
            id: "ex4-unit-cert",
            priority: 40,
            canonicalName: "Specimen Unit Certificate",
            filenamePattern: #"(?i)ex[-_.x]?0?4([-_.x]?0?[1-9a-z])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)units?\s+certificate"#,
            notes: "Specimen public unit certificate."
        ),
        ExhibitTypeRule(
            id: "ex4-share-cert",
            priority: 50,
            canonicalName: "Specimen Class A Share / Common Stock Certificate",
            filenamePattern: #"(?i)ex[-_.x]?0?4([-_.x]?0?[1-9a-z])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(shares?|stock)\s+certificate"#,
            notes: "Specimen Class A ordinary share or common stock certificate."
        ),
        ExhibitTypeRule(
            id: "ex4-warrant-agreement",
            priority: 60,
            canonicalName: "Warrant Agreement",
            filenamePattern: #"(?i)ex[-_.x]?0?4([-_.x]?0?[1-9a-z])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(warrants?\s+agreement|rights?\s+agreement|indenture)"#,
            notes: "Public & private placement warrant (or rights) agreement."
        ),
        ExhibitTypeRule(
            id: "ex4-warrant-cert",
            priority: 65,
            canonicalName: "Specimen Warrant / Right Certificate",
            filenamePattern: #"(?i)ex[-_.x]?0?4([-_.x]?0?[1-9a-z])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(warrants?|rights?)\s+certificate"#,
            notes: "Standalone specimen warrant or right certificate."
        ),
        ExhibitTypeRule(
            id: "ex5-legal-opinion",
            priority: 70,
            canonicalName: "Opinion of Counsel",
            filenamePattern: #"(?i)ex[-_.x]?0?5([-_.x]?0?[1234a-c])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Securities validity opinion (U.S. and offshore/Cayman counsel)."
        ),
        ExhibitTypeRule(
            id: "ex107-fee-table",
            priority: 75,
            canonicalName: "Filing Fee Table (Ex. 107)",
            filenamePattern: #"(?i)(ex[-_.x]?(107|fee)|fee[-_.]?table)[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Form S-1 Calculation of Filing Fee Tables (Item 601(b)(107))."
        ),
        ExhibitTypeRule(
            id: "ex10-trust-agreement",
            priority: 80,
            canonicalName: "Investment Management Trust Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)trust\s+agreement"#,
            notes: "IPO proceeds trust account agreement (e.g. Continental / Odyssey)."
        ),
        ExhibitTypeRule(
            id: "ex10-letter-agreement",
            priority: 90,
            canonicalName: "Sponsor Insider Letter Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)letter\s+agreement"#,
            notes: "Lock-up, waiver of redemption rights, and voting agreement among Sponsor & insiders."
        ),
        ExhibitTypeRule(
            id: "ex10-reg-rights",
            priority: 100,
            canonicalName: "Registration Rights Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(registration\s+(and\s+(shareholder|stockholder)s?\s+)?rights|investor\s+rights\s+agreement)"#,
            notes: "Founder and private placement registration (and shareholder) rights agreement."
        ),
        ExhibitTypeRule(
            id: "ex10-private-placement",
            priority: 110,
            canonicalName: "Private Placement Purchase Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(private\s+placement|warrants?\s+purchase|units?\s+purchase|placement\s+(unit|warrant)|rights?\s+purchase)"#,
            notes: "Sponsor / underwriter private placement warrant, unit, or rights purchase agreement."
        ),
        ExhibitTypeRule(
            id: "ex10-indemnity",
            priority: 120,
            canonicalName: "Form of Indemnity Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)indemnit(y|fication)"#,
            notes: "Director and officer indemnification agreement."
        ),
        ExhibitTypeRule(
            id: "ex10-promissory-note",
            priority: 130,
            canonicalName: "Sponsor Promissory Note",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)promissory\s+note"#,
            notes: "Pre-IPO working capital promissory note to Sponsor."
        ),
        ExhibitTypeRule(
            id: "ex10-subscription",
            priority: 140,
            canonicalName: "Founder Securities Subscription Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(subscription\s+agreement|securities\s+purchase\s+agreement|founder\s+shares)"#,
            notes: "Founder shares subscription / securities purchase agreement."
        ),
        ExhibitTypeRule(
            id: "ex10-forward-purchase",
            priority: 145,
            canonicalName: "Form of Forward Purchase Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)forward\s+purchase"#,
            notes: "Institutional or anchor forward purchase agreement for PIPE / de-SPAC commitment."
        ),
        ExhibitTypeRule(
            id: "ex10-admin-services",
            priority: 150,
            canonicalName: "Administrative Services Agreement",
            filenamePattern: #"(?i)ex[-_.x]?10[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(administrative\s+(services|support)|office\s+space)"#,
            notes: "Monthly administrative support agreement."
        ),
        ExhibitTypeRule(
            id: "ex14-ethics",
            priority: 160,
            canonicalName: "Code of Ethics",
            filenamePattern: #"(?i)ex[-_.x]?14[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Code of Business Conduct and Ethics."
        ),
        ExhibitTypeRule(
            id: "ex21-subsidiaries",
            priority: 165,
            canonicalName: "List of Subsidiaries (Ex. 21)",
            filenamePattern: #"(?i)ex[-_.x]?21[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Subsidiaries of the registrant."
        ),
        ExhibitTypeRule(
            id: "ex23-consent",
            priority: 168,
            canonicalName: "Auditor / Counsel Consent (Ex. 23)",
            filenamePattern: #"(?i)(ex[-_.x]?23|[_-]23[-_.x][1234])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Consent of independent registered public accounting firm or counsel."
        ),
        ExhibitTypeRule(
            id: "ex99-charter-or-consent",
            priority: 170,
            canonicalName: "Committee Charter / Director Nominee Consent (Ex. 99)",
            filenamePattern: #"(?i)ex[-_.x]?99[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Audit/Compensation/Nominating charters and Rule 438 director consents."
        ),
        ExhibitTypeRule(
            id: "ex23-consent-by-title",
            priority: 175,
            canonicalName: "Auditor / Counsel Consent (Ex. 23)",
            filenamePattern: #"(?i)\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)^(\s*ex[-_. ]?23[^0-9]|consent\s+of\s+(?!.*(director|nominee)))"#,
            notes: "Auditor or counsel consent where printer omitted 'ex23' from filename."
        ),
        ExhibitTypeRule(
            id: "ex24-poa",
            priority: 185,
            canonicalName: "Power of Attorney (Ex. 24)",
            filenamePattern: #"(?i)\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)(power\s+of\s+attorney|\bex[-_. ]?24\b)"#,
            notes: "Power of Attorney (standalone or signature-page cross-reference)."
        ),
        ExhibitTypeRule(
            id: "ex107-fee-by-title",
            priority: 190,
            canonicalName: "Filing Fee Table (Ex. 107)",
            filenamePattern: #"(?i)\.(htm|html|txt)$"#,
            docNamePattern: #"(?i)filing\s+fee\s+table"#,
            notes: "Filing fee table matched by description when filename lacks 'ex107'."
        ),
        ExhibitTypeRule(
            id: "ex4-specimen-numbered",
            priority: 240,
            canonicalName: "Exhibit 4 — Specimen Security / Warrant Instrument",
            filenamePattern: #"(?i)ex[-_.x]?0?4([-_.x]?0?[1-9a-z])?(?![0-9])[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Exhibit 4 security specimen or warrant/rights agreement filed with bare number (e.g. '4.1') in index."
        ),
        ExhibitTypeRule(
            id: "ex10-contract-numbered",
            priority: 250,
            canonicalName: "Exhibit 10 — SPAC Material Contract (Numbered)",
            filenamePattern: #"(?i)ex[-_.x]?10(?!(7|1\.(ins|sch|cal|def|lab|pre)))[-_.x0-9a-z]*[^/]*\.(htm|html|txt)$"#,
            docNamePattern: nil,
            notes: "Exhibit 10 SPAC contract filed with bare exhibit number (e.g. '10.1'–'10.9') in index."
        )
    ]

    // MARK: - Queries

    func overview() async -> CatalogOverviewResponse {
        if !didLoadFromStore && !isSyncing,
           let (oData, _) = try? await store.read(overviewPath),
           let cached = try? JSONDecoder().decode(CatalogOverviewResponse.self, from: oData) {
            return cached
        }
        await ensureLoaded()
        return buildOverview()
    }

    func currentRules() async -> [ExhibitTypeRule] {
        await ensureLoaded()
        return rules.sorted { $0.priority < $1.priority }
    }

    func updateRules(_ updated: [ExhibitTypeRule]) async throws -> CatalogOverviewResponse {
        await ensureLoaded()
        // Validate every regex upfront so invalid syntax fails loudly instead of silently.
        let sorted = updated.sorted { $0.priority < $1.priority }
        _ = try Self.compileRules(sorted)

        let clock = ContinuousClock()
        let start = clock.now
        rules = sorted
        try Self.applyRules(rules, to: &exhibits, updatingSubmissions: &submissions)
        await persistCatalogArtifacts()

        let elapsed = Self.seconds(from: clock.now - start)
        let labeled = exhibits.reduce(0) { $0 + ($1.canonicalType != nil ? 1 : 0) }
        await logger.record(
            operation: "apply-rules",
            message: "Applied \(rules.count) regex type rules across \(exhibits.count) exhibits: \(labeled) labeled, \(exhibits.count - labeled) unlabeled.",
            durationSeconds: elapsed,
            metadata: [
                "ruleCount": "\(rules.count)",
                "labeledExhibits": "\(labeled)",
                "unlabeledExhibits": "\(exhibits.count - labeled)"
            ]
        )
        return buildOverview()
    }

    func querySubmissions(
        search: String?,
        form: String?,
        onlySIC6770: Bool,
        offset: Int,
        limit: Int
    ) async -> PagedSubmissionsResponse {
        await ensureLoaded()
        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let formFilter = form?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""

        let filtered = submissions.filter { sub in
            if onlySIC6770 && sub.sic != "6770" { return false }
            if !formFilter.isEmpty && sub.formType.uppercased() != formFilter { return false }
            guard !needle.isEmpty else { return true }
            return sub.accessionNo.lowercased().contains(needle)
                || sub.cik.lowercased().contains(needle)
                || sub.companyName.lowercased().contains(needle)
                || sub.fileNumber.lowercased().contains(needle)
                || sub.tickers.contains(where: { $0.lowercased().contains(needle) })
                || sub.stateOfIncorporationDescription.lowercased().contains(needle)
        }

        let safeOffset = min(max(offset, 0), filtered.count)
        let safeLimit = min(max(limit, 1), 500)
        let slice = Array(filtered.dropFirst(safeOffset).prefix(safeLimit))
        return PagedSubmissionsResponse(
            totalMatching: filtered.count,
            offset: safeOffset,
            limit: safeLimit,
            items: slice
        )
    }

    func queryDeals(search: String?, offset: Int, limit: Int) async -> PagedDealsResponse {
        await ensureLoaded()
        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        var grouped: [String: [SubmissionRecord]] = [:]
        for sub in submissions {
            let key = sub.fileNumber.isEmpty ? "cik:\(sub.cik):\(sub.accessionNo)" : "\(sub.fileNumber)_\(sub.cik)"
            grouped[key, default: []].append(sub)
        }

        var exhibitsByFolder: [String: [CatalogExhibit]] = [:]
        for ex in exhibits {
            exhibitsByFolder[ex.folderKey, default: []].append(ex)
        }

        var deals: [DealGroupRecord] = grouped.map { key, subs in
            let chronological = subs.sorted { $0.filingDate < $1.filingDate }
            let latest = chronological.last ?? subs[0]
            let earliest = chronological.first ?? subs[0]
            var distinctTypes = Set<String>()
            var totalEx = 0
            for s in chronological {
                let list = exhibitsByFolder[s.folderKey] ?? []
                totalEx += list.count
                for item in list {
                    if let t = item.canonicalType { distinctTypes.insert(t) }
                }
            }
            return DealGroupRecord(
                dealKey: key,
                fileNumber: latest.fileNumber.isEmpty ? "Unassigned" : latest.fileNumber,
                cik: latest.cik,
                companyName: latest.companyName,
                sic: latest.sic,
                stateOfIncorporationDescription: latest.stateOfIncorporationDescription,
                earliestFilingDate: earliest.filingDate,
                latestFilingDate: latest.filingDate,
                submissionCount: chronological.count,
                totalExhibits: totalEx,
                distinctCanonicalTypes: distinctTypes.sorted(),
                submissions: chronological.reversed()
            )
        }

        deals.sort {
            if $0.latestFilingDate != $1.latestFilingDate {
                return $0.latestFilingDate > $1.latestFilingDate
            }
            return $0.dealKey < $1.dealKey
        }

        if !needle.isEmpty {
            deals = deals.filter { d in
                d.companyName.lowercased().contains(needle)
                    || d.fileNumber.lowercased().contains(needle)
                    || d.cik.lowercased().contains(needle)
                    || d.stateOfIncorporationDescription.lowercased().contains(needle)
                    || d.submissions.contains(where: { $0.accessionNo.lowercased().contains(needle) })
            }
        }

        let safeOffset = min(max(offset, 0), deals.count)
        let safeLimit = min(max(limit, 1), 200)
        let slice = Array(deals.dropFirst(safeOffset).prefix(safeLimit))
        return PagedDealsResponse(
            totalMatching: deals.count,
            offset: safeOffset,
            limit: safeLimit,
            items: slice
        )
    }

    func queryExhibits(
        status: String?,
        canonicalType: String?,
        ruleID: String?,
        folderKey: String?,
        search: String?,
        offset: Int,
        limit: Int
    ) async -> PagedExhibitsResponse {
        await ensureLoaded()
        let statusMode = (status ?? "all").lowercased()
        let typeFilter = canonicalType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ruleFilter = ruleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folderFilter = folderKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needle = search?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let filtered = exhibits.filter { ex in
            if statusMode == "labeled" && ex.canonicalType == nil { return false }
            if statusMode == "unlabeled" && ex.canonicalType != nil { return false }
            if !typeFilter.isEmpty && ex.canonicalType != typeFilter { return false }
            if !ruleFilter.isEmpty && ex.matchedRuleID != ruleFilter { return false }
            if !folderFilter.isEmpty && ex.folderKey != folderFilter { return false }
            guard !needle.isEmpty else { return true }
            return ex.filename.lowercased().contains(needle)
                || ex.docName.lowercased().contains(needle)
                || ex.accessionNo.lowercased().contains(needle)
                || ex.companyName.lowercased().contains(needle)
                || ex.fileNumber.lowercased().contains(needle)
                || (ex.canonicalType?.lowercased().contains(needle) ?? false)
        }

        let safeOffset = min(max(offset, 0), filtered.count)
        let safeLimit = min(max(limit, 1), 500)
        let slice = Array(filtered.dropFirst(safeOffset).prefix(safeLimit))
        return PagedExhibitsResponse(
            totalMatching: filtered.count,
            offset: safeOffset,
            limit: safeLimit,
            items: slice
        )
    }

    func allDealGroupsSnapshot() async -> (
        deals: [DealGroupRecord],
        totalPackages: Int,
        totalExhibits: Int,
        labeledExhibits: Int
    ) {
        await ensureLoaded()
        var grouped: [String: [SubmissionRecord]] = [:]
        for sub in submissions {
            let key = sub.fileNumber.isEmpty ? "cik:\(sub.cik):\(sub.accessionNo)" : "\(sub.fileNumber)_\(sub.cik)"
            grouped[key, default: []].append(sub)
        }
        var exhibitsByFolder: [String: [CatalogExhibit]] = [:]
        var labeledCount = 0
        for ex in exhibits {
            exhibitsByFolder[ex.folderKey, default: []].append(ex)
            if ex.canonicalType != nil { labeledCount += 1 }
        }
        var deals: [DealGroupRecord] = grouped.map { key, subs in
            let chronological = subs.sorted { $0.filingDate < $1.filingDate }
            let latest = chronological.last ?? subs[0]
            let earliest = chronological.first ?? subs[0]
            var distinctTypes = Set<String>()
            var totalEx = 0
            for s in chronological {
                let list = exhibitsByFolder[s.folderKey] ?? []
                totalEx += list.count
                for item in list {
                    if let t = item.canonicalType { distinctTypes.insert(t) }
                }
            }
            return DealGroupRecord(
                dealKey: key,
                fileNumber: latest.fileNumber.isEmpty ? "Unassigned" : latest.fileNumber,
                cik: latest.cik,
                companyName: latest.companyName,
                sic: latest.sic,
                stateOfIncorporationDescription: latest.stateOfIncorporationDescription,
                earliestFilingDate: earliest.filingDate,
                latestFilingDate: latest.filingDate,
                submissionCount: chronological.count,
                totalExhibits: totalEx,
                distinctCanonicalTypes: distinctTypes.sorted(),
                submissions: chronological.reversed()
            )
        }
        deals.sort {
            if $0.latestFilingDate != $1.latestFilingDate {
                return $0.latestFilingDate > $1.latestFilingDate
            }
            return $0.dealKey < $1.dealKey
        }
        return (
            deals: deals,
            totalPackages: submissions.count,
            totalExhibits: exhibits.count,
            labeledExhibits: labeledCount
        )
    }

    func exhibitsForDeal(folderKeys: Set<String>) async -> [CatalogExhibit] {
        await ensureLoaded()
        return exhibits
            .filter { folderKeys.contains($0.folderKey) }
            .sorted {
                if $0.filingDate != $1.filingDate { return $0.filingDate > $1.filingDate }
                return $0.filename < $1.filename
            }
    }

    // MARK: - Background Sync & 2020–2026 Corpus Cleanup

    static func is2020OrLater(accessionNo: String) -> Bool {
        let parts = accessionNo.split(separator: "-")
        guard parts.count == 3, parts[1].count == 2, let yy = Int(parts[1]) else {
            return true
        }
        // SEC EDGAR accession numbers began in 1994 (94..99) and rolled over to 00..26+.
        return yy >= 20 && yy <= 89
    }

    func startSyncIfNeeded(
        forceRefreshSEC: Bool = false,
        upgradeDefaultRules: Bool = false,
        onStateReconciled: (@Sendable ([String], Int) async -> Void)? = nil
    ) async -> CatalogOverviewResponse {
        await ensureLoaded()
        guard !isSyncing else {
            return buildOverview()
        }
        if upgradeDefaultRules {
            rules = Self.defaultRules.sorted { $0.priority < $1.priority }
        }
        isSyncing = true
        syncPhase = "Enumerating GCS document packages…"
        syncCompleted = 0
        syncTotal = 0

        Task {
            await self.performSync(forceRefreshSEC: forceRefreshSEC, onStateReconciled: onStateReconciled)
        }
        return buildOverview()
    }

    func startClean2020Corpus(
        onStateReconciled: (@Sendable ([String], Int) async -> Void)? = nil
    ) async -> CatalogOverviewResponse {
        await ensureLoaded()
        guard !isSyncing else {
            return buildOverview()
        }
        isSyncing = true
        syncPhase = "Auditing GCS packages for 2020–2026 cleanup…"
        syncCompleted = 0
        syncTotal = 0

        Task {
            await self.performClean2020Corpus(onStateReconciled: onStateReconciled)
        }
        return buildOverview()
    }

    /// Prunes pre-2020 (`1994–2019`) packages from GCS, backfills missing exhibits on `2020–2026` packages
    /// directly from official `www.sec.gov` `{accessionNo}-index.htm`, upgrades default regex rules, and rebuilds catalog + JSONL artifacts.
    func performClean2020Corpus(
        onStateReconciled: (@Sendable ([String], Int) async -> Void)? = nil
    ) async {
        await ensureLoaded()
        isSyncing = true
        let clock = ContinuousClock()
        let startedAt = clock.now
        defer {
            isSyncing = false
            syncPhase = "Idle"
        }

        do {
            syncPhase = "Listing packages in gs://\(store.bucket)/\(filingsPrefix)/…"
            let rawPrefixes = try await store.listSubprefixes(under: filingsPrefix)
            let allPackages: [(folderKey: String, accessionNo: String, cik: String)] = rawPrefixes.compactMap { p in
                let trimmed = p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let folderKey = trimmed.split(separator: "/").last.map(String.init) else { return nil }
                let parts = folderKey.split(separator: "_", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (folderKey: folderKey, accessionNo: parts[0], cik: parts[1])
            }

            let pre2020Packages = allPackages.filter { !Self.is2020OrLater(accessionNo: $0.accessionNo) }
            let modernPackages = allPackages.filter { Self.is2020OrLater(accessionNo: $0.accessionNo) }

            var deletedObjects = 0
            if !pre2020Packages.isEmpty {
                syncPhase = "Deleting \(pre2020Packages.count) pre-2020 packages from GCS…"
                syncCompleted = 0
                syncTotal = pre2020Packages.count
                let storeRef = self.store
                let rootPrefix = self.filingsPrefix

                let perFolderCounts = try await ConcurrentJobs.run(pre2020Packages, limit: 64) { [weak self] pkg -> Int in
                    let names = (try? await storeRef.listObjectNames(under: "\(rootPrefix)/\(pkg.folderKey)/")) ?? []
                    for name in names {
                        try? await storeRef.delete(name)
                    }
                    await self?.incrementProgress()
                    return names.count
                }
                deletedObjects = perFolderCounts.reduce(0, +)
            }

            // Drop pre-2020 entries from in-memory caches before checking for 2020+ zero-exhibit packages.
            let modernFolderKeys = Set(modernPackages.map(\.folderKey))
            submissions.removeAll { !modernFolderKeys.contains($0.folderKey) }
            exhibits.removeAll { !modernFolderKeys.contains($0.folderKey) }

            var primaryDocByFolder: [String: String] = [:]
            for sub in submissions where !sub.primaryDocument.isEmpty {
                primaryDocByFolder[sub.folderKey] = sub.primaryDocument
            }

            let foldersWithCachedExhibits = Set(exhibits.map(\.folderKey))
            let candidateEmptyPackages = modernPackages.filter { !foldersWithCachedExhibits.contains($0.folderKey) }

            var emptyModernPackages: [(folderKey: String, accessionNo: String, cik: String)] = []
            if !candidateEmptyPackages.isEmpty {
                syncPhase = "Checking manifests for \(candidateEmptyPackages.count) 2020+ packages…"
                syncCompleted = 0
                syncTotal = candidateEmptyPackages.count
                let storeRef = self.store
                let rootPrefix = self.filingsPrefix

                let checked = try await ConcurrentJobs.run(candidateEmptyPackages, limit: 32) { [weak self] pkg -> (String, String, String)? in
                    let manifestPath = "\(rootPrefix)/\(pkg.folderKey)/exhibits/manifest.json"
                    if let (data, _) = try? await storeRef.read(manifestPath),
                       let decoded = try? JSONDecoder().decode([SavedExhibit].self, from: data),
                       !decoded.isEmpty {
                        await self?.incrementProgress()
                        return nil
                    }
                    await self?.incrementProgress()
                    return pkg
                }
                emptyModernPackages = checked.compactMap { $0 }
            }

            var backfilledPackages = 0
            var backfilledExhibits = 0
            if !emptyModernPackages.isEmpty {
                syncPhase = "Backfilling exhibits from sec.gov for \(emptyModernPackages.count) 2020+ filings…"
                syncCompleted = 0
                syncTotal = emptyModernPackages.count

                for pkg in emptyModernPackages {
                    let recovered = await ExhibitScraper.backfillExhibitsDirectFromSEC(
                        folderKey: pkg.folderKey,
                        accessionNo: pkg.accessionNo,
                        cik: pkg.cik,
                        primaryDocument: primaryDocByFolder[pkg.folderKey] ?? "",
                        prefix: filingsPrefix,
                        store: store,
                        secUserAgent: secUserAgent
                    )
                    if !recovered.isEmpty {
                        backfilledPackages += 1
                        backfilledExhibits += recovered.count
                        exhibits.removeAll { $0.folderKey == pkg.folderKey }
                    }
                    syncCompleted += 1
                }
            }

            // Upgrade rules to the latest default SPAC rulebook and run full catalog sync.
            rules = Self.defaultRules.sorted { $0.priority < $1.priority }
            try await runSyncPipeline(forceRefreshSEC: false, secFetcher: nil, startedAt: startedAt)

            if let onStateReconciled {
                await onStateReconciled(submissions.map(\.accessionNo), exhibits.count)
            }

            let elapsed = Self.seconds(from: clock.now - startedAt)
            await logger.record(
                operation: "clean-2020-corpus",
                message: "Pruned \(pre2020Packages.count) pre-2020 packages (\(deletedObjects) objects), backfilled \(backfilledExhibits) exhibits across \(backfilledPackages) 2020+ filings from sec.gov; \(submissions.count) modern packages and \(exhibits.count) exhibits live.",
                durationSeconds: elapsed,
                metadata: [
                    "deletedPre2020Packages": "\(pre2020Packages.count)",
                    "deletedObjects": "\(deletedObjects)",
                    "backfilledPackages": "\(backfilledPackages)",
                    "backfilledExhibits": "\(backfilledExhibits)",
                    "survivingPackages": "\(submissions.count)",
                    "totalExhibits": "\(exhibits.count)"
                ]
            )
        } catch {
            await logger.record(
                severity: "ERROR",
                operation: "clean-2020-corpus",
                message: "2020+ corpus cleanup failed: \(error.localizedDescription)"
            )
        }
    }

    /// Runs synchronously (used in tests or direct calls) and updates persisted catalog artifacts.
    func performSync(
        forceRefreshSEC: Bool = false,
        secFetcher: (@Sendable (String) async throws -> Data)? = nil,
        onStateReconciled: (@Sendable ([String], Int) async -> Void)? = nil
    ) async {
        await ensureLoaded()
        isSyncing = true
        let startedAt = ContinuousClock.now
        defer {
            isSyncing = false
            syncPhase = "Idle"
        }

        do {
            try await runSyncPipeline(forceRefreshSEC: forceRefreshSEC, secFetcher: secFetcher, startedAt: startedAt)
            if let onStateReconciled {
                await onStateReconciled(submissions.map(\.accessionNo), exhibits.count)
            }
        } catch {
            await logger.record(
                severity: "ERROR",
                operation: "sync-catalog",
                message: "Catalog sync failed: \(error.localizedDescription)"
            )
        }
    }

    private func runSyncPipeline(
        forceRefreshSEC: Bool,
        secFetcher: (@Sendable (String) async throws -> Data)?,
        startedAt: ContinuousClock.Instant
    ) async throws {
            let clock = ContinuousClock()
            // 1. Enumerate all `filings/<accessionNo>_<cik>/` document packages in GCS.
            syncPhase = "Listing packages in gs://\(store.bucket)/\(filingsPrefix)/…"
            let rawPrefixes = try await store.listSubprefixes(under: filingsPrefix)
            let parsedPackages: [(folderKey: String, accessionNo: String, cik: String)] = rawPrefixes.compactMap { p in
                let trimmed = p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let folderKey = trimmed.split(separator: "/").last.map(String.init) else { return nil }
                let parts = folderKey.split(separator: "_", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (folderKey: folderKey, accessionNo: parts[0], cik: parts[1])
            }

            // 2. Fetch or load official SEC `CIK##########.json` (`data.sec.gov/submissions`) for all unique CIKs.
            let uniqueCIKs = Array(Set(parsedPackages.map(\.cik))).sorted()
            let existingSECObjects: Set<String>
            if forceRefreshSEC {
                existingSECObjects = []
            } else {
                let names = (try? await store.listObjectNames(under: "\(secCachePrefix)/")) ?? []
                existingSECObjects = Set(names)
            }

            let missingCIKs = uniqueCIKs.filter { cik in
                let padded = Self.paddedCIK(cik)
                return !existingSECObjects.contains("\(secCachePrefix)/CIK\(padded).json")
            }

            if !missingCIKs.isEmpty {
                syncPhase = "Downloading official SEC submissions JSON (\(missingCIKs.count) CIKs)…"
                syncCompleted = 0
                syncTotal = missingCIKs.count
                let store = self.store
                let cachePrefix = self.secCachePrefix
                let ua = self.secUserAgent

                _ = try await ConcurrentJobs.run(missingCIKs, limit: 6) { [weak self] cik -> Bool in
                    let padded = Self.paddedCIK(cik)
                    do {
                        let data: Data
                        if let secFetcher {
                            data = try await secFetcher(padded)
                        } else {
                            data = try await Self.fetchSECSubmissionsJSON(paddedCIK: padded, userAgent: ua)
                        }
                        try await store.write(
                            data,
                            to: "\(cachePrefix)/CIK\(padded).json",
                            contentType: "application/json"
                        )
                        await self?.incrementProgress()
                        return true
                    } catch {
                        await self?.incrementProgress()
                        return false
                    }
                }
            }

            // 3. Decode cached SEC `CIK##########.json` into a fast lookup table keyed by `(cik, accessionNo)`.
            syncPhase = "Indexing official SEC submissions metadata…"
            syncCompleted = 0
            syncTotal = uniqueCIKs.count
            let storeRef = self.store
            let cachePrefix = self.secCachePrefix

            struct CIKIndexResult: Sendable {
                let cik: String
                let companyName: String
                let tickers: [String]
                let sic: String
                let sicDescription: String
                let stateOfIncorporation: String
                let stateOfIncorporationDescription: String
                let byAccession: [String: SECFilingMeta]
            }

            let cikResults = try await ConcurrentJobs.run(uniqueCIKs, limit: 32) { [weak self] cik -> CIKIndexResult? in
                let padded = Self.paddedCIK(cik)
                guard let (data, _) = try? await storeRef.read("\(cachePrefix)/CIK\(padded).json"),
                      let decoded = try? JSONDecoder().decode(SECSubmissionsFile.self, from: data) else {
                    await self?.incrementProgress()
                    return nil
                }
                var map: [String: SECFilingMeta] = [:]
                if let recent = decoded.filings?.recent {
                    Self.collectColumns(recent, into: &map)
                }
                await self?.incrementProgress()
                return CIKIndexResult(
                    cik: cik,
                    companyName: decoded.name ?? "CIK \(cik)",
                    tickers: decoded.tickers ?? [],
                    sic: decoded.sic ?? "",
                    sicDescription: decoded.sicDescription ?? "",
                    stateOfIncorporation: decoded.stateOfIncorporation ?? "",
                    stateOfIncorporationDescription: decoded.stateOfIncorporationDescription ?? "",
                    byAccession: map
                )
            }

            var cikLookup: [String: CIKIndexResult] = [:]
            for item in cikResults.compactMap({ $0 }) {
                cikLookup[item.cik] = item
            }

            // 4. Read `exhibits/manifest.json` for packages (reusing cached manifests for already-indexed packages!).
            var existingManifestByFolder: [String: [CatalogExhibit]] = [:]
            for ex in exhibits {
                existingManifestByFolder[ex.folderKey, default: []].append(ex)
            }

            let uncachedPackages = parsedPackages.filter { existingManifestByFolder[$0.folderKey] == nil }
            var newlyReadManifests: [String: [SavedExhibit]] = [:]

            if !uncachedPackages.isEmpty {
                syncPhase = "Reading exhibit manifests (\(uncachedPackages.count) new packages)…"
                syncCompleted = 0
                syncTotal = uncachedPackages.count
                let rootPrefix = self.filingsPrefix

                let pairs = try await ConcurrentJobs.run(uncachedPackages, limit: 64) { [weak self] pkg -> (String, [SavedExhibit]) in
                    let manifestPath = "\(rootPrefix)/\(pkg.folderKey)/exhibits/manifest.json"
                    guard let (data, _) = try? await storeRef.read(manifestPath),
                          let saved = try? JSONDecoder().decode([SavedExhibit].self, from: data) else {
                        await self?.incrementProgress()
                        return (pkg.folderKey, [])
                    }
                    await self?.incrementProgress()
                    return (pkg.folderKey, saved)
                }
                for (folderKey, list) in pairs {
                    newlyReadManifests[folderKey] = list
                }
            }

            // 5. Join packages + SEC `submissions` metadata + exhibits, then apply deterministic regex rules.
            syncPhase = "Joining SEC metadata & applying type rules…"
            var builtSubmissions: [SubmissionRecord] = []
            builtSubmissions.reserveCapacity(parsedPackages.count)
            var builtExhibits: [CatalogExhibit] = []

            for pkg in parsedPackages {
                let cikInfo = cikLookup[pkg.cik]
                let secMeta = cikInfo?.byAccession[pkg.accessionNo]
                let companyName = cikInfo?.companyName ?? "CIK \(pkg.cik)"
                let formType = secMeta?.form ?? "S-1"
                let fileNumber = secMeta?.fileNumber ?? ""
                let filingDate = secMeta?.filingDate ?? ""

                let packageExhibits: [CatalogExhibit]
                if let fresh = newlyReadManifests[pkg.folderKey] {
                    packageExhibits = fresh.map { saved in
                        CatalogExhibit(
                            folderKey: pkg.folderKey,
                            accessionNo: pkg.accessionNo,
                            cik: pkg.cik,
                            companyName: companyName,
                            fileNumber: fileNumber,
                            formType: formType,
                            filingDate: filingDate,
                            filename: saved.filename,
                            docName: saved.attachment.docName,
                            docURL: saved.attachment.docURL,
                            objectPath: saved.objectPath,
                            canonicalType: nil,
                            matchedRuleID: nil
                        )
                    }
                } else if let cached = existingManifestByFolder[pkg.folderKey] {
                    packageExhibits = cached.map { old in
                        CatalogExhibit(
                            folderKey: pkg.folderKey,
                            accessionNo: pkg.accessionNo,
                            cik: pkg.cik,
                            companyName: companyName,
                            fileNumber: fileNumber,
                            formType: formType,
                            filingDate: filingDate,
                            filename: old.filename,
                            docName: old.docName,
                            docURL: old.docURL,
                            objectPath: old.objectPath,
                            canonicalType: nil,
                            matchedRuleID: nil
                        )
                    }
                } else {
                    packageExhibits = []
                }

                builtExhibits.append(contentsOf: packageExhibits)
                builtSubmissions.append(SubmissionRecord(
                    folderKey: pkg.folderKey,
                    accessionNo: pkg.accessionNo,
                    cik: pkg.cik,
                    companyName: companyName,
                    tickers: cikInfo?.tickers ?? [],
                    sic: cikInfo?.sic ?? "",
                    sicDescription: cikInfo?.sicDescription ?? "",
                    stateOfIncorporation: cikInfo?.stateOfIncorporation ?? "",
                    stateOfIncorporationDescription: cikInfo?.stateOfIncorporationDescription ?? "",
                    formType: formType,
                    fileNumber: fileNumber,
                    filingDate: filingDate,
                    acceptanceDateTime: secMeta?.acceptanceDateTime ?? "",
                    primaryDocument: secMeta?.primaryDocument ?? "",
                    exhibitCount: packageExhibits.count,
                    labeledExhibitCount: 0,
                    matchedInSECSubmissions: secMeta != nil
                ))
            }

            builtSubmissions.sort {
                if $0.filingDate != $1.filingDate { return $0.filingDate > $1.filingDate }
                return $0.accessionNo > $1.accessionNo
            }

            try Self.applyRules(rules, to: &builtExhibits, updatingSubmissions: &builtSubmissions)

            submissions = builtSubmissions
            exhibits = builtExhibits
            syncedAtISO8601 = ISO8601DateFormatter().string(from: Date())

            syncPhase = "Writing catalog & JSONL tables to GCS…"
            await persistCatalogArtifacts()

            let elapsed = Self.seconds(from: clock.now - startedAt)
            let labeledCount = builtExhibits.reduce(0) { $0 + ($1.canonicalType != nil ? 1 : 0) }
            let matchedSEC = builtSubmissions.reduce(0) { $0 + ($1.matchedInSECSubmissions ? 1 : 0) }

            await logger.record(
                operation: "sync-catalog",
                message: "Indexed \(builtSubmissions.count) packages (\(matchedSEC) matched to SEC submissions.json) and \(builtExhibits.count) exhibits (\(labeledCount) typed).",
                durationSeconds: elapsed,
                metadata: [
                    "packages": "\(builtSubmissions.count)",
                    "matchedSEC": "\(matchedSEC)",
                    "uniqueCIKs": "\(uniqueCIKs.count)",
                    "exhibits": "\(builtExhibits.count)",
                    "labeledExhibits": "\(labeledCount)"
                ]
            )
    }

    // MARK: - Rule Evaluation ("One-Triggers-All")

    private struct CompiledRule {
        let rule: ExhibitTypeRule
        let filenameRegex: NSRegularExpression
        let docNameRegex: NSRegularExpression?
    }

    private static func compileRules(_ rules: [ExhibitTypeRule]) throws -> [CompiledRule] {
        try rules.sorted(by: { $0.priority < $1.priority }).map { rule in
            let fnRegex = try NSRegularExpression(pattern: rule.filenamePattern, options: [])
            let trimmedDoc = rule.docNamePattern?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let docRegex = trimmedDoc.isEmpty ? nil : try NSRegularExpression(pattern: trimmedDoc, options: [])
            return CompiledRule(rule: rule, filenameRegex: fnRegex, docNameRegex: docRegex)
        }
    }

    static func applyRules(
        _ rules: [ExhibitTypeRule],
        to exhibits: inout [CatalogExhibit],
        updatingSubmissions submissions: inout [SubmissionRecord]
    ) throws {
        let compiled = try compileRules(rules)
        var labeledByFolder: [String: Int] = [:]

        for idx in exhibits.indices {
            let fn = exhibits[idx].filename
            let fnRange = NSRange(fn.startIndex..<fn.endIndex, in: fn)
            let dn = exhibits[idx].docName
            let dnRange = NSRange(dn.startIndex..<dn.endIndex, in: dn)

            var matched: ExhibitTypeRule?
            for candidate in compiled {
                guard candidate.filenameRegex.firstMatch(in: fn, options: [], range: fnRange) != nil else {
                    continue
                }
                if let docRegex = candidate.docNameRegex {
                    guard docRegex.firstMatch(in: dn, options: [], range: dnRange) != nil else {
                        continue
                    }
                }
                matched = candidate.rule
                break
            }

            exhibits[idx].canonicalType = matched?.canonicalName
            exhibits[idx].matchedRuleID = matched?.id
            if matched != nil {
                labeledByFolder[exhibits[idx].folderKey, default: 0] += 1
            }
        }

        for idx in submissions.indices {
            submissions[idx].labeledExhibitCount = labeledByFolder[submissions[idx].folderKey] ?? 0
        }
    }

    // MARK: - Persistence & Helpers

    private struct SECFilingMeta: Sendable {
        let form: String
        let fileNumber: String
        let filingDate: String
        let acceptanceDateTime: String
        let primaryDocument: String
    }

    private static func collectColumns(_ cols: SubmissionColumns, into map: inout [String: SECFilingMeta]) {
        guard let accessions = cols.accessionNumber else { return }
        let forms = cols.form ?? []
        let fileNos = cols.fileNumber ?? []
        let dates = cols.filingDate ?? []
        let acceptances = cols.acceptanceDateTime ?? []
        let docs = cols.primaryDocument ?? []

        for i in accessions.indices {
            let acc = accessions[i]
            map[acc] = SECFilingMeta(
                form: i < forms.count ? forms[i] : "",
                fileNumber: i < fileNos.count ? fileNos[i] : "",
                filingDate: i < dates.count ? dates[i] : "",
                acceptanceDateTime: i < acceptances.count ? acceptances[i] : "",
                primaryDocument: i < docs.count ? docs[i] : ""
            )
        }
    }

    private static func paddedCIK(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        if digits.count >= 10 { return digits }
        return String(repeating: "0", count: 10 - digits.count) + digits
    }

    private static func fetchSECSubmissionsJSON(paddedCIK: String, userAgent: String) async throws -> Data {
        guard let url = URL(string: "https://data.sec.gov/submissions/CIK\(paddedCIK).json") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        // Polite pacing (~120ms) per worker slot so 6 slots stay comfortably under SEC's 10 req/s guideline.
        try await Task.sleep(for: .milliseconds(120))
        return try await getData(request: request)
    }

    private func incrementProgress() {
        syncCompleted += 1
    }

    private func ensureLoaded() async {
        guard !didLoadFromStore else { return }
        didLoadFromStore = true
        let decoder = JSONDecoder()

        if let (rData, _) = try? await store.read(rulesPath),
           let savedRules = try? decoder.decode([ExhibitTypeRule].self, from: rData),
           !savedRules.isEmpty {
            rules = savedRules
        }
        if let (sData, _) = try? await store.read(submissionsPath),
           let savedSubs = try? decoder.decode([SubmissionRecord].self, from: sData) {
            submissions = savedSubs
        }
        if let (eData, _) = try? await store.read(exhibitsPath),
           let savedEx = try? decoder.decode([CatalogExhibit].self, from: eData) {
            exhibits = savedEx
        }
        if let (oData, _) = try? await store.read(overviewPath),
           let savedOv = try? decoder.decode(CatalogOverviewResponse.self, from: oData) {
            syncedAtISO8601 = savedOv.syncedAtISO8601
        }
    }

    private func persistCatalogArtifacts() async {
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys]

        if let rData = try? pretty.encode(rules) {
            try? await store.write(rData, to: rulesPath, contentType: "application/json")
        }
        if let sData = try? compact.encode(submissions) {
            try? await store.write(sData, to: submissionsPath, contentType: "application/json")
        }
        if let eData = try? compact.encode(exhibits) {
            try? await store.write(eData, to: exhibitsPath, contentType: "application/json")
        }
        // Also write newline-delimited JSONL files so BigQuery (`bq load --source_format=NEWLINE_DELIMITED_JSON`) can ingest directly!
        if let sJSONL = Self.encodeJSONLines(submissions, encoder: compact) {
            try? await store.write(sJSONL, to: submissionsJSONLPath, contentType: "application/x-ndjson")
        }
        if let eJSONL = Self.encodeJSONLines(exhibits, encoder: compact) {
            try? await store.write(eJSONL, to: exhibitsJSONLPath, contentType: "application/x-ndjson")
        }
        let ov = buildOverview()
        if let oData = try? pretty.encode(ov) {
            try? await store.write(oData, to: overviewPath, contentType: "application/json")
        }
    }

    private static func encodeJSONLines<T: Encodable>(_ items: [T], encoder: JSONEncoder) -> Data? {
        var out = Data()
        let newline = Data("\n".utf8)
        for item in items {
            guard let row = try? encoder.encode(item) else { continue }
            out.append(row)
            out.append(newline)
        }
        return out
    }

    private func buildOverview() -> CatalogOverviewResponse {
        var countsByRule: [String: Int] = [:]
        var labeled = 0
        for ex in exhibits {
            if let rid = ex.matchedRuleID {
                countsByRule[rid, default: 0] += 1
                labeled += 1
            }
        }
        let summaries = rules.sorted(by: { $0.priority < $1.priority }).map { rule in
            TypeRuleSummary(rule: rule, matchedCount: countsByRule[rule.id] ?? 0)
        }
        let matchedSEC = submissions.reduce(0) { $0 + ($1.matchedInSECSubmissions ? 1 : 0) }
        let uniqueCIKs = Set(submissions.map(\.cik)).count
        let uniqueFiles = Set(submissions.map(\.fileNumber).filter { !$0.isEmpty }).count
        let sic6770 = submissions.reduce(0) { $0 + ($1.sic == "6770" ? 1 : 0) }

        return CatalogOverviewResponse(
            bucket: store.bucket,
            syncedAtISO8601: syncedAtISO8601,
            isSyncing: isSyncing,
            syncPhase: syncPhase,
            syncCompleted: syncCompleted,
            syncTotal: syncTotal,
            totalPackagesInBucket: submissions.count,
            matchedToSECSubmissions: matchedSEC,
            uniqueCIKs: uniqueCIKs,
            uniqueFileNumbers: uniqueFiles,
            spacSIC6770Count: sic6770,
            totalExhibits: exhibits.count,
            labeledExhibits: labeled,
            unlabeledExhibits: max(0, exhibits.count - labeled),
            ruleSummaries: summaries
        )
    }

    private static func seconds(from duration: Duration) -> Double {
        let c = duration.components
        let raw = Double(c.seconds) + (Double(c.attoseconds) / 1e18)
        return (raw * 100).rounded() / 100
    }
}
