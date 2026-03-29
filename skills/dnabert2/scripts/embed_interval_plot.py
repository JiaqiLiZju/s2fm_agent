#!/usr/bin/env python3
"""Run DNABERT2 embedding on a genomic interval and save a PCA plot."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import requests
import torch
import transformers
from sklearn.decomposition import PCA
from transformers import AutoModel, AutoTokenizer
from transformers.models.bert.configuration_bert import BertConfig


def normalize_int_token(raw: str) -> int:
    cleaned = re.sub(r"[_,\s]", "", raw)
    if not cleaned.isdigit():
        raise ValueError(f"Invalid integer token: {raw}")
    return int(cleaned)


def parse_interval_spec(spec: str) -> tuple[str, int, int]:
    text = spec.strip()
    match = re.fullmatch(r"(chr[\w]+):([0-9_,]+)-([0-9_,]+)", text, flags=re.IGNORECASE)
    if not match:
        raise ValueError(
            f"Invalid --interval format: {spec}. Expected like chr19:6700000-6732768"
        )
    chrom = match.group(1)
    start = normalize_int_token(match.group(2))
    end = normalize_int_token(match.group(3))
    return chrom, start, end


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Fetch a real genomic sequence from UCSC by assembly/chrom/start/end, "
            "run DNABERT2 embedding inference, and save a PCA visualization."
        )
    )
    parser.add_argument("--species", default="human", help="Species label for metadata.")
    parser.add_argument(
        "--assembly",
        default="hg38",
        help="Genome assembly for UCSC API query (example: hg38).",
    )
    parser.add_argument(
        "--interval",
        default=None,
        help="Canonical alias for interval, e.g. chr19:6700000-6732768 (0-based [start, end)).",
    )
    parser.add_argument("--chrom", default=None, help="Chromosome name (example: chr19).")
    parser.add_argument("--start", default=None, type=int, help="0-based inclusive start.")
    parser.add_argument("--end", default=None, type=int, help="0-based exclusive end.")
    parser.add_argument(
        "--model-id",
        default="zhihan1996/DNABERT-2-117M",
        help="Hugging Face model id. Default: zhihan1996/DNABERT-2-117M",
    )
    parser.add_argument(
        "--output-dir",
        default="output/dnabert2",
        help="Output directory for plot + metadata. Default: output/dnabert2.",
    )
    parser.add_argument(
        "--plot-name",
        default=None,
        help="Output PCA image filename. Default: derived from prefix.",
    )
    parser.add_argument(
        "--metadata-name",
        default=None,
        help="Output metadata filename. Default: derived from prefix.",
    )
    parser.add_argument(
        "--save-token-embeddings",
        action="store_true",
        help="Also save token embedding matrix to token_embeddings.npy.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="HTTP timeout in seconds for UCSC sequence fetch. Default: 60.",
    )
    return parser.parse_args()


def fetch_sequence(assembly: str, chrom: str, start: int, end: int, timeout: int) -> tuple[str, str]:
    if start < 0:
        raise ValueError("start must be >= 0")
    if end <= start:
        raise ValueError("end must be greater than start")

    url = "https://api.genome.ucsc.edu/getData/sequence"
    params = {
        "genome": assembly,
        "chrom": chrom,
        "start": start,
        "end": end,
    }
    response = requests.get(url, params=params, timeout=timeout)
    response.raise_for_status()
    payload: dict[str, Any] = response.json()
    seq = str(payload.get("dna", "")).upper()
    if not seq:
        raise RuntimeError(f"No sequence returned from UCSC API: {payload}")
    return seq, response.url


def parse_major_minor(version_str: str) -> tuple[int, int]:
    parts = version_str.split(".")
    if len(parts) < 2:
        return (0, 0)
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return (0, 0)


def load_model(model_id: str) -> tuple[AutoTokenizer, AutoModel]:
    tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
    major_minor = parse_major_minor(transformers.__version__)
    if major_minor > (4, 28):
        config = BertConfig.from_pretrained(model_id)
        model = AutoModel.from_pretrained(model_id, trust_remote_code=True, config=config)
    else:
        model = AutoModel.from_pretrained(model_id, trust_remote_code=True)
    model.eval()
    return tokenizer, model


def extract_token_embeddings(tokenizer: AutoTokenizer, model: AutoModel, seq: str) -> tuple[np.ndarray, np.ndarray]:
    with torch.no_grad():
        encoded = tokenizer(seq, return_tensors="pt", truncation=False)
        outputs = model(**encoded)

    hidden = outputs[0]
    hidden_np = hidden[0].detach().cpu().numpy()
    input_ids = encoded["input_ids"][0].detach().cpu().numpy()

    special_ids = set(tokenizer.all_special_ids or [])
    if special_ids:
        keep_mask = np.array([token_id not in special_ids for token_id in input_ids], dtype=bool)
        token_emb = hidden_np[keep_mask]
    else:
        token_emb = hidden_np

    if token_emb.size == 0:
        token_emb = hidden_np
    return hidden_np, token_emb


def make_plot(coords: np.ndarray, explained_var: np.ndarray, title: str, output_path: Path) -> None:
    idx = np.arange(coords.shape[0])
    fig, axes = plt.subplots(1, 2, figsize=(14, 5), dpi=160)

    scatter = axes[0].scatter(coords[:, 0], coords[:, 1], c=idx, s=10, cmap="viridis", alpha=0.85)
    axes[0].set_title(title)
    axes[0].set_xlabel(f"PC1 ({explained_var[0] * 100:.1f}% var)")
    axes[0].set_ylabel(f"PC2 ({explained_var[1] * 100:.1f}% var)")
    colorbar = fig.colorbar(scatter, ax=axes[0])
    colorbar.set_label("Token index")

    axes[1].plot(idx, coords[:, 0], label="PC1", linewidth=1.2)
    axes[1].plot(idx, coords[:, 1], label="PC2", linewidth=1.2)
    axes[1].set_title("PC trajectory along token order")
    axes[1].set_xlabel("Token index")
    axes[1].set_ylabel("PC value")
    axes[1].legend()
    axes[1].grid(alpha=0.3)

    fig.tight_layout()
    fig.savefig(output_path)
    plt.close(fig)


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    chrom = args.chrom
    start = args.start
    end = args.end
    normalization_steps: list[str] = []

    if args.interval:
        chrom, start, end = parse_interval_spec(args.interval)
        normalization_steps.append("interval-overrides-chrom-start-end")

    if chrom is None or start is None or end is None:
        raise SystemExit(
            "Missing coordinates. Provide --interval or all of --chrom --start --end."
        )

    prefix = f"dnabert2_embedding_{chrom}_{start}_{end}"

    sequence, source_url = fetch_sequence(
        assembly=args.assembly,
        chrom=chrom,
        start=start,
        end=end,
        timeout=args.timeout,
    )

    expected_len = end - start
    if len(sequence) != expected_len:
        raise RuntimeError(
            f"Fetched sequence length mismatch: expected {expected_len}, got {len(sequence)}"
        )

    tokenizer, model = load_model(args.model_id)
    hidden_all, token_emb = extract_token_embeddings(tokenizer, model, sequence)

    if token_emb.shape[0] < 2:
        raise RuntimeError("Need at least 2 tokens for PCA plot.")

    pca = PCA(n_components=2, random_state=0)
    coords = pca.fit_transform(token_emb)
    explained = pca.explained_variance_ratio_

    plot_name = args.plot_name or f"{prefix}_plot.png"
    plot_path = output_dir / plot_name
    plot_title = (
        "DNABERT2 token embeddings PCA\n"
        f"{chrom}:{start}-{end} ({args.assembly}, {args.species})"
    )
    make_plot(coords, explained, plot_title, plot_path)

    if args.save_token_embeddings:
        np.save(output_dir / f"{prefix}_token_embeddings.npy", token_emb)

    metadata_name = args.metadata_name or f"{prefix}_result.json"
    metadata_path = output_dir / metadata_name

    metadata = {
        "skill_id": "dnabert2",
        "task": "embedding",
        "species": args.species,
        "assembly": args.assembly,
        "chrom": chrom,
        "start": start,
        "end": end,
        "coordinate_convention": "[start, end) zero-based",
        "input_normalization": {
            "interval_raw": args.interval,
            "chrom_raw": args.chrom,
            "start_raw": args.start,
            "end_raw": args.end,
            "normalization_steps": normalization_steps,
        },
        "resolved_inputs": {
            "assembly": args.assembly,
            "chrom": chrom,
            "start": start,
            "end": end,
        },
        "sequence_source": "UCSC API",
        "sequence_source_url": source_url,
        "sequence_length_bp": len(sequence),
        "model_id": args.model_id,
        "transformers_version": transformers.__version__,
        "token_count_with_special_tokens": int(hidden_all.shape[0]),
        "token_count_used_for_pca": int(token_emb.shape[0]),
        "embedding_dim": int(token_emb.shape[1]),
        "pca_explained_variance_ratio": [float(explained[0]), float(explained[1])],
        "plot_path": str(plot_path),
        "outputs": {
            "plot": str(plot_path),
            "npz": None,
            "result_json": str(metadata_path),
        },
    }

    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
