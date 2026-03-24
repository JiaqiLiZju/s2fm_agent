# s2f-skills

An English-language Codex skills repository for genomics and genome-model workflows.

This repo packages reusable skills that help Codex work with:

- AlphaGenome API workflows
- Evo 2 installation and inference
- The GPN model family (`GPN`, `GPN-MSA`, `PhyloGPN`, `GPN-Star`)
- The Nucleotide Transformer ecosystem, including classic NT, NTv3, and SegmentNT-family models

The goal is to give Codex grounded, task-specific guidance instead of relying on generic model knowledge alone.

## What This Repository Contains

The repository currently includes six packaged skills:

| Skill ID | Display name | Best for | Explicit invocation |
| --- | --- | --- | --- |
| `alphagenome-api` | AlphaGenome API | AlphaGenome setup, variant prediction, plotting, and troubleshooting | `$alphagenome-api` |
| `evo2-inference` | Evo 2 Inference | Evo 2 installation, checkpoint choice, forward pass, embeddings, generation, and deployment paths | `$evo2-inference` |
| `gpn-models` | GPN Models | Choosing between GPN-family frameworks and using grounded loading / CLI workflows | `$gpn-models` |
| `nucleotide-transformer` | Nucleotide Transformer | Classic NT v1/v2 JAX inference, tokenization, and embeddings workflows | `$nucleotide-transformer` |
| `nucleotide-transformer-v3` | Nucleotide Transformer v3 | NTv3 Transformers inference, species conditioning, setup troubleshooting, and length-aware runs | `$nucleotide-transformer-v3` |
| `segment-nt` | SegmentNT Family | SegmentNT, SegmentEnformer, and SegmentBorzoi segmentation inference workflows | `$segment-nt` |

There is also a `Readme/` folder with source material used to build or plan skills.

## Repository Layout

```text
s2f-skills/
├── README.md
├── Readme/
│   ├── AG_README.md
│   ├── CHM13_README.md
│   ├── Evo2_README.md
│   ├── GPN_README.md
│   ├── NT_README.md
│   ├── nucleotide_transformer.md
│   ├── nucleotide_transformer_v3.md
│   └── segment_nt.md
├── alphagenome-api/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── references/
├── evo2-inference/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── references/
├── gpn-models/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── references/
├── nucleotide-transformer/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   └── references/
├── nucleotide-transformer-v3/
│   ├── SKILL.md
│   ├── agents/openai.yaml
│   ├── scripts/
│   └── references/
└── segment-nt/
    ├── SKILL.md
    ├── agents/openai.yaml
    ├── scripts/
    └── references/
```

## How To Use These Skills

### 1. Install the skills where Codex can discover them

If you want Codex to auto-discover these skills, place each skill folder under:

```bash
${CODEX_HOME:-$HOME/.codex}/skills
```

