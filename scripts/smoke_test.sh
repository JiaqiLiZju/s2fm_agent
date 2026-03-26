#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_REGISTRY_FILE="$REPO_ROOT/registry/skills.yaml"
source "$REPO_ROOT/scripts/lib_registry.sh"
SKILL_IDS=()

usage() {
  cat <<'EOF'
Usage: smoke_test.sh [options]

Check that the repository layout, skill links, helper scripts, and optional software imports
look correct on a target machine.

Options:
  --registry FILE         Skill registry file. Default: <repo>/registry/skills.yaml
  --skills-dir DIR         Check linked/copied skills in this Codex skills directory.
  --alphagenome-python P   Run AlphaGenome import checks with this Python executable.
  --gpn-python P           Run GPN import checks with this Python executable.
  --nt-python P            Run classic NT / SegmentNT JAX import checks with this Python executable.
  --ntv3-python P          Run NTv3 Transformers import checks with this Python executable.
  --borzoi-python P        Run Borzoi import checks with this Python executable.
  --evo2-python P          Run Evo 2 import checks with this Python executable.
  -h, --help               Show this help message.
EOF
}

load_registry_skills() {
  SKILL_IDS=()
  while IFS= read -r skill_id; do
    if [[ -n "$skill_id" ]]; then
      SKILL_IDS+=("$skill_id")
    fi
  done < <(registry_list_ids "$registry_file")

  if [[ ${#SKILL_IDS[@]} -eq 0 ]]; then
    echo "error: no skills found in registry file: $registry_file" >&2
    exit 1
  fi
}

skills_dir=""
registry_file="$DEFAULT_REGISTRY_FILE"
alphagenome_python=""
gpn_python=""
nt_python=""
ntv3_python=""
borzoi_python=""
evo2_python=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)
      registry_file="$2"
      shift 2
      ;;
    --skills-dir)
      skills_dir="$2"
      shift 2
      ;;
    --alphagenome-python)
      alphagenome_python="$2"
      shift 2
      ;;
    --gpn-python)
      gpn_python="$2"
      shift 2
      ;;
    --nt-python)
      nt_python="$2"
      shift 2
      ;;
    --ntv3-python)
      ntv3_python="$2"
      shift 2
      ;;
    --borzoi-python)
      borzoi_python="$2"
      shift 2
      ;;
    --evo2-python)
      evo2_python="$2"
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

load_registry_skills

failures=0

check_exists() {
  local path="$1"
  local label="$2"
  if [[ -e "$path" ]]; then
    echo "ok: $label"
  else
    echo "fail: missing $label ($path)" >&2
    failures=$((failures + 1))
  fi
}

run_import_check() {
  local label="$1"
  local python_bin="$2"
  local code="$3"

  if [[ -z "$python_bin" ]]; then
    return 0
  fi

  if "$python_bin" -c "$code" >/dev/null; then
    echo "ok: $label imports"
  else
    echo "fail: $label imports" >&2
    failures=$((failures + 1))
  fi
}

skill_file_path() {
  local skill_id="$1"
  local rel_path="$2"
  local skill_path
  skill_path="$(registry_get_path "$registry_file" "$skill_id" || true)"
  if [[ -z "$skill_path" ]]; then
    skill_path="$skill_id"
  fi
  printf '%s/%s/%s\n' "$REPO_ROOT" "$skill_path" "$rel_path"
}

check_exists "$REPO_ROOT/README.md" "repo README"
check_exists "$REPO_ROOT/Makefile" "Makefile"
check_exists "$REPO_ROOT/agent/SYSTEM.md" "agent system spec"
check_exists "$REPO_ROOT/agent/ROUTING.md" "agent routing spec"
check_exists "$REPO_ROOT/agent/SAFETY.md" "agent safety spec"
check_exists "$REPO_ROOT/agent/agent.yaml" "agent metadata"
check_exists "$registry_file" "skill registry"
check_exists "$REPO_ROOT/registry/tags.yaml" "tag registry"
check_exists "$REPO_ROOT/registry/routing.yaml" "routing config"
check_exists "$REPO_ROOT/registry/task_contracts.yaml" "task contracts"
check_exists "$REPO_ROOT/playbooks/variant-effect/README.md" "variant-effect playbook"
check_exists "$REPO_ROOT/playbooks/embedding/README.md" "embedding playbook"
check_exists "$REPO_ROOT/playbooks/fine-tuning/README.md" "fine-tuning playbook"
check_exists "$REPO_ROOT/playbooks/track-prediction/README.md" "track-prediction playbook"
check_exists "$REPO_ROOT/playbooks/environment-setup/README.md" "environment-setup playbook"
check_exists "$REPO_ROOT/evals/routing/cases.yaml" "routing eval cases"
check_exists "$REPO_ROOT/scripts/link_skills.sh" "link_skills.sh"
check_exists "$REPO_ROOT/scripts/bootstrap.sh" "bootstrap.sh"
check_exists "$REPO_ROOT/scripts/provision_stack.sh" "provision_stack.sh"
check_exists "$REPO_ROOT/scripts/smoke_test.sh" "smoke_test.sh"
check_exists "$REPO_ROOT/scripts/lib_registry.sh" "registry helper library"
check_exists "$REPO_ROOT/scripts/validate_registry.sh" "validate_registry.sh"
check_exists "$REPO_ROOT/scripts/validate_skill_metadata.sh" "validate_skill_metadata.sh"
check_exists "$REPO_ROOT/scripts/validate_routing.sh" "validate_routing.sh"
check_exists "$REPO_ROOT/scripts/validate_migration_paths.sh" "validate_migration_paths.sh"
check_exists "$REPO_ROOT/scripts/route_query.sh" "route_query.sh"
check_exists "$REPO_ROOT/scripts/run_agent.sh" "run_agent.sh"
check_exists "$REPO_ROOT/scripts/agent_console.sh" "agent_console.sh"
check_exists "$(skill_file_path dnabert2 scripts/validate_dataset_csv.py)" "DNABERT2 dataset validator"
check_exists "$(skill_file_path dnabert2 scripts/recommend_max_length.py)" "DNABERT2 max-length helper"
check_exists "$(skill_file_path nucleotide-transformer-v3 scripts/check_valid_length.py)" "NTv3 helper script"
check_exists "$(skill_file_path nucleotide-transformer-v3 scripts/run_track_prediction.py)" "NTv3 track prediction script"
check_exists "$(skill_file_path segment-nt scripts/compute_rescaling_factor.py)" "SegmentNT helper script"

