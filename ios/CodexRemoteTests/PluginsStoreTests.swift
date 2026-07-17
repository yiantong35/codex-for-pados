import Testing
import Foundation
@testable import CodexRemote

struct PluginsStoreTests {
    // attach 触发 refresh → 发出 plugin/list 帧
    @MainActor @Test func attachSendsListFrame() async {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = PluginsStore()
        await store.attach(rpc: rpc)
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("plugin/list") })
    }

    // readPluginDetail 发出 plugin/read 帧
    @MainActor @Test func readDetailSendsReadFrame() async {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = PluginsStore()
        await store.attach(rpc: rpc)
        _ = await store.readPluginDetail(pluginName: "Weather", marketplace: "official")
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("plugin/read") })
    }

    // readPluginSkill 发出 plugin/skill/read 帧
    @MainActor @Test func readSkillSendsSkillReadFrame() async {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = PluginsStore()
        await store.attach(rpc: rpc)
        _ = await store.readPluginSkill(marketplace: "official", pluginId: "p1", skillName: "forecast")
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("plugin/skill/read") })
    }

    // 未连接 → refresh 不发请求、marketplaces 空、下钻返回 nil、不崩
    @MainActor @Test func withoutRpcIsNoOp() async {
        let store = PluginsStore()
        await store.refresh()
        #expect(store.marketplaces.isEmpty)
        let detail = await store.readPluginDetail(pluginName: "x", marketplace: "m")
        #expect(detail == nil)
        let contents = await store.readPluginSkill(marketplace: "m", pluginId: "p", skillName: "s")
        #expect(contents == nil)
    }
}
