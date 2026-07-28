# relay-server 部署说明（阿里云 ECS / Ubuntu）

relay-server 是一个基于 SwiftNIO 的极简中继服务端：

- 绑定 `0.0.0.0:9000`（端口可用环境变量 `RELAY_PORT` 覆盖）。
- `GET /relay/{sessionId}` + WebSocket upgrade + 请求头 `x-role`（`devMachine` / `iPad`）→ 按 sessionId 撮合一对连接。
- `GET /health`（非 upgrade）→ 返回 `{"ok":true}`（200）。
- **零知识**：relay 只按 sessionId 撮合并原样双向转发密文帧，绝不解密、绝不解析 JSON-RPC。端到端加密由共享包 RelayProtocol 保证。

目标：在开发机（macOS）上交叉编译出一个**零依赖单 ELF 二进制**，`scp` 到阿里云 ECS（Ubuntu），用 systemd 常驻运行。

---

## 1. 交叉编译（macOS → Linux x86_64，musl 静态）

推荐使用 Swift 官方的 Static Linux SDK，产出静态链接（musl）的二进制，运行时不依赖目标机的 glibc / 动态库，最省心。

### 1.1 安装 Static Linux SDK

Swift Static Linux SDK 随各 Swift release 提供。到 [swift.org/download](https://www.swift.org/download/) 找到与本机 Swift 工具链**版本一致**的 “Static Linux SDK”，取其下载 URL 与校验和后安装：

```bash
# 先确认本机工具链版本，SDK 版本必须与之匹配
swift --version

# 安装官方 static-linux SDK（URL / checksum 见 swift.org 下载页对应版本）
swift sdk install \
  "https://download.swift.org/.../swift-<VERSION>-RELEASE_static-linux-<...>.artifactbundle.tar.gz" \
  --checksum <SHA256>

# 确认已装上，记下 SDK 标识
swift sdk list
```

安装后 `swift sdk list` 会列出可用的目标三元组，x86_64 目标通常为 `x86_64-swift-linux-musl`（以 `swift sdk list` 实际输出为准；aarch64 ECS 则选对应的 `aarch64-swift-linux-musl`）。

### 1.2 编译 + strip

```bash
cd relay-server

# release 交叉编译到 Linux x86_64（musl 静态）
swift build -c release --swift-sdk x86_64-swift-linux-musl

# 产物路径（三元组以实际 SDK 为准）
BIN=.build/x86_64-swift-linux-musl/release/relay-server

# 确认是静态 ELF（应显示 statically linked，无动态依赖）
file "$BIN"

# strip 掉符号表，显著减小体积
strip "$BIN"
```

得到的 `relay-server` 是零依赖单 ELF 二进制，可直接拷到干净的 Ubuntu 上运行。

> **架构对齐**：ECS 是 x86_64 用 `x86_64-swift-linux-musl`；是 ARM（如倚天 / Graviton 类）用 `aarch64-swift-linux-musl`。二者选一，别拷错架构。

---

## 2. 部署到 ECS（systemd 常驻）

### 2.1 拷贝二进制

```bash
# 在 ECS 上准备目录（假设已有非 root 用户 relay）
ssh <user>@<ecs-ip> 'sudo mkdir -p /opt/relay-server && sudo chown relay:relay /opt/relay-server'

# scp 单二进制过去
scp .build/x86_64-swift-linux-musl/release/relay-server <user>@<ecs-ip>:/tmp/relay-server
ssh <user>@<ecs-ip> 'sudo mv /tmp/relay-server /opt/relay-server/relay-server \
  && sudo chown relay:relay /opt/relay-server/relay-server \
  && sudo chmod 755 /opt/relay-server/relay-server'
```

### 2.2 systemd unit

在 ECS 上创建 `/etc/systemd/system/relay-server.service`：

```ini
[Unit]
Description=codex relay-server (zero-knowledge ws relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# 非 root 运行（建议专用系统用户 relay）
User=relay
Group=relay
ExecStart=/opt/relay-server/relay-server
# 可选：覆盖监听端口（默认 9000）
Environment=RELAY_PORT=9000
Restart=always
RestartSec=2
# 收紧权限（可选加固）
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

若尚无 `relay` 用户：

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin relay
```

启用并启动：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now relay-server
sudo systemctl status relay-server
# 查日志
sudo journalctl -u relay-server -f
```

---

## 3. 验证

```bash
# 本机上（ECS 内）
curl http://127.0.0.1:9000/health
# → {"ok":true}

# 外网（放行 9000 之后）
curl http://<ecs-ip>:9000/health
# → {"ok":true}
```

返回 `{"ok":true}` 即服务正常。

---

## 4. 安全组 / 防火墙

- **阿里云安全组**：入方向放行 TCP `9000`（或你在 `RELAY_PORT` 设的端口），来源按需收紧到开发机 / iPad 出口 IP。
- **ECS 本机防火墙**（若启用 ufw）：`sudo ufw allow 9000/tcp`。
- **TLS（强烈建议）**：relay 转发的是密文，但 ws 明文（`ws://`）仍暴露 sessionId、连接元数据，且部分网络会拦截非 TLS 的 upgrade。生产建议在前面挂 nginx / Caddy 做 TLS 终止，对外暴露 `wss://`：
  - Caddy 一行即可自动签证书并反代到 `127.0.0.1:9000`：
    ```
    relay.example.com {
        reverse_proxy 127.0.0.1:9000
    }
    ```
  - 此时对外为 `wss://relay.example.com`（443），relay-server 只监听 127.0.0.1:9000，安全组只放行 443。
  - 客户端（relay-dialout 的 `RELAY_URL`、iPad 配对载荷里的 relay 地址）相应用 `wss://relay.example.com`。

### per-IP 限流由反代（Caddy）承担

relay-server 自身**不再做 per-IP 并发/速率限流**（历史上曾用 `channel.remoteAddress`——反代后所有对端为 `127.0.0.1`，per-IP 桶会塌成全体共享、把整机误卡在上限，见 relay-security-hardening-2/D2）。relay 只保**全局并发**（`maxTotalConnections`）+ **房间总数**（`maxRooms`）+ 单消息大小上限 + 空闲超时四道全局闸。

**生产 MUST 走 Caddy `wss` 反代，并在 Caddy 层按真实客户端 IP 做 per-IP 限流**（Caddy 看得到 `X-Forwarded-For` / 真实远端，relay 看不到）：

```
relay.example.com {
    rate_limit {
        zone per_ip {
            key    {remote_host}
            events 60
            window 1m
        }
    }
    reverse_proxy 127.0.0.1:9000
}
```

（`rate_limit` 为 Caddy 限流插件指令，按部署的 Caddy 构建选用等价配置。）

**部署前提**：
- 生产 MUST 经 Caddy 反代对外暴露 `wss://`，per-IP 保护由反代承担；relay-server 只监听 `127.0.0.1:9000`。
- 裸机 `ws://<ecs-ip>:9000`（无 Caddy）**无 per-IP 保护**，仅全局并发 + 房间 + 消息大小 + 空闲超时兜底——**仅供本机排障**，不作生产暴露。

---

## 5. 兜底方案（musl SDK 编译遇阻时）

若 static-linux musl SDK 交叉编译触发编译器 bug 或第三方依赖不兼容，任选其一：

1. **Docker（glibc）容器内构建**：用官方 `swift:jammy` 镜像在容器里 `swift build -c release`，产物为 glibc 动态链接二进制。同架构的 Ubuntu ECS 上依赖 glibc 一般已满足，`scp` 后可直接跑（如缺库按提示 `apt install` 对应的 Swift runtime 依赖）：
   ```bash
   docker run --rm -v "$PWD":/src -w /src swift:jammy \
     swift build -c release
   # 产物：.build/release/relay-server（glibc 动态链接）
   ```
   注意：Docker 构建产出的架构 = 容器架构，跨架构需 `--platform` + QEMU。
2. **在 ECS 上本地构建**：直接在 Ubuntu ECS 上装官方 Swift toolchain（[swift.org/install/linux](https://www.swift.org/install/linux/)），`git`/`scp` 源码上去后本机 `swift build -c release`。省去跨编译烦恼，代价是 ECS 上要装完整工具链。

无论哪种兜底，最终交付物都是 `/opt/relay-server/relay-server` 一个二进制 + 同一份 systemd unit。

---

## 6. 开发机侧：启动 relay-dialout

relay-server 起来后，开发机（macOS）侧跑 `relay-dialout` 拨出，桥接**开发机上已有的共享 daemon**（不自 spawn app-server，proxy 幂等接入，保真跨端同步）。

环境变量：

| 变量 | 含义 | 默认 |
|------|------|------|
| `RELAY_URL` | relay 地址（生产用 `wss://relay.example.com`，裸机 `ws://<ecs-ip>:9000`） | `wss://relay.example.com` |
| `CONTROL_SOCK` | 开发机现有共享 daemon 的 control socket 路径 | `~/.codex/control.sock` |
| `CODEX_PATH` | `codex` 可执行路径 | `codex` |
| `DEV_DEVICE_ID` | 开发机标识（可选） | 随机 `dev-xxxx` |

运行：

```bash
cd relay-dialout
RELAY_URL="wss://relay.example.com" \
CONTROL_SOCK="$HOME/.codex/control.sock" \
swift run relay-dialout
```

启动后终端会打印一次性配对载荷（10 分钟内有效），形如：

```
=== relay-dialout ready ===
将下面配对载荷搬到 iPad（10 分钟内有效）：
codexrelay://pair?relay=...&sid=...&pk=...&pc=...&exp=...
===========================
relay-dialout 已拨出 <host>:<port>/relay/<sessionId> (role=devMachine)
```

把 `codexrelay://pair?...` 这一行手动搬到 iPad（相册截图 / 消息 / 剪贴板），在 iPad 的「粘贴配对载荷」界面导入即可。relay-dialout 内部：ws 拨出 relay（`x-role: devMachine`）→ 与 iPad 完成握手（验 iPad 签名 + 校验一次性 pairingCode）→ 建 SecureSession → spawn `codex app-server proxy --sock <control.sock>` 桥接共享 daemon → 双向：iPad 密文帧解密写 proxy stdin，proxy stdout 明文加密回发 iPad。pairingCode 握手成功后即失效（一次性）。

---

## ✅ 安全前提（已收口）

开发机的 `app-server` 默认绑 `127.0.0.1`（仅本机 loopback）。外部（iPad）流量只能经 relay 的端到端加密通道或 SSH 隧道进入——relay-dialout 在开发机**本机**连 app-server（loopback），SSH transport 走隧道 + Unix socket（`control.sock`），二者均不经此 TCP 监听，故收口不影响正式接入。杜绝了绕过 relay 的明文裸连。

逃生阀：临时 LAN 裸连排障时可 `CODEX_WS_BIND=0.0.0.0` 启动 `scripts/start-codex-appserver.sh` 覆盖默认绑定（脚本会警示当前处于裸连模式）；日常应留默认 `127.0.0.1`。

> 历史：探路阶段（relay-e2e-spike）默认绑 `0.0.0.0` 便于 bring-up，此项作为紧后续安全收口任务留待 relay 上线后处理。已由 change `bind-appserver-loopback`（2026-07-24）收口。
