---
name: nucleotide-transformer
description: Use InstaDeep Nucleotide Transformer JAX workflows for NT v1/v2 (primary) and compatible `get_pretrained_model` checkpoints such as `1B_agro_nt` and `codon_nt` (secondary), including 6-mer tokenization limits, embeddings/attention extraction, and model-name troubleshooting. Use when Codex needs to write, fix, explain, or review code or notebooks involving `get_pretrained_model`, `tokenizer.batch_tokenize`, `hk.transform`, `forward_fn.apply`, `embeddings_layers_to_save`, or `attention_maps_to_save`.
---

# Nucleotide Transformer

## Overview

Use this skill for `nucleotide_transformer.pretrained.get_pretrained_model` workflows. Prefer the grounded JAX + Haiku path from the bundled docs and notebooks.

Primary scope:
- NT v1 and NT v2 models.

Secondary compatible scope:
- `1B_agro_nt`
- `codon_nt`

When the request is really about NTv3 pre/post-trained species-conditioned outputs, route to `$nucleotide-transformer-v3`.

## Follow This Decision Flow

1. Choose the NT generation.
- Use NT v1 when the user explicitly wants `500M_human_ref`, `500M_1000G`, `2B5_1000G`, or `2B5_multi_species`.
- Use NT v2 when the user wants the more efficient rotary / SwiGLU models with longer 12 kbp context.
- If the user explicitly asks for plant-focused `1B_agro_nt` or 3-mer `codon_nt`, keep the same JAX API but state that these are adjacent variants, not NTv1/NTv2 benchmarks.

2. Check sequence length and tokenization assumptions.
- NT uses 6-mer tokenization with special handling for `N`.
- If the sequence contains `N`, or the length is not divisible by 6, tokenization falls back to single nucleotides around those regions.
- Use consistent token-count terminology across NT and SegmentNT:
  - `num_tokens_inference`: total tokens including prepended CLS.
  - `num_dna_tokens_excluding_cls`: token count excluding CLS.
- Use the limits in [references/tokenization-and-limits.md](references/tokenization-and-limits.md) before promising that a sequence will fit.

3. Use the grounded JAX inference path.
- Import `get_pretrained_model` from `nucleotide_transformer.pretrained`.
- Tokenize with `tokenizer.batch_tokenize(...)`.
- Transform the forward function with `hk.transform(...)`.
- Call `forward_fn.apply(parameters, random_key, tokens)`.

4. Handle embeddings carefully.
- `embeddings_layers_to_save` is 1-indexed.
- If the user asks for final embeddings from a Roberta LM head model, note the special behavior described in the docs.

5. Handle attention maps when requested.
- Use `attention_maps_to_save=((layer, head), ...)`.
- Read attention tensors from keys like `attention_map_layer_1_number_4`.
- Mention that layer/head indices must exist in the loaded model config.

6. Present the smallest working example.
- Return runnable JAX code first.
- Mention GPU/TPU support only as a capability note, not as a hidden dependency.

## Grounded API Surface

Treat the following names and patterns as grounded by the bundled docs:

- `from nucleotide_transformer.pretrained import get_pretrained_model`
- `get_pretrained_model(...)`
- `tokenizer.batch_tokenize(...)`
- `hk.transform(forward_fn)`
- `forward_fn.apply(parameters, random_key, tokens)`
- `embeddings_layers_to_save=(...)`
- `attention_maps_to_save=((layer, head), ...)`
- `max_positions=...`
- `outs["attention_map_layer_<layer>_number_<head>"]`

Supported model names grounded by the docs:

- `500M_human_ref`
- `500M_1000G`
- `2B5_1000G`
- `2B5_multi_species`
- `50M_multi_species_v2`
- `100M_multi_species_v2`
- `250M_multi_species_v2`
- `500M_multi_species_v2`
- `1B_agro_nt`
- `codon_nt`

Do not invent PyTorch Transformers wrappers for this skill path. Keep code on the JAX API unless the user supplies a different grounded source.

## Response Style

- Prefer concrete JAX examples over broad architectural summaries.
- Surface tokenization behavior whenever the user mentions `N`, odd sequence lengths, or exact context limits.
- State clearly whether a recommendation targets v1 or v2.
- If using `1B_agro_nt` or `codon_nt`, state explicitly that it is an adjacent variant loaded by the same API.

## References

- Read [references/model-variants.md](references/model-variants.md) for NT v1/v2 model selection.
- Read [references/usage-patterns.md](references/usage-patterns.md) for the grounded JAX inference pattern.
- Read [references/tokenization-and-limits.md](references/tokenization-and-limits.md) for 6-mer behavior and sequence limits.
