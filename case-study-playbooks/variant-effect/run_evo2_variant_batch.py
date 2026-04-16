#!/usr/bin/env python3
"""Run Evo2 variant-effect batch from a normalized variant manifest.

This script is intentionally local to the case-study playbook so we can run
strict VCF REF/ALT batch evaluation without changing shared skill scripts.
"""

from __future__ import annotations

import argparse
import base64
import csv
import datetime as dt
import io
import json
import os
import signal
import time
import zipfile
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import requests


ENSEMBL_BASE = "https://rest.ensembl.org/sequence/region/human"
UCSC_BASE = "https://api.genome.ucsc.edu/getData/sequence"
EVO2_MODEL = "evo2-7b"
EVO2_BASE = f"https://health.api.nvidia.com/v1/biology/arc/{EVO2_MODEL}"
EVO2_FORWARD_FALLBACK_BASE = "https://health.api.nvidia.com/v1/biology/arc/evo2-40b"
VALID_BASES = {"A", "C", "G", "T"}


def utc_now_iso() -> str:
    return dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def normalize_chrom_for_workflow(chrom: str) -> str:
    text = chrom.strip()
    return text[3:] if text.lower().startswith("chr") else text


def with_chr_prefix(chrom: str) -> str:
    text = chrom.strip()
    return text if text.lower().startswith("chr") else f"chr{text}"


def fetch_hg38_sequence(chrom: str, start_1based: int, end_1based: int) -> str:
    if start_1based <= 0 or end_1based < start_1based:
        raise ValueError("Invalid coordinate range")

    ensembl_url = (
        f"{ENSEMBL_BASE}/{chrom}:{start_1based}..{end_1based}:1"
        "?coord_system_version=GRCh38"
    )

    seq = ""
    for attempt in range(1, 4):
        resp = requests.get(
            ensembl_url, headers={"Content-Type": "text/plain"}, timeout=120
        )
        if resp.status_code == 200:
            seq = resp.text.strip().upper()
            break
        time.sleep(1.5 * attempt)

    if not seq:
        ucsc_params = {
            "genome": "hg38",
            "chrom": with_chr_prefix(chrom),
            "start": start_1based - 1,
            "end": end_1based,
        }
        ucsc_resp = requests.get(UCSC_BASE, params=ucsc_params, timeout=120)
        if ucsc_resp.status_code != 200:
            raise RuntimeError(
                "Failed to fetch sequence from Ensembl and UCSC "
                f"(Ensembl URL: {ensembl_url}, UCSC status: {ucsc_resp.status_code})"
            )
        seq = ucsc_resp.json().get("dna", "").strip().upper()

    expected_len = end_1based - start_1based + 1
    if len(seq) != expected_len:
        raise RuntimeError(
            f"Sequence length mismatch: expected {expected_len}, got {len(seq)}"
        )
    return seq


def run_with_wall_timeout(timeout_sec: float, fn):
    if timeout_sec <= 0:
        return fn()
    if not hasattr(signal, "SIGALRM"):
        return fn()

    def _handler(signum, frame):
        raise TimeoutError(f"wall-timeout>{timeout_sec}s")

    prev_handler = signal.signal(signal.SIGALRM, _handler)
    signal.setitimer(signal.ITIMER_REAL, float(timeout_sec))
    try:
        return fn()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, prev_handler)


