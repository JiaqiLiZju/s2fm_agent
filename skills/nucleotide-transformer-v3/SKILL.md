---
name: nucleotide-transformer-v3
description: Use Nucleotide Transformer v3 for long-context multispecies inference with Hugging Face Transformers as the primary path, with JAX helper APIs as secondary compatibility, including pre-trained MLM outputs, post-trained species-conditioned track/annotation prediction, length-divisibility checks, and gated-repo troubleshooting. Use when Codex needs to write, fix, explain, or review code or notebooks involving `AutoTokenizer.from_pretrained(..., trust_remote_code=True)`, `AutoModelForMaskedLM`, `AutoModel`, `encode_species`, `num_downsamples`, `keep_target_center_fraction`, NTv3 model names, bigwig/bed outputs, or NTv3 install/auth issues.
---

# Nucleotide Transformer v3

## Overview

Use this skill for NTv3 only.

- Primary path: Hugging Face Transformers + PyTorch with `trust_remote_code=True`.
- Secondary path: legacy JAX helper APIs for projects that already depend on `nucleotide_transformer_v3.pretrained`.

## Follow This Decision Flow

1. Choose the backend first.
- Default to the HF backend: Transformers + PyTorch.
- Use the JAX helper backend only for existing code that already uses `nucleotide_transformer_v3.pretrained`.

2. Confirm gated-repo access early.
- NTv3 model repos are gated.
- Authenticate with `huggingface-cli login` or pass `token=...` in `from_pretrained(...)`.

3. Choose the NTv3 stage.
- Use pre-trained models for embeddings and masked-language-model style outputs.
- Use post-trained models for species-conditioned functional-track and genome-annotation prediction.

4. Choose a model size or checkpoint family.
- Use the main production checkpoints first.
- Only surface ablation or intermediate checkpoints when the user explicitly needs them.

5. Validate sequence length before writing code.
- Sequence length must be divisible by `2^num_downsamples`.
- Main production models typically use `num_downsamples=7` (divisor `128`).
- 5-downsample ablations use divisor `32`.
- Prefer deriving divisor from config (`2 ** model.config.num_downsamples`) instead of hardcoding.
- For HF tokenization, use `pad_to_multiple_of=<divisor>`, or crop/pad with `N`.
- Use [scripts/check_valid_length.py](scripts/check_valid_length.py) when the user gives a concrete sequence length.

6. Handle conditioning and outputs correctly.
- For HF post-trained models, get species ids with `model.encode_species(...)`.
- Explain that functional-track and annotation outputs keep the model's center fraction (`model.config.keep_target_center_fraction`), while MLM logits stay full-length.
- For main post-trained checkpoints this center fraction is commonly 37.5%, but do not hardcode it.

7. Address install, version, and network issues explicitly.
- For installation failures, start with [references/setup-and-troubleshooting.md](references/setup-and-troubleshooting.md).
- Prefer pinned dependencies: `transformers>=4.55,<5`, `huggingface_hub>=0.23,<1`, and `numpy<2` with `torch 2.2.x`.
- If download transport is unstable, set `HF_HUB_DISABLE_XET=1`.
- If JAX-source install errors on `jax>=0.6.0` with Python 3.9, switch to Python >=3.10 or use the HF tutorial path.

8. Use the reusable track-prediction script for full workflows.
- For region-level track prediction + plotting, prefer [scripts/run_track_prediction.py](scripts/run_track_prediction.py) instead of rewriting notebook cells.

## Real Track Prediction Fastpath

Use this path when the user asks for one real NTv3 track prediction run and wants directly executable commands.

- Default model: `InstaDeepAI/NTv3_100M_post`.
- Default output directory: `output/ntv3_results`.
- CPU execution is acceptable when CUDA is unavailable.

Preflight order (do not skip):

1. `HF_TOKEN` availability from environment (for example via root `.env`).
2. Gated model access check (`InstaDeepAI/NTv3_100M_post`).
3. Runtime check with `conda run -n ntv3`.
4. Network checks for UCSC sequence API and Hugging Face model fetch.

Standard command template:

