# Tokenization And Limits

Use this file when the request depends on exact context size or tokenization behavior.

## 6-mer tokenization

Classic NT tokenizes DNA from left to right in 6-mers.

Examples grounded by the docs:

```python
dna_sequence_1 = "ACGTGTACGTGCACGGACGACTAGTCAGCA"
tokenized_dna_sequence_1 = [<CLS>,<ACGTGT>,<ACGTGC>,<ACGGAC>,<GACTAG>,<TCAGCA>]

dna_sequence_2 = "ACGTGTACNTGCACGGANCGACTAGTCTGA"
tokenized_dna_sequence_2 = [<CLS>,<ACGTGT>,<A>,<C>,<N>,<TGCACG>,<G>,<A>,<N>,<CGACTA>,<GTCTGA>]
```

## Important behavior

- The tokenizer does not group `N` into 6-mers.
- If the sequence length is not a multiple of 6, trailing nucleotides may be tokenized individually.
- This means effective token count depends on sequence content, not just raw length.
- The prepended `<CLS>` token also consumes one token position.

## Shared terminology (NT + SegmentNT)

Use these terms consistently when reasoning about length:

- `num_tokens_inference`: total token count including prepended CLS.
- `num_dna_tokens_excluding_cls`: token count excluding CLS.
- Approximation with no `N`: `num_tokens_inference = ceil(bp / 6) + 1`.

## Sequence limits

Grounded maximum nucleotide counts with no `N`:

- NT v1: up to 5,994 nucleotides
- NT v2: up to 12,282 nucleotides

These limits assume no `N` characters appear in the input.

Token-level context from docs:

- NT v1 training context: up to 1,000 tokens (including `<CLS>`)
- NT v2 training context: up to 2,000 tokens (including `<CLS>`)

## Practical guidance

- If the user is near the limit, mention that `N` bases may reduce usable context.
- Avoid promising an exact token count when the sequence contains `N` unless you can inspect the real tokenizer output.
- If the user asks to speed up inference or reduce memory, recommend setting `max_positions` close to the true tokenized batch length instead of leaving it unnecessarily large.
- For off-by-one confusion, explicitly state whether a reported token count includes CLS.
