# Variant-Effect Case Playbook (Execution Layer)

This directory contains the executable case-study workflow for multi-skill
variant-effect runs on VCF input.

Behavior guarantees:

- run-root is replayable and timestamped as UTC `YYYYMMDDTHHMMSSZ`
- VCF input is validated and normalized into a SNP-only manifest
- unified wide output and per-skill standardized records are always emitted
- Evo2 uses adaptive window fallback with attempt history recording

## Entry Points

- `run_variant_effect_case.sh`
  - End-to-end run for `alphagenome`, `borzoi`, `evo2`, `gpn`
  - Archives legacy outputs into timestamped folders
  - Uses UTC run id format: `YYYYMMDDTHHMMSSZ`
- `run_evo2_variant_batch.py`
  - Evo2 strict REF/ALT batch runner from normalized variant manifest
  - Supports timeout/attempt controls for hosted API stability
- `build_unified_variant_effect_report.py`
  - Produces unified cross-skill wide report under `logs/`
- `build_skill_variant_effect_reports.py`
  - Produces standardized per-skill records inside each skill folder

## Quick Run

```bash
bash case-study-playbooks/variant-effect/run_variant_effect_case.sh \
  --vcf case-study-playbooks/variant-effect/vcf/Test.geuvadis.vcf \
  --skills alphagenome,borzoi,evo2,gpn \
  --assembly hg38 \
  --continue-on-error 1
```

## Output Contract (Run Root)

Run root example: `case-study-playbooks/variant-effect/20260416T114822Z/`

- `variant_effect_case_summary.json`
- `logs/variant_effect_case_manifest.tsv`
- `logs/variants_manifest.tsv`
- `logs/unified_variant_effect_records.tsv` (wide cross-skill table)
- `logs/unified_variant_effect_records.json`
- `<skill>_results/<skill>_variant_effect_records.tsv`
- `<skill>_results/<skill>_variant_effect_records.json`
- `<skill>_results/<skill>_variant_effect_schema.md`

## Notes

- VCF manifest rows include only SNPs; non-SNP records are counted in summary metadata.
- Failure rows keep auditable fields: `status`, `error`, `run_time_utc`, `result_json`.
- Evo2 summary includes effective `window_len` and downgrade history across retry attempts.
