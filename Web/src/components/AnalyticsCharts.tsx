import { useState, useMemo } from 'react';
import ReactECharts from 'echarts-for-react';
import { Calendar, Plus, X } from 'lucide-react';
import type {
  AnnualStructurePoint,
  LeagueTableEntry,
} from '../types';
import {
  CHART_COLORS,
  formatCompactUSD,
  formatDayOfWeek,
  formatFilingDate,
  type DailyBusinessPoint,
  type IntervalSummary,
} from '../utils/format';
import {
  BENCHMARK_CATALOG,
  computeBenchmarkIntervalStats,
  formatBenchmarkDelta,
  formatBenchmarkValue,
  getBenchmarkValue,
  type BenchmarkKey,
  type MarketBenchmarksPayload,
  type OverlayScaleGroup,
} from '../utils/benchmarks';

interface AnalyticsChartsProps {
  isDark: boolean;
  dailySeries: DailyBusinessPoint[];
  benchmarks: MarketBenchmarksPayload | null;
  minCorpusDate: string;
  maxCorpusDate: string;
  intervalAStart: string;
  intervalAEnd: string;
  intervalASummary: IntervalSummary;
  compareEnabled: boolean;
  intervalBStart: string;
  intervalBEnd: string;
  intervalBSummary: IntervalSummary | null;
  onChangeIntervalA: (start: string, end: string) => void;
  onToggleCompare: (enabled: boolean) => void;
  onChangeIntervalB: (start: string, end: string) => void;
  annual: AnnualStructurePoint[];
  underwriters: LeagueTableEntry[];
  counsel: LeagueTableEntry[];
  selectedUnderwriter: string;
  selectedCounsel: string;
  selectedCoverage: string;
  onSelectUnderwriter: (bank: string) => void;
  onSelectCounsel: (firm: string) => void;
  onSelectCoverage: (coverage: string) => void;
}

const COVERAGE_SERIES: { key: string; label: string; color: string }[] = [
  { key: '1 Whole Warrant', label: '1 Whole Warrant', color: '#f59e0b' },
  { key: '3/4 Warrant', label: '3/4 Warrant', color: '#f97316' },
  { key: '1/2 Warrant', label: '1/2 Warrant', color: '#3b82f6' },
  { key: '1/3 Warrant', label: '1/3 Warrant', color: '#06b6d4' },
  { key: '1/4 Warrant', label: '1/4 Warrant', color: '#8b5cf6' },
  { key: '1/5 or Less Warrant', label: '≤1/5 Warrant', color: '#6366f1' },
  { key: 'Share Right Only', label: 'Share Right Only', color: '#10b981' },
  { key: 'Share Right + Warrant', label: 'Right + Warrant', color: '#84cc16' },
  { key: 'Share Only (No Warrant)', label: 'Share Only (No Warrant)', color: '#ec4899' },
];

const OVERLAY_CATEGORIES: Array<
  'Equity & Vol' | 'Repo & Funding' | 'Treasury' | 'Agency'
> = ['Equity & Vol', 'Repo & Funding', 'Treasury', 'Agency'];

interface QuickPreset {
  label: string;
  start: string;
  end: string;
}

function findNearestDateOnOrAfter(dates: string[], target: string): string {
  for (const d of dates) {
    if (d >= target) return d;
  }
  return dates[dates.length - 1] ?? target;
}

function findNearestDateOnOrBefore(dates: string[], target: string): string {
  for (let i = dates.length - 1; i >= 0; i -= 1) {
    if (dates[i] <= target) return dates[i];
  }
  return dates[0] ?? target;
}

function formatSignedPctDelta(bVal: number, aVal: number, suffix = '%'): string {
  const diff = bVal - aVal;
  if (Math.abs(diff) < 0.05) return '0.0' + suffix;
  return `${diff > 0 ? '+' : ''}${diff.toFixed(1)}${suffix}`;
}

function formatRatioChange(bVal: number, aVal: number): string {
  if (aVal <= 0 && bVal <= 0) return '—';
  if (aVal <= 0) return 'New';
  const pct = ((bVal - aVal) / aVal) * 100;
  return `${pct >= 0 ? '+' : ''}${pct.toFixed(1)}%`;
}

function scaleAxisHeader(group: OverlayScaleGroup): { name: string; fmt: (v: number) => string } {
  switch (group) {
    case 'ratePct':
      return { name: 'Rate / Yield (%)', fmt: (v) => `${v}%` };
    case 'vix':
      return { name: 'VIX', fmt: (v) => `${v}` };
    case 'spx':
      return { name: 'SPX', fmt: (v) => v.toLocaleString() };
    case 'ixic':
      return { name: 'Nasdaq', fmt: (v) => v.toLocaleString() };
    case 'spreadBps':
      return { name: 'Spread (bps)', fmt: (v) => `${v}bp` };
  }
}