For example:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R alphagenome-api evo2-inference gpn-models nucleotide-transformer nucleotide-transformer-v3 segment-nt "${CODEX_HOME:-$HOME/.codex}/skills/"
```

If you prefer to keep the canonical copies in this repo, you can also symlink them into your Codex skills directory.

### 2. Let Codex trigger them automatically

Each skill has a `SKILL.md` file with frontmatter that describes when the skill should be used. When a user request matches that description closely enough, Codex can load the skill automatically.

Examples:

- Asking for AlphaGenome variant prediction help may trigger `alphagenome-api`
- Asking how to run Evo 2 locally on GPUs may trigger `evo2-inference`
- Asking which GPN family model fits aligned vs unaligned genomes may trigger `gpn-models`
- Asking how to use classic NT v1/v2 in JAX may trigger `nucleotide-transformer`
- Asking how to run NTv3 with the right species or input length may trigger `nucleotide-transformer-v3`
- Asking how to run SegmentNT or related segmentation models may trigger `segment-nt`

### 3. Invoke a skill explicitly when you want deterministic behavior

Explicit invocation is often the most reliable option. Use the skill ID with a leading `$` inside your prompt.

Examples:

```text
Use $alphagenome-api to write a minimal AlphaGenome variant prediction example for chr22.
```

```text
Use $evo2-inference to recommend the right Evo 2 checkpoint for my hardware and generate a smoke test.
```

```text
Use $gpn-models to help me choose between GPN-Star and PhyloGPN for a new variant scoring workflow.
```

```text
Use $nucleotide-transformer-v3 to tell me whether my 32768 bp input is valid and write a species-conditioned NTv3 example.
```

## How Skills And Agents Work In This Repo

Each packaged skill has three important parts:

### `SKILL.md`

This is the operational guide for Codex. It defines:

- what the skill does
- when it should trigger
- the core workflow Codex should follow
- the grounded API surface or command patterns Codex should trust

### `references/`

This folder contains deeper guidance that should only be loaded when needed, such as:

- setup matrices
- minimal code patterns
- caveats and troubleshooting notes
- family-selection guides

This keeps `SKILL.md` short while still giving Codex access to task-specific detail.

### `scripts/`

Some skills include small helper scripts when the same calculation or validation would otherwise be re-explained repeatedly.

Current examples:

- `nucleotide-transformer-v3/scripts/check_valid_length.py`
- `segment-nt/scripts/compute_rescaling_factor.py`

## Fresh-Machine Deployment

This repository is designed so you can prepare a new machine without modifying the current one.

### 1. Link the skills into Codex

```bash
./scripts/link_skills.sh
```

Or use the Makefile:

```bash
make link-skills
```

Useful variants:

```bash
./scripts/link_skills.sh --list
./scripts/link_skills.sh --skills-dir /opt/codex/skills --force
./scripts/link_skills.sh nucleotide-transformer nucleotide-transformer-v3 segment-nt
```

### 2. Provision the software stack you need

Use the deployment helper on the target machine:

```bash
./scripts/provision_stack.sh alphagenome
./scripts/provision_stack.sh gpn
./scripts/provision_stack.sh nt-jax
./scripts/provision_stack.sh ntv3-hf
```

For a one-step fresh-machine install of the default stacks:

```bash
./scripts/bootstrap.sh
```

Or, with Make:

```bash
make bootstrap
```

`nt-jax` is the recommended JAX environment for:

- `nucleotide-transformer`
- `segment-nt`

`ntv3-hf` is the recommended NTv3 tutorial environment for:

- `nucleotide-transformer-v3`

#### Evo 2 light install

Evo 2 requires hardware-specific PyTorch setup before `flash-attn`, so the script expects `TORCH_INSTALL_CMD`:

```bash
export TORCH_INSTALL_CMD='$VENV_PYTHON -m pip install torch==2.7.1 --index-url https://download.pytorch.org/whl/cu128'
./scripts/provision_stack.sh evo2-light
```

One-step variant:

```bash
export TORCH_INSTALL_CMD='$VENV_PYTHON -m pip install torch==2.7.1 --index-url https://download.pytorch.org/whl/cu128'
./scripts/bootstrap.sh --with-evo2-light
# or
make bootstrap-evo2-light
```

#### Evo 2 full install

For the full Evo 2 path, activate a conda environment first, then run:

```bash
conda create -n evo2-full python=3.11 -y
conda activate evo2-full
./scripts/provision_stack.sh evo2-full
```

One-step variant:

```bash
conda create -n evo2-full python=3.11 -y
conda activate evo2-full
./scripts/bootstrap.sh --with-evo2-full
# or
make bootstrap-evo2-full
```

#### Hardware-specific JAX

By default, `nt-jax` installs a generic `jax>=0.3.25` before the source install. If your target machine needs a custom accelerator-specific JAX install, set `JAX_INSTALL_CMD`:

```bash
export JAX_INSTALL_CMD='$VENV_PYTHON -m pip install jax[cuda12]'
./scripts/provision_stack.sh nt-jax
```

This also works with the one-step installers:

```bash
export JAX_INSTALL_CMD='$VENV_PYTHON -m pip install jax[cuda12]'
./scripts/bootstrap.sh
# or
make bootstrap
```

Note: the upstream source install used by `nt-jax` currently requires Python 3.10+ in practice because of newer JAX constraints.

#### NTv3 Transformers stack

For the NTv3 tutorial path (Hugging Face Transformers + PyTorch):

```bash
./scripts/provision_stack.sh ntv3-hf
```

One-step variant:

```bash
./scripts/bootstrap.sh --with-ntv3-hf
# or
make bootstrap-ntv3-hf
```

### 3. Run a smoke test on the new machine

Basic repository and helper-script checks:

```bash
./scripts/smoke_test.sh --skills-dir "${CODEX_HOME:-$HOME/.codex}/skills"
```

Optional import checks against deployed environments:

```bash
./scripts/smoke_test.sh \
  --skills-dir "${CODEX_HOME:-$HOME/.codex}/skills" \
  --alphagenome-python /path/to/alphagenome/bin/python \
  --gpn-python /path/to/gpn/bin/python \
  --nt-python /path/to/nt-jax/bin/python \
  --ntv3-python /path/to/ntv3-hf/bin/python \
  --evo2-python /path/to/evo2-light/bin/python
