import Foundation

/// 全局唯一 request id 生成器（设计 §4 A2，应对 daemon 广播总线无 id 命名空间）。
/// 形如 "ipad-<UUID>"，保证不与 Mac 端或其它下游碰撞。
enum RequestIdGenerator {
    static func next() -> RequestId {
        .string("ipad-" + UUID().uuidString)
    }
}
