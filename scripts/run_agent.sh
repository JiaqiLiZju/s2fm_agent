#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY_FILE="$REPO_ROOT/registry/skills.yaml"
DEFAULT_TAGS_FILE="$REPO_ROOT/registry/tags.yaml"
DEFAULT_ROUTING_FILE="$REPO_ROOT/registry/routing.yaml"
DEFAULT_CONTRACTS_FILE="$REPO_ROOT/registry/task_contracts.yaml"
DEFAULT_OUTPUT_CONTRACTS_FILE="$REPO_ROOT/registry/output_contracts.yaml"
DEFAULT_RECOVERY_POLICIES_FILE="$REPO_ROOT/registry/recovery_policies.yaml"
DEFAULT_INPUT_SCHEMA_FILE="$REPO_ROOT/registry/input_schema.yaml"
DEFAULT_ROUTER_SCRIPT="$REPO_ROOT/scripts/route_query.sh"
source "$REPO_ROOT/scripts/lib_registry.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: run_agent.sh [options]

Run the s2f agent orchestration for one query:
- route to a primary skill
- provide secondary candidates
- map to playbook (if available)
- report required inputs and missing fields

Options:
  --query TEXT           Query text to process. If omitted, read from stdin.
  --task TASK            Optional task hint.
  --top-k N              Number of total candidates to include. Default: 3
  --format FMT           Output format: text or json. Default: text
  --registry FILE        Skill registry file. Default: <repo>/registry/skills.yaml
  --tags FILE            Task tag registry file. Default: <repo>/registry/tags.yaml
  --routing-config FILE  Routing config for router. Default: <repo>/registry/routing.yaml
  --contracts FILE       Task contracts file. Default: <repo>/registry/task_contracts.yaml
  --output-contracts FILE Output contracts file. Default: <repo>/registry/output_contracts.yaml
  --recovery FILE        Recovery policy file. Default: <repo>/registry/recovery_policies.yaml
  --input-schema FILE    Canonical input schema file. Default: <repo>/registry/input_schema.yaml
  --router FILE          Router script path. Default: <repo>/scripts/route_query.sh
  --include-disabled     Include disabled skills in routing candidates.
  -h, --help             Show this help message.
EOF_USAGE
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_text() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

contains_token() {
  local haystack="$1"
  local needle="$2"
  if [[ -z "$needle" ]]; then
    return 1
  fi
  [[ "$haystack" == *"$needle"* ]]
}

