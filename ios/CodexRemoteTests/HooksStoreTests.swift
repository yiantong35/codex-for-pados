import Testing
import Foundation
@testable import CodexRemote

struct HooksStoreTests {
    // attach 触发 refresh → 发出 hooks/list 帧
    @MainActor @Test func attachSendsListFrame() async {
        let mock = MockTransport()
        await mock.setAutoRespond(true)
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = HooksStore()
        await store.attach(rpc: rpc)
        let frames = await mock.sent
        #expect(frames.contains { $0.contains("hooks/list") })
    }

    // 未连接（未 attach，rpc == nil）→ refresh 不发请求、hooks 空、count 0、不崩
    @MainActor @Test func refreshWithoutRpcIsNoOp() async {
        let store = HooksStore()
        await store.refresh()
        #expect(store.hooks.isEmpty)
        #expect(store.count == 0)
    }

    // 跨 cwd 打平 + 按 key 去重（纯函数 flatten，避免依赖 MockTransport 定制响应）
    @Test func flattenDedupsAcrossCwds() throws {
        let json = """
        {"data":[
          {"cwd":"/a","warnings":[],"errors":[],"hooks":[
            {"key":"dup","eventName":"stop","handlerType":"command","source":"user","trustStatus":"trusted","enabled":true},
            {"key":"only-a","eventName":"stop","handlerType":"command","source":"user","trustStatus":"trusted","enabled":true}]},
          {"cwd":"/b","warnings":[],"errors":[],"hooks":[
            {"key":"dup","eventName":"stop","handlerType":"command","source":"project","trustStatus":"managed","enabled":false},
            {"key":"only-b","eventName":"stop","handlerType":"command","source":"user","trustStatus":"trusted","enabled":true}]}
        ]}
        """
        let response = try JSONDecoder().decode(HooksListResponse.self, from: Data(json.utf8))
        let flat = HooksStore.flatten(response)
        // dup 只留一条（首次出现），加 only-a / only-b → 共 3 条
        #expect(flat.count == 3)
        #expect(flat.filter { $0.key == "dup" }.count == 1)
        #expect(Set(flat.map { $0.key }) == ["dup", "only-a", "only-b"])
    }
}
