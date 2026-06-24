#!/usr/bin/env bash
set -euo pipefail

# ⚠️ 已废弃（switch-to-official-ws-appserver）：
# 自建广播 daemon 已退役。请改用 scripts/start-codex-appserver.sh 起官方 ws app-server。
# 本脚本保留仅供回退/对照，不在默认启动路径。
echo "⚠️  start-bridge-daemon.sh 已废弃，请用 scripts/start-codex-appserver.sh（官方 ws app-server）。" >&2

# 启动 Codex 广播 daemon(局域网,单一 app-server 连接 + WS 广播)。
# 用法: scripts/start-bridge-daemon.sh [PORT] [TOKEN]
#   PORT  默认 8765
#   TOKEN 省略则 daemon 随机生成并打印

# 1) 校验 codex 在 PATH(daemon 要 spawn codex app-server)
if ! command -v codex >/dev/null 2>&1; then
  echo "❌ codex 不在 PATH。请先安装 Codex CLI。" >&2
  exit 1
fi
echo "ℹ️  codex: $(codex --version 2>/dev/null || echo 未知)"

# 2) 构建 release
DAEMON_DIR="$(cd "$(dirname "$0")/../mac-daemon" && pwd)"
cd "$DAEMON_DIR"
echo "ℹ️  构建 daemon (release)…"
swift build -c release

# 3) 连接信息 + 启动
PORT="${1:-8765}"
TOKEN="${2:-}"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '未知')"
echo "──────────────────────────────────────────"
echo " 启动广播 daemon"
echo "  Mac LAN IP : ${LAN_IP}"
echo "  端口        : ${PORT}"
echo "  下游连接    : ws://${LAN_IP}:${PORT}/?token=<下方 daemon 打印的 token>"
echo "──────────────────────────────────────────"

ARGS=(--port "${PORT}")
[ -n "${TOKEN}" ] && ARGS+=(--token "${TOKEN}")
# daemon 会打印 token 与监听地址;Ctrl-C 优雅关闭(只终止自己 spawn 的 codex)
exec .build/release/codex-bridge-daemon "${ARGS[@]}"

# 注: 本期不做 launchd 持久化(手动启动);崩溃自启/开机自启留后续增强。
