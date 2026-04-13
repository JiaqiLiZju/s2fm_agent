# Benchmark Section

This directory is the single management root for comparative benchmark work.

## Structure

- `tools/` — benchmark runner and mock/fixture tests
- `config/` — benchmark and participant configuration
- `prompts/` — baseline prompt variants (`direct`, `catalog-only`, `catalog+contracts`)
- `fixtures/` — mock OpenAI responses for regression tests
- `runs/` — timestamped benchmark run outputs
- `reports/manuscript/` — manuscript-ready benchmark tables and summaries

## Main Commands

```bash
make eval-benchmark
make test-eval-benchmark-mock
python3 benchmark/tools/eval_benchmark.py --participants s2f-agent --dry-run
```

## Notes

- Routing/groundedness/task-success case sources remain under `evals/` as shared ground-truth suites.
- Benchmark outputs are written to `benchmark/runs/` unless `--output-dir` is provided.
