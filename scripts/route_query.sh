#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY_FILE="$REPO_ROOT/registry/skills.yaml"
DEFAULT_TAGS_FILE="$REPO_ROOT/registry/tags.yaml"
DEFAULT_ROUTING_FILE="$REPO_ROOT/registry/routing.yaml"
source "$REPO_ROOT/scripts/lib_registry.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: route_query.sh [options]

Route a user query to a primary skill and secondary candidates using registry metadata.

Options:
  --query TEXT           Query text to route. If omitted, read from stdin.
  --task TASK            Optional task hint (for example: embedding, variant-effect).
  --top-k N              Number of total candidates to return (including primary). Default: 3
  --format FMT           Output format: text or json. Default: text
  --registry FILE        Skill registry file. Default: <repo>/registry/skills.yaml
  --tags FILE            Task tag registry file. Default: <repo>/registry/tags.yaml
  --routing-config FILE  Routing config file. Default: <repo>/registry/routing.yaml
  -h, --help             Show this help message.
EOF_USAGE
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_text() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

trim_text() {
  printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
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

append_unique_csv() {
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

csv_count() {
  local csv="${1:-}"
  if [[ -z "$csv" ]]; then
    printf '0\n'
    return 0
  fi
  awk -F',' '{print NF}' <<<"$csv"
}

append_reason() {
  local current="${1:-}"
  local msg="${2:-}"
  if [[ -z "$msg" ]]; then
    printf '%s\n' "$current"
    return 0
  fi
  if [[ -z "$current" ]]; then
    printf '%s\n' "$msg"
  else
    printf '%s\n' "$current|$msg"
  fi
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

config_get_int() {
  local cfg_file="$1"
  local key="$2"
  local fallback="$3"
  local value
  value="$(yaml_get_scalar_field "$cfg_file" "$key" || true)"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

config_get_string() {
  local cfg_file="$1"
  local key="$2"
  local fallback="$3"
  local value
  value="$(yaml_get_scalar_field "$cfg_file" "$key" || true)"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

skill_has_task_direct() {
  local skill_id="$1"
  local task_name="$2"
  while IFS= read -r task_item; do
    if [[ "$task_item" == "$task_name" ]]; then
      return 0
    fi
  done < <(registry_get_list_field "$registry_file" "$skill_id" "tasks")
  return 1
}

skill_in_task_tag() {
  local skill_id="$1"
  local task_name="$2"
  if [[ -z "$task_name" ]]; then
    return 1
  fi
  while IFS= read -r sid; do
    if [[ "$sid" == "$skill_id" ]]; then
      return 0
    fi
  done < <(tag_registry_list_for_task "$tags_file" "$task_name")
  return 1
}

skill_aligned_with_task() {
  local skill_id="$1"
  local task_name="$2"
  if [[ -z "$task_name" ]]; then
    return 1
  fi
  if skill_has_task_direct "$skill_id" "$task_name"; then
    return 0
  fi
  if skill_in_task_tag "$skill_id" "$task_name"; then
    return 0
  fi
  return 1
}

matched_triggers_csv() {
  local skill_id="$1"
  local query_lc="$2"
  local csv=""
  local trigger_lc
  while IFS= read -r trigger; do
    [[ -z "$trigger" ]] && continue
    trigger_lc="$(to_lower "$trigger")"
    if contains_token "$query_lc" "$trigger_lc"; then
      csv="$(append_unique_csv "$csv" "$trigger")"
    fi
  done < <(registry_get_list_field "$registry_file" "$skill_id" "triggers")
  printf '%s\n' "$csv"
}

score_skill_for_query() {
  local skill_id="$1"
  local query_lc="$2"
  local task_name="${3:-}"
  local score=0
  local skill_lc
  local trigger_lc

  skill_lc="$(to_lower "$skill_id")"

  if contains_token "$query_lc" "\$$skill_lc"; then
    score=$((score + WEIGHT_EXPLICIT_SKILL_MENTION))
  fi
  if contains_token "$query_lc" "$skill_lc"; then
    score=$((score + WEIGHT_SKILL_ID_MENTION))
  fi

  while IFS= read -r trigger; do
    [[ -z "$trigger" ]] && continue
    trigger_lc="$(to_lower "$trigger")"
    if contains_token "$query_lc" "$trigger_lc"; then
      score=$((score + WEIGHT_TRIGGER_MATCH))
    fi
  done < <(registry_get_list_field "$registry_file" "$skill_id" "triggers")

  if [[ -n "$task_name" ]] && skill_aligned_with_task "$skill_id" "$task_name"; then
    score=$((score + WEIGHT_TASK_ALIGNMENT))
  fi

  printf '%s\n' "$score"
}

infer_task_from_alias_rules() {
  local query_lc="$1"
  local best_task=""
  local best_len=0
  local rule
  local phrase
  local mapped
  local phrase_lc
  local mapped_lc
  local phrase_len

  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    if [[ "$rule" != *"=>"* ]]; then
      continue
    fi
    phrase="${rule%%=>*}"
    mapped="${rule#*=>}"
    phrase="$(trim_text "$phrase")"
    mapped="$(trim_text "$mapped")"
    [[ -z "$phrase" || -z "$mapped" ]] && continue
    phrase_lc="$(to_lower "$phrase")"
    mapped_lc="$(to_lower "$mapped")"

    if contains_token "$query_lc" "$phrase_lc"; then
      phrase_len=${#phrase_lc}
      if [[ "$phrase_len" -gt "$best_len" ]]; then
        best_len="$phrase_len"
        best_task="$mapped_lc"
      fi
    fi
  done < <(yaml_get_list_field "$routing_file" "task_alias_rules")

  if [[ -n "$best_task" ]]; then
    printf '%s\n' "$best_task"
  fi
}

infer_task() {
  local query_lc="$1"
  local best_task=""
  local best_score=0
  local candidate_lc
  local phrase
  local term_count
  local score
  local sid_lc
  local trigger_lc
  local trigger_hits

  while IFS= read -r candidate_task; do
    [[ -z "$candidate_task" ]] && continue
    score=0
    candidate_lc="$(to_lower "$candidate_task")"
    phrase="${candidate_lc//-/ }"
    phrase="${phrase//_/ }"
    term_count="$(awk '{print NF}' <<<"$phrase")"

    if contains_token "$query_lc" "$phrase"; then
      score=$((score + INFER_PHRASE_EXACT_BASE + (term_count - 1) * INFER_PHRASE_EXACT_TERM_BONUS))
    elif contains_token "$query_lc" "$candidate_lc"; then
      score=$((score + INFER_TASK_KEY_BONUS))
    fi

    for token in $phrase; do
      if [[ ${#token} -ge 4 ]] && contains_token "$query_lc" "$token"; then
        score=$((score + INFER_TOKEN_MATCH))
      fi
    done

    while IFS= read -r sid; do
      [[ -z "$sid" ]] && continue
      sid_lc="$(to_lower "$sid")"
      if contains_token "$query_lc" "$sid_lc"; then
        score=$((score + INFER_SKILL_MENTION_IN_TASK))
      fi

      trigger_hits=0
      while IFS= read -r trigger; do
        [[ -z "$trigger" ]] && continue
        trigger_lc="$(to_lower "$trigger")"
        if contains_token "$query_lc" "$trigger_lc"; then
          score=$((score + INFER_TRIGGER_MATCH_IN_TASK))
          trigger_hits=$((trigger_hits + 1))
          if [[ "$trigger_hits" -ge "$INFER_TRIGGER_MATCH_CAP" ]]; then
            break
          fi
        fi
      done < <(registry_get_list_field "$registry_file" "$sid" "triggers")
    done < <(tag_registry_list_for_task "$tags_file" "$candidate_task")

    if [[ "$score" -gt "$best_score" ]]; then
      best_score="$score"
      best_task="$candidate_task"
    elif [[ "$score" -eq "$best_score" && -n "$candidate_task" && ( -z "$best_task" || "$candidate_task" < "$best_task" ) ]]; then
      best_task="$candidate_task"
    fi
  done < <(tag_registry_list_tasks "$tags_file")

  if [[ "$best_score" -gt 0 ]]; then
    printf '%s\n' "$best_task"
  fi
}

build_reasons_pipe() {
  local skill_id="$1"
  local score="$2"
  local query_lc="$3"
  local task_name="$4"
  local from_tag_fallback="$5"
  local reasons=""
  local skill_lc
  local trigger_csv

  skill_lc="$(to_lower "$skill_id")"

  if contains_token "$query_lc" "\$$skill_lc"; then
    reasons="$(append_reason "$reasons" "explicit skill mention: \$$skill_lc")"
  fi
  if contains_token "$query_lc" "$skill_lc"; then
    reasons="$(append_reason "$reasons" "query mentions skill id")"
  fi

  trigger_csv="$(matched_triggers_csv "$skill_id" "$query_lc")"
  if [[ -n "$trigger_csv" ]]; then
    reasons="$(append_reason "$reasons" "matched triggers: $trigger_csv")"
  fi

  if [[ -n "$task_name" ]] && skill_aligned_with_task "$skill_id" "$task_name"; then
    reasons="$(append_reason "$reasons" "task alignment: $task_name")"
  fi

  if [[ "$from_tag_fallback" -eq 1 ]]; then
    reasons="$(append_reason "$reasons" "task-tag fallback candidate: $task_name")"
  fi

  if [[ -z "$reasons" ]]; then
    reasons="heuristic score: $score"
  fi

  printf '%s\n' "$reasons"
}

compute_confidence() {
  local primary_score="$1"
  local secondary_best_score="$2"
  local query_lc="$3"
  local primary_skill="$4"
  local skill_lc
  local margin

  if [[ -z "$primary_score" ]]; then
    primary_score=0
  fi
  if [[ -z "$secondary_best_score" ]]; then
    secondary_best_score=0
  fi

  skill_lc="$(to_lower "$primary_skill")"
  margin=$((primary_score - secondary_best_score))
  if [[ "$margin" -lt 0 ]]; then
    margin=0
  fi

  if [[ -n "$primary_skill" ]] && ( contains_token "$query_lc" "\$$skill_lc" || contains_token "$query_lc" "$skill_lc" ); then
    printf 'high|0.92\n'
    return 0
  fi

  if [[ "$primary_score" -ge "$CONF_HIGH_MIN_PRIMARY_SCORE" && "$margin" -ge "$CONF_HIGH_MIN_MARGIN" ]]; then
    printf 'high|0.86\n'
    return 0
  fi

  if [[ "$primary_score" -ge "$CONF_MEDIUM_MIN_PRIMARY_SCORE" && "$margin" -ge "$CONF_MEDIUM_MIN_MARGIN" ]]; then
    printf 'medium|0.64\n'
    return 0
  fi

  printf 'low|0.34\n'
}

print_reasons_text() {
  local reasons_pipe="${1:-}"
  local -a arr=()
  if [[ -z "$reasons_pipe" ]]; then
    echo "- heuristic rank"
    return 0
  fi
  IFS='|' read -r -a arr <<<"$reasons_pipe"
  for reason in "${arr[@]}"; do
    [[ -z "$reason" ]] && continue
    echo "- $reason"
  done
}

print_reasons_json() {
  local reasons_pipe="${1:-}"
  local -a arr=()
  local first=1
  local escaped
  if [[ -z "$reasons_pipe" ]]; then
    printf '[]'
    return 0
  fi
  IFS='|' read -r -a arr <<<"$reasons_pipe"
  printf '['
  for reason in "${arr[@]}"; do
    [[ -z "$reason" ]] && continue
    escaped="$(json_escape "$reason")"
    if [[ "$first" -eq 0 ]]; then
      printf ','
    fi
    printf '"%s"' "$escaped"
    first=0
  done
  printf ']'
}

query=""
task=""
top_k=3
format="text"
registry_file="$DEFAULT_REGISTRY_FILE"
tags_file="$DEFAULT_TAGS_FILE"
routing_file="$DEFAULT_ROUTING_FILE"

# Defaults before reading optional routing config overrides.
WEIGHT_EXPLICIT_SKILL_MENTION=120
WEIGHT_SKILL_ID_MENTION=80
WEIGHT_TRIGGER_MATCH=25
WEIGHT_TASK_ALIGNMENT=20
INFER_PHRASE_EXACT_BASE=60
INFER_PHRASE_EXACT_TERM_BONUS=12
INFER_TASK_KEY_BONUS=35
INFER_TOKEN_MATCH=8
INFER_SKILL_MENTION_IN_TASK=6
INFER_TRIGGER_MATCH_IN_TASK=4
INFER_TRIGGER_MATCH_CAP=3
CONF_HIGH_MIN_PRIMARY_SCORE=70
CONF_HIGH_MIN_MARGIN=25
CONF_MEDIUM_MIN_PRIMARY_SCORE=35
CONF_MEDIUM_MIN_MARGIN=10
CLARIFY_LOW_CONFIDENCE_BEHAVIOR="ask"
CLARIFY_QUESTION="I can route this better with one detail: which task do you want (environment-setup, embedding, variant-effect, fine-tuning, track-prediction, troubleshooting)?"

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

WEIGHT_EXPLICIT_SKILL_MENTION="$(config_get_int "$routing_file" "weight_explicit_skill_mention" "$WEIGHT_EXPLICIT_SKILL_MENTION")"
WEIGHT_SKILL_ID_MENTION="$(config_get_int "$routing_file" "weight_skill_id_mention" "$WEIGHT_SKILL_ID_MENTION")"
WEIGHT_TRIGGER_MATCH="$(config_get_int "$routing_file" "weight_trigger_match" "$WEIGHT_TRIGGER_MATCH")"
WEIGHT_TASK_ALIGNMENT="$(config_get_int "$routing_file" "weight_task_alignment" "$WEIGHT_TASK_ALIGNMENT")"
INFER_PHRASE_EXACT_BASE="$(config_get_int "$routing_file" "infer_phrase_exact_base" "$INFER_PHRASE_EXACT_BASE")"
INFER_PHRASE_EXACT_TERM_BONUS="$(config_get_int "$routing_file" "infer_phrase_exact_term_bonus" "$INFER_PHRASE_EXACT_TERM_BONUS")"
INFER_TASK_KEY_BONUS="$(config_get_int "$routing_file" "infer_task_key_bonus" "$INFER_TASK_KEY_BONUS")"
INFER_TOKEN_MATCH="$(config_get_int "$routing_file" "infer_token_match" "$INFER_TOKEN_MATCH")"
INFER_SKILL_MENTION_IN_TASK="$(config_get_int "$routing_file" "infer_skill_mention_in_task" "$INFER_SKILL_MENTION_IN_TASK")"
INFER_TRIGGER_MATCH_IN_TASK="$(config_get_int "$routing_file" "infer_trigger_match_in_task" "$INFER_TRIGGER_MATCH_IN_TASK")"
INFER_TRIGGER_MATCH_CAP="$(config_get_int "$routing_file" "infer_trigger_match_cap" "$INFER_TRIGGER_MATCH_CAP")"
CONF_HIGH_MIN_PRIMARY_SCORE="$(config_get_int "$routing_file" "confidence_high_min_primary_score" "$CONF_HIGH_MIN_PRIMARY_SCORE")"
CONF_HIGH_MIN_MARGIN="$(config_get_int "$routing_file" "confidence_high_min_margin" "$CONF_HIGH_MIN_MARGIN")"
CONF_MEDIUM_MIN_PRIMARY_SCORE="$(config_get_int "$routing_file" "confidence_medium_min_primary_score" "$CONF_MEDIUM_MIN_PRIMARY_SCORE")"
CONF_MEDIUM_MIN_MARGIN="$(config_get_int "$routing_file" "confidence_medium_min_margin" "$CONF_MEDIUM_MIN_MARGIN")"
CLARIFY_LOW_CONFIDENCE_BEHAVIOR="$(config_get_string "$routing_file" "clarify_low_confidence_behavior" "$CLARIFY_LOW_CONFIDENCE_BEHAVIOR")"
CLARIFY_QUESTION="$(config_get_string "$routing_file" "clarify_question" "$CLARIFY_QUESTION")"

query_lc="$(to_lower "$query")"

effective_task=""
task_source="none"
if [[ -n "$task" ]]; then
  effective_task="$(to_lower "$task")"
  task_source="provided"
else
  alias_task="$(infer_task_from_alias_rules "$query_lc" || true)"
  if [[ -n "$alias_task" ]]; then
    effective_task="$alias_task"
    task_source="alias"
  else
    inferred_task="$(infer_task "$query_lc" || true)"
    if [[ -n "$inferred_task" ]]; then
      effective_task="$inferred_task"
      task_source="inferred"
    fi
  fi
fi

skill_ids=()
while IFS= read -r sid; do
  [[ -n "$sid" ]] && skill_ids+=("$sid")
done < <(registry_list_ids "$registry_file")

if [[ ${#skill_ids[@]} -eq 0 ]]; then
  echo "error: no skills found in registry: $registry_file" >&2
  exit 1
fi

score_table=""
for sid in "${skill_ids[@]}"; do
  score="$(score_skill_for_query "$sid" "$query_lc" "$effective_task")"
  score_table+="$score"$'\t'"$sid"$'\n'
done

sorted_scores="$(printf '%s' "$score_table" | sort -t$'\t' -k1,1nr -k2,2)"
primary_skill="$(printf '%s\n' "$sorted_scores" | awk 'NF{print $2; exit}')"
primary_score="$(printf '%s\n' "$sorted_scores" | awk 'NF{print $1; exit}')"
if [[ -z "$primary_score" ]]; then
  primary_score=0
fi

primary_from_tag_fallback=0
if [[ -n "$effective_task" && "$primary_score" -le 0 ]]; then
  fallback_primary="$(tag_registry_list_for_task "$tags_file" "$effective_task" | head -n 1 || true)"
  if [[ -n "$fallback_primary" ]]; then
    primary_skill="$fallback_primary"
    primary_score=0
    primary_from_tag_fallback=1
  fi
fi

secondary_best_score="$(printf '%s\n' "$sorted_scores" | awk -v p="$primary_skill" 'NF && $2 != p {print $1; exit}')"
if [[ -z "$secondary_best_score" ]]; then
  secondary_best_score=0
fi

confidence_pair="$(compute_confidence "$primary_score" "$secondary_best_score" "$query_lc" "$primary_skill")"
confidence_level="${confidence_pair%%|*}"
confidence_score="${confidence_pair#*|}"
clarify_question="$CLARIFY_QUESTION"
if [[ -n "$effective_task" ]]; then
  top_skills_csv="$(printf '%s\n' "$sorted_scores" | awk 'NF{print $2}' | head -n 3 | paste -sd ',' -)"
  if [[ -n "$top_skills_csv" ]]; then
    clarify_question="I inferred task '$effective_task' but confidence is low. Which skill should lead ($top_skills_csv)?"
  else
    clarify_question="I inferred task '$effective_task' but confidence is low. Which skill should lead?"
  fi
fi

decision="route"
if [[ -z "$primary_skill" ]]; then
  decision="clarify"
fi
if [[ "$decision" == "route" && "$task_source" != "provided" && "$CLARIFY_LOW_CONFIDENCE_BEHAVIOR" == "ask" && "$confidence_level" == "low" ]]; then
  decision="clarify"
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
    echo "confidence: $confidence_level ($confidence_score)"
    echo "clarify_question: $clarify_question"
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
  printf '"score":%s' "$confidence_score"
  printf '},'
  printf '"clarify_question":"%s",' "$(json_escape "$clarify_question")"
  printf '"primary":null,'
  printf '"secondary":[]'
  printf '}\n'
  exit 0
fi

if [[ -z "$primary_skill" ]]; then
  echo "error: failed to select a primary skill." >&2
  exit 1
fi

secondary_csv=""
secondary_rows=""
secondary_limit=$((top_k - 1))

while IFS=$'\t' read -r score sid; do
  [[ -z "$sid" ]] && continue
  if [[ "$sid" == "$primary_skill" ]]; then
    continue
  fi
  if [[ "$score" -le 0 ]]; then
    continue
  fi
  secondary_csv="$(append_unique_csv "$secondary_csv" "$sid")"
  secondary_rows+="$score"$'\t'"$sid"$'\t'"0"$'\n'
  if [[ "$(csv_count "$secondary_csv")" -ge "$secondary_limit" ]]; then
    break
  fi
done <<<"$sorted_scores"

if [[ "$secondary_limit" -gt 0 && -n "$effective_task" && "$(csv_count "$secondary_csv")" -lt "$secondary_limit" ]]; then
  while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    if [[ "$sid" == "$primary_skill" ]] || in_csv_list "$sid" "$secondary_csv"; then
      continue
    fi
    score="$(score_skill_for_query "$sid" "$query_lc" "$effective_task")"
    secondary_csv="$(append_unique_csv "$secondary_csv" "$sid")"
    secondary_rows+="$score"$'\t'"$sid"$'\t'"1"$'\n'
    if [[ "$(csv_count "$secondary_csv")" -ge "$secondary_limit" ]]; then
      break
    fi
  done < <(tag_registry_list_for_task "$tags_file" "$effective_task")
fi

primary_reasons="$(build_reasons_pipe "$primary_skill" "$primary_score" "$query_lc" "$effective_task" "$primary_from_tag_fallback")"

if [[ "$format" == "text" ]]; then
  echo "query: $query"
  if [[ -n "$effective_task" ]]; then
    echo "task: $effective_task ($task_source)"
  else
    echo "task: none ($task_source)"
  fi
  echo "decision: route"
  echo "confidence: $confidence_level ($confidence_score)"
  echo "primary: $primary_skill (score=$primary_score)"
  echo "primary_reasons:"
  print_reasons_text "$primary_reasons"

  if [[ -z "$secondary_rows" ]]; then
    echo "secondary: none"
    exit 0
  fi

  echo "secondary:"
  while IFS=$'\t' read -r score sid from_tag; do
    [[ -z "$sid" ]] && continue
    secondary_reasons="$(build_reasons_pipe "$sid" "$score" "$query_lc" "$effective_task" "$from_tag")"
    echo "- $sid (score=$score)"
    print_reasons_text "$secondary_reasons" | sed 's/^/  /'
  done <<<"$secondary_rows"
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
printf '"score":%s' "$confidence_score"
printf '},'
printf '"clarify_question":null,'
printf '"primary":{'
printf '"skill":"%s",' "$(json_escape "$primary_skill")"
printf '"score":%s,' "$primary_score"
printf '"reasons":'
print_reasons_json "$primary_reasons"
printf '},'
printf '"secondary":['
first_secondary=1
while IFS=$'\t' read -r score sid from_tag; do
  [[ -z "$sid" ]] && continue
  secondary_reasons="$(build_reasons_pipe "$sid" "$score" "$query_lc" "$effective_task" "$from_tag")"
  if [[ "$first_secondary" -eq 0 ]]; then
    printf ','
  fi
  printf '{'
  printf '"skill":"%s",' "$(json_escape "$sid")"
  printf '"score":%s,' "$score"
  printf '"reasons":'
  print_reasons_json "$secondary_reasons"
  printf '}'
  first_secondary=0
done <<<"$secondary_rows"
printf ']'
printf '}\n'
