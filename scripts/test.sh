#!/bin/zsh
set -euo pipefail
LAB_ROOT="${0:A:h:h}"
LAB_WORK="${NOTIFICATION_LAB_WORK:-$LAB_ROOT/work}"
mkdir -p "$LAB_WORK/build/module-cache" "$LAB_WORK/test-runs" "$LAB_ROOT/validation"
LAB_FIXTURE=$(mktemp -d "$LAB_WORK/test-runs/run.XXXXXX")
xcrun swiftc -swift-version 5 -module-cache-path "$LAB_WORK/build/module-cache" \
    "$LAB_ROOT/Sources/Core.swift" "$LAB_ROOT/Sources/Persistence.swift" "$LAB_ROOT/Sources/Configuration.swift" "$LAB_ROOT/Sources/DatabaseProbe.swift" "$LAB_ROOT/Sources/AccessibilityProbe.swift" \
    "$LAB_ROOT/Tests/ProbeTests.swift" -o "$LAB_WORK/build/probe-tests"
"$LAB_WORK/build/probe-tests" --db "$LAB_FIXTURE/fixture.sqlite" "$LAB_FIXTURE" \
    | tee "$LAB_ROOT/validation/unit-tests.txt"
