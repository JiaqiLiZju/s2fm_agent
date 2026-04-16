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
| `assumptions` | coordinate-convention-must-be-explicit, ref-alt-interpretation-limited-to-selected-model, vcf-pos-is-1based-passed-directly-to-genome-variant, indel-supported-snp-and-multibase-ref-alt, info-fields-collected-by-two-pass-and-transparently-output |
| `runnable_steps` | `bash scripts/run_agent.sh --task variant-effect --query {selected_skill}-variant-effect-workflow`; `bash scripts/execute_plan.sh --task variant-effect --query {selected_skill}-variant-effect-workflow --dry-run`; `python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py --variant-spec <chr:pos:alt> --assembly hg38|hg19 --output-dir <dir>`; `python skills/alphagenome-api/scripts/run_alphagenome_vcf_batch.py --input <file.vcf> --assembly hg38|hg19 --output-dir <dir> --non-interactive` |
| `expected_outputs` | plan-json:variant-effect, alphagenome_variant-effect_<chrom>_<position>_<ref>_to_<alt>_result.json, alphagenome_variant-effect_<chrom>_<position>_<ref>_to_<alt>_rnaseq_overlay.png, <vcf_stem>_tissues.tsv |
| `fallbacks` | ask-for-missing-variant-spec, retry-with-network-proxy-once-if-client-create-times-out |
| `retry_policy` | clarify-missing-inputs-then-connectivity-proxy-retry-once |

### embedding

| Field | Value |
|---|---|
| `assumptions` | sequence-length-and-tokenization-must-match-model, embedding-granularity-must-be-explicit |
| `runnable_steps` | `bash scripts/run_agent.sh --task embedding --query {selected_skill}-embedding-workflow` |
| `expected_outputs` | plan-json:embedding, embedding-metadata.json, embedding-shape.txt |
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
| `variant-effect` | clarify-missing-inputs-then-connectivity-proxy-retry-once | borzoi-workflows, gpn-models, evo2-inference |
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
