import Testing
import Foundation
@testable import CodexRemote

struct ExtensionCountTests {
    // 四组 store 新建即 count == 0（未连接/无数据），编译契约 + 类型为 Int
    @MainActor @Test func freshStoresReportZeroCount() {
        #expect(McpStore().count == 0)
        #expect(SkillsStore().count == 0)
        #expect(PluginsStore().count == 0)
        #expect(HooksStore().count == 0)
    }

    // PluginsStore.count = 跨 marketplace 打平后的插件总数（用解码结果构造场景）
    @Test func pluginsCountSumsAcrossMarketplaces() throws {
        let json = """
        {"marketplaces":[
          {"name":"official","plugins":[
            {"id":"p1","name":"A","enabled":true,"installed":true,"installPolicy":"AVAILABLE",
             "authPolicy":"ON_USE","source":{"type":"remote"},"availability":"AVAILABLE"},
            {"id":"p2","name":"B","enabled":true,"installed":true,"installPolicy":"AVAILABLE",
             "authPolicy":"ON_USE","source":{"type":"remote"},"availability":"AVAILABLE"}]},
          {"name":"third","plugins":[
            {"id":"p3","name":"C","enabled":true,"installed":true,"installPolicy":"AVAILABLE",
             "authPolicy":"ON_USE","source":{"type":"remote"},"availability":"AVAILABLE"}]}
        ]}
        """
        let r = try JSONDecoder().decode(PluginListResponse.self, from: Data(json.utf8))
        #expect(PluginsStore.count(of: r.marketplaces) == 3)
    }
}
