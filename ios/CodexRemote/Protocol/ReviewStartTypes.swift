import Foundation

/// `review/start` 投递位置（schema: ReviewDelivery）：inline=当前 thread 内跑，
/// detached=新建 review thread。本 change 只用 inline（设计 D3）。
enum ReviewDelivery: String, Codable {
    case inline
    case detached
}

/// 审查目标（schema: ReviewTarget，内部判别 `type` 字段的 oneOf）。
/// 本 change 只用 `uncommittedChanges`（全量审查）与 `custom`（本轮审查，设计 D2）；
/// `baseBranch`/`commit` 协议存在但暂不接入（无列分支/列提交 RPC，留后续增量）。
enum ReviewTarget: Encodable {
    case uncommittedChanges
    case custom(instructions: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case instructions
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .uncommittedChanges:
            try c.encode("uncommittedChanges", forKey: .type)
        case .custom(let instructions):
            try c.encode("custom", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
        }
    }
}

/// `review/start` 请求参数（schema: ReviewStartParams）。
struct ReviewStartParams: Encodable {
    let threadId: String
    let target: ReviewTarget
    let delivery: ReviewDelivery
}

/// `review/start` 响应（schema: ReviewStartResponse）。
/// 只取 `reviewThreadId`（inline 时=当前 thread）；`turn` 结构复杂，宽松解码/忽略（设计 D6 + 风险 4）。
struct ReviewStartResponse: Decodable {
    let reviewThreadId: String

    private enum CodingKeys: String, CodingKey {
        case reviewThreadId
    }
}
