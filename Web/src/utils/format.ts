import { Temporal as PolyfillTemporal } from 'temporal-polyfill';
import type {
  DealTrendRecord,
  QuarterlyTrendPoint,
  AnnualStructurePoint,
  LeagueTableEntry,
} from '../types';

// Use native Temporal when available, falling back to temporal-polyfill (Safari / older engines)
const TemporalAPI: typeof PolyfillTemporal =
  (globalThis as unknown as { Temporal?: typeof PolyfillTemporal }).Temporal ??
  PolyfillTemporal;

const MONTH_SHORT = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const DOW_SHORT = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

export const CHART_COLORS = [
  '#3b82f6',
  '#10b981',
  '#f59e0b',
  '#ef4444',
  '#8b5cf6',
  '#ec4899',
  '#06b6d4',
  '#84cc16',
  '#f97316',
  '#6366f1',
];

export function parsePlainDateSafe(isoDate?: string | null): PolyfillTemporal.PlainDate | null {
  if (!isoDate || !/^\d{4}-\d{2}-\d{2}$/.test(isoDate)) return null;
  try {
    return TemporalAPI.PlainDate.from(isoDate);
  } catch {
    return null;
  }
}

/**
 * Formats a YYYY-MM-DD calendar date without time-zone conversion drift.
 */
export function formatFilingDate(isoDate?: string | null): string {
  const pd = parsePlainDateSafe(isoDate);
  if (!pd) return isoDate || '—';
  const mon = MONTH_SHORT[pd.month - 1] ?? '';
  const dd = String(pd.day).padStart(2, '0');
  return `${mon} ${dd}, ${pd.year}`;
}

export function formatDayOfWeek(isoDate: string): string {
  const pd = parsePlainDateSafe(isoDate);
  if (!pd) return '';
  return DOW_SHORT[pd.dayOfWeek] ?? '';
}

export function addDaysISO(isoDate: string, days: number): string {
  const pd = parsePlainDateSafe(isoDate);
  if (!pd) return isoDate;
  return pd.add({ days }).toString();
}

export function compareISODates(a: string, b: string): number {
  const pa = parsePlainDateSafe(a);
  const pb = parsePlainDateSafe(b);
  if (pa && pb) return TemporalAPI.PlainDate.compare(pa, pb);
  return a.localeCompare(b);
}

export function formatCompactUSD(amount?: number | null): string {
  if (amount === null || amount === undefined || amount <= 0) return '—';
  if (amount >= 1_000_000_000) {
    return `$${(amount / 1_000_000_000).toFixed(2)}B`;
  }
  if (amount >= 1_000_000) {
    const m = amount / 1_000_000;
    return `$${m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)}M`;
  }
  return `$${Math.round(amount).toLocaleString()}`;
}

export function formatExactUSD(amount?: number | null): string {
  if (amount === null || amount === undefined || amount <= 0) return '—';
  return `$${amount.toLocaleString()}`;
}

export function formatUnits(units?: number | null): string {
  if (units === null || units === undefined || units <= 0) return '—';
  if (units >= 1_000_000) {
    const m = units / 1_000_000;
    return `${m % 1 === 0 ? m.toFixed(1) : m.toFixed(2)}M units`;
  }
  return `${units.toLocaleString()} units`;
}

// --- SEC EDGAR Official Federal Holiday Calendar (Observed Dates) ---

function nthWeekdayOfMonth(
  year: number,
  month: number,
  targetDayOfWeek: number, // 1=Mon .. 7=Sun
  nth: number
): PolyfillTemporal.PlainDate {
  const first = TemporalAPI.PlainDate.from({ year, month, day: 1 });
  const offset = (targetDayOfWeek - first.dayOfWeek + 7) % 7;
  return first.add({ days: offset + (nth - 1) * 7 });
}

function lastWeekdayOfMonth(
  year: number,
  month: number,
  targetDayOfWeek: number
): PolyfillTemporal.PlainDate {
  const ym = TemporalAPI.PlainYearMonth.from({ year, month, calendar: 'iso8601' });
  const last = ym.toPlainDate({ day: ym.daysInMonth });
  const back = (last.dayOfWeek - targetDayOfWeek + 7) % 7;
  return last.subtract({ days: back });
}

function observedFixedHoliday(
  month: number,
  day: number,
  year: number
): PolyfillTemporal.PlainDate {
  const md = TemporalAPI.PlainMonthDay.from({ month, day, calendar: 'iso8601' });
  const date = md.toPlainDate({ year });
  if (date.dayOfWeek === 6) return date.subtract({ days: 1 }); // Saturday -> Friday
  if (date.dayOfWeek === 7) return date.add({ days: 1 }); // Sunday -> Monday
  return date;
}