in_csv_list() {
  local value="${1:-}"
  local csv="${2:-}"
  if [[ -z "$value" || -z "$csv" ]]; then
    return 1
  fi
  local -a arr=()
  IFS=',' read -r -a arr <<<"$csv"
  if [[ ${#arr[@]} -eq 0 ]]; then
    return 1
  fi
  for item in "${arr[@]}"; do
    if [[ "$item" == "$value" ]]; then
      return 0
    fi
  done
  return 1
}

append_csv() {
  local csv="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$csv"
    return 0
  fi
  if in_csv_list "$value" "$csv"; then
    printf '%s\n' "$csv"
    return 0
  fi
  if [[ -z "$csv" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$csv,$value"
  fi
}

remove_csv_item() {
  local csv="${1:-}"
  local target="${2:-}"
  local out=""
  local -a arr=()
  local item
  if [[ -z "$csv" || -z "$target" ]]; then
    printf '%s\n' "$csv"
    return 0
  fi
  IFS=',' read -r -a arr <<<"$csv"
  for item in "${arr[@]}"; do
    [[ -z "$item" ]] && continue
    if [[ "$item" == "$target" ]]; then
      continue
    fi
    out="$(append_csv "$out" "$item")"
  done
  printf '%s\n' "$out"
}

csv_to_lines_prefixed() {
  local csv="${1:-}"
  local prefix="${2:-- }"
  if [[ -z "$csv" ]]; then
    return 0
  fi
  local -a arr=()
  IFS=',' read -r -a arr <<<"$csv"
  for item in "${arr[@]}"; do
    [[ -z "$item" ]] && continue
    printf '%s%s\n' "$prefix" "$item"
  done
}

emit_json_array_from_csv() {
  local csv="${1:-}"
  local first=1
  local item
  printf '['
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    if [[ "$first" -eq 0 ]]; then
      printf ','
    fi
    printf '"%s"' "$(json_escape "$item")"
    first=0
  done < <(printf '%s\n' "$csv" | tr ',' '\n')
  printf ']'
}

emit_text_plan_block() {
  local plan_task="$1"
  local selected_skill="$2"
  local assumptions_csv="$3"
  local required_csv="$4"
  local missing_csv="$5"
  local constraints_csv="$6"
  local steps_csv="$7"
  local outputs_csv="$8"
  local fallbacks_csv="$9"
  local retry_policy="${10:-none}"

  echo "plan:"
  echo "  task: $plan_task"
  echo "  selected_skill: $selected_skill"
  echo "  assumptions:"
  if [[ -n "$assumptions_csv" ]]; then
    csv_to_lines_prefixed "$assumptions_csv" "    - "
  else
    echo "    - none"
  fi
  echo "  required_inputs:"
  if [[ -n "$required_csv" ]]; then
    csv_to_lines_prefixed "$required_csv" "    - "
  else
    echo "    - none"
  fi
  echo "  missing_inputs:"
  if [[ -n "$missing_csv" ]]; then
    csv_to_lines_prefixed "$missing_csv" "    - "
  else
    echo "    - none"
  fi
  echo "  constraints:"
  if [[ -n "$constraints_csv" ]]; then
    csv_to_lines_prefixed "$constraints_csv" "    - "
  else
    echo "    - none"
  fi
  echo "  runnable_steps:"
  if [[ -n "$steps_csv" ]]; then
    csv_to_lines_prefixed "$steps_csv" "    - "
  else
    echo "    - none"
  fi
  echo "  expected_outputs:"
  if [[ -n "$outputs_csv" ]]; then
    csv_to_lines_prefixed "$outputs_csv" "    - "
  else
    echo "    - none"
  fi
  echo "  fallbacks:"
  if [[ -n "$fallbacks_csv" ]]; then
    csv_to_lines_prefixed "$fallbacks_csv" "    - "
  else
    echo "    - none"
  fi
  echo "  retry_policy: ${retry_policy:-none}"
}

emit_json_plan_object() {
  local plan_task="$1"
  local selected_skill="$2"
  local assumptions_csv="$3"
  local required_csv="$4"
  local missing_csv="$5"
  local constraints_csv="$6"
  local steps_csv="$7"
  local outputs_csv="$8"
  local fallbacks_csv="$9"
  local retry_policy="${10:-none}"

  printf '{'
  printf '"task":"%s",' "$(json_escape "$plan_task")"
  printf '"selected_skill":"%s",' "$(json_escape "$selected_skill")"
  printf '"assumptions":'
  emit_json_array_from_csv "$assumptions_csv"
  printf ','
  printf '"required_inputs":'
  emit_json_array_from_csv "$required_csv"
  printf ','
  printf '"missing_inputs":'
  emit_json_array_from_csv "$missing_csv"
  printf ','
  printf '"constraints":'
  emit_json_array_from_csv "$constraints_csv"
  printf ','
  printf '"runnable_steps":'
  emit_json_array_from_csv "$steps_csv"
  printf ','
  printf '"expected_outputs":'
  emit_json_array_from_csv "$outputs_csv"
  printf ','
  printf '"fallbacks":'
  emit_json_array_from_csv "$fallbacks_csv"
  printf ','
  printf '"retry_policy":"%s"' "$(json_escape "${retry_policy:-none}")"
  printf '}'
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

canonicalize_csv() {
  local csv="${1:-}"
  local schema_file="${2:-}"
  local out=""
  local item=""
  local resolved=""

  if [[ -z "$csv" ]]; then
    printf '\n'
    return 0
  fi

  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    if [[ -n "$schema_file" ]]; then
      resolved="$(input_schema_resolve_key "$schema_file" "$item" || true)"
    else
      resolved=""
    fi
    if [[ -z "$resolved" ]]; then
      resolved="$item"
    fi
    out="$(append_csv "$out" "$resolved")"
  done < <(printf '%s\n' "$csv" | tr ',' '\n')

  printf '%s\n' "$out"
}

extract_decision_from_json() {
  local json="$1"
  printf '%s\n' "$json" | sed -n 's/.*"decision":"\([^"]*\)".*/\1/p'
}

extract_task_from_json() {
  local json="$1"
  if printf '%s\n' "$json" | grep -q '"task":null'; then
    printf '\n'
    return 0
  fi
  printf '%s\n' "$json" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p'
}

extract_task_source_from_json() {
  local json="$1"
  printf '%s\n' "$json" | sed -n 's/.*"task_source":"\([^"]*\)".*/\1/p'
}

extract_confidence_level_from_json() {
  local json="$1"
  printf '%s\n' "$json" | sed -n 's/.*"confidence":{"level":"\([^"]*\)","score":[0-9.]*}.*/\1/p'
}

extract_confidence_score_from_json() {
  local json="$1"
  printf '%s\n' "$json" | sed -n 's/.*"confidence":{"level":"[^"]*","score":\([0-9.]*\)}.*/\1/p'
}

extract_clarify_question_from_json() {
  local json="$1"
  if printf '%s\n' "$json" | grep -q '"clarify_question":null'; then
    printf '\n'
    return 0
  fi
  printf '%s\n' "$json" | sed -n 's/.*"clarify_question":"\([^"]*\)".*/\1/p' | sed 's/\\"/"/g'
}

extract_primary_skill_from_json() {
  local json="$1"
  printf '%s\n' "$json" | sed -n 's/.*"primary":{"skill":"\([^"]*\)".*/\1/p'
}

extract_secondary_csv_from_json() {
  local json="$1"
  local csv=""
  local first=1
  local skill
  while IFS= read -r skill; do
    [[ -z "$skill" ]] && continue
    if [[ "$first" -eq 1 ]]; then
      first=0
      continue
    fi
    csv="$(append_csv "$csv" "$skill")"
  done < <(printf '%s\n' "$json" | grep -o '"skill":"[^"]*"' | sed 's/"skill":"//; s/"$//')
  printf '%s\n' "$csv"
}

render_plan_value() {
  local raw="$1"
  local plan_task="$2"
  local selected_skill="$3"
  local rendered="$raw"
  rendered="${rendered//\{task\}/$plan_task}"
  rendered="${rendered//\{selected_skill\}/$selected_skill}"
  printf '%s\n' "$rendered"
}

has_track_head_intent() {
  local query_lc="$1"
  contains_token "$query_lc" "head" || \
    contains_token "$query_lc" "track" || \
    contains_token "$query_lc" "trackplot" || \
    contains_token "$query_lc" "output" || \
    contains_token "$query_lc" "bigwig" || \
    contains_token "$query_lc" "bed" || \
    contains_token "$query_lc" "轨道" || \
    contains_token "$query_lc" "绘图" || \
    contains_token "$query_lc" "绘制" || \
    contains_token "$query_lc" "画图"
}

normalize_numeric_token() {
  local raw="${1:-}"
  printf '%s\n' "$raw" | tr -d '_, ' | tr -cd '0-9'
}

extract_track_run_id_from_query() {
  local query_raw="$1"
  local run_id=""
  run_id="$(printf '%s\n' "$query_raw" | grep -Eo '[0-9]{8}T[0-9]{6}Z' | head -n 1 || true)"
  printf '%s\n' "$run_id"
}

extract_track_output_root_from_query() {
  local query_raw="$1"
  local root=""
  root="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/track_prediction/[0-9]{8}T[0-9]{6}Z' | head -n 1 || true)"
  root="$(printf '%s\n' "$root" | sed -E "s/^[\"'()]+//; s/[\"'(),;:。；，]+$//")"
  printf '%s\n' "$root"
}

extract_track_explicit_skills_from_query() {
  local query_lc="$1"
  local out=""
  if contains_token "$query_lc" "alphagenome"; then
    out="$(append_csv "$out" "alphagenome-api")"
  fi
  if contains_token "$query_lc" "ntv3" || contains_token "$query_lc" "nucleotide-transformer-v3"; then
    out="$(append_csv "$out" "nucleotide-transformer-v3")"
  fi
  if contains_token "$query_lc" "borzoi"; then
    out="$(append_csv "$out" "borzoi-workflows")"
  fi
  if contains_token "$query_lc" "segmentnt" || contains_token "$query_lc" "segment-nt"; then
    out="$(append_csv "$out" "segment-nt")"
  fi
  printf '%s\n' "$out"
}

extract_ntv3_species_from_query() {
  local query_lc="$1"
  if contains_token "$query_lc" "human"; then
    printf 'human\n'
    return 0
  fi
  if contains_token "$query_lc" "mouse" || contains_token "$query_lc" "mice"; then
    printf 'mouse\n'
    return 0
  fi
  printf '\n'
}

extract_ntv3_assembly_from_query() {
  local query_lc="$1"
  if contains_token "$query_lc" "hg38"; then
    printf 'hg38\n'
    return 0
  fi
  if contains_token "$query_lc" "hg19"; then
    printf 'hg19\n'
    return 0
  fi
  if contains_token "$query_lc" "mm10"; then
    printf 'mm10\n'
    return 0
  fi
  if contains_token "$query_lc" "chm13"; then
    printf 'chm13\n'
    return 0
  fi
  printf '\n'
}

extract_ntv3_interval_from_query() {
  local query_lc="$1"
  local token=""
  local chrom=""
  local start_raw=""
  local end_raw=""
  local start=""
  local end=""
  local rest=""

  token="$(printf '%s\n' "$query_lc" | grep -Eio 'chr[[:alnum:]_]+:[0-9_,]+-[0-9_,]+' | head -n 1 || true)"
  if [[ -n "$token" ]]; then
    chrom="${token%%:*}"
    rest="${token#*:}"
    start_raw="${rest%-*}"
    end_raw="${rest#*-}"
    start="$(normalize_numeric_token "$start_raw")"
    end="$(normalize_numeric_token "$end_raw")"
  fi

  if [[ -z "$chrom" ]]; then
    chrom="$(printf '%s\n' "$query_lc" | grep -Eio 'chrom[[:space:]]*=[[:space:]]*"?chr[[:alnum:]_]+' | head -n 1 | sed -E 's/.*(chr[[:alnum:]_]+).*/\1/' || true)"
  fi
  if [[ -z "$chrom" ]]; then
    chrom="$(printf '%s\n' "$query_lc" | grep -Eio 'chr[[:alnum:]_]+' | head -n 1 || true)"
  fi
  if [[ -z "$start" ]]; then
    start_raw="$(printf '%s\n' "$query_lc" | grep -Eio 'start[[:space:]]*=[[:space:]]*[0-9_,]+' | head -n 1 | sed -E 's/.*=[[:space:]]*([0-9_,]+).*/\1/' || true)"
    start="$(normalize_numeric_token "$start_raw")"
  fi
  if [[ -z "$end" ]]; then
    end_raw="$(printf '%s\n' "$query_lc" | grep -Eio 'end[[:space:]]*=[[:space:]]*[0-9_,]+' | head -n 1 | sed -E 's/.*=[[:space:]]*([0-9_,]+).*/\1/' || true)"
    end="$(normalize_numeric_token "$end_raw")"
  fi

  if [[ -n "$chrom" && -n "$start" && -n "$end" ]]; then
    printf '%s,%s,%s\n' "$chrom" "$start" "$end"
    return 0
  fi
  printf '\n'
}

extract_ntv3_bed_path_from_query() {
  local query_raw="$1"
  local bed_path=""
  bed_path="$(printf '%s\n' "$query_raw" | grep -Eo '[/A-Za-z0-9._~-]+\.bed' | head -n 1 || true)"
  if [[ -z "$bed_path" ]]; then
    printf '\n'
    return 0
  fi
  bed_path="$(printf '%s\n' "$bed_path" | sed -E "s/^[\"'()]+//; s/[\"'(),;:。；，]+$//")"
  printf '%s\n' "$bed_path"
}

extract_ntv3_output_dir_from_query() {
  local query_raw="$1"
  local out=""
  out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/track_prediction/[0-9]{8}T[0-9]{6}Z/ntv3_results' | head -n 1 || true)"
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/[A-Za-z0-9._/-]*ntv3_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study/[A-Za-z0-9._/-]*ntv3_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'output/[A-Za-z0-9._/-]*ntv3_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio '[A-Za-z0-9._/-]*ntv3_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  out="$(printf '%s\n' "$out" | sed -E "s/^[\"'()]+//; s/[\"'(),;:。；，]+$//")"
  out="${out%/.}"
  out="${out%/}"
  printf '%s\n' "$out"
}

extract_alphagenome_track_species_from_query() {
  local query_lc="$1"
  extract_ntv3_species_from_query "$query_lc"
}

extract_alphagenome_track_interval_from_query() {
  local query_lc="$1"
  extract_ntv3_interval_from_query "$query_lc"
}

extract_alphagenome_track_bed_path_from_query() {
  local query_raw="$1"
  extract_ntv3_bed_path_from_query "$query_raw"
}

extract_alphagenome_track_output_dir_from_query() {
  local query_raw="$1"
  local out=""
  out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/track_prediction/[0-9]{8}T[0-9]{6}Z/alphagenome_results' | head -n 1 || true)"
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/[A-Za-z0-9._/-]*alphagenome_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'output/[A-Za-z0-9._/-]*alphagenome[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio '[A-Za-z0-9._/-]*alphagenome_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  out="$(printf '%s\n' "$out" | sed -E "s/^[\"'()]+//; s/[\"'(),;:。；，]+$//")"
  out="${out%/.}"
  out="${out%/}"
  printf '%s\n' "$out"
}

extract_borzoi_track_output_dir_from_query() {
  local query_raw="$1"
  local out=""
  out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/track_prediction/[0-9]{8}T[0-9]{6}Z/borzoi_results' | head -n 1 || true)"
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/[A-Za-z0-9._/-]*borzoi_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study/[A-Za-z0-9._/-]*borzoi_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'output/[A-Za-z0-9._/-]*borzoi[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio '[A-Za-z0-9._/-]*borzoi_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  out="$(printf '%s\n' "$out" | sed -E "s/^[\"'()]+//; s/[\"'(),;:。；，]+$//")"
  out="${out%/.}"
  out="${out%/}"
  printf '%s\n' "$out"
}

extract_segmentnt_track_output_dir_from_query() {
  local query_raw="$1"
  local out=""
  out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/track_prediction/[0-9]{8}T[0-9]{6}Z/segmentnt_results' | head -n 1 || true)"
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'case-study-playbooks/[A-Za-z0-9._/-]*segmentnt_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio 'output/[A-Za-z0-9._/-]*segmentnt[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(printf '%s\n' "$query_raw" | grep -Eio '[A-Za-z0-9._/-]*segmentnt_results[A-Za-z0-9._/-]*' | head -n 1 || true)"
  fi
  out="$(printf '%s\n' "$out" | sed -E "s/^[\"'()]+//; s/[\"'(),;:。；，]+$//")"
  out="${out%/.}"
  out="${out%/}"
  printf '%s\n' "$out"
}

csv_count() {
  local csv="${1:-}"
  local count=0
  local item=""
  if [[ -z "$csv" ]]; then
    printf '0\n'
    return 0
  fi
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    count=$((count + 1))
  done < <(printf '%s\n' "$csv" | tr ',' '\n')
  printf '%s\n' "$count"
}

track_query_mentions_all_skills() {
  local query_lc="$1"
  contains_token "$query_lc" "all skills" || \
    contains_token "$query_lc" "all four" || \
    contains_token "$query_lc" "four skills" || \
    contains_token "$query_lc" "四技能" || \
    contains_token "$query_lc" "四个技能" || \
    contains_token "$query_lc" "四种技能" || \
    contains_token "$query_lc" "全部技能"
}

track_skill_case_token() {
  local skill="$1"
  case "$skill" in
    alphagenome-api) printf 'alphagenome\n' ;;
    nucleotide-transformer-v3) printf 'ntv3\n' ;;
    borzoi-workflows) printf 'borzoi\n' ;;
    segment-nt) printf 'segmentnt\n' ;;
    *)
      printf '\n'
      ;;
  esac
}

track_skill_output_subdir() {
  local skill="$1"
  case "$skill" in
    alphagenome-api) printf 'alphagenome_results\n' ;;
    nucleotide-transformer-v3) printf 'ntv3_results\n' ;;
    borzoi-workflows) printf 'borzoi_results\n' ;;
    segment-nt) printf 'segmentnt_results\n' ;;
    *)
      printf '\n'
      ;;
  esac
}

track_skill_summary_file() {
  local skill="$1"
  case "$skill" in
    alphagenome-api) printf 'alphagenome_track_bed_batch_summary.json\n' ;;
    nucleotide-transformer-v3) printf 'ntv3_bed_batch_summary.json\n' ;;
    borzoi-workflows) printf 'borzoi_bed_batch_summary.json\n' ;;
    segment-nt) printf 'segmentnt_bed_batch_summary.json\n' ;;
    *)
      printf '\n'
      ;;
  esac
}

compute_track_run_id() {
  local query_raw="$1"
  local run_id=""
  run_id="$(extract_track_run_id_from_query "$query_raw")"
  if [[ -z "$run_id" ]]; then
    run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  printf '%s\n' "$run_id"
}

compute_track_output_root() {
  local query_raw="$1"
  local run_id="$2"
  local out=""
  out="$(extract_track_output_root_from_query "$query_raw")"
  if [[ -z "$out" ]]; then
    out="case-study-playbooks/track_prediction/${run_id}"
  fi
  out="${out%/.}"
  out="${out%/}"
  printf '%s\n' "$out"
}

default_track_output_dir_for_skill() {
  local output_root="$1"
  local skill="$2"
  local subdir=""
  subdir="$(track_skill_output_subdir "$skill")"
  if [[ -z "$subdir" ]]; then
    printf '%s\n' "$output_root"
    return 0
  fi
  printf '%s/%s\n' "$output_root" "$subdir"
}

resolve_abs_path_text() {
  local raw="$1"
  python3 - "$raw" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
}

