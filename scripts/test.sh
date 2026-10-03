#!/bin/sh
# Runs the test suite. Works around a Command Line Tools bug where an incremental
# rebuild of the tests fails with "plugin for module 'TestingMacros' not found":
# the cached module goes stale, so clear it and try once more.
set -u
cd "$(dirname "$0")/.."

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
swift test "$@" 2>&1 | tee "$log"
status=$?
if grep -q "plugin for module 'TestingMacros' not found" "$log"; then
    echo "--- Stale module cache; clearing it and retrying."
    rm -rf .build/out/ModuleCache.noindex
    swift test "$@"
    status=$?
fi
exit $status
