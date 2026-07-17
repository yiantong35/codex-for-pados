import Testing
import Foundation
@testable import CodexRemote

struct ExtensionProtocolTests {
    // MARK: 方法常量 wire 字符串（核实自 v2 schema）
    @Test func methodConstantsMatchWire() {
        #expect(RPCMethod.skillsList == "skills/list")
        #expect(RPCMethod.skillsConfigWrite == "skills/config/write")
        #expect(RPCMethod.pluginList == "plugin/list")
        #expect(RPCMethod.pluginRead == "plugin/read")
        #expect(RPCMethod.pluginSkillRead == "plugin/skill/read")
    }

    // SkillsChanged 真实 wire method = "skills/changed"（不是 schema 定义名 SkillsChangedNotification）
    @Test func skillsChangedNotificationWire() {
        #expect(ServerNotificationMethod.skillsChanged == "skills/changed")
    }

    // MARK: SkillsListResponse 解码
    @Test func decodeSkillsListFull() throws {
        let json = """
        {"data":[{"cwd":"/repo","errors":[],"skills":[
          {"name":"fmt","description":"Formatter","enabled":true,"path":"/u/fmt","scope":"user",
           "dependencies":{"tools":[{"type":"command","value":"prettier","command":"prettier"}]}},
          {"name":"lint","description":"Linter","enabled":false,"path":"/r/lint","scope":"repo"}
        ]}]}
        """
        let r = try JSONDecoder().decode(SkillsListResponse.self, from: Data(json.utf8))
        #expect(r.data.count == 1)
        let skills = r.data[0].skills
        #expect(skills.count == 2)
        #expect(skills[0].name == "fmt")
        #expect(skills[0].enabled == true)
        #expect(skills[0].scope == .user)
        #expect(skills[0].dependencies?.tools.first?.value == "prettier")
        #expect(skills[1].scope == .repo)
        #expect(skills[1].dependencies == nil)
        #expect(skills[0].id == "/u/fmt")   // Identifiable = path
    }

    // 未知 scope 兜底 .unknown，不崩
    @Test func decodeSkillUnknownScope() throws {
        let json = """
        {"data":[{"cwd":"/x","errors":[],"skills":[
          {"name":"weird","description":"d","enabled":true,"path":"/p","scope":"galaxy"}]}]}
        """
        let r = try JSONDecoder().decode(SkillsListResponse.self, from: Data(json.utf8))
        #expect(r.data[0].skills[0].scope == .unknown)
    }

