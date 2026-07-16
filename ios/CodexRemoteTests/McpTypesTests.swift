import Testing
import Foundation
@testable import CodexRemote

struct McpTypesTests {
    private func decode<T: Decodable>(_ t: T.Type, _ j: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(j.utf8))
    }

    // MARK: 方法/通知常量（tasks 1.1）

    @Test func methodConstants() {
        #expect(RPCMethod.mcpServerStatusList == "mcpServerStatus/list")
        #expect(RPCMethod.mcpServerReload == "config/mcpServer/reload")
        #expect(ServerNotificationMethod.mcpServerStatusUpdated == "mcpServer/startupStatus/updated")
    }

    // MARK: authStatus 各枚举值 + 未知兜底

    @Test func decodeAuthStatusAllCases() throws {
        #expect(try decode(McpAuthStatus.self, "\"unsupported\"") == .unsupported)
        #expect(try decode(McpAuthStatus.self, "\"notLoggedIn\"") == .notLoggedIn)
        #expect(try decode(McpAuthStatus.self, "\"bearerToken\"") == .bearerToken)
        #expect(try decode(McpAuthStatus.self, "\"oAuth\"") == .oAuth)
    }

    @Test func decodeAuthStatusUnknownFallback() throws {
        // 协议未来新增枚举值不得崩溃，落 .unknown
        #expect(try decode(McpAuthStatus.self, "\"someFutureValue\"") == .unknown)
    }

    // MARK: 完整 server：tools 字典 / resources 数组 / serverInfo

    @Test func decodeFullServerStatus() throws {
        let json = #"""
        {"data":[{
          "name":"filesystem",
          "authStatus":"notLoggedIn",
          "tools":{"read_file":{"name":"read_file","description":"Read a file"},
                   "write_file":{"name":"write_file","inputSchema":{"type":"object"}}},
          "resources":[{"name":"root","uri":"file:///","mimeType":"inode/directory"}],
          "resourceTemplates":[{"name":"file","uriTemplate":"file:///{path}"}],
          "serverInfo":{"name":"fs-server","version":"1.2.0","title":"FS"}
        }],"nextCursor":null}
        """#
        let resp = try decode(ListMcpServerStatusResponse.self, json)
        #expect(resp.data.count == 1)
        let s = resp.data[0]
        #expect(s.name == "filesystem")
        #expect(s.authStatus == .notLoggedIn)
        #expect(s.tools.count == 2)
        #expect(s.tools["read_file"]?.description == "Read a file")
        #expect(s.resources.first?.uri == "file:///")
        #expect(s.resourceTemplates.first?.uriTemplate == "file:///{path}")
        #expect(s.serverInfo?.version == "1.2.0")
    }

    // MARK: serverInfo 缺省 + 空集合宽松解码不崩

    @Test func decodeServerStatusLenientDefaults() throws {
        // 仅 required 字段的最小体，serverInfo 缺省、集合为空 → 不崩，默认空集合
        let json = #"""
        {"data":[{"name":"minimal","authStatus":"unsupported",
                  "tools":{},"resources":[],"resourceTemplates":[]}]}
        """#
        let resp = try decode(ListMcpServerStatusResponse.self, json)
        let s = resp.data[0]
        #expect(s.name == "minimal")
        #expect(s.serverInfo == nil)
        #expect(s.tools.isEmpty)
        #expect(s.resources.isEmpty)
        #expect(s.resourceTemplates.isEmpty)
        #expect(resp.nextCursor == nil)
    }
}
