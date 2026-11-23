import Foundation

/// Deterministic, primary-source cover-page extractor for SEC Form S-1 and S-1/A registration statements.
/// Strips Inline XBRL (`<ix:header>`), CSS, and scripts linearly, then extracts deal economics, bookrunners,
/// issuer/underwriter/offshore counsel + named partners, unit/warrant coverage, trust overfunding, and
/// verbatim cover-page evidence snippets.
enum CoverPageExtractor {
    struct PartialCoverExtraction: Sendable {
        var facingSIC: String?
        var facingJurisdiction: String?
        var isSPAC: Bool = false
        var isExhibitOnlyAmendment: Bool = false
        var ipoProceedsUSD: Int64?
        var overAllotmentProceedsUSD: Int64?
        var unitCount: Int64?
        var unitPriceUSD: Double?
        var bookrunners: [String] = []
        var issuerCounsel: [String] = []
        var underwriterCounsel: [String] = []
        var offshoreCounsel: [String] = []
        var counselPartners: [String] = []
        var warrantCoverage: String = "Unspecified"
        var trustPerUnitUSD: Double?
        var trustee: String?
        var combinationWindowMonths: Int?
        var exchange: String?
        var proposedTicker: String?
        var rawOfferingSnippet: String?
        var rawBookrunnerSnippet: String?
        var rawCopiesToSnippet: String?
        var rawUnitStructureSnippet: String?
    }

    // MARK: - Canonical Investment Bank & Law Firm Dictionaries