const holidayCache = new Map<number, Set<string>>();

export function getSECHolidaysForYear(year: number): Set<string> {
  const cached = holidayCache.get(year);
  if (cached) return cached;

  const set = new Set<string>();
  // Fixed federal holidays (with Saturday->Friday and Sunday->Monday observance)
  set.add(observedFixedHoliday(1, 1, year).toString()); // New Year's Day
  if (year >= 2021) {
    set.add(observedFixedHoliday(6, 19, year).toString()); // Juneteenth (enacted June 2021)
  }
  set.add(observedFixedHoliday(7, 4, year).toString()); // Independence Day
  set.add(observedFixedHoliday(11, 11, year).toString()); // Veterans Day
  set.add(observedFixedHoliday(12, 25, year).toString()); // Christmas Day

  // If Jan 1 of next year falls on Saturday, Dec 31 of `year` is the observed federal holiday
  const nextNY = observedFixedHoliday(1, 1, year + 1);
  if (nextNY.year === year) {
    set.add(nextNY.toString());
  }

  // Floating Monday / Thursday federal holidays
  set.add(nthWeekdayOfMonth(year, 1, 1, 3).toString()); // MLK Jr. Day (3rd Mon Jan)
  set.add(nthWeekdayOfMonth(year, 2, 1, 3).toString()); // Washington's Birthday (3rd Mon Feb)
  set.add(lastWeekdayOfMonth(year, 5, 1).toString()); // Memorial Day (Last Mon May)
  set.add(nthWeekdayOfMonth(year, 9, 1, 1).toString()); // Labor Day (1st Mon Sep)
  set.add(nthWeekdayOfMonth(year, 10, 1, 2).toString()); // Columbus Day (2nd Mon Oct)
  set.add(nthWeekdayOfMonth(year, 11, 4, 4).toString()); // Thanksgiving Day (4th Thu Nov)

  holidayCache.set(year, set);
  return set;
}

export function isSECBusinessDay(pd: PolyfillTemporal.PlainDate): boolean {
  if (pd.dayOfWeek >= 6) return false; // Saturday (6) or Sunday (7)
  return !getSECHolidaysForYear(pd.year).has(pd.toString());
}

export interface DailyBusinessPoint {
  date: string; // YYYY-MM-DD
  filingCount: number; // 333- registrations anchored on this date
  submissionVolume: number; // total S-1 + S-1/A filings across those registrations
  proceedsUSD: number;
}

export function dealAnchorDate(d: DealTrendRecord): string {
  return d.earliestFilingDate || d.latestFilingDate;
}

/**
 * Builds a contiguous series of SEC EDGAR business days (excluding weekends & federal holidays)
 * across `[minISO, maxISO]` and aggregates daily filing counts and gross proceeds.
 */
export function buildDailyBusinessSeries(
  deals: DealTrendRecord[],
  minISO?: string,
  maxISO?: string
): DailyBusinessPoint[] {
  if (deals.length === 0) return [];

  let earliest = minISO ?? '';
  let latest = maxISO ?? '';
  const byDate = new Map<
    string,
    { filingCount: number; submissionVolume: number; proceedsUSD: number }
  >();

  for (const d of deals) {
    const dt = dealAnchorDate(d);
    if (!dt || !/^\d{4}-\d{2}-\d{2}$/.test(dt)) continue;
    if (!earliest || dt < earliest) earliest = dt;
    if (!latest || dt > latest) latest = dt;

    const cur = byDate.get(dt) ?? { filingCount: 0, submissionVolume: 0, proceedsUSD: 0 };
    cur.filingCount += 1;
    cur.submissionVolume += d.submissionCount;
    cur.proceedsUSD += d.ipoProceedsUSD ?? 0;
    byDate.set(dt, cur);
  }

  const startPD = parsePlainDateSafe(minISO || earliest);
  const endPD = parsePlainDateSafe(maxISO || latest);
  if (!startPD || !endPD || TemporalAPI.PlainDate.compare(startPD, endPD) > 0) {
    return [];
  }

  const points: DailyBusinessPoint[] = [];
  let cursor = startPD;
  while (TemporalAPI.PlainDate.compare(cursor, endPD) <= 0) {
    const iso = cursor.toString();
    const bucket = byDate.get(iso);
    // Include every official SEC business day (plus any rare weekend/holiday EDGAR acceptance so totals reconcile 100%)
    if (isSECBusinessDay(cursor) || bucket) {
      points.push({
        date: iso,
        filingCount: bucket?.filingCount ?? 0,
        submissionVolume: bucket?.submissionVolume ?? 0,
        proceedsUSD: bucket?.proceedsUSD ?? 0,
      });
    }
    cursor = cursor.add({ days: 1 });
  }

  return points;
}

