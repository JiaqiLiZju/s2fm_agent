# Task Contracts, Output Contracts, and Recovery Policies

## How Contracts Interlock

Three YAML files in `registry/` form the contract surface for task execution:

1. **Task contracts** (`registry/task_contracts.yaml`) — define required inputs that must be present before `run_agent.sh` proceeds. Missing inputs become `missing_inputs` in the output.
2. **Output contracts** (`registry/output_contracts.yaml`) — define what a valid normalized plan looks like: assumptions, runnable steps, expected output files, and fallbacks.
3. **Recovery policies** (`registry/recovery_policies.yaml`) — define retry strategy and ordered fallback skill candidates when a plan fails.

`run_agent.sh` reads all three files on every invocation.

## Task Contracts

Required canonical inputs per task. All keys must be present (or inferable) for `missing_inputs` to be empty.

| Task | Required canonical inputs | Aliases |
|---|---|---|
| `environment-setup` | target-stack-or-model-family, runtime-context, hardware-context | `setup` |
| `embedding` | sequence-or-interval, embedding-target | — |
| `variant-effect` | assembly, coordinate-or-interval, ref-alt-or-variant-spec | — |
| `fine-tuning` | task-objective, dataset-schema, compute-constraints | — |
| `track-prediction` | species, assembly, sequence-or-interval | — |
| `troubleshooting` | failing-step-or-error, runtime-context | `general-troubleshooting` |
| `loading` | model-family-objective, runtime-context | — |
| `framework-selection` | model-family-objective, objective | — |

Source: `registry/task_contracts.yaml`

## Output Contracts

For the four core executable tasks, the output contract defines the expected shape of the normalized `plan` object emitted by `run_agent.sh`.

### variant-effect

| Field | Value |
|---|---|
| `assumptions` | coordinate-convention-must-be-explicit, ref-alt-interpretation-limited-to-selected-model, explicit-compare-intent-required-for-multi-skill-composition, vcf-batch-manifest-normalizes-to-snp-records-with-status-tracking, unified-output-defaults-to-wide-table-plus-per-skill-standardized-records, evo2-prefers-large-window-then-adaptive-window-fallback |
| `runnable_steps` | `bash scripts/run_agent.sh --task variant-effect --query {selected_skill}-variant-effect-workflow`; explicit multi-skill: `bash case-study-playbooks/variant-effect/run_variant_effect_case.sh --vcf <file.vcf> --run-id <YYYYMMDDTHHMMSSZ> --skills alphagenome,borzoi,evo2,gpn --assembly hg38 --continue-on-error 1` |
| `expected_outputs` | plan-json:variant-effect, case-study-playbooks/variant-effect/<run_id>/variant_effect_case_summary.json, case-study-playbooks/variant-effect/<run_id>/logs/variant_effect_case_manifest.tsv, case-study-playbooks/variant-effect/<run_id>/logs/unified_variant_effect_records.tsv, case-study-playbooks/variant-effect/<run_id>/logs/unified_variant_effect_records.json, plus per-skill `*_variant_effect_records.tsv` |
| `fallbacks` | ask-for-missing-variant-spec, fallback-to-single-primary-skill-when-no-explicit-compare-intent, retry-with-network-proxy-once-if-hosted-api-times-out |
| `retry_policy` | adaptive-window-fallback-with-timeout-proxy-retry |

### embedding

| Field | Value |
|---|---|
| `assumptions` | sequence-length-and-tokenization-must-match-model, embedding-granularity-must-be-explicit |
| `runnable_steps` | `bash case-study-playbooks/embedding/run_embedding_case.sh --bed case-study-playbooks/embedding/bed/Test.interval.bed --run-id $(date -u +%Y%m%dT%H%M%SZ) --skills all --continue-on-error 1` |
| `expected_outputs` | plan-json:embedding, case-study-playbooks/embedding/<run_id>/embedding_case_summary.json, case-study-playbooks/embedding/<run_id>/logs/embedding_case_manifest.tsv, case-study-playbooks/embedding/<run_id>/logs/embedding_intervals_manifest.tsv, case-study-playbooks/embedding/<run_id>/logs/history_archive_manifest.tsv, plus per-skill interval results under `dnabert2_results`, `evo2_results`, `ntv3_results` |
| `fallbacks` | switch-to-compatible-embedding-skill |
| `retry_policy` | clarify-then-single-retry |