export function AnalyticsCharts({
  isDark,
  dailySeries,
  benchmarks,
  minCorpusDate,
  maxCorpusDate,
  intervalAStart,
  intervalAEnd,
  intervalASummary,
  compareEnabled,
  intervalBStart,
  intervalBEnd,
  intervalBSummary,
  onChangeIntervalA,
  onToggleCompare,
  onChangeIntervalB,
  annual,
  underwriters,
  counsel,
  selectedUnderwriter,
  selectedCounsel,
  selectedCoverage,
  onSelectUnderwriter,
  onSelectCounsel,
  onSelectCoverage,
}: AnalyticsChartsProps) {
  const [dailyMetric, setDailyMetric] = useState<'filings' | 'proceeds'>('proceeds');
  const [activeOverlays, setActiveOverlays] = useState<BenchmarkKey[]>([]);
  const [coverageMode, setCoverageMode] = useState<'share' | 'count'>('share');
  const [leagueMode, setLeagueMode] = useState<'counsel' | 'underwriters'>('counsel');
  const [leagueMetric, setLeagueMetric] = useState<'deals' | 'proceeds'>('deals');

  const axisColor = isDark ? '#a1a1aa' : '#52525b';
  const splitLineColor = isDark ? '#1e1e24' : '#f4f4f5';
  const tooltipStyle = useMemo(
    () => ({
      backgroundColor: isDark ? 'rgba(12, 12, 15, 0.96)' : 'rgba(255, 255, 255, 0.96)',
      borderColor: isDark ? '#27272a' : '#e4e4e7',
      textStyle: {
        color: isDark ? '#fafafa' : '#09090b',
        fontFamily: '"DM Sans", sans-serif',
        fontSize: 12,
      },
    }),
    [isDark]
  );

  const fieldIndexMap = useMemo(() => {
    const m = new Map<BenchmarkKey, number>();
    if (benchmarks?.fields) {
      benchmarks.fields.forEach((f, idx) => m.set(f, idx));
    }
    return m;
  }, [benchmarks]);

  const activeOverlayMetas = useMemo(
    () => BENCHMARK_CATALOG.filter((item) => activeOverlays.includes(item.key)),
    [activeOverlays]
  );

  const toggleOverlay = (key: BenchmarkKey) => {
    setActiveOverlays((prev) =>
      prev.includes(key) ? prev.filter((k) => k !== key) : [...prev, key]
    );
  };

  const presets: QuickPreset[] = useMemo(
    () => [
      { label: 'All', start: minCorpusDate, end: maxCorpusDate },
      { label: '2020', start: '2020-01-02', end: '2020-12-31' },
      { label: '2021', start: '2021-01-04', end: '2021-12-31' },
      { label: '2022–2023', start: '2022-01-03', end: '2023-12-29' },
      { label: '2024', start: '2024-01-02', end: '2024-12-31' },
      { label: '2025', start: '2025-01-02', end: '2025-12-31' },
      { label: '2026 YTD', start: '2026-01-02', end: maxCorpusDate },
    ],
    [minCorpusDate, maxCorpusDate]
  );

  const dates = useMemo(() => dailySeries.map((p) => p.date), [dailySeries]);

  const intervalADates = useMemo(
    () =>
      dates.filter(
        (dt) => dt >= intervalASummary.startDate && dt <= intervalASummary.endDate
      ),
    [dates, intervalASummary.startDate, intervalASummary.endDate]
  );

  const intervalBDates = useMemo(
    () =>
      intervalBSummary
        ? dates.filter(
            (dt) => dt >= intervalBSummary.startDate && dt <= intervalBSummary.endDate
          )
        : [],
    [dates, intervalBSummary]
  );

  const overlayStatsA = useMemo(
    () =>
      activeOverlayMetas.map((meta) =>
        computeBenchmarkIntervalStats(benchmarks, fieldIndexMap, intervalADates, meta)
      ),
    [activeOverlayMetas, benchmarks, fieldIndexMap, intervalADates]
  );

  const overlayStatsB = useMemo(
    () =>
      compareEnabled && intervalBSummary
        ? activeOverlayMetas.map((meta) =>
            computeBenchmarkIntervalStats(benchmarks, fieldIndexMap, intervalBDates, meta)
          )
        : [],
    [compareEnabled, intervalBSummary, activeOverlayMetas, benchmarks, fieldIndexMap, intervalBDates]
  );

  // Chart 1: Daily SEC Business-Day Filings / Gross Proceeds + Multi-Asset Overlays
  const dailyOption = useMemo(() => {
    const values = dailySeries.map((p) =>
      dailyMetric === 'proceeds'
        ? Number((p.proceedsUSD / 1_000_000).toFixed(2))
        : p.filingCount
    );

    const markAreas: Array<[Record<string, unknown>, Record<string, unknown>]> = [];
    if (dates.length > 0 && compareEnabled && intervalBSummary) {
      const a0 = findNearestDateOnOrAfter(dates, intervalASummary.startDate);
      const a1 = findNearestDateOnOrBefore(dates, intervalASummary.endDate);
      if (a0 <= a1) {
        markAreas.push([
          {
            name: 'Interval 1',
            xAxis: a0,
            itemStyle: { color: isDark ? 'rgba(59, 130, 246, 0.16)' : 'rgba(37, 99, 235, 0.12)' },
            label: { color: '#3b82f6', fontWeight: 600, fontSize: 11, position: 'insideTopLeft' },
          },
          { xAxis: a1 },
        ]);
      }

      const b0 = findNearestDateOnOrAfter(dates, intervalBSummary.startDate);
      const b1 = findNearestDateOnOrBefore(dates, intervalBSummary.endDate);
      if (b0 <= b1) {
        markAreas.push([
          {
            name: 'Interval 2',
            xAxis: b0,
            itemStyle: { color: isDark ? 'rgba(16, 185, 129, 0.16)' : 'rgba(16, 185, 129, 0.13)' },
            label: { color: '#10b981', fontWeight: 600, fontSize: 11, position: 'insideTopLeft' },
          },
          { xAxis: b1 },
        ]);
      }
    }

    // Build dynamic right-hand Y-axes per active scale group so % rates share one scale while SPX / VIX / bps never squash one another
    const activeGroups: OverlayScaleGroup[] = [];
    for (const meta of activeOverlayMetas) {
      if (!activeGroups.includes(meta.scaleGroup)) {
        activeGroups.push(meta.scaleGroup);
      }
    }

    const groupToAxisIndex = new Map<OverlayScaleGroup, number>();
    const yAxes: Record<string, unknown>[] = [
      {
        type: 'value',
        name: dailyMetric === 'proceeds' ? 'Gross Proceeds ($M)' : 'S-1 Filings',
        nameTextStyle: { color: axisColor, fontSize: 11 },
        axisLabel: {
          color: axisColor,
          fontFamily: '"JetBrains Mono", monospace',
          formatter: dailyMetric === 'proceeds' ? '${value}M' : '{value}',
        },
        splitLine: { lineStyle: { color: splitLineColor } },
      },
    ];

    activeGroups.forEach((grp, idx) => {
      const axisIndex = idx + 1;
      groupToAxisIndex.set(grp, axisIndex);
      const header = scaleAxisHeader(grp);
      // Display ticks for the primary right-hand scale group; secondary scale groups auto-fit cleanly without overlapping right labels
      const showRightTicks = idx === 0;
      yAxes.push({
        type: 'value',
        position: 'right',
        scale: grp !== 'ratePct',
        show: showRightTicks,
        name: showRightTicks ? header.name : '',
        nameTextStyle: { color: axisColor, fontSize: 11 },
        axisLabel: {
          color: axisColor,
          fontFamily: '"JetBrains Mono", monospace',
          formatter: header.fmt,
        },
        splitLine: { show: false },
      });
    });

    const overlayLineSeries = activeOverlayMetas.map((meta) => ({
      name: meta.shortLabel,
      type: 'line',
      yAxisIndex: groupToAxisIndex.get(meta.scaleGroup) ?? 1,
      showSymbol: false,
      connectNulls: true,
      lineStyle: {
        width: 1.9,
        color: meta.color,
        type: meta.dashed ? 'dashed' : 'solid',
      },
      itemStyle: { color: meta.color },
      data: dates.map((dt) => getBenchmarkValue(benchmarks, fieldIndexMap, dt, meta.key)),
    }));

    const zoomStartValue = compareEnabled
      ? dates[0]
      : findNearestDateOnOrAfter(dates, intervalAStart);
    const zoomEndValue = compareEnabled
      ? dates[dates.length - 1]
      : findNearestDateOnOrBefore(dates, intervalAEnd);

    return {
      color: CHART_COLORS,
      textStyle: { fontFamily: '"DM Sans", sans-serif' },
      tooltip: {
        trigger: 'axis',
        axisPointer: { type: 'cross' },
        ...tooltipStyle,
        formatter: (params: Array<{ dataIndex: number }>) => {
          if (!params.length) return '';
          const pt = dailySeries[params[0].dataIndex];
          if (!pt) return '';
          const dow = formatDayOfWeek(pt.date);
          let html = `<div style="font-weight:600;margin-bottom:4px">${dow}, ${formatFilingDate(pt.date)}</div>
            <div>Initial S-1 Filings: <b>${pt.filingCount}</b> (${pt.submissionVolume} w/ S-1/A)</div>
            <div>Gross Proceeds: <b>${pt.proceedsUSD > 0 ? formatCompactUSD(pt.proceedsUSD) : '$0'}</b></div>`;
          if (activeOverlayMetas.length > 0) {
            html += `<div style="margin-top:5px;padding-top:5px;border-top:1px solid ${isDark ? '#27272a' : '#e4e4e7'}">`;
            for (const meta of activeOverlayMetas) {
              const v = getBenchmarkValue(benchmarks, fieldIndexMap, pt.date, meta.key);
              html += `<div style="display:flex;justify-content:space-between;gap:14px">
                <span style="color:${meta.color}">● ${meta.shortLabel}</span>
                <b style="font-family:'JetBrains Mono',monospace">${formatBenchmarkValue(v, meta.unit)}</b>
              </div>`;
            }
            html += `</div>`;
          }
          return html;
        },
      },
      legend:
        activeOverlayMetas.length > 0
          ? {
              top: 0,
              right: 0,
              textStyle: { color: axisColor, fontSize: 11.5 },
            }
          : undefined,
      grid: {
        left: 60,
        right: activeGroups.length > 0 ? 64 : 24,
        top: activeOverlayMetas.length > 0 ? 34 : 20,
        bottom: 72,
      },
      xAxis: {
        type: 'category',
        data: dates,
        axisLabel: {
          color: axisColor,
          fontFamily: '"JetBrains Mono", monospace',
          fontSize: 11,
          formatter: (val: string) => val.slice(0, 7),
        },
        axisLine: { lineStyle: { color: splitLineColor } },
      },
      yAxis: yAxes,
      dataZoom: [
        {
          type: 'inside',
          startValue: zoomStartValue,
          endValue: zoomEndValue,
          zoomLock: false,
        },
        {
          type: 'slider',
          height: 26,
          bottom: 14,
          startValue: zoomStartValue,
          endValue: zoomEndValue,
          borderColor: isDark ? '#27272a' : '#e4e4e7',
          fillerColor: isDark ? 'rgba(59, 130, 246, 0.22)' : 'rgba(37, 99, 235, 0.15)',
          handleStyle: { color: '#3b82f6' },
          textStyle: { color: axisColor, fontFamily: '"JetBrains Mono", monospace', fontSize: 10 },
        },
      ],
      series: [
        {
          name: dailyMetric === 'proceeds' ? 'Gross Proceeds ($M)' : 'S-1 Filings',
          type: 'bar',
          yAxisIndex: 0,
          large: true,
          barMaxWidth: 10,
          itemStyle: {
            color: dailyMetric === 'proceeds' ? '#3b82f6' : '#10b981',
            opacity: activeOverlayMetas.length > 0 ? 0.55 : 0.92,
          },
          data: values,
          markArea: markAreas.length > 0 ? { silent: true, data: markAreas } : undefined,
        },
        ...overlayLineSeries,
      ],
    };
  }, [
    dailySeries,
    dates,
    dailyMetric,
    activeOverlayMetas,
    benchmarks,
    fieldIndexMap,
    compareEnabled,
    intervalAStart,
    intervalAEnd,
    intervalASummary.startDate,
    intervalASummary.endDate,
    intervalBSummary,
    axisColor,
    splitLineColor,
    tooltipStyle,
    isDark,
  ]);

  // Chart 2: Unit Coverage by Year (2020–2026)
  const coverageOption = useMemo(() => {
    const years = annual.map((a) => String(a.year));
    const totalsByYear = annual.map((a) =>
      COVERAGE_SERIES.reduce((acc, s) => acc + (a.buckets[s.key] ?? 0), 0)
    );

    const barSeries = COVERAGE_SERIES.map((s) => ({
      name: s.label,
      type: 'bar',
      stack: 'coverage',
      barMaxWidth: 52,
      emphasis: { focus: 'series' },
      itemStyle: {
        color: s.color,
        opacity:
          selectedCoverage === 'ALL' || selectedCoverage === s.key ? 0.95 : 0.28,
      },
      data: annual.map((a, idx) => {
        const raw = a.buckets[s.key] ?? 0;
        if (coverageMode === 'count') return raw;
        const denom = totalsByYear[idx] || 1;
        return Number(((raw / denom) * 100).toFixed(1));
      }),
    }));

    return {
      textStyle: { fontFamily: '"DM Sans", sans-serif' },
      tooltip: {
        trigger: 'axis',
        axisPointer: { type: 'shadow' },
        ...tooltipStyle,
      },
      legend: {
        top: 0,
        left: 0,
        textStyle: { color: axisColor, fontSize: 11.5 },
        itemWidth: 12,
        itemHeight: 10,
      },
      grid: { left: 54, right: 24, top: 52, bottom: 30 },
      xAxis: {
        type: 'category',
        data: years,
        axisLabel: {
          color: axisColor,
          fontFamily: '"JetBrains Mono", monospace',
          fontWeight: 600,
        },
        axisLine: { lineStyle: { color: splitLineColor } },
      },
      yAxis: {
        type: 'value',
        max: coverageMode === 'share' ? 100 : undefined,
        name: coverageMode === 'share' ? 'Share of Offerings (%)' : 'Offerings',
        nameTextStyle: { color: axisColor, fontSize: 11 },
        axisLabel: {
          color: axisColor,
          fontFamily: '"JetBrains Mono", monospace',
          formatter: coverageMode === 'share' ? '{value}%' : '{value}',
        },
        splitLine: { lineStyle: { color: splitLineColor } },
      },
      series: barSeries,
    };
  }, [annual, coverageMode, selectedCoverage, axisColor, splitLineColor, tooltipStyle]);

  // Chart 3: Counsel & Underwriters
  const leagueOption = useMemo(() => {
    const source = leagueMode === 'counsel' ? counsel : underwriters;
    const sorted = [...source]
      .sort((a, b) =>
        leagueMetric === 'proceeds'
          ? b.totalProceedsUSD - a.totalProceedsUSD || b.dealCount - a.dealCount
          : b.dealCount - a.dealCount || b.totalProceedsUSD - a.totalProceedsUSD
      )
      .slice(0, 14)
      .reverse();

    const labels = sorted.map((x) => x.name);

    if (leagueMode === 'counsel' && leagueMetric === 'deals') {
      return {
        textStyle: { fontFamily: '"DM Sans", sans-serif' },
        tooltip: {
          trigger: 'axis',
          axisPointer: { type: 'shadow' },
          ...tooltipStyle,
          formatter: (params: Array<{ seriesName: string; value: number; dataIndex: number }>) => {
            if (!params.length) return '';
            const row = sorted[params[0].dataIndex];
            return `<div style="font-weight:600;margin-bottom:4px">${row.name}</div>
              <div>Total Filings: <b>${row.dealCount}</b> (${formatCompactUSD(row.totalProceedsUSD)})</div>
              <div style="color:#3b82f6">Issuer Counsel: <b>${row.issuerRoleCount}</b></div>
              <div style="color:#10b981">Underwriter Counsel: <b>${row.underwriterRoleCount}</b></div>`;
          },
        },
        legend: {
          top: 0,
          right: 0,
          textStyle: { color: axisColor, fontSize: 12 },
        },
        grid: { left: 250, right: 36, top: 34, bottom: 28 },
        xAxis: {
          type: 'value',
          axisLabel: { color: axisColor, fontFamily: '"JetBrains Mono", monospace' },
          splitLine: { lineStyle: { color: splitLineColor } },
        },
        yAxis: {
          type: 'category',
          data: labels,
          axisLabel: { color: axisColor, fontSize: 11.5 },
          axisLine: { lineStyle: { color: splitLineColor } },
        },
        series: [
          {
            name: 'Issuer Counsel',
            type: 'bar',
            stack: 'mandates',
            barMaxWidth: 18,
            itemStyle: { color: '#3b82f6' },
            data: sorted.map((x) => x.issuerRoleCount),
          },
          {
            name: 'Underwriter Counsel',
            type: 'bar',
            stack: 'mandates',
            barMaxWidth: 18,
            itemStyle: { color: '#10b981', borderRadius: [0, 4, 4, 0] },
            data: sorted.map((x) => x.underwriterRoleCount),
          },
        ],
      };
    }

    const values = sorted.map((x) =>
      leagueMetric === 'proceeds'
        ? Number((x.totalProceedsUSD / 1_000_000_000).toFixed(2))
        : x.dealCount
    );

    return {
      textStyle: { fontFamily: '"DM Sans", sans-serif' },
      tooltip: {
        trigger: 'axis',
        axisPointer: { type: 'shadow' },
        ...tooltipStyle,
        formatter: (params: Array<{ dataIndex: number }>) => {
          if (!params.length) return '';
          const row = sorted[params[0].dataIndex];
          return `<div style="font-weight:600;margin-bottom:4px">${row.name}</div>
            <div>Aggregate Gross Proceeds: <b>${formatCompactUSD(row.totalProceedsUSD)}</b></div>
            <div>Offerings: <b>${row.dealCount}</b></div>`;
        },
      },
      grid: { left: 250, right: 44, top: 20, bottom: 28 },
      xAxis: {
        type: 'value',
        axisLabel: {
          color: axisColor,
          fontFamily: '"JetBrains Mono", monospace',
          formatter: leagueMetric === 'proceeds' ? '${value}B' : '{value}',
        },
        splitLine: { lineStyle: { color: splitLineColor } },
      },
      yAxis: {
        type: 'category',
        data: labels,
        axisLabel: { color: axisColor, fontSize: 11.5 },
        axisLine: { lineStyle: { color: splitLineColor } },
      },
      series: [
        {
          name: leagueMetric === 'proceeds' ? 'Gross Proceeds ($B)' : 'Offerings',
          type: 'bar',
          barMaxWidth: 18,
          itemStyle: {
            borderRadius: [0, 4, 4, 0],
            color: (p: { name: string }) => {
              const active =
                leagueMode === 'counsel' ? selectedCounsel : selectedUnderwriter;
              if (active !== 'ALL' && p.name === active) return '#f59e0b';
              return leagueMode === 'counsel' ? '#6366f1' : '#2563eb';
            },
          },
          data: values,
        },
      ],
    };
  }, [
    leagueMode,
    leagueMetric,
    counsel,
    underwriters,
    selectedCounsel,
    selectedUnderwriter,
    axisColor,
    splitLineColor,
    tooltipStyle,
  ]);

  const handleDataZoom = (evt: {
    start?: number;
    end?: number;
    batch?: Array<{ start?: number; end?: number }>;
  }) => {
    if (compareEnabled || dates.length === 0) return;
    const z = evt.batch?.[0] ?? evt;
    if (typeof z.start !== 'number' || typeof z.end !== 'number') return;
    const sIdx = Math.max(
      0,
      Math.min(dates.length - 1, Math.round((z.start / 100) * (dates.length - 1)))
    );
    const eIdx = Math.max(
      sIdx,
      Math.min(dates.length - 1, Math.round((z.end / 100) * (dates.length - 1)))
    );
    const nextS = dates[sIdx];
    const nextE = dates[eIdx];
    if (nextS && nextE && (nextS !== intervalAStart || nextE !== intervalAEnd)) {
      onChangeIntervalA(nextS, nextE);
    }
  };

  return (
    <div className="grid grid-cols-1 gap-5">
      {/* Chart 1: Daily SEC Business-Day Filings & Gross Proceeds + Market/Rate Overlays */}
      <section className="containment-section bg-white dark:bg-[#0c0c0f] rounded-xl border border-zinc-200 dark:border-[#1e1e24] shadow-sm p-5 space-y-4">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
              Daily Form S-1 Filings &amp; Gross Proceeds (SEC Business Days, Excl. Weekends &amp; Federal Holidays)
            </h2>
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Select a date range, toggle market &amp; rate overlays below, or add a second interval to compare periods side by side.
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-2 self-start">
            <div className="bg-zinc-100 dark:bg-zinc-900 p-1 rounded-[8px] flex items-center text-xs font-medium border border-zinc-200/70 dark:border-zinc-800">
              <button
                type="button"
                onClick={() => setDailyMetric('proceeds')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  dailyMetric === 'proceeds'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                Daily Gross Proceeds
              </button>
              <button
                type="button"
                onClick={() => setDailyMetric('filings')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  dailyMetric === 'filings'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                Daily Filings
              </button>
            </div>

            {!compareEnabled ? (
              <button
                type="button"
                onClick={() => onToggleCompare(true)}
                className="inline-flex items-center gap-1.5 text-xs font-medium px-3 py-1.5 rounded-[8px] bg-[#2563eb] hover:bg-blue-700 text-white shadow-sm transition-colors"
              >
                <Plus className="w-3.5 h-3.5" />
                Add Second Interval
              </button>
            ) : (
              <button
                type="button"
                onClick={() => onToggleCompare(false)}
                className="inline-flex items-center gap-1.5 text-xs font-medium px-3 py-1.5 rounded-[8px] bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 text-zinc-800 dark:text-zinc-200 border border-zinc-200 dark:border-zinc-700 transition-colors"
              >
                <X className="w-3.5 h-3.5" />
                Clear Second Interval
              </button>
            )}
          </div>
        </div>

        {/* Market, Repo, Treasury & Agency Overlay Selector Strip */}
        <div className="rounded-lg px-3 py-2.5 bg-zinc-50/90 dark:bg-zinc-900/50 border border-zinc-200/80 dark:border-zinc-800/90 space-y-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <span className="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
              Overlay Market Indices &amp; Rates (FRED / NY Fed Daily)
            </span>
            {activeOverlays.length > 0 && (
              <button
                type="button"
                onClick={() => setActiveOverlays([])}
                className="text-[11px] font-medium text-blue-600 dark:text-blue-400 hover:underline"
              >
                Clear overlays ({activeOverlays.length})
              </button>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
            {OVERLAY_CATEGORIES.map((cat) => (
              <div key={cat} className="flex flex-wrap items-center gap-1.5">
                <span className="text-[11px] font-medium text-zinc-400 dark:text-zinc-500 mr-0.5">
                  {cat}:
                </span>
                {BENCHMARK_CATALOG.filter((m) => m.category === cat).map((meta) => {
                  const isActive = activeOverlays.includes(meta.key);
                  return (
                    <button
                      key={meta.key}
                      type="button"
                      title={meta.label}
                      onClick={() => toggleOverlay(meta.key)}
                      className={`inline-flex items-center gap-1.5 text-[11px] font-medium px-2 py-0.5 rounded-md border transition-colors ${
                        isActive
                          ? 'bg-zinc-900 text-white border-zinc-900 dark:bg-zinc-100 dark:text-zinc-950 dark:border-zinc-100 shadow-sm'
                          : 'bg-white dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border-zinc-200 dark:border-zinc-800 hover:bg-zinc-100 dark:hover:bg-zinc-800'
                      }`}
                    >
                      <span
                        className="w-2 h-2 rounded-full shrink-0"
                        style={{ backgroundColor: meta.color }}
                      />
                      {meta.shortLabel}
                    </button>
                  );
                })}
              </div>
            ))}
          </div>
        </div>

        {/* Interval Controls Row */}
        <div
          className={`grid grid-cols-1 ${
            compareEnabled ? 'xl:grid-cols-2' : 'xl:grid-cols-1'
          } gap-3`}
        >
          {/* Interval 1 Picker */}
          <div className="rounded-lg p-3 bg-zinc-50 dark:bg-zinc-900/70 border border-blue-200/80 dark:border-blue-900/50 space-y-2.5">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex items-center gap-2">
                <span className="w-2.5 h-2.5 rounded-full bg-blue-600 inline-block" />
                <span className="text-xs font-semibold text-zinc-900 dark:text-zinc-100">
                  {compareEnabled ? 'Interval 1' : 'Selected Interval'}
                </span>
                <span className="font-mono text-[11px] text-zinc-500 dark:text-zinc-400">
                  ({intervalASummary.businessDays.toLocaleString()} SEC business days)
                </span>
              </div>
              <div className="flex flex-wrap items-center gap-1">
                {presets.map((pr) => {
                  const active = intervalAStart === pr.start && intervalAEnd === pr.end;
                  return (
                    <button
                      key={pr.label}
                      type="button"
                      onClick={() => onChangeIntervalA(pr.start, pr.end)}
                      className={`text-[11px] font-mono px-2 py-0.5 rounded transition-colors ${
                        active
                          ? 'bg-blue-600 text-white'
                          : 'bg-white dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300 border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-700'
                      }`}
                    >
                      {pr.label}
                    </button>
                  );
                })}
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2 text-xs">
              <Calendar className="w-3.5 h-3.5 text-blue-600 dark:text-blue-400 shrink-0" />
              <label className="flex items-center gap-1.5 text-zinc-600 dark:text-zinc-300">
                <span>From</span>
                <input
                  type="date"
                  min={minCorpusDate}
                  max={maxCorpusDate}
                  value={intervalAStart}
                  onChange={(e) => {
                    if (e.target.value) onChangeIntervalA(e.target.value, intervalAEnd);
                  }}
                  className="font-mono text-xs bg-white dark:bg-[#09090b] border border-zinc-200 dark:border-zinc-700 rounded-md px-2 py-1 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-500/40"
                />
              </label>
              <label className="flex items-center gap-1.5 text-zinc-600 dark:text-zinc-300">
                <span>To</span>
                <input
                  type="date"
                  min={minCorpusDate}
                  max={maxCorpusDate}
                  value={intervalAEnd}
                  onChange={(e) => {
                    if (e.target.value) onChangeIntervalA(intervalAStart, e.target.value);
                  }}
                  className="font-mono text-xs bg-white dark:bg-[#09090b] border border-zinc-200 dark:border-zinc-700 rounded-md px-2 py-1 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-blue-500/40"
                />
              </label>
            </div>
          </div>

          {/* Interval 2 Picker */}
          {compareEnabled && intervalBSummary && (
            <div className="rounded-lg p-3 bg-zinc-50 dark:bg-zinc-900/70 border border-emerald-300/80 dark:border-emerald-900/60 space-y-2.5">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="flex items-center gap-2">
                  <span className="w-2.5 h-2.5 rounded-full bg-emerald-500 inline-block" />
                  <span className="text-xs font-semibold text-zinc-900 dark:text-zinc-100">
                    Interval 2 (Comparison)
                  </span>
                  <span className="font-mono text-[11px] text-zinc-500 dark:text-zinc-400">
                    ({intervalBSummary.businessDays.toLocaleString()} SEC business days)
                  </span>
                </div>
                <div className="flex flex-wrap items-center gap-1">
                  {presets.slice(1).map((pr) => {
                    const active = intervalBStart === pr.start && intervalBEnd === pr.end;
                    return (
                      <button
                        key={pr.label}
                        type="button"
                        onClick={() => onChangeIntervalB(pr.start, pr.end)}
                        className={`text-[11px] font-mono px-2 py-0.5 rounded transition-colors ${
                          active
                            ? 'bg-emerald-600 text-white'
                            : 'bg-white dark:bg-zinc-800 text-zinc-600 dark:text-zinc-300 border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-100 dark:hover:bg-zinc-700'
                        }`}
                      >
                        {pr.label}
                      </button>
                    );
                  })}
                </div>
              </div>

              <div className="flex flex-wrap items-center gap-2 text-xs">
                <Calendar className="w-3.5 h-3.5 text-emerald-600 dark:text-emerald-400 shrink-0" />
                <label className="flex items-center gap-1.5 text-zinc-600 dark:text-zinc-300">
                  <span>From</span>
                  <input
                    type="date"
                    min={minCorpusDate}
                    max={maxCorpusDate}
                    value={intervalBStart}
                    onChange={(e) => {
                      if (e.target.value) onChangeIntervalB(e.target.value, intervalBEnd);
                    }}
                    className="font-mono text-xs bg-white dark:bg-[#09090b] border border-zinc-200 dark:border-zinc-700 rounded-md px-2 py-1 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-emerald-500/40"
                  />
                </label>
                <label className="flex items-center gap-1.5 text-zinc-600 dark:text-zinc-300">
                  <span>To</span>
                  <input
                    type="date"
                    min={minCorpusDate}
                    max={maxCorpusDate}
                    value={intervalBEnd}
                    onChange={(e) => {
                      if (e.target.value) onChangeIntervalB(intervalBStart, e.target.value);
                    }}
                    className="font-mono text-xs bg-white dark:bg-[#09090b] border border-zinc-200 dark:border-zinc-700 rounded-md px-2 py-1 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-2 focus:ring-emerald-500/40"
                  />
                </label>
              </div>
            </div>
          )}
        </div>

        {/* Daily Timeline Chart */}
        <ReactECharts
          option={dailyOption}
          style={{ height: 330, width: '100%' }}
          notMerge={true}
          onEvents={{
            datazoom: handleDataZoom,
          }}
        />

        {/* Single-Interval Summary OR Two-Interval Comparative Matrix */}
        {!compareEnabled || !intervalBSummary ? (
          <div className="space-y-3 pt-1">
            <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-3">
              <div className="rounded-lg p-3.5 bg-zinc-50 dark:bg-zinc-900/60 border border-zinc-200/80 dark:border-zinc-800">
                <div className="text-[11px] font-medium text-zinc-500 dark:text-zinc-400">
                  S-1 Offerings in Interval
                </div>
                <div className="mt-1 flex items-baseline gap-2">
                  <span className="font-mono text-xl font-bold text-zinc-950 dark:text-zinc-50">
                    {intervalASummary.dealCount.toLocaleString()}
                  </span>
                  <span className="font-mono text-xs text-blue-600 dark:text-blue-400">
                    {intervalASummary.dealsPerBusinessDay.toFixed(2)} / day
                  </span>
                </div>
                <div className="mt-1 text-[11px] text-zinc-500 dark:text-zinc-400">
                  {intervalASummary.totalSubmissions.toLocaleString()} total S-1 &amp; S-1/A filings
                </div>
              </div>

              <div className="rounded-lg p-3.5 bg-zinc-50 dark:bg-zinc-900/60 border border-zinc-200/80 dark:border-zinc-800">
                <div className="text-[11px] font-medium text-zinc-500 dark:text-zinc-400">
                  Aggregate Gross Proceeds
                </div>
                <div className="mt-1 flex items-baseline gap-2">
                  <span className="font-mono text-xl font-bold text-zinc-950 dark:text-zinc-50">
                    {formatCompactUSD(intervalASummary.aggregateProceedsUSD)}
                  </span>
                  <span className="font-mono text-xs text-emerald-600 dark:text-emerald-400">
                    Med {formatCompactUSD(intervalASummary.medianProceedsUSD)}
                  </span>
                </div>
                <div className="mt-1 text-[11px] text-zinc-500 dark:text-zinc-400">
                  {formatCompactUSD(intervalASummary.proceedsPerBusinessDayUSD)} per SEC business day
                </div>
              </div>

              <div className="rounded-lg p-3.5 bg-zinc-50 dark:bg-zinc-900/60 border border-zinc-200/80 dark:border-zinc-800">
                <div className="text-[11px] font-medium text-zinc-500 dark:text-zinc-400">
                  Unit Coverage Mix
                </div>
                <div className="mt-1 font-mono text-sm font-bold text-zinc-950 dark:text-zinc-50">
                  {intervalASummary.shareRightPct}% Rights • {intervalASummary.fractionalWarrantPct}% Frac •{' '}
                  {intervalASummary.wholeWarrantPct}% Whole
                </div>
                <div className="mt-1 text-[11px] text-zinc-500 dark:text-zinc-400">
                  {intervalASummary.noWarrantPct}% Share-Only • Avg unit overhang +{intervalASummary.impliedUnitOverhangPct}%
                </div>
              </div>

              <div className="rounded-lg p-3.5 bg-zinc-50 dark:bg-zinc-900/60 border border-zinc-200/80 dark:border-zinc-800">
                <div className="text-[11px] font-medium text-zinc-500 dark:text-zinc-400">
                  Most Active in Interval
                </div>
                <div className="mt-1 text-xs font-semibold text-zinc-900 dark:text-zinc-100 truncate">
                  UW:{' '}
                  {intervalASummary.topUnderwriters[0]
                    ? `${intervalASummary.topUnderwriters[0].name} (${intervalASummary.topUnderwriters[0].count})`
                    : '—'}
                </div>
                <div className="mt-1 text-xs font-semibold text-zinc-900 dark:text-zinc-100 truncate">
                  Counsel:{' '}
                  {intervalASummary.topCounsel[0]
                    ? `${intervalASummary.topCounsel[0].name} (${intervalASummary.topCounsel[0].count})`
                    : '—'}
                </div>
              </div>
            </div>

            {/* Active Market & Rate Overlay Interval Summary Strip */}
            {overlayStatsA.length > 0 && (
              <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-2.5">
                {overlayStatsA.map((st) => (
                  <div
                    key={st.meta.key}
                    className="rounded-lg px-3 py-2.5 bg-zinc-50/70 dark:bg-zinc-900/40 border border-zinc-200/70 dark:border-zinc-800/80 flex items-center justify-between gap-2"
                  >
                    <div className="min-w-0">
                      <div className="flex items-center gap-1.5 text-[11px] font-semibold text-zinc-700 dark:text-zinc-200 truncate">
                        <span
                          className="w-2 h-2 rounded-full shrink-0"
                          style={{ backgroundColor: st.meta.color }}
                        />
                        {st.meta.label}
                      </div>
                      <div className="font-mono text-[11px] text-zinc-500 dark:text-zinc-400 mt-0.5">
                        {formatBenchmarkValue(st.startVal, st.meta.unit)} →{' '}
                        {formatBenchmarkValue(st.endVal, st.meta.unit)} (
                        {formatBenchmarkDelta(st.startVal, st.endVal, st.meta.unit)})
                      </div>
                    </div>
                    <div className="text-right shrink-0">
                      <div className="text-[10px] uppercase tracking-wider text-zinc-400">Avg</div>
                      <div className="font-mono text-sm font-bold text-zinc-950 dark:text-zinc-50">
                        {formatBenchmarkValue(st.mean, st.meta.unit)}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div className="overflow-x-auto rounded-lg border border-zinc-200 dark:border-zinc-800">
            <table className="w-full text-left text-xs border-collapse">
              <thead className="bg-zinc-100 dark:bg-zinc-900 text-zinc-600 dark:text-zinc-300 border-b border-zinc-200 dark:border-zinc-800">
                <tr>
                  <th scope="col" className="py-2.5 px-3.5 font-semibold">
                    Metric
                  </th>
                  <th scope="col" className="py-2.5 px-3.5 font-semibold text-blue-700 dark:text-blue-400">
                    Interval 1 ({formatFilingDate(intervalASummary.startDate)} – {formatFilingDate(intervalASummary.endDate)})
                  </th>
                  <th scope="col" className="py-2.5 px-3.5 font-semibold text-emerald-700 dark:text-emerald-400">
                    Interval 2 ({formatFilingDate(intervalBSummary.startDate)} – {formatFilingDate(intervalBSummary.endDate)})
                  </th>
                  <th scope="col" className="py-2.5 px-3.5 font-semibold">
                    Interval 2 vs. 1
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800/80 font-mono">
                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    SEC Business Days
                  </td>
                  <td className="py-2 px-3.5">{intervalASummary.businessDays.toLocaleString()}</td>
                  <td className="py-2 px-3.5">{intervalBSummary.businessDays.toLocaleString()}</td>
                  <td className="py-2 px-3.5 text-zinc-500">
                    {intervalBSummary.businessDays - intervalASummary.businessDays >= 0 ? '+' : ''}
                    {intervalBSummary.businessDays - intervalASummary.businessDays} days
                  </td>
                </tr>
                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    S-1 Offerings (Daily Pace)
                  </td>
                  <td className="py-2 px-3.5">
                    {intervalASummary.dealCount.toLocaleString()} ({intervalASummary.dealsPerBusinessDay.toFixed(2)}/day)
                  </td>
                  <td className="py-2 px-3.5">
                    {intervalBSummary.dealCount.toLocaleString()} ({intervalBSummary.dealsPerBusinessDay.toFixed(2)}/day)
                  </td>
                  <td className="py-2 px-3.5 font-semibold">
                    {formatRatioChange(intervalBSummary.dealsPerBusinessDay, intervalASummary.dealsPerBusinessDay)} pace
                  </td>
                </tr>
                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    Aggregate Gross Proceeds (Daily Pace)
                  </td>
                  <td className="py-2 px-3.5">
                    {formatCompactUSD(intervalASummary.aggregateProceedsUSD)} ({formatCompactUSD(intervalASummary.proceedsPerBusinessDayUSD)}/day)
                  </td>
                  <td className="py-2 px-3.5">
                    {formatCompactUSD(intervalBSummary.aggregateProceedsUSD)} ({formatCompactUSD(intervalBSummary.proceedsPerBusinessDayUSD)}/day)
                  </td>
                  <td className="py-2 px-3.5 font-semibold">
                    {formatRatioChange(intervalBSummary.proceedsPerBusinessDayUSD, intervalASummary.proceedsPerBusinessDayUSD)} / day
                  </td>
                </tr>
                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    Median / Mean Offering Size
                  </td>
                  <td className="py-2 px-3.5">
                    {formatCompactUSD(intervalASummary.medianProceedsUSD)} / {formatCompactUSD(intervalASummary.meanProceedsUSD)}
                  </td>
                  <td className="py-2 px-3.5">
                    {formatCompactUSD(intervalBSummary.medianProceedsUSD)} / {formatCompactUSD(intervalBSummary.meanProceedsUSD)}
                  </td>
                  <td className="py-2 px-3.5">
                    {formatRatioChange(intervalBSummary.medianProceedsUSD, intervalASummary.medianProceedsUSD)} median
                  </td>
                </tr>
                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    Share-Right Units (% of Offerings)
                  </td>
                  <td className="py-2 px-3.5">{intervalASummary.shareRightPct.toFixed(1)}%</td>
                  <td className="py-2 px-3.5">{intervalBSummary.shareRightPct.toFixed(1)}%</td>
                  <td className="py-2 px-3.5 font-semibold">
                    {formatSignedPctDelta(intervalBSummary.shareRightPct, intervalASummary.shareRightPct, ' pp')}
                  </td>
                </tr>
                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    Fractional Warrant / Whole Warrant / No Warrant
                  </td>
                  <td className="py-2 px-3.5">
                    {intervalASummary.fractionalWarrantPct}% / {intervalASummary.wholeWarrantPct}% / {intervalASummary.noWarrantPct}%
                  </td>
                  <td className="py-2 px-3.5">
                    {intervalBSummary.fractionalWarrantPct}% / {intervalBSummary.wholeWarrantPct}% / {intervalBSummary.noWarrantPct}%
                  </td>
                  <td className="py-2 px-3.5">
                    Avg overhang {formatSignedPctDelta(intervalBSummary.impliedUnitOverhangPct, intervalASummary.impliedUnitOverhangPct, ' pp')}
                  </td>
                </tr>

                {/* Dynamic rows for every active Market / Rate Overlay */}
                {overlayStatsA.map((stA, idx) => {
                  const stB = overlayStatsB[idx];
                  if (!stB) return null;
                  return (
                    <tr key={stA.meta.key} className="bg-zinc-50/50 dark:bg-zinc-900/30">
                      <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300 flex items-center gap-1.5">
                        <span
                          className="w-2 h-2 rounded-full shrink-0"
                          style={{ backgroundColor: stA.meta.color }}
                        />
                        {stA.meta.label} (Period Avg)
                      </td>
                      <td className="py-2 px-3.5">
                        {formatBenchmarkValue(stA.mean, stA.meta.unit)}{' '}
                        <span className="text-zinc-400">
                          ({formatBenchmarkValue(stA.startVal, stA.meta.unit)} → {formatBenchmarkValue(stA.endVal, stA.meta.unit)})
                        </span>
                      </td>
                      <td className="py-2 px-3.5">
                        {formatBenchmarkValue(stB.mean, stB.meta.unit)}{' '}
                        <span className="text-zinc-400">
                          ({formatBenchmarkValue(stB.startVal, stB.meta.unit)} → {formatBenchmarkValue(stB.endVal, stB.meta.unit)})
                        </span>
                      </td>
                      <td className="py-2 px-3.5 font-semibold">
                        {formatBenchmarkDelta(stA.mean, stB.mean, stA.meta.unit)} avg
                      </td>
                    </tr>
                  );
                })}

                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    Top Underwriters
                  </td>
                  <td className="py-2 px-3.5 font-sans">
                    {intervalASummary.topUnderwriters.map((u) => `${u.name} (${u.count})`).join(', ') || '—'}
                  </td>
                  <td className="py-2 px-3.5 font-sans">
                    {intervalBSummary.topUnderwriters.map((u) => `${u.name} (${u.count})`).join(', ') || '—'}
                  </td>
                  <td className="py-2 px-3.5 text-zinc-400">—</td>
                </tr>
                <tr>
                  <td className="py-2 px-3.5 font-sans font-medium text-zinc-700 dark:text-zinc-300">
                    Top Counsel
                  </td>
                  <td className="py-2 px-3.5 font-sans">
                    {intervalASummary.topCounsel.map((c) => `${c.name} (${c.count})`).join(', ') || '—'}
                  </td>
                  <td className="py-2 px-3.5 font-sans">
                    {intervalBSummary.topCounsel.map((c) => `${c.name} (${c.count})`).join(', ') || '—'}
                  </td>
                  <td className="py-2 px-3.5 text-zinc-400">—</td>
                </tr>
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* Chart 2: Unit Coverage by Year */}
      <section className="containment-section bg-white dark:bg-[#0c0c0f] rounded-xl border border-zinc-200 dark:border-[#1e1e24] shadow-sm p-5">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-3">
          <div>
            <h2 className="text-base font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
              Unit Coverage by Year (2020–2026)
            </h2>
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Warrant fractions, share rights, and share-only units extracted from S-1 cover pages (click any segment to filter).
            </p>
          </div>
          <div className="flex items-center gap-2 self-start">
            <div className="bg-zinc-100 dark:bg-zinc-900 p-1 rounded-[8px] flex items-center text-xs font-medium border border-zinc-200/70 dark:border-zinc-800">
              <button
                type="button"
                onClick={() => setCoverageMode('share')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  coverageMode === 'share'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                % Share
              </button>
              <button
                type="button"
                onClick={() => setCoverageMode('count')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  coverageMode === 'count'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                Count
              </button>
            </div>
          </div>
        </div>
        <ReactECharts
          option={coverageOption}
          style={{ height: 310, width: '100%' }}
          notMerge={true}
          onEvents={{
            click: (params: { seriesName?: string }) => {
              const hit = COVERAGE_SERIES.find((s) => s.label === params.seriesName);
              if (hit) {
                onSelectCoverage(selectedCoverage === hit.key ? 'ALL' : hit.key);
              }
            },
          }}
        />
      </section>

      {/* Chart 3: Counsel & Underwriters */}
      <section className="containment-section bg-white dark:bg-[#0c0c0f] rounded-xl border border-zinc-200 dark:border-[#1e1e24] shadow-sm p-5">
        <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-3 mb-3">
          <div>
            <h2 className="text-base font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
              Counsel &amp; Underwriters
            </h2>
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Click any firm or underwriter bar to filter the filings below.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <div className="bg-zinc-100 dark:bg-zinc-900 p-1 rounded-[8px] flex items-center text-xs font-medium border border-zinc-200/70 dark:border-zinc-800">
              <button
                type="button"
                onClick={() => setLeagueMode('counsel')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  leagueMode === 'counsel'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                Counsel
              </button>
              <button
                type="button"
                onClick={() => setLeagueMode('underwriters')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  leagueMode === 'underwriters'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                Underwriters
              </button>
            </div>
            <div className="bg-zinc-100 dark:bg-zinc-900 p-1 rounded-[8px] flex items-center text-xs font-medium border border-zinc-200/70 dark:border-zinc-800">
              <button
                type="button"
                onClick={() => setLeagueMetric('deals')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  leagueMetric === 'deals'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                By Filings
              </button>
              <button
                type="button"
                onClick={() => setLeagueMetric('proceeds')}
                className={`px-2.5 py-1 rounded-[6px] transition-colors ${
                  leagueMetric === 'proceeds'
                    ? 'bg-white dark:bg-zinc-800 text-[#2563eb] dark:text-[#60a5fa] shadow-sm'
                    : 'text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-200'
                }`}
              >
                By Gross Proceeds ($B)
              </button>
            </div>
          </div>
        </div>
        <ReactECharts
          option={leagueOption}
          style={{ height: 390, width: '100%' }}
          notMerge={true}
          onEvents={{
            click: (params: { name?: string }) => {
              if (!params.name) return;
              if (leagueMode === 'counsel') {
                onSelectCounsel(selectedCounsel === params.name ? 'ALL' : params.name);
              } else {
                onSelectUnderwriter(
                  selectedUnderwriter === params.name ? 'ALL' : params.name
                );
              }
            },
          }}
        />
      </section>
    </div>
  );
}