export interface IntervalSummary {
  startDate: string;
  endDate: string;
  businessDays: number;
  dealCount: number;
  totalSubmissions: number;
  dealsPerBusinessDay: number;
  pricedDealCount: number;
  aggregateProceedsUSD: number;
  proceedsPerBusinessDayUSD: number;
  medianProceedsUSD: number;
  meanProceedsUSD: number;
  wholeWarrantPct: number;
  fractionalWarrantPct: number;
  shareRightPct: number;
  noWarrantPct: number;
  impliedUnitOverhangPct: number;
  topUnderwriters: { name: string; count: number; proceedsUSD: number }[];
  topCounsel: { name: string; count: number; proceedsUSD: number }[];
}

function unitOverhangRatio(coverage: string): number | null {
  switch (coverage) {
    case '1 Whole Warrant':
      return 1.0;
    case '3/4 Warrant':
      return 0.75;
    case '1/2 Warrant':
      return 0.5;
    case '1/3 Warrant':
      return 1 / 3;
    case '1/4 Warrant':
      return 0.25;
    case '1/5 or Less Warrant':
      return 0.167;
    case 'Share Right Only':
      return 0.1; // standard 1/10 share right
    case 'Share Right + Warrant':
      return 0.6;
    case 'Share Only (No Warrant)':
      return 0.0;
    default:
      return null;
  }
}

export function computeIntervalSummary(
  deals: DealTrendRecord[],
  startISO: string,
  endISO: string
): IntervalSummary {
  const [normStart, normEnd] =
    compareISODates(startISO, endISO) <= 0 ? [startISO, endISO] : [endISO, startISO];

  // Count SEC business days in [normStart, normEnd]
  let businessDays = 0;
  const startPD = parsePlainDateSafe(normStart);
  const endPD = parsePlainDateSafe(normEnd);
  if (startPD && endPD) {
    let cur = startPD;
    while (TemporalAPI.PlainDate.compare(cur, endPD) <= 0) {
      if (isSECBusinessDay(cur)) businessDays += 1;
      cur = cur.add({ days: 1 });
    }
  }
  const safeBizDays = Math.max(1, businessDays);

  const inWindow = deals.filter((d) => {
    const dt = dealAnchorDate(d);
    return dt >= normStart && dt <= normEnd;
  });

  let aggregateProceedsUSD = 0;
  let totalSubmissions = 0;
  const priced: number[] = [];

  let structuredUnitsTotal = 0;
  let wholeCnt = 0;
  let fracCnt = 0;
  let rightCnt = 0;
  let noWarrantCnt = 0;
  let overhangSum = 0;
  let overhangCnt = 0;

  const uwMap = new Map<string, { count: number; proceedsUSD: number }>();
  const counselMap = new Map<string, { count: number; proceedsUSD: number }>();

  for (const d of inWindow) {
    totalSubmissions += d.submissionCount;
    const p = d.ipoProceedsUSD ?? 0;
    if (p > 0) {
      aggregateProceedsUSD += p;
      priced.push(p);
    }

    const cov = d.warrantCoverage;
    if (cov !== 'Unspecified' && cov !== 'Common Stock / Direct IPO') {
      structuredUnitsTotal += 1;
      if (cov === '1 Whole Warrant' || cov === '3/4 Warrant') wholeCnt += 1;
      else if (
        cov === '1/2 Warrant' ||
        cov === '1/3 Warrant' ||
        cov === '1/4 Warrant' ||
        cov === '1/5 or Less Warrant' ||
        cov === 'Other Warrant Unit'
      ) {
        fracCnt += 1;
      } else if (cov === 'Share Right Only' || cov === 'Share Right + Warrant') {
        rightCnt += 1;
      } else if (cov === 'Share Only (No Warrant)') {
        noWarrantCnt += 1;
      }
    }

    const oh = unitOverhangRatio(cov);
    if (oh !== null) {
      overhangSum += oh * 100;
      overhangCnt += 1;
    }

    for (const bank of new Set(d.bookrunners)) {
      const cur = uwMap.get(bank) ?? { count: 0, proceedsUSD: 0 };
      cur.count += 1;
      cur.proceedsUSD += p;
      uwMap.set(bank, cur);
    }

    const firms = new Set([...d.issuerCounsel, ...d.underwriterCounsel]);
    for (const firm of firms) {
      const cur = counselMap.get(firm) ?? { count: 0, proceedsUSD: 0 };
      cur.count += 1;
      cur.proceedsUSD += p;
      counselMap.set(firm, cur);
    }
  }

  priced.sort((a, b) => a - b);
  const medianProceedsUSD = priced.length > 0 ? priced[Math.floor(priced.length / 2)] : 0;
  const meanProceedsUSD = priced.length > 0 ? Math.round(aggregateProceedsUSD / priced.length) : 0;
  const pct = (n: number) =>
    structuredUnitsTotal > 0 ? Math.round((n / structuredUnitsTotal) * 1000) / 10 : 0;

  const topUnderwriters = [...uwMap.entries()]
    .map(([name, v]) => ({ name, ...v }))
    .sort((a, b) => b.count - a.count || b.proceedsUSD - a.proceedsUSD)
    .slice(0, 3);

  const topCounsel = [...counselMap.entries()]
    .map(([name, v]) => ({ name, ...v }))
    .sort((a, b) => b.count - a.count || b.proceedsUSD - a.proceedsUSD)
    .slice(0, 3);

  return {
    startDate: normStart,
    endDate: normEnd,
    businessDays,
    dealCount: inWindow.length,
    totalSubmissions,
    dealsPerBusinessDay: Math.round((inWindow.length / safeBizDays) * 100) / 100,
    pricedDealCount: priced.length,
    aggregateProceedsUSD,
    proceedsPerBusinessDayUSD: Math.round(aggregateProceedsUSD / safeBizDays),
    medianProceedsUSD,
    meanProceedsUSD,
    wholeWarrantPct: pct(wholeCnt),
    fractionalWarrantPct: pct(fracCnt),
    shareRightPct: pct(rightCnt),
    noWarrantPct: pct(noWarrantCnt),
    impliedUnitOverhangPct:
      overhangCnt > 0 ? Math.round((overhangSum / overhangCnt) * 10) / 10 : 0,
    topUnderwriters,
    topCounsel,
  };
}

