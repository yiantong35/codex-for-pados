#!/usr/bin/env bash
# Comet verify guard: 跑全量单测(模拟器)
set -euo pipefail
cd "$(dirname "$0")/../ios"
exec xcodebuild test -scheme CodexRemote -destination 'platform=iOS Simulator,name=iPad-Test' -derivedDataPath DerivedData
