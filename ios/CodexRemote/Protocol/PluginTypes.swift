import Foundation

// MARK: - Plugins 协议类型（对齐 codex 0.140 v2：PluginListResponse.json / PluginReadResponse.json / PluginSkillRead*.json）
// 只解展示 + 下钻所需字段，其余宽容忽略；未知枚举兜底、缺省宽松（设计 D3）。

/// 插件可用性。schema：DISABLED_BY_ADMIN | AVAILABLE；上游 plugin-service 发 "ENABLED" 别名映射为 available；未知值兜底 .unknown。
enum PluginAvailability: String, Decodable, Equatable {
    case available, disabledByAdmin, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "AVAILABLE", "ENABLED": self = .available
        case "DISABLED_BY_ADMIN":    self = .disabledByAdmin
        default:                     self = .unknown
        }
    }
}

/// 插件展示接口（全部可选，用于分类/名字/描述）。
struct PluginInterface: Decodable, Equatable {
    var displayName: String?
    var category: String?
    var shortDescription: String?
    var longDescription: String?

    enum CodingKeys: String, CodingKey { case displayName, category, shortDescription, longDescription }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        displayName = try? c.decode(String.self, forKey: .displayName)
        category = try? c.decode(String.self, forKey: .category)
        shortDescription = try? c.decode(String.self, forKey: .shortDescription)
        longDescription = try? c.decode(String.self, forKey: .longDescription)
    }
}

/// 插件列表摘要（plugin/list 元素）。schema 必需 id/name/enabled/installed/installPolicy/authPolicy/source；
/// availability 默认 AVAILABLE；interface/remotePluginId 可选。此处仅解展示与下钻所需字段。
struct PluginSummary: Decodable, Equatable, Identifiable {
    let id: String
    var name: String
    var enabled: Bool
    var installed: Bool
    var availability: PluginAvailability
    var interface: PluginInterface?
    var remotePluginId: String?

    enum CodingKeys: String, CodingKey { case id, name, enabled, installed, availability, interface, remotePluginId }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        installed = (try? c.decode(Bool.self, forKey: .installed)) ?? false
        availability = (try? c.decode(PluginAvailability.self, forKey: .availability)) ?? .available
        interface = try? c.decode(PluginInterface.self, forKey: .interface)
        remotePluginId = try? c.decode(String.self, forKey: .remotePluginId)
    }

    /// 展示分类（interface.category）。
    var category: String? { interface?.category }
    /// 展示描述（shortDescription 优先，再 longDescription）。
    var displayDescription: String? { interface?.shortDescription ?? interface?.longDescription }
    /// 下钻用远端 plugin id：remotePluginId 优先，回落到本地 id。
    var effectiveRemotePluginId: String { remotePluginId ?? id }
}

/// 一个 marketplace 分组（name + plugins）。
struct PluginMarketplaceEntry: Decodable, Equatable, Identifiable {
    var name: String
    var plugins: [PluginSummary]

    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, plugins }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        plugins = (try? c.decode([PluginSummary].self, forKey: .plugins)) ?? []
    }
}

/// plugin/list 响应（marketplaces 缺省空）。
struct PluginListResponse: Decodable {
    var marketplaces: [PluginMarketplaceEntry]

    enum CodingKeys: String, CodingKey { case marketplaces }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        marketplaces = (try? c.decode([PluginMarketplaceEntry].self, forKey: .marketplaces)) ?? []
    }
}

/// 插件内置 skill 摘要（PluginDetail.skills 元素）。schema 必需 name/description/enabled。
struct SkillSummary: Decodable, Equatable, Identifiable {
    let name: String
    var description: String
    var enabled: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, description, enabled }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
    }
}

/// plugin/read 响应中的插件详情。只解展示所需 marketplaceName/mcpServers/skills（schema 另有 apps/hooks 等，暂不展示）。
struct PluginDetail: Decodable, Equatable {
    var marketplaceName: String
    var mcpServers: [String]
    var skills: [SkillSummary]

    enum CodingKeys: String, CodingKey { case marketplaceName, mcpServers, skills }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        marketplaceName = (try? c.decode(String.self, forKey: .marketplaceName)) ?? ""
        mcpServers = (try? c.decode([String].self, forKey: .mcpServers)) ?? []
        skills = (try? c.decode([SkillSummary].self, forKey: .skills)) ?? []
    }
}

/// plugin/read 响应（plugin 必需）。
struct PluginReadResponse: Decodable {
    var plugin: PluginDetail

    enum CodingKeys: String, CodingKey { case plugin }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        plugin = try c.decode(PluginDetail.self, forKey: .plugin)
    }
}

/// plugin/read 请求参数（pluginName 必需，remoteMarketplaceName 可选）。
struct PluginReadParams: Encodable {
    let pluginName: String
    var remoteMarketplaceName: String?
}

/// plugin/skill/read 请求参数（三者均必需）。
struct PluginSkillReadParams: Encodable {
    let remoteMarketplaceName: String
    let remotePluginId: String
    let skillName: String
}

/// plugin/skill/read 响应（contents 可选）。
struct PluginSkillReadResponse: Decodable {
    var contents: String?

    enum CodingKeys: String, CodingKey { case contents }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        contents = try? c.decode(String.self, forKey: .contents)
    }
}
