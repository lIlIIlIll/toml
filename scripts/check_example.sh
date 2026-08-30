#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
example_dir="$repo_root/examples/basic"
expected=$'title=demo\nport=8080\nedited_port=9090\noriginal_unchanged=true'
(cd "$example_dir" && cjpm build)
example_bin="$example_dir/target/release/bin/main"
if [[ -x "${example_bin}.exe" ]]; then
    example_bin="${example_bin}.exe"
fi
actual=$("$example_bin")

if [[ "$actual" != "$expected" ]]; then
    echo "basic example output mismatch" >&2
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    exit 1
fi

printf '%s\n' "$actual"