def evo2_forward(
    api_key: str,
    sequence: str,
    output_layer: str,
    request_timeout_sec: float,
    wall_timeout_sec: float,
    max_attempts: int,
) -> np.ndarray:
    payload = {"sequence": sequence, "output_layers": [output_layer]}
    bases = [EVO2_BASE, EVO2_FORWARD_FALLBACK_BASE]
    all_errors: list[str] = []

    for base in bases:
        last_err = None
        for attempt in range(1, max_attempts + 1):
            try:
                print(
                    f"[EVO2][FORWARD] layer={output_layer} base={base.rsplit('/', 1)[-1]} attempt={attempt}",
                    flush=True,
                )
                def _request_and_decode():
                    resp = requests.post(
                        f"{base}/forward",
                        headers={"Authorization": f"Bearer {api_key}"},
                        json=payload,
                        timeout=request_timeout_sec,
                    )
                    if resp.status_code != 200:
                        return resp, None

                    data_b64 = resp.json()["data"]
                    decoded = base64.b64decode(data_b64)
                    with zipfile.ZipFile(io.BytesIO(decoded)) as zf:
                        target = None
                        for name in zf.namelist():
                            if name.startswith(f"{output_layer}.") and name.endswith(".npy"):
                                target = name
                                break
                        if target is None:
                            raise RuntimeError(
                                f"Layer {output_layer} not found in forward response"
                            )
                        return resp, np.load(io.BytesIO(zf.read(target)))

                resp, layer_arr = run_with_wall_timeout(wall_timeout_sec, _request_and_decode)
            except (requests.RequestException, TimeoutError) as exc:
                last_err = (
                    f"base={base}, attempt={attempt}, "
                    f"request_error={type(exc).__name__}: {exc}"
                )
                time.sleep(1.5 * attempt)
                continue
            except Exception as exc:
                last_err = (
                    f"base={base}, attempt={attempt}, "
                    f"decode_error={type(exc).__name__}: {exc}"
                )
                time.sleep(1.5 * attempt)
                continue

            if resp.status_code == 200 and layer_arr is not None:
                return layer_arr

            last_err = (
                f"base={base}, attempt={attempt}, "
                f"status={resp.status_code}, body={resp.text}"
            )
            time.sleep(1.5 * attempt)

        all_errors.append(last_err or f"base={base}, unknown error")

    raise RuntimeError("Forward request failed: " + " | ".join(all_errors))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run Evo2 variant-effect batch using strict VCF REF/ALT."
    )
    parser.add_argument("--variant-manifest", required=True, help="Input TSV manifest.")
    parser.add_argument("--output-dir", required=True, help="Output directory.")
    parser.add_argument(
        "--manifest-out",
        default="",
        help="Output TSV manifest path. Default: <output-dir>/evo2_variant_batch_manifest.tsv",
    )
    parser.add_argument(
        "--summary-json",
        default="",
        help="Output summary JSON path. Default: <output-dir>/evo2_variant_batch_summary.json",
    )
    parser.add_argument(
        "--window-len",
        type=int,
        default=2048,
        help="Window length around each variant, must be even (default: 2048).",
    )
    parser.add_argument(
        "--continue-on-error",
        type=int,
        default=1,
        choices=[0, 1],
        help="Continue after failures (1) or stop early (0).",
    )
    parser.add_argument(
        "--forward-timeout-sec",
        type=float,
        default=30.0,
        help="Requests timeout seconds for each Evo2 forward request (default: 30).",
    )
    parser.add_argument(
        "--forward-wall-timeout-sec",
        type=float,
        default=45.0,
        help="Hard wall timeout seconds for each forward request+decode (default: 45).",
    )
    parser.add_argument(
        "--forward-max-attempts",
        type=int,
        default=3,
        help="Max attempts per endpoint for Evo2 forward requests (default: 3).",
    )
    return parser.parse_args()


def load_api_key() -> str:
    key = os.getenv("NVCF_RUN_KEY") or os.getenv("EVO2_API_KEY")
    if key:
        return key
    ngc = os.getenv("NGC_API_KEY", "").strip()
    if ngc:
        return ngc if ngc.startswith("nvapi-") else f"nvapi-{ngc}"
    raise RuntimeError("Missing API key: set NVCF_RUN_KEY or EVO2_API_KEY or NGC_API_KEY")


