#!/usr/bin/env python3
"""
Flattens SEC EDGAR's bulk XBRL `companyfacts.zip` archive (or individual `CIK##########.json`
files) into gzipped NDJSON shards ready for partitioned + clustered BigQuery ingestion.

Standard library only. Uses multi-core worker processes so all ~18,800 SEC registrants
(~120M+ XBRL facts) stream directly from `companyfacts.zip` into compressed shards
without extracting intermediate raw files to disk.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import datetime
import gzip
import json
import math
import os
from pathlib import Path
import re
import sys
import time
import zipfile

CAMEL_SPLIT_RE = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")

_DATE_CACHE: dict[str, tuple[str | None, int | None]] = {}


def parse_iso_date(raw: object) -> tuple[str | None, int | None]:
    if not isinstance(raw, str) or len(raw) != 10:
        return None, None
    cached = _DATE_CACHE.get(raw)
    if cached is not None:
        return cached
    try:
        dt = datetime.date.fromisoformat(raw)
        if dt.year < 1900 or dt.year > 2100:
            res = (None, None)
        else:
            res = (raw, dt.toordinal())
    except ValueError:
        res = (None, None)
    if len(_DATE_CACHE) < 65536:
        _DATE_CACHE[raw] = res
    return res


def humanize_concept(concept: str) -> str:
    spaced = CAMEL_SPLIT_RE.sub(" ", concept).replace("_", " ").strip()
    return spaced if spaced else concept


def parse_cik_payload(
    raw_bytes: bytes,
    corpus_ciks: set[int],
    out_all_lines: list[str],
    out_corpus_lines: list[str] | None,
) -> tuple[int, bool, int]:
    """Returns (cik_int, is_corpus, fact_count)."""
    doc = json.loads(raw_bytes)
    if not isinstance(doc, dict):
        return 0, False, 0

    raw_cik = doc.get("cik")
    if raw_cik is None:
        return 0, False, 0
    try:
        cik_int = int(str(raw_cik).strip())
    except ValueError:
        return 0, False, 0
    if cik_int <= 0:
        return 0, False, 0

    cik_padded = f"{cik_int:010d}"
    is_corpus = cik_int in corpus_ciks
    entity_name_raw = doc.get("entityName")
    entity_name = str(entity_name_raw).strip() if entity_name_raw else None

    facts_root = doc.get("facts")
    if not isinstance(facts_root, dict) or not facts_root:
        return cik_int, is_corpus, 0

    # Pre-encode CIK-constant prefix once per registrant for high throughput
    cik_prefix = (
        f'{{"cik":"{cik_padded}","cik_int":{cik_int},'
        f'"entity_name":{json.dumps(entity_name, ensure_ascii=False)},'
        f'"is_corpus_cik":{"true" if is_corpus else "false"},'
    )

    fact_count = 0
    dumps = json.dumps

    for taxonomy, concepts in facts_root.items():
        if not isinstance(concepts, dict):
            continue
        tax_json = dumps(str(taxonomy), ensure_ascii=False)

        for concept, meta in concepts.items():
            if not isinstance(meta, dict):
                continue
            units = meta.get("units")
            if not isinstance(units, dict):
                continue

            raw_label = meta.get("label")
            label_str = (
                str(raw_label).strip()
                if isinstance(raw_label, str) and raw_label.strip()
                else humanize_concept(str(concept))
            )
            concept_prefix = (
                f'{cik_prefix}"taxonomy":{tax_json},'
                f'"concept":{dumps(str(concept), ensure_ascii=False)},'
                f'"label":{dumps(label_str, ensure_ascii=False)},'
            )

            for unit_name, items in units.items():
                if not isinstance(items, list) or not items:
                    continue
                unit_prefix = f'{concept_prefix}"unit":{dumps(str(unit_name), ensure_ascii=False)},'

                for item in items:
                    if not isinstance(item, dict):
                        continue

                    raw_val = item.get("val")
                    val_num_json = "null"
                    val_str_json = "null"
                    if isinstance(raw_val, bool):
                        val_num_json = "1.0" if raw_val else "0.0"
                    elif isinstance(raw_val, (int, float)):
                        fval = float(raw_val)
                        if math.isfinite(fval):
                            val_num_json = repr(fval)
                        else:
                            continue
                    elif raw_val is not None:
                        sval = str(raw_val).strip()
                        if not sval:
                            continue
                        val_str_json = dumps(sval[:500], ensure_ascii=False)
                    else:
                        continue

                    start_iso, start_ord = parse_iso_date(item.get("start"))
                    end_iso, end_ord = parse_iso_date(item.get("end"))
                    filed_iso, _ = parse_iso_date(item.get("filed"))

                    is_instant = start_iso is None
                    duration_json = "null"
                    if start_ord is not None and end_ord is not None:
                        diff = end_ord - start_ord
                        if -3660 <= diff <= 36600:
                            duration_json = str(diff)

                    raw_fy = item.get("fy")
                    fy_json = "null"
                    if isinstance(raw_fy, int) and not isinstance(raw_fy, bool):
                        if 1900 <= raw_fy <= 2100:
                            fy_json = str(raw_fy)

                    fp = item.get("fp")
                    fp_json = dumps(fp, ensure_ascii=False) if isinstance(fp, str) and fp else "null"
                    form = item.get("form")
                    form_json = dumps(form, ensure_ascii=False) if isinstance(form, str) and form else "null"
                    frame = item.get("frame")
                    frame_json = dumps(frame, ensure_ascii=False) if isinstance(frame, str) and frame else "null"
                    accn = item.get("accn")
                    accn_json = dumps(accn, ensure_ascii=False) if isinstance(accn, str) and accn else "null"

                    start_json = f'"{start_iso}"' if start_iso else "null"
                    end_json = f'"{end_iso}"' if end_iso else "null"
                    filed_json = f'"{filed_iso}"' if filed_iso else "null"
                    inst_json = "true" if is_instant else "false"

                    line = (
                        f'{unit_prefix}"val":{val_num_json},"val_str":{val_str_json},'
                        f'"start_date":{start_json},"end_date":{end_json},'
                        f'"duration_days":{duration_json},"is_instant":{inst_json},'
                        f'"filed":{filed_json},"fy":{fy_json},"fp":{fp_json},'
                        f'"form":{form_json},"frame":{frame_json},"accn":{accn_json}}}\n'
                    )
                    out_all_lines.append(line)
                    if is_corpus and out_corpus_lines is not None:
                        out_corpus_lines.append(line)
                    fact_count += 1

    return cik_int, is_corpus, fact_count


def _worker_process_shard(
    worker_id: int,
    num_workers: int,
    zip_path: str,
    corpus_ciks: set[int],
    out_dir: str,
) -> dict[str, int]:
    all_shard_path = Path(out_dir) / "all" / f"part-{worker_id:02d}.jsonl.gz"
    corpus_shard_path = Path(out_dir) / "corpus" / f"part-{worker_id:02d}.jsonl.gz"
    raw_corpus_dir = Path(out_dir) / "raw_corpus_json"

    total_files = 0
    corpus_files = 0
    total_facts = 0
    corpus_facts = 0
    skipped_files = 0

    all_buf: list[str] = []
    corpus_buf: list[str] = []

    with (
        zipfile.ZipFile(zip_path, "r") as zf,
        gzip.open(all_shard_path, "wt", encoding="utf-8", compresslevel=3) as gz_all,
        gzip.open(corpus_shard_path, "wt", encoding="utf-8", compresslevel=3) as gz_corpus,
    ):
        members = [m for m in zf.namelist() if m.endswith(".json")][worker_id::num_workers]
        for member in members:
            try:
                raw_bytes = zf.read(member)
                if not raw_bytes:
                    skipped_files += 1
                    continue
                cik_int, is_corpus, count = parse_cik_payload(
                    raw_bytes=raw_bytes,
                    corpus_ciks=corpus_ciks,
                    out_all_lines=all_buf,
                    out_corpus_lines=corpus_buf,
                )
                if cik_int > 0:
                    total_files += 1
                    total_facts += count
                    if is_corpus:
                        corpus_files += 1
                        corpus_facts += count
                        raw_out = raw_corpus_dir / f"CIK{cik_int:010d}.json"
                        raw_out.write_bytes(raw_bytes)
            except Exception:
                skipped_files += 1
                continue

            if len(all_buf) >= 25000:
                gz_all.writelines(all_buf)
                all_buf.clear()
            if len(corpus_buf) >= 10000:
                gz_corpus.writelines(corpus_buf)
                corpus_buf.clear()

        if all_buf:
            gz_all.writelines(all_buf)
            all_buf.clear()
        if corpus_buf:
            gz_corpus.writelines(corpus_buf)
            corpus_buf.clear()

    return {
        "worker_id": worker_id,
        "total_files": total_files,
        "corpus_files": corpus_files,
        "total_facts": total_facts,
        "corpus_facts": corpus_facts,
        "skipped_files": skipped_files,
    }


def load_corpus_ciks(path: str | None) -> set[int]:
    if not path:
        return set()
    p = Path(path)
    if not p.exists():
        return set()
    ciks: set[int] = set()
    for line in p.read_text(encoding="utf-8").splitlines():
        s = line.strip().strip('"')
        if not s or s.lower() == "cik":
            continue
        try:
            ciks.add(int(s))
        except ValueError:
            continue
    return ciks


def main() -> int:
    parser = argparse.ArgumentParser(description="Flatten SEC companyfacts.zip into gzipped NDJSON shards.")
    parser.add_argument("--zip", dest="zip_path", help="Path to companyfacts.zip")
    parser.add_argument("--single-json", dest="single_json", help="Test mode: path to a single CIK##########.json")
    parser.add_argument("--corpus-ciks-file", dest="corpus_ciks_file", help="Path to newline-delimited corpus CIKs")
    parser.add_argument("--out-dir", dest="out_dir", required=True, help="Output directory for shards")
    parser.add_argument("--workers", dest="workers", type=int, default=max(1, os.cpu_count() or 4))
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    (out_dir / "all").mkdir(parents=True, exist_ok=True)
    (out_dir / "corpus").mkdir(parents=True, exist_ok=True)
    (out_dir / "raw_corpus_json").mkdir(parents=True, exist_ok=True)

    corpus_ciks = load_corpus_ciks(args.corpus_ciks_file)
    print(f"[companyfacts] Loaded {len(corpus_ciks):,} corpus CIKs.", flush=True)

    t0 = time.time()

    if args.single_json:
        raw_bytes = Path(args.single_json).read_bytes()
        all_lines: list[str] = []
        corpus_lines: list[str] = []
        cik_int, is_corpus, fact_count = parse_cik_payload(
            raw_bytes=raw_bytes,
            corpus_ciks=corpus_ciks,
            out_all_lines=all_lines,
            out_corpus_lines=corpus_lines,
        )
        with gzip.open(out_dir / "all" / "part-00.jsonl.gz", "wt", encoding="utf-8") as f:
            f.writelines(all_lines)
        with gzip.open(out_dir / "corpus" / "part-00.jsonl.gz", "wt", encoding="utf-8") as f:
            f.writelines(corpus_lines)
        print(
            f"[companyfacts] Single file CIK={cik_int:010d} is_corpus={is_corpus} "
            f"facts={fact_count:,} in {time.time() - t0:.2f}s",
            flush=True,
        )
        return 0

    if not args.zip_path or not Path(args.zip_path).exists():
        print("Error: --zip or --single-json must point to an existing file.", file=sys.stderr)
        return 1

    num_workers = max(1, args.workers)
    print(f"[companyfacts] Processing {args.zip_path} across {num_workers} workers...", flush=True)

    agg = {
        "total_files": 0,
        "corpus_files": 0,
        "total_facts": 0,
        "corpus_facts": 0,
        "skipped_files": 0,
    }

    with ProcessPoolExecutor(max_workers=num_workers) as pool:
        futures = [
            pool.submit(
                _worker_process_shard,
                w,
                num_workers,
                args.zip_path,
                corpus_ciks,
                str(out_dir),
            )
            for w in range(num_workers)
        ]
        for fut in as_completed(futures):
            stats = fut.result()
            for k in agg:
                agg[k] += stats[k]
            print(
                f"  worker {stats['worker_id']:02d} done: "
                f"files={stats['total_files']:,} (corpus={stats['corpus_files']:,}), "
                f"facts={stats['total_facts']:,} (corpus={stats['corpus_facts']:,})",
                flush=True,
            )

    elapsed = time.time() - t0
    manifest = {
        **agg,
        "corpus_ciks_requested": len(corpus_ciks),
        "elapsed_seconds": round(elapsed, 2),
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[companyfacts] Complete in {elapsed:.1f}s: {json.dumps(manifest)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
