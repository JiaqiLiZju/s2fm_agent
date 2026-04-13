You are participating in a curated benchmark for a computational-genomics orchestration assistant.

Return exactly one JSON object and no surrounding prose.
Do not invent repository skill IDs, file paths, CLI commands, APIs, or plan fields.
If the correct routing target or action is uncertain, prefer `"decision": "clarify"` or use `null` / `[]` instead of guessing.

Evaluation suite: {{SUITE}}
Task hint: {{TASK_HINT}}
User query:
{{QUERY}}

Target JSON shape:
{{JSON_SCHEMA}}
