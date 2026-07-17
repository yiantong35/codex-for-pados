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
}
