#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY_FILE="$REPO_ROOT/registry/skills.yaml"
DEFAULT_TAGS_FILE="$REPO_ROOT/registry/tags.yaml"
DEFAULT_ROUTING_FILE="$REPO_ROOT/registry/routing.yaml"
DEFAULT_CASES_FILE="$REPO_ROOT/evals/routing/cases.yaml"
DEFAULT_ROUTER_SCRIPT="$REPO_ROOT/scripts/route_query.sh"
source "$REPO_ROOT/scripts/lib_registry.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: validate_routing.sh [options]

Evaluate routing quality against eval cases by invoking the runtime router.

Options:
  --registry FILE        Skill registry file. Default: <repo>/registry/skills.yaml
  --tags FILE            Task tag registry file. Default: <repo>/registry/tags.yaml
  --routing-config FILE  Routing config file. Default: <repo>/registry/routing.yaml
  --cases FILE           Routing eval case file. Default: <repo>/evals/routing/cases.yaml
  --router FILE          Router script path. Default: <repo>/scripts/route_query.sh
  -h, --help             Show this help message.
EOF_USAGE
}

registry_file="$DEFAULT_REGISTRY_FILE"
tags_file="$DEFAULT_TAGS_FILE"
routing_file="$DEFAULT_ROUTING_FILE"
cases_file="$DEFAULT_CASES_FILE"
router_script="$DEFAULT_ROUTER_SCRIPT"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --cases)
      cases_file="$2"
      shift 2
      ;;
    --router)
      router_script="$2"
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

registry_require_file "$registry_file"
registry_require_file "$tags_file"
registry_require_file "$routing_file"
registry_require_file "$cases_file"
if [[ ! -f "$router_script" ]]; then
  echo "error: router script not found: $router_script" >&2
  exit 1
fi

