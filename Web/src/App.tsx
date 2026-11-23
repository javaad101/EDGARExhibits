import { useEffect, useMemo, useRef, useState } from 'react';
import {
  Sun,
  Moon,
  Search,
  ChevronDown,
  ChevronsLeft,
  ChevronLeft,
  ChevronRight,
  ChevronsRight,
  ArrowUpDown,
  Download,
  RotateCcw,
  Code2,
  Scale,
  X,
  Loader2,
  AlertCircle,
} from 'lucide-react';
import type { DealTrendRecord, TrendsDashboardResponse } from './types';
import {
  buildDailyBusinessSeries,
  computeCohortAnalytics,
  computeIntervalSummary,
  dealAnchorDate,
  downloadDealsCSV,
  formatCompactUSD,
  formatFilingDate,
  formatUnits,
} from './utils/format';
import { AnalyticsCharts } from './components/AnalyticsCharts';
import { ProofSidePanel } from './components/ProofSidePanel';
import type { MarketBenchmarksPayload } from './utils/benchmarks';

type SortKey = 'latestFilingDate' | 'companyName' | 'ipoProceedsUSD' | 'warrantCoverage' | 'exhibitCount';
type SortDirection = 'ascending' | 'descending';

const textCollator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
const PAGE_SIZE = 30;

function readInitialDark(): boolean {
  if (typeof window === 'undefined') return true;
  try {
    const stored = localStorage.getItem('color-scheme');
    if (stored === 'dark') return true;
    if (stored === 'light') return false;
  } catch {
    // ignore storage errors
  }
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
}

