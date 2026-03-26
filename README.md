# s2f-skills

An academically oriented Codex skills repository for computational genomics and genome foundation model workflows.

This repository curates grounded methodological guidance, reproducible command templates, and model-specific caveats for end-to-end research tasks, including:

- controlled environment setup and dependency provisioning across model families
- inference, variant-effect estimation, and interpretation workflows
- preprocessing, training, and attribution pipelines for supported frameworks
- validation utilities and smoke tests for reproducible workflow deployment

The goal of `s2f-skills` is to improve methodological consistency, reduce setup variance, and accelerate translation from research question to executable analysis.

## Quick Start

### Path A: Link skills only

```bash
./scripts/link_skills.sh
```

### Path B: Fresh machine bootstrap (recommended)

```bash
./scripts/bootstrap.sh
```

Equivalent Make target:

```bash
make bootstrap
```

### Verify installation

```bash
./scripts/smoke_test.sh --skills-dir "${CODEX_HOME:-$HOME/.codex}/skills"
```

### Use a skill explicitly

```text
Use $nucleotide-transformer-v3 to write a species-conditioned NTv3 inference example.
```

## Table of Contents

- [What This Repository Includes](#what-this-repository-includes)
- [Repository Layout](#repository-layout)
- [Deployment Guide](#deployment-guide)
- [Verification and Troubleshooting](#verification-and-troubleshooting)
- [How Skills and Agents Work](#how-skills-and-agents-work)
- [Orchestration Layer](#orchestration-layer)
- [Agent Runtime CLI](#agent-runtime-cli)
- [Recommended Prompting Pattern](#recommended-prompting-pattern)
- [Maintainers](#maintainers)
- [Star History](#star-history)

## What This Repository Includes

The repository currently includes ten packaged skills:

| Skill ID | Best for | Explicit invocation | Docs |
| --- | --- | --- | --- |
| `alphagenome-api` | AlphaGenome setup, variant prediction, plotting, and troubleshooting | `$alphagenome-api` | [`SKILL.md`](./skills/alphagenome-api/SKILL.md) · [`references/`](./skills/alphagenome-api/references/) |
| `basset-workflows` | Legacy Basset Torch7 preprocessing, prediction, interpretation, and SAD workflows | `$basset-workflows` | [`SKILL.md`](./basset-workflows/SKILL.md) · [`references/`](./basset-workflows/references/) |
| `bpnet` | BPNet setup, preprocessing, train/predict/SHAP workflows, and motif/hit-calling integration | `$bpnet` | [`SKILL.md`](./bpnet/SKILL.md) · [`references/`](./bpnet/references/) |
| `borzoi-workflows` | Borzoi setup, tutorials, model download, variant scoring, and interpretation workflows | `$borzoi-workflows` | [`SKILL.md`](./skills/borzoi-workflows/SKILL.md) · [`references/`](./skills/borzoi-workflows/references/) |
| `dnabert2` | DNABERT2 embeddings, GUE evaluation, CSV validation, and fine-tuning workflows | `$dnabert2` | [`SKILL.md`](./skills/dnabert2/SKILL.md) · [`references/`](./skills/dnabert2/references/) |
| `evo2-inference` | Evo 2 installation, checkpoint choice, inference, and deployment paths | `$evo2-inference` | [`SKILL.md`](./skills/evo2-inference/SKILL.md) · [`references/`](./skills/evo2-inference/references/) |
| `gpn-models` | Choosing between GPN-family frameworks and grounded loading/CLI workflows | `$gpn-models` | [`SKILL.md`](./skills/gpn-models/SKILL.md) · [`references/`](./skills/gpn-models/references/) |
| `nucleotide-transformer` | Classic NT v1/v2 JAX inference, tokenization, and embeddings workflows | `$nucleotide-transformer` | [`SKILL.md`](./nucleotide-transformer/SKILL.md) · [`references/`](./nucleotide-transformer/references/) |
| `nucleotide-transformer-v3` | NTv3 Transformers inference, species conditioning, setup troubleshooting, and length-aware runs | `$nucleotide-transformer-v3` | [`SKILL.md`](./skills/nucleotide-transformer-v3/SKILL.md) · [`references/`](./skills/nucleotide-transformer-v3/references/) |
| `segment-nt` | SegmentNT, SegmentEnformer, and SegmentBorzoi segmentation inference workflows | `$segment-nt` | [`SKILL.md`](./skills/segment-nt/SKILL.md) · [`references/`](./skills/segment-nt/references/) |

Source notes used to build or plan skills are in [`Readme/`](./Readme/).

## Repository Layout

```text
s2f-skills/
├── agent/
├── registry/
├── skills/
├── playbooks/
├── evals/
├── docs/
├── README.md
├── Readme/
├── scripts/
├── basset-workflows/
├── bpnet/
├── nucleotide-transformer/
└── skills/
```

Namespace migration note:

- The following tested skills are now canonical under `skills/<skill-id>/`:
  - `alphagenome-api`
  - `borzoi-workflows`
  - `nucleotide-transformer-v3`
  - `gpn-models`
  - `evo2-inference`
  - `dnabert2`
  - `segment-nt`
- Root-level paths for these migrated skills are now removed; use `skills/<skill-id>/` paths.

## Deployment Guide

### Prerequisites

- Bash shell and Git
- Python 3.10+ recommended (required by several stacks in practice)
- Conda only if you plan to use `evo2-full`
- NVIDIA GPU + CUDA toolchain for local Evo 2 GPU installs (`evo2-light` / `evo2-full`)

### 1. Install skills where Codex can discover them

Default skills directory:

```bash
${CODEX_HOME:-$HOME/.codex}/skills
```

Install all skills:

```bash
./scripts/link_skills.sh
# or
make link-skills
```

Useful variants:

```bash
./scripts/link_skills.sh --list
./scripts/link_skills.sh --skills-dir /opt/codex/skills --force
./scripts/link_skills.sh --registry ./registry/skills.yaml --list
./scripts/link_skills.sh basset-workflows bpnet dnabert2 nucleotide-transformer nucleotide-transformer-v3 segment-nt borzoi-workflows
```

### 2. Provision software stacks

Provision individual stacks:

```bash
./scripts/provision_stack.sh alphagenome
./scripts/provision_stack.sh gpn
./scripts/provision_stack.sh nt-jax
./scripts/provision_stack.sh ntv3-hf
./scripts/provision_stack.sh borzoi
```

One-step default install (skills + `alphagenome` + `gpn` + `nt-jax` + smoke test):

```bash
./scripts/bootstrap.sh
# or
make bootstrap
```

Optional one-step variants:

```bash
./scripts/bootstrap.sh --with-ntv3-hf
./scripts/bootstrap.sh --with-borzoi
./scripts/bootstrap.sh --with-evo2-light
./scripts/bootstrap.sh --with-evo2-full
```

Equivalent Make targets:

```bash
make bootstrap-ntv3-hf
make bootstrap-borzoi
make bootstrap-evo2-light
make bootstrap-evo2-full
```

### 3. Optional: Evo 2 setup paths

#### Evo 2 light install

`evo2-light` requires hardware-specific PyTorch setup before `flash-attn`:

```bash
export TORCH_INSTALL_CMD='$VENV_PYTHON -m pip install torch==2.7.1 --index-url https://download.pytorch.org/whl/cu128'
./scripts/provision_stack.sh evo2-light
```

#### Evo 2 full install

Use an active Conda environment:

```bash
conda create -n evo2-full python=3.11 -y
conda activate evo2-full
./scripts/provision_stack.sh evo2-full
```

#### Evo 2 hosted API (recommended on macOS / no NVIDIA GPU)

```bash
export NVCF_RUN_KEY='your_run_key'
python skills/evo2-inference/scripts/run_hosted_api.py --num-tokens 8 --top-k 1
```

Full hosted workflow with plots:

```bash
export NVCF_RUN_KEY='your_run_key'
python skills/evo2-inference/scripts/run_real_evo2_workflow.py --output-dir skills/evo2-inference/results
```

Operational notes reflected in this repo:

- For forward/embedding tracks, prefer `evo2-7b/forward`
- For generation, try `evo2-7b/generate`, then fallback to `evo2-40b/generate` when degraded
- Variant effect is represented here as REF-vs-ALT delta proxy, not AlphaGenome-style `predict_variant(...)`

### 4. Optional: Hardware-specific JAX override

If `nt-jax` needs accelerator-specific JAX wheels:

```bash
export JAX_INSTALL_CMD='$VENV_PYTHON -m pip install jax[cuda12]'
./scripts/provision_stack.sh nt-jax
```

## Verification and Troubleshooting

Run baseline smoke checks:

```bash
./scripts/smoke_test.sh --skills-dir "${CODEX_HOME:-$HOME/.codex}/skills"
```

Validate registry entries:

```bash
./scripts/validate_registry.sh
# or
make validate-registry
```

Validate skill metadata consistency:

```bash
./scripts/validate_skill_metadata.sh
# or
make validate-skill-metadata
```

Run full agent validation bundle:

```bash
make validate-agent
```

Evaluate routing cases:

```bash
./scripts/validate_routing.sh
# or
make eval-routing
```

Note:

- `validate_routing.sh` invokes `route_query.sh` for each eval case, so runtime routing and offline eval use one routing logic source.
- routing eval now includes both `route` and `clarify` decisions.

Run one query through the router:

```bash
./scripts/route_query.sh --query "Use \$dnabert2 to validate my train/dev/test CSV."
./scripts/route_query.sh --query "I need NTv3 track prediction for human hg38." --format json
./scripts/route_query.sh --query "Train a model on fasta labels."
# or
make route-query QUERY='Help me run AlphaGenome predict_variant with RNA output'
make route-query QUERY='Need variant-effect guidance' TASK='variant-effect'
```

Run with environment import checks:

```bash
./scripts/smoke_test.sh \
  --skills-dir "${CODEX_HOME:-$HOME/.codex}/skills" \
  --alphagenome-python /path/to/alphagenome/bin/python \
  --gpn-python /path/to/gpn/bin/python \
  --nt-python /path/to/nt-jax/bin/python \
  --ntv3-python /path/to/ntv3-hf/bin/python \
  --borzoi-python /path/to/borzoi/bin/python \
  --evo2-python /path/to/evo2-light/bin/python
```

If a workflow fails, start from the skill's `references/` folder for setup caveats and troubleshooting notes.

## How Skills and Agents Work

Each packaged skill includes:

### `SKILL.md`

Operational instructions for Codex:

- what the skill does
- when it should trigger
- workflow and trusted command/API patterns

### `references/`

On-demand deep guidance:

- setup matrix and compatibility notes
- runnable patterns
- caveats and troubleshooting

### `scripts/`

Optional helper scripts for repeated validation or calculations.

Current examples:

- `skills/dnabert2/scripts/validate_dataset_csv.py`
- `skills/dnabert2/scripts/recommend_max_length.py`
- `skills/nucleotide-transformer-v3/scripts/check_valid_length.py`
- `skills/segment-nt/scripts/compute_rescaling_factor.py`
- `skills/segment-nt/scripts/run_segment_nt_region.py`
- `skills/evo2-inference/scripts/run_hosted_api.py`
- `skills/evo2-inference/scripts/run_real_evo2_workflow.py`

### `agents/openai.yaml`

UI-facing metadata for discovery and invocation:

- `display_name`
- `short_description`
- `default_prompt`

`agents/openai.yaml` improves discoverability, while `SKILL.md` remains the source of operational behavior.

## Orchestration Layer

`s2f` now ships with a deterministic agent layer that routes queries across skills and decides whether to answer directly (`route`) or ask one focused follow-up (`clarify`).

Core components:

- `agent/`: orchestrator identity, routing policy, and safety boundaries
- `registry/`: machine-readable skill index, tag taxonomy, routing config, and task input contracts
- `playbooks/`: cross-skill task patterns (`variant-effect`, `embedding`, `fine-tuning`, `track-prediction`, `environment-setup`)
- `evals/routing/`: routing evaluation cases for both `route` and `clarify` decisions
- `scripts/route_query.sh`: runtime router (`decision` + `confidence` + ranked candidates + reasons)
- `scripts/run_agent.sh`: full orchestration output (router decision + input contract checks + playbook mapping)

Routing lifecycle per query:

1. infer task from explicit `--task`, alias rules, and query text
2. rank candidate skills via explicit mention, trigger hits, and task alignment
3. estimate confidence and emit `decision=route` or `decision=clarify`
4. when routed, resolve required inputs from task contracts first, then skill contracts

Compatibility note:

- migrated skills use `skills/<skill-id>/` as the canonical path
- operational scripts enumerate skills from `registry/skills.yaml` rather than hardcoded lists

## Agent Runtime CLI

Use `route_query.sh` when you only need routing decisions:

```bash
./scripts/route_query.sh --query "Use \$dnabert2 to validate my train/dev/test CSV."
./scripts/route_query.sh --query "I need NTv3 track prediction for hg38." --format json
./scripts/route_query.sh --query "Train a model on fasta labels."
```

Typical outputs:

- high/medium confidence query -> `decision: route` with primary/secondary skills
- low confidence query -> `decision: clarify` with one focused clarification question

Use `run_agent.sh` when you need execution-facing orchestration details:

```bash
./scripts/run_agent.sh --query "Need variant-effect guidance around chr12 with REF/ALT."
./scripts/run_agent.sh --query "Help me run Evo2 generation without NVIDIA GPU" --format json
```

`run_agent.sh` additionally returns:

- `required_inputs_source` (`task-contract:<task>` or `skill:<id>`)
- `required_inputs`, `provided_inputs`, `missing_inputs`
- selected `playbook` (when available), `constraints`, and `next_prompt`

Useful options:

- force task selection with `--task` when intent is known
- use `--format json` for downstream tooling or UI integration

Interactive local console:

```bash
./scripts/agent_console.sh
```

## Recommended Prompting Pattern

For best results, make prompts concrete:

- name the model/framework
- include hardware or environment constraints
- include organism/genome build/input schema when relevant
- ask for runnable examples when needed

Examples:

- `Use $alphagenome-api to write a notebook cell that compares REF vs ALT RNA-seq output for a single variant.`
- `Use $bpnet to draft input_data.json and a runnable bpnet-train/bpnet-shap workflow for my ChIP-seq peaks.`
- `Use $evo2-inference to tell me whether I can run evo2_20b on my machine and give me the correct install path.`
- `Use $gpn-models to tell me whether aligned genomes are required for this workflow and suggest the right family.`
- `Use $dnabert2 to check my DNABERT2 CSV schema and recommend model_max_length from sequence lengths.`
- `Use $nucleotide-transformer to write a minimal JAX example with 250M_multi_species_v2 and explain 6-mer tokenization.`
- `Use $nucleotide-transformer-v3 to write a post-trained NTv3 Transformers example for human and explain the output tensors.`
- `Use $segment-nt to help me run SegmentNT on a 40 kb sequence and calculate the needed rescaling factor.`
- `Use $borzoi-workflows to set up Borzoi and run latest tutorial variant scoring scripts on a small VCF.`
- `Use $basset-workflows to validate my Torch7/Basset environment and run a conservative basset_predict.lua workflow.`

## Maintainers

When extending this repository:

- keep `SKILL.md` concise
- move detailed material to `references/`
- add `scripts/` only when repeated logic is worth encoding
- keep `agents/openai.yaml` aligned with the skill purpose
- validate new skills before publishing
- avoid claiming support for workflows not grounded in source material

This repository currently ships the ten skills listed above.

`Readme/CHM13_README.md` exists as source material, but a packaged CHM13 skill has not been added yet.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=JiaqiLiZju/s2fm_agent&type=Date)](https://star-history.com/#JiaqiLiZju/s2fm_agent&Date)
