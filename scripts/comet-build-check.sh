#!/usr/bin/env bash
# Comet build guard: 构建 iOS app(模拟器)
set -euo pipefail
cd "$(dirname "$0")/../ios"
exec xcodebuild build -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData
