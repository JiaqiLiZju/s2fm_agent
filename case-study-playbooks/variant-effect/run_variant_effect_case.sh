#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.."; pwd)"
VARIANT_DIR="$REPO_ROOT/case-study-playbooks/variant-effect"

CONDA_BIN="${CONDA_BIN:-/Users/jiaqili/miniconda3_arm/bin/conda}"
RUN_ID="${VARIANT_EFFECT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
VCF_PATH="${VARIANT_EFFECT_VCF_PATH:-$VARIANT_DIR/vcf/Test.geuvadis.vcf}"
ASSEMBLY="${VARIANT_EFFECT_ASSEMBLY:-hg38}"
SKILLS="${VARIANT_EFFECT_SKILLS:-alphagenome,borzoi,evo2,gpn}"
CONTINUE_ON_ERROR="${VARIANT_EFFECT_CONTINUE_ON_ERROR:-1}"

usage() {
  cat <<'EOF_USAGE'
Usage: run_variant_effect_case.sh [options]

Options:
  --vcf PATH                 Input VCF path (default: variant-effect/vcf/Test.geuvadis.vcf)
  --run-id ID                UTC run id, format YYYYMMDDTHHMMSSZ (default: now in UTC)
  --assembly NAME            Assembly for compatible tools (default: hg38)
  --skills LIST              Comma-separated: alphagenome,borzoi,evo2,gpn (default: all)
  --continue-on-error 0|1    Continue when a skill fails (default: 1)
  --conda-bin PATH           Conda binary path (default: /Users/jiaqili/miniconda3_arm/bin/conda)
  -h, --help                 Show this help
EOF_USAGE
}

log() {
  echo "[variant-effect-case] $*"
}

resolve_abs_path() {
  python3 - "$1" <<'PY'
import pathlib
import sys
print(pathlib.Path(sys.argv[1]).expanduser().resolve())
PY
}

load_env_file() {
  if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
  fi
}

require_conda() {
  if [[ -x "$CONDA_BIN" ]]; then
    return 0
  fi
  if command -v conda >/dev/null 2>&1; then
    CONDA_BIN="$(command -v conda)"
    return 0
  fi
  echo "error: conda not found; set --conda-bin or CONDA_BIN." >&2
  exit 1
}

normalize_skills() {
  local raw="$1"
  local normalized_raw=""
  local out=""
  local token=""

  normalized_raw="$(printf '%s\n' "$raw" | tr '+' ',')"
  IFS=',' read -r -a arr <<<"$normalized_raw"
  for token in "${arr[@]}"; do
    token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]' | xargs)"
    case "$token" in
      all) out="alphagenome,borzoi,evo2,gpn"; break ;;
      alphagenome|alphagenome-api) token="alphagenome" ;;
      borzoi|borzoi-workflows) token="borzoi" ;;
      evo2|evo2-inference) token="evo2" ;;
      gpn|gpn-models) token="gpn" ;;
      "") continue ;;
      *)
        echo "error: unsupported skill token: $token" >&2
        exit 1
        ;;
    esac

    if [[ -z "$out" ]]; then
      out="$token"
    elif [[ ",$out," != *",$token,"* ]]; then
      out="$out,$token"
    fi
  done

  if [[ -z "$out" ]]; then
    out="alphagenome,borzoi,evo2,gpn"
  fi
  printf '%s\n' "$out"
}

asset_set_ready() {
  local dir="$1"
  [[ -f "$dir/model0_best.h5" && -f "$dir/params.json" && -f "$dir/hg38/targets.txt" ]]
}

resolve_borzoi_model_dir() {
  local configured="${BORZOI_MODEL_DIR:-}"
  if [[ -n "$configured" ]]; then
    if asset_set_ready "$configured"; then
      BORZOI_MODEL_DIR_RESOLVED="$configured"
      return 0
    fi
    echo "error: BORZOI_MODEL_DIR missing required assets: $configured" >&2
    exit 1
  fi

  local candidate_a="$REPO_ROOT/case-study/borzoi_fast"
  local candidate_b="$REPO_ROOT/case-study-skills/borzoi_resouce"
  if asset_set_ready "$candidate_a"; then
    BORZOI_MODEL_DIR_RESOLVED="$candidate_a"
    return 0
  fi
  if asset_set_ready "$candidate_b"; then
    BORZOI_MODEL_DIR_RESOLVED="$candidate_b"
    return 0
  fi

  echo "error: no usable Borzoi model assets found." >&2
  echo "tried: $candidate_a and $candidate_b" >&2
  exit 1
}