resolve_track_bed_path() {
  local bed_path="${1:-}"
  local resolved=""
  local source=""
  local error_msg=""
  local repo_candidate=""
  local fallback_candidate=""
  local fallback_base_candidate=""

  if [[ -z "$bed_path" ]]; then
    printf '||\n'
    return 0
  fi

  if [[ "$bed_path" == /* ]]; then
    if [[ -f "$bed_path" ]]; then
      resolved="$bed_path"
      source="absolute-path"
    else
      error_msg="bed-path-not-found:absolute:${bed_path}"
    fi
  else
    repo_candidate="$REPO_ROOT/$bed_path"
    fallback_candidate="$REPO_ROOT/case-study-playbooks/track_prediction/bed/$bed_path"
    fallback_base_candidate="$REPO_ROOT/case-study-playbooks/track_prediction/bed/$(basename "$bed_path")"
    if [[ -f "$repo_candidate" ]]; then
      resolved="$repo_candidate"
      source="repo-root-relative"
    elif [[ -f "$fallback_candidate" ]]; then
      resolved="$fallback_candidate"
      source="track-bed-fallback"
    elif [[ -f "$fallback_base_candidate" ]]; then
      resolved="$fallback_base_candidate"
      source="track-bed-fallback-basename"
    else
      error_msg="bed-path-not-found:raw=${bed_path};checked=${repo_candidate}|${fallback_candidate}|${fallback_base_candidate}"
    fi
  fi

  if [[ -n "$resolved" ]]; then
    resolved="$(resolve_abs_path_text "$resolved")"
  fi

  printf '%s|%s|%s\n' "$resolved" "$source" "$error_msg"
}

extract_alphagenome_track_head_from_query() {
  local query_lc="$1"
  if contains_token "$query_lc" "rna_seq" || contains_token "$query_lc" "rna-seq" || contains_token "$query_lc" "rna seq"; then
    printf 'RNA_SEQ\n'
    return 0
  fi
  if contains_token "$query_lc" "atac"; then
    printf 'ATAC\n'
    return 0
  fi
  if contains_token "$query_lc" "cage"; then
    printf 'CAGE\n'
    return 0
  fi
  if contains_token "$query_lc" "dnase"; then
    printf 'DNASE\n'
    return 0
  fi
  if contains_token "$query_lc" "chip_tf" || contains_token "$query_lc" "chip tf"; then
    printf 'CHIP_TF\n'
    return 0
  fi
  if contains_token "$query_lc" "chip_histone" || contains_token "$query_lc" "chip histone"; then
    printf 'CHIP_HISTONE\n'
    return 0
  fi
  if contains_token "$query_lc" "splice_sites" || contains_token "$query_lc" "splice sites"; then
    printf 'SPLICE_SITES\n'
    return 0
  fi
  if contains_token "$query_lc" "splice_site_usage" || contains_token "$query_lc" "splice site usage"; then
    printf 'SPLICE_SITE_USAGE\n'
    return 0
  fi
  if contains_token "$query_lc" "splice_junctions" || contains_token "$query_lc" "splice junctions"; then
    printf 'SPLICE_JUNCTIONS\n'
    return 0
  fi
  if contains_token "$query_lc" "contact_maps" || contains_token "$query_lc" "contact maps"; then
    printf 'CONTACT_MAPS\n'
    return 0
  fi
  if contains_token "$query_lc" "procap"; then
    printf 'PROCAP\n'
    return 0
  fi
  printf '\n'
}

extract_alphagenome_ontology_term_from_query() {
  local query_raw="$1"
  local term=""
  term="$(printf '%s\n' "$query_raw" | grep -Eio '(UBERON|CL):[0-9]+' | head -n 1 || true)"
  printf '%s\n' "$term"
}

extract_alphagenome_assembly_from_query() {
  local query_lc="$1"
  extract_ntv3_assembly_from_query "$query_lc"
}

extract_alphagenome_variant_from_query() {
  local query_raw="$1"
  local token=""
  local chrom=""
  local position_raw=""
  local position=""
  local alt_token=""
  local alt=""
  local rest=""

  token="$(printf '%s\n' "$query_raw" | LC_ALL=C grep -Eio 'chr[[:alnum:]_]+:[0-9_,]+' | head -n 1 || true)"
  if [[ -n "$token" ]]; then
    chrom="${token%%:*}"
    rest="${token#*:}"
    position="$(normalize_numeric_token "$rest")"
  fi

  if [[ -z "$chrom" ]]; then
    chrom="$(printf '%s\n' "$query_raw" | LC_ALL=C grep -Eio 'chrom[[:space:]]*=[[:space:]]*"?chr[[:alnum:]_]+' | head -n 1 | sed -E 's/.*(chr[[:alnum:]_]+).*/\1/' || true)"
  fi
  if [[ -z "$chrom" ]]; then
    chrom="$(printf '%s\n' "$query_raw" | LC_ALL=C grep -Eio 'chr[[:alnum:]_]+' | head -n 1 || true)"
  fi

  if [[ -z "$position" ]]; then
    position_raw="$(printf '%s\n' "$query_raw" | grep -Eio 'position[[:space:]]*[:=]?[[:space:]]*[0-9_,]+' | head -n 1 | grep -Eo '[0-9][0-9_,]*' | head -n 1 || true)"
    position="$(normalize_numeric_token "$position_raw")"
  fi
  if [[ -z "$position" ]]; then
    position_raw="$(printf '%s\n' "$query_raw" | grep -Eio '[0-9][0-9_,]*[[:space:]]*位点' | head -n 1 | sed -E 's/[^0-9_,]*([0-9][0-9_,]*).*/\1/' || true)"
    position="$(normalize_numeric_token "$position_raw")"
  fi
  if [[ -z "$position" ]]; then
    position_raw="$(printf '%s\n' "$query_raw" | grep -Eo '[0-9][0-9_,]{4,}' | head -n 1 || true)"
    position="$(normalize_numeric_token "$position_raw")"
  fi

  alt_token="$(printf '%s\n' "$query_raw" | grep -Eio 'alt[[:space:]]*[:=]?[[:space:]]*"?[ACGTN]' | head -n 1 || true)"
  if [[ -n "$alt_token" ]]; then
    alt="$(printf '%s\n' "$alt_token" | sed -E 's/.*([ACGTN])$/\1/' | tr '[:lower:]' '[:upper:]')"
  fi
  if [[ -z "$alt" ]]; then
    alt_token="$(printf '%s\n' "$query_raw" | grep -Eio '[ACGTN][[:space:]]*>[[:space:]]*[ACGTN]' | head -n 1 || true)"
    if [[ -n "$alt_token" ]]; then
      alt="$(printf '%s\n' "$alt_token" | sed -E 's/.*>[[:space:]]*([ACGTN]).*/\1/' | tr '[:lower:]' '[:upper:]')"
    fi
  fi
  if [[ -z "$alt" ]]; then
    alt_token="$(printf '%s\n' "$query_raw" | grep -Eio 'to[[:space:]]*[ACGTN]' | head -n 1 || true)"
    if [[ -n "$alt_token" ]]; then
      alt="$(printf '%s\n' "$alt_token" | sed -E 's/.*([ACGTN])$/\1/' | tr '[:lower:]' '[:upper:]')"
    fi
  fi
  if [[ -z "$alt" ]]; then
    alt_token="$(printf '%s\n' "$query_raw" | grep -Eio '(突变为|变为)[ACGTN]' | head -n 1 || true)"
    if [[ -n "$alt_token" ]]; then
      alt="$(printf '%s\n' "$alt_token" | sed -E 's/.*([ACGTN])$/\1/' | tr '[:lower:]' '[:upper:]')"
    fi
  fi

  if [[ -n "$chrom" && -n "$position" && -n "$alt" ]]; then
    printf '%s,%s,%s\n' "$chrom" "$position" "$alt"
    return 0
  fi
  printf '\n'
}

extract_alphagenome_output_dir_from_query() {
  local query_raw="$1"
  local out=""
  out="$(printf '%s\n' "$query_raw" | grep -Eio 'output/[A-Za-z0-9._/-]+' | head -n 1 || true)"
  if [[ -z "$out" ]]; then
    out="output/alphagenome"
  fi
  out="${out%/}"
  if [[ -z "$out" ]]; then
    out="output/alphagenome"
  fi
  printf '%s\n' "$out"
}

extract_alphagenome_env_from_query() {
  local query_raw="$1"
  local env_name=""
  env_name="$(printf '%s\n' "$query_raw" | grep -Eio 'conda[[:space:]]+run[[:space:]]+-n[[:space:]]+[A-Za-z0-9._-]+' | head -n 1 | awk '{print $NF}' || true)"
  if [[ -z "$env_name" ]]; then
    env_name="$(printf '%s\n' "$query_raw" | grep -Eio 'envs/[A-Za-z0-9._-]+' | head -n 1 | sed -E 's#envs/##' || true)"
  fi
  if [[ -z "$env_name" ]]; then
    env_name="alphagenome-py310"
  fi
  printf '%s\n' "$env_name"
}

resolve_conda_env_prefix() {
  local env_name="$1"
  local prefix=""
  local line=""

  if [[ -z "$env_name" ]]; then
    printf '\n'
    return 0
  fi
  if ! command -v conda >/dev/null 2>&1; then
    printf '\n'
    return 0
  fi

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == *"/envs/${env_name}"* || "$line" == */"${env_name}" ]]; then
      prefix="${line##* }"
    else
      set -- $line
      if [[ "$1" == "$env_name" ]]; then
        prefix="${@: -1}"
      fi
    fi

    if [[ -n "$prefix" && -x "$prefix/bin/python" ]]; then
      printf '%s\n' "$prefix"
      return 0
    fi
    prefix=""
  done < <(conda info --envs 2>/dev/null || true)

  printf '\n'
}

