#!/usr/bin/env bash
set -euo pipefail
PIN="$(cat "$(dirname "$0")/../protocol/codex-version.txt")"
ACTUAL="$(codex --version | awk '{print $NF}')"
if [ "$ACTUAL" != "$PIN" ]; then
  echo "ERROR: codex 版本 $ACTUAL != pin $PIN，协议可能不兼容。中止。" >&2
  exit 1
fi
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/protocol"
rm -rf "$OUT_DIR/schema" "$OUT_DIR/ts"
mkdir -p "$OUT_DIR/schema" "$OUT_DIR/ts"
codex app-server generate-json-schema --out "$OUT_DIR/schema"
codex app-server generate-ts --out "$OUT_DIR/ts"
echo "OK: 协议产物已生成到 ${OUT_DIR}（codex ${PIN}）"