archive_legacy_results() {
  local tmp_manifest="$1"
  printf 'source_dir\tstatus\tfiles_before\tfiles_after\tdestination_dir\n' > "$tmp_manifest"

  local entries=(
    "alphagenome|20260331T124340Z|alphagenome_results"
    "borzoi_results|20260414T183959Z|borzoi_results"
    "evo2_results|20260415T061711Z|evo2_results"
    "gpn_results|20260415T032617Z|gpn_results"
  )

  local entry src run_ts dst_name src_path dst_parent dst_path before_count after_count status
  for entry in "${entries[@]}"; do
    IFS='|' read -r src run_ts dst_name <<<"$entry"
    src_path="$VARIANT_DIR/$src"
    dst_parent="$VARIANT_DIR/$run_ts"
    dst_path="$dst_parent/$dst_name"
    before_count=0
    after_count=0

    if [[ -d "$src_path" ]]; then
      before_count="$(find "$src_path" -type f | wc -l | tr -d ' ')"
      mkdir -p "$dst_parent"
      if [[ -e "$dst_path" ]]; then
        echo "error: destination exists, refusing to overwrite: $dst_path" >&2
        exit 1
      fi
      mv "$src_path" "$dst_path"
      after_count="$(find "$dst_path" -type f | wc -l | tr -d ' ')"
      if [[ "$before_count" == "$after_count" ]]; then
        status="moved"
      else
        status="mismatch"
        echo "error: file count mismatch while archiving $src_path -> $dst_path" >&2
        exit 1
      fi
    else
      status="skipped_missing"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$src" "$status" "$before_count" "$after_count" "$dst_path" >> "$tmp_manifest"
  done
}

build_variants_manifest() {
  local vcf_abs="$1"
  local manifest_path="$2"
  local summary_path="$3"
  python3 - "$vcf_abs" "$manifest_path" "$summary_path" <<'PY'
import csv
import json
import pathlib
import sys
from datetime import datetime

vcf_path = pathlib.Path(sys.argv[1]).resolve()
manifest_path = pathlib.Path(sys.argv[2]).resolve()
summary_path = pathlib.Path(sys.argv[3]).resolve()

if not vcf_path.exists() or vcf_path.stat().st_size == 0:
    raise SystemExit(f"VCF missing or empty: {vcf_path}")

valid = {"A", "C", "G", "T"}
total = 0
snp = 0
non_snp = 0
rows = []

with vcf_path.open(encoding="utf-8") as handle:
    for line_no, raw in enumerate(handle, 1):
        if raw.startswith("#"):
            continue
        total += 1
        parts = raw.rstrip("\n").split("\t")
        if len(parts) < 5:
            continue
        chrom_raw = parts[0].strip()
        chrom = chrom_raw if chrom_raw.startswith("chr") else f"chr{chrom_raw}"
        position = int(parts[1].strip())
        vid = parts[2].strip() if len(parts) > 2 else "."
        ref = parts[3].strip().upper()
        alt = parts[4].strip().upper().split(",")[0]
        if len(ref) == 1 and len(alt) == 1 and ref in valid and alt in valid:
            snp += 1
            rows.append({
                "row_index": str(snp),
                "vid": vid,
                "chrom": chrom,
                "position": str(position),
                "ref": ref,
                "alt": alt,
                "variant_type": "SNP",
                "variant_spec": f"{chrom}:{position}:{ref}>{alt}",
                "vcf_line_number": str(line_no),
            })
        else:
            non_snp += 1

if snp == 0:
    raise SystemExit("No SNP variants found in VCF")

manifest_path.parent.mkdir(parents=True, exist_ok=True)
with manifest_path.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(
        handle,
        fieldnames=[
            "row_index",
            "vid",
            "chrom",
            "position",
            "ref",
            "alt",
            "variant_type",
            "variant_spec",
            "vcf_line_number",
        ],
        delimiter="\t",
    )
    writer.writeheader()
    writer.writerows(rows)

summary = {
    "vcf_path": str(vcf_path),
    "total_records": total,
    "snp_records": snp,
    "non_snp_records": non_snp,
    "generated_at_utc": datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "variants_manifest": str(manifest_path),
}
summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(json.dumps(summary, indent=2))
PY
}

