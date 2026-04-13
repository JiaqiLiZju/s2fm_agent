#!/usr/bin/env python3
"""Fixture-based tests for eval_benchmark.py."""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path


def load_module() -> object:
    repo_root = Path(__file__).resolve().parents[2]
    module_path = repo_root / "benchmark/tools/eval_benchmark.py"
    spec = importlib.util.spec_from_file_location("eval_benchmark", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EvalBenchmarkMockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = Path(__file__).resolve().parents[2]
        cls.fixtures = cls.repo_root / "benchmark/fixtures/mock_openai"
        cls.mod = load_module()
        cls.known_skills = {"dnabert2", "alphagenome-api", "nucleotide-transformer-v3"}

    def read_fixture(self, name: str) -> str:
        return (self.fixtures / name).read_text(encoding="utf-8")

    def test_valid_json_fixture_normalizes(self) -> None:
        raw = self.read_fixture("valid_response.json")
        normalized = self.mod.normalize_from_raw_text(raw, self.known_skills)
        self.assertEqual(normalized["decision"], "route")
        self.assertEqual(normalized["primary_skill"], "dnabert2")
        self.assertEqual(normalized["validation_errors"], [])

    def test_non_json_fixture_marks_parse_error(self) -> None:
        raw = self.read_fixture("non_json.txt")
        normalized = self.mod.normalize_from_raw_text(raw, self.known_skills)
        self.assertIsNone(normalized["decision"])
        self.assertTrue(normalized["validation_errors"])
        self.assertIn("raw_json_parse_error", normalized["validation_errors"][0])

    def test_missing_fields_fails_task_success_scoring(self) -> None:
        raw = self.read_fixture("missing_fields.json")
        normalized = self.mod.normalize_from_raw_text(raw, self.known_skills)
        case = {
            "id": "task_mock_001",
            "query": "Need embedding plan",
            "task": "embedding",
            "min_runnable_steps": 1,
            "min_expected_outputs": 1,
        }
        score = self.mod.score_task_success_case(case, normalized)
        self.assertFalse(score["pass"])
        by_name = {item["name"]: item for item in score["checks"]}
        self.assertFalse(by_name["plan_non_null"]["pass"])

    def test_unknown_skill_fails_groundedness_scoring(self) -> None:
        raw = self.read_fixture("unknown_skill.json")
        normalized = self.mod.normalize_from_raw_text(raw, self.known_skills)
        case = {
            "id": "grounded_mock_001",
            "query": "Need DNABERT2 embedding workflow",
            "task": "embedding",
            "expected_primary_skill": "dnabert2",
            "required_constraint_contains": "transformers",
            "forbidden_substring": "invented_cli_flag",
        }
        score = self.mod.score_groundedness_case(case, normalized)
        self.assertFalse(score["pass"])
        by_name = {item["name"]: item for item in score["checks"]}
        self.assertFalse(by_name["primary_skill"]["pass"])
        self.assertFalse(by_name["normalization_validation"]["pass"])

    def test_openai_retry_on_429_then_success(self) -> None:
        calls = []

        def fake_request(url, headers, payload, timeout_s):
            calls.append((url, payload.get("model"), payload.get("reasoning_effort")))
            if len(calls) == 1:
                return 429, "{\"error\":\"rate limit\"}"
            content = json.dumps({"decision": "route", "primary_skill": "dnabert2"})
            body = json.dumps({"choices": [{"message": {"content": content}}]})
            return 200, body

        participant = {
            "id": "o3-mini",
            "kind": "openai_chat",
            "model": "o3-mini",
            "reasoning_effort": "medium",
        }
        result = self.mod.call_openai_chat(
            participant=participant,
            prompt="test",
            api_key="test-key",
            base_url="https://api.openai.com/v1",
            timeout_s=5,
            max_retries=1,
            request_fn=fake_request,
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["attempts"], 2)
        self.assertEqual(len(calls), 2)

    def test_o3_mini_payload_includes_reasoning_effort(self) -> None:
        participant = {
            "id": "o3-mini",
            "kind": "openai_chat",
            "model": "o3-mini",
            "reasoning_effort": "medium",
        }
        payload = self.mod.build_openai_payload(participant, prompt="hello")
        self.assertEqual(payload["model"], "o3-mini")
        self.assertEqual(payload["reasoning_effort"], "medium")
        self.assertIn("response_format", payload)


if __name__ == "__main__":
    unittest.main(verbosity=2)
