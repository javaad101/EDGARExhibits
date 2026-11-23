# EDGARExhibits

A server-side **Swift 6** service built on **Hummingbird 2** and Google's official **Server-Side Cloud Swift SDK** (`swift-google-cloud-storage`), paired with an interactive **React + Vite + Apache ECharts** public web observatory (**EDGAR Deal & Market Trends Observatory**), that:

1. Harvests modern (`2020–2026`) SEC Form S-1 / S-1/A registration statements (`SIC 6770` Blank Checks and comparative IPO cohorts) into **Google Cloud Storage** (`gs://edgar-exhibits-corpus`),
2. Extracts every exhibit via both SEC EDGAR `{accessionNo}-index.htm` / `documentFormatFiles` tables and primary registration-statement hyperlinks,
3. Joins every accession number against official SEC `submissions` (`CIK##########.json`) registrant & `333-` file-number metadata,
4. Classifies `116,968` exhibits across a deterministic 27-rule "one-triggers-all" regular expression rulebook (`98.40%` typed),
5. Deterministically extracts **Form S-1 Facing-Page & Item 501(b) Prospectus Cover-Page deal terms** across `1,879` `333-` registration chains—including **Gross IPO Proceeds (`$`)**, **Unit Count & Greenshoe**, **Tombstone Bookrunners**, **Issuer / Underwriter / Offshore Legal Counsel & Named Partners**, **Unit Warrant & Share-Right Coverage**, **Trust Account Overfunding (`$/unit`)**, and **Combination Completion Windows**—complete with verbatim cover-page evidence quotes, `Schema.org` `Dataset` JSON-LD structured metadata, and BigQuery-ready NDJSON exports (`spac_corpus.submissions`, `spac_corpus.exhibits`, `spac_corpus.deal_trends`).

## Architecture

| File / Directory | Responsibility |
| :--- | :--- |
| `Sources/EDGARExhibits/Models.swift` | `Codable` + `Sendable` models for `sec-api.io` queries, EDGAR filings (`folderKey` = `<accessionNo>_<cik>`), official SEC `submissions` (`CIK##########.json`), `333-` deal chains, exhibit type rules, cover-page `DealTrendRecord` rows, and league-table / quarterly rollups. |
| `Sources/EDGARExhibits/CoverPageExtractor.swift` | Linear Inline-XBRL (`<ix:header>`) / CSS stripper, primary-source cover-page extractor (`CoverPageExtractor`), and corpus-wide `TrendsAnalyzer` actor resolving exhibit-only `S-1/A` amendments across `333-` deal chains. |
| `Sources/EDGARExhibits/Download.swift` | Rewrites EDGAR archive URLs, dispatches filing jobs across the stateless Cloud Run worker fleet, and performs bounded HTTP retries honoring `Retry-After`. |
| `Sources/EDGARExhibits/ConcurrentJobs.swift` | Bounded `ThrowingTaskGroup` runner preserving input order, isolating per-item errors, and propagating task cancellation. |
| `Sources/EDGARExhibits/ObjectStore.swift` | `GCSObjectStore` backed by `GoogleCloudStorage.StorageClient` & `StorageControlClient`, authenticating via keyless Cloud Run Application Default Credentials (`32 MB` single-shot writes, streaming reads, prefix/delimiter listing, and object deletion). |
| `Sources/EDGARExhibits/HTMLLinkScanner.swift` | Zero-DOM single-pass UTF-8 byte scanner (`HTMLLinkScanner`) + `EDGARIndexParser` for SEC's `{accessionNo}-index.htm` `Document Format Files` table so non-hyperlinked S-1 exhibits are never missed. |
| `Sources/EDGARExhibits/ExhibitScraper.swift` | Swift `actor` merging structured `documentFormatFiles` / `{accessionNo}-index.htm` entries with S-1 prose hyperlinks, skipping graphic/XBRL wrappers, and providing direct `www.sec.gov` exhibit backfill. |
| `Sources/EDGARExhibits/CorpusCatalog.swift` | Bucket-wide indexer joining `filings/<accessionNo>_<cik>/` against official SEC `data.sec.gov/submissions/CIK##########.json`, grouping `333-` deal chains, applying the 27-rule SPAC exhibit regex rulebook, pruning pre-2020 noise, and writing JSON + BigQuery NDJSON tables. |
| `Sources/EDGARExhibits/ActivityLogger.swift` | Structured Cloud Logging emitter + ring-buffered `logs/recent.json` persistence for live UI observability. |
| `Sources/EDGARExhibits/App.swift` | `ScrapeCoordinator` actor + Hummingbird 2 HTTP router serving the public web observatory (`/`), market-trends JSON & `Schema.org` JSON-LD endpoints, catalog search, live regex rule editing, and primary-source filing/exhibit streaming. |
| `Web/` → `Public/` | TypeScript + React 19 + Vite + Tailwind CSS + Apache ECharts frontend (`EDGAR Deal & Market Trends Observatory`) with interactive quarterly/structure/league-table charts, sortable semantic deal ledger, and a primary-source Proof Drawer embedding live archived `document.html` & typed exhibits. |