### fine-tuning

| Field | Value |
|---|---|
| `assumptions` | dataset-schema-must-be-validated-before-training, evaluation-artifacts-path-must-be-defined |
| `runnable_steps` | `bash scripts/run_agent.sh --task fine-tuning --query {selected_skill}-fine-tuning-workflow` |
| `expected_outputs` | plan-json:fine-tuning, train-command.sh, eval-metrics.json |
| `fallbacks` | reduce-scope-to-minimal-train-run |
| `retry_policy` | clarify-then-single-retry |

### track-prediction

| Field | Value |
|---|---|
| `assumptions` | species-and-assembly-must-be-provided, bed-batch-summary-is-source-of-truth-for-partial-failures, per-interval-artifacts-must-land-under-track-run-root |
| `runnable_steps` | `bash scripts/run_agent.sh --task track-prediction --query {selected_skill}-track-prediction-workflow` |
| `expected_outputs` | plan-json:track-prediction, case-study-playbooks/track_prediction/<run_id>/alphagenome_results/alphagenome_track_bed_batch_summary.json, case-study-playbooks/track_prediction/<run_id>/ntv3_results/ntv3_bed_batch_summary.json, case-study-playbooks/track_prediction/<run_id>/borzoi_results/borzoi_bed_batch_summary.json, case-study-playbooks/track_prediction/<run_id>/segmentnt_results/segmentnt_bed_batch_summary.json, case-study-playbooks/track_prediction/<run_id>/*_results/*_trackplot.png, case-study-playbooks/track_prediction/<run_id>/*_results/*_result.json, case-study-playbooks/track_prediction/<run_id>/*_results/*.log |
| `fallbacks` | fallback-to-secondary-track-skill |
| `retry_policy` | clarify-interval-or-bed-then-per-interval-network-retry-once |

Source: `registry/output_contracts.yaml`

## Recovery Policies

When a plan step fails, the recovery policy defines the retry strategy and ordered fallback skills.

| Task | Retry policy | Fallback skills (ordered) |
|---|---|---|
| `variant-effect` | adaptive-window-fallback-with-timeout-proxy-retry | borzoi-workflows, gpn-models, evo2-inference |
| `embedding` | clarify-embedding-target-then-retry-once | nucleotide-transformer-v3, evo2-inference |
| `fine-tuning` | clarify-dataset-schema-then-retry-once | dnabert2 |
| `track-prediction` | clarify-interval-or-bed-then-per-interval-network-retry-once | alphagenome-api, nucleotide-transformer-v3, borzoi-workflows, segment-nt |

Source: `registry/recovery_policies.yaml`

## How run_agent.sh Uses Contracts

On each invocation, `run_agent.sh`:

1. Calls `route_query.sh` to get `primary_skill` and `decision`
2. Looks up the task in `task_contracts.yaml` to get `canonical_required_inputs`
3. Maps query tokens against `input_schema.yaml` to populate `provided_inputs_canonical`
4. Emits `missing_inputs_canonical` = required − provided
5. If decision is `route` and missing inputs are empty, emits a normalized `plan` object from `output_contracts.yaml`
6. Emits both canonical fields (`required_inputs_canonical`, `provided_inputs_canonical`, `missing_inputs_canonical`) and legacy equivalents for backwards compatibility

## Validation

Check that all task contract keys exist in the canonical input schema and are consistent with skill-level `skill.yaml` contracts:

```bash
bash scripts/validate_input_contracts.sh
# or
make validate-input-contracts
```

## See Also

- [Input Schema Reference](./input-schema.md)
- [Routing Reference](./routing.md)
- [Scripts Reference](./scripts-reference.md)
- `playbooks/variant-effect/README.md`, `playbooks/embedding/README.md`, etc. — procedural walkthroughs per task
