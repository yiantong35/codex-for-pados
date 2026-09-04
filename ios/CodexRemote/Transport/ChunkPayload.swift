import Foundation

/// 分片载荷（位于 .chunk 帧的密封明文内）。字段/类型/顺序与 dev 侧 ChunkPayload 完全一致。
struct ChunkPayload: Codable, Equatable {
    var seq: UInt32
    var totalChunks: UInt32
    var compressed: Bool
    var data: Data
}
