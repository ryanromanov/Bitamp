#!/bin/sh
# Runs the test suite. Works around a Swift Build bug where an incremental rebuild
# of the tests sometimes fails with "plugin for module 'TestingMacros' not found":
# the explicit-module build forgets to load the swift-testing macros, which live in
# a folder of their own. Naming that folder with -plugin-path stops it (7 of 16
# rebuilds failed without it, 0 of 18 with it). If it ever comes back, clear the
# caches and retry, and if that isn't enough, retry from a clean build.
set -u
cd "$(dirname "$0")/.."

plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    set -- -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi

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
