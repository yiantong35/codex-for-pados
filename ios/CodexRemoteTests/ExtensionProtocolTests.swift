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

    // MARK: Hooks 方法常量 wire 字符串（核实自 ClientRequest.json）
    @Test func hooksListMethodMatchesWire() {
        #expect(RPCMethod.hooksList == "hooks/list")
    }

    // HooksListResponse 全字段解码：跨 cwd、事件/类型/来源/信任/启用、matcher/command
    @Test func decodeHooksListFull() throws {
        let json = """
        {"data":[
          {"cwd":"/repo","warnings":[],"errors":[],"hooks":[
            {"key":"h1","eventName":"preToolUse","handlerType":"command","matcher":"Bash",
             "command":"echo hi","timeoutSec":30,"sourcePath":"/cfg/hooks.toml","source":"user",
             "displayOrder":0,"enabled":true,"isManaged":false,"currentHash":"abc","trustStatus":"trusted"},
            {"key":"h2","eventName":"stop","handlerType":"prompt","matcher":null,"command":null,
             "timeoutSec":10,"sourcePath":"/cfg/hooks.toml","source":"project",
             "displayOrder":1,"enabled":false,"isManaged":true,"currentHash":"def","trustStatus":"managed"}
          ]}
        ]}
        """
        let r = try JSONDecoder().decode(HooksListResponse.self, from: Data(json.utf8))
        #expect(r.data.count == 1)
        let hooks = r.data[0].hooks
        #expect(hooks.count == 2)
        #expect(hooks[0].key == "h1")
        #expect(hooks[0].eventName == .preToolUse)
        #expect(hooks[0].handlerType == .command)
        #expect(hooks[0].matcher == "Bash")
        #expect(hooks[0].command == "echo hi")
        #expect(hooks[0].source == .user)
        #expect(hooks[0].trustStatus == .trusted)
        #expect(hooks[0].enabled == true)
        #expect(hooks[0].id == "h1")            // Identifiable = key
        #expect(hooks[1].eventName == .stop)
        #expect(hooks[1].handlerType == .prompt)
        #expect(hooks[1].matcher == nil)        // null → nil
        #expect(hooks[1].command == nil)
        #expect(hooks[1].trustStatus == .managed)
        #expect(hooks[1].enabled == false)
    }

    // 未知枚举兜底 .unknown（eventName/handlerType/source/trustStatus 全落 unknown），不崩
    @Test func decodeHookUnknownEnums() throws {
        let json = """
        {"data":[{"cwd":"/x","warnings":[],"errors":[],"hooks":[
          {"key":"h","eventName":"warpDrive","handlerType":"telepathy","matcher":null,"command":null,
           "timeoutSec":1,"sourcePath":"/p","source":"galaxy","displayOrder":0,
           "enabled":true,"isManaged":false,"currentHash":"x","trustStatus":"quantum"}]}]}
        """
        let r = try JSONDecoder().decode(HooksListResponse.self, from: Data(json.utf8))
        let h = r.data[0].hooks[0]
        #expect(h.eventName == .unknown)
        #expect(h.handlerType == .unknown)
        #expect(h.source == .unknown)
        #expect(h.trustStatus == .unknown)
    }

    // 缺省宽松：缺 data / 缺集合字段 / 单字段缺失都不整条失败
    @Test func decodeHooksLoose() throws {
        let empty = try JSONDecoder().decode(HooksListResponse.self, from: Data("{}".utf8))
        #expect(empty.data.isEmpty)
        let entry = try JSONDecoder().decode(HooksListEntry.self, from: Data(#"{"cwd":"/a"}"#.utf8))
        #expect(entry.hooks.isEmpty)
        #expect(entry.errors.isEmpty)
        #expect(entry.warnings.isEmpty)
        // 单个 hook 缺大量字段：key 保留，枚举/布尔落默认，不抛
        let hook = try JSONDecoder().decode(HookMetadata.self, from: Data(#"{"key":"only"}"#.utf8))
        #expect(hook.key == "only")
        #expect(hook.eventName == .unknown)
        #expect(hook.handlerType == .unknown)
        #expect(hook.source == .unknown)
        #expect(hook.trustStatus == .unknown)
        #expect(hook.enabled == false)
    }

    // HookErrorInfo（path/message）解码
    @Test func decodeHookErrorInfo() throws {
        let e = try JSONDecoder().decode(HookErrorInfo.self,
            from: Data(#"{"path":"/cfg/bad.toml","message":"parse error"}"#.utf8))
        #expect(e.path == "/cfg/bad.toml")
        #expect(e.message == "parse error")
    }
}
