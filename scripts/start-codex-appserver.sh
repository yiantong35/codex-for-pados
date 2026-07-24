#!/usr/bin/env bash
set -euo pipefail

# 官方 ws app-server 启动脚本（switch-to-official-ws-appserver）。
# 起官方 codex app-server --listen ws，启用 capability-token 鉴权。
# 进程安全铁律（design D6）：只精确管理本脚本 spawn 的 PID，绝不 pkill -f codex/app-server
# （会误杀 desktop GUI 私有 app-server，已踩坑）。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_FILE="${ROOT}/protocol/codex-version.txt"
PIN="$(cat "${PIN_FILE}" 2>/dev/null || echo "unknown")"

PORT="${CODEX_WS_PORT:-8900}"
BIND="${CODEX_WS_BIND:-127.0.0.1}"   # 默认仅本机 loopback；外部访问走 relay(E2E)或 SSH 隧道。临时 LAN 裸连排障可设 CODEX_WS_BIND=0.0.0.0
TOKEN_FILE="${CODEX_WS_TOKEN_FILE:-${HOME}/.codex/ws-capability-token}"

# 1) 校验 codex 版本符合 pin
ACTUAL="$(codex --version 2>/dev/null | awk '{print $NF}')"
if [ "${ACTUAL}" != "${PIN}" ]; then
  echo "⚠️  警告：本机 codex 版本 ${ACTUAL} 与 pin ${PIN} 不一致，协议可能不兼容。" >&2
fi

# 2) 生成强随机高熵 capability-token（若已存在则复用，避免每次重启都要重配客户端）
if [ ! -s "${TOKEN_FILE}" ]; then
  mkdir -p "$(dirname "${TOKEN_FILE}")"
  umask 077
  printf '%s' "$(openssl rand -hex 32)" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
  echo "ℹ️  已生成新 capability-token：${TOKEN_FILE}"
fi
chmod 600 "${TOKEN_FILE}" 2>/dev/null || true
TOKEN="$(cat "${TOKEN_FILE}")"

# 3) 起官方 app-server（前台运行；Ctrl-C 退出即停本进程，trap 精确清理自身 PID）
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '未知')"
echo "──────────────────────────────────────────"
echo " 官方 Codex ws app-server 启动中"
echo "  绑定      : ws://${BIND}:${PORT}"
if [ "${BIND}" = "127.0.0.1" ] || [ "${BIND}" = "localhost" ]; then
  echo "  访问方式  : 仅本机 loopback。外部（iPad）访问经 relay(E2E) 或 SSH 隧道进入，勿裸连。"
else
  echo "  Mac LAN IP: ${LAN_IP}（裸连模式：iPad 用 ${LAN_IP}:${PORT}）"
  echo "  ⚠️ 当前 BIND=${BIND} 为逃生阀裸连，仅供临时排障；日常应留默认 127.0.0.1。"
fi
echo "  token 文件: ${TOKEN_FILE}"
echo "  capability-token: ${TOKEN}"
echo "  iPad/官方 TUI 配置：port=${PORT} token=<上方 capability-token>"
echo "──────────────────────────────────────────"

codex app-server --listen "ws://${BIND}:${PORT}" \
  --ws-auth capability-token --ws-token-file "${TOKEN_FILE}" &
APP_SERVER_PID=$!

# 进程安全：只清理本脚本 spawn 的 PID，绝不宽匹配（design D6）
cleanup() { kill "${APP_SERVER_PID}" 2>/dev/null || true; }
trap cleanup INT TERM EXIT

echo "  app-server PID: ${APP_SERVER_PID}（停止：Ctrl-C 或 kill ${APP_SERVER_PID}）"
wait "${APP_SERVER_PID}"
