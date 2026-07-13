import Foundation

/// 发送时的模型/推理强度选择（D-model，服务器驱动）。
///
/// 设计要点（见 memory: pados-model-server-driven）：pados **绝不硬编码模型或默认值**。
/// 用户未显式选择时，生效值回退到账号 `config/read` 的默认（`CuratedConfig.model` /
/// `model_reasoning_effort`）——该默认由 daemon 按当前登录（账号登录 / API 登录）返回，
/// 故天然适配两种登录。都无时返回 nil，让服务器用其默认，绝不硬塞一个可能无效的模型。
struct ModelSelection: Equatable {
    /// 用户在 composer 里显式选择的模型 slug；nil = 跟随账号默认。
    var modelOverride: String?
    /// 用户显式选择的推理强度；nil = 跟随账号默认。
    var effortOverride: ReasoningEffort?

    /// 生效模型：显式选择优先，否则回退 config 默认，都无则 nil（服务器默认）。
    func effectiveModel(config: CuratedConfig?) -> String? {
        modelOverride ?? config?.model
    }

    /// 生效推理强度：显式选择优先，否则解析 config 字符串默认，非法/缺失则 nil。
    func effectiveEffort(config: CuratedConfig?) -> ReasoningEffort? {
        if let e = effortOverride { return e }
        return config?.modelReasoningEffort.flatMap(ReasoningEffort.init(rawValue:))
    }
}
