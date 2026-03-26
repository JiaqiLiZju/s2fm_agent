#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY_FILE="$REPO_ROOT/registry/skills.yaml"
DEFAULT_MANIFEST_FILE="$REPO_ROOT/registry/migration_wave1.yaml"
DEFAULT_NAMESPACE="skills"
source "$REPO_ROOT/scripts/lib_registry.sh"

usage() {
  cat <<'EOF_USAGE'
Usage: validate_migration_paths.sh [options]

Validate that selected migrated skills resolve to skills/<id> in registry,
exist in the namespace directory, and no longer rely on root-level legacy paths.

Options:
  --registry FILE   Skill registry file. Default: <repo>/registry/skills.yaml
  --manifest FILE   Migration manifest. Default: <repo>/registry/migration_wave1.yaml
  --namespace DIR   Namespace directory. Default: skills
  -h, --help        Show this help message.
EOF_USAGE
}

registry_file="$DEFAULT_REGISTRY_FILE"
manifest_file="$DEFAULT_MANIFEST_FILE"
namespace_dir="$DEFAULT_NAMESPACE"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      registry_file="$2"
      shift 2
      ;;
    --manifest)
      manifest_file="$2"
      shift 2
      ;;
    --namespace)
      namespace_dir="$2"
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
registry_require_file "$manifest_file"

if [[ ! -d "$REPO_ROOT/$namespace_dir" ]]; then
  echo "fail: namespace directory missing ($REPO_ROOT/$namespace_dir)" >&2
  exit 1
fi

manifest_list_skills() {
  local file="$1"
  awk '
    /^[[:space:]]*skills:[[:space:]]*$/ {
      in_list = 1
      next
    }
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
      gsub(/"/, "", item)
      if (item != "") {
        print item
      }
      next
    }
    in_list && /^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*/ {
      in_list = 0
      next
    }
  ' "$file"
}

failures=0
total=0

while IFS= read -r skill_id; do
  [[ -z "$skill_id" ]] && continue
  total=$((total + 1))

  expected_path="$namespace_dir/$skill_id"
  registry_path="$(registry_get_path "$registry_file" "$skill_id" || true)"
  if [[ "$registry_path" != "$expected_path" ]]; then
    echo "fail: $skill_id registry path mismatch (expected '$expected_path', got '${registry_path:-<empty>}')" >&2
    failures=$((failures + 1))
    continue
  fi

  namespace_root="$REPO_ROOT/$expected_path"
  legacy_root="$REPO_ROOT/$skill_id"

  if [[ ! -d "$namespace_root" ]]; then
    echo "fail: $skill_id missing namespace dir ($namespace_root)" >&2
    failures=$((failures + 1))
    continue
  fi

  if [[ ! -f "$namespace_root/SKILL.md" ]]; then
    echo "fail: $skill_id missing SKILL.md under namespace ($namespace_root/SKILL.md)" >&2
    failures=$((failures + 1))
  fi

  if [[ ! -f "$namespace_root/skill.yaml" ]]; then
    echo "fail: $skill_id missing skill.yaml under namespace ($namespace_root/skill.yaml)" >&2
    failures=$((failures + 1))
  fi

  if [[ ! -f "$namespace_root/agents/openai.yaml" ]]; then
    echo "fail: $skill_id missing agents/openai.yaml under namespace ($namespace_root/agents/openai.yaml)" >&2
    failures=$((failures + 1))
  fi

  if [[ -e "$legacy_root" || -L "$legacy_root" ]]; then
    echo "fail: $skill_id legacy root path should be removed after migration ($legacy_root)" >&2
    failures=$((failures + 1))
    continue
  fi

  echo "ok: $skill_id migrated (namespace path active, legacy root path removed)"
done < <(manifest_list_skills "$manifest_file")

if [[ "$total" -eq 0 ]]; then
  echo "fail: no skills listed in migration manifest ($manifest_file)" >&2
  exit 1
fi

if [[ "$failures" -ne 0 ]]; then
  echo "migration path validation failed with $failures issue(s)" >&2
  exit 1
fi

echo "migration path validation passed for $total skill(s)"