    // 缺省宽松：缺 data / 缺集合字段不整条失败
    @Test func decodeSkillsLoose() throws {
        let r = try JSONDecoder().decode(SkillsListResponse.self, from: Data("{}".utf8))
        #expect(r.data.isEmpty)
        let entry = try JSONDecoder().decode(SkillsListEntry.self, from: Data(#"{"cwd":"/a"}"#.utf8))
        #expect(entry.skills.isEmpty)
        #expect(entry.errors.isEmpty)
    }

    // SkillsConfigWriteParams 编码：enabled 必带，name/path 二选一（nil 不出现）
    @Test func encodeSkillsConfigWriteParams() throws {
        let p = SkillsConfigWriteParams(enabled: false, name: "fmt", path: nil)
        let obj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(p)) as! [String: Any]
        #expect(obj["enabled"] as? Bool == false)
        #expect(obj["name"] as? String == "fmt")
        #expect(obj["path"] == nil)
    }

    // MARK: PluginListResponse 解码
    @Test func decodePluginListFull() throws {
        let json = """
        {"marketplaces":[{"name":"official","plugins":[
          {"id":"p1","name":"Weather","enabled":true,"installed":true,"installPolicy":"AVAILABLE",
           "authPolicy":"ON_USE","source":{"type":"remote"},"availability":"AVAILABLE",
           "interface":{"category":"Utilities","shortDescription":"Forecast"}},
          {"id":"p2","name":"Blocked","enabled":false,"installed":false,"installPolicy":"NOT_AVAILABLE",
           "authPolicy":"ON_INSTALL","source":{"type":"remote"},"availability":"DISABLED_BY_ADMIN"}
        ]}]}
        """
        let r = try JSONDecoder().decode(PluginListResponse.self, from: Data(json.utf8))
        #expect(r.marketplaces.count == 1)
        let plugins = r.marketplaces[0].plugins
        #expect(plugins.count == 2)
        #expect(plugins[0].name == "Weather")
        #expect(plugins[0].availability == .available)
        #expect(plugins[0].category == "Utilities")
        #expect(plugins[0].displayDescription == "Forecast")
        #expect(plugins[1].availability == .disabledByAdmin)
        #expect(r.marketplaces[0].id == "official")   // Identifiable = name
    }

    // ENABLED 上游别名映射为 .available；未知值兜底 .unknown
    @Test func decodePluginAvailabilityAliasAndUnknown() throws {
        func avail(_ raw: String) throws -> PluginAvailability {
            let json = """
            {"marketplaces":[{"name":"m","plugins":[
              {"id":"i","name":"n","enabled":true,"installed":true,"installPolicy":"AVAILABLE",
               "authPolicy":"ON_USE","source":{"type":"remote"},"availability":"\(raw)"}]}]}
            """
            return try JSONDecoder().decode(PluginListResponse.self, from: Data(json.utf8))
                .marketplaces[0].plugins[0].availability
        }
        #expect(try avail("ENABLED") == .available)
        #expect(try avail("SOMETHING_NEW") == .unknown)
    }

    // 缺省宽松：缺 marketplaces 不整条失败
    @Test func decodePluginListLoose() throws {
        let r = try JSONDecoder().decode(PluginListResponse.self, from: Data("{}".utf8))
        #expect(r.marketplaces.isEmpty)
    }

    // PluginReadResponse → PluginDetail.skills（内置 skill 摘要）
    @Test func decodePluginDetailSkills() throws {
        let json = """
        {"plugin":{"marketplaceName":"official","mcpServers":["srv"],
          "appTemplates":[],"apps":[],"hooks":[],
          "summary":{"id":"p1","name":"Weather","enabled":true,"installed":true,
            "installPolicy":"AVAILABLE","authPolicy":"ON_USE","source":{"type":"remote"}},
          "skills":[{"name":"forecast","description":"Get forecast","enabled":true}]}}
        """
        let r = try JSONDecoder().decode(PluginReadResponse.self, from: Data(json.utf8))
        #expect(r.plugin.marketplaceName == "official")
        #expect(r.plugin.mcpServers == ["srv"])
        #expect(r.plugin.skills.count == 1)
        #expect(r.plugin.skills[0].name == "forecast")
        #expect(r.plugin.skills[0].id == "forecast")   // Identifiable = name
    }

    // PluginSkillReadResponse.contents 可选
    @Test func decodePluginSkillReadContents() throws {
        let r = try JSONDecoder().decode(PluginSkillReadResponse.self,
            from: Data(##"{"contents":"# Forecast\n..."}"##.utf8))
        #expect(r.contents == "# Forecast\n...")
        let empty = try JSONDecoder().decode(PluginSkillReadResponse.self, from: Data("{}".utf8))
        #expect(empty.contents == nil)
    }

    // 请求参数编码：plugin/read 与 plugin/skill/read
    @Test func encodePluginParams() throws {
        let read = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PluginReadParams(pluginName: "Weather", remoteMarketplaceName: "official"))) as! [String: Any]
        #expect(read["pluginName"] as? String == "Weather")
        #expect(read["remoteMarketplaceName"] as? String == "official")

        let skill = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PluginSkillReadParams(remoteMarketplaceName: "official", remotePluginId: "p1", skillName: "forecast"))) as! [String: Any]
        #expect(skill["remoteMarketplaceName"] as? String == "official")
        #expect(skill["remotePluginId"] as? String == "p1")
        #expect(skill["skillName"] as? String == "forecast")
    }
}
