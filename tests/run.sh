#!/bin/bash
# Runs Booth Check's unit tests. Each tests/test_*.swift is compiled next to a copy of BoothCheck.swift
# with @main removed (and showCheck made visible), in a temporary folder, then run. The tests cover the
# check logic kept outside Booth for this (showIsOpen, appNapCheck, dmxDriverPIDs, showOpenNext,
# replugFrame, startUpSettles…); they read nothing from this Mac and change nothing.
#
# Usage: bash tests/run.sh      ->  every test's PASS/FAIL; exits non-zero if any fail
set -uo pipefail
cd "$(dirname "$0")/.."

# Same choice as build.sh: the first SDK this Swift compiler accepts.
pick_sdk() {
    local probe
    probe=$(mktemp -d)
    printf 'import SwiftUI\n' > "$probe/p.swift"
    for sdk in "$(xcrun --show-sdk-path 2>/dev/null)" /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
        [ -d "$sdk" ] || continue
        if swiftc -sdk "$sdk" -typecheck "$probe/p.swift" 2>/dev/null; then echo "$sdk"; rm -rf "$probe"; return; fi
    done
    rm -rf "$probe"
    echo "No SDK works with this Swift compiler." >&2
    return 1
}
SDK=$(pick_sdk) || exit 1

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sed -e 's/^@main$//' -e 's/private func showCheck/func showCheck/' BoothCheck.swift > "$work/BoothCheck.swift"

failed=0
for t in tests/test_*.swift; do
    name=$(basename "$t" .swift)
    mkdir -p "$work/$name"
    cp "$t" "$work/$name/main.swift"
    echo "== $name"
    if ! swiftc -swift-version 5 -sdk "$SDK" "$work/BoothCheck.swift" "$work/$name/main.swift" \
            -o "$work/$name/run" > "$work/$name/build.log" 2>&1; then
        grep -E 'error' "$work/$name/build.log"
        failed=1
        continue
    fi
    "$work/$name/run" || failed=1
done
[ $failed -eq 0 ] && echo "== all tests pass" || echo "== some tests FAILED"
exit $failed