write_alphagenome_summary() {
  local result_tsv="$1"
  local summary_json="$2"
  local vcf_abs="$3"
  local output_dir="$4"
  local assembly="$5"
  local command_rc="$6"
  python3 - "$result_tsv" "$summary_json" "$vcf_abs" "$output_dir" "$assembly" "$command_rc" <<'PY'
import csv
import datetime
import json
import pathlib
import sys

result_tsv = pathlib.Path(sys.argv[1]).resolve()
summary_json = pathlib.Path(sys.argv[2]).resolve()
vcf_abs = str(pathlib.Path(sys.argv[3]).resolve())
output_dir = str(pathlib.Path(sys.argv[4]).resolve())
assembly = sys.argv[5]
command_rc = int(sys.argv[6])

rows = []
run_time_non_empty = 0
status_counts = {}

if result_tsv.exists() and result_tsv.stat().st_size > 0:
    with result_tsv.open(encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        rows = list(reader)
    for row in rows:
        status = row.get("status", "")
        status_counts[status] = status_counts.get(status, 0) + 1
        if row.get("run_time_utc", "").strip():
            run_time_non_empty += 1

failed_count = len([r for r in rows if r.get("status") != "success"])
payload = {
    "skill_id": "alphagenome-api",
    "task": "variant-effect-batch",
    "assembly": assembly,
    "input_vcf": vcf_abs,
    "output_dir": output_dir,
    "result_tsv": str(result_tsv),
    "command_exit_code": command_rc,
    "total_variants": len(rows),
    "succeeded_count": len(rows) - failed_count,
    "failed_count": failed_count,
    "status_counts": status_counts,
    "run_time_utc_non_empty_count": run_time_non_empty,
    "status": (
        "completed"
        if command_rc == 0 and failed_count == 0
        else "completed_with_failures"
        if rows
        else "failed_no_output"
    ),
    "generated_at_utc": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
}
summary_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
print(json.dumps(payload, indent=2))
PY
}

write_borzoi_summary() {
  local manifest="$1"
  local summary="$2"
  local output_dir="$3"
  local model_dir="$4"
  local assembly="$5"
  python3 - "$manifest" "$summary" "$output_dir" "$model_dir" "$assembly" <<'PY'
import csv
import datetime
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1]).resolve()
summary = pathlib.Path(sys.argv[2]).resolve()
output_dir = str(pathlib.Path(sys.argv[3]).resolve())
model_dir = str(pathlib.Path(sys.argv[4]).resolve())
assembly = sys.argv[5]

with manifest.open(encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))

failed = [r for r in rows if r.get("status") != "success"]
payload = {
    "skill_id": "borzoi-workflows",
    "task": "variant-effect-batch",
    "assembly": assembly,
    "output_dir": output_dir,
    "model_dir": model_dir,
    "manifest": str(manifest),
    "total_variants": len(rows),
    "succeeded_count": len(rows) - len(failed),
    "failed_count": len(failed),
    "status": "completed" if not failed else "completed_with_failures",
    "generated_at_utc": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "results": rows,
}
summary.write_text(json.dumps(payload, indent=2), encoding="utf-8")
print(json.dumps(payload, indent=2))
PY
}

write_gpn_summaries() {
  local manifest="$1"
  local summary_json="$2"
  local summary_tsv="$3"
  local output_dir="$4"
  python3 - "$manifest" "$summary_json" "$summary_tsv" "$output_dir" <<'PY'
import csv
import datetime
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1]).resolve()
summary_json = pathlib.Path(sys.argv[2]).resolve()
summary_tsv = pathlib.Path(sys.argv[3]).resolve()
output_dir = str(pathlib.Path(sys.argv[4]).resolve())

with manifest.open(encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))

summary_tsv.parent.mkdir(parents=True, exist_ok=True)
with summary_tsv.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, delimiter="\t")
    writer.writerow([
        "chrom",
        "position",
        "ref",
        "alt",
        "llr_fwd",
        "llr_rev",
        "llr_mean",
        "model",
        "genome",
        "result_json",
        "run_time_utc",
        "status",
        "error",
    ])
    for row in rows:
        llr_fwd = ""
        llr_rev = ""
        llr_mean = ""
        model = ""
        genome = ""
        run_time_utc = row.get("run_time_utc", "")
        result_json = row.get("result_json", "").strip()
        status = row.get("status", "")
        error = row.get("error", "")
        if status == "success" and result_json:
            path = pathlib.Path(result_json)
            if path.exists():
                payload = json.loads(path.read_text(encoding="utf-8"))
                llr_fwd = payload.get("llr_fwd", "")
                llr_rev = payload.get("llr_rev", "")
                llr_mean = payload.get("llr_mean", "")
                model = payload.get("model", "")
                genome = payload.get("genome", "")
                if not run_time_utc:
                    run_time_utc = datetime.datetime.utcfromtimestamp(
                        path.stat().st_mtime
                    ).replace(microsecond=0).isoformat() + "Z"
        writer.writerow([
            row.get("chrom", ""),
            row.get("position", ""),
            row.get("ref", ""),
            row.get("alt", ""),
            llr_fwd,
            llr_rev,
            llr_mean,
            model,
            genome,
            result_json,
            run_time_utc,
            status,
            error,
        ])

