#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY_FILE="$REPO_ROOT/registry/skills.yaml"
DEFAULT_TAGS_FILE="$REPO_ROOT/registry/tags.yaml"
DEFAULT_ROUTING_FILE="$REPO_ROOT/registry/routing.yaml"
DEFAULT_CONTRACTS_FILE="$REPO_ROOT/registry/task_contracts.yaml"
DEFAULT_OUTPUT_CONTRACTS_FILE="$REPO_ROOT/registry/output_contracts.yaml"
DEFAULT_RECOVERY_POLICIES_FILE="$REPO_ROOT/registry/recovery_policies.yaml"
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

extract_ntv3_output_dir_from_query() {
  local query_raw="$1"
  local out=""
  out="$(printf '%s\n' "$query_raw" | grep -Eio 'output/[A-Za-z0-9._/-]+' | head -n 1 || true)"
  if [[ -z "$out" ]]; then
    out="output/ntv3_results"
  fi
  out="${out%/}"
  if [[ -z "$out" ]]; then
    out="output/ntv3_results"
  fi
  printf '%s\n' "$out"
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
    position_raw="$(printf '%s\n' "$query_raw" | grep -Eio 'position[[:space:]]*[:=]?[[:space:]]*[0-9_,]+' | head -n 1 | sed -E 's/.*([0-9][0-9_,]*).*/\1/' || true)"
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

input_satisfied() {
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
  printf '"required_inputs_source":null,'
  printf '"provided_inputs":[],'
  printf '"missing_inputs":[],'
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
required_inputs_source="skill"
constraints_csv=""
tools_csv=""

while IFS= read -r v; do
  [[ -n "$v" ]] && skill_required_csv="$(append_csv "$skill_required_csv" "$v")"
done < <(yaml_get_list_field "$skill_meta" "required_inputs")

required_csv="$skill_required_csv"
if [[ -n "$effective_task" ]]; then
  task_required_csv=""
  while IFS= read -r v; do
    [[ -n "$v" ]] && task_required_csv="$(append_csv "$task_required_csv" "$v")"
  done < <(task_contract_list_required_inputs "$contracts_file" "$effective_task")

  if [[ -n "$task_required_csv" ]]; then
    required_csv="$task_required_csv"
    required_inputs_source="task-contract:$effective_task"
  else
    required_inputs_source="skill:$primary_skill"
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
provided_csv=""
missing_csv=""
for req in $(printf '%s\n' "$required_csv" | tr ',' ' '); do
  [[ -z "$req" ]] && continue
  if input_satisfied "$req" "$query_lc"; then
    provided_csv="$(append_csv "$provided_csv" "$req")"
  else
    missing_csv="$(append_csv "$missing_csv" "$req")"
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
  ntv3_species="$(extract_ntv3_species_from_query "$query_lc")"
  ntv3_assembly="$(extract_ntv3_assembly_from_query "$query_lc")"
  ntv3_output_dir="$(extract_ntv3_output_dir_from_query "$query")"
  ntv3_model="InstaDeepAI/NTv3_100M_post"
  ntv3_chrom=""
  ntv3_start=""
  ntv3_end=""
  ntv3_prefix=""
  ntv3_plot_path=""
  ntv3_meta_path=""
  ntv3_log_path=""
  ntv3_step_cmd=""
  ntv3_fallback_cmd=""

  if [[ -n "$ntv3_interval_csv" ]]; then
    IFS=',' read -r ntv3_chrom ntv3_start ntv3_end <<<"$ntv3_interval_csv"
  fi

  if [[ -n "$ntv3_species" && -n "$ntv3_assembly" && -n "$ntv3_chrom" && -n "$ntv3_start" && -n "$ntv3_end" && -z "$ntv3_missing_non_head" ]]; then
    if [[ "$ntv3_end" =~ ^[0-9]+$ && "$ntv3_start" =~ ^[0-9]+$ && "$ntv3_end" -gt "$ntv3_start" ]]; then
      ntv3_prefix="ntv3_${ntv3_species}_${ntv3_assembly}_${ntv3_chrom}_${ntv3_start}_${ntv3_end}"
      ntv3_plot_path="${ntv3_output_dir}/${ntv3_prefix}_trackplot.png"
      ntv3_meta_path="${ntv3_output_dir}/${ntv3_prefix}_meta.json"
      ntv3_log_path="${ntv3_output_dir}/ntv3_run.log"

      ntv3_step_cmd="set -a; source .env; set +a; mkdir -p ${ntv3_output_dir}; conda run -n ntv3 python skills/nucleotide-transformer-v3/scripts/run_track_prediction.py --model ${ntv3_model} --species ${ntv3_species} --assembly ${ntv3_assembly} --chrom ${ntv3_chrom} --start ${ntv3_start} --end ${ntv3_end} --output-dir ${ntv3_output_dir} 2>&1 | tee ${ntv3_log_path}"
      ntv3_fallback_cmd="set -a; source .env; set +a; mkdir -p ${ntv3_output_dir}; conda run -n ntv3 python skills/nucleotide-transformer-v3/scripts/run_track_prediction.py --model ${ntv3_model} --species ${ntv3_species} --assembly ${ntv3_assembly} --chrom ${ntv3_chrom} --start ${ntv3_start} --end ${ntv3_end} --output-dir ${ntv3_output_dir} --disable-xet 2>&1 | tee ${ntv3_log_path}"

      plan_steps_csv="$ntv3_step_cmd"
      plan_expected_outputs_csv=""
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-plot:${ntv3_plot_path}")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_meta_path}")"
      plan_expected_outputs_csv="$(append_csv "$plan_expected_outputs_csv" "expected-file:${ntv3_log_path}")"
      plan_fallbacks_csv="$(append_csv "$plan_fallbacks_csv" "$ntv3_fallback_cmd")"

      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "ntv3-track-fastpath-enabled")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-model:${ntv3_model}")"
      plan_assumptions_csv="$(append_csv "$plan_assumptions_csv" "default-output-dir:${ntv3_output_dir}")"
    fi
  fi
