---
name: alphagenome-api
description: Build and debug AlphaGenome Python API workflows for genomic interval and variant-effect prediction, including API key setup, package installation, `dna_client` creation, selecting `requested_outputs`, adding `ontology_terms`, plotting results, and troubleshooting environment or response issues. Use when Codex needs to write, fix, explain, or review code and notebooks that use `alphagenome`, `dna_client`, `genome.Interval`, `genome.Variant`, AlphaGenome plotting helpers, or AlphaGenome API prediction workflows.
---

# AlphaGenome API

## Overview

Use this skill to produce conservative AlphaGenome Python snippets and notebook cells. Prefer the smallest runnable example that satisfies the request, and verify any symbol not grounded by the bundled references before relying on it.

## Follow This Workflow

1. Confirm setup.
- Confirm whether the user already has an AlphaGenome API key.
- Confirm the active Python version is `>=3.10` before installing `alphagenome`.
- Prefer a virtual environment before installing packages.
- Keep API credentials out of code and logs; prefer `ALPHAGENOME_API_KEY` from environment variables.
- Use the install flow in [references/quickstart.md](references/quickstart.md).

2. Build the client.
- Import `genome` from `alphagenome.data` and `dna_client` from `alphagenome.models`.
- Create the client with `dna_client.create(API_KEY)`.

3. Choose the prediction path.
- Use `genome.Variant` plus `model.predict_variant(...)` when the task compares reference and alternate alleles.
- Confirm the exact client method from the installed package or official docs before writing interval-only code, because the bundled source only demonstrates the variant path.
- For `model.predict_variant(...)`, use a supported interval width (currently `16384`, `131072`, `524288`, or `1048576` bp), then verify this list against the installed package when needed.
- Keep each interval at or below 1,000,000 base pairs.

4. Limit the request.
- Request only the output modalities the user needs.
- Add `ontology_terms` only when the selected assay depends on tissue or anatomical context.
- Surface every assumption about tissues, cell types, coordinates, and output types.

5. Present the result.
- Return a short runnable snippet first.
- Add plotting only when the user asks to inspect predictions or compare reference and alternate tracks.
- Use [references/workflows.md](references/workflows.md) for code patterns and [references/caveats.md](references/caveats.md) for limits and troubleshooting.

## Grounded API Surface

Treat the following names as grounded by the bundled AlphaGenome README:

- `genome.Interval`
- `genome.Variant`
- `dna_client.create`
- `model.predict_variant`
- `dna_client.OutputType.RNA_SEQ`
- `plot_components.plot`
- `plot_components.OverlaidTracks`
- `plot_components.VariantAnnotation`

Verify any other method, output enum, or helper against the installed package or official docs before using it. Do not invent modality names or helper functions.

## Response Style

- Prefer code the user can run immediately.
- Explain genomic assumptions in plain language.
- Call out when you are inferring a coordinate window, assay, or ontology term.
- Push back on large-batch workloads that exceed the README guidance.
- Redact secrets in examples and transcripts; never echo API keys.

## References

- Read [references/quickstart.md](references/quickstart.md) for installation and minimal setup.
- Read [references/workflows.md](references/workflows.md) for variant analysis patterns, plotting, and parameter selection.
- Read [references/caveats.md](references/caveats.md) for limits, licensing, and troubleshooting.
