#!/usr/bin/env bash
# run_cases.sh — End-to-end case study runner for s2f-agent
# Usage: bash case-study/run_cases.sh [--dry-run] [--case A1|A2|A3|A4|A5|A6|A7|A8|A9|B1|B2|C1|C2|C3|C4|all]
#
# Runs each case study against run_agent.sh and reports pass/fail.
# For A-class cases, also checks that required output files exist after execution.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"
AGENT="$REPO_ROOT/scripts/run_agent.sh"
CASE_DATA="$REPO_ROOT/case-study"

dry_run=0
target_case="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --case) target_case="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: bash case-study/run_cases.sh [--dry-run] [--case A1|A2|A3|A4|A5|A6|A7|A8|A9|B1|B2|C1|C2|C3|C4|all]"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

pass=0
fail=0
skip=0

run_case() {
  local id="$1" query="$2" task="$3" expected_decision="$4"
  local required_step_contains="${5:-}" required_output="${6:-}" expected_selected_skill="${7:-}"
  local required_assumption_contains="${8:-}" forbidden_step_contains="${9:-}"

  if [[ "$target_case" != "all" && "$target_case" != "$id" ]]; then
    skip=$((skip + 1))
    return 0
  fi

  echo ""
  echo "=== Case $id ==="
  echo "  query: $query"

  local cmd=(bash "$AGENT" --query "$query" --format json)
  [[ -n "$task" ]] && cmd+=(--task "$task")

  local output
  if ! output="$("${cmd[@]}" 2>&1)"; then
    echo "FAIL: $id — run_agent.sh exited non-zero" >&2
    echo "  error: $output" >&2
    fail=$((fail + 1))
    return 0
  fi

  # Check decision
  local decision
  decision="$(printf '%s' "$output" | sed -n 's/.*"decision":"\([^"]*\)".*/\1/p')"
  if [[ "$decision" != "$expected_decision" ]]; then
    echo "FAIL: $id — expected decision=$expected_decision got=$decision" >&2
    fail=$((fail + 1))
    return 0
  fi

  if [[ "$expected_decision" == "route" && -n "$expected_selected_skill" ]]; then
    local selected_skill
    selected_skill="$(printf '%s' "$output" | sed -n 's/.*"selected_skill":"\([^"]*\)".*/\1/p' | head -n 1)"
    if [[ "$selected_skill" != "$expected_selected_skill" ]]; then
      echo "FAIL: $id — expected selected_skill=$expected_selected_skill got=$selected_skill" >&2
      fail=$((fail + 1))
      return 0
    fi
  fi

  # For route decisions: check required step fragment
  if [[ "$expected_decision" == "route" && -n "$required_step_contains" ]]; then
    local steps_lower output_lower
    output_lower="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
    local needle_lower
    needle_lower="$(printf '%s' "$required_step_contains" | tr '[:upper:]' '[:lower:]')"
    if [[ "$output_lower" != *"$needle_lower"* ]]; then
      echo "FAIL: $id — runnable_steps missing fragment: $required_step_contains" >&2
      fail=$((fail + 1))
      return 0
    fi
  fi

  # For route decisions: check required output path mentioned
  if [[ "$expected_decision" == "route" && -n "$required_output" ]]; then
    local out_lower needle_lower
    out_lower="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
    needle_lower="$(printf '%s' "$required_output" | tr '[:upper:]' '[:lower:]')"
    if [[ "$out_lower" != *"$needle_lower"* ]]; then
      echo "FAIL: $id — expected_outputs missing path: $required_output" >&2
      fail=$((fail + 1))
      return 0
    fi
  fi

  if [[ "$expected_decision" == "route" && -n "$required_assumption_contains" ]]; then
    local out_lower needle_lower
    out_lower="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
    needle_lower="$(printf '%s' "$required_assumption_contains" | tr '[:upper:]' '[:lower:]')"
    if [[ "$out_lower" != *"$needle_lower"* ]]; then
      echo "FAIL: $id — assumptions missing fragment: $required_assumption_contains" >&2
      fail=$((fail + 1))
      return 0
    fi
  fi

  if [[ "$expected_decision" == "route" && -n "$forbidden_step_contains" ]]; then
    local out_lower needle_lower
    out_lower="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
    needle_lower="$(printf '%s' "$forbidden_step_contains" | tr '[:upper:]' '[:lower:]')"
    if [[ "$out_lower" == *"$needle_lower"* ]]; then
      echo "FAIL: $id — runnable_steps unexpectedly contains: $forbidden_step_contains" >&2
      fail=$((fail + 1))
      return 0
    fi
  fi

  echo "PASS: $id (decision=$decision)"
  pass=$((pass + 1))
}

# ── Class A: Core execution cases ─────────────────────────────────────────────

# A1: VCF batch variant-effect routing regression case.
# Keep required_step_contains empty to avoid over-coupling with exact step strings.
run_case "A1" \
  "Use AlphaGenome to run VCF batch variant effect prediction on case-study-playbooks/variant-effect/vcf/Test.geuvadis.vcf, assembly hg38, output to output/alphagenome/." \
  "variant-effect" "route" \
  "" ""

run_case "A2" \
  "Use \$nucleotide-transformer-v3 to run track prediction BED batch for human hg38 on case-study-playbooks/track_prediction/bed/Test.interval.bed with run_id 20260416T120000Z." \
  "track-prediction" "route" \
  "run_ntv3_track_case.sh" "case-study-playbooks/track_prediction/20260416T120000Z/ntv3_results/ntv3_bed_batch_summary.json"

run_case "A3" \
  "Use DNABERT2 to compute token-level embeddings for a DNA sequence, output NPZ to output/dnabert2/." \
  "embedding" "route" \
  "" "output/dnabert2"

run_case "A4" \
  "Use borzoi-workflows to score variant effect at hg38 chr12 position 1000000 REF A ALT G, output TSV and trackplot to output/borzoi/." \
  "variant-effect" "route" \
  "" "output/borzoi"

run_case "A5" \
  "Use \$nucleotide-transformer-v3 for binary classification fine-tuning with dataset schema sequence,label and single 24GB GPU budget; emit train-command.sh and eval-metrics.json." \
  "fine-tuning" "route" \
  "" "train-command.sh"

run_case "A6" \
  "Use \$nucleotide-transformer-v3 to run embedding case-study for human hg38 chr19:6700000-6732768 and save outputs to case-study/ntv3/output." \
  "embedding" "route" \
  "nucleotide-transformer-v3-embedding-workflow" "embedding-metadata.json"

run_case "A7" \
  "Use \$nucleotide-transformer-v3 for fine-tuning prep case-study with dataset schema sequence,label in case-study/ntv3/data and single 24GB GPU budget; output to case-study/ntv3/output with train-command.sh and eval-metrics.json." \
  "fine-tuning" "route" \
  "nucleotide-transformer-v3-fine-tuning-workflow" "train-command.sh"

run_case "A8" \
  "Use \$borzoi-workflows to run track prediction BED batch for species human assembly hg38 on case-study-playbooks/track_prediction/bed/Test.interval.bed with run_id 20260416T120000Z." \
  "track-prediction" "route" \
  "run_borzoi_track_case.sh" "case-study-playbooks/track_prediction/20260416T120000Z/borzoi_results/borzoi_bed_batch_summary.json" "borzoi-workflows"

run_case "A9" \
  "Use \$borzoi-workflows to score variant effect at hg38 chr12 position 1000000 REF A ALT G and save outputs to case-study/variant-effect/borzoi_results." \
  "variant-effect" "route" \
  "run_borzoi_predict.py" "" "borzoi-workflows"

# ── Class B: Boundary / clarify cases ─────────────────────────────────────────

run_case "B1" \
  "I want to analyze my genomic sequences." \
  "" "clarify" \
  "" ""

run_case "B2" \
  "Run AlphaGenome variant effect prediction." \
  "variant-effect" "route" \
  "" ""

# ── Class C: Multi-skill cases ─────────────────────────────────────────────────

run_case "C1" \
  "Use borzoi and gpn to compare variant scoring on hg38 chr12 position 1000000 REF A ALT G." \
  "variant-effect" "route" \
  "" ""

run_case "C2" \
  "Compare variant-effect across \$alphagenome-api and \$borzoi-workflows on case-study-playbooks/variant-effect/vcf/Test.geuvadis.vcf with assembly hg38." \
  "variant-effect" "route" \
  "run_variant_effect_case.sh --vcf" "unified_variant_effect_records.tsv" "" "" ""

run_case "C3" \
  "Use \$alphagenome-api and \$borzoi-workflows for variant-effect on case-study-playbooks/variant-effect/vcf/Test.geuvadis.vcf with assembly hg38." \
  "variant-effect" "route" \
  "" "" "" "" "run_variant_effect_case.sh"

run_case "C4" \
  "Use \$evo2-inference variant-effect on case-study-playbooks/variant-effect/vcf/Test.geuvadis.vcf with assembly hg38 and output to case-study-playbooks/variant-effect/20260416T120000Z/evo2_results." \
  "variant-effect" "route" \
  "run_variant_effect_case.sh --vcf" "evo2_variant_batch_summary.json" "" "evo2-summary-includes-window-len-and-downgrade-history" ""

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "case study summary: $pass passed, $fail failed, $skip skipped"
if [[ "$fail" -ne 0 ]]; then
  exit 1
fi
