#!/usr/bin/env python3
"""Enforce production-source line coverage from a cjcov JSON report."""

from __future__ import annotations

import argparse
from decimal import Decimal
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--minimum", type=Decimal, required=True)
    parser.add_argument("--label", default="package")
    args = parser.parse_args()

    payload = json.loads(args.report.read_text(encoding="utf-8"))
    production = [
        item
        for item in payload.get("fileLists", [])
        if item.get("filepath", "").startswith("src/")
        and not item.get("filepath", "").endswith("_test.cj")
    ]
    if not production:
        raise SystemExit(f"{args.label}: report contains no production src/*.cj files")

    total = sum(int(item["totalLines"]) for item in production)
    hit = sum(len(item.get("hitLines", [])) for item in production)
    if total <= 0:
        raise SystemExit(f"{args.label}: report contains no instrumented production lines")

    percentage = Decimal(hit) * Decimal(100) / Decimal(total)
    print(
        f"{args.label} line coverage: {hit}/{total} "
        f"({percentage.quantize(Decimal('0.01'))}%), required >= {args.minimum}%"
    )
    if percentage < args.minimum:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