failed = [r for r in rows if r.get("status") != "success"]
payload = {
    "skill_id": "gpn-models",
    "task": "variant-effect-batch",
    "output_dir": output_dir,
    "manifest": str(manifest),
    "summary_tsv": str(summary_tsv),
    "total_variants": len(rows),
    "succeeded_count": len(rows) - len(failed),
    "failed_count": len(failed),
    "status": "completed" if not failed else "completed_with_failures",
    "generated_at_utc": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "results": rows,
}
summary_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
print(json.dumps(payload, indent=2))
PY
}

write_case_summary() {
  local case_manifest="$1"
  local summary_path="$2"
  local run_root="$3"
  local run_id="$4"
  local vcf_abs="$5"
  local variants_manifest="$6"
  python3 - "$case_manifest" "$summary_path" "$run_root" "$run_id" "$vcf_abs" "$variants_manifest" <<'PY'
import csv
import datetime
import json
import pathlib
import sys

case_manifest = pathlib.Path(sys.argv[1]).resolve()
summary_path = pathlib.Path(sys.argv[2]).resolve()
run_root = str(pathlib.Path(sys.argv[3]).resolve())
run_id = sys.argv[4]
vcf_abs = str(pathlib.Path(sys.argv[5]).resolve())
variants_manifest = pathlib.Path(sys.argv[6]).resolve()

with case_manifest.open(encoding="utf-8") as handle:
    skills = list(csv.DictReader(handle, delimiter="\t"))

with variants_manifest.open(encoding="utf-8") as handle:
    total_variants = sum(1 for _ in handle) - 1

failed = [r for r in skills if r.get("status") != "success"]
payload = {
    "task": "variant-effect-case",
    "run_id": run_id,
    "run_root": run_root,
    "input_vcf": vcf_abs,
    "variants_manifest": str(variants_manifest),
    "total_variants": total_variants,
    "total_skills": len(skills),
    "succeeded_skills": len(skills) - len(failed),
    "failed_skills": len(failed),
    "status": "completed" if not failed else "completed_with_failures",
    "generated_at_utc": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "skills": skills,
}
summary_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
print(json.dumps(payload, indent=2))
PY
}

annotate_evo2_summary() {
  local summary_json="$1"
  local attempts_tsv="$2"
  local windows_csv="$3"
  local proxy_retry="$4"
  python3 - "$summary_json" "$attempts_tsv" "$windows_csv" "$proxy_retry" <<'PY'
import csv
import json
import pathlib
import sys

summary_json = pathlib.Path(sys.argv[1]).resolve()
attempts_tsv = pathlib.Path(sys.argv[2]).resolve()
windows_csv = sys.argv[3]
proxy_retry = sys.argv[4]

payload = {}
if summary_json.exists() and summary_json.stat().st_size > 0:
    payload = json.loads(summary_json.read_text(encoding="utf-8"))

attempts = []
if attempts_tsv.exists() and attempts_tsv.stat().st_size > 0:
    with attempts_tsv.open(encoding="utf-8") as handle:
        attempts = list(csv.DictReader(handle, delimiter="\t"))

window_ladder = [int(x) for x in windows_csv.split(",") if x.strip().isdigit()]
final_window = None
for row in attempts:
    if str(row.get("failed_count", "")).strip() == "0":
        w = row.get("window_len", "").strip()
        if w.isdigit():
            final_window = int(w)
            break

if final_window is None and attempts:
    w = attempts[-1].get("window_len", "").strip()
    if w.isdigit():
        final_window = int(w)

payload["adaptive_window_attempts"] = attempts
payload["window_ladder"] = window_ladder
payload["proxy_retry_enabled"] = proxy_retry == "1"
payload["effective_window_len"] = final_window
payload["window_len"] = final_window
payload["downgrade_applied"] = bool(window_ladder and final_window is not None and final_window != window_ladder[0])
payload["downgrade_from_window_len"] = window_ladder[0] if payload["downgrade_applied"] else None
payload["downgrade_to_window_len"] = final_window if payload["downgrade_applied"] else None

summary_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
print(json.dumps({
    "summary_json": str(summary_json),
    "effective_window_len": final_window,
    "downgrade_applied": payload["downgrade_applied"],
}, indent=2))
PY
}

run_alphagenome() {
  local run_root="$1"
  local vcf_abs="$2"
  local case_manifest="$3"
  local output_dir="$run_root/alphagenome_results"
  local skill_log="$run_root/logs/alphagenome_case.log"
  local output_tsv="$output_dir/$(basename "${vcf_abs%.vcf}")_tissues.tsv"
  local summary_json="$output_dir/alphagenome_variant_batch_summary.json"

  set +e
  "$CONDA_BIN" run -n alphagenome-py310 python "$REPO_ROOT/skills/alphagenome-api/scripts/run_alphagenome_vcf_batch.py" \
    --input "$vcf_abs" \
    --assembly "$ASSEMBLY" \
    --output-dir "$output_dir" \
    --non-interactive \
    --request-timeout-sec 120 \
    2>&1 | tee "$skill_log"
  local rc=${PIPESTATUS[0]}
  set -e

  write_alphagenome_summary "$output_tsv" "$summary_json" "$vcf_abs" "$output_dir" "$ASSEMBLY" "$rc"

  local status="success"
  if [[ "$rc" -ne 0 ]]; then
    status="failed"
  fi
  printf 'alphagenome\t%s\t%s\t%s\t%s\n' "$status" "$rc" "$skill_log" "$summary_json" >> "$case_manifest"
  return "$rc"
}

run_borzoi() {
  local run_root="$1"
  local variants_manifest="$2"
  local case_manifest="$3"
  local output_dir="$run_root/borzoi_results"
  local skill_log="$run_root/logs/borzoi_case.log"
  local batch_manifest="$output_dir/borzoi_variant_batch_manifest.tsv"
  local summary_json="$output_dir/borzoi_variant_batch_summary.json"

  resolve_borzoi_model_dir
  local model_dir_abs
  model_dir_abs="$(resolve_abs_path "$BORZOI_MODEL_DIR_RESOLVED")"
  : > "$skill_log"

  printf 'row_index\tchrom\tposition\tref\talt\tvariant_spec\texit_code\tstatus\tplot\ttsv\tnpz\tresult_json\tlog\terror\n' > "$batch_manifest"

  local row_index chrom position ref alt variant_spec prefix rc status
  local plot_file tsv_file npz_file result_file log_file

  while IFS=$'\t' read -r row_index _vid chrom position ref alt _vtype variant_spec _line; do
    [[ "$row_index" == "row_index" ]] && continue
    prefix="borzoi_variant-effect_${chrom}_${position}_${ref}_to_${alt}"
    plot_file="$output_dir/${prefix}_trackplot.png"
    tsv_file="$output_dir/${prefix}_variant.tsv"
    npz_file="$output_dir/${prefix}_tracks.npz"
    result_file="$output_dir/${prefix}_result.json"
    log_file="$output_dir/borzoi_${chrom}_${position}_${ref}_to_${alt}.log"

    {
      log "RUN borzoi variant=$variant_spec"
      set +e
      "$CONDA_BIN" run -n borzoi_py310 python "$REPO_ROOT/skills/borzoi-workflows/scripts/run_borzoi_predict.py" \
        --variant-spec "$variant_spec" \
        --assembly "$ASSEMBLY" \
        --model-dir "$model_dir_abs" \
        --output-dir "$output_dir" \
        --output-prefix "$prefix" \
        2>&1 | tee "$log_file"
      rc=${PIPESTATUS[0]}
      set -e
      status="failed"
      if [[ "$rc" -eq 0 && -s "$plot_file" && -s "$tsv_file" && -s "$npz_file" && -s "$result_file" ]]; then
        status="success"
      fi
      local err_msg=""
      if [[ "$status" != "success" ]]; then
        err_msg="borzoi command failed or expected artifact missing"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$row_index" "$chrom" "$position" "$ref" "$alt" "$variant_spec" \
        "$rc" "$status" "$plot_file" "$tsv_file" "$npz_file" "$result_file" "$log_file" "$err_msg" >> "$batch_manifest"
      log "DONE borzoi variant=$variant_spec status=$status rc=$rc"
    } >> "$skill_log" 2>&1
  done < "$variants_manifest"

  write_borzoi_summary "$batch_manifest" "$summary_json" "$output_dir" "$model_dir_abs" "$ASSEMBLY"

  local failed
  failed="$(awk -F'\t' 'NR>1 && $8!="success"{c++} END{print c+0}' "$batch_manifest")"
  local rc=0
  local status="success"
  if [[ "$failed" -gt 0 ]]; then
    rc=1
    status="failed"
  fi
  printf 'borzoi\t%s\t%s\t%s\t%s\n' "$status" "$rc" "$skill_log" "$summary_json" >> "$case_manifest"
  return "$rc"
}

run_gpn() {
  local run_root="$1"
  local variants_manifest="$2"
  local case_manifest="$3"
  local output_dir="$run_root/gpn_results"
  local skill_log="$run_root/logs/gpn_case.log"
  local batch_manifest="$output_dir/gpn_variant_batch_manifest.tsv"
  local summary_json="$output_dir/gpn_variant_batch_summary.json"
  local summary_tsv="$output_dir/gpn_variant_effect_summary.tsv"

  : > "$skill_log"
  printf 'row_index\tchrom\tposition\tref\talt\texit_code\tstatus\tresult_json\trun_time_utc\tlog\terror\n' > "$batch_manifest"

  local row_index chrom position ref alt variant_spec rc status result_json log_file err_msg run_time_utc
  while IFS=$'\t' read -r row_index _vid chrom position ref alt _vtype variant_spec _line; do
    [[ "$row_index" == "row_index" ]] && continue
    result_json="$output_dir/gpn_variant-effect_${chrom}_${position}_${ref}_to_${alt}_result.json"
    log_file="$output_dir/gpn_${chrom}_${position}_${ref}_to_${alt}.log"
    rc=0
    status="failed"
    err_msg=""
    run_time_utc=""

    {
      log "RUN gpn variant=$variant_spec"
      set +e
      "$CONDA_BIN" run -n gpn-py310 python "$REPO_ROOT/skills/gpn-models/references/predict_variant_single_site.py" \
        --genome "$ASSEMBLY" \
        --chrom "$chrom" \
        --pos "$position" \
        --alt "$alt" \
        --output-json "$result_json" \
        2>&1 | tee "$log_file"
      rc=${PIPESTATUS[0]}
      set -e
      if [[ "$rc" -eq 0 && -s "$result_json" ]]; then
        status="success"
        run_time_utc="$(date -u -r "$result_json" +%Y-%m-%dT%H:%M:%SZ)"
      else
        err_msg="gpn command failed or expected result missing"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$row_index" "$chrom" "$position" "$ref" "$alt" "$rc" "$status" "$result_json" "$run_time_utc" "$log_file" "$err_msg" >> "$batch_manifest"
      log "DONE gpn variant=$variant_spec status=$status rc=$rc"
    } >> "$skill_log" 2>&1
  done < "$variants_manifest"

  write_gpn_summaries "$batch_manifest" "$summary_json" "$summary_tsv" "$output_dir"

  local failed
  failed="$(awk -F'\t' 'NR>1 && $7!="success"{c++} END{print c+0}' "$batch_manifest")"
  local rc=0
  local status="success"
  if [[ "$failed" -gt 0 ]]; then
    rc=1
    status="failed"
  fi
  printf 'gpn\t%s\t%s\t%s\t%s\n' "$status" "$rc" "$skill_log" "$summary_json" >> "$case_manifest"
  return "$rc"
}

