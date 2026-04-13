SHELL := /bin/bash

REPO_ROOT := $(CURDIR)
SKILLS_DIR ?= $(CODEX_HOME)/skills
ifeq ($(strip $(SKILLS_DIR)),/skills)
SKILLS_DIR := $(HOME)/.codex/skills
endif
ifeq ($(strip $(SKILLS_DIR)),)
SKILLS_DIR := $(HOME)/.codex/skills
endif

DEPLOY_ROOT ?= $(REPO_ROOT)/.deploy
PERSISTENT_ROOT ?= $(HOME)/.cache/s2f-skills
PYTHON_BIN ?= python3
PREFETCH_MODELS ?= 0

BOOTSTRAP_FLAGS :=
ifeq ($(COPY_SKILLS),1)
BOOTSTRAP_FLAGS += --copy-skills
endif
ifeq ($(FORCE_LINKS),1)
BOOTSTRAP_FLAGS += --force-links
endif
ifeq ($(PREFETCH_MODELS),1)
BOOTSTRAP_FLAGS += --prefetch-models
endif

.PHONY: help link-skills validate-registry validate-registry-tracking validate-skill-metadata validate-input-contracts validate-migration-paths validate-agent eval-routing eval-groundedness eval-task-success eval-benchmark test-eval-benchmark-mock route-query run-agent execute-plan agent-console bootstrap bootstrap-persistent bootstrap-ntv3-hf bootstrap-borzoi bootstrap-evo2-light bootstrap-evo2-full prefetch-models clean-runtime smoke smoke-lite

help:
	@printf '%s\n' \
	  'Available targets:' \
	  '  make link-skills           Link all packaged skills into the Codex skills dir' \
	  '  make validate-registry     Validate registry entries against local skill package paths' \
	  '  make validate-registry-tracking Validate enabled registry skills are tracked and not ignored' \
	  '  make validate-skill-metadata Validate skill.yaml completeness and registry consistency' \
	  '  make validate-input-contracts Validate canonical input schema across task contracts and stable skills' \
	  '  make validate-migration-paths Validate selected migrated skills paths and compatibility symlinks' \
	  '  make validate-agent        Run registry + skill metadata + routing validations' \
	  '  make eval-routing          Evaluate routing behavior using eval cases and registry metadata' \
	  '  make eval-groundedness     Evaluate groundedness constraints against curated cases' \
	  '  make eval-task-success     Evaluate task-plan completeness against curated cases' \
	  '  make eval-benchmark        Run comparative benchmark (s2f-agent + configured baselines)' \
	  '  make test-eval-benchmark-mock Run fixture-based benchmark unit tests' \
	  '  make route-query           Route one query (set QUERY=... and optional TASK=...)' \
	  '  make run-agent             Run full agent orchestration (set QUERY=... and optional TASK=...)' \
	  '  make execute-plan          Build/execute plan from query (set QUERY=... and optional TASK=...)' \
	  '  make agent-console         Open interactive local agent console' \
	  '  make bootstrap             One-step install: skills + alphagenome + gpn + nt-jax + smoke test' \
	  '  make bootstrap-persistent  One-time persistent install with shared deploy/cache root' \
	  '  make bootstrap-ntv3-hf     Same as bootstrap, plus ntv3-hf (Transformers path) + smoke check' \
	  '  make bootstrap-borzoi      Same as bootstrap, plus borzoi (Calico tutorial stack) + smoke check' \
	  '  make bootstrap-evo2-light  Same as bootstrap, plus evo2-light (requires TORCH_INSTALL_CMD)' \
	  '  make bootstrap-evo2-full   Same as bootstrap, plus evo2-full in active conda env' \
	  '  make prefetch-models       Prefetch default Hugging Face model weights into cache' \
	  '  make clean-runtime         One-click cleanup for s2f runtime envs and temp files' \
	  '  make smoke                 Run smoke tests against enabled skills and deployed paths' \
	  '  make smoke-lite            Run smoke tests without optional import checks' \
	  '' \
	  'Useful variables:' \
	  "  SKILLS_DIR=$(SKILLS_DIR)" \
	  "  DEPLOY_ROOT=$(DEPLOY_ROOT)" \
	  "  PERSISTENT_ROOT=$(PERSISTENT_ROOT)" \
	  "  PYTHON_BIN=$(PYTHON_BIN)" \
	  '  COPY_SKILLS=1              Copy skills instead of symlinking them' \
	  '  FORCE_LINKS=1             Replace existing paths in the skills directory' \
	  '  PREFETCH_MODELS=1         Also prefetch default models during bootstrap' \
	  '' \
	  'Example:' \
	  '  make bootstrap SKILLS_DIR=$$HOME/.codex/skills DEPLOY_ROOT=$$HOME/.cache/s2f-skills'

link-skills:
	bash $(REPO_ROOT)/scripts/link_skills.sh --skills-dir "$(SKILLS_DIR)" $(if $(filter 1,$(COPY_SKILLS)),--copy,) $(if $(filter 1,$(FORCE_LINKS)),--force,)

validate-registry:
	bash $(REPO_ROOT)/scripts/validate_registry.sh

validate-registry-tracking:
	bash $(REPO_ROOT)/scripts/validate_registry_tracking.sh

validate-skill-metadata:
	bash $(REPO_ROOT)/scripts/validate_skill_metadata.sh

validate-input-contracts:
	bash $(REPO_ROOT)/scripts/validate_input_contracts.sh

validate-migration-paths:
	bash $(REPO_ROOT)/scripts/validate_migration_paths.sh

