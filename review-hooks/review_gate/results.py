"""Reviewer result parsing.

Version 2 asks for one JSON object between fixed sentinels and validates
it before the harness renders Markdown. The legacy parser reads the three
version 1 marker lines; evidence marks it as legacy-v1.
"""

import json
import re
from dataclasses import dataclass, field

from . import RESULT_SCHEMA_VERSION
from .prompts import RESULT_BEGIN, RESULT_END

VERDICTS = ("SAFE", "MERGE-WITH-FIXES", "DO-NOT-MERGE", "INCONCLUSIVE")
RISK_CLASSES = ("security-money", "general", "none")
SEVERITIES = ("MUST-FIX", "SHOULD-FIX", "NIT")


class ResultError(Exception):
    """The reviewer output is not a trustworthy result. Exit code 2."""


@dataclass
class ParsedResult:
    verdict: str
    risk_class: str
    findings: list = field(default_factory=list)
    limitations: list = field(default_factory=list)
    parser: str = "json-v2"
    raw_text: str = ""

    @property
    def blocking(self):
        if self.verdict == "DO-NOT-MERGE":
            return True
        return any(f.get("severity") == "MUST-FIX" for f in self.findings)

    @property
    def completed(self):
        return self.verdict in ("SAFE", "MERGE-WITH-FIXES", "DO-NOT-MERGE")


def _require(condition, message):
    if not condition:
        raise ResultError(message)


def _validate_finding(index, finding):
    _require(isinstance(finding, dict), "finding %d is not an object" % index)
    _require(
        finding.get("severity") in SEVERITIES,
        "finding %d has invalid severity" % index,
    )
    for key in ("file", "trigger", "consequence", "fix"):
        _require(
            isinstance(finding.get(key), str) and finding[key].strip(),
            "finding %d is missing %s" % (index, key),
        )
    line = finding.get("line")
    _require(
        isinstance(line, int) and not isinstance(line, bool) and line >= 0,
        "finding %d has an invalid line" % index,
    )
    return {
        "severity": finding["severity"],
        "file": finding["file"],
        "line": finding["line"],
        "trigger": finding["trigger"],
        "consequence": finding["consequence"],
        "fix": finding["fix"],
    }


def parse_result_v2(stdout_text):
    begin = stdout_text.rfind(RESULT_BEGIN)
    _require(begin >= 0, "missing %s sentinel" % RESULT_BEGIN)
    end = stdout_text.find(RESULT_END, begin)
    _require(end >= 0, "missing %s sentinel" % RESULT_END)
    body = stdout_text[begin + len(RESULT_BEGIN):end].strip()
    try:
        data = json.loads(body)
    except json.JSONDecodeError as error:
        raise ResultError("result JSON is invalid: %s" % error)

    _require(isinstance(data, dict), "result is not a JSON object")
    _require(
        data.get("schema_version") == RESULT_SCHEMA_VERSION,
        "unsupported result schema_version: %r" % data.get("schema_version"),
    )
    _require(data.get("verdict") in VERDICTS, "invalid verdict")
    _require(data.get("risk_class") in RISK_CLASSES, "invalid risk_class")
    raw_findings = data.get("findings")
    _require(isinstance(raw_findings, list), "findings must be a list")
    findings = [
        _validate_finding(index, finding)
        for index, finding in enumerate(raw_findings)
    ]
    limitations = data.get("limitations")
    _require(isinstance(limitations, list), "limitations must be a list")
    _require(
        all(isinstance(item, str) for item in limitations),
        "limitations must be strings",
    )
    return ParsedResult(
        verdict=data["verdict"],
        risk_class=data["risk_class"],
        findings=findings,
        limitations=list(limitations),
        parser="json-v2",
        raw_text=stdout_text,
    )


def parse_result_legacy(stdout_text):
    lines = [line for line in stdout_text.splitlines() if line.strip()]
    tail = lines[-3:]
    _require(len(tail) == 3, "missing legacy completion markers")
    verdict = _legacy_marker(tail[0], "VERDICT")
    blockers = _legacy_marker(tail[1], "BLOCKERS")
    risk_class = _legacy_marker(tail[2], "RISK-CLASS")
    _require(verdict in VERDICTS, "invalid legacy verdict")
    _require(blockers in ("yes", "no"), "invalid legacy blockers marker")
    _require(risk_class in RISK_CLASSES, "invalid legacy risk class")
    findings = []
    if blockers == "yes" and verdict != "DO-NOT-MERGE":
        # The legacy contract carries no structured findings; keep the
        # blocking bit through one synthetic entry.
        findings = [{
            "severity": "MUST-FIX",
            "file": "unknown",
            "line": 0,
            "trigger": "legacy report marked blockers: yes",
            "consequence": "see the legacy report text",
            "fix": "see the legacy report text",
        }]
    return ParsedResult(
        verdict=verdict,
        risk_class=risk_class,
        findings=findings,
        limitations=[],
        parser="legacy-v1",
        raw_text=stdout_text,
    )


def _legacy_marker(line, key):
    match = re.fullmatch(r"%s: (.+)" % re.escape(key), line.strip())
    _require(match is not None, "missing legacy %s marker" % key)
    return match.group(1)


def parse_result(stdout_text, prompt_template_version):
    if prompt_template_version == "1":
        return parse_result_legacy(stdout_text)
    return parse_result_v2(stdout_text)
