# Scripts Reference

All 19 scripts in `scripts/`. For step-by-step usage in task context see `playbooks/`.

## Script Groups

### Setup and Provisioning

| Script | Purpose | Key flags |
|---|---|---|
| `bootstrap.sh` | One-step installer: links skills + provisions core stacks (alphagenome, gpn, nt-jax) + smoke test | `--persistent-root`, `--with-evo2-light`, `--with-borzoi`, `--with-ntv3-hf`, `--prefetch-models`, `--skip-smoke` |
| `provision_stack.sh` | Provision one software stack on a target machine | stack name: `alphagenome`, `gpn`, `nt-jax`, `ntv3-hf`, `borzoi`, `evo2-light`, `evo2-full` |
| `link_skills.sh` | Symlink (or copy) packaged skills into the Codex skills directory | `--skills-dir`, `--include-disabled`, `--force`, `--copy`, `--list` |
| `prefetch_models.sh` | Download Hugging Face model snapshots to a persistent cache | `--model ID`, `--hf-token`, `--cache-dir` |
| `clean_runtime.sh` | Remove deploy root, persistent root, and repo temp files (`output/`, `__pycache__/`, etc.) | `--deploy-root`, `--persistent-root`, `--dry-run` |

### Runtime and Orchestration

| Script | Purpose | Key flags |
|---|---|---|
| `route_query.sh` | Route a query to a primary skill + confidence; no plan generated | `--query`, `--task`, `--format json\|text`, `--top-k`, `--include-disabled` |
| `run_agent.sh` | Full orchestration: routing + input validation + normalized plan | `--query`, `--task`, `--format json\|text`, `--contracts`, `--output-contracts`, `--recovery`, `--input-schema` |
| `execute_plan.sh` | Dry-run or execute `plan.runnable_steps` from `run_agent.sh` output | `--query`, `--task`, `--run` (default: dry-run), `--format json\|text` |
| `agent_console.sh` | Interactive REPL that pipes each line to `run_agent.sh` | none |

### Validation and Evals

| Script | Purpose | Key flags |
|---|---|---|
| `validate_registry.sh` | Check each skill in registry resolves to a real path with required files | `--registry`, `--include-disabled` |
| `validate_registry_tracking.sh` | Check enabled skills are tracked by git and not ignored | `--registry`, `--include-disabled` |
| `validate_skill_metadata.sh` | Check `skill.yaml` completeness and consistency with registry | `--registry`, `--tags`, `--include-disabled` |
| `validate_input_contracts.sh` | Check task contract keys exist in canonical input schema and skill metadata | `--registry`, `--contracts`, `--input-schema`, `--include-disabled` |
| `validate_migration_paths.sh` | Check migrated skills resolve under `skills/` and have no legacy root-level paths | `--registry`, `--manifest`, `--namespace` |
| `validate_routing.sh` | Run `evals/routing/cases.yaml` against the live router; checks `decision` and `primary_skill` | `--cases`, `--router`, `--include-disabled` |
| `validate_groundedness.sh` | Run `evals/groundedness/cases.yaml`; checks no forbidden substrings appear in output | `--cases`, `--agent`, `--include-disabled` |
| `validate_task_success.sh` | Run `evals/task_success/cases.yaml`; checks plan has minimum runnable steps and expected outputs | `--cases`, `--agent`, `--include-disabled` |
| `benchmark/tools/eval_benchmark.py` | Comparative benchmark aggregator across routing/groundedness/task-success suites, with summary tables and statistics | `--participants`, `--suites`, `--output-dir`, `--seed`, `--dry-run`, `--openai-base-url` |
| `benchmark/tools/test_eval_benchmark_mock.py` | Fixture/mock regression checks for benchmark parser, scorer, and retry behavior | none |

### Support Library

| Script | Purpose |
|---|---|
| `lib_registry.sh` | Shared bash functions for reading `registry/skills.yaml` (sourced by most other scripts) |
| `smoke_test.sh` | Check layout, skill links, scripts, and optional import health on target machine |

## Dependency Map

```
bootstrap.sh
  └─ link_skills.sh
  └─ provision_stack.sh
  └─ smoke_test.sh

run_agent.sh
  └─ route_query.sh

execute_plan.sh
  └─ run_agent.sh
    └─ route_query.sh

validate_routing.sh
  └─ route_query.sh

validate_groundedness.sh
  └─ run_agent.sh

validate_task_success.sh
  └─ run_agent.sh
```

All scripts that iterate over skills source `scripts/lib_registry.sh`.

## Make Targets

| Target | Equivalent script invocation |
|---|---|
| `make link-skills` | `link_skills.sh` |
| `make validate-registry` | `validate_registry.sh` |
| `make validate-registry-tracking` | `validate_registry_tracking.sh` |
| `make validate-skill-metadata` | `validate_skill_metadata.sh` |
| `make validate-input-contracts` | `validate_input_contracts.sh` |
| `make validate-migration-paths` | `validate_migration_paths.sh` |
| `make validate-agent` | registry + skill metadata + routing validations (composite) |
| `make eval-routing` | `validate_routing.sh` |
| `make eval-groundedness` | `validate_groundedness.sh` |
| `make eval-task-success` | `validate_task_success.sh` |
| `make eval-benchmark` | `benchmark/tools/eval_benchmark.py` |
| `make test-eval-benchmark-mock` | `benchmark/tools/test_eval_benchmark_mock.py` |
| `make route-query QUERY=...` | `route_query.sh --query "$QUERY"` |
| `make run-agent QUERY=...` | `run_agent.sh --query "$QUERY"` |
| `make execute-plan QUERY=...` | `execute_plan.sh --query "$QUERY"` |
| `make agent-console` | `agent_console.sh` |
| `make bootstrap` | `bootstrap.sh` |
| `make bootstrap-persistent` | `bootstrap.sh --persistent-root ...` |
| `make prefetch-models` | `prefetch_models.sh` |
| `make clean-runtime` | `clean_runtime.sh` |
| `make smoke` | `smoke_test.sh` |

## Key Environment Variables

| Variable | Used by | Purpose |
|---|---|---|
| `CODEX_HOME` | `link_skills.sh`, `bootstrap.sh` | Codex skills directory root (default: `~/.codex`) |
| `S2F_DEPLOY_ROOT` | `bootstrap.sh`, `clean_runtime.sh` | Working root for venvs and upstream clones |
| `S2F_PERSISTENT_ROOT` | `bootstrap.sh`, `clean_runtime.sh` | Stable cross-session deploy/cache root |
| `HF_HOME` | `prefetch_models.sh` | Hugging Face cache directory |
| `ALPHAGENOME_API_KEY` | `execute_plan.sh` (env precheck) | AlphaGenome API credential |
| `HF_TOKEN` | `execute_plan.sh` (env precheck) | Hugging Face token (NTv3) |
| `NVCF_RUN_KEY` / `EVO2_API_KEY` | `execute_plan.sh` (env precheck) | Evo 2 hosted API credential |

## See Also

- [Evals Reference](./evals.md) — how to run and interpret validation/eval output
- `playbooks/getting-started/README.md` — end-to-end walkthrough using these scripts