for skill in "${SKILL_IDS[@]}"; do
  skill_path="$(registry_get_path "$registry_file" "$skill" || true)"
  if [[ -z "$skill_path" ]]; then
    skill_path="$skill"
  fi

  check_exists "$REPO_ROOT/$skill_path/SKILL.md" "$skill SKILL.md"
  check_exists "$REPO_ROOT/$skill_path/skill.yaml" "$skill skill.yaml"
  check_exists "$REPO_ROOT/$skill_path/agents/openai.yaml" "$skill agents/openai.yaml"

  if [[ -n "$skills_dir" ]]; then
    check_exists "$skills_dir/$skill" "$skill installed in skills dir"
  fi
done

run_import_check \
  "alphagenome" \
  "$alphagenome_python" \
  'from alphagenome.data import genome; from alphagenome.models import dna_client'

run_import_check \
  "gpn" \
  "$gpn_python" \
  'import gpn.model; import gpn.star.model; from transformers import AutoModel; from transformers import AutoModelForMaskedLM'

run_import_check \
  "nt-jax-stack" \
  "$nt_python" \
  'from nucleotide_transformer.pretrained import get_pretrained_model, get_pretrained_segment_nt_model'

run_import_check \
  "ntv3-transformers" \
  "$ntv3_python" \
  'from transformers import AutoModel, AutoModelForMaskedLM, AutoTokenizer; import huggingface_hub; import torch'

run_import_check \
  "borzoi" \
  "$borzoi_python" \
  'import borzoi'

run_import_check \
  "evo2" \
  "$evo2_python" \
  'from evo2 import Evo2'

if python3 "$(skill_file_path nucleotide-transformer-v3 scripts/check_valid_length.py)" 32768 >/dev/null; then
  echo "ok: NTv3 helper script"
else
  echo "fail: NTv3 helper script" >&2
  failures=$((failures + 1))
fi

if python3 "$(skill_file_path segment-nt scripts/compute_rescaling_factor.py)" --sequence-length-bp 40008 >/dev/null; then
  echo "ok: SegmentNT helper script"
else
  echo "fail: SegmentNT helper script" >&2
  failures=$((failures + 1))
fi

route_output="$(bash "$REPO_ROOT/scripts/route_query.sh" --query "Use \$dnabert2 to validate my CSV schema." || true)"
if printf '%s\n' "$route_output" | grep -q '^primary: dnabert2 '; then
  echo "ok: route query primary selection"
else
  echo "fail: route query primary selection" >&2
  failures=$((failures + 1))
fi

route_clarify_output="$(bash "$REPO_ROOT/scripts/route_query.sh" --query "Train a model on fasta labels." || true)"
if printf '%s\n' "$route_clarify_output" | grep -q '^decision: clarify$'; then
  echo "ok: route query clarify behavior"
else
  echo "fail: route query clarify behavior" >&2
  failures=$((failures + 1))
fi

if bash "$REPO_ROOT/scripts/validate_routing.sh" >/dev/null; then
  echo "ok: validate routing eval"
else
  echo "fail: validate routing eval" >&2
  failures=$((failures + 1))
fi

if bash "$REPO_ROOT/scripts/validate_skill_metadata.sh" >/dev/null; then
  echo "ok: validate skill metadata"
else
  echo "fail: validate skill metadata" >&2
  failures=$((failures + 1))
fi

if bash "$REPO_ROOT/scripts/validate_migration_paths.sh" >/dev/null; then
  echo "ok: validate migration paths"
else
  echo "fail: validate migration paths" >&2
  failures=$((failures + 1))
fi

agent_output="$(bash "$REPO_ROOT/scripts/run_agent.sh" --query "Need NTv3 track prediction on hg38 human interval" || true)"
if printf '%s\n' "$agent_output" | grep -q '^primary_skill: nucleotide-transformer-v3$'; then
  echo "ok: run agent primary selection"
else
  echo "fail: run agent primary selection" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
  echo "smoke test failed with $failures issue(s)" >&2
  exit 1
fi

echo "smoke test passed"