export default function App() {
  const [isDark, setIsDark] = useState<boolean>(readInitialDark);
  const [dashboard, setDashboard] = useState<TrendsDashboardResponse | null>(null);
  const [benchmarks, setBenchmarks] = useState<MarketBenchmarksPayload | null>(null);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);

  // Filters
  const [searchQuery, setSearchQuery] = useState<string>('');
  const [onlySPAC, setOnlySPAC] = useState<boolean>(false);
  const [selectedYear, setSelectedYear] = useState<string>('ALL');
  const [selectedUnderwriter, setSelectedUnderwriter] = useState<string>('ALL');
  const [selectedCounsel, setSelectedCounsel] = useState<string>('ALL');
  const [counselRoleFilter, setCounselRoleFilter] = useState<'ANY' | 'ISSUER' | 'UW'>('ANY');
  const [selectedCoverage, setSelectedCoverage] = useState<string>('ALL');

  // Interval 1 & Optional Comparative Interval 2
  const [intervalAStart, setIntervalAStart] = useState<string>('2020-01-02');
  const [intervalAEnd, setIntervalAEnd] = useState<string>('2026-11-13');
  const [compareEnabled, setCompareEnabled] = useState<boolean>(false);
  const [intervalBStart, setIntervalBStart] = useState<string>('2025-01-02');
  const [intervalBEnd, setIntervalBEnd] = useState<string>('2026-11-13');

  // Dropdown open state (`relative z-30` above `z-10` sticky table header)
  const [openMenu, setOpenMenu] = useState<string | null>(null);
  const toolbarRef = useRef<HTMLDivElement | null>(null);

  // Sortable table state
  const [sortKey, setSortKey] = useState<SortKey>('latestFilingDate');
  const [sortDirection, setSortDirection] = useState<SortDirection>('descending');
  const [sortAnnouncement, setSortAnnouncement] = useState<string>('');
  const [currentPage, setCurrentPage] = useState<number>(1);

  // Selected row & modals
  const [selectedDealKey, setSelectedDealKey] = useState<string | null>(null);
  const [showSchemaModal, setShowSchemaModal] = useState<boolean>(false);
  const [showMethodologyModal, setShowMethodologyModal] = useState<boolean>(false);

  // Sync theme with `<meta name="color-scheme">` + OS preference
  useEffect(() => {
    document.documentElement.classList.toggle('dark', isDark);
  }, [isDark]);

  useEffect(() => {
    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handleOSChange = (e: MediaQueryListEvent) => {
      try {
        if (!localStorage.getItem('color-scheme')) {
          setIsDark(e.matches);
        }
      } catch {
        setIsDark(e.matches);
      }
    };
    const handleStorage = (e: StorageEvent) => {
      if (e.key === 'color-scheme') {
        const meta = document.querySelector('meta[name="color-scheme"]');
        if (meta) meta.setAttribute('content', e.newValue ?? 'light dark');
        if (e.newValue === 'dark') setIsDark(true);
        else if (e.newValue === 'light') setIsDark(false);
        else setIsDark(mq.matches);
      }
    };
    mq.addEventListener('change', handleOSChange);
    window.addEventListener('storage', handleStorage);
    return () => {
      mq.removeEventListener('change', handleOSChange);
      window.removeEventListener('storage', handleStorage);
    };
  }, []);

  const toggleTheme = () => {
    const targetDark = !isDark;
    const targetScheme = targetDark ? 'dark' : 'light';
    const osDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    const osScheme = osDark ? 'dark' : 'light';
    const meta = document.querySelector('meta[name="color-scheme"]');

    try {
      if (targetScheme === osScheme) {
        localStorage.removeItem('color-scheme');
        if (meta) meta.setAttribute('content', 'light dark');
      } else {
        localStorage.setItem('color-scheme', targetScheme);
        if (meta) meta.setAttribute('content', targetScheme);
      }
    } catch {
      if (meta) meta.setAttribute('content', targetScheme);
    }
    setIsDark(targetDark);
  };

  // Close dropdowns on outside click or Escape
  useEffect(() => {
    const onPointerDown = (e: MouseEvent) => {
      if (toolbarRef.current && !toolbarRef.current.contains(e.target as Node)) {
        setOpenMenu(null);
      }
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setOpenMenu(null);
        setShowSchemaModal(false);
        setShowMethodologyModal(false);
      }
    };
    document.addEventListener('mousedown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('mousedown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, []);

  // Fetch live corpus dashboard
  const fetchDashboard = async () => {
    try {
      setError(null);
      const res = await fetch('/trends/dashboard');
      if (!res.ok) throw new Error(`API returned HTTP ${res.status}`);
      const data = (await res.json()) as TrendsDashboardResponse;
      setDashboard(data);
      setLoading(false);

      // Initialize Interval A bounds to exact corpus date span on first load
      if (data.deals.length > 0) {
        let minD = '';
        let maxD = '';
        for (const d of data.deals) {
          const dt = dealAnchorDate(d);
          if (!dt) continue;
          if (!minD || dt < minD) minD = dt;
          if (!maxD || dt > maxD) maxD = dt;
        }
        if (minD && maxD) {
          setIntervalAStart(minD);
          setIntervalAEnd(maxD);
          setIntervalBEnd(maxD);
        }
      }

      // Hydrate Schema.org Dataset JSON-LD in <head>
      const ldNode = document.getElementById('dataset-jsonld');
      if (ldNode && data.totalDeals > 0) {
        ldNode.textContent = JSON.stringify(
          {
            '@context': 'https://schema.org',
            '@type': 'Dataset',
            name: 'EDGAR Form S-1 & S-1/A Cover-Page Terms & Exhibits (2020–2026)',
            description: `Cover-page gross proceeds, underwriters, issuer and underwriter counsel, named partners, unit coverage, and exhibits across ${data.totalPackagesInCorpus.toLocaleString()} Form S-1 and S-1/A filings (${data.totalExhibitsInCorpus.toLocaleString()} exhibits, 2020–2026).`,
            temporalCoverage: '2020-01-01/2026-12-31',
            isAccessibleForFree: true,
            license: 'https://www.sec.gov/privacy#dissemination',
            creator: {
              '@type': 'Organization',
              name: 'Advocates Close',
              url: 'https://spac.advocatesclose.nyc',
            },
            distribution: [
              {
                '@type': 'DataDownload',
                encodingFormat: 'application/json',
                contentUrl: `${window.location.origin}/trends/dashboard`,
              },
              {
                '@type': 'DataDownload',
                encodingFormat: 'application/ld+json',
                contentUrl: `${window.location.origin}/schema/dataset.jsonld`,
              },
            ],
          },
          null,
          2
        );
      }
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Unable to fetch market trends dataset.');
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchDashboard();
    fetch('/assets/market-benchmarks.json')
      .then((res) => (res.ok ? (res.json() as Promise<MarketBenchmarksPayload>) : null))
      .then((data) => {
        if (data) setBenchmarks(data);
      })
      .catch(() => {
        // optional benchmark overlay asset
      });
  }, []);

  useEffect(() => {
    if (!dashboard?.status.isExtracting) return;
    const id = window.setInterval(() => {
      fetchDashboard();
    }, 3000);
    return () => window.clearInterval(id);
  }, [dashboard?.status.isExtracting]);

  const { minCorpusDate, maxCorpusDate } = useMemo(() => {
    if (!dashboard || dashboard.deals.length === 0) {
      return { minCorpusDate: '2020-01-02', maxCorpusDate: '2026-11-13' };
    }
    let minD = '';
    let maxD = '';
    for (const d of dashboard.deals) {
      const dt = dealAnchorDate(d);
      if (!dt) continue;
      if (!minD || dt < minD) minD = dt;
      if (!maxD || dt > maxD) maxD = dt;
    }
    return {
      minCorpusDate: minD || '2020-01-02',
      maxCorpusDate: maxD || '2026-11-13',
    };
  }, [dashboard]);

  // Deals filtered by attribute filters (search, SPAC, underwriter, counsel, unit coverage — BEFORE date interval)
  const attributeFilteredDeals = useMemo(() => {
    if (!dashboard) return [];
    const q = searchQuery.trim().toLowerCase();

    return dashboard.deals.filter((d) => {
      if (onlySPAC && !d.isSPAC) return false;
      if (selectedUnderwriter !== 'ALL' && !d.bookrunners.includes(selectedUnderwriter)) {
        return false;
      }
      if (selectedCounsel !== 'ALL') {
        const inIss = d.issuerCounsel.includes(selectedCounsel);
        const inUW = d.underwriterCounsel.includes(selectedCounsel);
        if (counselRoleFilter === 'ISSUER' && !inIss) return false;
        if (counselRoleFilter === 'UW' && !inUW) return false;
        if (counselRoleFilter === 'ANY' && !inIss && !inUW) return false;
      }
      if (selectedCoverage !== 'ALL' && d.warrantCoverage !== selectedCoverage) {
        return false;
      }
      if (!q) return true;

      return (
        d.companyName.toLowerCase().includes(q) ||
        d.fileNumber.toLowerCase().includes(q) ||
        d.cik.toLowerCase().includes(q) ||
        (d.proposedTicker?.toLowerCase().includes(q) ?? false) ||
        d.jurisdiction.toLowerCase().includes(q) ||
        d.bookrunners.some((b) => b.toLowerCase().includes(q)) ||
        d.issuerCounsel.some((c) => c.toLowerCase().includes(q)) ||
        d.underwriterCounsel.some((c) => c.toLowerCase().includes(q)) ||
        d.offshoreCounsel.some((c) => c.toLowerCase().includes(q)) ||
        d.counselPartners.some((p) => p.toLowerCase().includes(q))
      );
    });
  }, [
    dashboard,
    searchQuery,
    onlySPAC,
    selectedUnderwriter,
    selectedCounsel,
    counselRoleFilter,
    selectedCoverage,
  ]);

  // Full daily SEC business-day series (across the corpus span, respecting active underwriter/counsel/search filters)
  const dailySeries = useMemo(
    () => buildDailyBusinessSeries(attributeFilteredDeals, minCorpusDate, maxCorpusDate),
    [attributeFilteredDeals, minCorpusDate, maxCorpusDate]
  );

  const intervalASummary = useMemo(
    () => computeIntervalSummary(attributeFilteredDeals, intervalAStart, intervalAEnd),
    [attributeFilteredDeals, intervalAStart, intervalAEnd]
  );

  const intervalBSummary = useMemo(
    () =>
      compareEnabled
        ? computeIntervalSummary(attributeFilteredDeals, intervalBStart, intervalBEnd)
        : null,
    [compareEnabled, attributeFilteredDeals, intervalBStart, intervalBEnd]
  );

  // Deals shown in the lower charts & table (scoped to Interval 1 unless Compare Mode is comparing two windows across the full corpus)
  const filteredDeals = useMemo(() => {
    const [s, e] =
      intervalAStart <= intervalAEnd
        ? [intervalAStart, intervalAEnd]
        : [intervalAEnd, intervalAStart];

    if (compareEnabled) {
      const [bS, bE] =
        intervalBStart <= intervalBEnd
          ? [intervalBStart, intervalBEnd]
          : [intervalBEnd, intervalBStart];
      return attributeFilteredDeals.filter((d) => {
        const dt = dealAnchorDate(d);
        return (dt >= s && dt <= e) || (dt >= bS && dt <= bE);
      });
    }

    return attributeFilteredDeals.filter((d) => {
      const dt = dealAnchorDate(d);
      return dt >= s && dt <= e;
    });
  }, [
    attributeFilteredDeals,
    compareEnabled,
    intervalAStart,
    intervalAEnd,
    intervalBStart,
    intervalBEnd,
  ]);

  // Reset pagination to page 1 when filters change
  useEffect(() => {
    setCurrentPage(1);
  }, [
    searchQuery,
    onlySPAC,
    selectedYear,
    selectedUnderwriter,
    selectedCounsel,
    counselRoleFilter,
    selectedCoverage,
    intervalAStart,
    intervalAEnd,
    compareEnabled,
    intervalBStart,
    intervalBEnd,
  ]);

  const handleSelectYear = (yr: string) => {
    setSelectedYear(yr);
    setCompareEnabled(false);
    if (yr === 'ALL') {
      setIntervalAStart(minCorpusDate);
      setIntervalAEnd(maxCorpusDate);
    } else {
      const start = yr === '2020' ? minCorpusDate : `${yr}-01-01`;
      const end = yr === '2026' ? maxCorpusDate : `${yr}-12-31`;
      setIntervalAStart(start);
      setIntervalAEnd(end);
    }
  };

  const handleChangeIntervalA = (start: string, end: string) => {
    setIntervalAStart(start);
    setIntervalAEnd(end);
    if (start === minCorpusDate && end === maxCorpusDate) {
      setSelectedYear('ALL');
    } else if (start.slice(0, 4) === end.slice(0, 4) && start.endsWith('-01-01')) {
      setSelectedYear(start.slice(0, 4));
    } else {
      setSelectedYear('CUSTOM');
    }
  };

  const handleToggleCompare = (enabled: boolean) => {
    setCompareEnabled(enabled);
    if (enabled) {
      // If currently looking at the entire 2020-2026 range, default Interval 1 = 2021 vs Interval 2 = 2025–2026 so comparison is immediately meaningful
      if (intervalAStart === minCorpusDate && intervalAEnd === maxCorpusDate) {
        setIntervalAStart('2021-01-04');
        setIntervalAEnd('2021-12-31');
        setIntervalBStart('2025-01-02');
        setIntervalBEnd(maxCorpusDate);
        setSelectedYear('CUSTOM');
      }
    }
  };

  const sortedDeals = useMemo(() => {
    const factor = sortDirection === 'ascending' ? 1 : -1;
    return [...filteredDeals].sort((a, b) => {
      switch (sortKey) {
        case 'ipoProceedsUSD':
          return factor * ((a.ipoProceedsUSD ?? -1) - (b.ipoProceedsUSD ?? -1));
        case 'warrantCoverage':
          return factor * textCollator.compare(a.warrantCoverage, b.warrantCoverage);
        case 'exhibitCount':
          return factor * (a.exhibitCount - b.exhibitCount);
        case 'companyName':
          return factor * textCollator.compare(a.companyName, b.companyName);
        case 'latestFilingDate':
        default:
          return factor * textCollator.compare(a.latestFilingDate, b.latestFilingDate);
      }
    });
  }, [filteredDeals, sortKey, sortDirection]);

  const cohortAnalytics = useMemo(
    () => computeCohortAnalytics(filteredDeals),
    [filteredDeals]
  );

  const maxProceedsInView = useMemo(() => {
    let m = 500_000_000;
    for (const d of filteredDeals) {
      if ((d.ipoProceedsUSD ?? 0) > m) m = d.ipoProceedsUSD ?? m;
    }
    return m;
  }, [filteredDeals]);

  const totalPages = Math.max(1, Math.ceil(sortedDeals.length / PAGE_SIZE));
  const safePage = Math.min(currentPage, totalPages);
  const pageDeals = useMemo(() => {
    const start = (safePage - 1) * PAGE_SIZE;
    return sortedDeals.slice(start, start + PAGE_SIZE);
  }, [sortedDeals, safePage]);

  const selectedDeal: DealTrendRecord | null = useMemo(() => {
    if (!selectedDealKey || !dashboard) return null;
    return dashboard.deals.find((d) => d.dealKey === selectedDealKey) ?? null;
  }, [selectedDealKey, dashboard]);

  const handleSort = (key: SortKey, label: string) => {
    const nextDir: SortDirection =
      sortKey === key && sortDirection === 'ascending' ? 'descending' : 'ascending';
    setSortKey(key);
    setSortDirection(nextDir);
    setSortAnnouncement(`Sorted by ${label}, ${nextDir}, ${sortedDeals.length} filings`);
  };

  const isCustomInterval =
    intervalAStart !== minCorpusDate || intervalAEnd !== maxCorpusDate || compareEnabled;

  const hasActiveFilters =
    searchQuery.trim() !== '' ||
    onlySPAC ||
    isCustomInterval ||
    selectedUnderwriter !== 'ALL' ||
    selectedCounsel !== 'ALL' ||
    selectedCoverage !== 'ALL';

  const resetAllFilters = () => {
    setSearchQuery('');
    setOnlySPAC(false);
    setSelectedYear('ALL');
    setSelectedUnderwriter('ALL');
    setSelectedCounsel('ALL');
    setCounselRoleFilter('ANY');
    setSelectedCoverage('ALL');
    setCompareEnabled(false);
    setIntervalAStart(minCorpusDate);
    setIntervalAEnd(maxCorpusDate);
  };

  const availableYears = useMemo(() => {
    if (!dashboard) return [];
    return [...new Set(dashboard.deals.map((d) => String(d.filingYear)))].sort((a, b) =>
      b.localeCompare(a)
    );
  }, [dashboard]);

  const availableCoverages = useMemo(() => {
    if (!dashboard) return [];
    const counts = new Map<string, number>();
    for (const d of dashboard.deals) {
      counts.set(d.warrantCoverage, (counts.get(d.warrantCoverage) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1]);
  }, [dashboard]);

  return (
    <div className="min-h-screen bg-zinc-50 dark:bg-[#09090b] text-zinc-950 dark:text-zinc-50">
      {/* Visually hidden single sort announcer */}
      <div role="status" aria-live="polite" className="sr-status-live">
        {sortAnnouncement}
      </div>

      <div className="max-w-[1600px] mx-auto px-4 sm:px-6 py-6 space-y-5">
        {/* Header Row */}
        <header className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4 pb-2 border-b border-zinc-200 dark:border-zinc-800/80">
          <div className="space-y-1">
            <div className="text-[11px] font-mono uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              SEC Form S-1 &amp; S-1/A Filings (2020–2026)
            </div>
            <h1 className="text-2xl sm:text-3xl font-extrabold tracking-tight text-zinc-950 dark:text-zinc-50">
              EDGAR Deal &amp; Market Trends Observatory
            </h1>
          </div>

          <div className="flex flex-wrap items-center gap-2 self-start lg:self-center">
            <button
              type="button"
              onClick={() => setShowMethodologyModal(true)}
              className="inline-flex items-center gap-1.5 text-xs font-medium px-3 py-2 rounded-[8px] bg-white dark:bg-[#141418] hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 border border-zinc-200 dark:border-zinc-800 shadow-sm transition-colors"
            >
              <Scale className="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" />
              Methodology
            </button>
            <button
              type="button"
              onClick={() => setShowSchemaModal(true)}
              className="inline-flex items-center gap-1.5 text-xs font-medium px-3 py-2 rounded-[8px] bg-white dark:bg-[#141418] hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 border border-zinc-200 dark:border-zinc-800 shadow-sm transition-colors"
            >
              <Code2 className="w-3.5 h-3.5 text-emerald-600 dark:text-emerald-400" />
              Schema.org JSON-LD
            </button>
            <button
              type="button"
              onClick={toggleTheme}
              aria-label={isDark ? 'Switch to light theme' : 'Switch to dark theme'}
              title={isDark ? 'Switch to light theme' : 'Switch to dark theme'}
              className="p-2 rounded-[8px] bg-white dark:bg-[#141418] hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 border border-zinc-200 dark:border-zinc-800 shadow-sm transition-colors"
            >
              {isDark ? <Sun className="w-4 h-4 text-amber-400" /> : <Moon className="w-4 h-4" />}
            </button>
          </div>
        </header>

        {/* Extraction In-Progress Banner */}
        {dashboard?.status.isExtracting && (
          <div className="rounded-lg p-4 flex items-center gap-3 bg-blue-50 dark:bg-blue-950/30 border border-blue-200 dark:border-blue-800/40 text-blue-800 dark:text-blue-200 text-sm">
            <Loader2 className="w-4 h-4 animate-spin shrink-0" />
            <div>
              <span className="font-semibold">Cover-Page Extraction Active:</span>{' '}
              {dashboard.status.phase} ({dashboard.status.completedDeals.toLocaleString()} /{' '}
              {dashboard.status.totalDeals.toLocaleString()})
            </div>
          </div>
        )}

        {/* Error Banner */}
        {error && (
          <div className="rounded-lg p-4 flex items-center justify-between gap-3 bg-rose-50 dark:bg-rose-900/20 border border-rose-200 dark:border-rose-800/40 text-rose-800 dark:text-rose-200 text-sm">
            <div className="flex items-center gap-2.5">
              <AlertCircle className="w-4 h-4 shrink-0" />
              <span>{error}</span>
            </div>
            <button
              type="button"
              onClick={() => {
                setLoading(true);
                fetchDashboard();
              }}
              className="px-3 py-1.5 rounded-md bg-rose-600 hover:bg-rose-700 text-white text-xs font-medium transition-colors"
            >
              Retry
            </button>
          </div>
        )}

        {/* Loading Skeleton */}
        {loading && !dashboard ? (
          <div className="space-y-5">
            <div className="h-24 rounded-xl bg-zinc-200/70 dark:bg-zinc-900 animate-pulse border border-zinc-200 dark:border-zinc-800" />
            <div className="h-96 rounded-xl bg-zinc-200/70 dark:bg-zinc-900 animate-pulse border border-zinc-200 dark:border-zinc-800" />
          </div>
        ) : (
          dashboard && (
            <>
              {/* Filter Toolbar (`relative z-30` above `z-10` sticky table header) */}
              <section
                ref={toolbarRef}
                aria-label="Filter Form S-1 filings"
                className="relative z-30 bg-white dark:bg-[#0c0c0f] border border-zinc-200 dark:border-[#1e1e24] rounded-xl p-4 shadow-sm space-y-3"
              >
                <div className="grid grid-cols-1 md:grid-cols-12 gap-3 items-end">
                  {/* Search Input */}
                  <div className="md:col-span-4">
                    <label
                      htmlFor="observatory-search"
                      className="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1.5"
                    >
                      Search
                    </label>
                    <div className="relative">
                      <Search className="w-4 h-4 text-zinc-400 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none" />
                      <input
                        id="observatory-search"
                        type="text"
                        value={searchQuery}
                        onChange={(e) => setSearchQuery(e.target.value)}
                        placeholder="Issuer, 333- file no., ticker, underwriter, counsel, or partner…"
                        className="w-full bg-white dark:bg-[#09090b] border border-zinc-200 dark:border-zinc-800 rounded-[8px] pl-9 pr-8 py-[8px] text-sm shadow-sm focus:outline-none focus:ring-2 focus:ring-blue-500/50 focus:border-blue-500 text-zinc-950 dark:text-zinc-100 transition-all"
                      />
                      {searchQuery && (
                        <button
                          type="button"
                          onClick={() => setSearchQuery('')}
                          aria-label="Clear search"
                          className="absolute right-2.5 top-1/2 -translate-y-1/2 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
                        >
                          <X className="w-3.5 h-3.5" />
                        </button>
                      )}
                    </div>
                  </div>

                  {/* Year Dropdown */}
                  <div className="md:col-span-2 relative z-30">
                    <span className="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1.5">
                      Year
                    </span>
                    <button
                      type="button"
                      onClick={() => setOpenMenu(openMenu === 'year' ? null : 'year')}
                      className="w-full flex items-center justify-between gap-2 bg-white dark:bg-[#09090b] hover:bg-zinc-50 dark:hover:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-[8px] px-3 py-[8px] text-sm text-zinc-900 dark:text-zinc-100 shadow-sm transition-colors"
                    >
                      <span className="truncate font-mono text-xs">
                        {selectedYear === 'ALL'
                          ? 'All Years'
                          : selectedYear === 'CUSTOM'
                          ? 'Custom Range'
                          : selectedYear}
                      </span>
                      <ChevronDown className="w-4 h-4 text-zinc-400 shrink-0" />
                    </button>
                    {openMenu === 'year' && (
                      <div className="absolute left-0 right-0 mt-1.5 bg-white dark:bg-[#0c0c0f] shadow-xl border border-zinc-200 dark:border-zinc-800 rounded-[12px] py-1 max-h-64 overflow-y-auto z-40">
                        <button
                          type="button"
                          onClick={() => {
                            handleSelectYear('ALL');
                            setOpenMenu(null);
                          }}
                          className="w-full text-left px-3 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                        >
                          All Years
                        </button>
                        {availableYears.map((yr) => (
                          <button
                            key={yr}
                            type="button"
                            onClick={() => {
                              handleSelectYear(yr);
                              setOpenMenu(null);
                            }}
                            className="w-full text-left px-3 py-1.5 text-xs font-mono hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                          >
                            {yr}
                          </button>
                        ))}
                      </div>
                    )}
                  </div>

                  {/* Underwriter Dropdown */}
                  <div className="md:col-span-2 relative z-30">
                    <span className="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1.5">
                      Underwriter
                    </span>
                    <button
                      type="button"
                      onClick={() => setOpenMenu(openMenu === 'underwriter' ? null : 'underwriter')}
                      className="w-full flex items-center justify-between gap-2 bg-white dark:bg-[#09090b] hover:bg-zinc-50 dark:hover:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-[8px] px-3 py-[8px] text-sm text-zinc-900 dark:text-zinc-100 shadow-sm transition-colors"
                    >
                      <span className="truncate text-xs">
                        {selectedUnderwriter === 'ALL' ? 'All Underwriters' : selectedUnderwriter}
                      </span>
                      <ChevronDown className="w-4 h-4 text-zinc-400 shrink-0" />
                    </button>
                    {openMenu === 'underwriter' && (
                      <div className="absolute left-0 w-72 mt-1.5 bg-white dark:bg-[#0c0c0f] shadow-xl border border-zinc-200 dark:border-zinc-800 rounded-[12px] py-1 max-h-72 overflow-y-auto z-40">
                        <button
                          type="button"
                          onClick={() => {
                            setSelectedUnderwriter('ALL');
                            setOpenMenu(null);
                          }}
                          className="w-full text-left px-3 py-1.5 text-xs font-medium hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                        >
                          All Underwriters
                        </button>
                        {dashboard.bookrunnerLeague.slice(0, 50).map((b) => (
                          <button
                            key={b.name}
                            type="button"
                            onClick={() => {
                              setSelectedUnderwriter(b.name);
                              setOpenMenu(null);
                            }}
                            className="w-full flex items-center justify-between gap-2 px-3 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                          >
                            <span className="truncate">{b.name}</span>
                            <span className="font-mono text-[11px] text-zinc-400">
                              {b.dealCount}
                            </span>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>

                  {/* Counsel Dropdown */}
                  <div className="md:col-span-2 relative z-30">
                    <span className="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1.5">
                      Counsel
                    </span>
                    <button
                      type="button"
                      onClick={() => setOpenMenu(openMenu === 'counsel' ? null : 'counsel')}
                      className="w-full flex items-center justify-between gap-2 bg-white dark:bg-[#09090b] hover:bg-zinc-50 dark:hover:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-[8px] px-3 py-[8px] text-sm text-zinc-900 dark:text-zinc-100 shadow-sm transition-colors"
                    >
                      <span className="truncate text-xs">
                        {selectedCounsel === 'ALL' ? 'All Counsel' : selectedCounsel}
                      </span>
                      <ChevronDown className="w-4 h-4 text-zinc-400 shrink-0" />
                    </button>
                    {openMenu === 'counsel' && (
                      <div className="absolute right-0 w-80 mt-1.5 bg-white dark:bg-[#0c0c0f] shadow-xl border border-zinc-200 dark:border-zinc-800 rounded-[12px] py-1.5 max-h-80 overflow-y-auto z-40">
                        <div className="px-3 pb-1.5 mb-1 border-b border-zinc-100 dark:border-zinc-800 flex items-center gap-1">
                          {(['ANY', 'ISSUER', 'UW'] as const).map((role) => (
                            <button
                              key={role}
                              type="button"
                              onClick={() => setCounselRoleFilter(role)}
                              className={`text-[11px] px-2 py-0.5 rounded font-medium ${
                                counselRoleFilter === role
                                  ? 'bg-blue-600 text-white'
                                  : 'bg-zinc-100 dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300'
                              }`}
                            >
                              {role === 'ANY'
                                ? 'Any Role'
                                : role === 'ISSUER'
                                ? 'Issuer Only'
                                : 'Underwriter Only'}
                            </button>
                          ))}
                        </div>
                        <button
                          type="button"
                          onClick={() => {
                            setSelectedCounsel('ALL');
                            setOpenMenu(null);
                          }}
                          className="w-full text-left px-3 py-1.5 text-xs font-medium hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                        >
                          All Counsel
                        </button>
                        {dashboard.counselLeague.slice(0, 50).map((c) => (
                          <button
                            key={c.name}
                            type="button"
                            onClick={() => {
                              setSelectedCounsel(c.name);
                              setOpenMenu(null);
                            }}
                            className="w-full flex items-center justify-between gap-2 px-3 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                          >
                            <span className="truncate">{c.name}</span>
                            <span className="font-mono text-[11px] text-zinc-400">
                              {c.dealCount}
                            </span>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>

                  {/* Unit Coverage Dropdown */}
                  <div className="md:col-span-2 relative z-30">
                    <span className="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1.5">
                      Unit Coverage
                    </span>
                    <button
                      type="button"
                      onClick={() => setOpenMenu(openMenu === 'coverage' ? null : 'coverage')}
                      className="w-full flex items-center justify-between gap-2 bg-white dark:bg-[#09090b] hover:bg-zinc-50 dark:hover:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-[8px] px-3 py-[8px] text-sm text-zinc-900 dark:text-zinc-100 shadow-sm transition-colors"
                    >
                      <span className="truncate text-xs">
                        {selectedCoverage === 'ALL' ? 'All Coverage' : selectedCoverage}
                      </span>
                      <ChevronDown className="w-4 h-4 text-zinc-400 shrink-0" />
                    </button>
                    {openMenu === 'coverage' && (
                      <div className="absolute right-0 w-64 mt-1.5 bg-white dark:bg-[#0c0c0f] shadow-xl border border-zinc-200 dark:border-zinc-800 rounded-[12px] py-1 max-h-72 overflow-y-auto z-40">
                        <button
                          type="button"
                          onClick={() => {
                            setSelectedCoverage('ALL');
                            setOpenMenu(null);
                          }}
                          className="w-full text-left px-3 py-1.5 text-xs font-medium hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                        >
                          All Unit Coverage
                        </button>
                        {availableCoverages.map(([label, cnt]) => (
                          <button
                            key={label}
                            type="button"
                            onClick={() => {
                              setSelectedCoverage(label);
                              setOpenMenu(null);
                            }}
                            className="w-full flex items-center justify-between gap-2 px-3 py-1.5 text-xs hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200"
                          >
                            <span className="truncate">{label}</span>
                            <span className="font-mono text-[11px] text-zinc-400">{cnt}</span>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                </div>

                {/* Quick Filter Row + CSV Export */}
                <div className="flex flex-wrap items-center justify-between gap-2 pt-2 border-t border-zinc-100 dark:border-zinc-800/80">
                  <div className="flex flex-wrap items-center gap-1.5">
                    <button
                      type="button"
                      onClick={() => setOnlySPAC(!onlySPAC)}
                      className={`text-xs px-2.5 py-1 rounded-md border transition-colors ${
                        onlySPAC
                          ? 'bg-blue-600 text-white border-blue-600'
                          : 'bg-zinc-50 dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border-zinc-200 dark:border-zinc-800 hover:bg-zinc-100 dark:hover:bg-zinc-800'
                      }`}
                    >
                      SPACs Only (SIC 6770)
                    </button>
                    <button
                      type="button"
                      onClick={() =>
                        setSelectedCoverage(
                          selectedCoverage === 'Share Right Only' ? 'ALL' : 'Share Right Only'
                        )
                      }
                      className={`text-xs px-2.5 py-1 rounded-md border transition-colors ${
                        selectedCoverage === 'Share Right Only'
                          ? 'bg-blue-600 text-white border-blue-600'
                          : 'bg-zinc-50 dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border-zinc-200 dark:border-zinc-800 hover:bg-zinc-100 dark:hover:bg-zinc-800'
                      }`}
                    >
                      Share Right Only
                    </button>
                    <button
                      type="button"
                      onClick={() =>
                        setSelectedCoverage(
                          selectedCoverage === 'Share Only (No Warrant)'
                            ? 'ALL'
                            : 'Share Only (No Warrant)'
                        )
                      }
                      className={`text-xs px-2.5 py-1 rounded-md border transition-colors ${
                        selectedCoverage === 'Share Only (No Warrant)'
                          ? 'bg-blue-600 text-white border-blue-600'
                          : 'bg-zinc-50 dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border-zinc-200 dark:border-zinc-800 hover:bg-zinc-100 dark:hover:bg-zinc-800'
                      }`}
                    >
                      Share Only (No Warrant)
                    </button>
                  </div>

                  <div className="flex items-center gap-2">
                    {hasActiveFilters && (
                      <button
                        type="button"
                        onClick={resetAllFilters}
                        className="inline-flex items-center gap-1 text-xs font-medium px-2.5 py-1.5 rounded-[8px] text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-950/40 transition-colors"
                      >
                        <RotateCcw className="w-3.5 h-3.5" />
                        Reset Filters
                      </button>
                    )}
                    <button
                      type="button"
                      disabled={sortedDeals.length === 0}
                      onClick={() => downloadDealsCSV(sortedDeals)}
                      className="inline-flex items-center gap-1.5 text-xs font-medium px-3 py-1.5 rounded-[8px] bg-white dark:bg-[#262626] hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-800 dark:text-zinc-200 border border-zinc-200 dark:border-zinc-700 shadow-sm transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      <Download className="w-3.5 h-3.5" />
                      Export CSV ({sortedDeals.length.toLocaleString()})
                    </button>
                  </div>
                </div>
              </section>

              {/* Analytical Charts Suite */}
              <AnalyticsCharts
                isDark={isDark}
                dailySeries={dailySeries}
                benchmarks={benchmarks}
                minCorpusDate={minCorpusDate}
                maxCorpusDate={maxCorpusDate}
                intervalAStart={intervalAStart}
                intervalAEnd={intervalAEnd}
                intervalASummary={intervalASummary}
                compareEnabled={compareEnabled}
                intervalBStart={intervalBStart}
                intervalBEnd={intervalBEnd}
                intervalBSummary={intervalBSummary}
                onChangeIntervalA={handleChangeIntervalA}
                onToggleCompare={handleToggleCompare}
                onChangeIntervalB={(s, e) => {
                  setIntervalBStart(s);
                  setIntervalBEnd(e);
                }}
                annual={cohortAnalytics.annual}
                underwriters={cohortAnalytics.bookrunners}
                counsel={cohortAnalytics.counsel}
                selectedUnderwriter={selectedUnderwriter}
                selectedCounsel={selectedCounsel}
                selectedCoverage={selectedCoverage}
                onSelectUnderwriter={setSelectedUnderwriter}
                onSelectCounsel={setSelectedCounsel}
                onSelectCoverage={setSelectedCoverage}
              />

              {/* Main Content Split: Filings Table (`w-full` -> `lg:w-2/3`) + Side Panel (`lg:w-1/3`) */}
              <section className="flex flex-col lg:flex-row items-start gap-5">
                <div
                  className={`w-full ${
                    selectedDeal ? 'lg:w-2/3' : 'lg:w-full'
                  } transition-all duration-300 bg-white dark:bg-[#0c0c0f] border border-zinc-200 dark:border-[#1e1e24] rounded-[12px] overflow-hidden shadow-sm`}
                >
                  {/* Table Header Bar */}
                  <div className="px-4 py-3.5 border-b border-zinc-200 dark:border-zinc-800 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
                    <div>
                      <h2 className="text-base font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
                        Form S-1 Filings — Click Any Row to View Cover Page &amp; Exhibits
                      </h2>
                      <p className="text-xs text-zinc-500 dark:text-zinc-400">
                        Showing{' '}
                        <span className="font-mono font-medium text-zinc-800 dark:text-zinc-200">
                          {sortedDeals.length === 0
                            ? 0
                            : (safePage - 1) * PAGE_SIZE + 1}
                          –{Math.min(safePage * PAGE_SIZE, sortedDeals.length)}
                        </span>{' '}
                        of{' '}
                        <span className="font-mono font-medium text-zinc-800 dark:text-zinc-200">
                          {sortedDeals.length.toLocaleString()}
                        </span>{' '}
                        offerings
                      </p>
                    </div>
                  </div>

                  {/* Responsive + Accessible Sortable Table Wrapper */}
                  <div
                    tabIndex={0}
                    role="region"
                    aria-labelledby="deals-table-caption"
                    className="table-wrapper"
                  >
                    <table className="deals-table text-left text-xs">
                      <caption id="deals-table-caption" className="sr-only">
                        Form S-1 and S-1/A filings from 2020 through 2026 with cover-page terms and exhibits
                      </caption>
                      <thead className="bg-zinc-100 dark:bg-zinc-900 text-zinc-500 dark:text-zinc-400 border-b border-zinc-200 dark:border-zinc-800">
                        <tr>
                          <th
                            scope="col"
                            data-type="text"
                            aria-sort={sortKey === 'companyName' ? sortDirection : undefined}
                            className="font-semibold border-b border-zinc-200 dark:border-zinc-800"
                          >
                            <button
                              type="button"
                              onClick={() => handleSort('companyName', 'Issuer')}
                            >
                              <span>Issuer / File No.</span>
                              <ArrowUpDown aria-hidden="true" className="w-3.5 h-3.5 sort-glyph shrink-0" />
                            </button>
                          </th>

                          <th
                            scope="col"
                            data-type="text"
                            aria-sort={sortKey === 'latestFilingDate' ? sortDirection : undefined}
                            className="font-semibold border-b border-zinc-200 dark:border-zinc-800"
                          >
                            <button
                              type="button"
                              onClick={() => handleSort('latestFilingDate', 'Filing Date')}
                            >
                              <span>Filing Date</span>
                              <ArrowUpDown aria-hidden="true" className="w-3.5 h-3.5 sort-glyph shrink-0" />
                            </button>
                          </th>

                          <th
                            scope="col"
                            data-type="number"
                            aria-sort={sortKey === 'ipoProceedsUSD' ? sortDirection : undefined}
                            className="font-semibold border-b border-zinc-200 dark:border-zinc-800"
                          >
                            <button
                              type="button"
                              onClick={() => handleSort('ipoProceedsUSD', 'Gross Proceeds')}
                            >
                              <span>Gross Proceeds</span>
                              <ArrowUpDown aria-hidden="true" className="w-3.5 h-3.5 sort-glyph shrink-0" />
                            </button>
                          </th>

                          <th
                            scope="col"
                            className="font-semibold border-b border-zinc-200 dark:border-zinc-800"
                          >
                            Underwriter(s)
                          </th>

                          <th
                            scope="col"
                            className="font-semibold border-b border-zinc-200 dark:border-zinc-800"
                          >
                            Counsel (Issuer / UW)
                          </th>

                          <th
                            scope="col"
                            data-type="text"
                            aria-sort={sortKey === 'warrantCoverage' ? sortDirection : undefined}
                            className="font-semibold border-b border-zinc-200 dark:border-zinc-800"
                          >
                            <button
                              type="button"
                              onClick={() => handleSort('warrantCoverage', 'Unit Coverage')}
                            >
                              <span>Unit Coverage</span>
                              <ArrowUpDown aria-hidden="true" className="w-3.5 h-3.5 sort-glyph shrink-0" />
                            </button>
                          </th>

                          <th
                            scope="col"
                            data-type="number"
                            aria-sort={sortKey === 'exhibitCount' ? sortDirection : undefined}
                            className="font-semibold border-b border-zinc-200 dark:border-zinc-800"
                          >
                            <button
                              type="button"
                              onClick={() => handleSort('exhibitCount', 'Exhibits')}
                            >
                              <span>Exhibits</span>
                              <ArrowUpDown aria-hidden="true" className="w-3.5 h-3.5 sort-glyph shrink-0" />
                            </button>
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        {pageDeals.map((d) => {
                          const isSelected = d.dealKey === selectedDealKey;
                          const pctWidth = d.ipoProceedsUSD
                            ? Math.min(100, Math.max(4, Math.round((d.ipoProceedsUSD / maxProceedsInView) * 100)))
                            : 0;

                          return (
                            <tr
                              key={d.dealKey}
                              onClick={() =>
                                setSelectedDealKey(isSelected ? null : d.dealKey)
                              }
                              className={`cursor-pointer transition-colors ${
                                isSelected
                                  ? 'bg-blue-50 dark:bg-blue-900/40 hover:bg-blue-100 dark:hover:bg-blue-900/60'
                                  : 'text-zinc-900 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800/70'
                              }`}
                            >
                              <th
                                scope="row"
                                className={`py-3 px-3.5 font-normal text-left border-b border-zinc-100 dark:border-zinc-800/80 ${
                                  isSelected
                                    ? 'bg-blue-50 dark:bg-[#13203b]'
                                    : 'bg-white dark:bg-[#0c0c0f]'
                                }`}
                              >
                                <div className="font-semibold text-zinc-950 dark:text-zinc-50 leading-snug">
                                  {d.companyName}
                                </div>
                                <div className="flex flex-wrap items-center gap-1.5 mt-1">
                                  <span className="font-mono text-[11px] text-zinc-500 bg-zinc-100 dark:bg-zinc-800 rounded px-1.5 py-0.2">
                                    {d.fileNumber}
                                  </span>
                                  {d.proposedTicker && (
                                    <span className="font-mono text-[11px] font-medium text-blue-600 dark:text-blue-400">
                                      {d.proposedTicker}
                                    </span>
                                  )}
                                  <span className="text-[11px] text-zinc-400">
                                    {d.jurisdiction}
                                  </span>
                                </div>
                              </th>

                              <td
                                data-value={d.latestFilingDate}
                                className="py-3 px-3.5 border-b border-zinc-100 dark:border-zinc-800/80 whitespace-nowrap"
                              >
                                <div className="font-medium text-zinc-900 dark:text-zinc-100">
                                  {formatFilingDate(d.latestFilingDate)}
                                </div>
                                <div className="font-mono text-[11px] text-zinc-500 dark:text-zinc-400 mt-0.5">
                                  {d.submissionCount} {d.submissionCount === 1 ? 'filing' : 'filings'}
                                </div>
                              </td>

                              <td
                                data-value={d.ipoProceedsUSD ?? -1}
                                className="py-3 px-3.5 border-b border-zinc-100 dark:border-zinc-800/80 whitespace-nowrap"
                              >
                                <div className="font-mono font-semibold text-zinc-950 dark:text-zinc-50">
                                  {formatCompactUSD(d.ipoProceedsUSD)}
                                </div>
                                {d.ipoProceedsUSD ? (
                                  <div className="mt-1 space-y-0.5">
                                    <div className="w-24 h-1.5 bg-zinc-200 dark:bg-zinc-700 rounded-sm overflow-hidden">
                                      <div
                                        className="h-full bg-emerald-500 rounded-sm"
                                        style={{ width: `${pctWidth}%` }}
                                      />
                                    </div>
                                    {d.unitCount && (
                                      <div className="font-mono text-[10px] text-zinc-500">
                                        {formatUnits(d.unitCount)}
                                      </div>
                                    )}
                                  </div>
                                ) : (
                                  <span className="text-[11px] text-zinc-400">Draft / TBD</span>
                                )}
                              </td>

                              <td className="py-3 px-3.5 border-b border-zinc-100 dark:border-zinc-800/80 max-w-[190px]">
                                {d.bookrunners.length > 0 ? (
                                  <div>
                                    <div className="font-medium text-zinc-900 dark:text-zinc-100 truncate">
                                      {d.bookrunners[0]}
                                    </div>
                                    {d.bookrunners.length > 1 && (
                                      <div className="text-[11px] text-zinc-500 truncate">
                                        +{d.bookrunners.length - 1} more
                                      </div>
                                    )}
                                  </div>
                                ) : (
                                  <span className="text-zinc-400">—</span>
                                )}
                              </td>

                              <td className="py-3 px-3.5 border-b border-zinc-100 dark:border-zinc-800/80 max-w-[240px]">
                                <div className="space-y-0.5">
                                  {d.issuerCounsel.length > 0 && (
                                    <div className="truncate text-[11px]">
                                      <span className="font-mono text-[10px] text-blue-600 dark:text-blue-400 mr-1">
                                        ISS
                                      </span>
                                      <span className="text-zinc-700 dark:text-zinc-300">
                                        {d.issuerCounsel[0]}
                                      </span>
                                    </div>
                                  )}
                                  {d.underwriterCounsel.length > 0 && (
                                    <div className="truncate text-[11px]">
                                      <span className="font-mono text-[10px] text-emerald-600 dark:text-emerald-400 mr-1">
                                        UW
                                      </span>
                                      <span className="text-zinc-700 dark:text-zinc-300">
                                        {d.underwriterCounsel[0]}
                                      </span>
                                    </div>
                                  )}
                                  {d.issuerCounsel.length === 0 &&
                                    d.underwriterCounsel.length === 0 && (
                                      <span className="text-zinc-400">—</span>
                                    )}
                                </div>
                              </td>

                              <td
                                data-value={d.warrantCoverage}
                                className="py-3 px-3.5 border-b border-zinc-100 dark:border-zinc-800/80 whitespace-nowrap"
                              >
                                <div className="font-medium text-zinc-900 dark:text-zinc-100">
                                  {d.warrantCoverage}
                                </div>
                                {d.exchange && (
                                  <div className="font-mono text-[11px] text-zinc-500 dark:text-zinc-400 mt-0.5">
                                    {d.exchange}
                                  </div>
                                )}
                              </td>

                              <td
                                data-value={d.exhibitCount}
                                className="py-3 px-3.5 border-b border-zinc-100 dark:border-zinc-800/80 whitespace-nowrap"
                              >
                                <span className="inline-flex items-center font-mono text-xs font-medium px-2 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-800 dark:text-zinc-200">
                                  {d.exhibitCount}
                                </span>
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>

                  {/* Pagination Controls */}
                  <div className="px-4 py-3 border-t border-zinc-200 dark:border-zinc-800 flex items-center justify-between">
                    <span className="text-xs font-mono text-zinc-500 dark:text-zinc-400">
                      Page {safePage} of {totalPages}
                    </span>
                    <div className="flex items-center gap-1.5">
                      <button
                        type="button"
                        aria-label="First page"
                        disabled={safePage <= 1}
                        onClick={() => setCurrentPage(1)}
                        className="p-1.5 rounded-[8px] border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        <ChevronsLeft className="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        aria-label="Previous page"
                        disabled={safePage <= 1}
                        onClick={() => setCurrentPage((p) => Math.max(1, p - 1))}
                        className="p-1.5 rounded-[8px] border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        <ChevronLeft className="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        aria-label="Next page"
                        disabled={safePage >= totalPages}
                        onClick={() => setCurrentPage((p) => Math.min(totalPages, p + 1))}
                        className="p-1.5 rounded-[8px] border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        <ChevronRight className="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        aria-label="Last page"
                        disabled={safePage >= totalPages}
                        onClick={() => setCurrentPage(totalPages)}
                        className="p-1.5 rounded-[8px] border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        <ChevronsRight className="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                </div>

                {/* Side Panel (`w-1/3`) */}
                {selectedDeal && (
                  <div className="w-full lg:w-1/3 transition-all duration-300 lg:sticky lg:top-4">
                    <ProofSidePanel
                      deal={selectedDeal}
                      onClose={() => setSelectedDealKey(null)}
                      onFilterByCounsel={(firm) => setSelectedCounsel(firm)}
                      onFilterByUnderwriter={(bank) => setSelectedUnderwriter(bank)}
                      onFilterBySearch={(term) => setSearchQuery(term)}
                    />
                  </div>
                )}
              </section>
            </>
          )
        )}

        {/* Schema.org JSON-LD Modal */}
        {showSchemaModal && dashboard && (
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="schema-modal-title"
            className="fixed inset-0 z-50 bg-zinc-950/60 backdrop-blur-sm flex items-center justify-center p-4"
            onClick={() => setShowSchemaModal(false)}
          >
            <div
              className="bg-white dark:bg-[#0c0c0f] rounded-[12px] border border-zinc-200 dark:border-zinc-800 shadow-xl w-full max-w-2xl p-6 space-y-4"
              onClick={(e) => e.stopPropagation()}
            >
              <div className="flex items-center justify-between">
                <h2 id="schema-modal-title" className="text-lg font-bold text-zinc-950 dark:text-zinc-50">
                  Schema.org Dataset Metadata (JSON-LD)
                </h2>
                <button
                  type="button"
                  aria-label="Close modal"
                  onClick={() => setShowSchemaModal(false)}
                  className="p-1.5 rounded-lg text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>
              <p className="text-xs text-zinc-600 dark:text-zinc-400">
                Embedded in <span className="font-mono">&lt;head&gt;</span> and served at{' '}
                <a
                  href="/schema/dataset.jsonld"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="font-mono text-blue-600 dark:text-blue-400 hover:underline"
                >
                  /schema/dataset.jsonld
                </a>
                :
              </p>
              <pre className="bg-zinc-950 text-zinc-100 p-4 rounded-lg text-xs font-mono overflow-x-auto max-h-80 border border-zinc-800">
                {document.getElementById('dataset-jsonld')?.textContent}
              </pre>
            </div>
          </div>
        )}

        {/* Methodology Modal */}
        {showMethodologyModal && (
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="methodology-modal-title"
            className="fixed inset-0 z-50 bg-zinc-950/60 backdrop-blur-sm flex items-center justify-center p-4"
            onClick={() => setShowMethodologyModal(false)}
          >
            <div
              className="bg-white dark:bg-[#0c0c0f] rounded-[12px] border border-zinc-200 dark:border-zinc-800 shadow-xl w-full max-w-2xl p-6 space-y-4"
              onClick={(e) => e.stopPropagation()}
            >
              <div className="flex items-center justify-between">
                <h2 id="methodology-modal-title" className="text-lg font-bold text-zinc-950 dark:text-zinc-50">
                  Methodology
                </h2>
                <button
                  type="button"
                  aria-label="Close modal"
                  onClick={() => setShowMethodologyModal(false)}
                  className="p-1.5 rounded-lg text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>
              <div className="space-y-3 text-xs leading-relaxed text-zinc-600 dark:text-zinc-300">
                <p>
                  All metrics are parsed directly from SEC Form S-1 and S-1/A HTML filings (`2020–2026`):
                </p>
                <ul className="list-disc pl-5 space-y-1.5">
                  <li>
                    <strong>Registration Grouping (`333-`):</strong> Amendments (`S-1/A`) are grouped with
                    their parent registration statement by SEC File Number (`333-XXXXXX`) using{' '}
                    <span className="font-mono">data.sec.gov/submissions</span> so proceeds are never
                    double-counted across pre-effective amendments, and exhibit-only amendments inherit the
                    most recent full cover page under the same file number.
                  </li>
                  <li>
                    <strong>SEC Business-Day Calendar:</strong> Daily series exclude Saturdays, Sundays, and
                    observed U.S. Federal / SEC EDGAR holidays.
                  </li>
                  <li>
                    <strong>Counsel &amp; Underwriters:</strong> Counsel and named partners are parsed from
                    the Facing Page <span className="font-mono">&ldquo;Copies to:&rdquo;</span> block;
                    underwriters and unit coverage are parsed from the Prospectus Cover Page.
                  </li>
                </ul>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
