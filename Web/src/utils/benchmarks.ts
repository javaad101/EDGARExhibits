export type OverlayScaleGroup = 'ratePct' | 'vix' | 'spx' | 'ixic' | 'spreadBps';

export type BenchmarkKey =
  | 'spx'
  | 'ixic'
  | 'vix'
  | 'sofr'
  | 'tgcr'
  | 'bgcr'
  | 'onRrp'
  | 'effr'
  | 'ust3m'
  | 'ust2y'
  | 'ust10y'
  | 'curve2s10s'
  | 'agency30y'
  | 'agencySpreadBps';

export interface BenchmarkSeriesMeta {
  key: BenchmarkKey;
  label: string;
  shortLabel: string;
  category: 'Equity & Vol' | 'Repo & Funding' | 'Treasury' | 'Agency';
  scaleGroup: OverlayScaleGroup;
  color: string;
  dashed?: boolean;
  unit: '%' | 'pts' | 'idx' | 'bps';
}

export const BENCHMARK_CATALOG: BenchmarkSeriesMeta[] = [
  // Equity & Volatility
  {
    key: 'spx',
    label: 'S&P 500 (SPX)',
    shortLabel: 'SPX',
    category: 'Equity & Vol',
    scaleGroup: 'spx',
    color: '#f59e0b',
    unit: 'idx',
  },
  {
    key: 'ixic',
    label: 'Nasdaq Composite',
    shortLabel: 'Nasdaq',
    category: 'Equity & Vol',
    scaleGroup: 'ixic',
    color: '#ec4899',
    unit: 'idx',
  },
  {
    key: 'vix',
    label: 'CBOE VIX',
    shortLabel: 'VIX',
    category: 'Equity & Vol',
    scaleGroup: 'vix',
    color: '#ef4444',
    unit: 'pts',
  },

  // Repo & Overnight Money Markets
  {
    key: 'sofr',
    label: 'SOFR (Overnight Treasury Repo)',
    shortLabel: 'SOFR',
    category: 'Repo & Funding',
    scaleGroup: 'ratePct',
    color: '#06b6d4',
    unit: '%',
  },
  {
    key: 'tgcr',
    label: 'TGCR (Tri-Party GC Repo)',
    shortLabel: 'TGCR',
    category: 'Repo & Funding',
    scaleGroup: 'ratePct',
    color: '#14b8a6',
    dashed: true,
    unit: '%',
  },
  {
    key: 'bgcr',
    label: 'BGCR (Broad GC Treasury/Agency Repo)',
    shortLabel: 'BGCR',
    category: 'Repo & Funding',
    scaleGroup: 'ratePct',
    color: '#22c55e',
    dashed: true,
    unit: '%',
  },
  {
    key: 'onRrp',
    label: 'Fed ON RRP Award Rate',
    shortLabel: 'ON RRP',
    category: 'Repo & Funding',
    scaleGroup: 'ratePct',
    color: '#a855f7',
    dashed: true,
    unit: '%',
  },
  {
    key: 'effr',
    label: 'Effective Fed Funds (EFFR)',
    shortLabel: 'Fed Funds',
    category: 'Repo & Funding',
    scaleGroup: 'ratePct',
    color: '#64748b',
    dashed: true,
    unit: '%',
  },

  // U.S. Treasuries
  {
    key: 'ust3m',
    label: '3M Treasury Bill (Trust Yield)',
    shortLabel: '3M T-Bill',
    category: 'Treasury',
    scaleGroup: 'ratePct',
    color: '#10b981',
    unit: '%',
  },
  {
    key: 'ust2y',
    label: '2Y Treasury Yield',
    shortLabel: '2Y UST',
    category: 'Treasury',
    scaleGroup: 'ratePct',
    color: '#6366f1',
    unit: '%',
  },
  {
    key: 'ust10y',
    label: '10Y Treasury Yield',
    shortLabel: '10Y UST',
    category: 'Treasury',
    scaleGroup: 'ratePct',
    color: '#8b5cf6',
    unit: '%',
  },
  {
    key: 'curve2s10s',
    label: '2s10s Treasury Curve',
    shortLabel: '2s10s',
    category: 'Treasury',
    scaleGroup: 'ratePct',
    color: '#eab308',
    dashed: true,
    unit: '%',
  },

  // Agency MBS / Conforming
  {
    key: 'agency30y',
    label: 'Agency 30Y Conforming Rate',
    shortLabel: 'Agency 30Y',
    category: 'Agency',
    scaleGroup: 'ratePct',
    color: '#f97316',
    unit: '%',
  },
  {
    key: 'agencySpreadBps',
    label: 'Agency 30Y Spread vs. 10Y UST',
    shortLabel: 'Agency Spread',
    category: 'Agency',
    scaleGroup: 'spreadBps',
    color: '#fb7185',
    unit: 'bps',
  },
];