```bash
set -a; source .env; set +a
mkdir -p output/ntv3_results
conda run -n ntv3 python skills/nucleotide-transformer-v3/scripts/run_track_prediction.py \
  --model InstaDeepAI/NTv3_100M_post \
  --species human \
  --assembly hg38 \
  --chrom chr19 \
  --start 6700000 \
  --end 6732768 \
  --output-dir output/ntv3_results \
  2>&1 | tee output/ntv3_results/ntv3_run.log
```

Download-transport fallback (retry once):

```bash
set -a; source .env; set +a
conda run -n ntv3 python skills/nucleotide-transformer-v3/scripts/run_track_prediction.py \
  --model InstaDeepAI/NTv3_100M_post \
  --species human \
  --assembly hg38 \
  --chrom chr19 \
  --start 6700000 \
  --end 6732768 \
  --output-dir output/ntv3_results \
  --disable-xet \
  2>&1 | tee output/ntv3_results/ntv3_run.log
```

Acceptance checklist:

- Log contains `loading config/tokenizer/model from HF`.
- Log contains `saved plot:` and `saved meta:`.
- `*_trackplot.png` exists.
- `*_meta.json` exists with expected `species/assembly/chrom/start/end`.

## Grounded API Surface

Treat the following HF tutorial names and patterns as grounded:

- `from transformers import AutoConfig, AutoModel, AutoModelForMaskedLM, AutoTokenizer`
- `AutoTokenizer.from_pretrained(..., trust_remote_code=True, token=...)`
- `AutoModelForMaskedLM.from_pretrained(..., trust_remote_code=True, token=...)`
- `AutoModel.from_pretrained(..., trust_remote_code=True, token=...)`
- `tokenizer(..., add_special_tokens=False, padding=True, pad_to_multiple_of=<divisor>, return_tensors="pt")`
- `model.encode_species(...)`
- `model(input_ids=..., species_ids=...)`
- `model.config.num_downsamples`
- `model.config.keep_target_center_fraction`
- `outs["logits"]`
- `outs["bigwig_tracks_logits"]`
- `outs["bed_tracks_logits"]`

Legacy JAX helper names remain grounded for compatibility:

- `from nucleotide_transformer_v3.pretrained import get_pretrained_ntv3_model`
- `from nucleotide_transformer_v3.pretrained import get_posttrained_ntv3_model`
- `get_pretrained_ntv3_model(...)`
- `get_posttrained_ntv3_model(...)`
- `tokenizer.batch_np_tokenize(...)`
- `model(tokens)`
- `posttrained_model.encode_species(...)`
- `posttrained_model(tokens=tokens, species_tokens=species_tokens)`

Grounded main model names and HF repo ids:

- `NTv3_8M_pre`
- `NTv3_100M_pre`
- `NTv3_650M_pre`
- `NTv3_100M_post`
- `NTv3_650M_post`
- `InstaDeepAI/NTv3_8M_pre`
- `InstaDeepAI/NTv3_100M_pre`
- `InstaDeepAI/NTv3_650M_pre`
- `InstaDeepAI/NTv3_100M_post`
- `InstaDeepAI/NTv3_650M_post`

Grounded optional intermediate/ablation names:

- `NTv3_8M_pre_8kb`
- `NTv3_100M_pre_8kb`
- `NTv3_100M_post_131kb`
- `NTv3_650M_pre_8kb`
- `NTv3_650M_post_131kb`
- `NTv3_5downsample_pre_8kb`
- `NTv3_5downsample_pre`
- `NTv3_5downsample_post_131kb`
- `NTv3_5downsample_post`

Do not invent alternate wrappers or training code from this skill alone.

## Response Style

- Prefer concise Transformers examples first, with exact model names.
- Use JAX examples only when the user asks for the legacy API path.
- Surface divisibility and center-fraction rules before discussing large-context runs.
- State clearly whether a sequence should be cropped or padded with `N`.

## References

- Read [references/setup-and-troubleshooting.md](references/setup-and-troubleshooting.md) first for install, version, and import failures.
- Read [references/model-catalog.md](references/model-catalog.md) for checkpoint selection.
- Read [references/pre-vs-post.md](references/pre-vs-post.md) for code patterns and output differences.
- Read [references/length-and-memory.md](references/length-and-memory.md) for divisibility, padding, and precision guidance.
- Use [scripts/check_valid_length.py](scripts/check_valid_length.py) to validate concrete input lengths.
- Use [scripts/run_track_prediction.py](scripts/run_track_prediction.py) for region-level prediction and plotting.