export function computeCohortAnalytics(deals: DealTrendRecord[]): {
  quarterly: QuarterlyTrendPoint[];
  annual: AnnualStructurePoint[];
  bookrunners: LeagueTableEntry[];
  counsel: LeagueTableEntry[];
  aggregateProceedsUSD: number;
  medianProceedsUSD: number;
} {
  const byQuarter = new Map<string, DealTrendRecord[]>();
  const byYear = new Map<number, DealTrendRecord[]>();
  const bankMap = new Map<string, { deals: number; proceeds: number }>();
  const counselMap = new Map<
    string,
    { deals: number; proceeds: number; issuer: number; uw: number }
  >();

  let aggregateProceedsUSD = 0;
  const allPriced: number[] = [];

  for (const d of deals) {
    const p = d.ipoProceedsUSD ?? 0;
    if (p > 0) {
      aggregateProceedsUSD += p;
      allPriced.push(p);
    }

    const qList = byQuarter.get(d.filingQuarter) ?? [];
    qList.push(d);
    byQuarter.set(d.filingQuarter, qList);

    const yList = byYear.get(d.filingYear) ?? [];
    yList.push(d);
    byYear.set(d.filingYear, yList);

    for (const b of new Set(d.bookrunners)) {
      const cur = bankMap.get(b) ?? { deals: 0, proceeds: 0 };
      cur.deals += 1;
      cur.proceeds += p;
      bankMap.set(b, cur);
    }

    const issSet = new Set(d.issuerCounsel);
    const uwSet = new Set(d.underwriterCounsel);
    for (const firm of new Set([...issSet, ...uwSet])) {
      const cur = counselMap.get(firm) ?? { deals: 0, proceeds: 0, issuer: 0, uw: 0 };
      cur.deals += 1;
      cur.proceeds += p;
      if (issSet.has(firm)) cur.issuer += 1;
      if (uwSet.has(firm)) cur.uw += 1;
      counselMap.set(firm, cur);
    }
  }

  allPriced.sort((a, b) => a - b);
  const medianProceedsUSD =
    allPriced.length > 0 ? allPriced[Math.floor(allPriced.length / 2)] : 0;

  const quarterly: QuarterlyTrendPoint[] = [...byQuarter.keys()].sort().map((quarter) => {
    const list = byQuarter.get(quarter) ?? [];
    const priced = list
      .map((x) => x.ipoProceedsUSD ?? 0)
      .filter((x) => x > 0)
      .sort((a, b) => a - b);
    const totalP = priced.reduce((acc, v) => acc + v, 0);
    const medP = priced.length > 0 ? priced[Math.floor(priced.length / 2)] : 0;
    return {
      quarter,
      dealCount: list.length,
      spacDealCount: list.filter((x) => x.isSPAC).length,
      pricedDealCount: priced.length,
      totalProceedsUSD: totalP,
      medianProceedsUSD: medP,
      overfundedSharePct: 0,
    };
  });

  const annual: AnnualStructurePoint[] = [...byYear.keys()]
    .sort((a, b) => a - b)
    .map((year) => {
      const list = byYear.get(year) ?? [];
      const buckets: Record<string, number> = {};
      let wSum = 0;
      let wCnt = 0;
      for (const d of list) {
        buckets[d.warrantCoverage] = (buckets[d.warrantCoverage] ?? 0) + 1;
        if (d.combinationWindowMonths) {
          wSum += d.combinationWindowMonths;
          wCnt += 1;
        }
      }
      return {
        year,
        dealCount: list.length,
        buckets,
        overfundedCount: 0,
        trustObservedCount: 0,
        avgCombinationMonths: wCnt > 0 ? Math.round((wSum / wCnt) * 10) / 10 : null,
      };
    });

  const bookrunners: LeagueTableEntry[] = [...bankMap.entries()]
    .map(([name, st]) => ({
      name,
      dealCount: st.deals,
      totalProceedsUSD: st.proceeds,
      issuerRoleCount: 0,
      underwriterRoleCount: st.deals,
    }))
    .sort((a, b) => b.dealCount - a.dealCount || b.totalProceedsUSD - a.totalProceedsUSD);

  const counsel: LeagueTableEntry[] = [...counselMap.entries()]
    .map(([name, st]) => ({
      name,
      dealCount: st.deals,
      totalProceedsUSD: st.proceeds,
      issuerRoleCount: st.issuer,
      underwriterRoleCount: st.uw,
    }))
    .sort((a, b) => b.dealCount - a.dealCount || b.totalProceedsUSD - a.totalProceedsUSD);

  return {
    quarterly,
    annual,
    bookrunners,
    counsel,
    aggregateProceedsUSD,
    medianProceedsUSD,
  };
}

