import Foundation

// MARK: - SEC Query Request

struct SECAPIQuery: Codable, Sendable {
    let query: String
    let from: String
    let size: String
    let sort: [Sort]

    init(
        query: String = #"entities.sic:"6770" AND formType:"S-1" AND filedAt:[2020-01-01 TO 2026-12-31]"#,
        from: String = "0",
        size: String = "50",
        sort: [Sort] = [Sort(filedAt: FiledAt(order: "desc"))]
    ) {
        self.query = query
        self.from = from
        self.size = size
        self.sort = sort
    }

    struct Sort: Codable, Sendable {
        let filedAt: FiledAt
    }

    struct FiledAt: Codable, Sendable {
        let order: String
    }
}

// MARK: - SEC Query Response

struct SECAPIFilingQueryResponsesBox: Codable, Sendable {
    let total: Total
    let filings: [Filing]

    struct Total: Codable, Sendable {
        let value: Int
        let relation: String
    }
}

struct Filing: Codable, Sendable {
    struct DocumentFormatFile: Codable, Equatable, Sendable {
        let description: String?
        let documentUrl: String?
        let type: String?

        init(description: String? = nil, documentUrl: String? = nil, type: String? = nil) {
            self.description = description
            self.documentUrl = documentUrl
            self.type = type
        }
    }

    let accessionNo: String
    let cik: String
    let linkToFilingDetails: String
    let linkToHtml: String?
    let documentFormatFiles: [DocumentFormatFile]?
    let ticker: String?
    let companyName: String?
    let formType: String?
    let filedAt: String?

    var folderKey: String {
        "\(accessionNo)_\(cik)"
    }

    init(
        accessionNo: String,
        cik: String,
        linkToFilingDetails: String,
        linkToHtml: String? = nil,
        documentFormatFiles: [DocumentFormatFile]? = nil,
        ticker: String? = nil,
        companyName: String? = nil,
        formType: String? = nil,
        filedAt: String? = nil
    ) {
        self.accessionNo = accessionNo
        self.cik = cik
        self.linkToFilingDetails = linkToFilingDetails
        self.linkToHtml = linkToHtml
        self.documentFormatFiles = documentFormatFiles
        self.ticker = ticker
        self.companyName = companyName
        self.formType = formType
        self.filedAt = filedAt
    }
}

// MARK: - Scrape Artifacts & Corpus State

struct Attachment: Codable, Hashable, Identifiable, Sendable {
    var id: String { docURL }
    let docName: String
    let docURL: String
}

struct SavedExhibit: Codable, Sendable {
    let attachment: Attachment
    let filename: String
    let objectPath: String
}

struct FailedExhibit: Codable, Sendable {
    let attachment: Attachment
    let message: String
}

struct FilingScrapeResult: Codable, Sendable {
    let folderKey: String
    let cik: String
    let accessionNo: String
    let companyName: String?
    let ticker: String?
    let formType: String?
    let filedAt: String?
    let filingObjectPath: String
    let savedExhibits: [SavedExhibit]
    let failedExhibits: [FailedExhibit]
}

struct BatchRunSummary: Codable, Identifiable, Sendable {
    let id: String
    let completedAtISO8601: String
    let query: String
    let filingsAdded: Int
    let exhibitsAdded: Int
    let exhibitsFailed: Int
    let durationSeconds: Double
}

struct CorpusState: Codable, Sendable {
    var query: String = #"entities.sic:"6770" AND formType:"S-1" AND filedAt:[2020-01-01 TO 2026-12-31]"#
    var nextOffset: Int = 0
    var offsetsByQuery: [String: Int]? = nil
    var totalFilingsSaved: Int = 0
    var totalExhibitsSaved: Int = 0
    var savedAccessionNumbers: [String] = []
    var recentRuns: [BatchRunSummary] = []

    func offset(for targetQuery: String) -> Int {
        if let mapped = offsetsByQuery?[targetQuery] {
            return mapped
        }
        return targetQuery == query ? nextOffset : 0
    }

    mutating func setOffset(_ value: Int, for targetQuery: String) {
        var dict = offsetsByQuery ?? [query: nextOffset]
        dict[targetQuery] = value
        offsetsByQuery = dict
        query = targetQuery
        nextOffset = value
    }
}

