#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

run_cjpm() {
    local directory=$1
    shift
    echo "==> ${directory#$repo_root/}: cjpm $*"
    (cd "$directory" && cjpm "$@")
}

python3 "$repo_root/scripts/check_std_only.py"
python3 "$repo_root/scripts/public_api_inventory.py" --check

run_cjpm "$repo_root/packages/toml" test
run_cjpm "$repo_root/packages/toml_macros" check
run_cjpm "$repo_root" test
run_cjpm "$repo_root/packages/toml_schema" test
run_cjpm "$repo_root/packages/toml_schema_macros" check
run_cjpm "$repo_root/packages/toml_schema_all" test

bash "$repo_root/scripts/check_example.sh"
echo "all local checks passed"
