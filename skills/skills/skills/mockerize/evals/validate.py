#!/usr/bin/env python3

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VALID_COMPLEXITIES = {"LOW", "MEDIUM", "HIGH"}
VALID_ASSERTION_TYPES = {"content_check"}


def load_json(name):
    with (ROOT / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def validate_quality_suite():
    suite = load_json("evals.json")
    assert suite.get("skill_name") == "mockerize"

    evals = suite.get("evals")
    assert isinstance(evals, list) and len(evals) >= 8

    ids = [case.get("id") for case in evals]
    names = [case.get("eval_name") for case in evals]
    assert len(ids) == len(set(ids)), "quality eval IDs must be unique"
    assert len(names) == len(set(names)), "quality eval names must be unique"

    required = {
        "id",
        "eval_name",
        "complexity",
        "dimensions",
        "prompt",
        "expected_output",
        "trap",
        "files",
        "assertions",
    }

    dimension_coverage = set()
    for case in evals:
        missing = required - set(case)
        assert not missing, f"{case.get('eval_name')}: missing {sorted(missing)}"
        assert case["complexity"] in VALID_COMPLEXITIES
        assert isinstance(case["dimensions"], list) and case["dimensions"]
        assert isinstance(case["prompt"], str) and len(case["prompt"]) >= 80
        assert isinstance(case["expected_output"], str) and case["expected_output"]
        assert isinstance(case["trap"], str) and case["trap"]
        assert isinstance(case["files"], list)
        assert isinstance(case["assertions"], list) and len(case["assertions"]) >= 6

        dimension_coverage.update(case["dimensions"])
        assertion_texts = []
        for assertion in case["assertions"]:
            assert set(assertion) == {"text", "type"}
            assert assertion["type"] in VALID_ASSERTION_TYPES
            assert isinstance(assertion["text"], str) and assertion["text"]
            assertion_texts.append(assertion["text"])
        assert len(assertion_texts) == len(set(assertion_texts))

    required_dimensions = {
        "visual_fidelity",
        "responsive_reasoning",
        "data_mapping",
        "backend_adjustment",
        "backward_compatibility",
        "protected_flow",
        "interaction_states",
        "mode_selection",
        "authorization",
        "rendered_verification",
    }
    missing_dimensions = required_dimensions - dimension_coverage
    assert not missing_dimensions, (
        f"quality suite missing dimensions: {sorted(missing_dimensions)}"
    )

    return len(evals), len(dimension_coverage)


def validate_trigger_suite():
    cases = load_json("trigger-evals.json")
    assert isinstance(cases, list) and len(cases) >= 16

    queries = [case.get("query") for case in cases]
    assert len(queries) == len(set(queries)), "trigger queries must be unique"

    positives = 0
    negatives = 0
    for case in cases:
        assert set(case) == {"query", "should_trigger"}
        assert isinstance(case["query"], str) and len(case["query"]) >= 30
        assert isinstance(case["should_trigger"], bool)
        if case["should_trigger"]:
            positives += 1
        else:
            negatives += 1

    assert positives >= 8
    assert negatives >= 8
    assert abs(positives - negatives) <= 2
    return len(cases), positives, negatives


def main():
    quality_count, dimension_count = validate_quality_suite()
    trigger_count, positives, negatives = validate_trigger_suite()
    print(
        "mockerize benchmarks valid: "
        f"{quality_count} quality evals across {dimension_count} dimensions; "
        f"{trigger_count} trigger evals ({positives} positive, {negatives} negative)"
    )


if __name__ == "__main__":
    main()