input_satisfied_legacy() {
  local input_name="$1"
  local query_lc="$2"
  local raw="$input_name"
  local phrase
  local token_hits=0
  local token_need=0

  phrase="$(to_lower "$raw")"
  phrase="${phrase//-/ }"
  phrase="${phrase//_/ }"

  if contains_token "$query_lc" "$phrase"; then
    return 0
  fi

  case "$raw" in
    sequence|sequence-or-interval)
      contains_token "$query_lc" "sequence" || contains_token "$query_lc" "interval" || contains_token "$query_lc" "fasta" || contains_token "$query_lc" "chr"
      return
      ;;
    embedding-target)
      contains_token "$query_lc" "embedding" || contains_token "$query_lc" "token" || contains_token "$query_lc" "pooled" || contains_token "$query_lc" "representation"
      return
      ;;
    assembly)
      contains_token "$query_lc" "assembly" || contains_token "$query_lc" "hg38" || contains_token "$query_lc" "hg19" || contains_token "$query_lc" "mm10" || contains_token "$query_lc" "chm13"
      return
      ;;
    chrom|chromosome)
      contains_token "$query_lc" "chr"
      return
      ;;
    coordinate-or-interval|interval-or-variant)
      contains_token "$query_lc" "position" || contains_token "$query_lc" "variant" || contains_token "$query_lc" "interval" || contains_token "$query_lc" "chr"
      return
      ;;
    ref-alt-or-variant-spec)
      contains_token "$query_lc" "ref" || contains_token "$query_lc" "alt" || contains_token "$query_lc" "a>" || contains_token "$query_lc" "g>" || contains_token "$query_lc" "variant" || contains_token "$query_lc" "mutation" || contains_token "$query_lc" "突变" || contains_token "$query_lc" "变为"
      return
      ;;
    hardware-context)
      contains_token "$query_lc" "gpu" || contains_token "$query_lc" "cuda" || contains_token "$query_lc" "nvidia" || contains_token "$query_lc" "h100" || contains_token "$query_lc" "cpu" || contains_token "$query_lc" "mac"
      return
      ;;
    execution-path)
      contains_token "$query_lc" "local" || contains_token "$query_lc" "hosted" || contains_token "$query_lc" "api" || contains_token "$query_lc" "nim" || contains_token "$query_lc" "docker"
      return
      ;;
    runtime-context)
      contains_token "$query_lc" "linux" || contains_token "$query_lc" "mac" || contains_token "$query_lc" "wsl" || contains_token "$query_lc" "windows" || contains_token "$query_lc" "docker" || contains_token "$query_lc" "conda"
      return
      ;;
    target-stack-or-model-family)
      contains_token "$query_lc" "stack" || contains_token "$query_lc" "model" || contains_token "$query_lc" "family" || contains_token "$query_lc" "ntv3" || contains_token "$query_lc" "evo2" || contains_token "$query_lc" "gpn" || contains_token "$query_lc" "alphagenome"
      return
      ;;
    task-objective|objective|model-family-objective)
      contains_token "$query_lc" "classification" || contains_token "$query_lc" "regression" || contains_token "$query_lc" "objective" || contains_token "$query_lc" "variant" || contains_token "$query_lc" "embedding" || contains_token "$query_lc" "prediction"
      return
      ;;
    dataset-schema)
      contains_token "$query_lc" "csv" || contains_token "$query_lc" "schema" || contains_token "$query_lc" "columns" || contains_token "$query_lc" "label" || contains_token "$query_lc" "fasta"
      return
      ;;
    compute-constraints)
      contains_token "$query_lc" "gpu" || contains_token "$query_lc" "memory" || contains_token "$query_lc" "runtime" || contains_token "$query_lc" "budget" || contains_token "$query_lc" "batch"
      return
      ;;
    failing-step-or-error)
      contains_token "$query_lc" "error" || contains_token "$query_lc" "fail" || contains_token "$query_lc" "issue" || contains_token "$query_lc" "traceback" || contains_token "$query_lc" "loading" || contains_token "$query_lc" "cannot"
      return
      ;;
    output-head)
      has_track_head_intent "$query_lc"
      return
      ;;
    species)
      contains_token "$query_lc" "human" || contains_token "$query_lc" "mouse" || contains_token "$query_lc" "species"
      return
      ;;
  esac

  for token in $phrase; do
    [[ ${#token} -lt 4 ]] && continue
    token_need=$((token_need + 1))
    if contains_token "$query_lc" "$token"; then
      token_hits=$((token_hits + 1))
    fi
  done

  if [[ "$token_need" -eq 0 ]]; then
    return 1
  fi
  if [[ "$token_hits" -ge "$token_need" ]]; then
    return 0
  fi
  return 1
}

input_satisfied() {
  local input_name="$1"
  local query_lc="$2"
  local skill_meta="$3"
  local schema_file="$4"
  local canonical_key=""
  local phrase=""
  local token=""
  local token_lc=""

  canonical_key="$(input_schema_resolve_key "$schema_file" "$input_name" || true)"
  if [[ -z "$canonical_key" ]]; then
    canonical_key="$input_name"
  fi

  for phrase in "$input_name" "$canonical_key"; do
    [[ -z "$phrase" ]] && continue
    phrase="$(to_lower "$phrase")"
    phrase="${phrase//-/ }"
    phrase="${phrase//_/ }"
    if contains_token "$query_lc" "$phrase"; then
      return 0
    fi
  done

  while IFS= read -r token; do
    [[ -z "$token" ]] && continue
    token_lc="$(to_lower "$token")"
    if contains_token "$query_lc" "$token_lc"; then
      return 0
    fi
  done < <(input_schema_list_query_tokens "$schema_file" "$canonical_key")

  if [[ -f "$skill_meta" ]]; then
    while IFS= read -r token; do
      [[ -z "$token" ]] && continue
      token_lc="$(to_lower "$token")"
      if contains_token "$query_lc" "$token_lc"; then
        return 0
      fi
    done < <(skill_meta_list_query_tokens "$skill_meta" "$canonical_key")
  fi

  if [[ "$canonical_key" == "output-head" ]]; then
    if has_track_head_intent "$query_lc"; then
      return 0
    fi
  fi

  if input_satisfied_legacy "$canonical_key" "$query_lc"; then
    return 0
  fi
  if [[ "$canonical_key" != "$input_name" ]]; then
    if input_satisfied_legacy "$input_name" "$query_lc"; then
      return 0
    fi
  fi

  return 1
}

query=""
task=""
top_k=3
format="text"
registry_file="$DEFAULT_REGISTRY_FILE"
tags_file="$DEFAULT_TAGS_FILE"
routing_file="$DEFAULT_ROUTING_FILE"
contracts_file="$DEFAULT_CONTRACTS_FILE"
output_contracts_file="$DEFAULT_OUTPUT_CONTRACTS_FILE"
recovery_policies_file="$DEFAULT_RECOVERY_POLICIES_FILE"
input_schema_file="$DEFAULT_INPUT_SCHEMA_FILE"
router_script="$DEFAULT_ROUTER_SCRIPT"
include_disabled=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query)
      query="$2"
      shift 2
      ;;
    --task)
      task="$2"
      shift 2
      ;;
    --top-k)
      top_k="$2"
      shift 2
      ;;
    --format)
      format="$2"
      shift 2
      ;;
    --registry)
      registry_file="$2"
      shift 2
      ;;
    --tags)
      tags_file="$2"
      shift 2
      ;;
    --routing-config)
      routing_file="$2"
      shift 2
      ;;
    --contracts)
      contracts_file="$2"
      shift 2
      ;;
    --output-contracts)
      output_contracts_file="$2"
      shift 2
      ;;
    --recovery)
      recovery_policies_file="$2"
      shift 2
      ;;
    --input-schema)
      input_schema_file="$2"
      shift 2
      ;;
    --router)
      router_script="$2"
      shift 2
      ;;
    --include-disabled)
      include_disabled=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unexpected argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$query" && ! -t 0 ]]; then
  query="$(cat)"
fi
query="$(normalize_text "$query")"

if [[ -z "$query" ]]; then
  echo "error: query is required (use --query or stdin)." >&2
  exit 1
fi

