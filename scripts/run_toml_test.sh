#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
adapter_dir="$repo_root/tools/toml_test_adapter"
adapter="$adapter_dir/target/release/bin/main"
toml_version=${TOML_VERSION:-1.1}
toml_test_version=v2.2.0

case "$toml_version" in
    1.0|1.1) ;;
    *)
        echo "TOML_VERSION must be 1.0 or 1.1" >&2
        exit 2
        ;;
esac

(cd "$adapter_dir" && cjpm build)

if [[ -n "${TOML_TEST_BIN:-}" ]]; then
    runner=("$TOML_TEST_BIN")
elif command -v toml-test >/dev/null 2>&1; then
    runner=(toml-test)
elif command -v go >/dev/null 2>&1; then
    runner=(go run "github.com/toml-lang/toml-test/v2/cmd/toml-test@${toml_test_version}")
else
    echo "toml-test or Go 1.19+ is required" >&2
    exit 2
fi

TOML_VERSION="$toml_version" "${runner[@]}" test \
    -toml="$toml_version" \
    -decoder="$adapter" \
    "$@"
