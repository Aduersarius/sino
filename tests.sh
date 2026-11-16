#!/bin/bash
# Runs the FoldCore assertions. No Xcode, no XCTest: swiftc + the sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /tmp/sino_tests
swiftc -O "$ROOT/Sources/FoldCore.swift" "$ROOT/Tests/FoldCoreTests.swift" -o /tmp/sino_tests/foldcore
/tmp/sino_tests/foldcore
swiftc -O "$ROOT/Sources/CoreParsers.swift" "$ROOT/Tests/CoreParsersTests.swift" -o /tmp/sino_tests/coreparsers
/tmp/sino_tests/coreparsers