if [[ ! "$top_k" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: --top-k must be a positive integer." >&2
  exit 1
fi

if [[ "$format" != "text" && "$format" != "json" ]]; then
  echo "error: --format must be 'text' or 'json'." >&2
  exit 1
fi

registry_require_file "$registry_file"
registry_require_file "$tags_file"
registry_require_file "$routing_file"
registry_require_file "$contracts_file"
registry_require_file "$output_contracts_file"
registry_require_file "$recovery_policies_file"
registry_require_file "$input_schema_file"
if [[ ! -f "$router_script" ]]; then
  echo "error: router script not found: $router_script" >&2
  exit 1
fi

router_json=""
router_cmd=(bash "$router_script" --registry "$registry_file" --tags "$tags_file" --routing-config "$routing_file" --query "$query" --top-k "$top_k" --format json)
if [[ -n "$task" ]]; then
  router_cmd+=(--task "$task")
fi
if [[ "$include_disabled" -eq 1 ]]; then
  router_cmd+=(--include-disabled)
fi

if ! router_json="$("${router_cmd[@]}" 2>&1)"; then
  echo "error: routing failed: $router_json" >&2
  exit 1
fi

decision="$(extract_decision_from_json "$router_json")"
effective_task="$(extract_task_from_json "$router_json")"
task_source="$(extract_task_source_from_json "$router_json")"
confidence_level="$(extract_confidence_level_from_json "$router_json")"
confidence_score="$(extract_confidence_score_from_json "$router_json")"
clarify_question="$(extract_clarify_question_from_json "$router_json")"

if [[ -z "$decision" ]]; then
  echo "error: failed to parse routing decision from router output: $router_json" >&2
  exit 1
fi

if [[ "$decision" == "clarify" ]]; then
  if [[ "$format" == "text" ]]; then
    echo "query: $query"
    if [[ -n "$effective_task" ]]; then
      echo "task: $effective_task ($task_source)"
    else
      echo "task: none ($task_source)"
    fi
    echo "decision: clarify"
    echo "confidence: ${confidence_level:-unknown} (${confidence_score:-0})"
    echo "clarify_question: ${clarify_question:-Please specify task or preferred skill.}"
    echo "plan: none"
    exit 0
  fi

  printf '{'
  printf '"query":"%s",' "$(json_escape "$query")"
  if [[ -n "$effective_task" ]]; then
    printf '"task":"%s",' "$(json_escape "$effective_task")"
  else
    printf '"task":null,'
  fi
  printf '"task_source":"%s",' "$(json_escape "$task_source")"
  printf '"decision":"clarify",'
  printf '"confidence":{'
  printf '"level":"%s",' "$(json_escape "$confidence_level")"
  printf '"score":%s' "${confidence_score:-0}"
  printf '},'
  if [[ -n "$clarify_question" ]]; then
    printf '"clarify_question":"%s",' "$(json_escape "$clarify_question")"
  else
    printf '"clarify_question":"%s",' "Please specify task or preferred skill."
  fi
  printf '"playbook":null,'
  printf '"primary_skill":null,'
  printf '"primary_skill_path":null,'
  printf '"skill_doc":null,'
  printf '"skill_metadata":null,'
  printf '"secondary_skills":[],'
  printf '"required_inputs":[],'
  printf '"required_inputs_canonical":[],'
  printf '"required_inputs_source":null,'
  printf '"provided_inputs":[],'
  printf '"provided_inputs_canonical":[],'
  printf '"missing_inputs":[],'
  printf '"missing_inputs_canonical":[],'
  printf '"constraints":[],'
  printf '"tools":[],'
  printf '"plan":null,'
  printf '"next_prompt":"%s"' "$(json_escape "Ask one focused clarification question before selecting a skill.")"
  printf '}\n'
  exit 0
fi

primary_skill="$(extract_primary_skill_from_json "$router_json")"
secondary_csv="$(extract_secondary_csv_from_json "$router_json")"

if [[ -z "$primary_skill" ]]; then
  echo "error: failed to resolve primary skill from router output: $router_json" >&2
  exit 1
fi

skill_path="$(registry_get_path "$registry_file" "$primary_skill" || true)"
if [[ -z "$skill_path" ]]; then
  skill_path="$primary_skill"
fi
skill_root="$REPO_ROOT/$skill_path"
skill_meta="$skill_root/skill.yaml"
skill_doc="$skill_root/SKILL.md"

skill_required_csv=""
required_csv=""
required_canonical_csv=""
required_inputs_source="skill"
constraints_csv=""
tools_csv=""

while IFS= read -r v; do
  [[ -n "$v" ]] && skill_required_csv="$(append_csv "$skill_required_csv" "$v")"
done < <(yaml_get_list_field "$skill_meta" "required_inputs")

required_csv="$skill_required_csv"
required_canonical_csv="$(canonicalize_csv "$skill_required_csv" "$input_schema_file")"
if [[ -n "$effective_task" ]]; then
  task_required_csv=""
  task_required_canonical_csv=""
  while IFS= read -r v; do
    [[ -n "$v" ]] && task_required_csv="$(append_csv "$task_required_csv" "$v")"
  done < <(task_contract_list_required_inputs "$contracts_file" "$effective_task")
  while IFS= read -r v; do
    [[ -n "$v" ]] && task_required_canonical_csv="$(append_csv "$task_required_canonical_csv" "$v")"
  done < <(task_contract_list_canonical_required_inputs "$contracts_file" "$effective_task")

  if [[ -n "$task_required_csv" ]]; then
    required_csv="$task_required_csv"
    required_inputs_source="task-contract:$effective_task"
  else
    required_inputs_source="skill:$primary_skill"
  fi

  if [[ -n "$task_required_canonical_csv" ]]; then
    required_canonical_csv="$task_required_canonical_csv"
  else
    required_canonical_csv="$(canonicalize_csv "$required_csv" "$input_schema_file")"
  fi
else
  required_inputs_source="skill:$primary_skill"
fi

while IFS= read -r v; do
  [[ -n "$v" ]] && constraints_csv="$(append_csv "$constraints_csv" "$v")"
done < <(yaml_get_list_field "$skill_meta" "constraints")

while IFS= read -r v; do
  [[ -n "$v" ]] && tools_csv="$(append_csv "$tools_csv" "$v")"
done < <(yaml_get_list_field "$skill_meta" "tools")

plan_assumptions_csv=""
plan_steps_csv=""
plan_expected_outputs_csv=""
plan_fallbacks_csv=""
plan_retry_policy=""

if [[ -n "$effective_task" ]]; then
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    rendered="$(render_plan_value "$v" "$effective_task" "$primary_skill")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "$rendered")"
  done < <(output_contract_list_field "$output_contracts_file" "$effective_task" "assumptions")

  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    rendered="$(render_plan_value "$v" "$effective_task" "$primary_skill")"
    plan_steps_csv="$(append_csv "$plan_steps_csv" "$rendered")"
  done < <(output_contract_list_field "$output_contracts_file" "$effective_task" "runnable_steps")

  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    rendered="$(render_plan_value "$v" "$effective_task" "$primary_skill")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "$rendered")"
  done < <(output_contract_list_field "$output_contracts_file" "$effective_task" "expected_outputs")

  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    rendered="$(render_plan_value "$v" "$effective_task" "$primary_skill")"
    plan_fallbacks_csv="$(append_csv "$plan_fallbacks_csv" "$rendered")"
  done < <(output_contract_list_field "$output_contracts_file" "$effective_task" "fallbacks")

  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    if [[ "$sid" == "$primary_skill" ]]; then
      continue
    fi
    plan_fallbacks_csv="$(append_csv "$plan_fallbacks_csv" "$sid")"
  done < <(recovery_policy_list_fallback_skills "$recovery_policies_file" "$effective_task")

  plan_retry_policy="$(recovery_policy_get_retry_policy "$recovery_policies_file" "$effective_task" || true)"
  if [[ -z "$plan_retry_policy" ]]; then
    plan_retry_policy="$(output_contract_get_scalar "$output_contracts_file" "$effective_task" "retry_policy" || true)"
  fi
fi

if [[ -z "$plan_retry_policy" ]]; then
  plan_retry_policy="single-pass-no-retry"
fi

query_lc="$(to_lower "$query")"
track_run_id=""
track_output_root=""
track_explicit_skills_csv=""
track_explicit_skill_count=0
track_bed_query_path=""
track_bed_resolved=""
track_bed_source=""
track_bed_error=""

if [[ "$effective_task" == "track-prediction" ]]; then
  track_run_id="$(compute_track_run_id "$query")"
  track_output_root="$(compute_track_output_root "$query" "$track_run_id")"
  track_explicit_skills_csv="$(extract_track_explicit_skills_from_query "$query_lc")"
  if track_query_mentions_all_skills "$query_lc"; then
    track_explicit_skills_csv="alphagenome-api,nucleotide-transformer-v3,borzoi-workflows,segment-nt"
  fi
  track_explicit_skill_count="$(csv_count "$track_explicit_skills_csv")"
  track_bed_query_path="$(extract_ntv3_bed_path_from_query "$query")"
  if [[ -n "$track_bed_query_path" ]]; then
    IFS='|' read -r track_bed_resolved track_bed_source track_bed_error < <(resolve_track_bed_path "$track_bed_query_path")
  fi
fi

provided_csv=""
missing_csv=""
provided_canonical_csv=""
missing_canonical_csv=""
for req in $(printf '%s\n' "$required_csv" | tr ',' ' '); do
  [[ -z "$req" ]] && continue
  req_canonical="$(input_schema_resolve_key "$input_schema_file" "$req" || true)"
  if [[ -z "$req_canonical" ]]; then
    req_canonical="$req"
  fi
  if input_satisfied "$req" "$query_lc" "$skill_meta" "$input_schema_file"; then
    provided_csv="$(append_csv "$provided_csv" "$req")"
    provided_canonical_csv="$(append_csv "$provided_canonical_csv" "$req_canonical")"
  else
    missing_csv="$(append_csv "$missing_csv" "$req")"
    missing_canonical_csv="$(append_csv "$missing_canonical_csv" "$req_canonical")"
  fi
done

if [[ "$effective_task" == "track-prediction" && "$primary_skill" == "nucleotide-transformer-v3" ]]; then
  if has_track_head_intent "$query_lc" && in_csv_list "output-head" "$missing_csv"; then
    missing_csv="$(remove_csv_item "$missing_csv" "output-head")"
    provided_csv="$(append_csv "$provided_csv" "output-head")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "output-head-inferred-from-track-intent")"
  fi
fi

if [[ -n "$missing_csv" ]]; then
  while IFS= read -r req; do
    [[ -z "$req" ]] && continue
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "missing-input-needs-clarification:$req")"
  done < <(printf '%s\n' "$missing_csv" | tr ',' '\n')
fi

if [[ -z "$plan_assumptions_csv" ]]; then
  plan_assumptions_csv="follow-task-contract-and-skill-constraints"
fi

if [[ "$effective_task" == "track-prediction" && "$primary_skill" == "nucleotide-transformer-v3" ]]; then
  ntv3_missing_non_head="$(remove_csv_item "$missing_csv" "output-head")"
  ntv3_interval_csv="$(extract_ntv3_interval_from_query "$query_lc")"
  ntv3_bed_path="$track_bed_query_path"
  ntv3_bed_resolved="$track_bed_resolved"
  ntv3_species="$(extract_ntv3_species_from_query "$query_lc")"
  ntv3_assembly="$(extract_ntv3_assembly_from_query "$query_lc")"
  ntv3_output_dir="$(extract_ntv3_output_dir_from_query "$query")"
  ntv3_model="InstaDeepAI/NTv3_100M_post"
  ntv3_chrom=""
  ntv3_start=""
  ntv3_end=""
  ntv3_prefix=""
  ntv3_plot_path=""
  ntv3_result_path=""
  ntv3_log_path=""
  ntv3_batch_summary_path=""
  ntv3_batch_log_path=""
  ntv3_step_cmd=""
  ntv3_fallback_cmd=""

  if [[ -z "$ntv3_output_dir" ]]; then
    ntv3_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "nucleotide-transformer-v3")"
  fi

  if [[ -n "$ntv3_bed_path" ]]; then
    if [[ -n "$ntv3_bed_resolved" ]]; then
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
        plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-bed-path")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "bed-path-resolution:${track_bed_source}")"
      ntv3_missing_non_head="$(remove_csv_item "$missing_csv" "output-head")"
    else
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "${track_bed_error}")"
    fi
  fi

  if [[ -n "$ntv3_interval_csv" ]]; then
    IFS=',' read -r ntv3_chrom ntv3_start ntv3_end <<<"$ntv3_interval_csv"
    if in_csv_list "sequence-or-interval" "$missing_csv"; then
      missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
      provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-interval-token")"
    fi
    if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
      missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
      provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
    fi
  fi

  if [[ -n "$ntv3_species" && -n "$ntv3_assembly" && -n "$ntv3_bed_resolved" && -z "$ntv3_missing_non_head" ]]; then
    ntv3_batch_summary_path="${ntv3_output_dir}/ntv3_bed_batch_summary.json"
    ntv3_batch_log_path="${ntv3_output_dir}/ntv3_bed_batch.log"
    ntv3_step_cmd="TRACK_PREDICTION_RUN_ID=${track_run_id} NTV3_TRACK_BED_PATH=${ntv3_bed_resolved} NTV3_TRACK_OUTPUT_DIR=${ntv3_output_dir} NTV3_SPECIES=${ntv3_species} NTV3_ASSEMBLY=${ntv3_assembly} bash case-study-playbooks/track_prediction/run_ntv3_track_case.sh"

    plan_steps_csv="$ntv3_step_cmd"
    plan_expected_outputs_csv=""
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_batch_summary_path}")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_batch_log_path}")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${ntv3_output_dir}/ntv3_*_trackplot.png")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_output_dir}/ntv3_*_result.json")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_output_dir}/ntv3_*.log")"

    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "ntv3-track-bed-batch-fastpath-enabled")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "partial-failures-recorded-in-summary")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-model:${ntv3_model}")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-output-dir:${ntv3_output_dir}")"
  elif [[ -n "$ntv3_species" && -n "$ntv3_assembly" && -n "$ntv3_chrom" && -n "$ntv3_start" && -n "$ntv3_end" && -z "$ntv3_missing_non_head" ]]; then
    if [[ "$ntv3_end" =~ ^[0-9]+$ && "$ntv3_start" =~ ^[0-9]+$ && "$ntv3_end" -gt "$ntv3_start" ]]; then
      ntv3_prefix="ntv3_${ntv3_species}_${ntv3_assembly}_${ntv3_chrom}_${ntv3_start}_${ntv3_end}"
      ntv3_plot_path="${ntv3_output_dir}/${ntv3_prefix}_trackplot.png"
      ntv3_result_path="${ntv3_output_dir}/${ntv3_prefix}_result.json"
      ntv3_log_path="${ntv3_output_dir}/ntv3_run.log"

      ntv3_step_cmd="set -a; source .env; set +a; mkdir -p ${ntv3_output_dir}; conda run -n ntv3 python skills/nucleotide-transformer-v3/scripts/run_track_prediction.py --model ${ntv3_model} --species ${ntv3_species} --assembly ${ntv3_assembly} --interval ${ntv3_chrom}:${ntv3_start}-${ntv3_end} --output-dir ${ntv3_output_dir} 2>&1 | tee ${ntv3_log_path}"
      ntv3_fallback_cmd="set -a; source .env; set +a; mkdir -p ${ntv3_output_dir}; conda run -n ntv3 python skills/nucleotide-transformer-v3/scripts/run_track_prediction.py --model ${ntv3_model} --species ${ntv3_species} --assembly ${ntv3_assembly} --interval ${ntv3_chrom}:${ntv3_start}-${ntv3_end} --output-dir ${ntv3_output_dir} --disable-xet 2>&1 | tee ${ntv3_log_path}"

      plan_steps_csv="$ntv3_step_cmd"
      plan_expected_outputs_csv=""
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${ntv3_plot_path}")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_result_path}")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_log_path}")"
      plan_fallbacks_csv="$(append_csv "$plan_fallbacks_csv" "$ntv3_fallback_cmd")"

      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "ntv3-track-fastpath-enabled")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-model:${ntv3_model}")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-output-dir:${ntv3_output_dir}")"
    fi
  fi
fi

if [[ "$effective_task" == "track-prediction" && "$primary_skill" == "alphagenome-api" ]]; then
  ag_track_missing_non_head="$(remove_csv_item "$missing_csv" "output-head")"
  ag_track_missing_non_head="$(remove_csv_item "$ag_track_missing_non_head" "species")"
  ag_track_interval_csv="$(extract_alphagenome_track_interval_from_query "$query_lc")"
  ag_track_bed_path="$track_bed_query_path"
  ag_track_bed_resolved="$track_bed_resolved"
  ag_track_species="$(extract_alphagenome_track_species_from_query "$query_lc")"
  ag_track_assembly="$(extract_alphagenome_assembly_from_query "$query_lc")"
  ag_track_head="$(extract_alphagenome_track_head_from_query "$query_lc")"
  ag_track_ontology="$(extract_alphagenome_ontology_term_from_query "$query")"
  ag_track_output_dir="$(extract_alphagenome_track_output_dir_from_query "$query")"
  ag_env_name="$(extract_alphagenome_env_from_query "$query")"
  ag_env_prefix="$(resolve_conda_env_prefix "$ag_env_name")"
  ag_conda_cmd=""
  ag_track_chrom=""
  ag_track_start=""
  ag_track_end=""
  ag_track_log_path=""
  ag_track_summary_path=""
  ag_track_step_cmd=""
  ag_track_fallback_cmd=""
  ag_track_prefix="alphagenome_track"

  if [[ -z "$ag_track_output_dir" ]]; then
    ag_track_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "alphagenome-api")"
  fi

  if [[ -z "$ag_track_species" ]]; then
    ag_track_species="human"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-species:human")"
  fi
  if in_csv_list "species" "$missing_csv"; then
    missing_csv="$(remove_csv_item "$missing_csv" "species")"
    provided_csv="$(append_csv "$provided_csv" "species")"
  fi
  if in_csv_list "species" "$missing_canonical_csv"; then
    missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "species")"
    provided_canonical_csv="$(append_csv "$provided_canonical_csv" "species")"
  fi

  if [[ -z "$ag_track_head" ]]; then
    ag_track_head="RNA_SEQ"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-output-head:RNA_SEQ")"
  fi
  if in_csv_list "output-head" "$missing_csv"; then
    missing_csv="$(remove_csv_item "$missing_csv" "output-head")"
    provided_csv="$(append_csv "$provided_csv" "output-head")"
  fi
  if in_csv_list "output-head" "$missing_canonical_csv"; then
    missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "output-head")"
    provided_canonical_csv="$(append_csv "$provided_canonical_csv" "output-head")"
  fi

  if [[ -z "$ag_track_ontology" ]]; then
    ag_track_ontology="UBERON:0001157"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-ontology-term:UBERON:0001157")"
  fi

  if [[ -n "$ag_track_bed_path" ]]; then
    if [[ -n "$ag_track_bed_resolved" ]]; then
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
        plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-bed-path")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "bed-path-resolution:${track_bed_source}")"
    else
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "${track_bed_error}")"
    fi
  elif [[ -n "$ag_track_interval_csv" ]]; then
    IFS=',' read -r ag_track_chrom ag_track_start ag_track_end <<<"$ag_track_interval_csv"
    if [[ -n "$ag_track_chrom" && -n "$ag_track_start" && -n "$ag_track_end" ]]; then
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
        plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-interval-token")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
    fi
  fi

  if [[ -n "$ag_env_prefix" ]]; then
    ag_conda_cmd="conda run -p ${ag_env_prefix}"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-auto-resolved:prefix")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-prefix:${ag_env_prefix}")"
  else
    ag_conda_cmd="conda run -n ${ag_env_name}"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-auto-resolved:name")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-name:${ag_env_name}")"
  fi

  ag_track_missing_non_head="$(remove_csv_item "$missing_csv" "output-head")"
  ag_track_missing_non_head="$(remove_csv_item "$ag_track_missing_non_head" "species")"

  ag_track_log_path="${ag_track_output_dir}/alphagenome_track_prediction.log"
  ag_track_summary_path="${ag_track_output_dir}/${ag_track_prefix}_bed_batch_summary.json"

  if [[ -n "$ag_track_assembly" && -n "$ag_track_bed_resolved" && -z "$ag_track_missing_non_head" ]]; then
    ag_track_step_cmd="set -a; source .env; set +a; mkdir -p ${ag_track_output_dir}; ${ag_conda_cmd} python skills/alphagenome-api/scripts/run_alphagenome_track_prediction_bed_batch.py --bed ${ag_track_bed_resolved} --species ${ag_track_species} --assembly ${ag_track_assembly} --output-head ${ag_track_head} --ontology-term ${ag_track_ontology} --output-dir ${ag_track_output_dir} --output-prefix ${ag_track_prefix} 2>&1 | tee ${ag_track_log_path}"
    ag_track_fallback_cmd="set -a; source .env; set +a; mkdir -p ${ag_track_output_dir}; grpc_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 ${ag_conda_cmd} python skills/alphagenome-api/scripts/run_alphagenome_track_prediction_bed_batch.py --bed ${ag_track_bed_resolved} --species ${ag_track_species} --assembly ${ag_track_assembly} --output-head ${ag_track_head} --ontology-term ${ag_track_ontology} --output-dir ${ag_track_output_dir} --output-prefix ${ag_track_prefix} --request-timeout-sec 120 2>&1 | tee ${ag_track_log_path}"

    plan_steps_csv="$ag_track_step_cmd"
    plan_expected_outputs_csv=""
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_summary_path}")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${ag_track_output_dir}/${ag_track_prefix}_*_trackplot.png")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_output_dir}/${ag_track_prefix}_*_result.json")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_output_dir}/${ag_track_prefix}_*_track_prediction.npz")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_log_path}")"
    plan_fallbacks_csv="$(append_csv "$plan_fallbacks_csv" "$ag_track_fallback_cmd")"

    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "alphagenome-track-bed-batch-fastpath-enabled")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "track-interval-coordinate-convention-0based-half-open")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "inference-window-auto-expanded-to-supported-width")"
  elif [[ -n "$ag_track_assembly" && -n "$ag_track_chrom" && -n "$ag_track_start" && -n "$ag_track_end" && -z "$ag_track_missing_non_head" ]]; then
    if [[ "$ag_track_end" =~ ^[0-9]+$ && "$ag_track_start" =~ ^[0-9]+$ && "$ag_track_end" -gt "$ag_track_start" ]]; then
      ag_track_step_cmd="set -a; source .env; set +a; mkdir -p ${ag_track_output_dir}; ${ag_conda_cmd} python skills/alphagenome-api/scripts/run_alphagenome_track_prediction_bed_batch.py --interval ${ag_track_chrom}:${ag_track_start}-${ag_track_end} --species ${ag_track_species} --assembly ${ag_track_assembly} --output-head ${ag_track_head} --ontology-term ${ag_track_ontology} --output-dir ${ag_track_output_dir} --output-prefix ${ag_track_prefix} 2>&1 | tee ${ag_track_log_path}"
      ag_track_fallback_cmd="set -a; source .env; set +a; mkdir -p ${ag_track_output_dir}; grpc_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 ${ag_conda_cmd} python skills/alphagenome-api/scripts/run_alphagenome_track_prediction_bed_batch.py --interval ${ag_track_chrom}:${ag_track_start}-${ag_track_end} --species ${ag_track_species} --assembly ${ag_track_assembly} --output-head ${ag_track_head} --ontology-term ${ag_track_ontology} --output-dir ${ag_track_output_dir} --output-prefix ${ag_track_prefix} --request-timeout-sec 120 2>&1 | tee ${ag_track_log_path}"

      plan_steps_csv="$ag_track_step_cmd"
      plan_expected_outputs_csv=""
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_summary_path}")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${ag_track_output_dir}/${ag_track_prefix}_${ag_track_chrom}_${ag_track_start}_${ag_track_end}_trackplot.png")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_output_dir}/${ag_track_prefix}_${ag_track_chrom}_${ag_track_start}_${ag_track_end}_result.json")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_output_dir}/${ag_track_prefix}_${ag_track_chrom}_${ag_track_start}_${ag_track_end}_track_prediction.npz")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_track_log_path}")"
      plan_fallbacks_csv="$(append_csv "$plan_fallbacks_csv" "$ag_track_fallback_cmd")"

      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "alphagenome-track-single-interval-fastpath-enabled")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "track-interval-coordinate-convention-0based-half-open")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "inference-window-auto-expanded-to-supported-width")"
    fi
  fi
fi

if [[ "$effective_task" == "track-prediction" && "$primary_skill" == "borzoi-workflows" ]]; then
  bz_missing_non_head="$(remove_csv_item "$missing_csv" "output-head")"
  bz_interval_csv="$(extract_ntv3_interval_from_query "$query_lc")"
  bz_bed_path="$track_bed_query_path"
  bz_bed_resolved="$track_bed_resolved"
  bz_species="$(extract_ntv3_species_from_query "$query_lc")"
  bz_assembly="$(extract_ntv3_assembly_from_query "$query_lc")"
  bz_output_dir="$(extract_borzoi_track_output_dir_from_query "$query")"
  bz_step_cmd=""
  bz_summary_path=""
  bz_run_bed=""
  bz_prepare_cmd=""
  bz_chrom=""
  bz_start=""
  bz_end=""

  if [[ -z "$bz_output_dir" ]]; then
    bz_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "borzoi-workflows")"
  fi

  if [[ -z "$bz_species" ]]; then
    bz_species="human"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-species:human")"
  fi
  if in_csv_list "species" "$missing_csv"; then
    missing_csv="$(remove_csv_item "$missing_csv" "species")"
    provided_csv="$(append_csv "$provided_csv" "species")"
  fi
  if in_csv_list "species" "$missing_canonical_csv"; then
    missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "species")"
    provided_canonical_csv="$(append_csv "$provided_canonical_csv" "species")"
  fi

  if [[ -n "$bz_bed_path" ]]; then
    if [[ -n "$bz_bed_resolved" ]]; then
      bz_run_bed="$bz_bed_resolved"
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
        plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-bed-path")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "bed-path-resolution:${track_bed_source}")"
    else
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "${track_bed_error}")"
    fi
  elif [[ -n "$bz_interval_csv" ]]; then
    IFS=',' read -r bz_chrom bz_start bz_end <<<"$bz_interval_csv"
    if [[ -n "$bz_chrom" && -n "$bz_start" && -n "$bz_end" ]]; then
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
        plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-interval-token")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
      bz_run_bed="${track_output_root}/borzoi_single_interval.bed"
      bz_prepare_cmd="mkdir -p ${track_output_root}; printf '%s\t%s\t%s\n' ${bz_chrom} ${bz_start} ${bz_end} > ${bz_run_bed}; "
    fi
  fi

  bz_missing_non_head="$(remove_csv_item "$bz_missing_non_head" "species")"
  if [[ -n "$bz_assembly" && -n "$bz_run_bed" && -z "$bz_missing_non_head" ]]; then
    bz_summary_path="${bz_output_dir}/borzoi_bed_batch_summary.json"
    bz_step_cmd="${bz_prepare_cmd}TRACK_PREDICTION_RUN_ID=${track_run_id} BORZOI_TRACK_BED_PATH=${bz_run_bed} BORZOI_TRACK_OUTPUT_DIR=${bz_output_dir} BORZOI_TRACK_ASSEMBLY=${bz_assembly} BORZOI_TRACK_CONTINUE_ON_ERROR=1 bash case-study-playbooks/track_prediction/run_borzoi_track_case.sh"

    plan_steps_csv="$bz_step_cmd"
    plan_expected_outputs_csv=""
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${bz_summary_path}")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${bz_output_dir}/borzoi_track_*_trackplot.png")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${bz_output_dir}/borzoi_track_*_result.json")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${bz_output_dir}/borzoi_track_*_track_prediction.npz")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${bz_output_dir}/borzoi_track_*_top_tracks.tsv")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${bz_output_dir}/borzoi_*.log")"

    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "borzoi-track-bed-batch-fastpath-enabled")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-output-dir:${bz_output_dir}")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "per-interval-ucsc-network-retry-once")"
  fi
fi

if [[ "$effective_task" == "track-prediction" && "$primary_skill" == "segment-nt" ]]; then
  sg_missing_non_head="$(remove_csv_item "$missing_csv" "output-head")"
  sg_interval_csv="$(extract_ntv3_interval_from_query "$query_lc")"
  sg_bed_path="$track_bed_query_path"
  sg_bed_resolved="$track_bed_resolved"
  sg_species="$(extract_ntv3_species_from_query "$query_lc")"
  sg_assembly="$(extract_ntv3_assembly_from_query "$query_lc")"
  sg_output_dir="$(extract_segmentnt_track_output_dir_from_query "$query")"
  sg_step_cmd=""
  sg_summary_path=""
  sg_run_bed=""
  sg_prepare_cmd=""
  sg_chrom=""
  sg_start=""
  sg_end=""

  if [[ -z "$sg_output_dir" ]]; then
    sg_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "segment-nt")"
  fi

  if [[ -z "$sg_species" ]]; then
    sg_species="human"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-species:human")"
  fi
  if in_csv_list "species" "$missing_csv"; then
    missing_csv="$(remove_csv_item "$missing_csv" "species")"
    provided_csv="$(append_csv "$provided_csv" "species")"
  fi
  if in_csv_list "species" "$missing_canonical_csv"; then
    missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "species")"
    provided_canonical_csv="$(append_csv "$provided_canonical_csv" "species")"
  fi

  if [[ -n "$sg_bed_path" ]]; then
    if [[ -n "$sg_bed_resolved" ]]; then
      sg_run_bed="$sg_bed_resolved"
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
        plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-bed-path")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "bed-path-resolution:${track_bed_source}")"
    else
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "${track_bed_error}")"
    fi
  elif [[ -n "$sg_interval_csv" ]]; then
    IFS=',' read -r sg_chrom sg_start sg_end <<<"$sg_interval_csv"
    if [[ -n "$sg_chrom" && -n "$sg_start" && -n "$sg_end" ]]; then
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
        plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "sequence-or-interval-inferred-from-interval-token")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
      sg_run_bed="${track_output_root}/segmentnt_single_interval.bed"
      sg_prepare_cmd="mkdir -p ${track_output_root}; printf '%s\t%s\t%s\n' ${sg_chrom} ${sg_start} ${sg_end} > ${sg_run_bed}; "
    fi
  fi

  sg_missing_non_head="$(remove_csv_item "$sg_missing_non_head" "species")"
  if [[ -n "$sg_assembly" && -n "$sg_run_bed" && -z "$sg_missing_non_head" ]]; then
    sg_summary_path="${sg_output_dir}/segmentnt_bed_batch_summary.json"
    sg_step_cmd="${sg_prepare_cmd}TRACK_PREDICTION_RUN_ID=${track_run_id} SEGMENT_NT_BED_PATH=${sg_run_bed} SEGMENT_NT_OUTPUT_DIR=${sg_output_dir} SEGMENT_NT_SPECIES=${sg_species} SEGMENT_NT_ASSEMBLY=${sg_assembly} SEGMENT_NT_CONTINUE_ON_ERROR=1 bash case-study-playbooks/track_prediction/run_segment_nt_track_case.sh"

    plan_steps_csv="$sg_step_cmd"
    plan_expected_outputs_csv=""
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${sg_summary_path}")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${sg_output_dir}/segmentnt_*_trackplot.png")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${sg_output_dir}/segmentnt_*_result.json")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${sg_output_dir}/segmentnt_*_probs.npz")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${sg_output_dir}/segmentnt_*.log")"

    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "segmentnt-track-bed-batch-fastpath-enabled")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-output-dir:${sg_output_dir}")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "segmentnt-length-normalization-32768-to-32764-when-needed")"
  fi
fi

if [[ "$effective_task" == "track-prediction" && "$track_explicit_skill_count" -gt 1 ]]; then
  multi_skills_csv="$track_explicit_skills_csv"
  multi_missing_non_head="$(remove_csv_item "$missing_csv" "output-head")"
  multi_species="$(extract_ntv3_species_from_query "$query_lc")"
  multi_assembly="$(extract_ntv3_assembly_from_query "$query_lc")"
  multi_interval_csv="$(extract_ntv3_interval_from_query "$query_lc")"
  multi_bed_path="$track_bed_query_path"
  multi_bed_resolved="$track_bed_resolved"
  multi_run_bed=""
  multi_prepare_cmd=""
  multi_chrom=""
  multi_start=""
  multi_end=""
  multi_ag_head="$(extract_alphagenome_track_head_from_query "$query_lc")"
  multi_ag_ontology="$(extract_alphagenome_ontology_term_from_query "$query")"

  if [[ -z "$multi_species" ]]; then
    multi_species="human"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-species:human")"
  fi
  if in_csv_list "species" "$missing_csv"; then
    missing_csv="$(remove_csv_item "$missing_csv" "species")"
    provided_csv="$(append_csv "$provided_csv" "species")"
  fi
  if in_csv_list "species" "$missing_canonical_csv"; then
    missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "species")"
    provided_canonical_csv="$(append_csv "$provided_canonical_csv" "species")"
  fi
  multi_missing_non_head="$(remove_csv_item "$multi_missing_non_head" "species")"

  if [[ -z "$multi_ag_head" ]]; then
    multi_ag_head="RNA_SEQ"
  fi
  if [[ -z "$multi_ag_ontology" ]]; then
    multi_ag_ontology="UBERON:0001157"
  fi

  if [[ -n "$multi_bed_path" ]]; then
    if [[ -n "$multi_bed_resolved" ]]; then
      multi_run_bed="$multi_bed_resolved"
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "bed-path-resolution:${track_bed_source}")"
    else
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "${track_bed_error}")"
    fi
  elif [[ -n "$multi_interval_csv" ]]; then
    IFS=',' read -r multi_chrom multi_start multi_end <<<"$multi_interval_csv"
    if [[ -n "$multi_chrom" && -n "$multi_start" && -n "$multi_end" ]]; then
      multi_run_bed="${track_output_root}/track_prediction_multi_interval.bed"
      multi_prepare_cmd="mkdir -p ${track_output_root}; printf '%s\t%s\t%s\n' ${multi_chrom} ${multi_start} ${multi_end} > ${multi_run_bed}; "
      if in_csv_list "sequence-or-interval" "$missing_csv"; then
        missing_csv="$(remove_csv_item "$missing_csv" "sequence-or-interval")"
        provided_csv="$(append_csv "$provided_csv" "sequence-or-interval")"
      fi
      if in_csv_list "sequence-or-interval" "$missing_canonical_csv"; then
        missing_canonical_csv="$(remove_csv_item "$missing_canonical_csv" "sequence-or-interval")"
        provided_canonical_csv="$(append_csv "$provided_canonical_csv" "sequence-or-interval")"
      fi
    fi
  fi

  if [[ -n "$multi_run_bed" && -n "$multi_assembly" && -z "$multi_missing_non_head" ]]; then
    plan_steps_csv=""
    plan_expected_outputs_csv=""
    multi_ordered_skills=(alphagenome-api nucleotide-transformer-v3 borzoi-workflows segment-nt)
    for multi_skill in "${multi_ordered_skills[@]}"; do
      if ! in_csv_list "$multi_skill" "$multi_skills_csv"; then
        continue
      fi

      multi_output_dir=""
      multi_step=""
      multi_summary_file="$(track_skill_summary_file "$multi_skill")"
      case "$multi_skill" in
        alphagenome-api)
          multi_output_dir="$(extract_alphagenome_track_output_dir_from_query "$query")"
          [[ -z "$multi_output_dir" ]] && multi_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "$multi_skill")"
          multi_step="TRACK_PREDICTION_RUN_ID=${track_run_id} ALPHAGENOME_TRACK_BED_PATH=${multi_run_bed} ALPHAGENOME_TRACK_OUTPUT_DIR=${multi_output_dir} ALPHAGENOME_TRACK_ASSEMBLY=${multi_assembly} ALPHAGENOME_TRACK_OUTPUT_HEAD=${multi_ag_head} ALPHAGENOME_TRACK_ONTOLOGY_TERM=${multi_ag_ontology} bash case-study-playbooks/track_prediction/run_alphagenome_track_case.sh"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/${multi_summary_file}")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${multi_output_dir}/alphagenome_track_*_trackplot.png")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/alphagenome_track_*_result.json")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/alphagenome_track_*_track_prediction.npz")"
          ;;
        nucleotide-transformer-v3)
          multi_output_dir="$(extract_ntv3_output_dir_from_query "$query")"
          [[ -z "$multi_output_dir" ]] && multi_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "$multi_skill")"
          multi_step="TRACK_PREDICTION_RUN_ID=${track_run_id} NTV3_TRACK_BED_PATH=${multi_run_bed} NTV3_TRACK_OUTPUT_DIR=${multi_output_dir} NTV3_SPECIES=${multi_species} NTV3_ASSEMBLY=${multi_assembly} bash case-study-playbooks/track_prediction/run_ntv3_track_case.sh"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/${multi_summary_file}")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${multi_output_dir}/ntv3_*_trackplot.png")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/ntv3_*_result.json")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/ntv3_*.log")"
          ;;
        borzoi-workflows)
          multi_output_dir="$(extract_borzoi_track_output_dir_from_query "$query")"
          [[ -z "$multi_output_dir" ]] && multi_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "$multi_skill")"
          multi_step="TRACK_PREDICTION_RUN_ID=${track_run_id} BORZOI_TRACK_BED_PATH=${multi_run_bed} BORZOI_TRACK_OUTPUT_DIR=${multi_output_dir} BORZOI_TRACK_ASSEMBLY=${multi_assembly} BORZOI_TRACK_CONTINUE_ON_ERROR=1 bash case-study-playbooks/track_prediction/run_borzoi_track_case.sh"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/${multi_summary_file}")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${multi_output_dir}/borzoi_track_*_trackplot.png")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/borzoi_track_*_result.json")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/borzoi_track_*_track_prediction.npz")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/borzoi_track_*_top_tracks.tsv")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/borzoi_*.log")"
          ;;
        segment-nt)
          multi_output_dir="$(extract_segmentnt_track_output_dir_from_query "$query")"
          [[ -z "$multi_output_dir" ]] && multi_output_dir="$(default_track_output_dir_for_skill "$track_output_root" "$multi_skill")"
          multi_step="TRACK_PREDICTION_RUN_ID=${track_run_id} SEGMENT_NT_BED_PATH=${multi_run_bed} SEGMENT_NT_OUTPUT_DIR=${multi_output_dir} SEGMENT_NT_SPECIES=${multi_species} SEGMENT_NT_ASSEMBLY=${multi_assembly} SEGMENT_NT_CONTINUE_ON_ERROR=1 bash case-study-playbooks/track_prediction/run_segment_nt_track_case.sh"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/${multi_summary_file}")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${multi_output_dir}/segmentnt_*_trackplot.png")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/segmentnt_*_result.json")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/segmentnt_*_probs.npz")"
          plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${multi_output_dir}/segmentnt_*.log")"
          ;;
      esac

      if [[ -n "$multi_prepare_cmd" ]]; then
        multi_step="${multi_prepare_cmd}${multi_step}"
        multi_prepare_cmd=""
      fi
      plan_steps_csv="$(append_csv "$plan_steps_csv" "$multi_step")"
    done

    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "track-multi-skill-composite-plan-enabled")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "track-run-id:${track_run_id}")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "track-output-root:${track_output_root}")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "selected-track-skills:${multi_skills_csv}")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "batch-summary-plus-per-interval-artifacts-contract")"
  fi