fi

if [[ "$effective_task" == "variant-effect" && "$primary_skill" == "alphagenome-api" ]]; then
  ag_assembly="$(extract_alphagenome_assembly_from_query "$query_lc")"
  ag_variant_csv="$(extract_alphagenome_variant_from_query "$query")"
  ag_output_dir="$(extract_alphagenome_output_dir_from_query "$query")"
  ag_env_name="$(extract_alphagenome_env_from_query "$query")"
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

    ag_step_cmd="set -a; source .env; set +a; mkdir -p ${ag_output_dir}; conda run -n ${ag_env_name} python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py --chrom ${ag_chrom} --position ${ag_position} --alt ${ag_alt} --assembly ${ag_assembly} --output-dir ${ag_output_dir} 2>&1 | tee ${ag_log_path}"
    ag_fallback_cmd="set -a; source .env; set +a; mkdir -p ${ag_output_dir}; grpc_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 conda run -n ${ag_env_name} python skills/alphagenome-api/scripts/run_alphagenome_predict_variant.py --chrom ${ag_chrom} --position ${ag_position} --alt ${ag_alt} --assembly ${ag_assembly} --output-dir ${ag_output_dir} --request-timeout-sec 120 2>&1 | tee ${ag_log_path}"

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

  if [[ -n "$provided_csv" ]]; then
    echo "provided_inputs:"
    csv_to_lines_prefixed "$provided_csv" "- "
  else
    echo "provided_inputs: none"
  fi

  if [[ -n "$missing_csv" ]]; then
    echo "missing_inputs:"
    csv_to_lines_prefixed "$missing_csv" "- "
  else
    echo "missing_inputs: none"
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
printf '"required_inputs_source":"%s",' "$(json_escape "$required_inputs_source")"
printf '"provided_inputs":'
emit_json_array_from_csv "${provided_csv:-}"
printf ','
printf '"missing_inputs":'
emit_json_array_from_csv "${missing_csv:-}"
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
