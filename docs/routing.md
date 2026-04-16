# Routing Reference

## Overview

The `s2f` router maps a free-text genomics query to a primary skill and optional secondary candidates. It is implemented as a pure-bash scoring function inside `scripts/route_query.sh` and is called by both `scripts/run_agent.sh` (full orchestration) and directly by users for inspection.

Two entry points:

| Script | Purpose |
|---|---|
| `scripts/route_query.sh` | Routing decision + confidence only |
| `scripts/run_agent.sh` | Full orchestration: routing + input validation + plan |

Both read `registry/routing.yaml`, `registry/skills.yaml`, and `registry/tags.yaml`.

## Scoring Weights

Scores are accumulated per-skill and determine ranking.

| Weight | Value | Triggered by |
|---|---|---|
| `weight_explicit_skill_mention` | 120 | `$skill-id` pattern in query |
| `weight_skill_id_mention` | 80 | bare skill id mentioned in query |
| `weight_trigger_match` | 25 | skill trigger keyword matched in query |
| `weight_task_alignment` | 20 | skill supports the classified task |
| `infer_phrase_exact_base` | 60 | exact task phrase match (e.g. "variant effect") |
| `infer_phrase_exact_term_bonus` | 12 | per additional term in exact match |
| `infer_task_key_bonus` | 35 | task key present in query after alias expansion |
| `infer_token_match` | 8 | individual query token matches skill metadata |
| `infer_skill_mention_in_task` | 6 | skill mentioned in task context |
| `infer_trigger_match_in_task` | 4 | trigger matched in task context |
| `infer_trigger_match_cap` | 3 | cap on trigger matches per skill |

Source: `registry/routing.yaml`

## Confidence Thresholds

| Band | Primary score | Margin over second | Result |
|---|---|---|---|
| High | ≥ 70 | ≥ 25 | `decision=route` |
| Medium | ≥ 35 | ≥ 10 | `decision=route` |
| Low | below medium | any | `decision=clarify` |

When confidence is low **and** the user did not provide an explicit task hint, the router emits `decision=clarify` with a focused follow-up question instead of a routing decision.

Default clarify question:
> "I can route this better with one detail: which task do you want (environment-setup, embedding, variant-effect, fine-tuning, track-prediction, troubleshooting)?"

## Task Alias Expansion

Before scoring, task phrases in the query are normalized via alias rules.

| Input phrase | Canonical task |
|---|---|
| set up, setup, install, bootstrap, environment | `environment-setup` |
| troubleshoot, debug, error, failure, general-troubleshooting | `troubleshooting` |
| fine tune, fine-tune, finetune, train, training | `fine-tuning` |
| embedding, embed | `embedding` |
| variant effect, variant-effect, variant scoring, ref alt | `variant-effect` |
| track prediction, sequence to track | `track-prediction` |
| model family, choose model | `framework-selection` |
| loading | `loading` |

Source: `registry/routing.yaml` → `task_alias_rules`

## Task-to-Skill Defaults

When no explicit skill is mentioned, the router selects from these defaults (ordered by priority):

| Task | Default skill candidates |
|---|---|
| `environment-setup` | alphagenome-api, gpn-models, nucleotide-transformer, nucleotide-transformer-v3, borzoi-workflows, evo2-inference |
| `embedding` | dnabert2, nucleotide-transformer, nucleotide-transformer-v3, evo2-inference |
| `variant-effect` | alphagenome-api, borzoi-workflows, gpn-models, evo2-inference |
| `fine-tuning` | dnabert2, nucleotide-transformer-v3, bpnet, basset-workflows |
| `track-prediction` | alphagenome-api, nucleotide-transformer-v3, segment-nt, borzoi-workflows |
| `troubleshooting` | skill that owns the failing stack or model family |

Source: `agent/ROUTING.md`

Track-prediction planner behavior (run_agent fastpath):

- If the query explicitly mentions multiple track skills, `run_agent.sh` emits a composite multi-step runnable plan (ordered: AlphaGenome -> NTv3 -> Borzoi -> SegmentNT).
- Default output root is inferred as `case-study-playbooks/track_prediction/<run_id>/` when output directories are not explicitly provided.
- BED resolution priority is: absolute path -> repo-relative path -> `case-study-playbooks/track_prediction/bed/` fallback, with explicit validation error text when unresolved.

Variant-effect planner behavior (run_agent fastpath):

- Default behavior remains single primary skill execution.
- A composite multi-skill variant-effect plan is generated only on explicit comparison intent (`compare`, `comparison`, `benchmark`, `all-skills`, `multi-skill`, `对比`, `比较`, `多技能`, `多模型`, `全量`) and >=2 explicitly mentioned variant skills.
- Mentioning multiple variant-effect skills without explicit comparison keywords keeps single-primary-skill execution.
- Composite execution uses a unified run root (`case-study-playbooks/variant-effect/<run_id>`) and emits wide unified records plus per-skill standardized records.

Fine-tuning disambiguation:

- Prefer `dnabert2` for generic CSV/classification fine-tuning requests.
- Prefer `nucleotide-transformer-v3` when the query explicitly mentions NTv3 and/or `bigwig` / `annotation` species-conditioned objectives.
- For NTv3 case-study prep wording (for example `case-study/ntv3` + `train-command.sh` / `eval-metrics.json`), keep `nucleotide-transformer-v3` as primary and `dnabert2` as fallback secondary.

## The 5-Step Routing Algorithm

1. **Classify primary task** — expand aliases, pick one primary task; mark others secondary
2. **Build candidate set** — explicit `$skill` mention > model/framework mention > task mapping > trigger overlap; top-1 + max 1 fallback
3. **Validate required inputs** — check `registry/task_contracts.yaml`; ask a focused question only when a required input is missing and risky to infer
4. **Apply constraint filter** — drop candidates that violate sequence length, runtime, execution path, or API compatibility constraints
5. **Emit decision** — `route` (sufficient confidence) or `clarify` (low confidence, no explicit task)

## Clarify Behavior

`decision=clarify` fires when:
- overall confidence is low (primary score < 35 or margin < 10), **and**
- the user did not provide an explicit `--task` hint

The clarify response includes:
- `decision: clarify`
- `confidence: low`
- `clarify_question`: a single focused follow-up

To bypass clarify, supply `--task <task>` explicitly:

```bash
bash scripts/route_query.sh \
  --query "Help me run inference" \
  --task embedding \
  --format json
```

## Debugging Routing

Inspect the full scoring output in JSON:

```bash
bash scripts/route_query.sh \
  --query "Use \$dnabert2 for CSV validation" \
  --format json
```

Key output fields:

| Field | Meaning |
|---|---|
| `decision` | `route` or `clarify` |
| `confidence` | `high`, `medium`, or `low` |
| `primary_skill` | top-ranked skill id |
| `secondary_skills` | fallback candidates |
| `clarify_question` | follow-up question when decision is `clarify` |

Run all eval cases against the live router:

```bash
bash scripts/validate_routing.sh
# or
make eval-routing
```

## See Also

- [Contracts Reference](./contracts.md) — how routing feeds into input validation and plan generation
- [Skills Reference](./skills-reference.md) — full skill catalog with triggers and tasks
- `agent/ROUTING.md` — the agent's imperative routing instructions
- `registry/routing.yaml` — raw scoring configuration
