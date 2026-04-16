# Track-Prediction Playbook

## Purpose

Provide a contract-aligned orchestration pattern for batch sequence-to-track prediction tasks.

## Use This When

- The user requests track prediction from BED intervals or genomic intervals.
- The user wants runnable plans for AlphaGenome, NTv3, Borzoi, SegmentNT, or a multi-skill comparison.
- The user needs standardized batch summaries plus per-interval artifacts.

## Required Inputs (Canonical Keys)

Required task-contract keys:

- `species`
- `assembly`
- `sequence-or-interval`

Optional context that improves response quality:

- explicit `output-head` (AlphaGenome defaults to `RNA_SEQ`)
- explicit `run_id`
- explicit per-skill output directory

## Output Contract (Batch Semantics)

The normalized default output root is:

- `case-study-playbooks/track_prediction/<run_id>/`

Expected per-skill summaries:

- `alphagenome_results/alphagenome_track_bed_batch_summary.json`
- `ntv3_results/ntv3_bed_batch_summary.json`
- `borzoi_results/borzoi_bed_batch_summary.json`
- `segmentnt_results/segmentnt_bed_batch_summary.json`

Per-interval artifacts are recorded by each summary and include plots, result JSON files, and run logs.

## Skill Selection Heuristics

1. Prefer `alphagenome-api` when ontology-conditioned heads are requested.
2. Prefer `nucleotide-transformer-v3` for NTv3 species-conditioned track outputs.
3. Prefer `borzoi-workflows` for Borzoi RNA-seq track outputs.
4. Prefer `segment-nt` for SegmentNT segmentation probability tracks.
5. Use multi-skill composite planning when the query explicitly requests multiple skills.

## Runbook (Minimal Commands)

Generate plan (text):

```bash
bash scripts/run_agent.sh \
  --task track-prediction \
  --query 'Run track prediction BED batch for human hg38 using alphagenome ntv3 borzoi segmentnt on case-study-playbooks/track_prediction/bed/Test.interval.bed' \
  --format text
```

Generate plan (json):

```bash
bash scripts/run_agent.sh \
  --task track-prediction \
  --query 'Run track prediction BED batch for human hg38 using alphagenome ntv3 borzoi segmentnt on case-study-playbooks/track_prediction/bed/Test.interval.bed' \
  --format json
```

Run the case-study orchestrator directly:

```bash
bash case-study-playbooks/track_prediction/run_track_prediction_case.sh \
  --bed case-study-playbooks/track_prediction/bed/Test.interval.bed \
  --run-id 20260416T105020Z \
  --skills alphagenome,ntv3,borzoi,segmentnt
```

## Clarify & Retry

1. Confirm `species`, `assembly`, and BED/interval input first.
2. If BED path is invalid, resolve in this order: absolute path, repo-relative path, `case-study-playbooks/track_prediction/bed/` fallback.
3. Retry per-interval network-sensitive failures once when applicable.
4. Use each `*_bed_batch_summary.json` as the source of truth for success/failure counts.

## Related Playbooks

- [Getting Started](../getting-started/README.md)
- [Troubleshooting](../troubleshooting/README.md)
