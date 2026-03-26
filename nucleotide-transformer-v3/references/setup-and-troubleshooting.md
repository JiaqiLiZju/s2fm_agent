# Setup And Troubleshooting

Use this file first when NTv3 code fails to install, import, or run.

## Recommended install path (tutorial-aligned)

Use a pinned Transformers 4.x stack to avoid accidental upgrades to 5.x:

```bash
pip install "transformers>=4.55,<5" "huggingface_hub>=0.23,<1" safetensors torch "numpy<2"
```

Optional notebook dependencies for track plotting and sequence download:

```bash
pip install pyfaidx requests seaborn matplotlib
```

## Authentication for gated repos (required)

NTv3 repos are gated. Authenticate before loading models.

Option 1: CLI login

```bash
huggingface-cli login
```

Option 2: Python login

```python
from huggingface_hub import login

login()
```

Option 3: pass token directly in code

```python
AutoModel.from_pretrained(..., token=HF_TOKEN, trust_remote_code=True)
```

Practical pattern:

- Prefer setting `HF_TOKEN` in the environment and reading it in scripts.
- Do not hardcode tokens in notebooks or committed files.

## Minimal import smoke check

```python
from transformers import AutoModel, AutoModelForMaskedLM, AutoTokenizer
import torch
import numpy
```

Minimal gated-model smoke check (HF path):

```python
import os
from transformers import AutoModel

token = os.environ["HF_TOKEN"]
model = AutoModel.from_pretrained(
    "InstaDeepAI/NTv3_100M_post",
    trust_remote_code=True,
    token=token,
)
print(model.config.num_downsamples)
print(model.config.keep_target_center_fraction)
```

## Common failure modes

1. `No module named transformers`
- Install the packages above in the same environment used for inference.

2. Hugging Face auth / 401 / gated model error
- Ensure account access to the NTv3 repo and authenticate (`huggingface-cli login`), or pass `token=...`.
- Verify the token is visible in the current process (`HF_TOKEN`) and has accepted gated-model terms.

3. Slow or unstable weight download
- Set `HF_HUB_DISABLE_XET=1` as a fallback when default transport is unreliable.

4. NumPy / PyTorch compatibility warnings
- If using `torch 2.2.x`, prefer `numpy<2`.
- Reinstall with pinned versions from the command above.

5. Legacy JAX-source install fails with `No matching distribution found for jax>=0.6.0`
- This usually means the environment is too old (for example Python 3.9).
- Switch to Python >=3.10 for source install, or use the Transformers tutorial path.

6. CUDA out-of-memory
- Use a smaller checkpoint first (`NTv3_8M_pre` or `NTv3_100M_post`).
- Use reduced precision (`bfloat16` or `float16`) on GPU.
- Reduce sequence length or batch size.
- Prefer single-example runs first for post-trained `32,768+` contexts before scaling batch size.

## Cold-start expectations

- First run may download hundreds of MB of model weights and remote code.
- CPU inference for 32,768 bp post-trained runs can take noticeably longer than GPU runs.
- For 32,768 bp inputs, expected post-trained output lengths are:
  - `logits`: full length (`32768`)
  - `bigwig_tracks_logits`: middle 37.5% (`12288`)
  - `bed_tracks_logits`: middle 37.5% (`12288`)

## Backend selection guidance

- Default: HF Transformers path for reliability and parity with official tutorials.
- Use JAX helper APIs only when a project already depends on `nucleotide_transformer_v3.pretrained`.
