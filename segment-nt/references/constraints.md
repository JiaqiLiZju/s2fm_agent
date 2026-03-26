# Constraints

Use this file when the request depends on length handling or tokenizer assumptions.

## SegmentNT-specific constraints

- SegmentNT models were trained on sequences of `30,000` nucleotides.
- The docs state that SegmentNT generalizes up to `50,000` bp.
- SegmentNT does not handle `N` in the input sequence.
- The number of DNA tokens, excluding the prepended CLS token, must be divisible by `4`.

Tokenization implications:

- SegmentNT uses 6-mer tokenization plus one prepended CLS token.
- Use consistent names with `$nucleotide-transformer`:
  - `num_tokens_inference` includes CLS.
  - `num_dna_tokens_excluding_cls` excludes CLS.
- Approximate token count from bp (only valid with no `N`): `num_tokens_inference = ceil(bp / 6) + 1`.
- Divisibility check applies to `num_dna_tokens_excluding_cls`.

## Rescaling

For inference between `30 kb` and `50 kb`, the docs instruct the user to pass a `rescaling_factor` to `get_pretrained_segment_nt_model(...)`.

Grounded formula from docs and notebooks:

- `rescaling_factor = num_tokens_inference / 2048`
- Here `num_tokens_inference` includes CLS.
- For `40008` bp with no `N`, the docs example gives `num_tokens_inference=6669`, so `rescaling_factor=6669/2048`.

Use [scripts/compute_rescaling_factor.py](../scripts/compute_rescaling_factor.py) when the user gives a concrete sequence length. The helper assumes 6-mer tokenization with no `N` when converting base pairs to token count.

## SegmentEnformer and SegmentBorzoi examples

Grounded example sequence lengths in the docs:

- SegmentEnformer: `196_608`
- SegmentBorzoi: `524_288`

Operational note:

- SegmentEnformer and SegmentBorzoi notebook paths use 1-mer tokenization and `hk.transform_with_state(...)`.