    private static let canonicalBanks: [(name: String, pattern: String)] = [
        ("Goldman Sachs", #"goldman\s+sachs"#),
        ("J.P. Morgan", #"j\.?\s*p\.?\s*morgan"#),
        ("Morgan Stanley", #"morgan\s+stanley"#),
        ("Citigroup", #"\bcitigroup\b|\bciti\b"#),
        ("BofA Securities", #"bofa\s+securities|bank\s+of\s+america|merrill\s+lynch"#),
        ("Cantor Fitzgerald", #"cantor\s+fitzgerald|\bcantor\b"#),
        ("Barclays", #"\bbarclays\b"#),
        ("Credit Suisse", #"credit\s+suisse"#),
        ("Jefferies", #"\bjefferies\b"#),
        ("Deutsche Bank", #"deutsche\s+bank"#),
        ("UBS Investment Bank", #"\bubs\s+investment|\bubs\s+securities|\bubs\b"#),
        ("BTIG", #"\bbtig\b"#),
        ("Cohen & Company Capital Markets", #"cohen\s*&\s*company|j\.?\s*v\.?\s*b\.?\s*financial"#),
        ("D. Boral Capital", #"d\.?\s*boral\s+capital"#),
        ("EF Hutton", #"e\.?\s*f\.?\s*hutton"#),
        ("Clear Street", #"clear\s+street"#),
        ("Santander", #"\bsantander\b"#),
        ("Leerink Partners", #"leerink|svb\s+securities"#),
        ("Stifel", #"\bstifel\b"#),
        ("Piper Sandler", #"piper\s+sandler"#),
        ("Oppenheimer & Co.", #"\boppenheimer\b"#),
        ("RBC Capital Markets", #"rbc\s+capital|\brbc\b"#),
        ("Wells Fargo Securities", #"wells\s+fargo"#),
        ("TD Cowen", #"td\s+cowen|\bcowen\b"#),
        ("Mizuho", #"\bmizuho\b"#),
        ("Guggenheim Securities", #"\bguggenheim\b"#),
        ("William Blair", #"william\s+blair"#),
        ("Keefe, Bruyette & Woods", #"keefe,?\s+bruyette|\bkbw\b"#),
        ("Raymond James", #"raymond\s+james"#),
        ("Truist Securities", #"\btruist\b"#),
        ("BMO Capital Markets", #"bmo\s+capital"#),
        ("Macquarie Capital", #"\bmacquarie\b"#),
        ("Evercore ISI", #"\bevercore\b"#),
        ("Moelis & Company", #"\bmoelis\b"#),
        ("PJT Partners", #"pjt\s+partners"#),
        ("Lazard", #"\blazard\b"#),
        ("Maxim Group", #"maxim\s+group"#),
        ("EarlyBirdCapital", #"earlybird\s*capital|\bearlybird\b"#),
        ("Chardan", #"\bchardan\b"#),
        ("A.G.P. / Alliance Global Partners", #"a\.?\s*g\.?\s*p\.?|alliance\s+global\s+partners"#),
        ("Ladenburg Thalmann", #"ladenburg\s+thalmann"#),
        ("I-Bankers Securities", #"i[- ]bankers"#),
        ("Roth Capital Partners", #"roth\s+capital|\broth\s+mkm\b"#),
        ("Craig-Hallum", #"craig[- ]hallum"#),
        ("B. Riley Securities", #"b\.?\s*riley"#),
        ("Needham & Company", #"needham\s*&\s*company|\bneedham\b"#),
        ("Stephens", #"stephens\s+inc"#),
        ("D.A. Davidson", #"d\.?\s*a\.?\s*davidson"#),
        ("JonesTrading", #"jonestrading|jones\s+trading"#),
        ("ThinkEquity", #"thinkequity|think\s+equity"#),
        ("Kingswood Capital Partners", #"kingswood\s+capital|\bkingswood\b"#),
        ("The Benchmark Company", #"the\s+benchmark\s+company|\bbenchmark\s+company\b"#),
        ("Brookline Capital Markets", #"brookline\s+capital"#),
        ("Lake Street Capital Markets", #"lake\s+street"#),
        ("Northland Capital Markets", #"northland\s+capital|northland\s+securities"#),
        ("Seaport Global", #"seaport\s+global"#),
        ("Lucid Capital Markets", #"lucid\s+capital"#),
        ("Spartan Capital Securities", #"spartan\s+capital"#),
        ("Dominari Securities", #"dominari\s+securities|\bdominari\b"#),
        ("US Tiger Securities", #"u\.?\s*s\.?\s*tiger"#),
        ("Prime Number Capital", #"prime\s+number\s+capital"#),
        ("Revere Securities", #"revere\s+securities"#),
        ("Boustead Securities", #"boustead\s+securities|\bboustead\b"#),
        ("Network 1 Financial", #"network\s+1\s+financial"#),
        ("Craft Capital Management", #"craft\s+capital"#),
        ("Dawson James", #"dawson\s+james"#),
        ("WallachBeth Capital", #"wallachbeth"#),
        ("Joseph Gunnar", #"joseph\s+gunnar"#),
        ("Paulson Investment", #"paulson\s+investment"#),
        ("Aegis Capital", #"aegis\s+capital"#),
        ("Univest Securities", #"univest\s+securities"#),
        ("Eddid Securities", #"eddid\s+securities"#),
        ("R.F. Lafferty", #"r\.?\s*f\.?\s*lafferty"#),
        ("H.C. Wainwright", #"h\.?\s*c\.?\s*wainwright"#),
        ("Nomura", #"\bnomura\b"#),
        ("HSBC", #"\bhsbc\b"#),
        ("BNP Paribas", #"bnp\s+paribas"#),
        ("Societe Generale", #"soci[eé]t[eé]\s+g[eé]n[eé]rale"#),
        ("Scotiabank", #"\bscotiabank\b"#),
        ("CIBC Capital Markets", #"cibc\s+capital|\bcibc\b"#),
        ("Canaccord Genuity", #"canaccord\s+genuity|\bcanaccord\b"#),
        ("Berenberg", #"\bberenberg\b"#),
        ("Citizens JMP", #"citizens\s+jmp|jmp\s+securities"#),
        ("Wedbush Securities", #"wedbush"#),
        ("Baird", #"robert\s+w\.?\s*baird|\bbaird\b"#),
        ("KeyBanc Capital Markets", #"\bkeybanc\b"#),
        ("Loop Capital Markets", #"loop\s+capital"#),
        ("Academy Securities", #"academy\s+securities"#),
        ("Siebert Williams Shank", #"siebert\s+williams"#),
        ("Tigress Financial", #"tigress\s+financial"#),
        ("Imperial Capital", #"imperial\s+capital"#),
        ("LionTree", #"\bliontree\b"#),
        ("Raine Securities", #"raine\s+securities|the\s+raine\s+group"#),
        ("Bancroft Capital", #"bancroft\s+capital"#),
        ("AmeriVet Securities", #"\bamerivet\b"#),
        ("Roberts & Ryan", #"roberts\s*&\s*ryan"#),
        ("Ramirez & Co.", #"ramirez\s*&\s*co"#),
        ("BTG Pactual", #"btg\s+pactual"#),
        ("SPAC Advisory Partners", #"spac\s+advisory\s+partners"#),
        ("Odeon Capital", #"odeon\s+capital"#),
        ("Newbridge Securities", #"newbridge\s+securities"#),
        ("WestPark Capital", #"westpark\s+capital"#),
        ("Polaris Advisory", #"polaris\s+advisory"#)
    ]

    private static let canonicalUSLawFirms: [(name: String, pattern: String)] = [
        ("Ellenoff Grossman & Schole LLP", #"ellenoff\s+grossman"#),
        ("Davis Polk & Wardwell LLP", #"davis\s+polk"#),
        ("Skadden, Arps, Slate, Meagher & Flom LLP", #"skadden,?\s+arps"#),
        ("White & Case LLP", #"white\s*&\s*case"#),
        ("Weil, Gotshal & Manges LLP", #"weil,?\s+gotshal"#),
        ("Paul, Weiss, Rifkind, Wharton & Garrison LLP", #"paul,?\s+weiss"#),
        ("Latham & Watkins LLP", #"latham\s*&\s*watkins"#),
        ("Simpson Thacher & Bartlett LLP", #"simpson\s+thacher"#),
        ("Ropes & Gray LLP", #"ropes\s*&\s*gray"#),
        ("Sullivan & Cromwell LLP", #"sullivan\s*&\s*cromwell"#),
        ("Cravath, Swaine & Moore LLP", #"cravath,?\s+swaine"#),
        ("Cleary Gottlieb Steen & Hamilton LLP", #"cleary\s+gottlieb"#),
        ("Debevoise & Plimpton LLP", #"debevoise\s*&\s*plimpton"#),
        ("Milbank LLP", #"\bmilbank\b"#),
        ("Gibson, Dunn & Crutcher LLP", #"gibson,?\s+dunn"#),
        ("Sidley Austin LLP", #"sidley\s+austin"#),
        ("Goodwin Procter LLP", #"goodwin\s+procter|\bgoodwin\s+llp\b"#),
        ("Cooley LLP", #"\bcooley\s+llp\b"#),
        ("Wilson Sonsini Goodrich & Rosati", #"wilson\s+sonsini"#),
        ("Fried, Frank, Harris, Shriver & Jacobson LLP", #"fried,?\s+frank"#),
        ("Willkie Farr & Gallagher LLP", #"willkie\s+farr"#),
        ("Wachtell, Lipton, Rosen & Katz", #"wachtell,?\s+lipton"#),
        ("A&O Shearman", #"a\s*&\s*o\s+shearman|shearman\s*&\s*sterling|allen\s*&\s*overy"#),
        ("Freshfields", #"\bfreshfields\b"#),
        ("Linklaters LLP", #"\blinklaters\b"#),
        ("Clifford Chance", #"clifford\s+chance"#),
        ("Proskauer Rose LLP", #"proskauer\s+rose|\bproskauer\b"#),
        ("Kramer Levin Naftalis & Frankel LLP", #"kramer\s+levin"#),
        ("Cadwalader, Wickersham & Taft LLP", #"\bcadwalader\b"#),
        ("Akin Gump Strauss Hauer & Feld LLP", #"akin\s+gump"#),
        ("Vinson & Elkins LLP", #"vinson\s*&\s*elkins"#),
        ("King & Spalding LLP", #"king\s*&\s*spalding"#),
        ("Kirkland & Ellis LLP", #"kirkland\s*&\s*ellis"#),
        ("Mayer Brown LLP", #"mayer\s+brown"#),
        ("DLA Piper LLP", #"dla\s+piper"#),
        ("Greenberg Traurig, LLP", #"greenberg\s+traurig"#),
        ("Winston & Strawn LLP", #"winston\s*&\s*strawn"#),
        ("Reed Smith LLP", #"reed\s+smith"#),
        ("Morrison & Foerster LLP", #"morrison\s*(?:&|and)\s*foerster"#),
        ("Hogan Lovells", #"hogan\s+lovells"#),
        ("Morgan, Lewis & Bockius LLP", #"morgan,?\s+lewis"#),
        ("O'Melveny & Myers LLP", #"o['’]melveny"#),
        ("Orrick, Herrington & Sutcliffe LLP", #"orrick,?\s+herrington|\borrick\b"#),
        ("Paul Hastings LLP", #"paul\s+hastings"#),
        ("Dechert LLP", #"\bdechert\b"#),
        ("McDermott Will & Emery", #"mcdermott\s+will"#),
        ("Holland & Knight LLP", #"holland\s*&\s*knight"#),
        ("Norton Rose Fulbright", #"norton\s+rose\s+fulbright"#),
        ("Jones Day", #"\bjones\s+day\b"#),
        ("Baker Botts L.L.P.", #"baker\s+botts"#),
        ("Baker McKenzie", #"baker\s*&\s*mckenzie|baker\s+mckenzie"#),
        ("Katten Muchin Rosenman LLP", #"katten\s+muchin"#),
        ("Schulte Roth & Zabel LLP", #"schulte\s+roth"#),
        ("Lowenstein Sandler LLP", #"lowenstein\s+sandler"#),
        ("Fenwick & West LLP", #"fenwick\s*&\s*west"#),
        ("Gunderson Dettmer", #"gunderson\s+dettmer"#),
        ("Perkins Coie LLP", #"perkins\s+coie"#),
        ("Covington & Burling LLP", #"covington\s*&\s*burling"#),
        ("Arnold & Porter", #"arnold\s*&\s*porter"#),
        ("WilmerHale", #"wilmer\s+cutler|wilmerhale"#),
        ("Jenner & Block", #"jenner\s*&\s*block"#),
        ("Loeb & Loeb LLP", #"loeb\s*&\s*loeb"#),
        ("Graubard Miller", #"graubard\s+miller"#),
        ("Blank Rome LLP", #"blank\s+rome"#),
        ("Nelson Mullins Riley & Scarborough LLP", #"nelson\s+mullins"#),
        ("Mintz", #"mintz,?\s+levin"#),
        ("K&L Gates LLP", #"k\s*&\s*l\s+gates"#),
        ("Troutman Pepper Locke", #"troutman\s+pepper|troutman\s+sanders|pepper\s+hamilton|locke\s+lord"#),
        ("Haynes and Boone, LLP", #"haynes\s+(?:and|&)\s+boone"#),
        ("Foley & Lardner LLP", #"foley\s*&\s*lardner"#),
        ("Duane Morris LLP", #"duane\s+morris"#),
        ("Pryor Cashman LLP", #"pryor\s+cashman"#),
        ("Olshan Frome Wolosky LLP", #"olshan\s+frome"#),
        ("Robinson & Cole LLP", #"robinson\s*&\s*cole"#),
        ("Sichenzia Ross Ference Carmel LLP", #"sichenzia\s+ross"#),
        ("Hunter Taubman Fischer & Li LLC", #"hunter\s+taubman"#),
        ("Ortoli Rosenstadt LLP", #"ortoli\s+rosenstadt"#),
        ("Becker & Poliakoff", #"becker\s*&\s*poliakoff"#),
        ("Rimôn P.C.", #"rim[oô]n\s+p\.?c\.?"#),
        ("Sheppard Mullin", #"sheppard,?\s+mullin"#),
        ("Bracewell LLP", #"\bbracewell\b"#),
        ("Alston & Bird LLP", #"alston\s*&\s*bird"#),
        ("Eversheds Sutherland", #"eversheds\s+sutherland"#),
        ("Bryan Cave Leighton Paisner", #"bryan\s+cave"#),
        ("Dentons", #"\bdentons\b"#),
        ("Squire Patton Boggs", #"squire\s+patton"#),
        ("Dorsey & Whitney LLP", #"dorsey\s*&\s*whitney"#),
        ("Faegre Drinker", #"faegre\s+drinker"#),
        ("Ballard Spahr LLP", #"ballard\s+spahr"#),
        ("Fox Rothschild LLP", #"fox\s+rothschild"#),
        ("Manatt, Phelps & Phillips, LLP", #"manatt,?\s+phelps"#),
        ("Polsinelli", #"\bpolsinelli\b"#),
        ("Thompson Hine LLP", #"thompson\s+hine"#),
        ("Sullivan & Worcester LLP", #"sullivan\s*&\s*worcester"#),
        ("McCarter & English, LLP", #"mccarter\s*&\s*english"#),
        ("Harter Secrest & Emery LLP", #"harter\s+secrest"#),
        ("Lucosky Brookman LLP", #"lucosky\s+brookman"#),
        ("Bevilacqua PLLC", #"bevilacqua\s+pllc"#),
        ("Crone Law Group", #"crone\s+law\s+group"#),
        ("ArentFox Schiff LLP", #"arentfox|arent\s+fox|schiff\s+hardin"#),
        ("MagStone Law, LLP", #"magstone\s+law"#),
        ("Anthony L.G., PLLC", #"anthony\s+l\.?g\.?"#),
        ("Celine / Ross Law Group", #"ross\s+law\s+group"#),
        ("Kaufman & Canoles", #"kaufman\s*&\s*canoles"#)
    ]

    private static let canonicalOffshoreLawFirms: [(name: String, pattern: String)] = [
        ("Maples and Calder", #"maples\s+and\s+calder|maples\s+group"#),
        ("Ogier", #"\bogier\b"#),
        ("Walkers", #"\bwalkers\b"#),
        ("Carey Olsen", #"carey\s+olsen"#),
        ("Appleby", #"\bappleby\b"#),
        ("Conyers Dill & Pearman", #"conyers\s+dill|\bconyers\b"#),
        ("Harneys", #"\bharneys\b"#),
        ("Mourant Ozannes", #"\bmourant\b"#),
        ("Campbells", #"\bcampbells\b"#),
        ("Forbes Hare", #"forbes\s+hare"#),
        ("Travers Thorp Alberga", #"travers\s+thorp"#),
        ("Loeb Smith", #"loeb\s+smith"#)
    ]

    private static let compiledBanks: [(name: String, regex: NSRegularExpression)] = canonicalBanks.compactMap {
        guard let rx = try? NSRegularExpression(pattern: "(?i)" + $0.pattern) else { return nil }
        return ($0.name, rx)
    }

    private static let compiledUSLawFirms: [(name: String, regex: NSRegularExpression)] = canonicalUSLawFirms.compactMap {
        guard let rx = try? NSRegularExpression(pattern: "(?i)" + $0.pattern) else { return nil }
        return ($0.name, rx)
    }

    private static let compiledOffshoreLawFirms: [(name: String, regex: NSRegularExpression)] = canonicalOffshoreLawFirms.compactMap {
        guard let rx = try? NSRegularExpression(pattern: "(?i)" + $0.pattern) else { return nil }
        return ($0.name, rx)
    }

    private static let nonPersonTokens: Set<String> = [
        "copies", "to", "attention", "attn", "street", "avenue", "ave", "boulevard", "blvd",
        "road", "drive", "plaza", "square", "tower", "towers", "building", "center", "centre",
        "suite", "floor", "fl", "new", "york", "boston", "chicago", "houston", "dallas", "austin",
        "miami", "los", "angeles", "san", "francisco", "palo", "alto", "menlo", "park",
        "washington", "cayman", "grand", "islands", "island", "british", "virgin", "bermuda",
        "tel", "telephone", "fax", "facsimile", "phone", "direct", "counsel", "partner", "partners",
        "firm", "law", "offices", "office", "group", "llp", "llc", "pllc", "pc", "inc", "ltd",
        "limited", "corporation", "corp", "americas", "lexington", "madison", "broadway",
        "wall", "water", "state", "market", "capitol", "california", "texas", "florida",
        "delaware", "illinois", "massachusetts", "district", "columbia", "hong", "kong",
        "central", "east", "west", "north", "south", "one", "two", "three", "four", "five",
        "cricket", "pavilion", "camana", "bay", "nexus", "way", "box", "po", "ugland", "house"
    ]

    // MARK: - Primary Cover Extraction Entrypoint

    /// Fast byte-level entrypoint that excises multi-megabyte Inline XBRL `<ix:header>...</ix:header>` blocks
    /// and caps UTF-8 input to the front of the registration statement before decoding `String`.
    static func extract(fromHTMLData rawData: Data) -> PartialCoverExtraction {
        guard !rawData.isEmpty else { return PartialCoverExtraction() }
        let slicedData = sliceFrontHTMLBytes(rawData, maxBytesAfterIXHeader: 950_000)
        let html = String(decoding: slicedData, as: UTF8.self)
        return extract(fromHTML: html)
    }

    static func extract(fromHTML rawHTML: String) -> PartialCoverExtraction {
        let strippedHTML = sliceAndStripNonVisibleBlocks(rawHTML, maxVisibleHTMLChars: 240_000)
        let normalized = normalizeHTMLToText(strippedHTML, maxChars: 65_000)
        guard !normalized.isEmpty else { return PartialCoverExtraction() }

        var out = PartialCoverExtraction()

        // 1. Facing Page Slice (first ~12,000 chars)
        let facingEnd = normalized.index(
            normalized.startIndex,
            offsetBy: min(12_000, normalized.count)
        )
        let facingSlice = String(normalized[..<facingEnd])

        if let sicMatch = firstCapture(
            pattern: #"\b([0-9]{4})\b\s*\(\s*Primary\s+Standard\s+Industrial\s+Classification"#,
            in: facingSlice
        ) {
            out.facingSIC = sicMatch
        }

        if let jurisRaw = firstCapture(
            pattern: #"([A-Za-z][A-Za-z .,'()-]{2,36}?)\s*\(\s*State\s+or\s+[Oo]ther\s+[Jj]urisdiction"#,
            in: facingSlice
        ) {
            out.facingJurisdiction = cleanJurisdiction(jurisRaw)
        }

        // Extract "Copies to:" block
        if let copiesSnippet = firstCapture(
            pattern: #"(?i)copies\s+to\s*:?\s*(.{40,1100}?)(?:approximate\s+date\s+of\s+commencement|if\s+any\s+of\s+the\s+securities)"#,
            in: facingSlice
        ) {
            let cleanedCopies = collapseSpaces(copiesSnippet)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_-• \n\t"))
            out.rawCopiesToSnippet = truncateSnippet(cleanedCopies, limit: 420)

            let offshoreHits = matchFirmsWithLocations(compiledOffshoreLawFirms, in: cleanedCopies)
            out.offshoreCounsel = offshoreHits.map(\.name)

            let usHits = matchFirmsWithLocations(compiledUSLawFirms, in: cleanedCopies)
            let usNames = usHits.map(\.name)
            if usNames.count >= 2 {
                out.issuerCounsel = Array(usNames.dropLast())
                out.underwriterCounsel = [usNames[usNames.count - 1]]
            } else if usNames.count == 1 {
                out.issuerCounsel = usNames
            }

            let allFirmHits = (usHits + offshoreHits).sorted { $0.location < $1.location }
            out.counselPartners = extractPartnerNames(from: cleanedCopies, firmHits: allFirmHits)
        }

        // 2. Locate start of Prospectus Cover Page (after Facing Page)
        let prospectusCover = sliceProspectusCover(from: normalized)
        let lowerCover = prospectusCover.lowercased()

        // Detect Exhibit-Only S-1/A amendments
        let head1800 = String(lowerCover.prefix(1_800))
        if head1800.contains("explanatory note") &&
            (head1800.contains("solely for the purpose of filing") ||
             head1800.contains("solely to file certain exhibits") ||
             head1800.contains("part ii") && !head1800.contains("per unit")) {
            out.isExhibitOnlyAmendment = true
        }

        // Detect Blank Check / SPAC characteristics
        if out.facingSIC == "6770" ||
            lowerCover.contains("blank check company") ||
            lowerCover.contains("initial business combination") {
            out.isSPAC = true
        }

        guard !out.isExhibitOnlyAmendment else {
            return out
        }

        // 3. Offering Size, Unit Count & Unit Price
        extractOfferingEconomics(from: prospectusCover, into: &out)

        // 4. Unit / Warrant / Share-Right Coverage
        extractUnitStructure(from: prospectusCover, into: &out)

        // 5. Trust Account Funding per Unit & Trustee
        extractTrustTerms(from: prospectusCover, into: &out)

        // 6. Business Combination Window (Months)
        extractCombinationWindow(from: prospectusCover, into: &out)

        // 7. Exchange & Proposed Ticker
        extractExchangeAndTicker(from: prospectusCover, into: &out)

        // 8. Bookrunners / Underwriters + Verbatim Tombstone Snippet
        extractBookrunners(from: prospectusCover, into: &out)

        return out
    }

    // MARK: - Section Slicers & Normalizers

    private static let ixHeaderOpenBytes = Array("<ix:header".utf8)
    private static let ixHeaderCloseBytes = Array("</ix:header>".utf8)

    /// Excises `<ix:header>...</ix:header>` at the raw byte level and caps UTF-8 payload size so 20–40 MB
    /// Form S-1 financial statement tables are never decoded into heap `String`s.
    static func sliceFrontHTMLBytes(_ data: Data, maxBytesAfterIXHeader: Int) -> Data {
        let initialScanCap = min(data.count, 400_000)
        if let ixStart = findCaseInsensitiveASCII(ixHeaderOpenBytes, in: data, range: 0..<initialScanCap),
           let ixCloseEnd = findCaseInsensitiveASCII(ixHeaderCloseBytes, in: data, range: (ixStart + ixHeaderOpenBytes.count)..<data.count) {
            let prefixEnd = min(ixStart, 32_000)
            let bodyStart = ixCloseEnd + ixHeaderCloseBytes.count
            let bodyEnd = min(data.count, bodyStart + maxBytesAfterIXHeader)
            var combined = Data()
            combined.reserveCapacity((prefixEnd) + 1 + max(0, bodyEnd - bodyStart))
            combined.append(data.subdata(in: 0..<prefixEnd))
            combined.append(0x20)
            if bodyStart < bodyEnd {
                combined.append(data.subdata(in: bodyStart..<bodyEnd))
            }
            return combined
        }
        if data.count <= maxBytesAfterIXHeader {
            return data
        }
        return data.subdata(in: 0..<maxBytesAfterIXHeader)
    }

    static func findCaseInsensitiveASCII(_ needleLower: [UInt8], in data: Data, range: Range<Int>) -> Int? {
        let nLen = needleLower.count
        guard nLen > 0, range.count >= nLen else { return nil }
        return data.withUnsafeBytes { rawBuf -> Int? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let first = needleLower[0]
            let firstUpper = (first >= 97 && first <= 122) ? (first - 32) : first
            let limit = range.upperBound - nLen
            var i = range.lowerBound
            while i <= limit {
                let b0 = base[i]
                if b0 == first || b0 == firstUpper {
                    var matched = true
                    var j = 1
                    while j < nLen {
                        var bj = base[i + j]
                        if bj >= 65 && bj <= 90 { bj += 32 }
                        if bj != needleLower[j] {
                            matched = false
                            break
                        }
                        j += 1
                    }
                    if matched { return i }
                }
                i += 1
            }
            return nil
        }
    }

    /// Linearly strips `<ix:header>`, `<style>`, `<script>`, and HTML comments before slicing visible HTML,
    /// avoiding expensive regex scans over multi-megabyte financial statement tables at the back of Form S-1.
    static func sliceAndStripNonVisibleBlocks(_ html: String, maxVisibleHTMLChars: Int) -> String {
        var working = html
        // Fast jump past Inline XBRL `<ix:header>...</ix:header>` if present near top of document
        if let ixStart = working.range(of: "<ix:header", options: [.caseInsensitive]),
           let ixEnd = working.range(of: "</ix:header>", options: [.caseInsensitive], range: ixStart.upperBound..<working.endIndex) {
            let prefixBytes = String(decoding: working[..<ixStart.lowerBound].utf8.prefix(24_000), as: UTF8.self)
            let tailBytes = String(decoding: working[ixEnd.upperBound...].utf8.prefix(maxVisibleHTMLChars + 120_000), as: UTF8.self)
            working = prefixBytes + " " + tailBytes
        } else if working.utf8.count > maxVisibleHTMLChars + 160_000 {
            working = String(decoding: working.utf8.prefix(maxVisibleHTMLChars + 160_000), as: UTF8.self)
        }

        working = removePairedTagBlock(working, openTag: "<style", closeTag: "</style>")
        working = removePairedTagBlock(working, openTag: "<script", closeTag: "</script>")
        working = removePairedTagBlock(working, openTag: "<!--", closeTag: "-->")

        if working.utf8.count > maxVisibleHTMLChars + 80_000 {
            working = String(decoding: working.utf8.prefix(maxVisibleHTMLChars + 80_000), as: UTF8.self)
        }
        return working
    }

    private static func removePairedTagBlock(_ input: String, openTag: String, closeTag: String) -> String {
        guard input.range(of: openTag, options: .caseInsensitive) != nil else { return input }
        var result = ""
        result.reserveCapacity(input.count)
        var cursor = input.startIndex
        while cursor < input.endIndex {
            guard let start = input.range(of: openTag, options: .caseInsensitive, range: cursor..<input.endIndex) else {
                result.append(contentsOf: input[cursor..<input.endIndex])
                break
            }
            result.append(contentsOf: input[cursor..<start.lowerBound])
            result.append(" ")
            if let end = input.range(of: closeTag, options: .caseInsensitive, range: start.upperBound..<input.endIndex) {
                cursor = end.upperBound
            } else {
                break
            }
        }
        return result
    }

    static func normalizeHTMLToText(_ html: String, maxChars: Int) -> String {
        var out = ""
        out.reserveCapacity(min(html.count / 2, maxChars + 4_096))

        var insideTag = false
        var lastWasSpace = true

        for scalar in html.unicodeScalars {
            if scalar == "<" {
                insideTag = true
                if !lastWasSpace {
                    out.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if scalar == ">" {
                insideTag = false
                continue
            }
            if insideTag { continue }

            // Drop zero-width spaces & soft hyphens inserted by financial printers (e.g. Toppan Merrill)
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D ||
                scalar.value == 0xFEFF || scalar.value == 0x00AD {
                continue
            }

            if scalar.value == 0x00A0 || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    out.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }

            if out.utf8.count >= maxChars + 8_000 {
                break
            }
        }

        let decoded = decodeEntities(out)
        let collapsed = collapseSpaces(decoded)
        if collapsed.utf8.count > maxChars, collapsed.count > maxChars {
            let idx = collapsed.index(collapsed.startIndex, offsetBy: maxChars)
            return String(collapsed[..<idx])
        }
        return collapsed
    }

    private static let literalEntityReplacements: [(String, String)] = [
        ("&nbsp;", " "),
        ("&#160;", " "),
        ("&amp;", "&"),
        ("&#38;", "&"),
        ("&quot;", "\""),
        ("&ldquo;", "“"),
        ("&rdquo;", "”"),
        ("&#8220;", "“"),
        ("&#8221;", "”"),
        ("&rsquo;", "’"),
        ("&lsquo;", "‘"),
        ("&#8217;", "’"),
        ("&#8216;", "‘"),
        ("&#39;", "'"),
        ("&apos;", "'"),
        ("&ndash;", "–"),
        ("&mdash;", "—"),
        ("&#8211;", "–"),
        ("&#8212;", "—"),
        ("&#36;", "$"),
        ("&#9679;", "●"),
        ("&bull;", "•")
    ]

    private static let caseInsensitiveEntityReplacements: [(String, String)] = [
        ("&#xa0;", " "),
        ("&#x201c;", "“"),
        ("&#x201d;", "”"),
        ("&#x2019;", "’"),
        ("&#x2013;", "–"),
        ("&#x2014;", "—")
    ]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        for (entity, replacement) in literalEntityReplacements {
            if s.contains(entity) {
                s = s.replacingOccurrences(of: entity, with: replacement)
            }
        }
        for (entity, replacement) in caseInsensitiveEntityReplacements {
            if s.range(of: entity, options: .caseInsensitive) != nil {
                s = s.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
            }
        }

        if let numericRegex = try? NSRegularExpression(pattern: #"&#([0-9]{2,5});"#) {
            let matches = numericRegex.matches(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)).reversed()
            for m in matches {
                if let codeRange = Range(m.range(at: 1), in: s),
                   let fullRange = Range(m.range, in: s),
                   let code = UInt32(s[codeRange]),
                   let scalar = UnicodeScalar(code) {
                    if scalar.value == 0x200B || scalar.value == 0xFEFF {
                        s.replaceSubrange(fullRange, with: "")
                    } else {
                        s.replaceSubrange(fullRange, with: String(Character(scalar)))
                    }
                }
            }
        }
        return s
    }

    private static func sliceProspectusCover(from normalized: String) -> String {
        var startIdx = normalized.startIndex
        let searchWindowEnd = normalized.index(normalized.startIndex, offsetBy: min(14_000, normalized.count))
        let searchWindow = normalized[..<searchWindowEnd]

        // Prefer starting right after the Facing Page "Approximate date of commencement" + Rule 415/EGC checkboxes
        if let approx = searchWindow.range(of: "Approximate date of commencement", options: .caseInsensitive) {
            startIdx = approx.upperBound
            let postApproxEnd = normalized.index(startIdx, offsetBy: min(5_500, normalized.distance(from: startIdx, to: normalized.endIndex)))
            let postApprox = normalized[startIdx..<postApproxEnd]
            if let delayAnchor = postApprox.range(of: "until the registrant shall file a further amendment", options: .caseInsensitive) {
                startIdx = delayAnchor.upperBound
            } else if let effectiveAnchor = postApprox.range(of: "acting pursuant to said Section 8(a)", options: .caseInsensitive) {
                startIdx = effectiveAnchor.upperBound
            }
        }

        let maxCoverLen = min(38_000, normalized.distance(from: startIdx, to: normalized.endIndex))
        let rawEnd = normalized.index(startIdx, offsetBy: maxCoverLen)
        var cover = String(normalized[startIdx..<rawEnd])

        // Trim at real Table of Contents table (after at least 1,500 chars so top-of-page "Table of Contents" nav link is ignored)
        if cover.count > 2_000 {
            let afterCoverIntro = cover.index(cover.startIndex, offsetBy: 1_800)
            if let tocRegex = try? NSRegularExpression(
                pattern: #"(?i)table\s+of\s+contents.{0,140}?\bsummary\b\s+[0-9]{1,2}\b"#
            ) {
                let nsRange = NSRange(afterCoverIntro..<cover.endIndex, in: cover)
                if let m = tocRegex.firstMatch(in: cover, range: nsRange),
                   let r = Range(m.range, in: cover) {
                    cover = String(cover[..<r.lowerBound])
                }
            }
        }
        return cover
    }

    // MARK: - Field Extractors

    private static func extractOfferingEconomics(from cover: String, into out: inout PartialCoverExtraction) {
        let topWindow = String(cover.prefix(8_000))

        // 1. Unit Count (e.g. "40,000,000 Units" or "7,500,000 Units")
        if let unitRegex = try? NSRegularExpression(pattern: #"(?i)\b([0-9]{1,3}(?:,[0-9]{3}){2})\s+units\b"#) {
            let matches = unitRegex.matches(in: topWindow, range: NSRange(topWindow.startIndex..<topWindow.endIndex, in: topWindow))
            for m in matches {
                guard let fullR = Range(m.range, in: topWindow),
                      let numR = Range(m.range(at: 1), in: topWindow) else { continue }
                let prefixStart = topWindow.index(fullR.lowerBound, offsetBy: -min(45, topWindow.distance(from: topWindow.startIndex, to: fullR.lowerBound)))
                let preceding = topWindow[prefixStart..<fullR.lowerBound].lowercased()
                if preceding.contains("additional") || preceding.contains("up to ") ||
                    preceding.contains("over-allotment") || preceding.contains("private placement") {
                    continue
                }
                if let parsed = Int64(topWindow[numR].replacingOccurrences(of: ",", with: "")),
                   parsed >= 1_000_000 && parsed <= 500_000_000 {
                    out.unitCount = parsed
                    break
                }
            }
        }

        // 2. Collect large dollar amounts ($5,000,000+) across cover
        var dollarAmounts: [Int64] = []
        if let dollarRegex = try? NSRegularExpression(
            pattern: #"\$\s*([1-9],[0-9]{3}(?:,[0-9]{3}){2}|[0-9]{1,3}(?:,[0-9]{3}){2})\b"#
        ) {
            let matches = dollarRegex.matches(in: cover, range: NSRange(cover.startIndex..<cover.endIndex, in: cover))
            for m in matches {
                if let r = Range(m.range(at: 1), in: cover),
                   let val = Int64(cover[r].replacingOccurrences(of: ",", with: "")),
                   val >= 5_000_000 && val <= 10_000_000_000 {
                    dollarAmounts.append(val)
                }
            }
        }

        // Also check "$XXX million" in the top 3,000 chars
        let topHeadline = String(cover.prefix(3_000))
        if let milRegex = try? NSRegularExpression(pattern: #"(?i)\$\s*([0-9]{2,4}(?:\.[0-9]+)?)\s+million\b"#) {
            let matches = milRegex.matches(in: topHeadline, range: NSRange(topHeadline.startIndex..<topHeadline.endIndex, in: topHeadline))
            for m in matches {
                if let r = Range(m.range(at: 1), in: topHeadline),
                   let val = Double(topHeadline[r]) {
                    let usd = Int64((val * 1_000_000).rounded())
                    if usd >= 10_000_000 {
                        dollarAmounts.append(usd)
                    }
                }
            }
        }

        // 3. Unit Offering Price (prefer explicit "offering price of $10.00" or exact `units * $10 == headline $` before "$XX.XX per unit", avoiding trust "$10.05 per unit")
        if let units = out.unitCount, dollarAmounts.contains(units * 10) {
            out.unitPriceUSD = 10.0
        } else if let explicitOfferPrice = firstCapture(
            pattern: #"(?i)(?:offering\s+price\s+(?:of|is)|public\s+offering\s+price\s*(?:of|:)?)\s*\$\s*([0-9]{1,2}\.[0-9]{2})"#,
            in: topWindow
        ), let price = Double(explicitOfferPrice) {
            out.unitPriceUSD = price
        } else if out.unitCount != nil && topWindow.contains("$10.00") {
            out.unitPriceUSD = 10.0
        } else if let priceStr = firstCapture(pattern: #"(?i)\$\s*(10\.00|[0-9]{1,2}\.[0-9]{2})\s+per\s+unit"#, in: topWindow),
                  let price = Double(priceStr) {
            out.unitPriceUSD = price
        }

        if let units = out.unitCount, let price = out.unitPriceUSD {
            let computed = Int64((Double(units) * price).rounded())
            if computed >= 5_000_000 {
                out.ipoProceedsUSD = computed
                if let oa = dollarAmounts.first(where: {
                    Double($0) >= Double(computed) * 1.10 && Double($0) <= Double(computed) * 1.20
                }) {
                    out.overAllotmentProceedsUSD = oa
                }
            }
        } else if let firstHeadline = dollarAmounts.first {
            out.ipoProceedsUSD = firstHeadline
            if let oa = dollarAmounts.dropFirst().first(where: {
                Double($0) >= Double(firstHeadline) * 1.10 && Double($0) <= Double(firstHeadline) * 1.20
            }) {
                out.overAllotmentProceedsUSD = oa
            }
        }

        // Fast linear window around "initial public offering" or top of cover page
        if let ipoRange = cover.range(of: "initial public offering", options: .caseInsensitive) {
            let sStart = cover.index(ipoRange.lowerBound, offsetBy: -min(80, cover.distance(from: cover.startIndex, to: ipoRange.lowerBound)))
            let sEnd = cover.index(ipoRange.upperBound, offsetBy: min(240, cover.distance(from: ipoRange.upperBound, to: cover.endIndex)))
            out.rawOfferingSnippet = truncateSnippet(String(cover[sStart..<sEnd]), limit: 320)
        } else if out.ipoProceedsUSD != nil {
            out.rawOfferingSnippet = truncateSnippet(String(cover.prefix(320)), limit: 320)
        }
    }

    private static func findUnitCompositionSentence(in cover: String) -> String? {
        let endSentenceRx = try? NSRegularExpression(pattern: #"(?<![0-9])\.\s+(?=[A-Z“"$])"#)
        var cursor = cover.startIndex
        while cursor < cover.endIndex,
              let unitRange = cover.range(of: "each unit", options: .caseInsensitive, range: cursor..<cover.endIndex) {
            let lookEnd = cover.index(unitRange.lowerBound, offsetBy: min(460, cover.distance(from: unitRange.lowerBound, to: cover.endIndex)))
            let rawWindow = String(cover[unitRange.lowerBound..<lookEnd])
            let sentence: String
            if let rx = endSentenceRx,
               let m = rx.firstMatch(in: rawWindow, range: NSRange(rawWindow.startIndex..<rawWindow.endIndex, in: rawWindow)),
               let r = Range(m.range, in: rawWindow) {
                sentence = String(rawWindow[...r.lowerBound])
            } else {
                sentence = rawWindow
            }
            let lowSent = sentence.lowercased()
            if lowSent.contains("consists of") || lowSent.contains("entitles the holder") || lowSent.contains("comprises") || lowSent.contains("consisting of") {
                return sentence
            }
            cursor = unitRange.upperBound
        }
        return nil
    }

    private static func extractUnitStructure(from cover: String, into out: inout PartialCoverExtraction) {
        if let unitSent = findUnitCompositionSentence(in: cover) {
            let clean = collapseSpaces(unitSent)
            out.rawUnitStructureSnippet = truncateSnippet(clean, limit: 340)
            let low = clean.lowercased()
            let hasRight = low.contains("one right") || low.contains("share right") || low.contains("right to receive") || low.contains("one-tenth") && low.contains("right")
            let hasWarrant = low.contains("warrant") && !low.contains("no warrant") && !low.contains("without warrant")

            if hasRight && hasWarrant {
                out.warrantCoverage = "Share Right + Warrant"
            } else if hasRight && !hasWarrant {
                out.warrantCoverage = "Share Right Only"
            } else if low.contains("one-half") || low.contains("1/2") {
                out.warrantCoverage = "1/2 Warrant"
            } else if low.contains("one-third") || low.contains("1/3") {
                out.warrantCoverage = "1/3 Warrant"
            } else if low.contains("one-fourth") || low.contains("one-quarter") || low.contains("1/4") {
                out.warrantCoverage = "1/4 Warrant"
            } else if low.contains("three-fourths") || low.contains("three-quarters") || low.contains("3/4") {
                out.warrantCoverage = "3/4 Warrant"
            } else if low.contains("one-fifth") || low.contains("1/5") ||
                        low.contains("one-sixth") || low.contains("1/6") ||
                        low.contains("one-seventh") || low.contains("1/7") ||
                        low.contains("one-eighth") || low.contains("1/8") ||
                        low.contains("one-ninth") || low.contains("1/9") ||
                        low.contains("one-tenth") || low.contains("1/10") {
                out.warrantCoverage = "1/5 or Less Warrant"
            } else if hasWarrant && (low.contains("one redeemable warrant") || low.contains("one warrant") || low.contains("and a warrant") || low.contains("one whole")) {
                out.warrantCoverage = "1 Whole Warrant"
            } else if !hasWarrant && !hasRight {
                out.warrantCoverage = "Share Only (No Warrant)"
            } else {
                out.warrantCoverage = "Other Warrant Unit"
            }
        } else {
            let low = cover.lowercased()
            if out.isSPAC && (low.contains("no warrants are being offered") ||
                              (out.unitCount == nil && low.contains("class a ordinary shares") && !low.contains("each unit consists"))) {
                out.warrantCoverage = "Share Only (No Warrant)"
            } else if !out.isSPAC {
                out.warrantCoverage = "Common Stock / Direct IPO"
            }
        }
    }

    private static func extractTrustTerms(from cover: String, into out: inout PartialCoverExtraction) {
        // Linearly locate "trust account" occurrences (immune to periods inside "U.S.-based trust account")
        var searchCursor = cover.startIndex
        while searchCursor < cover.endIndex,
              let tr = cover.range(of: "trust account", options: .caseInsensitive, range: searchCursor..<cover.endIndex) {
            let winStart = cover.index(tr.lowerBound, offsetBy: -min(260, cover.distance(from: cover.startIndex, to: tr.lowerBound)))
            let winEnd = cover.index(tr.upperBound, offsetBy: min(260, cover.distance(from: tr.upperBound, to: cover.endIndex)))
            let window = String(cover[winStart..<winEnd])
            if let amtStr = firstCapture(
                pattern: #"(?i)\$\s*(10\.[0-9]{2})\s+per\s+(?:unit|public\s+share|share)"#,
                in: window
            ), let val = Double(amtStr) {
                out.trustPerUnitUSD = val
                break
            }
            searchCursor = tr.upperBound
        }

        let low = cover.lowercased()
        if low.contains("continental stock transfer") {
            out.trustee = "Continental Stock Transfer & Trust"
        } else if low.contains("odyssey transfer") {
            out.trustee = "Odyssey Transfer and Trust"
        } else if low.contains("wilmington trust") {
            out.trustee = "Wilmington Trust"
        } else if low.contains("equiniti") {
            out.trustee = "Equiniti Trust"
        } else if low.contains("american stock transfer") {
            out.trustee = "American Stock Transfer & Trust"
        }
    }

    private static func extractCombinationWindow(from cover: String, into out: inout PartialCoverExtraction) {
        if let numStr = firstCapture(
            pattern: #"(?i)\bwithin\s+(?:[a-z-]+\s*\(\s*)?([0-9]{1,2})\s*\)?\s+months\s+from\s+the\s+closing"#,
            in: cover
        ), let months = Int(numStr), months >= 6 && months <= 36 {
            out.combinationWindowMonths = months
            return
        }
        let wordMap: [(String, Int)] = [
            ("twenty-four", 24), ("twenty-one", 21), ("eighteen", 18),
            ("fifteen", 15), ("twelve", 12), ("nine", 9)
        ]
        let low = cover.lowercased()
        for (word, months) in wordMap {
            if low.range(of: #"within\s+\#(word)\s+months\s+from\s+the\s+closing"#, options: .regularExpression) != nil {
                out.combinationWindowMonths = months
                return
            }
        }
    }

    private static func extractExchangeAndTicker(from cover: String, into out: inout PartialCoverExtraction) {
        let low = cover.lowercased()
        if low.contains("nyse american") {
            out.exchange = "NYSE American"
        } else if low.contains("nasdaq") {
            out.exchange = "Nasdaq"
        } else if low.contains("new york stock exchange") || low.range(of: #"\bnyse\b"#, options: .regularExpression) != nil {
            out.exchange = "NYSE"
        }

        if let ticker = firstCapture(
            pattern: #"under\s+the\s+symbols?\s+[“"]([A-Z]{3,6}(?:[.-][A-Z]{1,2})?)[”"]"#,
            in: cover
        ) {
            out.proposedTicker = ticker
        }
    }

    private static func extractBookrunners(from cover: String, into out: inout PartialCoverExtraction) {
        var evidenceWindows: [String] = []

        // 1. Tombstone window around "expects to deliver" or "Book-Running Manager(s)" / "Lead Manager"
        if let tomb = firstCapture(
            pattern: #"(?i)((?:the\s+underwriters?\s+expects?\s+to\s+deliver|expects?\s+to\s+deliver\s+the\s+(?:units|shares|securities)|sole\s+book[- ]running\s+manager|joint\s+book[- ]running\s+managers?|lead\s+book[- ]running\s+manager).{5,420})"#,
            in: cover
        ) {
            let trimmed = trimAtTableOfContents(tomb)
            evidenceWindows.append(trimmed)
        }

        // 2. Fast linear lookup for "representative of the underwriters" clauses (avoids O(N^2) unanchored prefix scanning)
        var repCursor = cover.startIndex
        var repHits = 0
        while repCursor < cover.endIndex && repHits < 2,
              let repRange = cover.range(of: "representative of the underwriters", options: .caseInsensitive, range: repCursor..<cover.endIndex) {
            let sStart = cover.index(repRange.lowerBound, offsetBy: -min(160, cover.distance(from: cover.startIndex, to: repRange.lowerBound)))
            let sEnd = cover.index(repRange.upperBound, offsetBy: min(90, cover.distance(from: repRange.upperBound, to: cover.endIndex)))
            evidenceWindows.append(String(cover[sStart..<sEnd]))
            repHits += 1
            repCursor = repRange.upperBound
        }

        let combinedPrimary = evidenceWindows.joined(separator: " | ")
        var matchedBanks = matchFirmsWithLocations(compiledBanks, in: combinedPrimary).map(\.name)

        // 3. Fallback: scan bottom 9,000 chars of cover page if primary windows had no hit
        if matchedBanks.isEmpty {
            let tailStart = cover.index(cover.endIndex, offsetBy: -min(9_000, cover.count))
            let tailSlice = String(cover[tailStart..<cover.endIndex])
            let tailHits = matchFirmsWithLocations(compiledBanks, in: tailSlice)
            matchedBanks = tailHits.map(\.name)
            if !matchedBanks.isEmpty, let firstHit = tailHits.first,
               let hitIdx = Range(NSRange(location: firstHit.location, length: 0), in: tailSlice)?.lowerBound {
                let snippetStart = tailSlice.index(
                    hitIdx,
                    offsetBy: -min(90, tailSlice.distance(from: tailSlice.startIndex, to: hitIdx))
                )
                let snippetEnd = tailSlice.index(
                    snippetStart,
                    offsetBy: min(260, tailSlice.distance(from: snippetStart, to: tailSlice.endIndex))
                )
                evidenceWindows.append(String(tailSlice[snippetStart..<snippetEnd]))
            }
        }

        // 4. Boutique fallback: extract explicit capitalized name right before ", the representative of the underwriters"
        if matchedBanks.isEmpty && !combinedPrimary.isEmpty,
           let boutique = firstCapture(
               pattern: #"(?:granted|unless|issue\s+to)\s+([A-Z][A-Za-z0-9&.,'’ -]{2,55}?)\s*(?:\([^)]{1,35}\)\s*)?,\s*(?:the\s+)?representative\s+of\s+the\s+underwriters"#,
               in: combinedPrimary
           ) {
            let cleaned = collapseSpaces(boutique).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
            if !cleaned.isEmpty {
                matchedBanks = [cleaned]
            }
        }

        out.bookrunners = matchedBanks
        if let bestSnippet = evidenceWindows.first, !bestSnippet.isEmpty {
            out.rawBookrunnerSnippet = truncateSnippet(collapseSpaces(bestSnippet), limit: 320)
        }
    }

    // MARK: - Regex & Name Helpers

    private static func matchFirmsWithLocations(
        _ catalog: [(name: String, regex: NSRegularExpression)],
        in text: String
    ) -> [(name: String, location: Int)] {
        guard !text.isEmpty else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var hits: [(name: String, location: Int)] = []
        var seen = Set<String>()

        for entry in catalog {
            if let m = entry.regex.firstMatch(in: text, range: nsRange), seen.insert(entry.name).inserted {
                hits.append((name: entry.name, location: m.range.location))
            }
        }
        return hits.sorted { $0.location < $1.location }
    }

    private static func extractPartnerNames(
        from copiesText: String,
        firmHits: [(name: String, location: Int)]
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func addCandidate(_ raw: String) {
            let cleaned = raw
                .replacingOccurrences(of: #"(?i),?\s*(?:Esq\.?|P\.?C\.?)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-_•()[]\n\t"))
            let words = cleaned.split(separator: " ").map(String.init)
            guard words.count >= 2 && words.count <= 4 else { return }
            for w in words {
                let alpha = w.trimmingCharacters(in: CharacterSet(charactersIn: ".'’-"))
                guard let first = alpha.first, first.isUppercase else { return }
                if alpha.contains(where: \.isNumber) { return }
                if nonPersonTokens.contains(alpha.lowercased()) { return }
            }
            let key = cleaned.lowercased()
            if seen.insert(key).inserted {
                ordered.append(cleaned)
            }
        }

        // 1. Explicit ", Esq." or ", P.C." honorific matches
        if let honRegex = try? NSRegularExpression(
            pattern: #"([A-Z][A-Za-z.'’-]+(?:\s+[A-Z][A-Za-z.'’-]*){1,3})\s*,\s*(?:Esq\.?|P\.?C\.?)"#
        ) {
            let matches = honRegex.matches(in: copiesText, range: NSRange(copiesText.startIndex..<copiesText.endIndex, in: copiesText))
            for m in matches {
                if let r = Range(m.range(at: 1), in: copiesText) {
                    addCandidate(String(copiesText[r]))
                }
            }
        }

        // 2. Window immediately preceding each matched law firm (catches partners listed without "Esq." honorifics)
        for hit in firmHits {
            guard let hitIdx = Range(NSRange(location: hit.location, length: 0), in: copiesText)?.lowerBound else {
                continue
            }
            let distFromStart = copiesText.distance(from: copiesText.startIndex, to: hitIdx)
            guard distFromStart > 3 else { continue }
            let winStartIdx = copiesText.index(hitIdx, offsetBy: -min(125, distFromStart))
            var window = String(copiesText[winStartIdx..<hitIdx])

            // Cut after the last phone number or 5-digit postal code from the previous address block
            if let phoneCut = try? NSRegularExpression(pattern: #"(?:\([0-9]{3}\)\s*[0-9]{3}\s*[-–]\s*[0-9]{4}|[0-9]{3}-[0-9]{3}-[0-9]{4}|\b[0-9]{5}(?:-[0-9]{4})?\b)"#) {
                let matches = phoneCut.matches(in: window, range: NSRange(window.startIndex..<window.endIndex, in: window))
                if let last = matches.last, let r = Range(last.range, in: window) {
                    window = String(window[r.upperBound...])
                }
            }

            // Strip ", P.C." / ", Esq." delimiters into commas so adjacent partner names split cleanly
            let segmented = window
                .replacingOccurrences(of: #"(?i),?\s*(?:Esq\.?|P\.?C\.?)\b"#, with: " | ", options: .regularExpression)
                .replacingOccurrences(of: ",", with: " | ")

            for part in segmented.split(separator: "|") {
                let tokens = part.split(separator: " ").map(String.init)
                if tokens.count >= 2 && tokens.count <= 4 {
                    addCandidate(tokens.joined(separator: " "))
                } else if tokens.count >= 4 && tokens.count <= 6 {
                    // Two 2-word names back-to-back without comma (e.g. "Jane Doe John Smith")
                    if tokens.count == 4 {
                        addCandidate(tokens[0...1].joined(separator: " "))
                        addCandidate(tokens[2...3].joined(separator: " "))
                    } else if tokens.count == 5 {
                        // Middle initial on first partner vs. second partner
                        if tokens[1].hasSuffix(".") {
                            addCandidate(tokens[0...2].joined(separator: " "))
                            addCandidate(tokens[3...4].joined(separator: " "))
                        } else {
                            addCandidate(tokens[0...1].joined(separator: " "))
                            addCandidate(tokens[2...4].joined(separator: " "))
                        }
                    }
                }
            }
        }

        return ordered
    }

    private static func cleanJurisdiction(_ raw: String) -> String {
        let low = collapseSpaces(raw).lowercased()
        if low.contains("cayman") { return "Cayman Islands" }
        if low.contains("delaware") { return "Delaware" }
        if low.contains("british virgin") || low == "bvi" { return "British Virgin Islands" }
        if low.contains("nevada") { return "Nevada" }
        if low.contains("bermuda") { return "Bermuda" }
        if low.contains("marshall") { return "Marshall Islands" }
        if low.contains("maryland") { return "Maryland" }
        if low.contains("new york") { return "New York" }
        if low.contains("texas") { return "Texas" }
        if low.contains("florida") { return "Florida" }
        if low.contains("california") { return "California" }
        return collapseSpaces(raw).trimmingCharacters(in: CharacterSet(charactersIn: " _-.,"))
    }

    private static func trimAtTableOfContents(_ s: String) -> String {
        if let r = s.range(of: "Table of Contents", options: .caseInsensitive) {
            return String(s[..<r.lowerBound])
        }
        return s
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = rx.firstMatch(in: text, range: nsRange),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }

    private static func collapseSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncateSnippet(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        let idx = s.index(s.startIndex, offsetBy: limit)
        return String(s[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

// MARK: - Corpus-Wide Market Trends Coordinator & Aggregator

actor TrendsAnalyzer {
    private let store: any ObjectStore
    private let filingsPrefix: String
    private let catalog: CorpusCatalog
    private let logger: ActivityLogger

    private let dealsJSONPath = "corpus/deal_trends.json"
    private let dealsJSONLPath = "corpus/deal_trends.jsonl"
    private let dashboardCachePath = "corpus/trends_dashboard.json"

    private var didLoadFromStore = false
    private var cachedDashboard: TrendsDashboardResponse?
    private var cachedDealsByKey: [String: DealTrendRecord] = [:]

    private var isExtracting = false
    private var phase = "Idle"
    private var completedDeals = 0
    private var totalDeals = 0
    private var extractedAtISO8601: String?

    init(
        store: any ObjectStore,
        filingsPrefix: String,
        catalog: CorpusCatalog,
        logger: ActivityLogger
    ) {
        self.store = store
        self.filingsPrefix = filingsPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.catalog = catalog
        self.logger = logger
    }

    func status() async -> TrendsExtractionStatus {
        await ensureLoaded()
        return TrendsExtractionStatus(
            isExtracting: isExtracting,
            phase: phase,
            completedDeals: completedDeals,
            totalDeals: totalDeals,
            extractedAtISO8601: extractedAtISO8601
        )
    }

    func dashboard() async -> TrendsDashboardResponse {
        await ensureLoaded()
        let currentStatus = TrendsExtractionStatus(
            isExtracting: isExtracting,
            phase: phase,
            completedDeals: completedDeals,
            totalDeals: totalDeals,
            extractedAtISO8601: extractedAtISO8601
        )
        if let cached = cachedDashboard {
            return TrendsDashboardResponse(
                bucket: cached.bucket,
                extractedAtISO8601: extractedAtISO8601 ?? cached.extractedAtISO8601,
                status: currentStatus,
                totalDeals: cached.totalDeals,
                spacDeals: cached.spacDeals,
                dealsWithProceeds: cached.dealsWithProceeds,
                dealsWithBookrunners: cached.dealsWithBookrunners,
                dealsWithCounsel: cached.dealsWithCounsel,
                aggregateProceedsUSD: cached.aggregateProceedsUSD,
                totalPackagesInCorpus: cached.totalPackagesInCorpus,
                totalExhibitsInCorpus: cached.totalExhibitsInCorpus,
                labeledExhibitsInCorpus: cached.labeledExhibitsInCorpus,
                quarterlyTrends: cached.quarterlyTrends,
                annualStructures: cached.annualStructures,
                bookrunnerLeague: cached.bookrunnerLeague,
                counselLeague: cached.counselLeague,
                deals: cached.deals
            )
        }
        return TrendsDashboardResponse(
            bucket: store.bucket,
            extractedAtISO8601: nil,
            status: currentStatus,
            totalDeals: 0,
            spacDeals: 0,
            dealsWithProceeds: 0,
            dealsWithBookrunners: 0,
            dealsWithCounsel: 0,
            aggregateProceedsUSD: 0,
            totalPackagesInCorpus: 0,
            totalExhibitsInCorpus: 0,
            labeledExhibitsInCorpus: 0,
            quarterlyTrends: [],
            annualStructures: [],
            bookrunnerLeague: [],
            counselLeague: [],
            deals: []
        )
    }

    func dealProof(for dealKey: String) async -> DealDetailProofResponse? {
        await ensureLoaded()
        guard let deal = cachedDealsByKey[dealKey] else { return nil }
        let snapshot = await catalog.allDealGroupsSnapshot()
        guard let group = snapshot.deals.first(where: { $0.dealKey == dealKey }) else {
            return DealDetailProofResponse(deal: deal, submissions: [], exhibits: [])
        }
        let folderKeys = Set(group.submissions.map(\.folderKey))
        let exhibits = await catalog.exhibitsForDeal(folderKeys: folderKeys)
        return DealDetailProofResponse(
            deal: deal,
            submissions: group.submissions,
            exhibits: exhibits
        )
    }

    func startExtractionIfNeeded() async -> TrendsExtractionStatus {
        await ensureLoaded()
        guard !isExtracting else {
            return await status()
        }
        isExtracting = true
        phase = "Loading 333- registration deal chains from catalog…"
        completedDeals = 0
        totalDeals = 0

        Task {
            await self.performExtraction()
        }
        return TrendsExtractionStatus(
            isExtracting: true,
            phase: phase,
            completedDeals: 0,
            totalDeals: 0,
            extractedAtISO8601: extractedAtISO8601
        )
    }

    func performExtraction() async {
        await ensureLoaded()
        isExtracting = true
        let clock = ContinuousClock()
        let startedAt = clock.now
        defer {
            isExtracting = false
            phase = "Idle"
        }

        do {
            let snapshot = await catalog.allDealGroupsSnapshot()
            let dealGroups = snapshot.deals
            totalDeals = dealGroups.count
            completedDeals = 0
            phase = "Extracting cover-page terms across \(dealGroups.count) registration deal chains…"

            let storeRef = self.store
            let rootPrefix = self.filingsPrefix

            let extractedDeals = try await ConcurrentJobs.run(dealGroups, limit: 64) { [weak self] group -> DealTrendRecord in
                let record = await Self.extractDealChain(
                    group: group,
                    store: storeRef,
                    filingsPrefix: rootPrefix
                )
                await self?.incrementProgress()
                return record
            }

            let sortedDeals = extractedDeals.sorted {
                if $0.latestFilingDate != $1.latestFilingDate {
                    return $0.latestFilingDate > $1.latestFilingDate
                }
                return $0.dealKey < $1.dealKey
            }

            phase = "Computing quarterly, structure, and league-table aggregations…"
            let nowISO = ISO8601DateFormatter().string(from: Date())
            extractedAtISO8601 = nowISO

            let built = Self.buildDashboard(
                bucket: store.bucket,
                extractedAtISO8601: nowISO,
                status: TrendsExtractionStatus(
                    isExtracting: false,
                    phase: "Idle",
                    completedDeals: sortedDeals.count,
                    totalDeals: sortedDeals.count,
                    extractedAtISO8601: nowISO
                ),
                deals: sortedDeals,
                totalPackages: snapshot.totalPackages,
                totalExhibits: snapshot.totalExhibits,
                labeledExhibits: snapshot.labeledExhibits
            )

            cachedDashboard = built
            cachedDealsByKey = Dictionary(uniqueKeysWithValues: sortedDeals.map { ($0.dealKey, $0) })

            phase = "Persisting deal_trends.json & deal_trends.jsonl to GCS…"
            let compact = JSONEncoder()
            compact.outputFormatting = [.sortedKeys]

            if let dealsData = try? compact.encode(sortedDeals) {
                try? await store.write(dealsData, to: dealsJSONPath, contentType: "application/json")
            }
            if let jsonlData = Self.encodeJSONLines(sortedDeals, encoder: compact) {
                try? await store.write(jsonlData, to: dealsJSONLPath, contentType: "application/x-ndjson")
            }
            if let dashData = try? compact.encode(built) {
                try? await store.write(dashData, to: dashboardCachePath, contentType: "application/json")
            }

            let elapsed = Self.seconds(from: clock.now - startedAt)
            await logger.record(
                operation: "extract-trends",
                message: "Extracted cover-page deal terms across \(sortedDeals.count) deals (\(built.dealsWithProceeds) with proceeds, \(built.dealsWithBookrunners) with bookrunners, \(built.dealsWithCounsel) with counsel).",
                durationSeconds: elapsed,
                metadata: [
                    "deals": "\(sortedDeals.count)",
                    "spacDeals": "\(built.spacDeals)",
                    "dealsWithProceeds": "\(built.dealsWithProceeds)",
                    "dealsWithBookrunners": "\(built.dealsWithBookrunners)",
                    "dealsWithCounsel": "\(built.dealsWithCounsel)"
                ]
            )
        } catch {
            await logger.record(
                severity: "ERROR",
                operation: "extract-trends",
                message: "Cover-page trend extraction failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Deal-Chain Cover Resolution

    private static func extractDealChain(
        group: DealGroupRecord,
        store: any ObjectStore,
        filingsPrefix: String
    ) async -> DealTrendRecord {
        // `group.submissions` is ordered newest-first (`chronological.reversed()`).
        let newestFirst = group.submissions
        var primarySub = newestFirst.first
        var merged = CoverPageExtractor.PartialCoverExtraction()
        var chosenCoverSub = newestFirst.first

        for (idx, sub) in newestFirst.enumerated() {
            let docPath = "\(filingsPrefix)/\(sub.folderKey)/document.html"
            guard let data = try? await store.readCoverPrefix(docPath),
                  !data.isEmpty else {
                continue
            }
            let parsed = CoverPageExtractor.extract(fromHTMLData: data)

            if idx == 0 {
                merged = parsed
                chosenCoverSub = sub
            } else {
                // Backfill missing Prospectus Cover Page fields when the latest S-1/A was an exhibit-only amendment
                if merged.ipoProceedsUSD == nil, let p = parsed.ipoProceedsUSD {
                    merged.ipoProceedsUSD = p
                    merged.overAllotmentProceedsUSD = parsed.overAllotmentProceedsUSD
                    merged.unitCount = parsed.unitCount
                    merged.unitPriceUSD = parsed.unitPriceUSD
                    merged.rawOfferingSnippet = parsed.rawOfferingSnippet
                    chosenCoverSub = sub
                }
                if merged.bookrunners.isEmpty && !parsed.bookrunners.isEmpty {
                    merged.bookrunners = parsed.bookrunners
                    merged.rawBookrunnerSnippet = parsed.rawBookrunnerSnippet
                    chosenCoverSub = sub
                }
                if merged.warrantCoverage == "Unspecified" && parsed.warrantCoverage != "Unspecified" {
                    merged.warrantCoverage = parsed.warrantCoverage
                    merged.rawUnitStructureSnippet = parsed.rawUnitStructureSnippet
                }
                if merged.trustPerUnitUSD == nil, let t = parsed.trustPerUnitUSD {
                    merged.trustPerUnitUSD = t
                    merged.trustee = merged.trustee ?? parsed.trustee
                }
                if merged.combinationWindowMonths == nil, let m = parsed.combinationWindowMonths {
                    merged.combinationWindowMonths = m
                }
                if merged.exchange == nil, let ex = parsed.exchange {
                    merged.exchange = ex
                }
                if merged.proposedTicker == nil, let tk = parsed.proposedTicker {
                    merged.proposedTicker = tk
                }
                if merged.issuerCounsel.isEmpty && !parsed.issuerCounsel.isEmpty {
                    merged.issuerCounsel = parsed.issuerCounsel
                    merged.underwriterCounsel = parsed.underwriterCounsel
                    merged.offshoreCounsel = parsed.offshoreCounsel
                    merged.counselPartners = parsed.counselPartners
                    merged.rawCopiesToSnippet = parsed.rawCopiesToSnippet
                }
                if merged.facingSIC == nil { merged.facingSIC = parsed.facingSIC }
                if merged.facingJurisdiction == nil { merged.facingJurisdiction = parsed.facingJurisdiction }
                if parsed.isSPAC { merged.isSPAC = true }
            }

            // Stop walking older amendments once we have both offering proceeds and bookrunners
            if merged.ipoProceedsUSD != nil && !merged.bookrunners.isEmpty && !merged.issuerCounsel.isEmpty {
                break
            }
        }

        let fallbackSub = chosenCoverSub ?? primarySub
        if primarySub == nil { primarySub = fallbackSub }

        let resolvedSIC = !group.sic.isEmpty ? group.sic : (merged.facingSIC ?? "")
        let isSPAC = resolvedSIC == "6770" || merged.isSPAC
        let resolvedJurisdiction = !group.stateOfIncorporationDescription.isEmpty
            ? group.stateOfIncorporationDescription
            : (merged.facingJurisdiction ?? "Unspecified")

        let anchorDate = !group.earliestFilingDate.isEmpty ? group.earliestFilingDate : group.latestFilingDate
        let (year, quarter) = Self.yearAndQuarter(from: anchorDate, fallbackAccession: fallbackSub?.accessionNo ?? "")

        let secTicker = newestFirst.compactMap { $0.tickers.first }.first
        let finalTicker = merged.proposedTicker ?? secTicker

        let sourceAcc = fallbackSub?.accessionNo ?? ""
        let cleanCIK = group.cik.drop(while: { $0 == "0" })
        let noDashAcc = sourceAcc.replacingOccurrences(of: "-", with: "")
        let primaryDoc = fallbackSub?.primaryDocument ?? ""
        let secArchiveURL: String
        if !noDashAcc.isEmpty && !cleanCIK.isEmpty {
            if !primaryDoc.isEmpty {
                secArchiveURL = "https://www.sec.gov/Archives/edgar/data/\(cleanCIK)/\(noDashAcc)/\(primaryDoc)"
            } else {
                secArchiveURL = "https://www.sec.gov/Archives/edgar/data/\(cleanCIK)/\(noDashAcc)/\(sourceAcc)-index.htm"
            }
        } else {
            secArchiveURL = "https://www.sec.gov/edgar/searchedgar/companysearch"
        }

        let isOverfunded = (merged.trustPerUnitUSD ?? 10.0) > 10.001

        return DealTrendRecord(
            dealKey: group.dealKey,
            fileNumber: group.fileNumber,
            cik: group.cik,
            companyName: group.companyName,
            sic: resolvedSIC,
            isSPAC: isSPAC,
            jurisdiction: resolvedJurisdiction,
            earliestFilingDate: group.earliestFilingDate,
            latestFilingDate: group.latestFilingDate,
            filingYear: year,
            filingQuarter: quarter,
            sourceFolderKey: fallbackSub?.folderKey ?? "",
            sourceAccessionNo: sourceAcc,
            sourceFormType: fallbackSub?.formType ?? "S-1",
            sourceFilingDate: fallbackSub?.filingDate ?? group.latestFilingDate,
            submissionCount: group.submissionCount,
            exhibitCount: group.totalExhibits,
            distinctExhibitTypes: group.distinctCanonicalTypes,
            ipoProceedsUSD: merged.ipoProceedsUSD,
            overAllotmentProceedsUSD: merged.overAllotmentProceedsUSD,
            unitCount: merged.unitCount,
            unitPriceUSD: merged.unitPriceUSD,
            bookrunners: merged.bookrunners,
            issuerCounsel: merged.issuerCounsel,
            underwriterCounsel: merged.underwriterCounsel,
            offshoreCounsel: merged.offshoreCounsel,
            counselPartners: merged.counselPartners,
            warrantCoverage: merged.warrantCoverage,
            trustPerUnitUSD: merged.trustPerUnitUSD,
            isOverfundedTrust: isOverfunded,
            trustee: merged.trustee,
            combinationWindowMonths: merged.combinationWindowMonths,
            exchange: merged.exchange,
            proposedTicker: finalTicker,
            rawOfferingSnippet: merged.rawOfferingSnippet,
            rawBookrunnerSnippet: merged.rawBookrunnerSnippet,
            rawCopiesToSnippet: merged.rawCopiesToSnippet,
            rawUnitStructureSnippet: merged.rawUnitStructureSnippet,
            secArchiveURL: secArchiveURL
        )
    }

    // MARK: - Aggregations

    static func buildDashboard(
        bucket: String,
        extractedAtISO8601: String?,
        status: TrendsExtractionStatus,
        deals: [DealTrendRecord],
        totalPackages: Int,
        totalExhibits: Int,
        labeledExhibits: Int
    ) -> TrendsDashboardResponse {
        var spacDeals = 0
        var dealsWithProceeds = 0
        var dealsWithBookrunners = 0
        var dealsWithCounsel = 0
        var aggregateProceeds: Int64 = 0

        var byQuarter: [String: [DealTrendRecord]] = [:]
        var byYear: [Int: [DealTrendRecord]] = [:]
        var bankStats: [String: (deals: Int, proceeds: Int64)] = [:]
        var counselStats: [String: (deals: Int, proceeds: Int64, issuer: Int, uw: Int)] = [:]

        for d in deals {
            if d.isSPAC { spacDeals += 1 }
            let proceeds = d.ipoProceedsUSD ?? 0
            if d.ipoProceedsUSD != nil {
                dealsWithProceeds += 1
                aggregateProceeds += proceeds
            }
            if !d.bookrunners.isEmpty { dealsWithBookrunners += 1 }
            if !d.issuerCounsel.isEmpty || !d.underwriterCounsel.isEmpty || !d.offshoreCounsel.isEmpty {
                dealsWithCounsel += 1
            }

            byQuarter[d.filingQuarter, default: []].append(d)
            byYear[d.filingYear, default: []].append(d)

            for bank in Set(d.bookrunners) {
                var cur = bankStats[bank] ?? (0, 0)
                cur.deals += 1
                cur.proceeds += proceeds
                bankStats[bank] = cur
            }

            let issuerSet = Set(d.issuerCounsel)
            let uwSet = Set(d.underwriterCounsel)
            let allUS = issuerSet.union(uwSet)
            for firm in allUS {
                var cur = counselStats[firm] ?? (0, 0, 0, 0)
                cur.deals += 1
                cur.proceeds += proceeds
                if issuerSet.contains(firm) { cur.issuer += 1 }
                if uwSet.contains(firm) { cur.uw += 1 }
                counselStats[firm] = cur
            }
        }

        let quarterlyTrends: [QuarterlyTrendPoint] = byQuarter.keys.sorted().map { q in
            let list = byQuarter[q] ?? []
            let priced = list.compactMap(\.ipoProceedsUSD).sorted()
            let totalP = priced.reduce(0, +)
            let medianP: Int64 = priced.isEmpty ? 0 : priced[priced.count / 2]
            let trustList = list.filter { $0.trustPerUnitUSD != nil }
            let overCount = trustList.filter(\.isOverfundedTrust).count
            let overPct = trustList.isEmpty ? 0.0 : (Double(overCount) / Double(trustList.count) * 1000).rounded() / 10
            return QuarterlyTrendPoint(
                quarter: q,
                dealCount: list.count,
                spacDealCount: list.filter(\.isSPAC).count,
                pricedDealCount: priced.count,
                totalProceedsUSD: totalP,
                medianProceedsUSD: medianP,
                overfundedSharePct: overPct
            )
        }

        let annualStructures: [AnnualStructurePoint] = byYear.keys.sorted().map { yr in
            let list = byYear[yr] ?? []
            var buckets: [String: Int] = [:]
            var overfunded = 0
            var trustObserved = 0
            var windowSum = 0
            var windowCount = 0
            for d in list {
                buckets[d.warrantCoverage, default: 0] += 1
                if d.trustPerUnitUSD != nil {
                    trustObserved += 1
                    if d.isOverfundedTrust { overfunded += 1 }
                }
                if let w = d.combinationWindowMonths {
                    windowSum += w
                    windowCount += 1
                }
            }
            let avgW = windowCount > 0 ? (Double(windowSum) / Double(windowCount) * 10).rounded() / 10 : nil
            return AnnualStructurePoint(
                year: yr,
                dealCount: list.count,
                buckets: buckets,
                overfundedCount: overfunded,
                trustObservedCount: trustObserved,
                avgCombinationMonths: avgW
            )
        }

        let bookrunnerLeague: [LeagueTableEntry] = bankStats.map { name, st in
            LeagueTableEntry(
                name: name,
                dealCount: st.deals,
                totalProceedsUSD: st.proceeds,
                issuerRoleCount: 0,
                underwriterRoleCount: st.deals
            )
        }.sorted {
            if $0.dealCount != $1.dealCount { return $0.dealCount > $1.dealCount }
            return $0.totalProceedsUSD > $1.totalProceedsUSD
        }

        let counselLeague: [LeagueTableEntry] = counselStats.map { name, st in
            LeagueTableEntry(
                name: name,
                dealCount: st.deals,
                totalProceedsUSD: st.proceeds,
                issuerRoleCount: st.issuer,
                underwriterRoleCount: st.uw
            )
        }.sorted {
            if $0.dealCount != $1.dealCount { return $0.dealCount > $1.dealCount }
            return $0.totalProceedsUSD > $1.totalProceedsUSD
        }

        return TrendsDashboardResponse(
            bucket: bucket,
            extractedAtISO8601: extractedAtISO8601,
            status: status,
            totalDeals: deals.count,
            spacDeals: spacDeals,
            dealsWithProceeds: dealsWithProceeds,
            dealsWithBookrunners: dealsWithBookrunners,
            dealsWithCounsel: dealsWithCounsel,
            aggregateProceedsUSD: aggregateProceeds,
            totalPackagesInCorpus: totalPackages,
            totalExhibitsInCorpus: totalExhibits,
            labeledExhibitsInCorpus: labeledExhibits,
            quarterlyTrends: quarterlyTrends,
            annualStructures: annualStructures,
            bookrunnerLeague: bookrunnerLeague,
            counselLeague: counselLeague,
            deals: deals
        )
    }

    // MARK: - Persistence & Helpers

    private func incrementProgress() {
        completedDeals += 1
    }

    private func ensureLoaded() async {
        if didLoadFromStore && (cachedDashboard != nil || isExtracting) {
            return
        }
        didLoadFromStore = true
        let decoder = JSONDecoder()
        if let (data, _) = try? await store.read(dashboardCachePath),
           let decoded = try? decoder.decode(TrendsDashboardResponse.self, from: data) {
            cachedDashboard = decoded
            extractedAtISO8601 = decoded.extractedAtISO8601
            cachedDealsByKey = Dictionary(uniqueKeysWithValues: decoded.deals.map { ($0.dealKey, $0) })
        }
    }

    private static func yearAndQuarter(from dateStr: String, fallbackAccession: String) -> (Int, String) {
        let parts = dateStr.split(separator: "-")
        if parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]), y >= 2020 && y <= 2030 {
            let q = ((max(1, min(12, m)) - 1) / 3) + 1
            return (y, "\(y)-Q\(q)")
        }
        let accParts = fallbackAccession.split(separator: "-")
        if accParts.count == 3, let yy = Int(accParts[1]), yy >= 20 && yy <= 30 {
            let y = 2000 + yy
            return (y, "\(y)-Q1")
        }
        return (2025, "2025-Q1")
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

    private static func seconds(from duration: Duration) -> Double {
        let c = duration.components
        let raw = Double(c.seconds) + (Double(c.attoseconds) / 1e18)
        return (raw * 100).rounded() / 100
    }
}
