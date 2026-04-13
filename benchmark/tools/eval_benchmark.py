#!/usr/bin/env python3
"""Comparative benchmark runner built on top of existing eval suites."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

import yaml

REQUIRED_PLAN_ARRAY_FIELDS = [
    "assumptions",
    "required_inputs",
    "missing_inputs",
    "constraints",
    "runnable_steps",
    "expected_outputs",
    "fallbacks",
]

PROMPT_VARIANT_TO_TEMPLATE = {
    "direct": "direct.md",
    "catalog-only": "catalog_only.md",
    "catalog+contracts": "catalog_contracts.md",
}


def load_yaml(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        parsed = yaml.safe_load(handle)
    if parsed is None:
        return {}
    if not isinstance(parsed, dict):
        raise ValueError(f"YAML root must be a mapping: {path}")
    return parsed


def parse_csv_arg(value: Optional[str]) -> List[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def iso_utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run_subprocess_json(cmd: Sequence[str], timeout_s: int = 180) -> Tuple[str, Optional[Dict[str, Any]], Optional[str]]:
    started = time.time()
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout_s,
        check=False,
    )
    elapsed_ms = int((time.time() - started) * 1000)
    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()
    combined = "\n".join([chunk for chunk in [stdout, stderr] if chunk]).strip()

    if proc.returncode != 0:
        return combined, None, f"subprocess_exit_{proc.returncode}"

    parsed, parse_error = parse_json_from_text(stdout)
    if parse_error:
        return combined, None, f"stdout_json_parse_error:{parse_error}"

    if not isinstance(parsed, dict):
        return combined, None, "stdout_json_not_object"

    return combined, parsed, None


def parse_json_from_text(text: str) -> Tuple[Optional[Any], Optional[str]]:
    raw = text.strip()
    if not raw:
        return None, "empty"
    try:
        return json.loads(raw), None
    except json.JSONDecodeError:
        pass

    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None, "no_object_delimiters"

    candidate = raw[start : end + 1]
    try:
        return json.loads(candidate), None
    except json.JSONDecodeError as exc:
        return None, str(exc)


def to_str_list(value: Any) -> List[str]:
    if value is None:
        return []
    if isinstance(value, list):
        out: List[str] = []
        for item in value:
            if isinstance(item, str):
                out.append(item)
            elif item is None:
                continue
            else:
                out.append(str(item))
        return out
    if isinstance(value, str):
        return [value]
    return [str(value)]


def lower_contains(haystack: str, needle: str) -> bool:
    return needle.lower() in haystack.lower()


def normalize_from_object(
    obj: Dict[str, Any],
    raw_response: str,
    known_skills: Iterable[str],
) -> Dict[str, Any]:
    known = set(known_skills)

    decision = obj.get("decision")
    if isinstance(decision, str):
        decision = decision.strip().lower()
    else:
        decision = None

    primary_skill = obj.get("primary_skill")
    if not isinstance(primary_skill, str) or not primary_skill.strip():
        primary = obj.get("primary")
        if isinstance(primary, dict):
            skill = primary.get("skill")
            if isinstance(skill, str) and skill.strip():
                primary_skill = skill.strip()
            else:
                primary_skill = None
        else:
            primary_skill = None

    secondary_skills_raw = obj.get("secondary_skills")
    if secondary_skills_raw is None:
        secondary_skills_raw = obj.get("secondary")

    secondary_skills: List[str] = []
    if isinstance(secondary_skills_raw, list):
        for item in secondary_skills_raw:
            if isinstance(item, str):
                sid = item.strip()
                if sid:
                    secondary_skills.append(sid)
            elif isinstance(item, dict):
                sid = item.get("skill")
                if isinstance(sid, str) and sid.strip():
                    secondary_skills.append(sid.strip())

    clarify_question = obj.get("clarify_question")
    if not isinstance(clarify_question, str):
        clarify_question = None

    constraints = to_str_list(obj.get("constraints"))

    plan = obj.get("plan")
    if not isinstance(plan, dict):
        plan = None

    validation_errors: List[str] = []
    if primary_skill and primary_skill not in known:
        validation_errors.append(f"unknown_primary_skill:{primary_skill}")

    for sid in secondary_skills:
        if sid not in known:
            validation_errors.append(f"unknown_secondary_skill:{sid}")

    if plan is not None:
        selected_skill = plan.get("selected_skill")
        if isinstance(selected_skill, str) and selected_skill and selected_skill not in known:
            validation_errors.append(f"unknown_plan_selected_skill:{selected_skill}")

    return {
        "decision": decision,
        "primary_skill": primary_skill,
        "secondary_skills": secondary_skills,
        "clarify_question": clarify_question,
        "constraints": constraints,
        "plan": plan,
        "raw_response": raw_response,
        "validation_errors": validation_errors,
    }


def normalize_from_raw_text(raw_text: str, known_skills: Iterable[str]) -> Dict[str, Any]:
    parsed, parse_error = parse_json_from_text(raw_text)
    if parse_error or not isinstance(parsed, dict):
        return {
            "decision": None,
            "primary_skill": None,
            "secondary_skills": [],
            "clarify_question": None,
            "constraints": [],
            "plan": None,
            "raw_response": raw_text,
            "validation_errors": [f"raw_json_parse_error:{parse_error or 'not_object'}"],
        }
    return normalize_from_object(parsed, raw_text, known_skills)


def score_routing_case(case: Dict[str, Any], normalized: Dict[str, Any]) -> Dict[str, Any]:
    checks: List[Dict[str, Any]] = []

    expected_decision = str(case.get("expected_decision") or "route").strip().lower()
    decision = normalized.get("decision")
    decision_ok = decision == expected_decision
    checks.append({"name": "decision", "pass": decision_ok, "expected": expected_decision, "actual": decision})

    overall_ok = decision_ok

    if expected_decision == "clarify":
        expected_fragment = str(case.get("expected_clarify_contains") or "").strip()
        if expected_fragment:
            actual_question = normalized.get("clarify_question") or ""
            clarify_ok = lower_contains(actual_question, expected_fragment)
            checks.append(
                {
                    "name": "clarify_question_contains",
                    "pass": clarify_ok,
                    "expected": expected_fragment,
                    "actual": actual_question,
                }
            )
            overall_ok = overall_ok and clarify_ok
        return {"pass": overall_ok, "checks": checks}

    primary_expected = case.get("expected_primary_skill")
    primary_actual = normalized.get("primary_skill")
    primary_ok = primary_actual == primary_expected
    checks.append({"name": "primary_skill", "pass": primary_ok, "expected": primary_expected, "actual": primary_actual})
    overall_ok = overall_ok and primary_ok

    expected_secondary = case.get("expected_secondary_skills") or []
    if not isinstance(expected_secondary, list):
        expected_secondary = []

    actual_secondary = normalized.get("secondary_skills") or []
    missing_secondary = [sid for sid in expected_secondary if sid not in actual_secondary]
    secondary_ok = len(missing_secondary) == 0
    checks.append(
        {
            "name": "secondary_skills_contains_expected",
            "pass": secondary_ok,
            "expected": expected_secondary,
            "actual": actual_secondary,
            "missing": missing_secondary,
        }
    )
    overall_ok = overall_ok and secondary_ok

    return {"pass": overall_ok, "checks": checks}


def score_groundedness_case(case: Dict[str, Any], normalized: Dict[str, Any]) -> Dict[str, Any]:
    checks: List[Dict[str, Any]] = []

    decision = normalized.get("decision")
    decision_ok = decision == "route"
    checks.append({"name": "decision_route", "pass": decision_ok, "actual": decision})

    expected_primary = case.get("expected_primary_skill")
    actual_primary = normalized.get("primary_skill")
    primary_ok = actual_primary == expected_primary
    checks.append({"name": "primary_skill", "pass": primary_ok, "expected": expected_primary, "actual": actual_primary})

    constraints = ",".join(to_str_list(normalized.get("constraints")))
    required_fragment = str(case.get("required_constraint_contains") or "").strip()
    constraint_ok = True
    if required_fragment:
        constraint_ok = lower_contains(constraints, required_fragment)
    checks.append(
        {
            "name": "required_constraint_contains",
            "pass": constraint_ok,
            "expected": required_fragment,
            "actual": constraints,
        }
    )

    forbidden = str(case.get("forbidden_substring") or "").strip()
    raw_response = str(normalized.get("raw_response") or "")
    forbidden_ok = True
    if forbidden:
        forbidden_ok = not lower_contains(raw_response, forbidden)
    checks.append(
        {
            "name": "forbidden_substring_absent",
            "pass": forbidden_ok,
            "expected": forbidden,
            "actual": "present" if not forbidden_ok else "absent",
        }
    )

    validation_errors = to_str_list(normalized.get("validation_errors"))
    validation_ok = len(validation_errors) == 0
    checks.append({"name": "normalization_validation", "pass": validation_ok, "actual": validation_errors})

    overall_ok = decision_ok and primary_ok and constraint_ok and forbidden_ok and validation_ok
    return {"pass": overall_ok, "checks": checks}


def score_task_success_case(case: Dict[str, Any], normalized: Dict[str, Any]) -> Dict[str, Any]:
    checks: List[Dict[str, Any]] = []

    decision = normalized.get("decision")
    decision_ok = decision == "route"
    checks.append({"name": "decision_route", "pass": decision_ok, "actual": decision})

    plan = normalized.get("plan")
    plan_ok = isinstance(plan, dict)
    checks.append({"name": "plan_non_null", "pass": plan_ok, "actual": type(plan).__name__ if plan is not None else None})

    task_hint = case.get("task")
    plan_task_ok = True
    plan_task_actual = None
    if isinstance(plan, dict):
        plan_task_actual = plan.get("task")
        if task_hint:
            plan_task_ok = plan_task_actual == task_hint
    checks.append({"name": "plan_task_matches_hint", "pass": plan_task_ok, "expected": task_hint, "actual": plan_task_actual})

    selected_skill_ok = False
    retry_policy_ok = False
    unknown_skill_ok = True
    missing_arrays: List[str] = []
    runnable_steps: List[str] = []
    expected_outputs: List[str] = []

    if isinstance(plan, dict):
        selected_skill = plan.get("selected_skill")
        retry_policy = plan.get("retry_policy")
        selected_skill_ok = isinstance(selected_skill, str) and bool(selected_skill.strip())
        retry_policy_ok = isinstance(retry_policy, str) and bool(retry_policy.strip())

        validation_errors = to_str_list(normalized.get("validation_errors"))
        unknown_skill_ok = len(validation_errors) == 0

        for field in REQUIRED_PLAN_ARRAY_FIELDS:
            value = plan.get(field)
            if not isinstance(value, list):
                missing_arrays.append(field)

        if isinstance(plan.get("runnable_steps"), list):
            runnable_steps = to_str_list(plan.get("runnable_steps"))
        if isinstance(plan.get("expected_outputs"), list):
            expected_outputs = to_str_list(plan.get("expected_outputs"))

    checks.append({"name": "selected_skill_present", "pass": selected_skill_ok})
    checks.append({"name": "retry_policy_present", "pass": retry_policy_ok})
    checks.append({"name": "normalization_validation", "pass": unknown_skill_ok, "actual": normalized.get("validation_errors")})
    checks.append({"name": "required_plan_arrays_present", "pass": len(missing_arrays) == 0, "missing": missing_arrays})

    min_steps = int(case.get("min_runnable_steps") or 1)
    min_outputs = int(case.get("min_expected_outputs") or 1)
    steps_ok = len(runnable_steps) >= min_steps
    outputs_ok = len(expected_outputs) >= min_outputs
    checks.append({"name": "min_runnable_steps", "pass": steps_ok, "expected": min_steps, "actual": len(runnable_steps)})
    checks.append({"name": "min_expected_outputs", "pass": outputs_ok, "expected": min_outputs, "actual": len(expected_outputs)})

    required_step_fragment = str(case.get("required_step_contains") or "").strip()
    required_output_fragment = str(case.get("required_expected_output_contains") or "").strip()

    step_fragment_ok = True
    if required_step_fragment:
        step_fragment_ok = any(lower_contains(step, required_step_fragment) for step in runnable_steps)
    checks.append(
        {
            "name": "required_step_contains",
            "pass": step_fragment_ok,
            "expected": required_step_fragment,
            "actual": runnable_steps,
        }
    )

    output_fragment_ok = True
    if required_output_fragment:
        output_fragment_ok = any(lower_contains(item, required_output_fragment) for item in expected_outputs)
    checks.append(
        {
            "name": "required_expected_output_contains",
            "pass": output_fragment_ok,
            "expected": required_output_fragment,
            "actual": expected_outputs,
        }
    )

    overall_ok = (
        decision_ok
        and plan_ok
        and plan_task_ok
        and selected_skill_ok
        and retry_policy_ok
        and unknown_skill_ok
        and len(missing_arrays) == 0
        and steps_ok
        and outputs_ok
        and step_fragment_ok
        and output_fragment_ok
    )
    return {"pass": overall_ok, "checks": checks}


def score_case(suite: str, case: Dict[str, Any], normalized: Dict[str, Any]) -> Dict[str, Any]:
    if suite == "routing":
        return score_routing_case(case, normalized)
    if suite == "groundedness":
        return score_groundedness_case(case, normalized)
    if suite == "task_success":
        return score_task_success_case(case, normalized)
    raise ValueError(f"Unsupported suite: {suite}")


def safe_percent(value: Optional[float]) -> str:
    if value is None:
        return "n/a"
    return f"{value * 100.0:.2f}%"


def compute_suite_micro(records: List[Dict[str, Any]]) -> Optional[float]:
    scored = [record for record in records if record.get("status") == "scored"]
    if not scored:
        return None
    passed = sum(1 for record in scored if record.get("score", {}).get("pass"))
    return passed / float(len(scored))


def compute_suite_macro(records: List[Dict[str, Any]]) -> Optional[float]:
    scored = [record for record in records if record.get("status") == "scored"]
    if not scored:
        return None

    by_task: Dict[str, List[bool]] = {}
    for record in scored:
        task = record.get("case", {}).get("task") or "general"
        by_task.setdefault(task, []).append(bool(record.get("score", {}).get("pass")))

    macro_values: List[float] = []
    for values in by_task.values():
        if values:
            macro_values.append(sum(1 for item in values if item) / float(len(values)))

    if not macro_values:
        return None
    return sum(macro_values) / float(len(macro_values))


def bootstrap_ci(values: List[float], alpha: float = 0.05) -> Optional[List[float]]:
    if not values:
        return None
    ordered = sorted(values)
    low_idx = int((alpha / 2.0) * (len(ordered) - 1))
    high_idx = int((1.0 - alpha / 2.0) * (len(ordered) - 1))
    return [ordered[low_idx], ordered[high_idx]]


def bootstrap_micro_ci(records: List[Dict[str, Any]], iterations: int, rng: random.Random) -> Optional[List[float]]:
    scored = [record for record in records if record.get("status") == "scored"]
    if not scored:
        return None

    outcomes = [1.0 if record.get("score", {}).get("pass") else 0.0 for record in scored]
    if len(outcomes) == 1:
        return [outcomes[0], outcomes[0]]

    draws: List[float] = []
    n = len(outcomes)
    for _ in range(iterations):
        sampled = [outcomes[rng.randrange(n)] for _ in range(n)]
        draws.append(sum(sampled) / float(n))
    return bootstrap_ci(draws)


def bootstrap_macro_ci(records: List[Dict[str, Any]], iterations: int, rng: random.Random) -> Optional[List[float]]:
    scored = [record for record in records if record.get("status") == "scored"]
    if not scored:
        return None

    if len(scored) == 1:
        value = 1.0 if scored[0].get("score", {}).get("pass") else 0.0
        return [value, value]

    draws: List[float] = []
    n = len(scored)
    for _ in range(iterations):
        sampled = [scored[rng.randrange(n)] for _ in range(n)]
        macro = compute_suite_macro(sampled)
        if macro is not None:
            draws.append(macro)
    return bootstrap_ci(draws)


def binom_tail_probability(n: int, k: int) -> float:
    total = 0.0
    for i in range(0, k + 1):
        total += math.comb(n, i)
    return total / float(2**n)


def exact_mcnemar_p_value(n01: int, n10: int) -> float:
    n = n01 + n10
    if n == 0:
        return 1.0
    tail = binom_tail_probability(n, min(n01, n10))
    return min(1.0, 2.0 * tail)


def paired_bootstrap_delta_ci(
    outcomes_a: List[bool],
    outcomes_b: List[bool],
    iterations: int,
    rng: random.Random,
) -> Optional[List[float]]:
    if not outcomes_a or len(outcomes_a) != len(outcomes_b):
        return None

    n = len(outcomes_a)
    if n == 1:
        delta = (1.0 if outcomes_a[0] else 0.0) - (1.0 if outcomes_b[0] else 0.0)
        return [delta, delta]

    draws: List[float] = []
    for _ in range(iterations):
        idxs = [rng.randrange(n) for _ in range(n)]
        sampled_a = [1.0 if outcomes_a[idx] else 0.0 for idx in idxs]
        sampled_b = [1.0 if outcomes_b[idx] else 0.0 for idx in idxs]
        draws.append(sum(sampled_a) / float(n) - sum(sampled_b) / float(n))
    return bootstrap_ci(draws)


def _http_post_json(url: str, headers: Dict[str, str], payload: Dict[str, Any], timeout_s: int) -> Tuple[int, str]:
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout_s) as response:
            status = int(response.status)
            body = response.read().decode("utf-8", errors="replace")
            return status, body
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return int(exc.code), body
    except urllib.error.URLError as exc:
        return 599, f"network_error:{exc}"
    except TimeoutError as exc:
        return 599, f"network_error:{exc}"
    except Exception as exc:
        return 599, f"network_error:{exc}"


def build_openai_payload(participant: Dict[str, Any], prompt: str) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "model": participant["model"],
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0,
        "response_format": {"type": "json_object"},
    }
    reasoning_effort = participant.get("reasoning_effort")
    if isinstance(reasoning_effort, str) and reasoning_effort.strip():
        payload["reasoning_effort"] = reasoning_effort.strip()
    return payload


def call_openai_chat(
    participant: Dict[str, Any],
    prompt: str,
    api_key: str,
    base_url: str,
    timeout_s: int,
    max_retries: int,
    request_fn: Optional[Callable[[str, Dict[str, str], Dict[str, Any], int], Tuple[int, str]]] = None,
) -> Dict[str, Any]:
    endpoint = base_url.rstrip("/") + "/chat/completions"
    payload = build_openai_payload(participant, prompt)
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    requester = request_fn or _http_post_json

    attempts = 0
    while True:
        attempts += 1
        status, body = requester(endpoint, headers, payload, timeout_s)

        if status == 200:
            parsed, parse_error = parse_json_from_text(body)
            if parse_error or not isinstance(parsed, dict):
                return {
                    "ok": False,
                    "error": f"openai_response_not_json:{parse_error}",
                    "raw_text": body,
                    "payload": payload,
                    "attempts": attempts,
                }

            choices = parsed.get("choices")
            if not isinstance(choices, list) or not choices:
                return {
                    "ok": False,
                    "error": "openai_missing_choices",
                    "raw_text": body,
                    "payload": payload,
                    "attempts": attempts,
                }

            message = choices[0].get("message") if isinstance(choices[0], dict) else None
            content = message.get("content") if isinstance(message, dict) else None

            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                chunks: List[str] = []
                for item in content:
                    if isinstance(item, dict):
                        text_value = item.get("text")
                        if isinstance(text_value, str):
                            chunks.append(text_value)
                text = "\n".join(chunks).strip()
            else:
                text = ""

            if not text:
                return {
                    "ok": False,
                    "error": "openai_empty_content",
                    "raw_text": body,
                    "payload": payload,
                    "attempts": attempts,
                }

            return {
                "ok": True,
                "error": None,
                "raw_text": text,
                "payload": payload,
                "attempts": attempts,
            }

        retriable = status == 429 or (500 <= status <= 599)
        if retriable and attempts <= (max_retries + 1):
            time.sleep(1.0)
            continue

        return {
            "ok": False,
            "error": f"openai_http_{status}",
            "raw_text": body,
            "payload": payload,
            "attempts": attempts,
        }


def format_skill_catalog(skills: List[Dict[str, Any]], family_descriptions: Dict[str, str]) -> str:
    lines: List[str] = []
    for skill in skills:
        sid = skill.get("id")
        family = skill.get("family") or "unknown"
        tasks = ", ".join(to_str_list(skill.get("tasks"))) or "none"
        desc = family_descriptions.get(family, "")
        if desc:
            lines.append(f"- {sid}: family={family}; tasks={tasks}; notes={desc}")
        else:
            lines.append(f"- {sid}: family={family}; tasks={tasks}")
    return "\n".join(lines)


def format_task_catalog(task_contracts: Dict[str, Any]) -> str:
    contracts = task_contracts.get("contracts")
    if not isinstance(contracts, dict):
        return "- none"

    lines: List[str] = []
    for task in sorted(contracts.keys()):
        required = contracts.get(task, {}).get("required_inputs")
        required_list = ", ".join(to_str_list(required)) or "none"
        lines.append(f"- {task}: required_inputs={required_list}")
    return "\n".join(lines)


def dump_json(obj: Any) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True)


def target_json_schema_text() -> str:
    schema = {
        "decision": "route|clarify",
        "primary_skill": "skill-id-or-null",
        "secondary_skills": ["skill-id"],
        "clarify_question": "string-or-null",
        "constraints": ["string"],
        "plan": {
            "task": "string-or-null",
            "selected_skill": "skill-id-or-null",
            "assumptions": ["string"],
            "required_inputs": ["string"],
            "missing_inputs": ["string"],
            "constraints": ["string"],
            "runnable_steps": ["string"],
            "expected_outputs": ["string"],
            "fallbacks": ["string"],
            "retry_policy": "string-or-null",
        },
    }
    return dump_json(schema)


def render_prompt(
    template_text: str,
    suite: str,
    case: Dict[str, Any],
    skill_catalog_text: str,
    task_catalog_text: str,
    task_contracts_text: str,
    output_contracts_text: str,
) -> str:
    replacements = {
        "{{SUITE}}": suite,
        "{{TASK_HINT}}": str(case.get("task") or "none"),
        "{{QUERY}}": str(case.get("query") or ""),
        "{{TASK_CATALOG}}": task_catalog_text,
        "{{SKILL_CATALOG}}": skill_catalog_text,
        "{{TASK_CONTRACTS}}": task_contracts_text,
        "{{OUTPUT_CONTRACTS}}": output_contracts_text,
        "{{JSON_SCHEMA}}": target_json_schema_text(),
    }

    rendered = template_text
    for token, value in replacements.items():
        rendered = rendered.replace(token, value)
    return rendered


def load_suite_cases(case_files: Dict[str, str], suites: List[str], repo_root: Path) -> Dict[str, List[Dict[str, Any]]]:
    by_suite: Dict[str, List[Dict[str, Any]]] = {}
    for suite in suites:
        rel_path = case_files.get(suite)
        if not isinstance(rel_path, str) or not rel_path.strip():
            raise ValueError(f"missing case file path for suite: {suite}")

        case_path = repo_root / rel_path
        if not case_path.exists():
            raise FileNotFoundError(f"case file not found: {case_path}")

        parsed = load_yaml(case_path)
        cases = parsed.get("cases")
        if not isinstance(cases, list):
            raise ValueError(f"case file missing 'cases' list: {case_path}")

        normalized_cases: List[Dict[str, Any]] = []
        for item in cases:
            if not isinstance(item, dict):
                continue
            case_id = item.get("id")
            query = item.get("query")
            if not isinstance(case_id, str) or not case_id.strip():
                continue
            if not isinstance(query, str) or not query.strip():
                continue
            normalized_cases.append(item)

        by_suite[suite] = normalized_cases
    return by_suite


def write_record(path: Path, data: Dict[str, Any]) -> None:
    ensure_parent(path)
    path.write_text(dump_json(data) + "\n", encoding="utf-8")


def write_raw(path: Path, text: str) -> None:
    ensure_parent(path)
    path.write_text(text, encoding="utf-8")


def choose_examples(
    records: List[Dict[str, Any]],
    main_participant_ids: List[str],
    limit_per_suite: int,
) -> List[Dict[str, Any]]:
    if not records:
        return []

    by_suite_case: Dict[Tuple[str, str], List[Dict[str, Any]]] = {}
    for record in records:
        suite = record.get("suite")
        case_id = record.get("case", {}).get("id")
        if not suite or not case_id:
            continue
        by_suite_case.setdefault((suite, case_id), []).append(record)

    chosen: List[Dict[str, Any]] = []
    suites = sorted({key[0] for key in by_suite_case.keys()})

    for suite in suites:
        suite_candidates: List[Dict[str, Any]] = []
        for (candidate_suite, case_id), case_records in by_suite_case.items():
            if candidate_suite != suite:
                continue

            by_pid = {entry.get("participant_id"): entry for entry in case_records}
            s2f = by_pid.get("s2f-agent")
            if not s2f:
                continue

            s2f_pass = bool(s2f.get("score", {}).get("pass"))
            baseline_failed = any(
                pid != "s2f-agent"
                and pid in by_pid
                and by_pid[pid].get("status") == "scored"
                and not bool(by_pid[pid].get("score", {}).get("pass"))
                for pid in main_participant_ids
            )

            if s2f_pass and baseline_failed:
                suite_candidates.append(
                    {
                        "suite": suite,
                        "case_id": case_id,
                        "query": s2f.get("case", {}).get("query"),
                        "participants": {
                            pid: {
                                "pass": bool(by_pid[pid].get("score", {}).get("pass")) if pid in by_pid else None,
                                "status": by_pid[pid].get("status") if pid in by_pid else "missing",
                                "raw_output_path": by_pid[pid].get("raw_output_path") if pid in by_pid else None,
                            }
                            for pid in main_participant_ids
                        },
                    }
                )

        if not suite_candidates:
            # fallback: first case from the suite
            for (candidate_suite, case_id), case_records in by_suite_case.items():
                if candidate_suite != suite:
                    continue
                head = case_records[0]
                by_pid = {entry.get("participant_id"): entry for entry in case_records}
                suite_candidates.append(
                    {
                        "suite": suite,
                        "case_id": case_id,
                        "query": head.get("case", {}).get("query"),
                        "participants": {
                            pid: {
                                "pass": bool(by_pid[pid].get("score", {}).get("pass")) if pid in by_pid else None,
                                "status": by_pid[pid].get("status") if pid in by_pid else "missing",
                                "raw_output_path": by_pid[pid].get("raw_output_path") if pid in by_pid else None,
                            }
                            for pid in main_participant_ids
                        },
                    }
                )
                break

        chosen.extend(suite_candidates[:limit_per_suite])

    return chosen


def render_examples_markdown(examples: List[Dict[str, Any]], output_root: Path) -> str:
    lines: List[str] = ["# Benchmark Examples", ""]
    if not examples:
        lines.append("No examples selected.")
        return "\n".join(lines) + "\n"

    for item in examples:
        lines.append(f"## {item['suite']} / {item['case_id']}")
        lines.append("")
        lines.append("Query:")
        lines.append("")
        lines.append(f"> {item.get('query')}")
        lines.append("")
        lines.append("Participants:")
        lines.append("")
        for pid, info in item.get("participants", {}).items():
            lines.append(f"- {pid}: status={info.get('status')} pass={info.get('pass')}")
            raw_path = info.get("raw_output_path")
            if isinstance(raw_path, str):
                full_path = output_root / raw_path
                if full_path.exists():
                    preview = full_path.read_text(encoding="utf-8")[:400].replace("\n", " ")
                    lines.append(f"  - raw_preview: {preview}")
        lines.append("")

    return "\n".join(lines) + "\n"


def format_metric_cell(metrics: Dict[str, Any], suite: str) -> str:
    suite_metrics = metrics.get("suite_metrics", {}).get(suite, {})
    micro = suite_metrics.get("micro")
    macro = suite_metrics.get("macro")
    return f"{safe_percent(micro)} / {safe_percent(macro)}"


def format_overall_cell(metrics: Dict[str, Any]) -> str:
    overall = metrics.get("overall", {})
    return f"{safe_percent(overall.get('micro'))} / {safe_percent(overall.get('macro'))}"


def build_table_markdown(
    participant_order: List[str],
    participant_configs: Dict[str, Dict[str, Any]],
    participant_metrics: Dict[str, Dict[str, Any]],
    suites: List[str],
) -> str:
    main = [pid for pid in participant_order if participant_configs[pid].get("table_group") == "main"]
    ablation = [pid for pid in participant_order if participant_configs[pid].get("table_group") == "ablation"]

    lines: List[str] = ["# Comparative Benchmark Summary", ""]

    lines.append("## Main Results")
    lines.append("")

    main_header = ["Participant"] + [suite for suite in suites] + ["overall"]
    lines.append("| " + " | ".join(main_header) + " |")
    lines.append("| " + " | ".join(["---"] * len(main_header)) + " |")

    for pid in main:
        metrics = participant_metrics.get(pid, {})
        row = [participant_configs[pid].get("label", pid)]
        for suite in suites:
            row.append(format_metric_cell(metrics, suite))
        row.append(format_overall_cell(metrics))
        lines.append("| " + " | ".join(row) + " |")

    if ablation:
        lines.append("")
        lines.append("## o3-mini Ablation")
        lines.append("")
        ablation_header = ["Participant"] + [suite for suite in suites] + ["overall"]
        lines.append("| " + " | ".join(ablation_header) + " |")
        lines.append("| " + " | ".join(["---"] * len(ablation_header)) + " |")
        for pid in ablation:
            metrics = participant_metrics.get(pid, {})
            row = [participant_configs[pid].get("label", pid)]
            for suite in suites:
                row.append(format_metric_cell(metrics, suite))
            row.append(format_overall_cell(metrics))
            lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    lines.append("- Cell format is `micro / macro`.")
    return "\n".join(lines) + "\n"


def compute_participant_metrics(
    records: List[Dict[str, Any]],
    participant_ids: List[str],
    suites: List[str],
    iterations: int,
    seed: int,
) -> Dict[str, Dict[str, Any]]:
    result: Dict[str, Dict[str, Any]] = {}

    for offset, pid in enumerate(participant_ids):
        rng = random.Random(seed + offset)
        pid_records = [record for record in records if record.get("participant_id") == pid]
        suite_metrics: Dict[str, Any] = {}

        total_scored = 0
        total_passed = 0
        suite_macro_values: List[float] = []

        for suite in suites:
            suite_records = [record for record in pid_records if record.get("suite") == suite]
            scored = [record for record in suite_records if record.get("status") == "scored"]
            passed = sum(1 for record in scored if record.get("score", {}).get("pass"))
            micro = compute_suite_micro(suite_records)
            macro = compute_suite_macro(suite_records)
            micro_ci = bootstrap_micro_ci(suite_records, iterations, rng)
            macro_ci = bootstrap_macro_ci(suite_records, iterations, rng)

            suite_metrics[suite] = {
                "total": len(scored),
                "passed": passed,
                "micro": micro,
                "macro": macro,
                "micro_ci": micro_ci,
                "macro_ci": macro_ci,
            }

            total_scored += len(scored)
            total_passed += passed
            if macro is not None:
                suite_macro_values.append(macro)

        overall_micro = None
        if total_scored > 0:
            overall_micro = total_passed / float(total_scored)

        overall_macro = None
        if suite_macro_values:
            overall_macro = sum(suite_macro_values) / float(len(suite_macro_values))

        result[pid] = {
            "suite_metrics": suite_metrics,
            "overall": {
                "total": total_scored,
                "passed": total_passed,
                "micro": overall_micro,
                "macro": overall_macro,
            },
        }

    return result


def build_case_outcome_map(records: List[Dict[str, Any]], participant_id: str, suite: Optional[str] = None) -> Dict[str, bool]:
    mapped: Dict[str, bool] = {}
    for record in records:
        if record.get("participant_id") != participant_id:
            continue
        if suite and record.get("suite") != suite:
            continue
        if record.get("status") != "scored":
            continue
        case_id = record.get("case", {}).get("id")
        case_suite = record.get("suite")
        if not case_id or not case_suite:
            continue
        key = f"{case_suite}::{case_id}"
        mapped[key] = bool(record.get("score", {}).get("pass"))
    return mapped


def compute_stats(
    records: List[Dict[str, Any]],
    participant_metrics: Dict[str, Dict[str, Any]],
    participant_order: List[str],
    suites: List[str],
    iterations: int,
    seed: int,
) -> Dict[str, Any]:
    if "s2f-agent" not in participant_order:
        return {"comparisons": []}

    main_baselines = [pid for pid in participant_order if pid != "s2f-agent"]
    comparisons: List[Dict[str, Any]] = []

    for idx, baseline_id in enumerate(main_baselines):
        if baseline_id.startswith("o3-mini-"):
            continue

        rng = random.Random(seed + 1000 + idx)
        for suite in ["overall"] + suites:
            left = build_case_outcome_map(records, "s2f-agent", None if suite == "overall" else suite)
            right = build_case_outcome_map(records, baseline_id, None if suite == "overall" else suite)

            aligned_keys = sorted(set(left.keys()) & set(right.keys()))
            if not aligned_keys:
                continue

            s2f_outcomes = [left[key] for key in aligned_keys]
            baseline_outcomes = [right[key] for key in aligned_keys]

            s2f_micro = sum(1 for item in s2f_outcomes if item) / float(len(s2f_outcomes))
            baseline_micro = sum(1 for item in baseline_outcomes if item) / float(len(baseline_outcomes))
            delta = s2f_micro - baseline_micro

            n10 = sum(1 for a, b in zip(s2f_outcomes, baseline_outcomes) if a and not b)
            n01 = sum(1 for a, b in zip(s2f_outcomes, baseline_outcomes) if not a and b)
            p_value = exact_mcnemar_p_value(n01=n01, n10=n10)
            delta_ci = paired_bootstrap_delta_ci(s2f_outcomes, baseline_outcomes, iterations, rng)

            comparisons.append(
                {
                    "suite": suite,
                    "target": "s2f-agent",
                    "baseline": baseline_id,
                    "n": len(aligned_keys),
                    "target_micro": s2f_micro,
                    "baseline_micro": baseline_micro,
                    "delta_micro": delta,
                    "delta_micro_ci": delta_ci,
                    "mcnemar": {
                        "n01_target_fail_baseline_pass": n01,
                        "n10_target_pass_baseline_fail": n10,
                        "p_value": p_value,
                    },
                }
            )

    macro_summary: Dict[str, Any] = {}
    for pid, metrics in participant_metrics.items():
        macro_summary[pid] = {
            "overall_macro": metrics.get("overall", {}).get("macro"),
            "suite_macro": {
                suite: metrics.get("suite_metrics", {}).get(suite, {}).get("macro") for suite in suites
            },
            "suite_macro_ci": {
                suite: metrics.get("suite_metrics", {}).get(suite, {}).get("macro_ci") for suite in suites
            },
        }

    return {
        "comparisons": comparisons,
        "macro_summary": macro_summary,
    }


def resolve_output_dir(output_dir_arg: Optional[str], benchmark_config: Dict[str, Any], repo_root: Path) -> Path:
    if output_dir_arg:
        return Path(output_dir_arg).resolve()

    defaults = benchmark_config.get("defaults", {})
    runs_root_rel = defaults.get("runs_root", "benchmark/runs")
    timestamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    return (repo_root / runs_root_rel / timestamp).resolve()


def get_participant_map(participants_config: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    entries = participants_config.get("participants")
    if not isinstance(entries, list):
        raise ValueError("participants config must include a 'participants' list")

    mapped: Dict[str, Dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        pid = entry.get("id")
        if isinstance(pid, str) and pid.strip():
            mapped[pid] = entry
    return mapped


def load_enabled_skills(repo_root: Path, include_disabled: bool) -> List[Dict[str, Any]]:
    skills_yaml = load_yaml(repo_root / "registry/skills.yaml")
    skills = skills_yaml.get("skills")
    if not isinstance(skills, list):
        return []

    output: List[Dict[str, Any]] = []
    for skill in skills:
        if not isinstance(skill, dict):
            continue
        enabled = bool(skill.get("enabled", False))
        if include_disabled or enabled:
            output.append(skill)
    return output


def participant_requires_openai(participant: Dict[str, Any]) -> bool:
    return participant.get("kind") == "openai_chat"


def run_benchmark(args: argparse.Namespace) -> int:
    repo_root = Path(__file__).resolve().parents[2]

    benchmark_config_path = (repo_root / args.config).resolve()
    participants_config_path = (repo_root / args.participants_config).resolve()

    benchmark_config = load_yaml(benchmark_config_path)
    participants_config = load_yaml(participants_config_path)

    defaults = benchmark_config.get("defaults", {})

    suites = parse_csv_arg(args.suites) or to_str_list(defaults.get("suites"))
    supported = {"routing", "groundedness", "task_success"}
    invalid_suites = [suite for suite in suites if suite not in supported]
    if invalid_suites:
        raise ValueError(f"unsupported suites: {invalid_suites}")

    participant_map = get_participant_map(participants_config)
    selected_participants = parse_csv_arg(args.participants)
    if not selected_participants:
        selected_participants = to_str_list(participants_config.get("default_participants"))

    if not args.no_ablations and "o3-mini" in selected_participants:
        for pid in to_str_list(defaults.get("ablation_participants")):
            if pid and pid not in selected_participants:
                selected_participants.append(pid)

    missing_participants = [pid for pid in selected_participants if pid not in participant_map]
    if missing_participants:
        raise ValueError(f"unknown participants: {missing_participants}")

    selected_configs = {pid: participant_map[pid] for pid in selected_participants}

    openai_participants = [pid for pid in selected_participants if participant_requires_openai(selected_configs[pid])]
    api_key = args.openai_api_key or os.environ.get("OPENAI_API_KEY", "")
    if openai_participants and not args.dry_run and not args.mock_response_dir and not api_key:
        raise RuntimeError(
            "OPENAI_API_KEY is required for OpenAI participants. "
            "Use --participants s2f-agent for local-only runs or set OPENAI_API_KEY."
        )

    output_dir = resolve_output_dir(args.output_dir, benchmark_config, repo_root)
    raw_outputs_dir = output_dir / "raw_outputs"
    case_records_dir = output_dir / "case_records"
    output_dir.mkdir(parents=True, exist_ok=True)
    raw_outputs_dir.mkdir(parents=True, exist_ok=True)
    case_records_dir.mkdir(parents=True, exist_ok=True)

    include_disabled = bool(defaults.get("include_disabled_skills", False))
    skills = load_enabled_skills(repo_root, include_disabled=include_disabled)
    known_skill_ids = {skill.get("id") for skill in skills if isinstance(skill.get("id"), str)}

    task_contracts_path = repo_root / "registry/task_contracts.yaml"
    output_contracts_path = repo_root / "registry/output_contracts.yaml"
    task_contracts = load_yaml(task_contracts_path)

    case_files = benchmark_config.get("case_files")
    if not isinstance(case_files, dict):
        raise ValueError("benchmark config missing case_files mapping")

    suite_cases = load_suite_cases(case_files, suites, repo_root)

    templates_root = repo_root / "benchmark/prompts"
    template_cache: Dict[str, str] = {}
    for variant, template_file in PROMPT_VARIANT_TO_TEMPLATE.items():
        template_cache[variant] = read_text(templates_root / template_file)

    family_descriptions = benchmark_config.get("family_descriptions")
    if not isinstance(family_descriptions, dict):
        family_descriptions = {}

    task_catalog_text = format_task_catalog(task_contracts)
    skill_catalog_text = format_skill_catalog(skills, family_descriptions)
    task_contracts_text = read_text(task_contracts_path)
    output_contracts_text = read_text(output_contracts_path)

    timeout_s = int(args.openai_timeout or defaults.get("openai_timeout_seconds") or 120)
    max_retries = int(args.openai_max_retries if args.openai_max_retries is not None else defaults.get("openai_max_retries") or 1)
    iterations = int(args.bootstrap_iterations or defaults.get("bootstrap_iterations") or 2000)

    openai_base_url = args.openai_base_url or defaults.get("openai_base_url") or "https://api.openai.com/v1"

    records: List[Dict[str, Any]] = []

    for participant_id in selected_participants:
        participant = selected_configs[participant_id]
        prompt_variant = participant.get("prompt_variant", "catalog+contracts")
        if participant.get("kind") == "openai_chat" and prompt_variant not in template_cache:
            raise ValueError(f"unsupported prompt variant: {prompt_variant}")

        for suite in suites:
            for case in suite_cases.get(suite, []):
                start = time.time()
                raw_text = ""
                status = "scored"
                error: Optional[str] = None
                payload_snapshot: Optional[Dict[str, Any]] = None

                if participant.get("kind") == "local_agent":
                    if suite == "routing":
                        top_k = max(1, len(skills))
                        cmd = [
                            "bash",
                            str(repo_root / "scripts/route_query.sh"),
                            "--query",
                            str(case.get("query") or ""),
                            "--top-k",
                            str(top_k),
                            "--format",
                            "json",
                        ]
                    else:
                        cmd = [
                            "bash",
                            str(repo_root / "scripts/run_agent.sh"),
                            "--query",
                            str(case.get("query") or ""),
                            "--format",
                            "json",
                        ]

                    task = case.get("task")
                    if isinstance(task, str) and task.strip():
                        cmd.extend(["--task", task])
                    if include_disabled:
                        cmd.append("--include-disabled")

                    raw_text, parsed_json, run_error = run_subprocess_json(cmd)
                    if run_error:
                        error = run_error
                        normalized = normalize_from_raw_text(raw_text, known_skill_ids)
                    else:
                        normalized = normalize_from_object(parsed_json or {}, raw_text, known_skill_ids)

                elif participant.get("kind") == "openai_chat":
                    mock_response_dir = Path(args.mock_response_dir).resolve() if args.mock_response_dir else None
                    if mock_response_dir:
                        mock_base = mock_response_dir / participant_id / suite
                        txt_path = mock_base / f"{case['id']}.txt"
                        json_path = mock_base / f"{case['id']}.json"
                        if txt_path.exists():
                            raw_text = txt_path.read_text(encoding="utf-8")
                        elif json_path.exists():
                            raw_text = json_path.read_text(encoding="utf-8")
                        else:
                            status = "skipped"
                            error = f"missing_mock_response:{txt_path}"
                            normalized = {
                                "decision": None,
                                "primary_skill": None,
                                "secondary_skills": [],
                                "clarify_question": None,
                                "constraints": [],
                                "plan": None,
                                "raw_response": "",
                                "validation_errors": [error],
                            }
                            elapsed_ms = int((time.time() - start) * 1000)
                            record = {
                                "timestamp": iso_utc_now(),
                                "suite": suite,
                                "participant_id": participant_id,
                                "participant_label": participant.get("label", participant_id),
                                "participant_kind": participant.get("kind"),
                                "status": status,
                                "error": error,
                                "elapsed_ms": elapsed_ms,
                                "case": case,
                                "normalized": normalized,
                                "score": {"pass": False, "checks": [{"name": "skipped", "pass": False, "reason": error}]},
                            }
                            raw_output_rel = Path("raw_outputs") / participant_id / suite / f"{case['id']}.txt"
                            record_path_rel = Path("case_records") / participant_id / suite / f"{case['id']}.json"
                            write_raw(output_dir / raw_output_rel, raw_text)
                            record["raw_output_path"] = raw_output_rel.as_posix()
                            record["record_path"] = record_path_rel.as_posix()
                            write_record(output_dir / record_path_rel, record)
                            records.append(record)
                            continue

                        normalized = normalize_from_raw_text(raw_text, known_skill_ids)

                    elif args.dry_run:
                        status = "skipped"
                        error = "dry_run_openai_skipped"
                        normalized = {
                            "decision": None,
                            "primary_skill": None,
                            "secondary_skills": [],
                            "clarify_question": None,
                            "constraints": [],
                            "plan": None,
                            "raw_response": "",
                            "validation_errors": [error],
                        }

                    else:
                        template_text = template_cache[prompt_variant]
                        prompt = render_prompt(
                            template_text=template_text,
                            suite=suite,
                            case=case,
                            skill_catalog_text=skill_catalog_text,
                            task_catalog_text=task_catalog_text,
                            task_contracts_text=task_contracts_text,
                            output_contracts_text=output_contracts_text,
                        )
                        openai_result = call_openai_chat(
                            participant=participant,
                            prompt=prompt,
                            api_key=api_key,
                            base_url=openai_base_url,
                            timeout_s=timeout_s,
                            max_retries=max_retries,
                        )
                        payload_snapshot = openai_result.get("payload")
                        raw_text = str(openai_result.get("raw_text") or "")
                        if not openai_result.get("ok"):
                            error = str(openai_result.get("error") or "openai_error")
                        normalized = normalize_from_raw_text(raw_text, known_skill_ids)

                else:
                    raise ValueError(f"Unsupported participant kind: {participant.get('kind')}")

                score = score_case(suite, case, normalized)
                if status == "skipped":
                    score = {"pass": False, "checks": [{"name": "skipped", "pass": False, "reason": error}]}

                elapsed_ms = int((time.time() - start) * 1000)
                record = {
                    "timestamp": iso_utc_now(),
                    "suite": suite,
                    "participant_id": participant_id,
                    "participant_label": participant.get("label", participant_id),
                    "participant_kind": participant.get("kind"),
                    "status": status,
                    "error": error,
                    "elapsed_ms": elapsed_ms,
                    "case": case,
                    "normalized": normalized,
                    "score": score,
                    "prompt_variant": prompt_variant,
                }
                if payload_snapshot is not None:
                    record["openai_payload"] = payload_snapshot

                raw_output_rel = Path("raw_outputs") / participant_id / suite / f"{case['id']}.txt"
                record_path_rel = Path("case_records") / participant_id / suite / f"{case['id']}.json"
                write_raw(output_dir / raw_output_rel, raw_text)
                record["raw_output_path"] = raw_output_rel.as_posix()
                record["record_path"] = record_path_rel.as_posix()
                write_record(output_dir / record_path_rel, record)
                records.append(record)

    participant_metrics = compute_participant_metrics(
        records=records,
        participant_ids=selected_participants,
        suites=suites,
        iterations=iterations,
        seed=args.seed,
    )

    stats = compute_stats(
        records=records,
        participant_metrics=participant_metrics,
        participant_order=selected_participants,
        suites=suites,
        iterations=iterations,
        seed=args.seed,
    )

    run_metadata = {
        "benchmark_name": benchmark_config.get("benchmark_name", "benchmark"),
        "generated_at": iso_utc_now(),
        "seed": args.seed,
        "dry_run": bool(args.dry_run),
        "participants": selected_participants,
        "suites": suites,
        "openai_base_url": openai_base_url,
        "openai_timeout_seconds": timeout_s,
        "openai_max_retries": max_retries,
        "bootstrap_iterations": iterations,
        "config_paths": {
            "benchmark": str(benchmark_config_path),
            "participants": str(participants_config_path),
        },
        "output_dir": str(output_dir),
    }

    summary_json = {
        "run_metadata": run_metadata,
        "participants": participant_metrics,
        "record_count": len(records),
    }

    (output_dir / "run_metadata.json").write_text(dump_json(run_metadata) + "\n", encoding="utf-8")
    (output_dir / "summary.json").write_text(dump_json(summary_json) + "\n", encoding="utf-8")
    (output_dir / "stats.json").write_text(dump_json(stats) + "\n", encoding="utf-8")

    summary_csv_path = output_dir / "summary.csv"
    with summary_csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "participant_id",
                "participant_label",
                "table_group",
                "suite",
                "total",
                "passed",
                "micro",
                "macro",
                "micro_ci_low",
                "micro_ci_high",
                "macro_ci_low",
                "macro_ci_high",
            ]
        )

        for pid in selected_participants:
            participant = selected_configs[pid]
            suite_metrics = participant_metrics.get(pid, {}).get("suite_metrics", {})
            for suite in suites:
                metrics = suite_metrics.get(suite, {})
                micro_ci = metrics.get("micro_ci") or [None, None]
                macro_ci = metrics.get("macro_ci") or [None, None]
                writer.writerow(
                    [
                        pid,
                        participant.get("label", pid),
                        participant.get("table_group", "main"),
                        suite,
                        metrics.get("total"),
                        metrics.get("passed"),
                        metrics.get("micro"),
                        metrics.get("macro"),
                        micro_ci[0],
                        micro_ci[1],
                        macro_ci[0],
                        macro_ci[1],
                    ]
                )

            overall = participant_metrics.get(pid, {}).get("overall", {})
            writer.writerow(
                [
                    pid,
                    participant.get("label", pid),
                    participant.get("table_group", "main"),
                    "overall",
                    overall.get("total"),
                    overall.get("passed"),
                    overall.get("micro"),
                    overall.get("macro"),
                    None,
                    None,
                    None,
                    None,
                ]
            )

    table_markdown = build_table_markdown(
        participant_order=selected_participants,
        participant_configs=selected_configs,
        participant_metrics=participant_metrics,
        suites=suites,
    )
    (output_dir / "table.md").write_text(table_markdown, encoding="utf-8")

    default_main = to_str_list(defaults.get("main_participants"))
    main_participants = [pid for pid in default_main if pid in selected_participants]
    if not main_participants:
        main_participants = [pid for pid in selected_participants if selected_configs[pid].get("table_group") == "main"]

    examples = choose_examples(
        records=records,
        main_participant_ids=main_participants,
        limit_per_suite=int(defaults.get("example_limit_per_suite") or 2),
    )
    examples_markdown = render_examples_markdown(examples, output_root=output_dir)
    (output_dir / "examples.md").write_text(examples_markdown, encoding="utf-8")

    print(f"benchmark complete: {output_dir}")
    print(f"participants: {', '.join(selected_participants)}")
    print(f"suites: {', '.join(suites)}")
    for pid in selected_participants:
        overall = participant_metrics.get(pid, {}).get("overall", {})
        print(
            f"summary [{pid}] micro={safe_percent(overall.get('micro'))} "
            f"macro={safe_percent(overall.get('macro'))} "
            f"n={overall.get('total', 0)}"
        )

    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run comparative benchmark on top of routing/groundedness/task_success eval suites."
    )
    parser.add_argument("--config", default="benchmark/config/benchmark.yaml", help="Benchmark config path")
    parser.add_argument(
        "--participants-config",
        default="benchmark/config/participants.yaml",
        help="Participants config path",
    )
    parser.add_argument(
        "--participants",
        default="",
        help="Comma-separated participant IDs (default from participants config)",
    )
    parser.add_argument(
        "--suites",
        default="",
        help="Comma-separated suites to run (routing,groundedness,task_success)",
    )
    parser.add_argument("--output-dir", default="", help="Output directory for this benchmark run")
    parser.add_argument("--seed", type=int, default=7, help="Random seed")
    parser.add_argument("--dry-run", action="store_true", help="Skip OpenAI calls and mark OpenAI participants as skipped")
    parser.add_argument("--openai-base-url", default="", help="OpenAI-compatible API base URL")
    parser.add_argument("--openai-api-key", default="", help="Override OPENAI_API_KEY")
    parser.add_argument("--openai-timeout", type=int, default=0, help="OpenAI request timeout seconds")
    parser.add_argument("--openai-max-retries", type=int, default=None, help="OpenAI retry count for 429/5xx")
    parser.add_argument("--bootstrap-iterations", type=int, default=0, help="Bootstrap iterations for confidence intervals")
    parser.add_argument("--mock-response-dir", default="", help="Read OpenAI responses from local fixtures directory")
    parser.add_argument("--no-ablations", action="store_true", help="Disable automatic o3-mini ablation participants")
    return parser


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()
    try:
        return run_benchmark(args)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
