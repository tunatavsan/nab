#!/bin/bash
# The gate CI runs: formatting, a build that treats warnings as errors, then every test. Does not launch the app.
set -euo pipefail
cd -P "$(dirname "$0")/.."
logs="$(mktemp -d "${TMPDIR:-/tmp}/nab-check.XXXXXX")"
trap 'rm -rf -- "$logs"' EXIT

if ! swift format lint --strict -r Sources Tests scripts/MakeIcon.swift >"$logs/format.log" 2>&1; then
    cat "$logs/format.log"
    echo "CHECK: FORMAT — run scripts/format.sh" >&2
    exit 1
fi
if ! swift build -Xswiftc -warnings-as-errors >"$logs/build.log" 2>&1; then
    cat "$logs/build.log"
    echo "CHECK: BUILD FAILED" >&2
    exit 1
fi
if grep -q 'warning:' "$logs/build.log"; then
    cat "$logs/build.log"
    echo "CHECK: BUILD WARNINGS" >&2
    exit 1
fi
if ! swift test -Xswiftc -warnings-as-errors >"$logs/test.log" 2>&1; then
    cat "$logs/test.log"
    echo "CHECK: TESTS FAILED" >&2
    exit 1
fi
if grep -q 'warning:' "$logs/test.log"; then
    cat "$logs/test.log"
    echo "CHECK: TEST WARNINGS" >&2
    exit 1
fi
summary="$(grep 'Test run with.*passed' "$logs/test.log" | tail -n 1 || true)"
if [[ -z "$summary" ]]; then
    cat "$logs/test.log"
    echo "CHECK: NO PASSING TEST SUMMARY" >&2
    exit 1
fi
printf 'CHECK: OK — formatted — build 0 warnings — %s\n' "$summary"