struct LiveStatusResponse: Codable, Sendable {
    let bucket: String
    let query: String
    let isRunning: Bool
    let completedInCurrentBatch: Int
    let targetInCurrentBatch: Int
    let exhibitsInCurrentBatch: Int
    let elapsedSeconds: Double
    let totalFilingsInBucket: Int
    let totalExhibitsInBucket: Int
    let nextOffset: Int
    let offsetsByQuery: [String: Int]
    let recentRuns: [BatchRunSummary]
}

struct ScrapeRequest: Decodable, Sendable {
    let query: String?
    let count: Int?
}

struct WorkerFilingRequest: Codable, Sendable {
    let filing: Filing
    let prefix: String
}

struct ScrapeResponse: Codable, Sendable {
    let bucket: String
    let query: String
    let filingsAdded: Int
    let exhibitsAdded: Int
    let exhibitsFailed: Int
    let durationSeconds: Double
    let totalFilingsInBucket: Int
    let totalExhibitsInBucket: Int
    let nextOffset: Int
    let offsetsByQuery: [String: Int]
    let recentRuns: [BatchRunSummary]
}

// MARK: - Official SEC `submissions` Schema (`CIK##########.json` / `submissions.zip`)

struct SECSubmissionsFile: Codable, Sendable {
    let cik: String?
    let entityType: String?
    let sic: String?
    let sicDescription: String?
    let name: String?
    let tickers: [String]?
    let exchanges: [String]?
    let stateOfIncorporation: String?
    let stateOfIncorporationDescription: String?
    let filings: FilingsContainer?

    struct FilingsContainer: Codable, Sendable {
        let recent: SubmissionColumns?
        let files: [OverflowFileRef]?
    }

    struct OverflowFileRef: Codable, Sendable {
        let name: String
    }
}

struct SubmissionColumns: Codable, Sendable {
    let accessionNumber: [String]?
    let filingDate: [String]?
    let acceptanceDateTime: [String]?
    let act: [String]?
    let form: [String]?
    let fileNumber: [String]?
    let filmNumber: [String]?
    let primaryDocument: [String]?
    let primaryDocDescription: [String]?
}

// MARK: - Enriched Bucket Catalog & Deterministic "One-Triggers-All" Type Engine

struct SubmissionRecord: Codable, Identifiable, Sendable {
    var id: String { folderKey }
    let folderKey: String
    let accessionNo: String
    let cik: String
    let companyName: String
    let tickers: [String]
    let sic: String
    let sicDescription: String
    let stateOfIncorporation: String
    let stateOfIncorporationDescription: String
    let formType: String
    let fileNumber: String
    let filingDate: String
    let acceptanceDateTime: String
    let primaryDocument: String
    var exhibitCount: Int
    var labeledExhibitCount: Int
    let matchedInSECSubmissions: Bool
}

struct DealGroupRecord: Codable, Identifiable, Sendable {
    var id: String { dealKey }
    let dealKey: String
    let fileNumber: String
    let cik: String
    let companyName: String
    let sic: String
    let stateOfIncorporationDescription: String
    let earliestFilingDate: String
    let latestFilingDate: String
    let submissionCount: Int
    let totalExhibits: Int
    let distinctCanonicalTypes: [String]
    let submissions: [SubmissionRecord]
}

struct CatalogExhibit: Codable, Identifiable, Sendable {
    var id: String { objectPath }
    let folderKey: String
    let accessionNo: String
    let cik: String
    let companyName: String
    let fileNumber: String
    let formType: String
    let filingDate: String
    let filename: String
    let docName: String
    let docURL: String
    let objectPath: String
    var canonicalType: String?
    var matchedRuleID: String?
}

struct ExhibitTypeRule: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var priority: Int
    var canonicalName: String
    var filenamePattern: String
    var docNamePattern: String?
    var notes: String?
}

struct TypeRuleSummary: Codable, Identifiable, Sendable {
    var id: String { rule.id }
    let rule: ExhibitTypeRule
    let matchedCount: Int
}

