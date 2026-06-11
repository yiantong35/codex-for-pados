#!/usr/bin/env bash
set -euo pipefail

PIN_FILE="$(cd "$(dirname "$0")/.." && pwd)/protocol/codex-version.txt"
PIN="$(cat "${PIN_FILE}" 2>/dev/null || echo "unknown")"

# 1) 校验 codex 版本符合 pin（mac-launcher: codex 版本不符合 pin）
ACTUAL="$(codex --version 2>/dev/null | awk '{print $NF}')"
if [ "${ACTUAL}" != "${PIN}" ]; then
  echo "⚠️  警告：本机 codex 版本 ${ACTUAL} 与 pin ${PIN} 不一致，协议可能不兼容。" >&2
fi

# 2) 校验 sshd / 远程登录（mac-launcher: sshd 未开启时提示）
#    systemsetup -getremotelogin 是权威判据，但需要管理员权限；无权限时回退到
#    launchctl 检查 com.openssh.sshd 是否已加载（无需 sudo）。
REMOTE_LOGIN="$(systemsetup -getremotelogin 2>/dev/null || true)"
SSHD_ON=""
if echo "${REMOTE_LOGIN}" | grep -qi 'Remote Login: On'; then
  SSHD_ON="yes"
elif echo "${REMOTE_LOGIN}" | grep -qi 'Remote Login: Off'; then
  SSHD_ON="no"
elif launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
  # systemsetup 不可用（无管理员权限），改用 launchctl 判定：服务已加载即视为开启。
  SSHD_ON="yes"
else
  SSHD_ON="no"
fi

if [ "${SSHD_ON}" != "yes" ]; then
  echo "❌ Mac 的“远程登录”(sshd) 未开启。" >&2
  echo "   请到 系统设置 → 通用 → 共享 → 远程登录 打开，或运行：" >&2
  echo "   sudo systemsetup -setremotelogin on" >&2
  exit 1
fi

# 3) 确保受管 daemon 启用远程控制（mac-launcher: 正常启用远程控制 / daemon 已运行）
#    注意：`daemon version` 报 status:running 只表示 control socket 上有 app-server
#    应答，并不保证它是经 `daemon bootstrap` 注册的“受管”实例——非受管实例（如
#    desktop app 顺带拉起的 app-server）同样会占用该 socket。因此用 version 判活后，
#    必须以 enable-remote-control 的真实结果区分“受管已运行”与“非受管占用”两态，
#    避免把 socket 被占用误报成远程控制已启用。
SOCK="${HOME}/.codex/app-server-control/app-server-control.sock"
if codex app-server daemon version >/dev/null 2>&1; then
  echo "ℹ️  control socket 上已有运行中的 app-server，尝试对受管 daemon 启用远程控制（不重复创建实例）。"
  ENABLE_OUT="$(codex app-server daemon enable-remote-control 2>&1)" && ENABLE_RC=0 || ENABLE_RC=$?
  if [ "${ENABLE_RC}" -ne 0 ]; then
    if echo "${ENABLE_OUT}" | grep -qi 'not managed'; then
      echo "❌ control socket 当前被一个“非受管”的 app-server 占用，无法对其启用远程控制。" >&2
      echo "   socket: ${SOCK}" >&2
      echo "   占用进程：" >&2
      lsof "${SOCK}" 2>/dev/null | sed 's/^/     /' >&2 || true
      echo "   该实例多半由 desktop app 或手动调用拉起，未经 daemon bootstrap 注册。" >&2
      echo "   为不破坏现用环境，脚本不会自动停止它。请确认后任选其一：" >&2
      echo "     - 退出占用该 socket 的 app-server，再重跑本脚本；或" >&2
      echo "     - 手动接管：codex app-server daemon restart --remote-control" >&2
      exit 1
    fi
    echo "❌ enable-remote-control 失败：${ENABLE_OUT}" >&2
    exit "${ENABLE_RC}"
  fi
  echo "  ${ENABLE_OUT}"
else
  echo "ℹ️  受管 daemon 未运行，bootstrap 并启用远程控制。"
  codex app-server daemon bootstrap --remote-control
fi
DAEMON_VERSION="$(codex app-server daemon version 2>/dev/null || echo '未知')"
echo "  daemon 版本 : ${DAEMON_VERSION}"
echo "  control sock: ${SOCK}"

# 4) 输出连接信息（mac-launcher: 正常启用远程控制并输出连接信息）
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '未知')"
SSH_USER="$(whoami)"
echo "──────────────────────────────────────────"
echo " Codex 受管 daemon 已启用远程控制"
echo "  Mac LAN IP : ${LAN_IP}"
echo "  SSH 用户名 : ${SSH_USER}"
echo "  iPad 接入  : SSH 到 ${SSH_USER}@${LAN_IP}，经 exec 通道运行"
echo "               codex app-server proxy（桥接到 control socket）"
echo "  control sock: ${SOCK}（仅属主可读，与桌面 app 共享受管 daemon）"
echo "──────────────────────────────────────────"
