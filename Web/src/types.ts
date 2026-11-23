export interface DealTrendRecord {
  dealKey: string;
  fileNumber: string;
  cik: string;
  companyName: string;
  sic: string;
  isSPAC: boolean;
  jurisdiction: string;
  earliestFilingDate: string;
  latestFilingDate: string;
  filingYear: number;
  filingQuarter: string;
  sourceFolderKey: string;
  sourceAccessionNo: string;
  sourceFormType: string;
  sourceFilingDate: string;
  submissionCount: number;
  exhibitCount: number;
  distinctExhibitTypes: string[];
  ipoProceedsUSD?: number | null;
  overAllotmentProceedsUSD?: number | null;
  unitCount?: number | null;
  unitPriceUSD?: number | null;
  bookrunners: string[];
  issuerCounsel: string[];
  underwriterCounsel: string[];
  offshoreCounsel: string[];
  counselPartners: string[];
  warrantCoverage: string;
  trustPerUnitUSD?: number | null;
  isOverfundedTrust: boolean;
  trustee?: string | null;
  combinationWindowMonths?: number | null;
  exchange?: string | null;
  proposedTicker?: string | null;
  rawOfferingSnippet?: string | null;
  rawBookrunnerSnippet?: string | null;
  rawCopiesToSnippet?: string | null;
  rawUnitStructureSnippet?: string | null;
  secArchiveURL: string;
}

export interface LeagueTableEntry {
  name: string;
  dealCount: number;
  totalProceedsUSD: number;
  issuerRoleCount: number;
  underwriterRoleCount: number;
}

export interface QuarterlyTrendPoint {
  quarter: string;
  dealCount: number;
  spacDealCount: number;
  pricedDealCount: number;
  totalProceedsUSD: number;
  medianProceedsUSD: number;
  overfundedSharePct: number;
}

export interface AnnualStructurePoint {
  year: number;
  dealCount: number;
  buckets: Record<string, number>;
  overfundedCount: number;
  trustObservedCount: number;
  avgCombinationMonths?: number | null;
}

export interface TrendsExtractionStatus {
  isExtracting: boolean;
  phase: string;
  completedDeals: number;
  totalDeals: number;
  extractedAtISO8601?: string | null;
}

export interface TrendsDashboardResponse {
  bucket: string;
  extractedAtISO8601?: string | null;
  status: TrendsExtractionStatus;
  totalDeals: number;
  spacDeals: number;
  dealsWithProceeds: number;
  dealsWithBookrunners: number;
  dealsWithCounsel: number;
  aggregateProceedsUSD: number;
  totalPackagesInCorpus: number;
  totalExhibitsInCorpus: number;
  labeledExhibitsInCorpus: number;
  quarterlyTrends: QuarterlyTrendPoint[];
  annualStructures: AnnualStructurePoint[];
  bookrunnerLeague: LeagueTableEntry[];
  counselLeague: LeagueTableEntry[];
  deals: DealTrendRecord[];
}

export interface SubmissionRecord {
  folderKey: string;
  accessionNo: string;
  cik: string;
  companyName: string;
  tickers: string[];
  sic: string;
  sicDescription: string;
  stateOfIncorporation: string;
  stateOfIncorporationDescription: string;
  formType: string;
  fileNumber: string;
  filingDate: string;
  acceptanceDateTime: string;
  primaryDocument: string;
  exhibitCount: number;
  labeledExhibitCount: number;
  matchedInSECSubmissions: boolean;
}

export interface CatalogExhibit {
  folderKey: string;
  accessionNo: string;
  cik: string;
  companyName: string;
  fileNumber: string;
  formType: string;
  filingDate: string;
  filename: string;
  docName: string;
  docURL: string;
  objectPath: string;
  canonicalType?: string | null;
  matchedRuleID?: string | null;
}

export interface DealDetailProofResponse {
  deal: DealTrendRecord;
  submissions: SubmissionRecord[];
  exhibits: CatalogExhibit[];
}
