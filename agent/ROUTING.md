# s2f Agent Routing Rules

## Objective

Route each request to the best-fit skill while keeping behavior predictable and explainable.

## Step 1: Classify Primary Task

Classify the user request into one primary task:

- `environment-setup`
- `embedding`
- `variant-effect`
- `fine-tuning`
- `track-prediction`
- `troubleshooting`

Notes:

- `setup` is treated as an alias of `environment-setup`.
- `general-troubleshooting` is treated as an alias of `troubleshooting`.

If multiple tasks appear, keep one primary task and mark others as secondary.

## Step 2: Build Skill Candidate Set

Candidate priority rules:

1. explicit skill mention (for example `$dnabert2`) has highest priority
2. explicit model/framework mention (for example `NTv3_100M_post`) maps to its owning skill
3. task-to-skill mapping from `registry/skills.yaml`
4. trigger keyword overlap from skill metadata

Default candidate limit: top 1 skill, with at most 1 fallback candidate.

## Step 3: Validate Required Inputs

Before drafting commands, check task-specific required inputs.

Required inputs by task:

- `environment-setup`: OS/runtime + target stack + hardware context
- `embedding`: sequence or interval + species/assembly (when interval-based) + expected output
- `variant-effect`: assembly + coordinate/interval or VCF input + allele/variant spec + selected modality
- `fine-tuning`: dataset schema + target label task + compute constraints
- `track-prediction`: species + assembly + interval + model/head choice
- `troubleshooting`: failing step or error + runtime context

If a required input is missing and risky to infer, ask a focused question. Otherwise continue with explicit assumptions.

## Step 4: Apply Constraint Filter

Filter out candidates that violate hard constraints, for example:

- unsupported sequence length or divisibility requirements
- incompatible runtime/toolchain assumptions
- unavailable hosted/local execution path
- unsupported API symbols in skill references

If all candidates fail constraints, provide a safe fallback plan and explain why.

## Step 5: Select and Execute

Execution order:

1. chosen skill `SKILL.md`
2. related `playbooks/<task>/README.md`
3. skill `references/` and helper scripts

Decision policy:

- emit `decision=route` when confidence is sufficient
- emit `decision=clarify` when confidence is low and user did not provide an explicit task
- include confidence level and a single focused clarification question

Answer format:

- short routing decision sentence
- runnable workflow snippet
- caveat summary
- optional fallback

## Task-to-Skill Defaults

- `environment-setup` -> `alphagenome-api`, `gpn-models`, `nucleotide-transformer`, `nucleotide-transformer-v3`, `borzoi-workflows`, `evo2-inference`
- `embedding` -> `dnabert2`, `nucleotide-transformer`, `nucleotide-transformer-v3`, `evo2-inference`
- `variant-effect` -> `alphagenome-api`, `borzoi-workflows`, `gpn-models`, `evo2-inference`
- `fine-tuning` -> `dnabert2`, `nucleotide-transformer-v3`, `bpnet`, `basset-workflows`
- `track-prediction` -> `alphagenome-api`, `nucleotide-transformer-v3`, `segment-nt`, `borzoi-workflows`
- `troubleshooting` -> pick the skill that owns the failing stack or model family

Fine-tuning disambiguation rule:

- Prefer `dnabert2` for generic CSV/classification fine-tuning requests.
- Prefer `nucleotide-transformer-v3` when the request explicitly targets NTv3 and/or bigwig or annotation heads with species-conditioned setup.

Variant-effect multi-skill composition rule:

- Keep single primary skill by default.
- Only emit a composite multi-skill variant-effect execution plan when both are true:
  - explicit comparison intent is present (`compare`, `comparison`, `benchmark`, `all-skills`, `multi-skill`, `对比`, `比较`, `多技能`, `多模型`, `全量`)
  - query explicitly mentions at least 2 variant-effect skills among `alphagenome-api`, `borzoi-workflows`, `evo2-inference`, `gpn-models`.
