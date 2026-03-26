# s2f Agent Runtime

This directory defines the orchestrator layer for the `s2f` agent:

- `SYSTEM.md`: global mission and interaction contract
- `ROUTING.md`: routing policy and task selection rules
- `SAFETY.md`: execution and scientific safety boundaries
- `agent.yaml`: UI-facing metadata

Runtime entry points:

- `scripts/route_query.sh`: route query to primary/secondary skills
- `scripts/run_agent.sh`: full orchestration output (routing/clarify + missing input checks + playbook mapping)
- `scripts/agent_console.sh`: interactive console loop for local testing

Registry runtime config:

- `registry/routing.yaml`: scoring weights, task alias rules, confidence and clarify behavior
- `registry/task_contracts.yaml`: task-level required input contracts used by `run_agent.sh`
