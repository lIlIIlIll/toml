#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
report_root="$repo_root/coverage_out"
mkdir -p "$report_root"

run_coverage() {
    local label=$1
    local package_dir=$2
    local minimum=$3
    local output_dir="$report_root/$label"

    # cjcov stores counters beside the module and under cov_output. Start from
    # an empty generated-artifact set so removed tests cannot leave stale hits.
    for counter in "$package_dir"/*.gcda; do
        [[ -e "$counter" ]] && rm -f -- "$counter"
    done
    if [[ -d "$package_dir/cov_output" ]]; then
        rm -rf -- "$package_dir/cov_output"
    fi
    if [[ -d "$output_dir" ]]; then
        rm -rf -- "$output_dir"
    fi

    echo "==> $label: cjpm clean"
    (cd "$package_dir" && cjpm clean)
    echo "==> $label: cjpm test --coverage"
    (cd "$package_dir" && cjpm test --coverage --no-color --no-progress)
    echo "==> $label: cjcov"
    (cd "$package_dir" && cjcov --root=. --source=src \
        --output="$output_dir" --json --html-details)
    python3 "$repo_root/scripts/check_coverage.py" \
        "$output_dir/coverage.json" --label "$label" --minimum "$minimum"
}

run_coverage core "$repo_root/packages/toml" 70
run_coverage schema "$repo_root/packages/toml_schema" 65

echo "line coverage gates passed"