## Cloud Storage Object Layout (`gs://edgar-exhibits-corpus`)

```text
gs://edgar-exhibits-corpus/
├── state.json                                    # Ground-truth accession set, per-query offsets & batch history
├── corpus/
│   ├── catalog_overview.json                     # Fast cold-start summary & per-rule match counts
│   ├── type_rules.json                           # Live-editable SPAC exhibit regex rulebook
│   ├── submissions.json / submissions.jsonl      # Enriched SEC submissions metadata (BigQuery spac_corpus.submissions)
│   ├── exhibits.json / exhibits.jsonl            # Typed exhibit catalog (BigQuery spac_corpus.exhibits)
│   ├── deal_trends.json / deal_trends.jsonl      # Cover-page deal terms per 333- chain (BigQuery spac_corpus.deal_trends)
│   └── trends_dashboard.json                     # Pre-aggregated quarterly, unit-structure & league-table rollups
├── sec-submissions/
│   └── CIK##########.json                        # Cached official SEC registrant & filing history JSON
└── filings/
    └── <accessionNo>_<cik>/                      # 1 folder per 2020–2026 registration statement
        ├── document.html                         # Primary Form S-1 / S-1/A HTML
        └── exhibits/
            ├── 1-ex1_1.htm                       # Extracted & deduplicated exhibits
            ├── 2-ex3_2.htm
            └── manifest.json                     # Structured exhibit metadata & GCS object paths
```

## Key HTTP Endpoints

- `GET /` & `GET /trends` — Interactive **EDGAR Deal & Market Trends Observatory** web UI (with embedded `Schema.org` `Dataset` JSON-LD).
- `GET /trends/dashboard` — Complete deal-level trends dataset, quarterly issuance & overfunding series, annual warrant/share-right structure matrix, and bookrunner/counsel league tables.
- `GET /trends/deals/:dealKey` — Primary-source proof payload returning all `S-1` / `S-1/A` submissions and deterministically typed exhibits across a `333-` deal chain.
- `POST /ops/extract-trends` — Background 64-way concurrent cover-page extraction across all `333-` deal chains in `gs://edgar-exhibits-corpus`, persisting `deal_trends.json` and `deal_trends.jsonl`.
- `GET /schema/dataset.jsonld` — Dynamic `application/ld+json` `Schema.org` `Dataset` document.
- `GET /health` & `GET /status` — Readiness probe, live batch progress, `ContinuousClock` elapsed seconds, and ground-truth package/exhibit counts.
- `GET /catalog/overview`, `/deals`, `/submissions`, `/exhibits` — Corpus & SEC `submissions.json` search and audit APIs.
- `GET /rules` & `PUT /rules` — Inspect or hot-update deterministic "one-triggers-all" regular expression rules across the entire corpus.
- `POST /ops/sync-catalog` & `POST /ops/clean-2020-corpus` — Background SEC catalog sync, 2020+ exhibit backfill, and corpus hygiene.
- `GET /filings/:folderKey`, `/document`, `/exhibits/:filename` — Streams manifests, primary registration statements, and exhibits from private GCS.
- `POST /scrape` & `POST /scrape-filing` — Coordinator + 50-way horizontal Cloud Run worker fan-out.

## Local Development & Tests

```bash
# Run Swift 6 backend & cover-page extractor test suite
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Rebuild static web observatory into Public/
npm --prefix Web run build
```
