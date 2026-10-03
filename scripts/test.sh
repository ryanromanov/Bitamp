#!/bin/sh
# Runs the test suite. Works around a Command Line Tools bug where an incremental
# rebuild of the tests fails with "plugin for module 'TestingMacros' not found".
# The plugin itself is fine; stale build state is the trigger. Clear the caches and
# retry, and if that isn't enough, retry from a clean build.
set -u
cd "$(dirname "$0")/.."

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Runs swift test, showing its output as it goes, and sets $status to its exit code.
run() {
    status=0
    swift test "$@" > "$log" 2>&1 &
    pid=$!
    tail -f -n +1 "$log" &
    tail_pid=$!
    wait "$pid" || status=$?
    sleep 0.2
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null
}

stale() {
    [ "$status" -ne 0 ] && grep -q "plugin for module 'TestingMacros' not found" "$log"
}

run "$@"
if stale; then
    echo "--- Stale build cache; clearing it and retrying."
    rm -rf .build/out/ModuleCache.noindex .build/out/Intermediates.noindex
    run "$@"
fi
if stale; then
    echo "--- Still stale; retrying from a clean build."
    rm -rf .build
    run "$@"
fi
exit "$status"
