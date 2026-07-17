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
}