struct CatalogOverviewResponse: Codable, Sendable {
    let bucket: String
    let syncedAtISO8601: String?
    let isSyncing: Bool
    let syncPhase: String
    let syncCompleted: Int
    let syncTotal: Int
    let totalPackagesInBucket: Int
    let matchedToSECSubmissions: Int
    let uniqueCIKs: Int
    let uniqueFileNumbers: Int
    let spacSIC6770Count: Int
    let totalExhibits: Int
    let labeledExhibits: Int
    let unlabeledExhibits: Int
    let ruleSummaries: [TypeRuleSummary]
}

struct PagedSubmissionsResponse: Codable, Sendable {
    let totalMatching: Int
    let offset: Int
    let limit: Int
    let items: [SubmissionRecord]
}

struct PagedDealsResponse: Codable, Sendable {
    let totalMatching: Int
    let offset: Int
    let limit: Int
    let items: [DealGroupRecord]
}

struct PagedExhibitsResponse: Codable, Sendable {
    let totalMatching: Int
    let offset: Int
    let limit: Int
    let items: [CatalogExhibit]
}

// MARK: - Form S-1 Cover-Page Deal Terms & Market Trends Observatory

struct DealTrendRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String { dealKey }
    let dealKey: String
    let fileNumber: String
    let cik: String
    let companyName: String
    let sic: String
    let isSPAC: Bool
    let jurisdiction: String
    let earliestFilingDate: String
    let latestFilingDate: String
    let filingYear: Int
    let filingQuarter: String
    let sourceFolderKey: String
    let sourceAccessionNo: String
    let sourceFormType: String
    let sourceFilingDate: String
    let submissionCount: Int
    let exhibitCount: Int
    let distinctExhibitTypes: [String]
    let ipoProceedsUSD: Int64?
    let overAllotmentProceedsUSD: Int64?
    let unitCount: Int64?
    let unitPriceUSD: Double?
    let bookrunners: [String]
    let issuerCounsel: [String]
    let underwriterCounsel: [String]
    let offshoreCounsel: [String]
    let counselPartners: [String]
    let warrantCoverage: String
    let trustPerUnitUSD: Double?
    let isOverfundedTrust: Bool
    let trustee: String?
    let combinationWindowMonths: Int?
    let exchange: String?
    let proposedTicker: String?
    let rawOfferingSnippet: String?
    let rawBookrunnerSnippet: String?
    let rawCopiesToSnippet: String?
    let rawUnitStructureSnippet: String?
    let secArchiveURL: String
}

struct LeagueTableEntry: Codable, Equatable, Sendable {
    let name: String
    let dealCount: Int
    let totalProceedsUSD: Int64
    let issuerRoleCount: Int
    let underwriterRoleCount: Int
}

struct QuarterlyTrendPoint: Codable, Equatable, Sendable {
    let quarter: String
    let dealCount: Int
    let spacDealCount: Int
    let pricedDealCount: Int
    let totalProceedsUSD: Int64
    let medianProceedsUSD: Int64
    let overfundedSharePct: Double
}

struct AnnualStructurePoint: Codable, Equatable, Sendable {
    let year: Int
    let dealCount: Int
    let buckets: [String: Int]
    let overfundedCount: Int
    let trustObservedCount: Int
    let avgCombinationMonths: Double?
}

struct TrendsExtractionStatus: Codable, Sendable {
    let isExtracting: Bool
    let phase: String
    let completedDeals: Int
    let totalDeals: Int
    let extractedAtISO8601: String?
}

struct TrendsDashboardResponse: Codable, Sendable {
    let bucket: String
    let extractedAtISO8601: String?
    let status: TrendsExtractionStatus
    let totalDeals: Int
    let spacDeals: Int
    let dealsWithProceeds: Int
    let dealsWithBookrunners: Int
    let dealsWithCounsel: Int
    let aggregateProceedsUSD: Int64
    let totalPackagesInCorpus: Int
    let totalExhibitsInCorpus: Int
    let labeledExhibitsInCorpus: Int
    let quarterlyTrends: [QuarterlyTrendPoint]
    let annualStructures: [AnnualStructurePoint]
    let bookrunnerLeague: [LeagueTableEntry]
    let counselLeague: [LeagueTableEntry]
    let deals: [DealTrendRecord]
}

struct DealDetailProofResponse: Codable, Sendable {
    let deal: DealTrendRecord
    let submissions: [SubmissionRecord]
    let exhibits: [CatalogExhibit]
}
