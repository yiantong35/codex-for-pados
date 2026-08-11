#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DESTINATION="${CODEX_IOS_DESTINATION:-platform=iOS Simulator,name=iPad-Test}"
DERIVED_DATA="${CODEX_DERIVED_DATA:-$ROOT_DIR/ios/DerivedData}"
IOS_PARALLEL_TESTING="${CODEX_IOS_PARALLEL_TESTING:-NO}"
OPEN_SPEC_CHANGE="${CODEX_OPENSPEC_CHANGE:-functionality-review-fixes}"

run_stage() {
    local label="$1"
    shift
    printf '\n==> %s\n' "$label"
    if "$@"; then
        printf 'PASS: %s\n' "$label"
    else
        local status=$?
        printf 'FAIL: %s (exit %s)\n' "$label" "$status" >&2
        return "$status"
    fi
}

generate_ios_project() {
    cd "$ROOT_DIR/ios"
    xcodegen generate
}

test_ios() {
    local common=(
        -quiet
        -project "$ROOT_DIR/ios/CodexRemote.xcodeproj"
        -scheme CodexRemote
        -destination "$IOS_DESTINATION"
        -derivedDataPath "$DERIVED_DATA"
    )
    xcodebuild test "${common[@]}" \
        -parallel-testing-enabled "$IOS_PARALLEL_TESTING" \
        -skip-testing:CodexRemoteTests/OrientationSnapshotTests \
        -skip-testing:CodexRemoteTests/RelayPairingImportViewModelTests \
        || return $?
    xcodebuild test "${common[@]}" \
        -parallel-testing-enabled NO \
        -test-iterations 3 \
        -retry-tests-on-failure \
        -only-testing:CodexRemoteTests/OrientationSnapshotTests \
        || return $?
    xcodebuild test "${common[@]}" \
        -parallel-testing-enabled NO \
        -test-iterations 3 \
        -retry-tests-on-failure \
        -only-testing:CodexRemoteTests/RelayPairingImportViewModelTests \
        || return $?
}

validate_openspec() {
    cd "$ROOT_DIR"
    if [[ -d "$ROOT_DIR/openspec/changes/$OPEN_SPEC_CHANGE" ]]; then
        openspec validate "$OPEN_SPEC_CHANGE" --strict
    else
        openspec validate --specs --strict
    fi
}

check_git_diff() {
    cd "$ROOT_DIR"
    git diff --check
}

run_stage "Test RelayProtocol" swift test --package-path "$ROOT_DIR/packages/RelayProtocol"
run_stage "Test relay-server" swift test --package-path "$ROOT_DIR/relay-server"
run_stage "Test relay-dialout" swift test --package-path "$ROOT_DIR/relay-dialout"
run_stage "Test mac-daemon" swift test --package-path "$ROOT_DIR/mac-daemon"
run_stage "Generate iOS project" generate_ios_project
run_stage "Test iOS app" test_ios
run_stage "Analyze iOS app" xcodebuild analyze -quiet \
    -project "$ROOT_DIR/ios/CodexRemote.xcodeproj" \
    -scheme CodexRemote \
    -destination "$IOS_DESTINATION" \
    -derivedDataPath "$DERIVED_DATA"
run_stage "Validate OpenSpec" validate_openspec
run_stage "Check Git diff" check_git_diff
