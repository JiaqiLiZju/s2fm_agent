#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.."; pwd)"
OUTPUT_DIR="$REPO_ROOT/case-study/variant-effect/borzoi_results"
MODEL_DIR="${BORZOI_MODEL_DIR:-$REPO_ROOT/case-study/borzoi_fast}"
PREFIX="borzoi_predict_variant_chr12_1000000"

PLOT_FILE="$OUTPUT_DIR/${PREFIX}_trackplot.png"
TSV_FILE="$OUTPUT_DIR/${PREFIX}_variant.tsv"
NPZ_FILE="$OUTPUT_DIR/${PREFIX}_tracks.npz"
RESULT_FILE="$OUTPUT_DIR/${PREFIX}_result.json"

mkdir -p "$OUTPUT_DIR"

required_assets=(
  "model0_best.h5"
  "params.json"
  "hg38/targets.txt"
)
for rel in "${required_assets[@]}"; do
  if [[ ! -f "$MODEL_DIR/$rel" ]]; then
    echo "error: missing Borzoi model asset: $MODEL_DIR/$rel" >&2
    exit 1
  fi
done

RUN_PREFIX=()
CONDA_BIN="${CONDA_BIN:-}"
if [[ -z "$CONDA_BIN" && -x "/Users/jiaqili/miniconda3_arm/bin/conda" ]]; then
  CONDA_BIN="/Users/jiaqili/miniconda3_arm/bin/conda"
fi
if [[ -z "$CONDA_BIN" ]] && command -v conda >/dev/null 2>&1; then
  CONDA_BIN="$(command -v conda)"
fi

if [[ -n "$CONDA_BIN" ]]; then
  if "$CONDA_BIN" run -n borzoi_py310 python - <<'PY' >/dev/null 2>&1
import borzoi, baskerville, tensorflow, pysam
print("imports_ok")
PY
  then
    RUN_PREFIX=("$CONDA_BIN" run -n borzoi_py310 python)
  fi
fi

if [[ ${#RUN_PREFIX[@]} -eq 0 ]]; then
  if [[ -x "/Users/jiaqili/miniconda3_arm/envs/borzoi_py310/bin/python" ]]; then
    RUN_PREFIX=("/Users/jiaqili/miniconda3_arm/envs/borzoi_py310/bin/python")
  fi
fi

if [[ ${#RUN_PREFIX[@]} -eq 0 ]]; then
  PYTHON_BIN="${PYTHON_BIN:-python3}"
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    PYTHON_BIN="python"
  fi
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "error: python interpreter not found (tried PYTHON_BIN/python3/python)." >&2
    exit 1
  fi
  RUN_PREFIX=("$PYTHON_BIN")
fi

echo "[borzoi-variant] Running Borzoi variant-effect case..."
"${RUN_PREFIX[@]}" "$REPO_ROOT/skills/borzoi-workflows/scripts/run_borzoi_predict.py" \
  --chrom chr12 \
  --position 1000000 \
  --alt G \
  --assembly hg38 \
  --model-dir "$MODEL_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --output-prefix "$PREFIX"

for f in "$PLOT_FILE" "$TSV_FILE" "$NPZ_FILE" "$RESULT_FILE"; do
  if [[ ! -s "$f" ]]; then
    echo "error: expected output not found: $f" >&2
    exit 1
  fi
done

echo "[borzoi-variant] Checkpoints:"
"${RUN_PREFIX[@]}" - "$RESULT_FILE" "$NPZ_FILE" <<'PY'
import json
import numpy as np
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
npz_path = pathlib.Path(sys.argv[2])
payload = json.loads(result_path.read_text(encoding="utf-8"))
npz = np.load(npz_path)

print(f"  status={payload.get('status')}")
print(f"  variant={payload.get('chrom')}:{payload.get('position_1based')} {payload.get('ref')}>{payload.get('alt')} ({payload.get('assembly')})")
print(f"  window=[{payload.get('window_start_0based')},{payload.get('window_end_0based')})")
print(f"  ref_preds_shape={tuple(npz['ref_preds'].shape)}")
print(f"  alt_preds_shape={tuple(npz['alt_preds'].shape)}")
print(f"  sad_shape={tuple(npz['sad'].shape)}")
print(f"  plot_path={payload.get('plot_path')}")
print(f"  result_json={result_path}")
PY

echo "[borzoi-variant] Completed."