validate-agent:
	bash $(REPO_ROOT)/scripts/validate_registry.sh
	bash $(REPO_ROOT)/scripts/validate_registry_tracking.sh
	bash $(REPO_ROOT)/scripts/validate_skill_metadata.sh
	bash $(REPO_ROOT)/scripts/validate_input_contracts.sh
	bash $(REPO_ROOT)/scripts/validate_routing.sh
	bash $(REPO_ROOT)/scripts/validate_migration_paths.sh

eval-routing:
	bash $(REPO_ROOT)/scripts/validate_routing.sh

eval-groundedness:
	bash $(REPO_ROOT)/scripts/validate_groundedness.sh

eval-task-success:
	bash $(REPO_ROOT)/scripts/validate_task_success.sh

eval-benchmark:
	python3 $(REPO_ROOT)/benchmark/tools/eval_benchmark.py

test-eval-benchmark-mock:
	python3 $(REPO_ROOT)/benchmark/tools/test_eval_benchmark_mock.py

route-query:
	@if [[ -z "$(QUERY)" ]]; then \
	  echo "error: set QUERY='<your query>' for make route-query"; \
	  exit 1; \
	fi
	@if [[ -n "$(TASK)" ]]; then \
	  bash $(REPO_ROOT)/scripts/route_query.sh --query "$(QUERY)" --task "$(TASK)"; \
	else \
	  bash $(REPO_ROOT)/scripts/route_query.sh --query "$(QUERY)"; \
	fi

run-agent:
	@if [[ -z "$(QUERY)" ]]; then \
	  echo "error: set QUERY='<your query>' for make run-agent"; \
	  exit 1; \
	fi
	@if [[ -n "$(TASK)" ]]; then \
	  bash $(REPO_ROOT)/scripts/run_agent.sh --query "$(QUERY)" --task "$(TASK)"; \
	else \
	  bash $(REPO_ROOT)/scripts/run_agent.sh --query "$(QUERY)"; \
	fi

execute-plan:
	@if [[ -z "$(QUERY)" ]]; then \
	  echo "error: set QUERY='<your query>' for make execute-plan"; \
	  exit 1; \
	fi
	@if [[ -n "$(TASK)" ]]; then \
	  bash $(REPO_ROOT)/scripts/execute_plan.sh --query "$(QUERY)" --task "$(TASK)"; \
	else \
	  bash $(REPO_ROOT)/scripts/execute_plan.sh --query "$(QUERY)"; \
	fi

agent-console:
	bash $(REPO_ROOT)/scripts/agent_console.sh

bootstrap:
	bash $(REPO_ROOT)/scripts/bootstrap.sh \
	  --skills-dir "$(SKILLS_DIR)" \
	  --deploy-root "$(DEPLOY_ROOT)" \
	  --python "$(PYTHON_BIN)" \
	  $(BOOTSTRAP_FLAGS)

bootstrap-persistent:
	bash $(REPO_ROOT)/scripts/bootstrap.sh \
	  --skills-dir "$(SKILLS_DIR)" \
	  --persistent-root "$(PERSISTENT_ROOT)" \
	  --python "$(PYTHON_BIN)" \
	  $(BOOTSTRAP_FLAGS)

bootstrap-ntv3-hf:
	bash $(REPO_ROOT)/scripts/bootstrap.sh \
	  --skills-dir "$(SKILLS_DIR)" \
	  --deploy-root "$(DEPLOY_ROOT)" \
	  --python "$(PYTHON_BIN)" \
	  --with-ntv3-hf \
	  $(BOOTSTRAP_FLAGS)

bootstrap-borzoi:
	bash $(REPO_ROOT)/scripts/bootstrap.sh \
	  --skills-dir "$(SKILLS_DIR)" \
	  --deploy-root "$(DEPLOY_ROOT)" \
	  --python "$(PYTHON_BIN)" \
	  --with-borzoi \
	  $(BOOTSTRAP_FLAGS)

bootstrap-evo2-light:
	bash $(REPO_ROOT)/scripts/bootstrap.sh \
	  --skills-dir "$(SKILLS_DIR)" \
	  --deploy-root "$(DEPLOY_ROOT)" \
	  --python "$(PYTHON_BIN)" \
	  --with-evo2-light \
	  $(BOOTSTRAP_FLAGS)

bootstrap-evo2-full:
	bash $(REPO_ROOT)/scripts/bootstrap.sh \
	  --skills-dir "$(SKILLS_DIR)" \
	  --deploy-root "$(DEPLOY_ROOT)" \
	  --python "$(PYTHON_BIN)" \
	  --with-evo2-full \
	  $(BOOTSTRAP_FLAGS)

prefetch-models:
	bash $(REPO_ROOT)/scripts/prefetch_models.sh \
	  --deploy-root "$(PERSISTENT_ROOT)/deploy" \
	  --python "$(PYTHON_BIN)"

clean-runtime:
	bash $(REPO_ROOT)/scripts/clean_runtime.sh \
	  --repo-root "$(REPO_ROOT)" \
	  --deploy-root "$(DEPLOY_ROOT)" \
	  --persistent-root "$(PERSISTENT_ROOT)" \
	  --yes

smoke:
	bash $(REPO_ROOT)/scripts/smoke_test.sh \
	  --skills-dir "$(SKILLS_DIR)" \
	  --alphagenome-python "$(DEPLOY_ROOT)/venvs/alphagenome/bin/python" \
	  --gpn-python "$(DEPLOY_ROOT)/venvs/gpn/bin/python" \
	  --nt-python "$(DEPLOY_ROOT)/venvs/nt-jax/bin/python"

smoke-lite:
	bash $(REPO_ROOT)/scripts/smoke_test.sh