def parse_variant_manifest(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    required = {"row_index", "chrom", "position", "ref", "alt"}
    if not rows:
        raise RuntimeError(f"Variant manifest is empty: {path}")
    missing = required.difference(rows[0].keys())
    if missing:
        raise RuntimeError(f"Variant manifest missing required columns: {sorted(missing)}")
    return rows


def run_one_variant(
    api_key: str,
    output_dir: Path,
    chrom_with_chr: str,
    position_1based: int,
    ref_base: str,
    alt_base: str,
    window_len: int,
    forward_timeout_sec: float,
    forward_wall_timeout_sec: float,
    forward_max_attempts: int,
) -> dict:
    if window_len % 2 != 0:
        raise ValueError("--window-len must be even")
    if ref_base not in VALID_BASES or alt_base not in VALID_BASES:
        raise ValueError(f"Only SNP A/C/G/T supported, got {ref_base}>{alt_base}")
    if ref_base == alt_base:
        raise ValueError(f"ALT equals REF ({alt_base})")

    chrom_for_fetch = normalize_chrom_for_workflow(chrom_with_chr)
    half = window_len // 2
    start_1based = position_1based - half + 1
    end_1based = start_1based + window_len - 1
    if start_1based <= 0:
        raise ValueError(f"Window start <= 0 for {chrom_with_chr}:{position_1based}")

    ref_base_genome = fetch_hg38_sequence(chrom_for_fetch, position_1based, position_1based)
    if ref_base_genome != ref_base:
        raise RuntimeError(
            f"REF mismatch with genome at {chrom_with_chr}:{position_1based}: "
            f"VCF={ref_base}, genome={ref_base_genome}"
        )

    ref_window = fetch_hg38_sequence(chrom_for_fetch, start_1based, end_1based)
    variant_index = position_1based - start_1based
    if ref_window[variant_index] != ref_base:
        raise RuntimeError("Reference base mismatch at variant index")

    alt_window = ref_window[:variant_index] + alt_base + ref_window[variant_index + 1 :]

    ref_unembed = evo2_forward(
        api_key=api_key,
        sequence=ref_window,
        output_layer="unembed",
        request_timeout_sec=forward_timeout_sec,
        wall_timeout_sec=forward_wall_timeout_sec,
        max_attempts=forward_max_attempts,
    )[0]
    alt_unembed = evo2_forward(
        api_key=api_key,
        sequence=alt_window,
        output_layer="unembed",
        request_timeout_sec=forward_timeout_sec,
        wall_timeout_sec=forward_wall_timeout_sec,
        max_attempts=forward_max_attempts,
    )[0]
    ref_top1 = ref_unembed.max(axis=-1)
    alt_top1 = alt_unembed.max(axis=-1)
    delta_top1 = alt_top1 - ref_top1

    ref_emb = evo2_forward(
        api_key=api_key,
        sequence=ref_window,
        output_layer="embedding_layer",
        request_timeout_sec=forward_timeout_sec,
        wall_timeout_sec=forward_wall_timeout_sec,
        max_attempts=forward_max_attempts,
    )[0]
    alt_emb = evo2_forward(
        api_key=api_key,
        sequence=alt_window,
        output_layer="embedding_layer",
        request_timeout_sec=forward_timeout_sec,
        wall_timeout_sec=forward_wall_timeout_sec,
        max_attempts=forward_max_attempts,
    )[0]
    delta_emb_norm = np.linalg.norm(alt_emb - ref_emb, axis=-1)

    prefix = (
        f"evo2_variant-effect_{chrom_with_chr}_{position_1based}_{ref_base}_to_{alt_base}"
    )
    plot_path = output_dir / f"{prefix}_variant_effect.png"
    result_path = output_dir / f"{prefix}_result.json"

    genomic_x = np.arange(start_1based, end_1based + 1, dtype=int)
    fig, axes = plt.subplots(3, 1, figsize=(15, 10), sharex=True)
    axes[0].plot(genomic_x, ref_top1, label=f"REF ({ref_base})", color="#4c78a8", linewidth=0.9)
    axes[0].plot(
        genomic_x,
        alt_top1,
        label=f"ALT ({alt_base})",
        color="#e45756",
        linewidth=0.9,
        alpha=0.9,
    )
    axes[0].axvline(position_1based, color="black", linestyle="--", linewidth=1.0)
    axes[0].set_title(f"Evo2 Variant Effect Proxy on hg38 {chrom_with_chr}:{position_1based:,}")
    axes[0].set_ylabel("Top-1 logit")
    axes[0].legend(loc="upper right")
    axes[0].grid(alpha=0.25)

    axes[1].plot(genomic_x, delta_top1, color="#72b7b2", linewidth=0.9)
    axes[1].axvline(position_1based, color="black", linestyle="--", linewidth=1.0)
    axes[1].set_ylabel("ALT - REF (logit)")
    axes[1].set_title("Forward Delta Track")
    axes[1].grid(alpha=0.25)

    axes[2].plot(genomic_x, delta_emb_norm, color="#f58518", linewidth=0.9)
    axes[2].axvline(position_1based, color="black", linestyle="--", linewidth=1.0)
    axes[2].set_ylabel("||ALT - REF||")
    axes[2].set_xlabel(f"Genomic coordinate ({chrom_with_chr}, hg38)")
    axes[2].set_title("Embedding Delta Norm Track")
    axes[2].grid(alpha=0.25)
    plt.tight_layout()
    fig.savefig(plot_path, dpi=180)
    plt.close(fig)

    payload = {
        "skill_id": "evo2-inference",
        "task": "variant-effect",
        "run_time_utc": utc_now_iso(),
        "model": EVO2_MODEL,
        "assembly": "hg38",
        "chrom": normalize_chrom_for_workflow(chrom_with_chr),
        "chrom_with_chr": chrom_with_chr,
        "position_1based": position_1based,
        "reference_base": ref_base,
        "alternate_base": alt_base,
        "window_start_1based": start_1based,
        "window_end_1based": end_1based,
        "window_len": window_len,
        "delta_top1_at_variant": float(delta_top1[variant_index]),
        "delta_emb_norm_at_variant": float(delta_emb_norm[variant_index]),
        "coordinate_convention": {
            "position": "1-based",
            "window": "1-based inclusive",
        },
        "outputs": {
            "plot": str(plot_path.resolve()),
            "result_json": str(result_path.resolve()),
        },
    }
    result_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return payload


def main() -> int:
    args = parse_args()
    api_key = load_api_key()

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest_out = (
        Path(args.manifest_out).resolve()
        if args.manifest_out
        else (output_dir / "evo2_variant_batch_manifest.tsv")
    )
    summary_json = (
        Path(args.summary_json).resolve()
        if args.summary_json
        else (output_dir / "evo2_variant_batch_summary.json")
    )
    variants = parse_variant_manifest(Path(args.variant_manifest).resolve())

    fieldnames = [
        "row_index",
        "chrom",
        "position",
        "ref",
        "alt",
        "variant_spec",
        "status",
        "exit_code",
        "plot",
        "result_json",
        "error",
        "delta_top1_at_variant",
        "delta_emb_norm_at_variant",
        "run_time_utc",
    ]

    rows: list[dict] = []
    failed_count = 0
    with manifest_out.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()

        for variant in variants:
            row_index = str(variant["row_index"]).strip()
            chrom = with_chr_prefix(str(variant["chrom"]).strip())
            position = int(str(variant["position"]).strip())
            ref = str(variant["ref"]).strip().upper()
            alt = str(variant["alt"]).strip().upper()
            variant_spec = f"{chrom}:{position}:{ref}>{alt}"

            out_row = {
                "row_index": row_index,
                "chrom": chrom,
                "position": str(position),
                "ref": ref,
                "alt": alt,
                "variant_spec": variant_spec,
                "status": "failed",
                "exit_code": "1",
                "plot": "",
                "result_json": "",
                "error": "",
                "delta_top1_at_variant": "",
                "delta_emb_norm_at_variant": "",
                "run_time_utc": "",
            }

            try:
                print(f"[EVO2][RUN] {variant_spec}", flush=True)
                result = run_one_variant(
                    api_key=api_key,
                    output_dir=output_dir,
                    chrom_with_chr=chrom,
                    position_1based=position,
                    ref_base=ref,
                    alt_base=alt,
                    window_len=args.window_len,
                    forward_timeout_sec=args.forward_timeout_sec,
                    forward_wall_timeout_sec=args.forward_wall_timeout_sec,
                    forward_max_attempts=args.forward_max_attempts,
                )
                out_row["status"] = "success"
                out_row["exit_code"] = "0"
                out_row["plot"] = result["outputs"]["plot"]
                out_row["result_json"] = result["outputs"]["result_json"]
                out_row["delta_top1_at_variant"] = f"{result['delta_top1_at_variant']:.10g}"
                out_row["delta_emb_norm_at_variant"] = f"{result['delta_emb_norm_at_variant']:.10g}"
                out_row["run_time_utc"] = result["run_time_utc"]
                print(f"[EVO2][OK] {variant_spec}", flush=True)
            except Exception as exc:
                failed_count += 1
                out_row["error"] = f"{type(exc).__name__}: {exc}"
                out_row["run_time_utc"] = utc_now_iso()
                print(f"[EVO2][WARN] {variant_spec}: {exc}", flush=True)
                if args.continue_on_error == 0:
                    writer.writerow(out_row)
                    rows.append(out_row)
                    break

            writer.writerow(out_row)
            rows.append(out_row)

    succeeded_count = len([r for r in rows if r["status"] == "success"])
    failed_count = len([r for r in rows if r["status"] != "success"])
    payload = {
        "skill_id": "evo2-inference",
        "task": "variant-effect-batch",
        "model": EVO2_MODEL,
        "assembly": "hg38",
        "variant_manifest": str(Path(args.variant_manifest).resolve()),
        "output_dir": str(output_dir),
        "total_variants": len(rows),
        "succeeded_count": succeeded_count,
        "failed_count": failed_count,
        "status": "completed" if failed_count == 0 else "completed_with_failures",
        "generated_at_utc": utc_now_iso(),
        "results": rows,
    }
    summary_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"[EVO2][SUMMARY] succeeded={succeeded_count} failed={failed_count}", flush=True)
    print(f"[EVO2][SUMMARY] manifest={manifest_out}", flush=True)
    print(f"[EVO2][SUMMARY] summary_json={summary_json}", flush=True)

    if failed_count and args.continue_on_error == 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
