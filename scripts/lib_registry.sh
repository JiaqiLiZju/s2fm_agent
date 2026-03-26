#!/usr/bin/env bash
set -euo pipefail

registry_require_file() {
  local registry_file="$1"
  if [[ ! -f "$registry_file" ]]; then
    echo "error: registry file not found: $registry_file" >&2
    return 1
  fi
}

yaml_get_scalar_field() {
  local yaml_file="$1"
  local field_name="$2"
  registry_require_file "$yaml_file"
  awk -v field="$field_name" '
    function cleaned(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/"/, "", s)
      return s
    }
    $0 ~ ("^[[:space:]]*" field ":[[:space:]]*") {
      v = $0
      sub("^[[:space:]]*" field ":[[:space:]]*", "", v)
      v = cleaned(v)
      print v
      exit
    }
  ' "$yaml_file"
}

yaml_get_list_field() {
  local yaml_file="$1"
  local field_name="$2"
  registry_require_file "$yaml_file"
  awk -v field="$field_name" '
    function cleaned(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/"/, "", s)
      return s
    }
    $0 ~ ("^[[:space:]]*" field ":[[:space:]]*$") {
      in_list = 1
      next
    }
    in_list && /^[[:space:]]*-[[:space:]]*/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      item = cleaned(item)
      if (item != "") {
        print item
      }
      next
    }
    in_list && /^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*/ {
      in_list = 0
      next
    }
  ' "$yaml_file"
}

registry_list_ids() {
  local registry_file="$1"
  registry_require_file "$registry_file"
  awk '
    /^[[:space:]]*-[[:space:]]id:[[:space:]]*/ {
      id = $0
      sub(/^[[:space:]]*-[[:space:]]id:[[:space:]]*/, "", id)
      gsub(/"/, "", id)
      print id
    }
  ' "$registry_file"
}

registry_get_path() {
  local registry_file="$1"
  local target_id="$2"
  registry_require_file "$registry_file"
  awk -v target="$target_id" '
    /^[[:space:]]*-[[:space:]]id:[[:space:]]*/ {
      current = $0
      sub(/^[[:space:]]*-[[:space:]]id:[[:space:]]*/, "", current)
      gsub(/"/, "", current)
      in_block = (current == target)
      next
    }
    in_block && /^[[:space:]]*path:[[:space:]]*/ {
      p = $0
      sub(/^[[:space:]]*path:[[:space:]]*/, "", p)
      gsub(/"/, "", p)
      print p
      exit
    }
  ' "$registry_file"
}

registry_get_list_field() {
  local registry_file="$1"
  local target_id="$2"
  local field_name="$3"
  registry_require_file "$registry_file"
  awk -v target="$target_id" -v field="$field_name" '
    function cleaned(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/"/, "", s)
      return s
    }
    /^[[:space:]]*-[[:space:]]id:[[:space:]]*/ {
      current = $0
      sub(/^[[:space:]]*-[[:space:]]id:[[:space:]]*/, "", current)
      current = cleaned(current)
      in_block = (current == target)
      in_list = 0
      next
    }
    in_block && $0 ~ ("^[[:space:]]*" field ":[[:space:]]*$") {
      in_list = 1
      next
    }
    in_block && in_list && /^[[:space:]]*-[[:space:]]*/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      item = cleaned(item)
      if (item != "") {
        print item
      }
      next
    }
    in_block && in_list && /^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*/ {
      in_list = 0
      next
    }
    in_block && in_list && /^[[:space:]]*#[^[:alnum:]]*/ {
      next
    }
  ' "$registry_file"
}

tag_registry_list_for_task() {
  local tags_file="$1"
  local task_name="$2"
  registry_require_file "$tags_file"
  awk -v target="$task_name" '
    function cleaned(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/"/, "", s)
      return s
    }
    /^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*$/ {
      key = $0
      sub(/^[[:space:]]*/, "", key)
      sub(/:[[:space:]]*$/, "", key)
      in_task = (key == target)
      next
    }
    in_task && /^[[:space:]]*-[[:space:]]*/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      item = cleaned(item)
      if (item != "") {
        print item
      }
      next
    }
    in_task && /^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*$/ {
      in_task = 0
      next
    }
  ' "$tags_file"
}

tag_registry_list_tasks() {
  local tags_file="$1"
  registry_require_file "$tags_file"
  awk '
    /^[[:space:]]*tags:[[:space:]]*$/ {
      in_tags = 1
      next
    }
    in_tags && /^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$/ {
      key = $0
      sub(/^[[:space:]]*/, "", key)
      sub(/:[[:space:]]*$/, "", key)
      print key
      next
    }
    in_tags && /^[^[:space:]]/ {
      in_tags = 0
      next
    }
  ' "$tags_file"
}

task_contract_list_required_inputs() {
  local contracts_file="$1"
  local task_name="$2"
  registry_require_file "$contracts_file"
  awk -v target="$task_name" '
    function cleaned(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      gsub(/"/, "", s)
      return s
    }
    /^[[:space:]]*contracts:[[:space:]]*$/ {
      in_contracts = 1
      next
    }
    in_contracts && $0 ~ ("^[[:space:]]{2}" target ":[[:space:]]*$") {
      in_task = 1
      in_required = 0
      next
    }
    in_contracts && in_task && /^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$/ {
      in_task = 0
      in_required = 0
      next
    }
    in_task && /^[[:space:]]{4}required_inputs:[[:space:]]*$/ {
      in_required = 1
      next
    }
    in_task && in_required && /^[[:space:]]{6}-[[:space:]]*/ {
      item = $0
      sub(/^[[:space:]]{6}-[[:space:]]*/, "", item)
      item = cleaned(item)
      if (item != "") {
        print item
      }
      next
    }
    in_task && in_required && /^[[:space:]]{4}[a-zA-Z0-9_-]+:[[:space:]]*/ {
      in_required = 0
      next
    }
  ' "$contracts_file"
}
