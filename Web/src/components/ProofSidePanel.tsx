import { useEffect, useState } from 'react';
import {
  X,
  ExternalLink,
  FileText,
  Scale,
  Building2,
  Quote,
  FileCheck2,
  Loader2,
  AlertCircle,
} from 'lucide-react';
import type { DealTrendRecord, DealDetailProofResponse } from '../types';
import {
  formatCompactUSD,
  formatExactUSD,
  formatFilingDate,
  formatUnits,
} from '../utils/format';

interface ProofSidePanelProps {
  deal: DealTrendRecord;
  onClose: () => void;
  onFilterByCounsel: (firm: string) => void;
  onFilterByUnderwriter: (bank: string) => void;
  onFilterBySearch: (term: string) => void;
}

export function ProofSidePanel({
  deal,
  onClose,
  onFilterByCounsel,
  onFilterByUnderwriter,
  onFilterBySearch,
}: ProofSidePanelProps) {
  const [activeTab, setActiveTab] = useState<'proof' | 'html' | 'exhibits'>('proof');
  const [detail, setDetail] = useState<DealDetailProofResponse | null>(null);
  const [loadingDetail, setLoadingDetail] = useState(false);
  const [detailError, setDetailError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoadingDetail(true);
    setDetailError(null);
    setDetail(null);

    fetch(`/trends/deals/${encodeURIComponent(deal.dealKey)}`)
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json() as Promise<DealDetailProofResponse>;
      })
      .then((payload) => {
        if (!cancelled) {
          setDetail(payload);
          setLoadingDetail(false);
        }
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setDetailError(err instanceof Error ? err.message : 'Failed to load exhibits');
          setLoadingDetail(false);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [deal.dealKey]);

  const rawCoverURL = deal.sourceFolderKey
    ? `/filings/${encodeURIComponent(deal.sourceFolderKey)}/document`
    : deal.secArchiveURL;

  return (
    <aside
      aria-label={`Filing details for ${deal.companyName}`}
      className="bg-white dark:bg-[#0c0c0f] border border-zinc-200 dark:border-[#1e1e24] rounded-xl shadow-sm flex flex-col overflow-hidden"
    >
      {/* Top Header */}
      <div className="p-4 border-b border-zinc-200 dark:border-zinc-800 flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-1.5 mb-1">
            <span className="font-mono text-[11px] font-medium px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300">
              {deal.fileNumber}
            </span>
            <span className="font-mono text-[11px] px-1.5 py-0.5 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400">
              CIK {deal.cik}
            </span>
            {deal.proposedTicker && (
              <span className="font-mono text-[11px] font-semibold px-1.5 py-0.5 rounded bg-blue-50 dark:bg-blue-950/60 text-blue-700 dark:text-blue-300 border border-blue-200/70 dark:border-blue-800/50">
                {deal.proposedTicker}
              </span>
            )}
          </div>
          <h3 className="text-base font-bold tracking-tight text-zinc-950 dark:text-zinc-50 leading-snug">
            {deal.companyName}
          </h3>
          <p className="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
            {deal.jurisdiction} {deal.sic ? `• SIC ${deal.sic}` : ''} •{' '}
            <span className="font-mono text-zinc-700 dark:text-zinc-300">
              {deal.sourceFormType}
            </span>{' '}
            ({formatFilingDate(deal.sourceFilingDate)})
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label="Close filing panel"
          className="p-1.5 rounded-lg text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors shrink-0"
        >
          <X className="w-4 h-4" />
        </button>
      </div>

      {/* Primary Verification Links */}
      <div className="px-4 py-2.5 bg-zinc-50 dark:bg-zinc-900/60 border-b border-zinc-200 dark:border-zinc-800 flex flex-wrap items-center gap-2">
        <a
          href={rawCoverURL}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-xs font-medium px-3 py-1.5 rounded-[8px] bg-[#2563eb] hover:bg-blue-700 text-white shadow-sm transition-colors"
        >
          <FileText className="w-3.5 h-3.5" />
          Open S-1 HTML
          <ExternalLink className="w-3 h-3 opacity-80" />
        </a>
        <a
          href={deal.secArchiveURL}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-xs font-medium px-3 py-1.5 rounded-[8px] bg-white dark:bg-[#262626] hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200 border border-zinc-200 dark:border-zinc-700 shadow-sm transition-colors"
        >
          Open on SEC.gov
          <ExternalLink className="w-3 h-3 opacity-75" />
        </a>
      </div>

      {/* Underline Navigation Tabs */}
      <div className="px-4 border-b border-zinc-200 dark:border-zinc-800 flex items-center gap-4 text-xs font-medium">
        <button
          type="button"
          onClick={() => setActiveTab('proof')}
          className={`py-2.5 border-b-2 transition-colors ${
            activeTab === 'proof'
              ? 'border-[#3b82f6] text-[#2563eb] dark:text-[#60a5fa]'
              : 'border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200'
          }`}
        >
          Cover Page Terms
        </button>
        <button
          type="button"
          onClick={() => setActiveTab('html')}
          className={`py-2.5 border-b-2 transition-colors ${
            activeTab === 'html'
              ? 'border-[#3b82f6] text-[#2563eb] dark:text-[#60a5fa]'
              : 'border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200'
          }`}
        >
          S-1 Preview
        </button>
        <button
          type="button"
          onClick={() => setActiveTab('exhibits')}
          className={`py-2.5 border-b-2 transition-colors flex items-center gap-1.5 ${
            activeTab === 'exhibits'
              ? 'border-[#3b82f6] text-[#2563eb] dark:text-[#60a5fa]'
              : 'border-transparent text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200'
          }`}
        >
          Exhibits
          <span className="font-mono text-[10px] px-1.5 py-0.2 rounded bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300">
            {deal.exhibitCount}
          </span>
        </button>
      </div>

      {/* Tab Content */}
      <div className="p-4 overflow-y-auto max-h-[760px] space-y-4">
        {activeTab === 'proof' && (
          <>
            {/* Deal Economics Grid */}
            <div className="grid grid-cols-2 gap-2.5">
              <div className="bg-zinc-50 dark:bg-zinc-900/80 border border-zinc-200/80 dark:border-zinc-800 rounded-lg p-3">
                <div className="text-[11px] uppercase tracking-wider font-semibold text-zinc-500 dark:text-zinc-400">
                  Gross Proceeds
                </div>
                <div className="font-mono text-lg font-bold text-zinc-950 dark:text-zinc-50 mt-0.5">
                  {formatCompactUSD(deal.ipoProceedsUSD)}
                </div>
                <div className="font-mono text-[11px] text-zinc-500 dark:text-zinc-400">
                  {deal.ipoProceedsUSD ? formatExactUSD(deal.ipoProceedsUSD) : 'Draft / Unpriced'}
                </div>
              </div>

              <div className="bg-zinc-50 dark:bg-zinc-900/80 border border-zinc-200/80 dark:border-zinc-800 rounded-lg p-3">
                <div className="text-[11px] uppercase tracking-wider font-semibold text-zinc-500 dark:text-zinc-400">
                  Units &amp; Over-Allotment
                </div>
                <div className="font-mono text-sm font-semibold text-zinc-950 dark:text-zinc-50 mt-1">
                  {formatUnits(deal.unitCount)}
                </div>
                <div className="font-mono text-[11px] text-zinc-500 dark:text-zinc-400 mt-0.5">
                  With OA: {formatCompactUSD(deal.overAllotmentProceedsUSD)}
                </div>
              </div>

              <div className="bg-zinc-50 dark:bg-zinc-900/80 border border-zinc-200/80 dark:border-zinc-800 rounded-lg p-3 col-span-2">
                <div className="text-[11px] uppercase tracking-wider font-semibold text-zinc-500 dark:text-zinc-400">
                  Unit Coverage &amp; Exchange
                </div>
                <div className="text-xs font-semibold text-zinc-950 dark:text-zinc-50 mt-1">
                  {deal.warrantCoverage}
                </div>
                <div className="text-[11px] text-zinc-500 dark:text-zinc-400 mt-0.5">
                  {deal.exchange ?? 'Exchange TBD'}
                  {deal.combinationWindowMonths ? ` • ${deal.combinationWindowMonths} months` : ''}
                </div>
              </div>
            </div>

            {/* Underwriters */}
            <div className="bg-zinc-50 dark:bg-zinc-900/80 border border-zinc-200/80 dark:border-zinc-800 rounded-lg p-3 space-y-2">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-700 dark:text-zinc-300">
                <Building2 className="w-3.5 h-3.5 text-blue-600 dark:text-blue-400" />
                Underwriters
              </div>
              {deal.bookrunners.length > 0 ? (
                <div className="flex flex-wrap gap-1.5">
                  {deal.bookrunners.map((bank) => (
                    <button
                      key={bank}
                      type="button"
                      onClick={() => onFilterByUnderwriter(bank)}
                      title="Filter by this underwriter"
                      className="text-xs font-medium px-2.5 py-1 rounded-md bg-white dark:bg-zinc-800 hover:bg-blue-50 dark:hover:bg-blue-950/50 text-zinc-800 dark:text-zinc-200 border border-zinc-200 dark:border-zinc-700 transition-colors"
                    >
                      {bank}
                    </button>
                  ))}
                </div>
              ) : (
                <p className="text-xs text-zinc-500">Not yet named on initial draft.</p>
              )}
            </div>

            {/* Counsel & Named Partners */}
            <div className="bg-zinc-50 dark:bg-zinc-900/80 border border-zinc-200/80 dark:border-zinc-800 rounded-lg p-3 space-y-2.5">
              <div className="flex items-center gap-1.5 text-xs font-semibold text-zinc-700 dark:text-zinc-300">
                <Scale className="w-3.5 h-3.5 text-emerald-600 dark:text-emerald-400" />
                Counsel (&ldquo;Copies to:&rdquo;)
              </div>

              <div className="space-y-1.5 text-xs">
                <div>
                  <span className="text-zinc-500 dark:text-zinc-400 font-medium">Issuer Counsel: </span>
                  {deal.issuerCounsel.length > 0 ? (
                    <span className="inline-flex flex-wrap gap-1 ml-1">
                      {deal.issuerCounsel.map((firm) => (
                        <button
                          key={firm}
                          type="button"
                          onClick={() => onFilterByCounsel(firm)}
                          className="font-medium text-blue-600 dark:text-blue-400 hover:underline"
                        >
                          {firm}
                        </button>
                      ))}
                    </span>
                  ) : (
                    <span className="text-zinc-400">—</span>
                  )}
                </div>

                <div>
                  <span className="text-zinc-500 dark:text-zinc-400 font-medium">Underwriter Counsel: </span>
                  {deal.underwriterCounsel.length > 0 ? (
                    <span className="inline-flex flex-wrap gap-1 ml-1">
                      {deal.underwriterCounsel.map((firm) => (
                        <button
                          key={firm}
                          type="button"
                          onClick={() => onFilterByCounsel(firm)}
                          className="font-medium text-emerald-600 dark:text-emerald-400 hover:underline"
                        >
                          {firm}
                        </button>
                      ))}
                    </span>
                  ) : (
                    <span className="text-zinc-400">—</span>
                  )}
                </div>

                {deal.offshoreCounsel.length > 0 && (
                  <div>
                    <span className="text-zinc-500 dark:text-zinc-400 font-medium">Offshore Counsel: </span>
                    <span className="text-zinc-800 dark:text-zinc-200">
                      {deal.offshoreCounsel.join(', ')}
                    </span>
                  </div>
                )}

                {deal.counselPartners.length > 0 && (
                  <div className="pt-1">
                    <div className="text-[11px] text-zinc-500 dark:text-zinc-400 mb-1">
                      Named Partners (click to filter):
                    </div>
                    <div className="flex flex-wrap gap-1.5">
                      {deal.counselPartners.map((partner) => (
                        <button
                          key={partner}
                          type="button"
                          onClick={() => onFilterBySearch(partner)}
                          className="text-[11px] font-mono px-2 py-0.5 rounded bg-white dark:bg-zinc-800 hover:bg-blue-50 dark:hover:bg-blue-950/40 text-zinc-700 dark:text-zinc-300 border border-zinc-200 dark:border-zinc-700 transition-colors"
                        >
                          {partner}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            </div>

            {/* Verbatim Excerpts */}
            <div className="space-y-2.5">
              <div className="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
                <Quote className="w-3.5 h-3.5" />
                Cover-Page Excerpts
              </div>

              {deal.rawCopiesToSnippet && (
                <blockquote className="text-xs leading-relaxed bg-zinc-50 dark:bg-zinc-900/70 border-l-2 border-emerald-500 p-2.5 rounded-r-md text-zinc-700 dark:text-zinc-300 font-mono">
                  <div className="text-[10px] font-sans font-semibold uppercase text-emerald-600 dark:text-emerald-400 mb-1">
                    Facing Page — Copies To
                  </div>
                  {deal.rawCopiesToSnippet}
                </blockquote>
              )}

              {deal.rawBookrunnerSnippet && (
                <blockquote className="text-xs leading-relaxed bg-zinc-50 dark:bg-zinc-900/70 border-l-2 border-blue-500 p-2.5 rounded-r-md text-zinc-700 dark:text-zinc-300">
                  <div className="text-[10px] font-semibold uppercase text-blue-600 dark:text-blue-400 mb-1">
                    Underwriters
                  </div>
                  {deal.rawBookrunnerSnippet}
                </blockquote>
              )}

              {deal.rawUnitStructureSnippet && (
                <blockquote className="text-xs leading-relaxed bg-zinc-50 dark:bg-zinc-900/70 border-l-2 border-amber-500 p-2.5 rounded-r-md text-zinc-700 dark:text-zinc-300">
                  <div className="text-[10px] font-semibold uppercase text-amber-600 dark:text-amber-400 mb-1">
                    Unit Coverage
                  </div>
                  {deal.rawUnitStructureSnippet}
                </blockquote>
              )}

              {deal.rawOfferingSnippet && (
                <blockquote className="text-xs leading-relaxed bg-zinc-50 dark:bg-zinc-900/70 border-l-2 border-zinc-400 p-2.5 rounded-r-md text-zinc-700 dark:text-zinc-300">
                  <div className="text-[10px] font-semibold uppercase text-zinc-500 mb-1">
                    Offering Summary
                  </div>
                  {deal.rawOfferingSnippet}
                </blockquote>
              )}
            </div>
          </>
        )}

        {activeTab === 'html' && (
          <div className="space-y-2">
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              Archived SEC EDGAR HTML (<span className="font-mono">{deal.sourceAccessionNo}</span>):
            </p>
            <iframe
              title={`Form S-1 cover page for ${deal.companyName}`}
              src={rawCoverURL}
              sandbox="allow-same-origin"
              className="w-full h-[580px] bg-white text-black rounded-lg border border-zinc-200 dark:border-zinc-700 shadow-inner"
            />
          </div>
        )}

        {activeTab === 'exhibits' && (
          <div className="space-y-3">
            {loadingDetail && (
              <div className="flex items-center justify-center gap-2 py-10 text-xs text-zinc-500">
                <Loader2 className="w-4 h-4 animate-spin text-blue-600" />
                Loading filings &amp; exhibits…
              </div>
            )}

            {detailError && (
              <div className="p-3 rounded-lg bg-rose-50 dark:bg-rose-900/20 border border-rose-200 dark:border-rose-800/40 text-xs text-rose-700 dark:text-rose-300 flex items-center gap-2">
                <AlertCircle className="w-4 h-4 shrink-0" />
                {detailError}
              </div>
            )}

            {detail && (
              <>
                <div className="space-y-1.5">
                  <div className="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
                    Filings Under {deal.fileNumber} ({detail.submissions.length})
                  </div>
                  <div className="space-y-1">
                    {detail.submissions.map((sub) => (
                      <div
                        key={sub.folderKey}
                        className="flex items-center justify-between text-xs px-2.5 py-1.5 rounded-md bg-zinc-50 dark:bg-zinc-900/70 border border-zinc-200/70 dark:border-zinc-800"
                      >
                        <div className="flex items-center gap-2 min-w-0">
                          <span className="font-mono font-semibold text-zinc-900 dark:text-zinc-100">
                            {sub.formType}
                          </span>
                          <span className="text-zinc-500 dark:text-zinc-400">
                            {formatFilingDate(sub.filingDate)}
                          </span>
                        </div>
                        <a
                          href={`/filings/${encodeURIComponent(sub.folderKey)}/document`}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="font-mono text-[11px] text-blue-600 dark:text-blue-400 hover:underline flex items-center gap-1"
                        >
                          {sub.accessionNo}
                          <ExternalLink className="w-3 h-3" />
                        </a>
                      </div>
                    ))}
                  </div>
                </div>

                <div className="space-y-1.5 pt-1">
                  <div className="text-[11px] font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
                    Exhibits ({detail.exhibits.length})
                  </div>
                  {detail.exhibits.length === 0 ? (
                    <p className="text-xs text-zinc-500">No exhibits filed on this initial draft.</p>
                  ) : (
                    <div className="space-y-1.5">
                      {detail.exhibits.map((ex) => (
                        <a
                          key={ex.objectPath}
                          href={`/filings/${encodeURIComponent(ex.folderKey)}/exhibits/${encodeURIComponent(ex.filename)}`}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="block p-2.5 rounded-lg bg-zinc-50 dark:bg-zinc-900/70 hover:bg-blue-50/70 dark:hover:bg-blue-950/30 border border-zinc-200/80 dark:border-zinc-800 transition-colors group"
                        >
                          <div className="flex items-start justify-between gap-2">
                            <span className="text-xs font-semibold text-zinc-900 dark:text-zinc-100 group-hover:text-blue-600 dark:group-hover:text-blue-400 flex items-center gap-1.5">
                              <FileCheck2 className="w-3.5 h-3.5 text-emerald-600 dark:text-emerald-400 shrink-0" />
                              {ex.canonicalType ?? 'Exhibit'}
                            </span>
                            <ExternalLink className="w-3 h-3 text-zinc-400 group-hover:text-blue-500 shrink-0 mt-0.5" />
                          </div>
                          <div className="text-[11px] text-zinc-500 dark:text-zinc-400 mt-1 line-clamp-2">
                            {ex.docName}
                          </div>
                          <div className="font-mono text-[10px] text-zinc-400 dark:text-zinc-500 mt-1">
                            {ex.formType} • {formatFilingDate(ex.filingDate)} • {ex.filename}
                          </div>
                        </a>
                      ))}
                    </div>
                  )}
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </aside>
  );
}
