> ⚠️ **已废弃（DEPRECATED）— 退役日期 2026-06-24**
>
> 本目录（`mac-daemon/`，自建广播中转 daemon）已**退役**，详见
> change `switch-to-official-ws-appserver`。
>
> 退役原因：官方 `codex app-server --listen ws` 已**原生支持多客户端广播**，
> 完全替代了本自建 daemon 的转发/扇出职责。
>
> **请改用**：`scripts/start-codex-appserver.sh` 启动官方 app-server。
>
> 本包代码**仅保留供回退 / 对照参考**，已**移出默认启动路径**，
> 不再作为常规运行组件。请勿在生产/默认流程中依赖本目录。

# codex-bridge-daemon（已退役）

自建的 WebSocket 广播中转 daemon，曾用于在多个客户端之间扇出/转发
codex app-server 的消息。

随着官方 `codex app-server --listen ws` 原生支持多客户端广播，本组件不再必要，
已于 2026-06-24 标记废弃并移出默认启动路径。

- 替代方案：`scripts/start-codex-appserver.sh`（启动官方 app-server）
- 关联 change：`switch-to-official-ws-appserver`
- 状态：代码保留，仅供回退/对照，不在默认启动路径