export interface MarketBenchmarksPayload {
  generatedAtISO8601: string;
  sources: string[];
  fields: BenchmarkKey[];
  byDate: Record<string, Array<number | null>>;
}

export interface BenchmarkIntervalStats {
  meta: BenchmarkSeriesMeta;
  mean: number | null;
  startVal: number | null;
  endVal: number | null;
  minVal: number | null;
  maxVal: number | null;
}

export function getBenchmarkValue(
  payload: MarketBenchmarksPayload | null,
  fieldIndexMap: Map<BenchmarkKey, number>,
  date: string,
  key: BenchmarkKey
): number | null {
  if (!payload) return null;
  const idx = fieldIndexMap.get(key);
  if (idx === undefined) return null;
  const row = payload.byDate[date];
  if (!row) return null;
  const val = row[idx];
  return typeof val === 'number' ? val : null;
}

export function formatBenchmarkValue(val: number | null, unit: BenchmarkSeriesMeta['unit']): string {
  if (val === null || Number.isNaN(val)) return '—';
  switch (unit) {
    case '%':
      return `${val.toFixed(2)}%`;
    case 'bps':
      return `${Math.round(val)} bps`;
    case 'pts':
      return val.toFixed(2);
    case 'idx':
      return val.toLocaleString(undefined, { maximumFractionDigits: 1, minimumFractionDigits: 1 });
  }
}

export function formatBenchmarkDelta(
  fromVal: number | null,
  toVal: number | null,
  unit: BenchmarkSeriesMeta['unit']
): string {
  if (fromVal === null || toVal === null) return '—';
  if (unit === '%') {
    const bps = Math.round((toVal - fromVal) * 100);
    return `${bps >= 0 ? '+' : ''}${bps} bps`;
  }
  if (unit === 'bps') {
    const diff = Math.round(toVal - fromVal);
    return `${diff >= 0 ? '+' : ''}${diff} bps`;
  }
  if (unit === 'pts') {
    const diff = toVal - fromVal;
    return `${diff >= 0 ? '+' : ''}${diff.toFixed(1)} pts`;
  }
  if (fromVal === 0) return '—';
  const pct = ((toVal - fromVal) / fromVal) * 100;
  return `${pct >= 0 ? '+' : ''}${pct.toFixed(1)}%`;
}

export function computeBenchmarkIntervalStats(
  payload: MarketBenchmarksPayload | null,
  fieldIndexMap: Map<BenchmarkKey, number>,
  datesInInterval: string[],
  meta: BenchmarkSeriesMeta
): BenchmarkIntervalStats {
  const vals: number[] = [];
  for (const dt of datesInInterval) {
    const v = getBenchmarkValue(payload, fieldIndexMap, dt, meta.key);
    if (v !== null) vals.push(v);
  }
  if (vals.length === 0) {
    return {
      meta,
      mean: null,
      startVal: null,
      endVal: null,
      minVal: null,
      maxVal: null,
    };
  }
  const sum = vals.reduce((a, b) => a + b, 0);
  let minV = vals[0];
  let maxV = vals[0];
  for (const v of vals) {
    if (v < minV) minV = v;
    if (v > maxV) maxV = v;
  }
  return {
    meta,
    mean: sum / vals.length,
    startVal: vals[0],
    endVal: vals[vals.length - 1],
    minVal: minV,
    maxVal: maxV,
  };
}