parse_eval_cases() {
  local file="$1"
  awk '
    BEGIN {
      FS = "\n"
      OFS = "\037"
      case_id = ""
      query = ""
      expected_primary = ""
      expected_secondary = ""
      task = ""
      expected_decision = ""
      expected_clarify_contains = ""
      in_secondary = 0
    }
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if (s ~ /^".*"$/) {
        sub(/^"/, "", s)
        sub(/"$/, "", s)
      }
      return s
    }
    function emit_case() {
      if (case_id != "") {
        print case_id, query, expected_primary, expected_secondary, task, expected_decision, expected_clarify_contains
      }
    }
    /^[[:space:]]*-[[:space:]]id:[[:space:]]*/ {
      emit_case()
      case_id = $0
      sub(/^[[:space:]]*-[[:space:]]id:[[:space:]]*/, "", case_id)
      case_id = unquote(case_id)
      query = ""
      expected_primary = ""
      expected_secondary = ""
      task = ""
      expected_decision = ""
      expected_clarify_contains = ""
      in_secondary = 0
      next
    }
    /^[[:space:]]*query:[[:space:]]*/ {
      query = $0
      sub(/^[[:space:]]*query:[[:space:]]*/, "", query)
      query = unquote(query)
      in_secondary = 0
      next
    }
    /^[[:space:]]*expected_primary_skill:[[:space:]]*/ {
      expected_primary = $0
      sub(/^[[:space:]]*expected_primary_skill:[[:space:]]*/, "", expected_primary)
      expected_primary = unquote(expected_primary)
      in_secondary = 0
      next
    }
    /^[[:space:]]*expected_secondary_skills:[[:space:]]*\[[[:space:]]*\][[:space:]]*$/ {
      expected_secondary = ""
      in_secondary = 0
      next
    }
    /^[[:space:]]*expected_secondary_skills:[[:space:]]*$/ {
      expected_secondary = ""
      in_secondary = 1
      next
    }
    in_secondary && /^[[:space:]]*-[[:space:]]*/ {
      secondary = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", secondary)
      secondary = unquote(secondary)
      if (secondary != "") {
        if (expected_secondary == "") {
          expected_secondary = secondary
        } else {
          expected_secondary = expected_secondary "," secondary
        }
      }
      next
    }
    /^[[:space:]]*task:[[:space:]]*/ {
      task = $0
      sub(/^[[:space:]]*task:[[:space:]]*/, "", task)
      task = unquote(task)
      in_secondary = 0
      next
    }
    /^[[:space:]]*expected_decision:[[:space:]]*/ {
      expected_decision = $0
      sub(/^[[:space:]]*expected_decision:[[:space:]]*/, "", expected_decision)
      expected_decision = unquote(expected_decision)
      in_secondary = 0
      next
    }
    /^[[:space:]]*expected_clarify_contains:[[:space:]]*/ {
      expected_clarify_contains = $0
      sub(/^[[:space:]]*expected_clarify_contains:[[:space:]]*/, "", expected_clarify_contains)
      expected_clarify_contains = unquote(expected_clarify_contains)
      in_secondary = 0
      next
    }
    END {
      emit_case()
    }
  ' "$file"
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
  if [[ -z "$csv" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$csv,$value"
  fi
}

extract_decision_from_json() {
  local json="$1"
  printf '%s\n' "$json" | sed -n 's/.*"decision":"\([^"]*\)".*/\1/p'
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

extract_primary_score_from_json() {
  local json="$1"
  local score
  score="$(printf '%s\n' "$json" | sed -n 's/.*"primary":{"skill":"[^"]*","score":\([0-9][0-9]*\).*/\1/p')"
  if [[ -z "$score" ]]; then
    score="0"
  fi
  printf '%s\n' "$score"
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

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

num_skills=0
while IFS= read -r _sid; do
  [[ -n "$_sid" ]] && num_skills=$((num_skills + 1))
done < <(registry_list_ids "$registry_file")

if [[ "$num_skills" -eq 0 ]]; then
  echo "error: no skills found in registry: $registry_file" >&2
  exit 1
fi

total_cases=0
pass_cases=0
fail_cases=0

while IFS=$'\x1f' read -r case_id query expected_primary expected_secondary task_name expected_decision expected_clarify_contains; do
  [[ -z "$case_id" ]] && continue
  total_cases=$((total_cases + 1))

  expected_decision="${expected_decision:-route}"
  if [[ -z "$expected_decision" ]]; then
    expected_decision="route"
  fi

  route_json=""
  router_cmd=(bash "$router_script" \
    --registry "$registry_file" \
    --tags "$tags_file" \
    --routing-config "$routing_file" \
    --query "$query" \
    --top-k "$num_skills" \
    --format json)
  if [[ -n "$task_name" ]]; then
    router_cmd+=(--task "$task_name")
  fi

  if ! route_json="$("${router_cmd[@]}" 2>&1)"; then
    fail_cases=$((fail_cases + 1))
    echo "fail: $case_id (router execution failed)" >&2
    echo "  query: $query" >&2
    echo "  router_error: $route_json" >&2
    continue
  fi

  predicted_decision="$(extract_decision_from_json "$route_json")"

  if [[ "$expected_decision" == "clarify" ]]; then
    clarify_ok=1
    if [[ "$predicted_decision" != "clarify" ]]; then
      clarify_ok=0
    fi

    if [[ "$clarify_ok" -eq 1 && -n "$expected_clarify_contains" ]]; then
      predicted_question="$(extract_clarify_question_from_json "$route_json")"
      expected_lc="$(to_lower "$expected_clarify_contains")"
      predicted_lc="$(to_lower "$predicted_question")"
      if [[ "$predicted_lc" != *"$expected_lc"* ]]; then
        clarify_ok=0
      fi
    fi

    if [[ "$clarify_ok" -eq 1 ]]; then
      pass_cases=$((pass_cases + 1))
      echo "pass: $case_id (decision=clarify)"
    else
      fail_cases=$((fail_cases + 1))
      echo "fail: $case_id" >&2
      echo "  expected decision: clarify" >&2
      echo "  predicted decision: ${predicted_decision:-none}" >&2
      echo "  expected clarify contains: ${expected_clarify_contains:-none}" >&2
      echo "  router_output: $route_json" >&2
    fi
    continue
  fi

  if [[ "$predicted_decision" != "route" ]]; then
    fail_cases=$((fail_cases + 1))
    echo "fail: $case_id" >&2
    echo "  expected decision: route" >&2
    echo "  predicted decision: ${predicted_decision:-none}" >&2
    echo "  router_output: $route_json" >&2
    continue
  fi

  predicted_primary="$(extract_primary_skill_from_json "$route_json")"
  predicted_primary_score="$(extract_primary_score_from_json "$route_json")"
  predicted_secondary_csv="$(extract_secondary_csv_from_json "$route_json")"

  primary_ok=0
  if [[ "$predicted_primary" == "$expected_primary" ]]; then
    primary_ok=1
  fi

  secondary_ok=1
  if [[ -n "$expected_secondary" ]]; then
    IFS=',' read -r -a expected_secondary_arr <<<"$expected_secondary"
    for expected_sid in "${expected_secondary_arr[@]}"; do
      if ! in_csv_list "$expected_sid" "$predicted_secondary_csv"; then
        secondary_ok=0
        break
      fi
    done
  fi

  if [[ "$primary_ok" -eq 1 && "$secondary_ok" -eq 1 ]]; then
    pass_cases=$((pass_cases + 1))
    echo "pass: $case_id (primary=$predicted_primary secondary=${predicted_secondary_csv:-none})"
  else
    fail_cases=$((fail_cases + 1))
    echo "fail: $case_id" >&2
    echo "  expected primary:   $expected_primary" >&2
    echo "  predicted primary:  $predicted_primary (score=$predicted_primary_score)" >&2
    echo "  expected secondary: ${expected_secondary:-none}" >&2
    echo "  predicted secondary:${predicted_secondary_csv:-none}" >&2
    echo "  query: $query" >&2
    echo "  router_output: $route_json" >&2
  fi
done < <(parse_eval_cases "$cases_file")

echo "routing eval summary: $pass_cases/$total_cases passed"

if [[ "$fail_cases" -ne 0 ]]; then
  exit 1
fi
