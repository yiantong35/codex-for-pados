import Foundation

// MARK: - Hooks 协议类型（对齐 codex 0.140 v2：HooksListResponse / HooksListEntry / HookMetadata / HookErrorInfo）
// 只解本 change 展示所需字段，其余宽容忽略；未知枚举兜底、单字段缺失不致整列解码失败（设计 D5）。

/// hook 触发事件名。schema 值见 HookEventName.ts；额外加 `unknown` 兜底（协议未来新增值时不崩）。
enum HookEventName: String, Decodable, Equatable {
    case preToolUse, permissionRequest, postToolUse, preCompact, postCompact
    case sessionStart, userPromptSubmit, subagentStart, subagentStop, stop
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HookEventName(rawValue: raw) ?? .unknown
    }
}

/// hook 处理类型。schema：command/prompt/agent；加 `unknown` 兜底。
enum HookHandlerType: String, Decodable, Equatable {
    case command, prompt, agent, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HookHandlerType(rawValue: raw) ?? .unknown
    }
}

/// hook 来源。schema 已含 `unknown` 值；此处 rawValue 直接匹配，未识别值一并落 .unknown。
enum HookSource: String, Decodable, Equatable {
    case system, user, project, mdm, sessionFlags, plugin
    case cloudRequirements, cloudManagedConfig
    case legacyManagedConfigFile, legacyManagedConfigMdm
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HookSource(rawValue: raw) ?? .unknown
    }
}

/// hook 信任状态。schema：managed/untrusted/trusted/modified；加 `unknown` 兜底。
enum HookTrustStatus: String, Decodable, Equatable {
    case managed, untrusted, trusted, modified, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HookTrustStatus(rawValue: raw) ?? .unknown
    }
}

/// 单个 hook 元信息。schema 必需 key/eventName/handlerType/source/trustStatus/enabled 等；
/// 只解展示所需字段（matcher/command 可空），其余（timeoutSec/sourcePath/pluginId/...）宽容忽略。
struct HookMetadata: Decodable, Equatable, Identifiable {
    let key: String
    var eventName: HookEventName
    var handlerType: HookHandlerType
    var matcher: String?
    var command: String?
    var source: HookSource
    var trustStatus: HookTrustStatus
    var enabled: Bool

    /// SwiftUI List 用；key 在单次结果内唯一（跨 cwd 打平时按 key 去重，见 HooksStore）。
    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, eventName, handlerType, matcher, command, source, trustStatus, enabled
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        eventName = (try? c.decode(HookEventName.self, forKey: .eventName)) ?? .unknown
        handlerType = (try? c.decode(HookHandlerType.self, forKey: .handlerType)) ?? .unknown
        matcher = try? c.decode(String.self, forKey: .matcher)
        command = try? c.decode(String.self, forKey: .command)
        source = (try? c.decode(HookSource.self, forKey: .source)) ?? .unknown
        trustStatus = (try? c.decode(HookTrustStatus.self, forKey: .trustStatus)) ?? .unknown
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
    }
}

/// hooks/list 单条加载错误（path/message）。用于一组失败不阻塞展示。
struct HookErrorInfo: Decodable, Equatable {
    var path: String
    var message: String

    enum CodingKeys: String, CodingKey { case path, message }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
    }
}

/// 单个 cwd 的 hooks 结果（cwd + hooks + warnings + errors）。
struct HooksListEntry: Decodable, Equatable {
    var cwd: String
    var hooks: [HookMetadata]
    var warnings: [String]
    var errors: [HookErrorInfo]

    enum CodingKeys: String, CodingKey { case cwd, hooks, warnings, errors }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        hooks = (try? c.decode([HookMetadata].self, forKey: .hooks)) ?? []
        warnings = (try? c.decode([String].self, forKey: .warnings)) ?? []
        errors = (try? c.decode([HookErrorInfo].self, forKey: .errors)) ?? []
    }
}

/// hooks/list 响应：data 为逐 cwd 分组。
struct HooksListResponse: Decodable {
    var data: [HooksListEntry]

    enum CodingKeys: String, CodingKey { case data }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        data = (try? c.decode([HooksListEntry].self, forKey: .data)) ?? []
    }
}
