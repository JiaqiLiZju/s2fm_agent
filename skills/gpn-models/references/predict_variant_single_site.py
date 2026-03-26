#!/usr/bin/env python3
"""Single-site variant scoring with a GPN-style masked language model.

This script fetches a sequence window from UCSC, masks the center position,
and computes:
  LLR = logit(alt) - logit(ref)
for forward and reverse-complement strands, then reports their mean.
"""

from __future__ import annotations

import argparse
import json
import os
from typing import Dict

import numpy as np
import requests
import torch
from gpn.data import Tokenizer
from transformers import AutoModelForMaskedLM

import gpn.model  # noqa: F401, needed for HF class registration


COMPLEMENT: Dict[str, str] = {
    "A": "T",
    "C": "G",
    "G": "C",
    "T": "A",
    "N": "N",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run single-site variant effect scoring with GPN-style MLM"
    )
    parser.add_argument("--genome", default="hg38", help="UCSC genome id, e.g. hg38")
    parser.add_argument("--chrom", required=True, help="Chromosome name, e.g. chr12")
    parser.add_argument(
        "--pos",
        required=True,
        type=int,
        help="1-based genomic position",
    )
    parser.add_argument(
        "--window-size",
        type=int,
        default=512,
        help="Sequence window size centered on the variant",
    )
    parser.add_argument(
        "--model-id",
        default="songlab/gpn-msa-sapiens",
        help="Hugging Face model id",
    )
    parser.add_argument(
        "--alt",
        default=None,
        help="Explicit ALT base (A/C/G/T). If omitted, uses --alt-rule",
    )
    parser.add_argument(
        "--alt-rule",
        choices=["to_G_unless_ref_G_then_T"],
        default="to_G_unless_ref_G_then_T",
        help="Rule used when --alt is omitted",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="HTTP timeout (seconds) for UCSC sequence API",
    )
    parser.add_argument(
        "--output-json",
        default=None,
        help="Optional JSON output path",
    )
    return parser.parse_args()


def fetch_ucsc_seq(
    genome: str,
    chrom: str,
    start_0based: int,
    end_0based_exclusive: int,
    timeout: int,
) -> str:
    url = (
        "https://api.genome.ucsc.edu/getData/sequence"
        f"?genome={genome};chrom={chrom};start={start_0based};end={end_0based_exclusive}"
    )
    response = requests.get(url, timeout=timeout)
    response.raise_for_status()
    data = response.json()
    dna = data.get("dna")
    if not dna:
        raise RuntimeError(f"UCSC returned no DNA sequence: {data}")
    return dna.upper()


def reverse_complement(seq: str) -> str:
    return "".join(COMPLEMENT.get(base, "N") for base in reversed(seq))


def choose_alt(ref: str, alt: str | None, rule: str) -> str:
    if alt is not None:
        alt = alt.upper()
        if alt not in {"A", "C", "G", "T"}:
            raise ValueError(f"ALT must be A/C/G/T, got: {alt}")
        if alt == ref:
            raise ValueError(f"ALT must differ from REF, both are {ref}")
        return alt
    if rule == "to_G_unless_ref_G_then_T":
        return "T" if ref == "G" else "G"
    raise ValueError(f"Unsupported alt rule: {rule}")


def encode_sequence(seq: str, tokenizer: Tokenizer) -> torch.Tensor:
    arr = np.frombuffer(seq.encode("ascii"), dtype="S1")
    token_ids = tokenizer(arr).astype(np.int64)
    return torch.tensor(token_ids, dtype=torch.long)


def main() -> None:
    args = parse_args()

    # Helpful default for environments where HF xet download can fail.
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

    if args.window_size < 3:
        raise ValueError("--window-size must be >= 3")

    pos0 = args.pos - 1
    start = pos0 - args.window_size // 2
    end = pos0 + args.window_size // 2
    if args.window_size % 2 == 1:
        end += 1

    seq_fwd = fetch_ucsc_seq(args.genome, args.chrom, start, end, args.timeout)
    if len(seq_fwd) != args.window_size:
        raise RuntimeError(
            f"Unexpected sequence length {len(seq_fwd)} (expected {args.window_size})"
        )

    pos_fwd = args.window_size // 2
    ref = seq_fwd[pos_fwd]
    if ref not in {"A", "C", "G", "T"}:
        raise RuntimeError(
            f"REF base at {args.chrom}:{args.pos} is not A/C/G/T (got {ref})"
        )
    alt = choose_alt(ref, args.alt, args.alt_rule)

    seq_rev = reverse_complement(seq_fwd)
    ref_rev = COMPLEMENT[ref]
    alt_rev = COMPLEMENT[alt]
    pos_rev = pos_fwd - 1 if args.window_size % 2 == 0 else pos_fwd

    if seq_fwd[pos_fwd] != ref:
        raise RuntimeError("Forward center base does not match REF")
    if seq_rev[pos_rev] != ref_rev:
        raise RuntimeError("Reverse center base does not match REF reverse-complement")

    mask_token = "?"
    seq_fwd_masked = seq_fwd[:pos_fwd] + mask_token + seq_fwd[pos_fwd + 1 :]
    seq_rev_masked = seq_rev[:pos_rev] + mask_token + seq_rev[pos_rev + 1 :]

    tokenizer = Tokenizer()  # vocab: -ACGT?
    vocab_id = {c: i for i, c in enumerate(tokenizer.vocab)}
    ids_fwd = encode_sequence(seq_fwd_masked, tokenizer).unsqueeze(0)
    ids_rev = encode_sequence(seq_rev_masked, tokenizer).unsqueeze(0)

    model = AutoModelForMaskedLM.from_pretrained(args.model_id, trust_remote_code=True)
    model.eval()
    with torch.no_grad():
        logits_fwd = model(input_ids=ids_fwd).logits[0, pos_fwd]
        logits_rev = model(input_ids=ids_rev).logits[0, pos_rev]

    llr_fwd = float((logits_fwd[vocab_id[alt]] - logits_fwd[vocab_id[ref]]).item())
    llr_rev = float(
        (logits_rev[vocab_id[alt_rev]] - logits_rev[vocab_id[ref_rev]]).item()
    )
    llr_mean = (llr_fwd + llr_rev) / 2.0

    result = {
        "model": args.model_id,
        "genome": args.genome,
        "chrom": args.chrom,
        "pos_1based": args.pos,
        "window_size": args.window_size,
        "window_start_0based": start,
        "window_end_0based_exclusive": end,
        "ref": ref,
        "alt_rule": args.alt_rule if args.alt is None else "explicit_alt",
        "alt": alt,
        "llr_fwd": llr_fwd,
        "llr_rev": llr_rev,
        "llr_mean": llr_mean,
        "interpretation": (
            "LLR > 0 means ALT is more likely than REF at the masked site; "
            "LLR < 0 means REF is more likely."
        ),
    }

    if args.output_json:
        output_dir = os.path.dirname(args.output_json)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        with open(args.output_json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
