# Variant-Effect Playbook

## Purpose

Provide one contract-aligned playbook for:

- single-skill variant-effect execution (default behavior)
- explicit multi-skill comparison execution (opt-in behavior)

## Required Inputs (Canonical Keys)

Required:

- `assembly`
- `coordinate-or-interval`
- `ref-alt-or-variant-spec`

Optional but strongly recommended for batch mode:

- `vcf-input`
- `output-dir` or run-root preference

## Routing and Trigger Rules

Default path:

- Keep single primary skill execution.

Multi-skill comparison path:

- Trigger only when both are true:
  - query includes explicit comparison intent keyword: `compare`, `comparison`, `benchmark`, `all-skills`, `multi-skill`, `对比`, `比较`, `多技能`, `多模型`, `全量`
  - query explicitly names at least 2 variant-effect skills among `alphagenome-api`, `borzoi-workflows`, `evo2-inference`, `gpn-models`

No comparison keyword:

- Even if multiple skills are mentioned, stay in single-skill execution.

## Entry Points

Single-skill route:

```bash
bash scripts/run_agent.sh \
  --task variant-effect \
  --query 'Use $borzoi-workflows variant-effect on hg38 chr12 position 1000000 ALT G and save outputs to output/borzoi' \
  --format json
```

Explicit multi-skill route:

```bash
bash scripts/run_agent.sh \
  --task variant-effect \
  --query 'Compare variant-effect across $alphagenome-api $borzoi-workflows $evo2-inference $gpn-models on case-study-playbooks/variant-effect/vcf/Test.geuvadis.vcf, assembly hg38' \
  --format json
```

Case runner (direct):

```bash
bash case-study-playbooks/variant-effect/run_variant_effect_case.sh \
  --vcf case-study-playbooks/variant-effect/vcf/Test.geuvadis.vcf \
  --run-id "$(date -u +%Y%m%dT%H%M%SZ)" \
  --skills alphagenome,borzoi,evo2,gpn \
  --assembly hg38 \
  --continue-on-error 1
```

## VCF Batch Contract

`run_variant_effect_case.sh` enforces:

- input validation: VCF must exist and be non-empty
- SNP filtering: only A/C/G/T single-base REF/ALT entries enter the batch manifest
- dropped non-SNP records are counted in summary metadata
- run root naming: UTC `YYYYMMDDTHHMMSSZ`
- per-row failure recording fields include `status`, `error`, `run_time_utc`, `result_json`

## Evo2 Stability Contract

Default policy:

- try higher windows first (`2048 -> 1024 -> 512 -> 256`)
- for each window: direct request first, optional proxy retry second
- stop early once all variants succeed

Audit requirements:

- summary must record final effective `window_len`
- summary must record downgrade/attempt history

## Unified Outputs

Run root: `case-study-playbooks/variant-effect/<run_id>/`

Mandatory:

- `variant_effect_case_summary.json`
- `logs/variant_effect_case_manifest.tsv`
- `logs/unified_variant_effect_records.tsv` (wide table primary output)
- `logs/unified_variant_effect_records.json`

Per-skill standardized records:

- `<skill>_results/<skill>_variant_effect_records.tsv`
- `<skill>_results/<skill>_variant_effect_records.json`
- `<skill>_results/<skill>_variant_effect_schema.md`

## Related

- [Getting Started](../getting-started/README.md)
- [Troubleshooting](../troubleshooting/README.md)
