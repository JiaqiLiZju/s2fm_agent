#!/usr/bin/env python3
"""Build a unified per-variant effect report across AlphaGenome/Borzoi/Evo2/GPN.

Outputs (under <run_root>/logs):
- unified_variant_effect_records.tsv
- unified_variant_effect_records.json
- unified_variant_effect_schema.md
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
from pathlib import Path
from typing import Dict, List, Tuple


def utc_now_iso() -> str:
    return dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def variant_key(chrom: str, position: str | int, ref: str, alt: str) -> Tuple[str, str, str, str]:
    return str(chrom), str(position), str(ref).upper(), str(alt).upper()


def safe_float(v):
    if v is None or v == "":
        return None
    try:
        return float(v)
    except Exception:
        return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build unified variant effect report.")
    parser.add_argument(
        "--run-root",
        required=True,
        help="Run root, e.g. case-study-playbooks/variant-effect/20260416T114822Z",
    )
    return parser.parse_args()


def load_variants_manifest(path: Path) -> List[dict]:
    with path.open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def load_alphagenome(path: Path) -> Tuple[Dict[Tuple[str, str, str, str], dict], List[str]]:
    if path is None or not path.exists() or path.stat().st_size == 0:
        return {}, []
    with path.open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    if not rows:
        return {}, []

    tissue_mean_cols = [c for c in rows[0].keys() if c.endswith("_mean_diff")]
    tissues = sorted(c[: -len("_mean_diff")] for c in tissue_mean_cols)

    out = {}
    for r in rows:
        k = variant_key(r["chrom"], r["position"], r["ref"], r["alt"])
        out[k] = r
    return out, tissues


def load_tsv_by_key(
    path: Path,
    chrom_col: str = "chrom",
    pos_col: str = "position",
    ref_col: str = "ref",
    alt_col: str = "alt",
) -> Dict[Tuple[str, str, str, str], dict]:
    if path is None or not path.exists() or path.stat().st_size == 0:
        return {}
    with path.open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    out = {}
    for r in rows:
        k = variant_key(r[chrom_col], r[pos_col], r[ref_col], r[alt_col])
        out[k] = r
    return out


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def resolve_alphagenome_tsv(run_root: Path) -> Path | None:
    summary = run_root / "alphagenome_results" / "alphagenome_variant_batch_summary.json"
    if summary.exists() and summary.stat().st_size > 0:
        payload = load_json(summary)
        result_tsv = payload.get("result_tsv", "")
        if result_tsv:
            p = Path(result_tsv)
            if p.exists() and p.stat().st_size > 0:
                return p

    candidates = sorted((run_root / "alphagenome_results").glob("*_tissues.tsv"))
    for candidate in candidates:
        if candidate.exists() and candidate.stat().st_size > 0:
            return candidate
    return None


def compute_alpha_aggregates(alpha_row: dict, tissues: List[str]) -> dict:
    mean_diffs = []
    log2fcs = []
    for t in tissues:
        md = safe_float(alpha_row.get(f"{t}_mean_diff"))
        lf = safe_float(alpha_row.get(f"{t}_log2fc"))
        if md is not None:
            mean_diffs.append(md)
        if lf is not None:
            log2fcs.append(lf)

    result = {
        "alphagenome_mean_diff_avg": None,
        "alphagenome_mean_diff_abs_avg": None,
        "alphagenome_log2fc_avg": None,
    }
    if mean_diffs:
        result["alphagenome_mean_diff_avg"] = sum(mean_diffs) / len(mean_diffs)
        result["alphagenome_mean_diff_abs_avg"] = sum(abs(x) for x in mean_diffs) / len(mean_diffs)
    if log2fcs:
        result["alphagenome_log2fc_avg"] = sum(log2fcs) / len(log2fcs)
    return result


def main() -> int:
    args = parse_args()
    run_root = Path(args.run_root).resolve()
    logs_dir = run_root / "logs"
    logs_dir.mkdir(parents=True, exist_ok=True)

    variants_path = logs_dir / "variants_manifest.tsv"
    alpha_path = resolve_alphagenome_tsv(run_root)
    borzoi_manifest_path = run_root / "borzoi_results" / "borzoi_variant_batch_manifest.tsv"
    evo2_manifest_path = run_root / "evo2_results" / "evo2_variant_batch_manifest.tsv"
    gpn_manifest_path = run_root / "gpn_results" / "gpn_variant_batch_manifest.tsv"

    variants = load_variants_manifest(variants_path)
    alpha_by_key, tissues = load_alphagenome(alpha_path)
    borzoi_by_key = load_tsv_by_key(borzoi_manifest_path)
    evo2_by_key = load_tsv_by_key(evo2_manifest_path)
    gpn_by_key = load_tsv_by_key(gpn_manifest_path)

    rows: List[dict] = []
    for v in variants:
        key = variant_key(v["chrom"], v["position"], v["ref"], v["alt"])
        row = {
            "row_index": v["row_index"],
            "variant_spec": v["variant_spec"],
            "chrom": v["chrom"],
            "position": int(v["position"]),
            "ref": v["ref"],
            "alt": v["alt"],
        }

        # AlphaGenome
        a = alpha_by_key.get(key)
        row["alphagenome_status"] = ""
        row["alphagenome_run_time_utc"] = ""
        row["alphagenome_result_row_id"] = ""
        if a:
            row["alphagenome_status"] = a.get("status", "")
            row["alphagenome_run_time_utc"] = a.get("run_time_utc", "")
            row["alphagenome_result_row_id"] = a.get("vid", "")
            aggs = compute_alpha_aggregates(a, tissues)
            row.update(aggs)
            for t in tissues:
                row[f"alphagenome_{t}_mean_diff"] = safe_float(a.get(f"{t}_mean_diff"))
                row[f"alphagenome_{t}_log2fc"] = safe_float(a.get(f"{t}_log2fc"))
        else:
            row["alphagenome_mean_diff_avg"] = None
            row["alphagenome_mean_diff_abs_avg"] = None
            row["alphagenome_log2fc_avg"] = None
            for t in tissues:
                row[f"alphagenome_{t}_mean_diff"] = None
                row[f"alphagenome_{t}_log2fc"] = None

        # Borzoi
        b = borzoi_by_key.get(key)
        row["borzoi_status"] = ""
        row["borzoi_run_time_utc"] = ""
        row["borzoi_sad_mean_across_tracks"] = None
        row["borzoi_sad_max_abs_track_idx"] = None
        row["borzoi_result_json"] = ""
        if b:
            row["borzoi_status"] = b.get("status", "")
            row["borzoi_result_json"] = b.get("result_json", "")
            if row["borzoi_result_json"]:
                p = Path(row["borzoi_result_json"])
                if p.exists():
                    bj = load_json(p)
                    row["borzoi_run_time_utc"] = bj.get("run_time_utc", "")
                    row["borzoi_sad_mean_across_tracks"] = safe_float(
                        bj.get("sad_mean_across_tracks")
                    )
                    row["borzoi_sad_max_abs_track_idx"] = bj.get("sad_max_abs_track_idx")

        # Evo2
        e = evo2_by_key.get(key)
        row["evo2_status"] = ""
        row["evo2_run_time_utc"] = ""
        row["evo2_delta_top1_at_variant"] = None
        row["evo2_delta_emb_norm_at_variant"] = None
        row["evo2_window_len"] = None
        row["evo2_result_json"] = ""
        if e:
            row["evo2_status"] = e.get("status", "")
            row["evo2_run_time_utc"] = e.get("run_time_utc", "")
            row["evo2_delta_top1_at_variant"] = safe_float(e.get("delta_top1_at_variant"))
            row["evo2_delta_emb_norm_at_variant"] = safe_float(e.get("delta_emb_norm_at_variant"))
            row["evo2_result_json"] = e.get("result_json", "")
            if row["evo2_result_json"]:
                p = Path(row["evo2_result_json"])
                if p.exists():
                    ej = load_json(p)
                    row["evo2_window_len"] = ej.get("window_len")

        # GPN
        g = gpn_by_key.get(key)
        row["gpn_status"] = ""
        row["gpn_run_time_utc"] = ""
        row["gpn_llr_fwd"] = None
        row["gpn_llr_rev"] = None
        row["gpn_llr_mean"] = None
        row["gpn_model"] = ""
        row["gpn_result_json"] = ""
        if g:
            row["gpn_status"] = g.get("status", "")
            row["gpn_run_time_utc"] = g.get("run_time_utc", "")
            row["gpn_result_json"] = g.get("result_json", "")
            if row["gpn_result_json"]:
                p = Path(row["gpn_result_json"])
                if p.exists():
                    gj = load_json(p)
                    row["gpn_llr_fwd"] = safe_float(gj.get("llr_fwd"))
                    row["gpn_llr_rev"] = safe_float(gj.get("llr_rev"))
                    row["gpn_llr_mean"] = safe_float(gj.get("llr_mean"))
                    row["gpn_model"] = gj.get("model", "")

        row["all_models_success"] = (
            row["alphagenome_status"] == "success"
            and row["borzoi_status"] == "success"
            and row["evo2_status"] == "success"
            and row["gpn_status"] == "success"
        )
        rows.append(row)

    # Column order (stable)
    cols = [
        "row_index",
        "variant_spec",
        "chrom",
        "position",
        "ref",
        "alt",
        "alphagenome_status",
        "alphagenome_run_time_utc",
        "alphagenome_result_row_id",
        "alphagenome_mean_diff_avg",
        "alphagenome_mean_diff_abs_avg",
        "alphagenome_log2fc_avg",
    ]
    for t in tissues:
        cols.append(f"alphagenome_{t}_mean_diff")
        cols.append(f"alphagenome_{t}_log2fc")
    cols += [
        "borzoi_status",
        "borzoi_run_time_utc",
        "borzoi_sad_mean_across_tracks",
        "borzoi_sad_max_abs_track_idx",
        "borzoi_result_json",
        "evo2_status",
        "evo2_run_time_utc",
        "evo2_delta_top1_at_variant",
        "evo2_delta_emb_norm_at_variant",
        "evo2_window_len",
        "evo2_result_json",
        "gpn_status",
        "gpn_run_time_utc",
        "gpn_llr_fwd",
        "gpn_llr_rev",
        "gpn_llr_mean",
        "gpn_model",
        "gpn_result_json",
        "all_models_success",
    ]

    tsv_out = logs_dir / "unified_variant_effect_records.tsv"
    with tsv_out.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=cols, delimiter="\t")
        writer.writeheader()
        for r in rows:
            writer.writerow(r)

    json_out = logs_dir / "unified_variant_effect_records.json"
    payload = {
        "task": "variant-effect-unified-report",
        "generated_at_utc": utc_now_iso(),
        "run_root": str(run_root),
        "row_count": len(rows),
        "tissues": tissues,
        "columns": cols,
        "rows": rows,
    }
    json_out.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    schema_out = logs_dir / "unified_variant_effect_schema.md"
    schema_out.write_text(
        "\n".join(
            [
                "# Unified Variant Effect Schema",
                "",
                f"- generated_at_utc: `{payload['generated_at_utc']}`",
                f"- run_root: `{run_root}`",
                f"- row_count: `{len(rows)}`",
                "",
                "## Key Interpretation Notes",
                "- `alphagenome_*_mean_diff`: ALT - REF tissue-level average signal difference.",
                "- `alphagenome_*_log2fc`: log2((ALT+1)/(REF+1)) tissue-level fold change.",
                "- `borzoi_sad_mean_across_tracks`: mean(ALT - REF) across Borzoi tracks.",
                "- `evo2_delta_top1_at_variant`: ALT - REF top-1 logit at variant position.",
                "- `evo2_delta_emb_norm_at_variant`: ||ALT-REF|| embedding difference at variant.",
                "- `gpn_llr_mean`: mean strand logit difference (ALT - REF).",
                "- `all_models_success`: all four model runs succeeded for this variant.",
                "",
                "## Columns",
            ]
            + [f"- `{c}`" for c in cols]
            + [""]
        ),
        encoding="utf-8",
    )

    print(str(tsv_out))
    print(str(json_out))
    print(str(schema_out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
