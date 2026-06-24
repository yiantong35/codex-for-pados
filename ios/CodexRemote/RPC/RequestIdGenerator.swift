import Foundation

/// 全局唯一 request id 生成器。形如 "ipad-<UUID>"。
///
/// 保留依据（spike 2026-06-24 实测坐实，§6.2）：官方 ws app-server 的 response 是**点对点**的——
/// 按请求 id 只回发起连接，iPad 本就只收到自己 id 的 response，不会串台。因此全局唯一 id
/// 并非为「去串台」而必需；多连接下单连接内自管 id + 点对点路由已不冲突。此处保留全局唯一
/// （UUID）仅作**低成本兜底**（无害、零冲突风险），故维持现状不改为计数器。
enum RequestIdGenerator {
    static func next() -> RequestId {
        .string("ipad-" + UUID().uuidString)
    }
}