fi

if [[ "$effective_task" == "variant-effect" && "$primary_skill" == "alphagenome-api" ]]; then
  ag_assembly="$(extract_alphagenome_assembly_from_query "$query_lc")"
  ag_variant_csv="$(extract_alphagenome_variant_from_query "$query")"
  ag_output_dir="$(extract_alphagenome_output_dir_from_query "$query")"
  ag_env_name="$(extract_alphagenome_env_from_query "$query")"
  ag_env_prefix="$(resolve_conda_env_prefix "$ag_env_name")"
  ag_conda_cmd=""
  ag_chrom=""
  ag_position=""
  ag_alt=""
  ag_summary_glob=""
  ag_plot_glob=""
  ag_log_path=""
  ag_step_cmd=""
  ag_fallback_cmd=""

  if [[ -n "$ag_variant_csv" ]]; then
    IFS=',' read -r ag_chrom ag_position ag_alt <<<"$ag_variant_csv"
  fi

  if [[ -n "$ag_assembly" && -n "$ag_chrom" && -n "$ag_position" && -n "$ag_alt" ]]; then
    if in_csv_list "assembly" "$missing_csv"; then
      missing_csv="$(remove_csv_item "$missing_csv" "assembly")"
      provided_csv="$(append_csv "$provided_csv" "assembly")"
    fi
    if in_csv_list "coordinate-or-interval" "$missing_csv"; then
      missing_csv="$(remove_csv_item "$missing_csv" "coordinate-or-interval")"
      provided_csv="$(append_csv "$provided_csv" "coordinate-or-interval")"
    fi
    if in_csv_list "ref-alt-or-variant-spec" "$missing_csv"; then
      missing_csv="$(remove_csv_item "$missing_csv" "ref-alt-or-variant-spec")"
      provided_csv="$(append_csv "$provided_csv" "ref-alt-or-variant-spec")"
    fi

    ag_summary_glob="${ag_output_dir}/${ag_chrom}_${ag_position}_*_to_${ag_alt}_summary.json"
    ag_plot_glob="${ag_output_dir}/${ag_chrom}_${ag_position}_*_to_${ag_alt}_rnaseq_overlay.png"
    ag_log_path="${ag_output_dir}/alphagenome_predict_variant.log"

    if [[ -n "$ag_env_prefix" ]]; then
      ag_conda_cmd="conda run -p ${ag_env_prefix}"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-auto-resolved:prefix")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-prefix:${ag_env_prefix}")"
    else
      ag_conda_cmd="conda run -n ${ag_env_name}"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-auto-resolved:name")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "conda-env-name:${ag_env_name}")"
    fi

    ag_step_cmd="set -a; source .env; set +a; mkdir -p ${ag_output_dir}; ${ag_conda_cmd} python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py --assembly ${ag_assembly} --variant-spec ${ag_chrom}:${ag_position}:${ag_alt} --output-dir ${ag_output_dir} 2>&1 | tee ${ag_log_path}"
    ag_fallback_cmd="set -a; source .env; set +a; mkdir -p ${ag_output_dir}; grpc_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 ${ag_conda_cmd} python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py --assembly ${ag_assembly} --variant-spec ${ag_chrom}:${ag_position}:${ag_alt} --output-dir ${ag_output_dir} --request-timeout-sec 120 2>&1 | tee ${ag_log_path}"

    plan_steps_csv="$ag_step_cmd"
    plan_expected_outputs_csv=""
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_summary_glob}")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${ag_plot_glob}")"
    plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ag_log_path}")"
    plan_fallbacks_csv="$(append_csv "$plan_fallbacks_csv" "$ag_fallback_cmd")"

    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "alphagenome-real-predict-variant-fastpath-enabled")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "ref-base-auto-resolved-from-${ag_assembly}-via-ucsc")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "fixed-rna-seq-with-uberon-0001157-for-minimal-stable-output")"
    plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "retry-with-local-proxy-if-grpc-connectivity-times-out")"
  fi
fi

if [[ -z "$required_canonical_csv" ]]; then
  required_canonical_csv="$(canonicalize_csv "$required_csv" "$input_schema_file")"
fi
provided_canonical_csv="$(canonicalize_csv "$provided_csv" "$input_schema_file")"
missing_canonical_csv="$(canonicalize_csv "$missing_csv" "$input_schema_file")"

if [[ -z "$plan_steps_csv" ]]; then
  if [[ -n "$effective_task" ]]; then
    plan_steps_csv="bash scripts/run_agent.sh --task $effective_task --query follow-up-required --format json"
  else
    plan_steps_csv="bash scripts/run_agent.sh --query follow-up-required --format json"
  fi
fi

if [[ -z "$plan_expected_outputs_csv" ]]; then
  plan_expected_outputs_csv="structured-agent-plan-json"
fi

playbook_path=""
if [[ -n "$effective_task" && -f "$REPO_ROOT/playbooks/$effective_task/README.md" ]]; then
  playbook_path="playbooks/$effective_task/README.md"
fi

next_prompt="Use \$$primary_skill to handle this request"
if [[ -n "$effective_task" ]]; then
  next_prompt="$next_prompt for task '$effective_task'"
fi
if [[ -n "$missing_csv" ]]; then
  next_prompt="$next_prompt. Ask for missing inputs: $missing_csv."
fi

if [[ "$format" == "text" ]]; then
  echo "query: $query"
  if [[ -n "$effective_task" ]]; then
    echo "task: $effective_task ($task_source)"
  else
    echo "task: none ($task_source)"
  fi
  echo "decision: route"
  echo "confidence: ${confidence_level:-unknown} (${confidence_score:-0})"
  echo "primary_skill: $primary_skill"
  echo "primary_skill_path: $skill_path"
  echo "skill_doc: $skill_path/SKILL.md"
  echo "skill_metadata: $skill_path/skill.yaml"
  if [[ -n "$playbook_path" ]]; then
    echo "playbook: $playbook_path"
  else
    echo "playbook: none"
  fi

  if [[ -n "$secondary_csv" ]]; then
    echo "secondary_skills:"
    csv_to_lines_prefixed "$secondary_csv" "- "
  else
    echo "secondary_skills: none"
  fi

  if [[ -n "$required_csv" ]]; then
    echo "required_inputs_source: $required_inputs_source"
    echo "required_inputs:"
    csv_to_lines_prefixed "$required_csv" "- "
  else
    echo "required_inputs_source: none"
    echo "required_inputs: none"
  fi

  if [[ -n "$required_canonical_csv" ]]; then
    echo "required_inputs_canonical:"
    csv_to_lines_prefixed "$required_canonical_csv" "- "
  else
    echo "required_inputs_canonical: none"
  fi

  if [[ -n "$provided_csv" ]]; then
    echo "provided_inputs:"
    csv_to_lines_prefixed "$provided_csv" "- "
  else
    echo "provided_inputs: none"
  fi

  if [[ -n "$provided_canonical_csv" ]]; then
    echo "provided_inputs_canonical:"
    csv_to_lines_prefixed "$provided_canonical_csv" "- "
  else
    echo "provided_inputs_canonical: none"
  fi

  if [[ -n "$missing_csv" ]]; then
    echo "missing_inputs:"
    csv_to_lines_prefixed "$missing_csv" "- "
  else
    echo "missing_inputs: none"
  fi

  if [[ -n "$missing_canonical_csv" ]]; then
    echo "missing_inputs_canonical:"
    csv_to_lines_prefixed "$missing_canonical_csv" "- "
  else
    echo "missing_inputs_canonical: none"
  fi

  if [[ -n "$constraints_csv" ]]; then
    echo "constraints:"
    csv_to_lines_prefixed "$constraints_csv" "- "
  else
    echo "constraints: none"
  fi

  if [[ -n "$tools_csv" ]]; then
    echo "tools:"
    csv_to_lines_prefixed "$tools_csv" "- "
  else
    echo "tools: none"
  fi

  emit_text_plan_block \
    "${effective_task:-none}" \
    "$primary_skill" \
    "$plan_assumptions_csv" \
    "$required_csv" \
    "$missing_csv" \
    "$constraints_csv" \
    "$plan_steps_csv" \
    "$plan_expected_outputs_csv" \
    "$plan_fallbacks_csv" \
    "$plan_retry_policy"

  echo "next_prompt: $next_prompt"
  exit 0
fi

printf '{'
printf '"query":"%s",' "$(json_escape "$query")"
if [[ -n "$effective_task" ]]; then
  printf '"task":"%s",' "$(json_escape "$effective_task")"
else
  printf '"task":null,'
fi
printf '"task_source":"%s",' "$(json_escape "$task_source")"
printf '"decision":"route",'
printf '"confidence":{'
printf '"level":"%s",' "$(json_escape "$confidence_level")"
printf '"score":%s' "${confidence_score:-0}"
printf '},'
printf '"clarify_question":null,'
printf '"primary_skill":"%s",' "$(json_escape "$primary_skill")"
printf '"primary_skill_path":"%s",' "$(json_escape "$skill_path")"
printf '"skill_doc":"%s",' "$(json_escape "$skill_doc")"
printf '"skill_metadata":"%s",' "$(json_escape "$skill_meta")"
if [[ -n "$playbook_path" ]]; then
  printf '"playbook":"%s",' "$(json_escape "$playbook_path")"
else
  printf '"playbook":null,'
fi
printf '"secondary_skills":'
emit_json_array_from_csv "${secondary_csv:-}"
printf ','
printf '"required_inputs":'
emit_json_array_from_csv "${required_csv:-}"
printf ','
printf '"required_inputs_canonical":'
emit_json_array_from_csv "${required_canonical_csv:-}"
printf ','
printf '"required_inputs_source":"%s",' "$(json_escape "$required_inputs_source")"
printf '"provided_inputs":'
emit_json_array_from_csv "${provided_csv:-}"
printf ','
printf '"provided_inputs_canonical":'
emit_json_array_from_csv "${provided_canonical_csv:-}"
printf ','
printf '"missing_inputs":'
emit_json_array_from_csv "${missing_csv:-}"
printf ','
printf '"missing_inputs_canonical":'
emit_json_array_from_csv "${missing_canonical_csv:-}"
printf ','
printf '"constraints":'
emit_json_array_from_csv "${constraints_csv:-}"
printf ','
printf '"tools":'
emit_json_array_from_csv "${tools_csv:-}"
printf ','
printf '"plan":'
emit_json_plan_object \
  "${effective_task:-none}" \
  "$primary_skill" \
  "$plan_assumptions_csv" \
  "$required_csv" \
  "$missing_csv" \
  "$constraints_csv" \
  "$plan_steps_csv" \
  "$plan_expected_outputs_csv" \
  "$plan_fallbacks_csv" \
  "$plan_retry_policy"
printf ','
printf '"next_prompt":"%s"' "$(json_escape "$next_prompt")"
printf '}\n'
