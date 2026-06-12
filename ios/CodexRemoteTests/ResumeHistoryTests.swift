import XCTest
@testable import CodexRemote

/// Task 20 Step 6：恢复桌面 app 会话时，thread/resume 响应里携带的历史 turn/item
/// 必须被摄入 ConversationState 并可渲染。fixture 取自真实 codex app-server 录制
/// （threadResumeHistory.json，见 commit body）。
///
/// 真实 item schema（实测）：
///   userMessage: { type, id, content:[{type:"text", text, text_elements}] }
///   agentMessage: { type, id, text }          ← text 为直接字段，非 content[]
///   fileChange:   { type, id, changes:[{path, kind:{type}, diff}], status }
final class ResumeHistoryTests: XCTestCase {

    /// 把真实 resume 响应灌入后，历史 turn 的各类 item 按真实 schema 映射进 state.items。
    func testIngestRealResumeHistory() throws {
        let result = try loadResumeResult("threadResumeHistory")
        var state = ConversationState(threadId: "019eaf93-e9b1-7383-b979-2fdacf29c211")
        let reducer = ThreadReducer()

        reducer.ingest(resumeResult: result, to: &state)

        // 至少包含两条 userMessage（两个 turn 各一条）、若干 agentMessage、一条 fileChange。
        let userMsgs = state.items.compactMap { item -> String? in
            if case .userMessage(_, let t) = item { return t } else { return nil }
        }
        XCTAssertGreaterThanOrEqual(userMsgs.count, 2, "应摄入历史 userMessage，实际 items=\(state.items)")
        XCTAssertTrue(userMsgs.contains { $0.contains("已完成交接整理") },
                      "userMessage 正文应取自 content[].text，实际：\(userMsgs)")

        let agentMsgs = state.items.compactMap { item -> String? in
            if case .agentMessage(_, let t) = item { return t } else { return nil }
        }
        XCTAssertTrue(agentMsgs.contains { $0.contains("只读接管检查") },
                      "agentMessage 正文应取自顶层 text 字段，实际：\(agentMsgs)")

        let fileChanges = state.items.filter { if case .fileChange = $0 { return true } else { return false } }
        XCTAssertEqual(fileChanges.count, 1, "应摄入一条 fileChange，实际：\(state.items)")
        guard case .fileChange(let id, let file, _, _, let diff)? = fileChanges.first else {
            return XCTFail("应有 fileChange item")
        }
        XCTAssertEqual(id, "call_8gpd2dRXAeIESpvPtjBL7fmp")
        XCTAssertEqual(file, "/Volumes/mount/workspace/web-dev/AGENTS.md",
                       "fileChange.file 应取自 changes[0].path")
        XCTAssertTrue(diff.contains("@@"), "diff 应取自 changes[0].diff")
    }

    /// 顺序保持：item 按 turns→items 出现顺序追加，第一条是首个 userMessage。
    func testIngestPreservesOrder() throws {
        let result = try loadResumeResult("threadResumeHistory")
        var state = ConversationState(threadId: "t")
        ThreadReducer().ingest(resumeResult: result, to: &state)
        guard case .userMessage(let id, _)? = state.items.first else {
            return XCTFail("首条应为 userMessage，实际：\(state.items)")
        }
        XCTAssertEqual(id, "item-1")
    }

    /// 重复摄入幂等：不产生重复 id 的 item。
    func testIngestIsIdempotent() throws {
        let result = try loadResumeResult("threadResumeHistory")
        var state = ConversationState(threadId: "t")
        let reducer = ThreadReducer()
        reducer.ingest(resumeResult: result, to: &state)
        let firstCount = state.items.count
        reducer.ingest(resumeResult: result, to: &state)
        XCTAssertEqual(state.items.count, firstCount, "重复摄入不应产生重复 item")
    }

    // MARK: - helpers

    /// 读取 fixture（完整 JSON-RPC 响应帧）并取出 result 字典。
    private func loadResumeResult(_ name: String) throws -> [String: Any] {
        let url = Bundle(for: type(of: self)).url(forResource: name, withExtension: "json")!
        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        guard let dict = response.result.value as? [String: Any] else {
            throw XCTSkip("fixture result 非对象")
        }
        return dict
    }
}
