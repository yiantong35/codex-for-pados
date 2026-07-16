import Foundation

// MARK: - MCP 协议类型（对齐 codex 0.140 v2 schema：ListMcpServerStatusResponse.json）
// 只解本 change 展示所需字段，其余宽容忽略；单字段缺失不致整列解码失败（设计 D3）。

/// MCP server 认证状态。schema 值 unsupported/notLoggedIn/bearerToken/oAuth，
/// 额外加 `unknown` 兜底：协议未来新增枚举值时不崩（对齐项目 unknown 兜底惯例）。
enum McpAuthStatus: String, Decodable, Equatable {
    case unsupported
    case notLoggedIn
    case bearerToken
    case oAuth
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = McpAuthStatus(rawValue: raw) ?? .unknown
    }
}

/// server 暴露的工具（只取展示所需 name + 可选 description；inputSchema 等忽略）。
struct McpTool: Decodable, Equatable {
    let name: String
    var description: String?

    enum CodingKeys: String, CodingKey { case name, description }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        description = try? c.decode(String.self, forKey: .description)
    }
}

/// 已知资源（name + uri + 可选 description/mimeType）。
struct McpResource: Decodable, Equatable {
    let name: String
    var uri: String?
    var description: String?
    var mimeType: String?

    enum CodingKeys: String, CodingKey { case name, uri, description, mimeType }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        uri = try? c.decode(String.self, forKey: .uri)
        description = try? c.decode(String.self, forKey: .description)
        mimeType = try? c.decode(String.self, forKey: .mimeType)
    }
}

/// 资源模板（name + uriTemplate + 可选 description）。
struct McpResourceTemplate: Decodable, Equatable {
    let name: String
    var uriTemplate: String?
    var description: String?

    enum CodingKeys: String, CodingKey { case name, uriTemplate, description }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        uriTemplate = try? c.decode(String.self, forKey: .uriTemplate)
        description = try? c.decode(String.self, forKey: .description)
    }
}

/// server 自述元信息（初始化后广播）。可选整体缺省。
struct McpServerInfo: Decodable, Equatable {
    var name: String?
    var version: String?
    var title: String?
    var description: String?

    enum CodingKeys: String, CodingKey { case name, version, title, description }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try? c.decode(String.self, forKey: .name)
        version = try? c.decode(String.self, forKey: .version)
        title = try? c.decode(String.self, forKey: .title)
        description = try? c.decode(String.self, forKey: .description)
    }
}

/// 单个 MCP server 状态。tools 为 {[name]: Tool} 字典；集合缺失时宽松默认空。
struct McpServerStatus: Decodable, Equatable, Identifiable {
    let name: String
    var authStatus: McpAuthStatus
    var tools: [String: McpTool]
    var resources: [McpResource]
    var resourceTemplates: [McpResourceTemplate]
    var serverInfo: McpServerInfo?

    /// SwiftUI List 用；server name 在单次 list 结果内唯一。
    var id: String { name }

    /// 工具名列表（字典无序，按名排序稳定展示）。
    var toolNames: [String] { tools.keys.sorted() }

    enum CodingKeys: String, CodingKey {
        case name, authStatus, tools, resources, resourceTemplates, serverInfo
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        authStatus = (try? c.decode(McpAuthStatus.self, forKey: .authStatus)) ?? .unknown
        tools = (try? c.decode([String: McpTool].self, forKey: .tools)) ?? [:]
        resources = (try? c.decode([McpResource].self, forKey: .resources)) ?? []
        resourceTemplates = (try? c.decode([McpResourceTemplate].self, forKey: .resourceTemplates)) ?? []
        serverInfo = try? c.decode(McpServerInfo.self, forKey: .serverInfo)
    }
}

/// mcpServerStatus/list 响应：data + 可选 nextCursor（D5：首版忽略分页，仅解出不用）。
struct ListMcpServerStatusResponse: Decodable {
    let data: [McpServerStatus]
    var nextCursor: String?
}
