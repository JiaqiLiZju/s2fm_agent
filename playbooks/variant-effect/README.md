# Variant-Effect Playbook

## Purpose

Provide a contract-aligned orchestration pattern for variant-effect requests.

## Use This When

- The user needs REF vs ALT impact guidance.
- The user asks for variant prioritization or variant scoring workflows.
- The user wants model-specific caveats before execution.

## Required Inputs (Canonical Keys)

Required task-contract keys:

- `assembly`
- `coordinate-or-interval`
- `ref-alt-or-variant-spec`

Optional context that improves routing quality:

- species
- output modality (for example RNA-related tracks)
- execution path preference (local vs hosted)

## Skill Selection Heuristics

1. Prefer `alphagenome-api` when the query explicitly asks for AlphaGenome API methods.
2. Prefer `borzoi-workflows` for Borzoi tutorial-grounded variant workflows.
3. Prefer `gpn-models` for framework-selection-heavy variant analysis.
4. Consider `evo2-inference` when local GPU constraints suggest hosted fallback.

## Output Expectations (Mapped to Output Contract)

For `variant-effect` in `registry/output_contracts.yaml`, a high-quality response should map to:

- `assumptions`: coordinate convention and model-limited REF/ALT interpretation
- `runnable_steps`: reproducible command chain for routing plus playbook reference
- `expected_outputs`: variant-effect plan artifact expectations
- `fallbacks`: clarify missing variant specification and alternative skills
- `retry_policy`: clarify missing inputs, then retry once

## Minimal Reproducible Commands

Text output:

```bash
bash scripts/run_agent.sh \
  --task variant-effect \
  --query 'Use $alphagenome-api variant-effect on hg38 chr12 REF A ALT G' \
  --format text
```

JSON output:

```bash
bash scripts/run_agent.sh \
  --task variant-effect \
  --query 'Use $alphagenome-api variant-effect on hg38 chr12 REF A ALT G' \
  --format json
```

## Clarify Flow (When Inputs Are Missing)

1. Check `missing_inputs` in the `run_agent.sh` output.
2. Ask one focused follow-up per missing key, prioritizing `assembly` then coordinate and allele specification.
3. Re-run `run_agent.sh` with the clarified inputs.
4. Validate dry-run execution with `scripts/execute_plan.sh` before any real run.

## AlphaGenome Real-Run Fast Path

When task + inputs are complete (assembly/chrom/position/ALT), prefer running:

```bash
set -a; source .env; set +a
conda run -n alphagenome-py310 \
  python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py \
  --chrom chr12 \
  --position 1000000 \
  --alt G \
  --assembly hg38 \
  --output-dir output/alphagenome
```

If client creation fails with `grpc.FutureTimeoutError`, retry via proxy:

```bash
set -a; source .env; set +a
grpc_proxy=http://127.0.0.1:7890 \
http_proxy=http://127.0.0.1:7890 \
https_proxy=http://127.0.0.1:7890 \
conda run -n alphagenome-py310 \
  python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py \
  --chrom chr12 \
  --position 1000000 \
  --alt G \
  --assembly hg38 \
  --output-dir output/alphagenome \
  --request-timeout-sec 120
```

## Matching Tutorial

- [Variant-Effect Tutorial](../../tutorials/02-variant-effect.md)
- [Troubleshooting and Clarify Tutorial](../../tutorials/06-troubleshooting-and-clarify.md)