```

### `agents/openai.yaml`

This file provides UI-facing metadata for Codex. In this repository, "agent" mainly refers to how a skill is surfaced and described in the product UI.

Typical fields include:

- `display_name`: human-facing skill name
- `short_description`: short one-line summary
- `default_prompt`: a ready-made prompt snippet that references the skill explicitly

Important: `agents/openai.yaml` does not replace `SKILL.md`. It improves discovery and invocation, while `SKILL.md` contains the actual working instructions.

## Skill Guide

### `alphagenome-api`

Use this skill for AlphaGenome Python API workflows, especially:

- API key setup
- package installation
- interval and variant prediction setup
- output selection and ontology-term usage
- plotting reference vs alternate predictions

This skill is intentionally conservative: it prefers grounded AlphaGenome patterns from the local source material and warns against inventing unsupported API calls.

### `evo2-inference`

Use this skill for Evo 2 inference and environment decisions, especially:

- choosing between local inference, Nvidia hosted API, and NIM
- matching checkpoints to hardware
- running forward-pass, embeddings, and generation workflows
- handling FP8 / Transformer Engine / Hopper GPU constraints

This skill is designed to keep hardware assumptions explicit before Codex emits install commands or model code.

### `gpn-models`

Use this skill when the user says "GPN" but the actual model family is still ambiguous.

It helps Codex:

- choose between `GPN`, `GPN-MSA`, `PhyloGPN`, and `GPN-Star`
- explain when alignments are required
- load grounded Hugging Face checkpoints
- use the documented single-sequence `GPN` CLI workflows for training, embeddings, and variant effect prediction

It also warns that `GPN-MSA` is deprecated in favor of `GPN-Star` for new alignment-based workflows.

### `nucleotide-transformer`

Use this skill for the classic Nucleotide Transformer v1 and v2 models, especially:

- choosing between v1 and v2 checkpoints
- grounded JAX + Haiku inference
- 6-mer tokenization behavior
- embeddings extraction with `embeddings_layers_to_save`
- context-limit troubleshooting when `N` bases appear

### `nucleotide-transformer-v3`

Use this skill for NTv3-specific workflows, especially:

- using the tutorial-default Hugging Face Transformers inference path
- choosing pre-trained vs post-trained NTv3 checkpoints
- handling base-resolution long-context inference
- species-conditioned post-trained runs
- understanding the difference between full-length logits and cropped bigwig / bed outputs
- validating legal sequence lengths and using reduced precision when memory is tight
- troubleshooting NTv3 setup and import failures

### `segment-nt`

Use this skill for segmentation-model workflows, especially:

- selecting between SegmentNT, SegmentEnformer, and SegmentBorzoi
- running JAX inference for nucleotide-resolution annotation
- handling SegmentNT-specific constraints such as no `N` in the input
- computing or explaining `rescaling_factor` for longer SegmentNT inputs
- converting logits into per-feature probabilities

## Recommended Prompting Pattern

If you want the best results, keep prompts concrete:

- say which model or framework you want to use
- mention your hardware or environment when relevant
- include the organism, genome build, or input schema when working with genomic data
- ask for a runnable example if you want code

Better prompts:

- `Use $alphagenome-api to write a notebook cell that compares REF vs ALT RNA-seq output for a single variant.`
- `Use $evo2-inference to tell me whether I can run evo2_20b on my machine and give me the correct install path.`
- `Use $gpn-models to tell me whether aligned genomes are required for this workflow and suggest the right family.`
- `Use $nucleotide-transformer to write a minimal JAX example with 250M_multi_species_v2 and explain 6-mer tokenization.`
- `Use $nucleotide-transformer-v3 to write a post-trained NTv3 Transformers example for human and explain the output tensors.`
- `Use $segment-nt to help me run SegmentNT on a 40 kb sequence and calculate the needed rescaling factor.`

## Current Scope

This repository currently ships the six skills listed above.

`Readme/CHM13_README.md` exists as source material, but a packaged CHM13 skill has not been added yet.

## For Maintainers

When extending this repo:

- keep `SKILL.md` concise
- move detailed material into `references/`
- add `scripts/` only when a repeated calculation or validation is worth encoding
- keep `agents/openai.yaml` aligned with the skill's purpose
- validate new skills before publishing them
- avoid claiming support for workflows that are not grounded in the source material

The source notes in `Readme/` are useful starting points for building additional skills.

## Star 记录

[![Star History Chart](https://api.star-history.com/svg?repos=JiaqiLiZju/s2fm_agent&type=Date)](https://star-history.com/#JiaqiLiZju/s2fm_agent&Date)
