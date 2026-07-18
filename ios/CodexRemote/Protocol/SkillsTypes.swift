import Foundation

// MARK: - Skills 协议类型（对齐 codex 0.140 v2：SkillsListResponse.json / SkillsConfigWriteParams.json）
// 只解本 change 展示所需字段，其余宽容忽略；未知枚举兜底、单字段缺失不致整列解码失败（设计 D3）。

/// skill 作用域。schema 值 user/repo/system/admin，额外加 `unknown` 兜底（协议未来新增值时不崩）。
enum SkillScope: String, Decodable, Equatable {
    case user, repo, system, admin, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SkillScope(rawValue: raw) ?? .unknown
    }
}

/// skill 声明的单个工具依赖（type/value 必需，其余可选）。
struct SkillToolDependency: Decodable, Equatable {
    let type: String
    let value: String
    var command: String?
    var url: String?
    var transport: String?
    var description: String?

    enum CodingKeys: String, CodingKey { case type, value, command, url, transport, description }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = (try? c.decode(String.self, forKey: .type)) ?? ""
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        command = try? c.decode(String.self, forKey: .command)
        url = try? c.decode(String.self, forKey: .url)
        transport = try? c.decode(String.self, forKey: .transport)
        description = try? c.decode(String.self, forKey: .description)
    }
}

/// skill 依赖集合（tools 缺省空）。
struct SkillDependencies: Decodable, Equatable {
    var tools: [SkillToolDependency]

    enum CodingKeys: String, CodingKey { case tools }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        tools = (try? c.decode([SkillToolDependency].self, forKey: .tools)) ?? []
    }
}

/// 单个 skill 元信息。schema 必需 name/description/enabled/path/scope；dependencies 可选。
struct SkillMetadata: Decodable, Equatable, Identifiable {
    let name: String
    var description: String
    var enabled: Bool
    var path: String
    var scope: SkillScope
    var dependencies: SkillDependencies?

    /// SwiftUI List 用；path 在单次结果内唯一（跨 cwd 打平时按 path 去重，见 SkillsStore）。
    var id: String { path }

    enum CodingKeys: String, CodingKey { case name, description, enabled, path, scope, dependencies }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        scope = (try? c.decode(SkillScope.self, forKey: .scope)) ?? .unknown
        dependencies = try? c.decode(SkillDependencies.self, forKey: .dependencies)
    }
}

/// skills/list 单条加载错误（message/path）。用于 D7 一组失败不阻塞展示。
struct SkillErrorInfo: Decodable, Equatable {
    var message: String
    var path: String

    enum CodingKeys: String, CodingKey { case message, path }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
    }
}

/// 单个 cwd 的 skills 结果（cwd + errors + skills）。
struct SkillsListEntry: Decodable, Equatable {
    var cwd: String
    var errors: [SkillErrorInfo]
    var skills: [SkillMetadata]

    enum CodingKeys: String, CodingKey { case cwd, errors, skills }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        errors = (try? c.decode([SkillErrorInfo].self, forKey: .errors)) ?? []
        skills = (try? c.decode([SkillMetadata].self, forKey: .skills)) ?? []
    }
}

/// skills/list 响应：data 为逐 cwd 分组。
struct SkillsListResponse: Decodable {
    var data: [SkillsListEntry]

    enum CodingKeys: String, CodingKey { case data }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        data = (try? c.decode([SkillsListEntry].self, forKey: .data)) ?? []
    }
}

/// skills/config/write 请求参数（enabled 必需，name/path 二选一；nil 不编码）。
struct SkillsConfigWriteParams: Encodable {
    let enabled: Bool
    var name: String?
    var path: String?
}
