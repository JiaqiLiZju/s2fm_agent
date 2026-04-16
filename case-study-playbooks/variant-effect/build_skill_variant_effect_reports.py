#!/usr/bin/env python3
"""Build per-skill standardized variant-effect reports under each skill folder.

Outputs for each skill directory:
- <skill>_variant_effect_records.tsv
- <skill>_variant_effect_records.json
- <skill>_variant_effect_schema.md
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


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def load_tsv(path: Path) -> List[dict]:
    with path.open(encoding="utf-8") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


def write_tsv(path: Path, columns: List[str], rows: List[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, delimiter="\t")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def write_schema(path: Path, title: str, columns: List[str], notes: List[str], run_root: Path) -> None:
    lines = [
        f"# {title}",
        "",
        f"- generated_at_utc: `{utc_now_iso()}`",
        f"- run_root: `{run_root}`",
        "",
        "## Notes",
    ]
    lines.extend(f"- {n}" for n in notes)
    lines.extend(["", "## Columns"])
    lines.extend(f"- `{c}`" for c in columns)
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build per-skill standardized reports.")
    parser.add_argument(
        "--run-root",
        required=True,
        help="Run root, e.g. case-study-playbooks/variant-effect/20260416T114822Z",
    )
    return parser.parse_args()


def compute_alpha_aggregates(row: dict, tissues: List[str]) -> dict:
    mean_diffs = []
    log2fcs = []
    for t in tissues:
        md = safe_float(row.get(f"{t}_mean_diff"))
        lf = safe_float(row.get(f"{t}_log2fc"))
        if md is not None:
            mean_diffs.append(md)
        if lf is not None:
            log2fcs.append(lf)
    out = {
        "mean_diff_avg": None,
        "mean_diff_abs_avg": None,
        "log2fc_avg": None,
    }
    if mean_diffs:
        out["mean_diff_avg"] = sum(mean_diffs) / len(mean_diffs)
        out["mean_diff_abs_avg"] = sum(abs(x) for x in mean_diffs) / len(mean_diffs)
    if log2fcs:
        out["log2fc_avg"] = sum(log2fcs) / len(log2fcs)
    return out


def build_alphagenome_report(run_root: Path, variants: List[dict]) -> List[Path]:
    skill_dir = run_root / "alphagenome_results"
    source_path = resolve_alphagenome_tsv(run_root)
    if source_path is None:
        return []
    src_rows = load_tsv(source_path)
    if not src_rows:
        return []
    by_key = {variant_key(r["chrom"], r["position"], r["ref"], r["alt"]): r for r in src_rows}
    tissues = sorted(
        c[: -len("_mean_diff")] for c in src_rows[0].keys() if c.endswith("_mean_diff")
    )

    rows = []
    for v in variants:
        k = variant_key(v["chrom"], v["position"], v["ref"], v["alt"])
        src = by_key.get(k, {})
        row = {
            "row_index": v["row_index"],
            "variant_spec": v["variant_spec"],
            "chrom": v["chrom"],
            "position": int(v["position"]),
            "ref": v["ref"],
            "alt": v["alt"],
            "status": src.get("status", ""),
            "error": src.get("error", ""),
            "run_time_utc": src.get("run_time_utc", ""),
            "result_row_id": src.get("vid", ""),
            "assembly": src.get("assembly", ""),
            "source_tsv": str(source_path.resolve()),
        }
        agg = compute_alpha_aggregates(src, tissues) if src else {
            "mean_diff_avg": None,
            "mean_diff_abs_avg": None,
            "log2fc_avg": None,
        }
        row.update(agg)
        for t in tissues:
            row[f"{t}_mean_diff"] = safe_float(src.get(f"{t}_mean_diff"))
            row[f"{t}_log2fc"] = safe_float(src.get(f"{t}_log2fc"))
        rows.append(row)

    cols = [
        "row_index",
        "variant_spec",
        "chrom",
        "position",
        "ref",
        "alt",
        "status",
        "error",
        "run_time_utc",
        "result_row_id",
        "assembly",
        "mean_diff_avg",
        "mean_diff_abs_avg",
        "log2fc_avg",
    ]
    for t in tissues:
        cols.append(f"{t}_mean_diff")
        cols.append(f"{t}_log2fc")
    cols.append("source_tsv")

    tsv_path = skill_dir / "alphagenome_variant_effect_records.tsv"
    json_path = skill_dir / "alphagenome_variant_effect_records.json"
    schema_path = skill_dir / "alphagenome_variant_effect_schema.md"
    write_tsv(tsv_path, cols, rows)
    write_json(
        json_path,
        {
            "skill_id": "alphagenome-api",
            "task": "variant-effect-standardized-records",
            "generated_at_utc": utc_now_iso(),
            "run_root": str(run_root),
            "source_tsv": str(source_path.resolve()),
            "tissues": tissues,
            "row_count": len(rows),
            "columns": cols,
            "rows": rows,
        },
    )
    write_schema(
        schema_path,
        "AlphaGenome Variant Effect Schema",
        cols,
        [
            "`*_mean_diff` is ALT-REF mean signal difference.",
            "`*_log2fc` is log2((ALT+1)/(REF+1)).",
            "`mean_diff_*` and `log2fc_avg` are tissue-level aggregates.",
        ],
        run_root,
    )
    return [tsv_path, json_path, schema_path]


def build_borzoi_report(run_root: Path, variants: List[dict]) -> List[Path]:
    skill_dir = run_root / "borzoi_results"
    source_manifest = skill_dir / "borzoi_variant_batch_manifest.tsv"
    if not source_manifest.exists() or source_manifest.stat().st_size == 0:
        return []
    src_rows = load_tsv(source_manifest)
    by_key = {variant_key(r["chrom"], r["position"], r["ref"], r["alt"]): r for r in src_rows}

    rows = []
    for v in variants:
        k = variant_key(v["chrom"], v["position"], v["ref"], v["alt"])
        src = by_key.get(k, {})
        result_json = src.get("result_json", "")
        result = load_json(Path(result_json)) if result_json and Path(result_json).exists() else {}
        rows.append(
            {
                "row_index": v["row_index"],
                "variant_spec": v["variant_spec"],
                "chrom": v["chrom"],
                "position": int(v["position"]),
                "ref": v["ref"],
                "alt": v["alt"],
                "status": src.get("status", ""),
                "error": src.get("error", ""),
                "exit_code": src.get("exit_code", ""),
                "run_time_utc": result.get("run_time_utc", ""),
                "assembly": result.get("assembly", ""),
                "sad_mean_across_tracks": safe_float(result.get("sad_mean_across_tracks")),
                "sad_max_abs_track_idx": result.get("sad_max_abs_track_idx"),
                "result_json": result_json,
                "variant_tsv": src.get("tsv", ""),
                "trackplot_png": src.get("plot", ""),
                "tracks_npz": src.get("npz", ""),
                "source_manifest": str(source_manifest.resolve()),
            }
        )

    cols = [
        "row_index",
        "variant_spec",
        "chrom",
        "position",
        "ref",
        "alt",
        "status",
        "error",
        "exit_code",
        "run_time_utc",
        "assembly",
        "sad_mean_across_tracks",
        "sad_max_abs_track_idx",
        "result_json",
        "variant_tsv",
        "trackplot_png",
        "tracks_npz",
        "source_manifest",
    ]

    tsv_path = skill_dir / "borzoi_variant_effect_records.tsv"
    json_path = skill_dir / "borzoi_variant_effect_records.json"
    schema_path = skill_dir / "borzoi_variant_effect_schema.md"
    write_tsv(tsv_path, cols, rows)
    write_json(
        json_path,
        {
            "skill_id": "borzoi-workflows",
            "task": "variant-effect-standardized-records",
            "generated_at_utc": utc_now_iso(),
            "run_root": str(run_root),
            "source_manifest": str(source_manifest.resolve()),
            "row_count": len(rows),
            "columns": cols,
            "rows": rows,
        },
    )
    write_schema(
        schema_path,
        "Borzoi Variant Effect Schema",
        cols,
        [
            "`sad_mean_across_tracks` is mean(ALT-REF) across output tracks.",
            "`sad_max_abs_track_idx` is the strongest absolute-effect track index.",
        ],
        run_root,
    )
    return [tsv_path, json_path, schema_path]


def build_evo2_report(run_root: Path, variants: List[dict]) -> List[Path]:
    skill_dir = run_root / "evo2_results"
    source_manifest = skill_dir / "evo2_variant_batch_manifest.tsv"
    if not source_manifest.exists() or source_manifest.stat().st_size == 0:
        return []
    src_rows = load_tsv(source_manifest)
    by_key = {variant_key(r["chrom"], r["position"], r["ref"], r["alt"]): r for r in src_rows}

    rows = []
    for v in variants:
        k = variant_key(v["chrom"], v["position"], v["ref"], v["alt"])
        src = by_key.get(k, {})
        result_json = src.get("result_json", "")
        result = load_json(Path(result_json)) if result_json and Path(result_json).exists() else {}
        rows.append(
            {
                "row_index": v["row_index"],
                "variant_spec": v["variant_spec"],
                "chrom": v["chrom"],
                "position": int(v["position"]),
                "ref": v["ref"],
                "alt": v["alt"],
                "status": src.get("status", ""),
                "error": src.get("error", ""),
                "exit_code": src.get("exit_code", ""),
                "run_time_utc": src.get("run_time_utc", ""),
                "model": result.get("model", ""),
                "assembly": result.get("assembly", ""),
                "delta_top1_at_variant": safe_float(src.get("delta_top1_at_variant")),
                "delta_emb_norm_at_variant": safe_float(src.get("delta_emb_norm_at_variant")),
                "window_len": result.get("window_len"),
                "result_json": result_json,
                "trackplot_png": src.get("plot", ""),
                "source_manifest": str(source_manifest.resolve()),
            }
        )

    cols = [
        "row_index",
        "variant_spec",
        "chrom",
        "position",
        "ref",
        "alt",
        "status",
        "error",
        "exit_code",
        "run_time_utc",
        "model",
        "assembly",
        "delta_top1_at_variant",
        "delta_emb_norm_at_variant",
        "window_len",
        "result_json",
        "trackplot_png",
        "source_manifest",
    ]

    tsv_path = skill_dir / "evo2_variant_effect_records.tsv"
    json_path = skill_dir / "evo2_variant_effect_records.json"
    schema_path = skill_dir / "evo2_variant_effect_schema.md"
    write_tsv(tsv_path, cols, rows)
    write_json(
        json_path,
        {
            "skill_id": "evo2-inference",
            "task": "variant-effect-standardized-records",
            "generated_at_utc": utc_now_iso(),
            "run_root": str(run_root),
            "source_manifest": str(source_manifest.resolve()),
            "row_count": len(rows),
            "columns": cols,
            "rows": rows,
        },
    )
    write_schema(
        schema_path,
        "Evo2 Variant Effect Schema",
        cols,
        [
            "`delta_top1_at_variant` is ALT-REF top-1 logit at variant position.",
            "`delta_emb_norm_at_variant` is embedding difference norm at variant position.",
            "`window_len` records the sequence window length used during scoring.",
        ],
        run_root,
    )
    return [tsv_path, json_path, schema_path]


def build_gpn_report(run_root: Path, variants: List[dict]) -> List[Path]:
    skill_dir = run_root / "gpn_results"
    source_manifest = skill_dir / "gpn_variant_batch_manifest.tsv"
    if not source_manifest.exists() or source_manifest.stat().st_size == 0:
        return []
    src_rows = load_tsv(source_manifest)
    by_key = {variant_key(r["chrom"], r["position"], r["ref"], r["alt"]): r for r in src_rows}

    rows = []
    for v in variants:
        k = variant_key(v["chrom"], v["position"], v["ref"], v["alt"])
        src = by_key.get(k, {})
        result_json = src.get("result_json", "")
        result = load_json(Path(result_json)) if result_json and Path(result_json).exists() else {}
        rows.append(
            {
                "row_index": v["row_index"],
                "variant_spec": v["variant_spec"],
                "chrom": v["chrom"],
                "position": int(v["position"]),
                "ref": v["ref"],
                "alt": v["alt"],
                "status": src.get("status", ""),
                "error": src.get("error", ""),
                "exit_code": src.get("exit_code", ""),
                "run_time_utc": src.get("run_time_utc", ""),
                "model": result.get("model", ""),
                "genome": result.get("genome", ""),
                "llr_fwd": safe_float(result.get("llr_fwd")),
                "llr_rev": safe_float(result.get("llr_rev")),
                "llr_mean": safe_float(result.get("llr_mean")),
                "result_json": result_json,
                "source_manifest": str(source_manifest.resolve()),
            }
        )

    cols = [
        "row_index",
        "variant_spec",
        "chrom",
        "position",
        "ref",
        "alt",
        "status",
        "error",
        "exit_code",
        "run_time_utc",
        "model",
        "genome",
        "llr_fwd",
        "llr_rev",
        "llr_mean",
        "result_json",
        "source_manifest",
    ]

    tsv_path = skill_dir / "gpn_variant_effect_records.tsv"
    json_path = skill_dir / "gpn_variant_effect_records.json"
    schema_path = skill_dir / "gpn_variant_effect_schema.md"
    write_tsv(tsv_path, cols, rows)
    write_json(
        json_path,
        {
            "skill_id": "gpn-models",
            "task": "variant-effect-standardized-records",
            "generated_at_utc": utc_now_iso(),
            "run_root": str(run_root),
            "source_manifest": str(source_manifest.resolve()),
            "row_count": len(rows),
            "columns": cols,
            "rows": rows,
        },
    )
    write_schema(
        schema_path,
        "GPN Variant Effect Schema",
        cols,
        [
            "`llr_fwd`/`llr_rev` are strand-wise logit(ALT)-logit(REF).",
            "`llr_mean` is the average of forward and reverse strand LLR.",
        ],
        run_root,
    )
    return [tsv_path, json_path, schema_path]


def main() -> int:
    args = parse_args()
    run_root = Path(args.run_root).resolve()
    variants_path = run_root / "logs" / "variants_manifest.tsv"
    variants = load_tsv(variants_path)

    generated: List[Path] = []
    generated.extend(build_alphagenome_report(run_root, variants))
    generated.extend(build_borzoi_report(run_root, variants))
    generated.extend(build_evo2_report(run_root, variants))
    generated.extend(build_gpn_report(run_root, variants))

    for p in generated:
        print(str(p))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