export function downloadDealsCSV(deals: DealTrendRecord[]): void {
  const headers = [
    'File Number',
    'CIK',
    'Company Name',
    'SIC',
    'Jurisdiction',
    'Initial S-1 Date',
    'Latest Filing Date',
    'Gross IPO Proceeds (USD)',
    'Over-Allotment Proceeds (USD)',
    'Unit Count',
    'Underwriters',
    'Issuer Counsel',
    'Underwriter Counsel',
    'Offshore Counsel',
    'Named Counsel Partners',
    'Unit Coverage',
    'Exchange',
    'Ticker',
    'Filings',
    'Exhibits',
    'SEC Archive URL',
  ];

  const escapeCell = (v: unknown): string => {
    if (v === null || v === undefined) return '';
    const str = String(v);
    if (str.includes(',') || str.includes('"') || str.includes('\n')) {
      return `"${str.replace(/"/g, '""')}"`;
    }
    return str;
  };

  const rows = deals.map((d) =>
    [
      d.fileNumber,
      d.cik,
      d.companyName,
      d.sic,
      d.jurisdiction,
      d.earliestFilingDate,
      d.latestFilingDate,
      d.ipoProceedsUSD ?? '',
      d.overAllotmentProceedsUSD ?? '',
      d.unitCount ?? '',
      d.bookrunners.join('; '),
      d.issuerCounsel.join('; '),
      d.underwriterCounsel.join('; '),
      d.offshoreCounsel.join('; '),
      d.counselPartners.join('; '),
      d.warrantCoverage,
      d.exchange ?? '',
      d.proposedTicker ?? '',
      d.submissionCount,
      d.exhibitCount,
      d.secArchiveURL,
    ]
      .map(escapeCell)
      .join(',')
  );

  const csvContent = [headers.join(','), ...rows].join('\n');
  const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `edgar-s1-filings-${deals.length}.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
