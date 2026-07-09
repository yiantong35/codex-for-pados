import XCTest
@testable import CodexRemote

final class ModelSelectionTests: XCTestCase {
    private func config(model: String?, effort: String?) -> CuratedConfig {
        // CuratedConfig 经 Decodable 构造：用 JSON 注入所需字段。
        var dict: [String: Any] = [:]
        if let model { dict["model"] = model }
        if let effort { dict["model_reasoning_effort"] = effort }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(CuratedConfig.self, from: data)
    }

    // 用户未显式选择 → 生效模型回退账号 config 默认（治两种登录：值来自服务器）
    func testEffectiveModelFallsBackToConfig() {
        let sel = ModelSelection()
        XCTAssertEqual(sel.effectiveModel(config: config(model: "gpt-5.5", effort: "xhigh")), "gpt-5.5")
    }

    // 用户显式选择 → 覆盖 config 默认
    func testEffectiveModelUsesOverride() {
        let sel = ModelSelection(modelOverride: "gpt-5-mini")
        XCTAssertEqual(sel.effectiveModel(config: config(model: "gpt-5.5", effort: "xhigh")), "gpt-5-mini")
    }

    // 无 override 且 config 未加载 → nil（让服务器用其默认，不硬塞）
    func testEffectiveModelNilWhenNoOverrideNoConfig() {
        let sel = ModelSelection()
        XCTAssertNil(sel.effectiveModel(config: nil))
    }

    // effort 回退 config（字符串 "xhigh" → .xhigh）
    func testEffectiveEffortParsesConfig() {
        let sel = ModelSelection()
        XCTAssertEqual(sel.effectiveEffort(config: config(model: "gpt-5.5", effort: "xhigh")), .xhigh)
    }

    // effort override 优先
    func testEffectiveEffortUsesOverride() {
        let sel = ModelSelection(effortOverride: .low)
        XCTAssertEqual(sel.effectiveEffort(config: config(model: "gpt-5.5", effort: "xhigh")), .low)
    }

    // config effort 非法/缺失 → nil
    func testEffectiveEffortNilWhenConfigInvalid() {
        let sel = ModelSelection()
        XCTAssertNil(sel.effectiveEffort(config: config(model: "gpt-5.5", effort: nil)))
        XCTAssertNil(sel.effectiveEffort(config: config(model: "gpt-5.5", effort: "bogus")))
    }
}