run_evo2() {
  local run_root="$1"
  local variants_manifest="$2"
  local case_manifest="$3"
  local output_dir="$run_root/evo2_results"
  local skill_log="$run_root/logs/evo2_case.log"
  local batch_manifest="$output_dir/evo2_variant_batch_manifest.tsv"
  local summary_json="$output_dir/evo2_variant_batch_summary.json"
  local windows_csv="${EVO2_VARIANT_WINDOW_LADDER:-2048,1024,512,256}"
  local forward_timeout="${EVO2_VARIANT_FORWARD_TIMEOUT_SEC:-30}"
  local forward_attempts="${EVO2_VARIANT_FORWARD_MAX_ATTEMPTS:-2}"
  local proxy_retry="${EVO2_VARIANT_PROXY_RETRY:-1}"
  local attempts_tsv="$output_dir/evo2_window_attempts.tsv"
  local window=""
  local failed_count=""
  local rc=1
  local status="failed"
  local attempt_index=0

  : > "$skill_log"
  printf 'attempt_index\twindow_len\tproxy\texit_code\tfailed_count\n' > "$attempts_tsv"

  for window in $(printf '%s\n' "$windows_csv" | tr ',' ' '); do
    [[ -z "$window" ]] && continue
    if [[ ! "$window" =~ ^[0-9]+$ ]]; then
      continue
    fi

    {
      log "RUN evo2 window_len=$window proxy=off"
      set +e
      "$CONDA_BIN" run -n evo2-py311 python "$VARIANT_DIR/run_evo2_variant_batch.py" \
        --variant-manifest "$variants_manifest" \
        --output-dir "$output_dir" \
        --manifest-out "$batch_manifest" \
        --summary-json "$summary_json" \
        --window-len "$window" \
        --continue-on-error 1 \
        --forward-timeout-sec "$forward_timeout" \
        --forward-max-attempts "$forward_attempts" \
        2>&1 | tee -a "$skill_log"
      rc=${PIPESTATUS[0]}
      set -e
      failed_count="$(python3 - "$summary_json" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
if not p.exists() or p.stat().st_size==0:
    print(-1)
else:
    d=json.loads(p.read_text(encoding='utf-8'))
    print(int(d.get('failed_count', -1)))
PY
)"
      log "DONE evo2 window_len=$window proxy=off rc=$rc failed_count=$failed_count"
    } >> "$skill_log" 2>&1
    attempt_index=$((attempt_index + 1))
    printf '%s\t%s\t%s\t%s\t%s\n' "$attempt_index" "$window" "off" "$rc" "$failed_count" >> "$attempts_tsv"

    if [[ "$failed_count" == "0" ]]; then
      status="success"
      rc=0
      break
    fi

    if [[ "$proxy_retry" == "1" ]]; then
      {
        log "RUN evo2 window_len=$window proxy=on"
        set +e
        env \
          http_proxy="http://127.0.0.1:7890" \
          https_proxy="http://127.0.0.1:7890" \
          grpc_proxy="http://127.0.0.1:7890" \
          "$CONDA_BIN" run -n evo2-py311 python "$VARIANT_DIR/run_evo2_variant_batch.py" \
            --variant-manifest "$variants_manifest" \
            --output-dir "$output_dir" \
            --manifest-out "$batch_manifest" \
            --summary-json "$summary_json" \
            --window-len "$window" \
            --continue-on-error 1 \
            --forward-timeout-sec "$forward_timeout" \
            --forward-max-attempts "$forward_attempts" \
            2>&1 | tee -a "$skill_log"
        rc=${PIPESTATUS[0]}
        set -e
        failed_count="$(python3 - "$summary_json" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
if not p.exists() or p.stat().st_size==0:
    print(-1)
else:
    d=json.loads(p.read_text(encoding='utf-8'))
    print(int(d.get('failed_count', -1)))
PY
)"
        log "DONE evo2 window_len=$window proxy=on rc=$rc failed_count=$failed_count"
      } >> "$skill_log" 2>&1
      attempt_index=$((attempt_index + 1))
      printf '%s\t%s\t%s\t%s\t%s\n' "$attempt_index" "$window" "on" "$rc" "$failed_count" >> "$attempts_tsv"

      if [[ "$failed_count" == "0" ]]; then
        status="success"
        rc=0
        break
      fi
    fi
  done

  if [[ "$status" != "success" ]]; then
    rc=1
  fi
  annotate_evo2_summary "$summary_json" "$attempts_tsv" "$windows_csv" "$proxy_retry"
  printf 'evo2\t%s\t%s\t%s\t%s\n' "$status" "$rc" "$skill_log" "$summary_json" >> "$case_manifest"
  return "$rc"
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vcf)
        VCF_PATH="$2"
        shift 2
        ;;
      --run-id)
        RUN_ID="$2"
        shift 2
        ;;
      --assembly)
        ASSEMBLY="$2"
        shift 2
        ;;
      --skills)
        SKILLS="$2"
        shift 2
        ;;
      --continue-on-error)
        CONTINUE_ON_ERROR="$2"
        shift 2
        ;;
      --conda-bin)
        CONDA_BIN="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ ! "$RUN_ID" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
    echo "error: --run-id must match YYYYMMDDTHHMMSSZ, got: $RUN_ID" >&2
    exit 1
  fi
  if [[ "$CONTINUE_ON_ERROR" != "0" && "$CONTINUE_ON_ERROR" != "1" ]]; then
    echo "error: --continue-on-error must be 0 or 1" >&2
    exit 1
  fi

  require_conda
  load_env_file

  local selected_skills
  selected_skills="$(normalize_skills "$SKILLS")"
  local vcf_abs
  vcf_abs="$(resolve_abs_path "$VCF_PATH")"
  if [[ ! -s "$vcf_abs" ]]; then
    echo "error: VCF missing or empty: $vcf_abs" >&2
    exit 1
  fi

  local archive_tmp
  archive_tmp="$(mktemp "${TMPDIR:-/tmp}/variant_archive.XXXXXX.tsv")"
  archive_legacy_results "$archive_tmp"

  local run_root="$VARIANT_DIR/$RUN_ID"
  if [[ -e "$run_root" ]]; then
    echo "error: run root already exists: $run_root" >&2
    exit 1
  fi
  mkdir -p "$run_root"/{alphagenome_results,borzoi_results,evo2_results,gpn_results,logs}

  mv "$archive_tmp" "$run_root/logs/history_archive_manifest.tsv"

  local variants_manifest="$run_root/logs/variants_manifest.tsv"
  local variants_summary="$run_root/logs/variants_manifest_summary.json"
  build_variants_manifest "$vcf_abs" "$variants_manifest" "$variants_summary"

  local case_manifest="$run_root/logs/variant_effect_case_manifest.tsv"
  printf 'skill\tstatus\texit_code\tlog\tsummary_json\n' > "$case_manifest"

  log "run_id=$RUN_ID"
  log "run_root=$run_root"
  log "input_vcf=$vcf_abs"
  log "skills=$selected_skills"
  log "assembly=$ASSEMBLY"

  local overall_rc=0
  local skill_rc=0

  if [[ ",$selected_skills," == *",alphagenome,"* ]]; then
    log "START skill=alphagenome"
    if run_alphagenome "$run_root" "$vcf_abs" "$case_manifest"; then
      skill_rc=0
    else
      skill_rc=$?
    fi
    log "DONE skill=alphagenome rc=$skill_rc"
    if [[ "$skill_rc" -ne 0 && "$CONTINUE_ON_ERROR" == "0" ]]; then
      overall_rc="$skill_rc"
    fi
  fi

  if [[ ",$selected_skills," == *",borzoi,"* ]]; then
    log "START skill=borzoi"
    if run_borzoi "$run_root" "$variants_manifest" "$case_manifest"; then
      skill_rc=0
    else
      skill_rc=$?
    fi
    log "DONE skill=borzoi rc=$skill_rc"
    if [[ "$skill_rc" -ne 0 && "$CONTINUE_ON_ERROR" == "0" && "$overall_rc" -eq 0 ]]; then
      overall_rc="$skill_rc"
    fi
  fi

  if [[ ",$selected_skills," == *",evo2,"* ]]; then
    log "START skill=evo2"
    if run_evo2 "$run_root" "$variants_manifest" "$case_manifest"; then
      skill_rc=0
    else
      skill_rc=$?
    fi
    log "DONE skill=evo2 rc=$skill_rc"
    if [[ "$skill_rc" -ne 0 && "$CONTINUE_ON_ERROR" == "0" && "$overall_rc" -eq 0 ]]; then
      overall_rc="$skill_rc"
    fi
  fi

  if [[ ",$selected_skills," == *",gpn,"* ]]; then
    log "START skill=gpn"
    if run_gpn "$run_root" "$variants_manifest" "$case_manifest"; then
      skill_rc=0
    else
      skill_rc=$?
    fi
    log "DONE skill=gpn rc=$skill_rc"
    if [[ "$skill_rc" -ne 0 && "$CONTINUE_ON_ERROR" == "0" && "$overall_rc" -eq 0 ]]; then
      overall_rc="$skill_rc"
    fi
  fi

  write_case_summary \
    "$case_manifest" \
    "$run_root/variant_effect_case_summary.json" \
    "$run_root" \
    "$RUN_ID" \
    "$vcf_abs" \
    "$variants_manifest"

  # Always emit unified cross-skill wide report and per-skill standardized records.
  python3 "$VARIANT_DIR/build_unified_variant_effect_report.py" --run-root "$run_root"
  python3 "$VARIANT_DIR/build_skill_variant_effect_reports.py" --run-root "$run_root"

  if [[ "$CONTINUE_ON_ERROR" == "1" ]]; then
    return 0
  fi
  return "$overall_rc"
}

main "$@"
