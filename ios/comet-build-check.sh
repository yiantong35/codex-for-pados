#!/bin/bash
# Comet build/verify guard 的构建检查脚本。
# 单独成脚本是因为 comet-guard 的 build_command 不允许 shell 元字符（=、, 等），
# 而 xcodebuild 的 -destination 'platform=...,name=...' 必须用到它们。
# 用法：bash ios/comet-build-check.sh
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate >/dev/null
xcodebuild build \
  -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPad-Test' \
  -derivedDataPath DerivedData \
  -quiet
