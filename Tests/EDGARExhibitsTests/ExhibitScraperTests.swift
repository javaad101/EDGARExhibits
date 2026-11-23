import Foundation
import XCTest
@testable import EDGARExhibits

final class ExhibitScraperTests: XCTestCase {
    actor InMemoryStore: ObjectStore {
        nonisolated let bucket = "test-bucket"
        private(set) var objects: [String: (Data, String)] = [:]

        func write(_ data: Data, to objectPath: String, contentType: String) async throws {
            objects[objectPath] = (data, contentType)
        }

        func read(_ objectPath: String) async throws -> (data: Data, contentType: String) {
            guard let entry = objects[objectPath] else {
                throw URLError(.fileDoesNotExist)
            }
            return entry
        }

        func delete(_ objectPath: String) async throws {
            objects.removeValue(forKey: objectPath)
        }

        func listSubprefixes(under prefix: String) async throws -> [String] {
            let normalized = prefix.isEmpty || prefix.hasSuffix("/") ? prefix : "\(prefix)/"
            var seen = Set<String>()
            for key in objects.keys where key.hasPrefix(normalized) {
                let remainder = key.dropFirst(normalized.count)
                if let slash = remainder.firstIndex(of: "/") {
                    let sub = normalized + remainder[...slash]
                    seen.insert(String(sub))
                }
            }
            return seen.sorted()
        }

        func listObjectNames(under prefix: String) async throws -> [String] {
            objects.keys.filter { $0.hasPrefix(prefix) }.sorted()
        }
    }

    func testRewritesMirrorURLAndRejectsExternalHosts() throws {
        let rewritten = try mirrorURL(
            for: "https://www.sec.gov/Archives/edgar/data/1318605/000095017026012345/s1.htm"
        )
        XCTAssertEqual(
            rewritten.absoluteString,
            "https://edgar-mirror.sec-api.io/1318605/000095017026012345/s1.htm"
        )
        XCTAssertThrowsError(
            try mirrorURL(for: "https://example.com/Archives/edgar/data/1/2/file.htm")
        )
    }

    func testExtractsCanonicalExhibitsAndUnwrapsInlineXBRL() async throws {
        let filing = Filing(
            accessionNo: "0001193125-26-012345",
            cik: "1318605",
            linkToFilingDetails: "https://www.sec.gov/Archives/edgar/data/1318605/000119312526012345/d12345ds1.htm",
            formType: "S-1"
        )
        let filingURL = try XCTUnwrap(URL(string: filing.linkToFilingDetails))
        let store = InMemoryStore()
        let scraper = ExhibitScraper(
            filing: filing,
            filingURL: filingURL,
            prefix: "filings",
            store: store,
            headers: [:]
        )

        let html = """
        <html>
          <head>
            <BASE HREF='https://www.sec.gov/Archives/edgar/data/1318605/000119312526012345/' />
            <script>var fake = "<a href='should_ignore.htm'>Fake</a>";</script>
          </head>
          <body>
            <!-- <a href="commented_out.htm">Commented Out</a> -->
            <area href="map_ignore.htm" />
            <a data-href="not_an_href.htm">Ignored</a>
            <a href="#toc">Table of Contents</a>
            <a href="d12345ds1.htm">Primary S-1</a>
            <a href="d12345dex21.htm"><span>Exhibit 2.1</span> &ndash;   Merger Agreement</a>
            <a href="/ix?doc=/Archives/edgar/data/1318605/000119312526012345/d12345dex101.htm&amp;x=1">Exhibit 10.1<br>Credit Agreement</a>
            <A HREF=d12345dex51.htm>Opinion of Counsel
            <a href="https://www.sec.gov/Archives/edgar/data/1318605/000119312526012345/d12345dex21.htm">Duplicate Exhibit 2.1</a>
            <a href="https://www.sec.gov/ix?doc=/Archives/edgar/data/1318605/000119312526012345/d12345ds1.htm">Self via iXBRL</a>
          </body>
        </html>
        """

        let attachments = await scraper.attachments(in: html)
        XCTAssertEqual(attachments.count, 3)
        XCTAssertEqual(attachments[0], Attachment(
            docName: "Exhibit 2.1 – Merger Agreement",
            docURL: "https://www.sec.gov/Archives/edgar/data/1318605/000119312526012345/d12345dex21.htm"
        ))
        XCTAssertEqual(attachments[1], Attachment(
            docName: "Exhibit 10.1 Credit Agreement",
            docURL: "https://www.sec.gov/Archives/edgar/data/1318605/000119312526012345/d12345dex101.htm"
        ))
        XCTAssertEqual(attachments[2], Attachment(
            docName: "Opinion of Counsel",
            docURL: "https://www.sec.gov/Archives/edgar/data/1318605/000119312526012345/d12345dex51.htm"
        ))
    }

    func testCatalogJoinsSECSubmissionsAndAppliesOneTriggersAllRegexRules() async throws {
        let store = InMemoryStore()
        let logger = ActivityLogger(store: store)
        let catalog = CorpusCatalog(store: store, filingsPrefix: "filings", logger: logger)

        let manifest: [SavedExhibit] = [
            SavedExhibit(
                attachment: Attachment(
                    docName: "Form of Amended and Restated Memorandum and Articles of Association.*",
                    docURL: "https://www.sec.gov/Archives/edgar/data/1995413/000101376223002569/fs12023ex3-2_colombier2.htm"
                ),
                filename: "3-fs12023ex3-2_colombier2.htm",
                objectPath: "filings/0001013762-23-002569_1995413/exhibits/3-fs12023ex3-2_colombier2.htm"
            ),
            SavedExhibit(
                attachment: Attachment(
                    docName: "Form of Investment Management Trust Agreement.",
                    docURL: "https://www.sec.gov/Archives/edgar/data/1995413/000101376223002569/fs12023ex10-2_colombier2.htm"
                ),
                filename: "8-fs12023ex10-2_colombier2.htm",
                objectPath: "filings/0001013762-23-002569_1995413/exhibits/8-fs12023ex10-2_colombier2.htm"
            ),
            SavedExhibit(
                attachment: Attachment(
                    docName: "Graphic Logo",
                    docURL: "https://www.sec.gov/Archives/edgar/data/1995413/000101376223002569/logo.jpg"
                ),
                filename: "9-logo.jpg",
                objectPath: "filings/0001013762-23-002569_1995413/exhibits/9-logo.jpg"
            )
        ]

        try await store.write(
            JSONEncoder().encode(manifest),
            to: "filings/0001013762-23-002569_1995413/exhibits/manifest.json",
            contentType: "application/json"
        )

        let fakeSECJSON = """
        {
          "cik": "1995413",
          "name": "Colombier Acquisition Corp. II",
          "sic": "6770",
          "sicDescription": "Blank Checks",
          "tickers": ["CLBR"],
          "stateOfIncorporation": "E9",
          "stateOfIncorporationDescription": "Cayman Islands",
          "filings": {
            "recent": {
              "accessionNumber": ["0001013762-23-002569"],
              "form": ["S-1/A"],
              "fileNumber": ["333-274567"],
              "filingDate": ["2023-11-15"],
              "acceptanceDateTime": ["2023-11-15T16:30:00.000Z"],
              "primaryDocument": ["fs12023a2_colombier2.htm"]
            }
          }
        }
        """

        await catalog.performSync(forceRefreshSEC: false) { paddedCIK in
            XCTAssertEqual(paddedCIK, "0001995413")
            return Data(fakeSECJSON.utf8)
        }

        let overview = await catalog.overview()
        XCTAssertEqual(overview.totalPackagesInBucket, 1)
        XCTAssertEqual(overview.matchedToSECSubmissions, 1)
        XCTAssertEqual(overview.spacSIC6770Count, 1)
        XCTAssertEqual(overview.totalExhibits, 3)
        XCTAssertEqual(overview.labeledExhibits, 2)
        XCTAssertEqual(overview.unlabeledExhibits, 1)

        let deals = await catalog.queryDeals(search: "333-274567", offset: 0, limit: 10)
        XCTAssertEqual(deals.totalMatching, 1)
        XCTAssertEqual(deals.items.first?.companyName, "Colombier Acquisition Corp. II")
        XCTAssertEqual(deals.items.first?.submissions.first?.formType, "S-1/A")

        let labeled = await catalog.queryExhibits(
            status: "labeled",
            canonicalType: "Amended and Restated Memorandum and Articles of Association",
            ruleID: nil,
            folderKey: nil,
            search: nil,
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(labeled.totalMatching, 1)
        XCTAssertEqual(labeled.items.first?.filename, "3-fs12023ex3-2_colombier2.htm")

        let unlabeled = await catalog.queryExhibits(
            status: "unlabeled",
            canonicalType: nil,
            ruleID: nil,
            folderKey: nil,
            search: nil,
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(unlabeled.totalMatching, 1)
        XCTAssertEqual(unlabeled.items.first?.filename, "9-logo.jpg")
    }

    func testIndexParserAndDocumentFormatFilesCaptureNonHyperlinkedS1Exhibits() async throws {
        let indexHTML = """
        <table class="tableFile" summary="Document Format Files">
           <tr>
              <th scope="col">Seq</th>
              <th scope="col">Description</th>
              <th scope="col">Document</th>
              <th scope="col">Type</th>
              <th scope="col">Size</th>
           </tr>
           <tr>
              <td>1</td>
              <td>FORM S-1</td>
              <td><a href="/ix?doc=/Archives/edgar/data/2136360/000213636026000003/mracs1.htm">mracs1.htm</a></td>
              <td>S-1</td>
              <td>1504920</td>
           </tr>
           <tr>
              <td>2</td>
              <td>FORM OF UNDERWRITING AGREEMENT</td>
              <td><a href="/Archives/edgar/data/2136360/000213636026000003/ex1-1.htm">ex1-1.htm</a></td>
              <td>EX-1.1</td>
              <td>185210</td>
           </tr>
           <tr>
              <td>3</td>
              <td>Form of Registration and Shareholder Rights Agreement</td>
              <td><a href="/Archives/edgar/data/2136360/000213636026000003/ex10-3.htm">ex10-3.htm</a></td>
              <td>EX-10.3</td>
              <td>98400</td>
           </tr>
           <tr>
              <td>4</td>
              <td>LOGO GRAPHIC</td>
              <td><a href="/Archives/edgar/data/2136360/000213636026000003/logo.jpg">logo.jpg</a></td>
              <td>GRAPHIC</td>
              <td>12400</td>
           </tr>
           <tr>
              <td>&nbsp;</td>
              <td>Complete submission text file</td>
              <td><a href="/Archives/edgar/data/2136360/000213636026000003/0002136360-26-000003.txt">0002136360-26-000003.txt</a></td>
              <td>&nbsp;</td>
              <td>2100000</td>
           </tr>
        </table>
        <table class="tableFile" summary="Data Files">
           <tr>
              <td>10</td>
              <td>XBRL TAXONOMY EXTENSION SCHEMA</td>
              <td><a href="/Archives/edgar/data/2136360/000213636026000003/mrac-20260713.xsd">mrac-20260713.xsd</a></td>
              <td>EX-101.SCH</td>
              <td>8200</td>
           </tr>
        </table>
        """

        let parsedFiles = EDGARIndexParser.parseDocumentFormatFiles(Data(indexHTML.utf8))
        XCTAssertEqual(parsedFiles.count, 5)

        let filing = Filing(
            accessionNo: "0002136360-26-000003",
            cik: "2136360",
            linkToFilingDetails: "https://www.sec.gov/Archives/edgar/data/2136360/000213636026000003/mracs1.htm",
            documentFormatFiles: parsedFiles,
            formType: "S-1"
        )
        let store = InMemoryStore()
        let scraper = ExhibitScraper(
            filing: filing,
            filingURL: try XCTUnwrap(URL(string: filing.linkToFilingDetails)),
            prefix: "filings",
            store: store,
            headers: [:]
        )

        let attachments = await scraper.attachments(from: parsedFiles)
        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments[0].docURL, "https://www.sec.gov/Archives/edgar/data/2136360/000213636026000003/ex1-1.htm")
        XCTAssertEqual(attachments[1].docName, "EX-10.3: Form of Registration and Shareholder Rights Agreement")
    }

    func testUpgradedRulebookClassifiesNumberedExhibitsAndPrunesPre2020() async throws {
        XCTAssertFalse(CorpusCatalog.is2020OrLater(accessionNo: "0000891020-97-000123"))
        XCTAssertFalse(CorpusCatalog.is2020OrLater(accessionNo: "0001193125-19-004567"))
        XCTAssertTrue(CorpusCatalog.is2020OrLater(accessionNo: "0001104659-20-012345"))
        XCTAssertTrue(CorpusCatalog.is2020OrLater(accessionNo: "0002136360-26-000003"))

        var subs: [SubmissionRecord] = []
        var exs: [CatalogExhibit] = [
            CatalogExhibit(
                folderKey: "f1", accessionNo: "0001104659-21-000001", cik: "1", companyName: "Test SPAC",
                fileNumber: "333-1", formType: "S-1", filingDate: "2021-02-01",
                filename: "4-ex10_3.htm",
                docName: "EX-10.3: Form of Registration and Shareholder Rights Agreement",
                docURL: "https://www.sec.gov/x", objectPath: "p1"
            ),
            CatalogExhibit(
                folderKey: "f1", accessionNo: "0001104659-21-000001", cik: "1", companyName: "Test SPAC",
                fileNumber: "333-1", formType: "S-1", filingDate: "2021-02-01",
                filename: "6-ex4x6.htm",
                docName: "Specimen Rights Certificate",
                docURL: "https://www.sec.gov/x2", objectPath: "p2"
            ),
            CatalogExhibit(
                folderKey: "f1", accessionNo: "0001104659-21-000001", cik: "1", companyName: "Test SPAC",
                fileNumber: "333-1", formType: "S-1", filingDate: "2021-02-01",
                filename: "7-d12345dex101.htm",
                docName: "10.1",
                docURL: "https://www.sec.gov/x3", objectPath: "p3"
            ),
            CatalogExhibit(
                folderKey: "f1", accessionNo: "0001104659-21-000001", cik: "1", companyName: "Test SPAC",
                fileNumber: "333-1", formType: "S-1", filingDate: "2021-02-01",
                filename: "8-dp136513_ex0401.htm",
                docName: "4.1",
                docURL: "https://www.sec.gov/x4", objectPath: "p4"
            ),
            CatalogExhibit(
                folderKey: "f1", accessionNo: "0001104659-21-000001", cik: "1", companyName: "Test SPAC",
                fileNumber: "333-1", formType: "S-1", filingDate: "2021-02-01",
                filename: "9-s1_poa.htm",
                docName: "Power of Attorney (included on signature page)",
                docURL: "https://www.sec.gov/x5", objectPath: "p5"
            )
        ]

        try CorpusCatalog.applyRules(CorpusCatalog.defaultRules, to: &exs, updatingSubmissions: &subs)
        XCTAssertEqual(exs[0].canonicalType, "Registration Rights Agreement")
        XCTAssertEqual(exs[1].canonicalType, "Specimen Warrant / Right Certificate")
        XCTAssertEqual(exs[2].canonicalType, "Exhibit 10 — SPAC Material Contract (Numbered)")
        XCTAssertEqual(exs[3].canonicalType, "Exhibit 4 — Specimen Security / Warrant Instrument")
        XCTAssertEqual(exs[4].canonicalType, "Power of Attorney (Ex. 24)")
    }

    func testCoverPageExtractorHandlesInlineXBRLPartnersAndUnitFractions() throws {
        let ixbrlS1 = """
        <html><body>
        <div style="display:none">
          <ix:header><ix:resources>HUGE_IXBRL_CONTEXT_PADDING</ix:resources></ix:header>
        </div>
        <p>As filed with the U.S. Securities and Exchange Commission on September 9, 2025. Registration No. 333-289900</p>
        <p>FORM S-1 REGISTRATION STATEMENT UNDER THE SECURITIES ACT OF 1933</p>
        <p>Example Horizon Acquisition Corp. (Exact Name of Registrant as Specified in Its Charter)</p>
        <p>Cayman Islands (State or Other Jurisdiction of Incorporation or Organization) 6770 (Primary Standard Industrial Classification Code Number)</p>
        <p>Copies to:
           Alex Rivera
           Davis Polk &amp; Wardwell LLP
           450 Lexington Avenue, New York, New York 10017
           Tel.: +1 (212) 450-4000
           Jordan M. Taylor, P.C.
           Morgan Chen
           Skadden, Arps, Slate, Meagher &amp; Flom LLP
           One Manhattan West, New York, New York 10001
           Tel.: +1 (212) 735-3000
        </p>
        <p>Approximate date of commencement of proposed sale to the public: As soon as practicable after the effective date.</p>
        <p>The Registrant hereby amends this Registration Statement on such date or dates as may be necessary to delay its effective date until the registrant shall file a further amendment.</p>
        <p>PROSPECTUS SUBJECT TO COMPLETION</p>
        <p>$400,000,000 Example Horizon Acquisition Corp. 40,000,000 Units</p>
        <p>Example Horizon Acquisition Corp. is a blank check company incorporated as a Cayman Islands exempted company. This is an initial public offering of our securities. Each unit has an offering price of $10.00 and consists of one Class A ordinary share, par value $0.0001 per share, and one-third of one redeemable warrant. We have also granted the underwriters a 45-day option to purchase up to an additional 6,000,000 units to cover over-allotments, for gross proceeds of $460,000,000.</p>
        <p>If we have not consummated an initial business combination within 24 months from the closing of this offering, we will redeem the public shares. An aggregate of $10.05 per unit sold in this offering will be placed in a U.S.-based trust account with Continental Stock Transfer &amp; Trust Company acting as trustee.</p>
        <p>We intend to apply to have our units listed on Nasdaq under the symbol &ldquo;EXHAU&rdquo;.</p>
        <p>The underwriters expect to deliver the units to the purchasers on or about October 1, 2025. Sole Book-Running Manager Cantor Fitzgerald &amp; Co.</p>
        </body></html>
        """

        let extracted = CoverPageExtractor.extract(fromHTML: ixbrlS1)
        XCTAssertEqual(extracted.facingSIC, "6770")
        XCTAssertEqual(extracted.facingJurisdiction, "Cayman Islands")
        XCTAssertTrue(extracted.isSPAC)
        XCTAssertFalse(extracted.isExhibitOnlyAmendment)
        XCTAssertEqual(extracted.ipoProceedsUSD, 400_000_000)
        XCTAssertEqual(extracted.overAllotmentProceedsUSD, 460_000_000)
        XCTAssertEqual(extracted.unitCount, 40_000_000)
        XCTAssertEqual(extracted.unitPriceUSD, 10.0)
        XCTAssertEqual(extracted.bookrunners, ["Cantor Fitzgerald"])
        XCTAssertEqual(extracted.issuerCounsel, ["Davis Polk & Wardwell LLP"])
        XCTAssertEqual(extracted.underwriterCounsel, ["Skadden, Arps, Slate, Meagher & Flom LLP"])
        XCTAssertTrue(extracted.counselPartners.contains("Jordan M. Taylor"))
        XCTAssertTrue(extracted.counselPartners.contains("Morgan Chen"))
        XCTAssertTrue(extracted.counselPartners.contains("Alex Rivera"))
        XCTAssertEqual(extracted.warrantCoverage, "1/3 Warrant")
        XCTAssertEqual(extracted.trustPerUnitUSD, 10.05)
        XCTAssertEqual(extracted.combinationWindowMonths, 24)
        XCTAssertEqual(extracted.exchange, "Nasdaq")
        XCTAssertEqual(extracted.proposedTicker, "EXHAU")
    }

    func testTrendsAnalyzerMergesExhibitOnlyAmendmentWithEarlierProspectusCover() async throws {
        let store = InMemoryStore()
        let logger = ActivityLogger(store: store)
        let catalog = CorpusCatalog(store: store, filingsPrefix: "filings", logger: logger)
        let analyzer = TrendsAnalyzer(store: store, filingsPrefix: "filings", catalog: catalog, logger: logger)

        let initialS1HTML = """
        <html><body>
        <p>Cayman Islands (State or other jurisdiction) 6770 (Primary Standard Industrial Classification Code Number)</p>
        <p>Copies to: Casey Morgan, Esq. Sichenzia Ross Ference Carmel LLP 1185 Avenue of the Americas, New York, NY 10036 (212) 930-9700 Samira Patel, Esq. Carey Olsen Grand Cayman (345) 749-2010 Taylor Brooks, Esq. Loeb &amp; Loeb LLP 345 Park Avenue, New York, NY 10154 (212) 407-4000 Approximate date of commencement of proposed sale to the public: As soon as practicable.</p>
        <p>PROSPECTUS $75,000,000 ZA Acquisition Corp. I 7,500,000 Units</p>
        <p>ZA Acquisition Corp. I is a blank check company. Each unit has an offering price of $10.00 per unit. Each unit consists of one Class A ordinary share, $0.0001 par value per share, and one right to receive one-tenth of one Class A ordinary share upon the consummation of an initial business combination. We have granted D. Boral Capital LLC, the representative of the underwriters, a 45-day option to purchase additional units. $10.00 per unit will be deposited into a trust account within 18 months from the closing of this offering.</p>
        </body></html>
        """

        let exhibitOnlyS1AHTML = """
        <html><body>
        <p>Cayman Islands (State or other jurisdiction) 6770 (Primary Standard Industrial Classification Code Number)</p>
        <p>Copies to: Casey Morgan, Esq. Sichenzia Ross Ference Carmel LLP 1185 Avenue of the Americas, New York, NY 10036 (212) 930-9700 Samira Patel, Esq. Carey Olsen Grand Cayman (345) 749-2010 Taylor Brooks, Esq. Loeb &amp; Loeb LLP 345 Park Avenue, New York, NY 10154 (212) 407-4000 Approximate date of commencement of proposed sale to the public: As soon as practicable.</p>
        <p>EXPLANATORY NOTE: ZA Acquisition Corp. I is filing this Amendment No. 1 to its Registration Statement on Form S-1 solely for the purpose of filing Exhibits 1.1 and 5.1. PART II INFORMATION NOT REQUIRED IN PROSPECTUS.</p>
        </body></html>
        """

        try await store.write(Data(initialS1HTML.utf8), to: "filings/0001213900-26-000001_2127714/document.html", contentType: "text/html")
        try await store.write(Data("[]".utf8), to: "filings/0001213900-26-000001_2127714/exhibits/manifest.json", contentType: "application/json")

        let s1aManifest = [
            SavedExhibit(
                attachment: Attachment(docName: "EX-1.1: Form of Underwriting Agreement", docURL: "https://www.sec.gov/ex1-1.htm"),
                filename: "1-ex1-1.htm",
                objectPath: "filings/0001213900-26-000002_2127714/exhibits/1-ex1-1.htm"
            )
        ]
        try await store.write(Data(exhibitOnlyS1AHTML.utf8), to: "filings/0001213900-26-000002_2127714/document.html", contentType: "text/html")
        try await store.write(JSONEncoder().encode(s1aManifest), to: "filings/0001213900-26-000002_2127714/exhibits/manifest.json", contentType: "application/json")

        let fakeSEC = """
        {
          "cik": "2127714",
          "name": "ZA Acquisition Corp. I",
          "sic": "",
          "sicDescription": "",
          "tickers": ["ZACAU"],
          "stateOfIncorporation": "E9",
          "stateOfIncorporationDescription": "Cayman Islands",
          "filings": {
            "recent": {
              "accessionNumber": ["0001213900-26-000002", "0001213900-26-000001"],
              "form": ["S-1/A", "S-1"],
              "fileNumber": ["333-299911", "333-299911"],
              "filingDate": ["2026-11-12", "2026-11-06"],
              "acceptanceDateTime": ["2026-11-12T16:00:00Z", "2026-11-06T16:00:00Z"],
              "primaryDocument": ["s1a.htm", "s1.htm"]
            }
          }
        }
        """

        await catalog.performSync(forceRefreshSEC: false) { _ in Data(fakeSEC.utf8) }
        await analyzer.performExtraction()

        let dash = await analyzer.dashboard()
        XCTAssertEqual(dash.totalDeals, 1)
        let deal = try XCTUnwrap(dash.deals.first)
        XCTAssertEqual(deal.sic, "6770")
        XCTAssertTrue(deal.isSPAC)
        XCTAssertEqual(deal.ipoProceedsUSD, 75_000_000)
        XCTAssertEqual(deal.bookrunners, ["D. Boral Capital"])
        XCTAssertEqual(deal.issuerCounsel, ["Sichenzia Ross Ference Carmel LLP"])
        XCTAssertEqual(deal.offshoreCounsel, ["Carey Olsen"])
        XCTAssertEqual(deal.underwriterCounsel, ["Loeb & Loeb LLP"])
        XCTAssertEqual(deal.warrantCoverage, "Share Right Only")
        XCTAssertEqual(deal.exhibitCount, 1)
        XCTAssertEqual(deal.sourceFolderKey, "0001213900-26-000001_2127714")
    }
}
