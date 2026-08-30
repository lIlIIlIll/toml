#!/usr/bin/env python3
"""Reject stdx imports and stdx package dependencies in production sources."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
failures: list[str] = []

for path in sorted(ROOT.rglob("cjpm.toml")):
    if "target" in path.parts:
        continue
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if re.match(r"^\s*stdx(?:\s*=|\.)", line):
            failures.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")

source_roots = [ROOT / "src", ROOT / "packages", ROOT / "examples", ROOT / "tools"]
for source_root in source_roots:
    if not source_root.exists():
        continue
    for path in sorted(source_root.rglob("*.cj")):
        if "target" in path.parts:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if re.match(r"^\s*(?:public\s+)?import\s+stdx(?:\.|\s|$)", line):
                failures.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")

if failures:
    print("std-only dependency check failed:")
    print("\n".join(failures))
    raise SystemExit(1)

print("std-only dependency check passed")
