# s2f-skills

`s2f-skills` is an academically oriented, execution-ready repository for computational genomics workflows with Codex.

It combines grounded skill packages, deterministic routing, task-level input contracts, reproducible environment setup scripts, and validation/evaluation tooling so research questions can be translated into runnable analysis with lower setup variance.

## Start Here

For a first successful run on a machine that already has this repo cloned:

```bash
./scripts/link_skills.sh
./scripts/route_query.sh --query "Use \$dnabert2 to validate my train/dev/test CSV files"
./scripts/run_agent.sh --query "Need variant-effect guidance for chr12 REF/ALT"
./scripts/smoke_test.sh --skills-dir "${CODEX_HOME:-$HOME/.codex}/skills"
```

For a fresh-machine bootstrap (recommended):

```bash
./scripts/bootstrap.sh
# or
make bootstrap
```

## Table of Contents

- [Functional Capabilities](#functional-capabilities)
- [Application Scenarios](#application-scenarios)
- [Skill Catalog](#skill-catalog)
- [Repository Structure](#repository-structure)
- [Routing and Agent Runtime](#routing-and-agent-runtime)
- [Installation and Deployment](#installation-and-deployment)
- [Validation and Troubleshooting](#validation-and-troubleshooting)
- [Maintainers](#maintainers)
- [Star History](#star-history)

## Functional Capabilities

| Capability | What it enables | Entry points |
| --- | --- | --- |
| Skill-grounded execution | Domain-specific guidance for genomics model families and workflows | `skills/*/SKILL.md`, `skills-dev/*/SKILL.md` |
| Deterministic routing | Ranked skill selection with `route` / `clarify` decision and confidence | `scripts/route_query.sh`, `registry/routing.yaml` |
| Task-contract checks | Detects missing required inputs before execution guidance | `scripts/run_agent.sh`, `registry/task_contracts.yaml` |
| Cross-skill playbook mapping | Maps user intent to reusable task playbooks | `playbooks/*/README.md` |
| Reproducible environment setup | Standardized stack provisioning and one-step bootstrap | `scripts/provision_stack.sh`, `scripts/bootstrap.sh`, `Makefile` |
| Validation and regression checks | Registry, metadata, migration, and routing consistency checks | `scripts/validate_*.sh`, `make validate-agent` |

## Application Scenarios

| Scenario | Typical objective | Primary skills | Playbook |
| --- | --- | --- | --- |
| Variant-effect analysis | Compare REF vs ALT impact or prioritize variants | `alphagenome-api`, `borzoi-workflows`, `gpn-models`, `evo2-inference` | [`variant-effect`](./playbooks/variant-effect/README.md) |
| Embedding and representation | Produce sequence embeddings for downstream analyses | `dnabert2`, `nucleotide-transformer-v3`, `nucleotide-transformer`, `evo2-inference` | [`embedding`](./playbooks/embedding/README.md) |
| Track prediction workflows | Run sequence-to-signal prediction with model-appropriate constraints | `nucleotide-transformer-v3`, `borzoi-workflows`, `segment-nt` | [`track-prediction`](./playbooks/track-prediction/README.md) |
| Fine-tuning and training setup | Prepare schemas, training configs, and model-specific run paths | `dnabert2`, `bpnet`, `basset-workflows` | [`fine-tuning`](./playbooks/fine-tuning/README.md) |
| Environment bring-up and migration | Build reproducible stacks and verify operational readiness | `skill-factory` plus stack-specific skills | [`environment-setup`](./playbooks/environment-setup/README.md) |

## Skill Catalog

The repository currently includes **11** packaged skills.

Status definition:

- `Stable`: canonical package in `skills/<skill-id>/`
- `Dev`: in-progress package in `skills-dev/<skill-id>/`

| Skill ID | Status | Path | Best for | Explicit invocation | Docs |
| --- | --- | --- | --- | --- | --- |
| `alphagenome-api` | Stable | `skills/alphagenome-api` | AlphaGenome setup, variant prediction, plotting, troubleshooting | `$alphagenome-api` | [`SKILL.md`](./skills/alphagenome-api/SKILL.md) · [`references/`](./skills/alphagenome-api/references/) |
| `basset-workflows` | Dev | `skills-dev/basset-workflows` | Legacy Basset Torch7 preprocessing, prediction, interpretation, SAD | `$basset-workflows` | [`SKILL.md`](./skills-dev/basset-workflows/SKILL.md) · [`references/`](./skills-dev/basset-workflows/references/) |
| `bpnet` | Dev | `skills-dev/bpnet` | BPNet preprocessing, train/predict/SHAP, motif integration | `$bpnet` | [`SKILL.md`](./skills-dev/bpnet/SKILL.md) · [`references/`](./skills-dev/bpnet/references/) |
| `borzoi-workflows` | Stable | `skills/borzoi-workflows` | Borzoi setup, tutorials, variant scoring, interpretation | `$borzoi-workflows` | [`SKILL.md`](./skills/borzoi-workflows/SKILL.md) · [`references/`](./skills/borzoi-workflows/references/) |
| `dnabert2` | Stable | `skills/dnabert2` | Embeddings, GUE evaluation, CSV validation, fine-tuning | `$dnabert2` | [`SKILL.md`](./skills/dnabert2/SKILL.md) · [`references/`](./skills/dnabert2/references/) |
| `evo2-inference` | Stable | `skills/evo2-inference` | Evo 2 setup, checkpoint choice, inference, deployment | `$evo2-inference` | [`SKILL.md`](./skills/evo2-inference/SKILL.md) · [`references/`](./skills/evo2-inference/references/) |
| `gpn-models` | Stable | `skills/gpn-models` | GPN-family framework selection and usage | `$gpn-models` | [`SKILL.md`](./skills/gpn-models/SKILL.md) · [`references/`](./skills/gpn-models/references/) |
| `nucleotide-transformer` | Dev | `skills-dev/nucleotide-transformer` | Classic NT v1/v2 JAX inference, tokenization, embeddings | `$nucleotide-transformer` | [`SKILL.md`](./skills-dev/nucleotide-transformer/SKILL.md) · [`references/`](./skills-dev/nucleotide-transformer/references/) |
| `nucleotide-transformer-v3` | Stable | `skills/nucleotide-transformer-v3` | NTv3 inference, species conditioning, length-aware runs | `$nucleotide-transformer-v3` | [`SKILL.md`](./skills/nucleotide-transformer-v3/SKILL.md) · [`references/`](./skills/nucleotide-transformer-v3/references/) |
| `segment-nt` | Stable | `skills/segment-nt` | SegmentNT-family segmentation inference and scaling logic | `$segment-nt` | [`SKILL.md`](./skills/segment-nt/SKILL.md) · [`references/`](./skills/segment-nt/references/) |
| `skill-factory` | Dev | `skills-dev/skill-factory` | Scaffold and validate consistent skill packages from specs | `$skill-factory` | [`SKILL.md`](./skills-dev/skill-factory/SKILL.md) · [`references/`](./skills-dev/skill-factory/references/) |

Reference notes used during skill development are in [`Readme/`](./Readme/).

## Repository Structure

```text
s2f-skills/
├── agent/                  # orchestrator identity, routing and safety policy
├── registry/               # skills index, tags, routing config, task contracts
├── skills/                 # canonical stable skill packages
├── skills-dev/             # in-progress skill packages
├── playbooks/              # task-level cross-skill guidance
├── evals/                  # routing evaluation cases
├── docs/                   # architecture and design notes
├── scripts/                # setup, routing, orchestration, validation tooling
├── Readme/                 # source notes and upstream references
└── README.md
```

Architecture details: [`docs/architecture.md`](./docs/architecture.md).

## Routing and Agent Runtime

Use the router when you only need skill selection and confidence:

```bash
./scripts/route_query.sh --query "Use \$dnabert2 to validate my train/dev/test CSV."
./scripts/route_query.sh --query "I need NTv3 track prediction for hg38." --format json
./scripts/route_query.sh --query "Train a model on fasta labels." --task fine-tuning
```

Use the full agent runtime when you also need required-input checks and playbook mapping:

```bash
./scripts/run_agent.sh --query "Need variant-effect guidance around chr12 with REF/ALT."
./scripts/run_agent.sh --query "Help me run Evo2 generation without NVIDIA GPU" --format json
```

Open the local interactive console:

```bash
./scripts/agent_console.sh
```

Decision lifecycle per query:

1. infer or accept task hint
2. score and rank candidate skills
3. emit `decision=route` or `decision=clarify` with confidence
4. if routed, resolve required inputs from task contracts first, then skill contracts

## Installation and Deployment

### Prerequisites

- Bash and Git
- Python 3.10+ recommended (required by multiple stacks in practice)
- Conda only if using `evo2-full`
- NVIDIA GPU + CUDA stack for local Evo 2 GPU paths (`evo2-light` / `evo2-full`)

### 1. Install skills for Codex discovery

Default skills directory:

```bash
${CODEX_HOME:-$HOME/.codex}/skills
```

Install all registry-listed skills:

```bash
./scripts/link_skills.sh
# or
make link-skills
```

Useful variants:

```bash
./scripts/link_skills.sh --list
./scripts/link_skills.sh --registry ./registry/skills.yaml --list
./scripts/link_skills.sh --skills-dir /opt/codex/skills --force
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

### 3. Optional Evo 2 paths

Evo 2 light (requires hardware-specific torch install command before `flash-attn`):

```bash
export TORCH_INSTALL_CMD='$VENV_PYTHON -m pip install torch==2.7.1 --index-url https://download.pytorch.org/whl/cu128'
./scripts/provision_stack.sh evo2-light
```

Evo 2 full (active conda environment):

```bash
conda create -n evo2-full python=3.11 -y
conda activate evo2-full
./scripts/provision_stack.sh evo2-full
```

Hosted Evo 2 API path (recommended on macOS or without NVIDIA GPU):

```bash
export NVCF_RUN_KEY='your_run_key'
python skills/evo2-inference/scripts/run_hosted_api.py --num-tokens 8 --top-k 1
```

Full hosted workflow with output plots:

```bash
export NVCF_RUN_KEY='your_run_key'
python skills/evo2-inference/scripts/run_real_evo2_workflow.py --output-dir skills/evo2-inference/results
```

### 4. Optional hardware-specific JAX override

```bash
export JAX_INSTALL_CMD='$VENV_PYTHON -m pip install jax[cuda12]'
./scripts/provision_stack.sh nt-jax
```

## Validation and Troubleshooting

Baseline smoke checks:

```bash
./scripts/smoke_test.sh --skills-dir "${CODEX_HOME:-$HOME/.codex}/skills"
```

Registry and metadata checks:

```bash
./scripts/validate_registry.sh
./scripts/validate_skill_metadata.sh
./scripts/validate_migration_paths.sh
```

Routing checks and full validation bundle:

```bash
./scripts/validate_routing.sh
make validate-agent
```

Optional Make shortcuts:

```bash
make validate-registry
make validate-skill-metadata
make validate-migration-paths
make eval-routing
make route-query QUERY='Need variant-effect guidance' TASK='variant-effect'
make run-agent QUERY='Help me run AlphaGenome predict_variant with RNA output'
```

Extended smoke test with explicit environment imports:

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

When a workflow fails, start from the skill's `references/` folder and then check routing/task configuration under `registry/`.

## Maintainers

When extending this repository:

- keep `SKILL.md` concise and operational
- move detailed guidance to `references/`
- add scripts only for repeated logic worth encoding
- keep `skill.yaml` and `agents/openai.yaml` aligned with scope
- update `registry/skills.yaml` when adding, moving, or disabling a skill
- run validation (`make validate-agent`) before publishing

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=JiaqiLiZju/s2fm_agent&type=Date)](https://star-history.com/#JiaqiLiZju/s2fm_agent&Date)
