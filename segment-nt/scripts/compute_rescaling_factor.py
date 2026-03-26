#!/usr/bin/env python3
"""Compute a SegmentNT rescaling factor from tokens or approximate base-pair length."""

import argparse
import math


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Compute the SegmentNT rescaling factor. If sequence length in base pairs is "
            "used, this assumes 6-mer tokenization with no N characters and includes the "
            "prepended CLS token."
        )
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--num-tokens-inference",
        type=int,
        help=(
            "Token count at inference time. By default this is interpreted as including "
            "the prepended CLS token."
        ),
    )
    group.add_argument(
        "--sequence-length-bp",
        type=int,
        help="Sequence length in base pairs. Assumes 6-mer tokenization with no N.",
    )
    parser.add_argument(
        "--tokens-exclude-cls",
        action="store_true",
        help=(
            "Interpret --num-tokens-inference as excluding CLS. The script will add one "
            "CLS token internally before computing the rescaling factor."
        ),
    )
    parser.add_argument(
        "--trained-max-tokens",
        type=int,
        default=2048,
        help="Max token count used for the NT backbone during training. Default: 2048.",
    )
    args = parser.parse_args()

    if args.trained_max_tokens <= 0:
        raise SystemExit("trained-max-tokens must be positive")

    if args.num_tokens_inference is not None:
        if args.num_tokens_inference <= 0:
            raise SystemExit("num-tokens-inference must be positive")
        if args.tokens_exclude_cls:
            num_tokens = args.num_tokens_inference + 1
            assumption = "provided_token_count_excluding_cls"
        else:
            num_tokens = args.num_tokens_inference
            assumption = "provided_token_count_including_cls"
    else:
        if args.sequence_length_bp <= 0:
            raise SystemExit("sequence-length-bp must be positive")
        if args.tokens_exclude_cls:
            raise SystemExit("--tokens-exclude-cls is only valid with --num-tokens-inference")
        num_tokens = math.ceil(args.sequence_length_bp / 6) + 1
        assumption = "estimated_from_bp_using_6mer_plus_cls"

    if num_tokens <= 1:
        raise SystemExit("effective token count must be >1 to include CLS and DNA tokens")

    num_dna_tokens_excluding_cls = num_tokens - 1
    factor = num_tokens / args.trained_max_tokens
    nearest_lower_div4 = num_dna_tokens_excluding_cls - (num_dna_tokens_excluding_cls % 4)
    nearest_upper_div4 = nearest_lower_div4 + (0 if num_dna_tokens_excluding_cls % 4 == 0 else 4)

    print(f"num_tokens_inference={num_tokens}")
    print(f"num_dna_tokens_excluding_cls={num_dna_tokens_excluding_cls}")
    # Backward-compatible field name kept for callers already parsing this output.
    print(f"dna_tokens_excluding_cls={num_dna_tokens_excluding_cls}")
    print(f"dna_tokens_excluding_cls_divisible_by_4={num_dna_tokens_excluding_cls % 4 == 0}")
    print(f"nearest_lower_dna_tokens_div_by_4={nearest_lower_div4}")
    print(f"nearest_upper_dna_tokens_div_by_4={nearest_upper_div4}")
    print(f"segment_nt_training_sequence_tokens=5001")
    print(f"extends_segment_nt_training_length={num_tokens > 5001}")
    print(f"trained_max_tokens={args.trained_max_tokens}")
    print(f"rescaling_factor={factor:.10f}")
    print(f"assumption={assumption}")
    if args.sequence_length_bp is not None:
        print("warning=bp_to_token_conversion_assumes_no_N_and_regular_6mer_tokenization")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
