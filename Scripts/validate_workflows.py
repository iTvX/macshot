#!/usr/bin/env python3

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
WORKFLOW_DIR = ROOT_DIR / ".github" / "workflows"
RUN_BLOCK = re.compile(r"^(?P<indent>\s*)run:\s*\|\s*$")
GITHUB_EXPRESSION = re.compile(r"\$\{\{.*?\}\}")


def indentation(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def shell_blocks(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    blocks: list[tuple[int, str]] = []
    index = 0

    while index < len(lines):
        match = RUN_BLOCK.match(lines[index])
        if match is None:
            index += 1
            continue

        marker_indent = len(match.group("indent"))
        start_line = index + 2
        index += 1
        content: list[str] = []

        while index < len(lines):
            line = lines[index]
            if line.strip() and indentation(line) <= marker_indent:
                break
            content.append(line)
            index += 1

        nonempty_indents = [indentation(line) for line in content if line.strip()]
        if not nonempty_indents:
            continue
        content_indent = min(nonempty_indents)
        script = "\n".join(
            line[content_indent:] if line.strip() else "" for line in content
        )
        blocks.append((start_line, GITHUB_EXPRESSION.sub("GITHUB_EXPRESSION", script)))

    return blocks


def main() -> int:
    failures = 0
    workflow_paths = sorted(WORKFLOW_DIR.glob("*.yml")) + sorted(
        WORKFLOW_DIR.glob("*.yaml")
    )

    for path in workflow_paths:
        for start_line, script in shell_blocks(path):
            result = subprocess.run(
                ["/bin/bash", "-n"],
                input=script,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode == 0:
                continue
            failures += 1
            detail = result.stderr.strip() or "unknown shell syntax error"
            print(
                f"{path.relative_to(ROOT_DIR)}:{start_line}: {detail}",
                file=sys.stderr,
            )

    if failures:
        return 1

    print("Workflow shell-block validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
