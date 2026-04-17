# Embedding Playbook

## Purpose

Provide a contract-aligned orchestration pattern for embedding execution under
`case-study-playbooks/embedding/<run_id>`.

## Use This When

- The user asks for sequence or interval embeddings.
- The user needs token-level or pooled representation guidance.
- The user wants reproducible run-id based outputs and logs.

## Required Inputs (Canonical Keys)

Required task-contract keys:

- `sequence-or-interval`
- `embedding-target`

Optional context that improves execution quality:

- BED path for batch interval execution
- explicit `run_id` (`YYYYMMDDTHHMMSSZ`)
- explicit skill set (`dnabert2`, `evo2`, `ntv3`)
- species and assembly labels

## Output Contract (Run-Root Semantics)

Default run root:

- `case-study-playbooks/embedding/<run_id>/`

Core outputs:

- `embedding_case_summary.json`
- `logs/embedding_case_manifest.tsv`
- `logs/embedding_intervals_manifest.tsv`
- `logs/history_archive_manifest.tsv`

Per-skill interval outputs:

- `dnabert2_results/interval_*/...`
- `evo2_results/interval_*/...`
- `ntv3_results/interval_*/...`

## Skill Selection Heuristics

1. Prefer `dnabert2` when the user explicitly mentions DNABERT-2.
2. Prefer `nucleotide-transformer-v3` for NTv3 species-conditioned embedding paths.
3. Prefer `evo2-inference` when hosted fallback behavior is important.
4. Use `run_embedding_case.sh --skills ...` when the request explicitly needs multi-skill embedding execution.

## Runbook (Minimal Commands)

Generate plan (text):

```bash
bash scripts/run_agent.sh \
  --task embedding \
  --query 'Use $dnabert2 to run embedding case-study on case-study-playbooks/embedding/bed/Test.interval.bed with run_id 20260417T000000Z' \
  --format text
```

Generate plan (json):

```bash
bash scripts/run_agent.sh \
  --task embedding \
  --query 'Use $dnabert2 to run embedding case-study on case-study-playbooks/embedding/bed/Test.interval.bed with run_id 20260417T000000Z' \
  --format json
```

Run the multi-skill embedding case-study directly:

```bash
bash case-study-playbooks/embedding/run_embedding_case.sh \
  --bed case-study-playbooks/embedding/bed/Test.interval.bed \
  --run-id 20260417T000000Z \
  --skills dnabert2,evo2,ntv3 \
  --continue-on-error 1
```

Run single-skill entrypoints directly:

```bash
bash case-study-playbooks/embedding/run_dnabert2_case.sh \
  --interval chr19:6700000-6732768 \
  --output-dir case-study-playbooks/embedding/20260417T000000Z/dnabert2_results/interval_0001_chr19_6700000_6732768
```

```bash
bash case-study-playbooks/embedding/run_ntv3_embedding_case.sh \
  --interval chr19:6700000-6732768 \
  --output-dir case-study-playbooks/embedding/20260417T000000Z/ntv3_results/interval_0001_chr19_6700000_6732768
```

```bash
EVO2_INTERVAL=chr19:6700000-6732768 \
EVO2_PLAYBOOK_EMBED_DIR=case-study-playbooks/embedding/20260417T000000Z/evo2_results/interval_0001_chr19_6700000_6732768 \
EVO2_PLAYBOOK_VARIANT_DIR=case-study-playbooks/embedding/20260417T000000Z/evo2_results/interval_0001_chr19_6700000_6732768/variant_sidecar \
bash case-study-playbooks/run_evo2_case.sh
```

## Archiving Notes

- Legacy flat directories (`dnabert2_results`, `evo2_results`, `ntv3_results`) are archived before each new run.
- Archive target is inferred from legacy directory `mtime` as UTC `YYYYMMDDTHHMMSSZ`.
- If archive destination already exists, execution fails fast to avoid overwrite.

## Clarify & Retry

1. Confirm `sequence-or-interval` and `embedding-target`.
2. If using BED batch, confirm BED path and run-id format.
3. Clarify one missing input at a time and re-run.
4. Use `embedding_case_summary.json` as the source of truth for success/failure counts.

## Related Playbooks

- [Getting Started](../getting-started/README.md)
- [Troubleshooting](../troubleshooting/README.md)
