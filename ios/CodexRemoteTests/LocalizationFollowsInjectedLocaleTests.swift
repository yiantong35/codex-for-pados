import XCTest
@testable import CodexRemote

/// D5：面向用户文案跟随注入 locale。共享 helper 按 locale 查对应 .lproj 表，
/// 切 en 得英文、切 zh-Hans 得中文，均非 key 本身（键存在）。
final class LocalizationFollowsInjectedLocaleTests: XCTestCase {

    /// 本任务新增/迁移的键，两种语言都必须可解析（解析失败会回落成 key 本身）。
    private let keys = [
        "review.source",            // 原 "数据源"
        "fileBrowser.empty",        // 原 "无选中会话，暂无可浏览目录"
        "fileBrowser.title",        // 原 "文件"
        "fileBrowser.refresh",      // 原 "刷新"
        "fileBrowser.tooLarge",     // 原 "文件过大，不支持预览"
        "fileBrowser.binary",       // 原 "二进制文件，不支持预览"
        "fileBrowser.selectFile",   // 原 "选择文件查看"
        "sideChat.start",           // 原 "开始侧聊"
        "sideChat.close",           // 原 "关闭侧聊"
        "sideChat.noMainThread",    // 原 "无选中主对话…"
        "sideChat.pickToStart",     // 原 "点「开始侧聊」…"
        "review.mode.turn",         // 原 "本轮"
        "review.mode.full",         // 原 "全量"
    ]

    func test_sharedHelper_returnsInjectedLanguage() {
        let en = Locale(identifier: "en")
        let zh = Locale(identifier: "zh-Hans")
        for key in keys {
            let e = L10n.string(key, locale: en)
            let z = L10n.string(key, locale: zh)
            XCTAssertNotEqual(e, key, "en 缺键 \(key)")
            XCTAssertNotEqual(z, key, "zh 缺键 \(key)")
            // en 结果不含 CJK（无中英混排残留）。
            XCTAssertFalse(e.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                           "en 文案含中文残留：\(key)=\(e)")
        }
    }

    /// 动态标签（审查模式名、右栏 tab 名）按注入 locale 解析，en 无中文残留。
    func test_dynamicLabels_followInjectedLocale() {
        let en = Locale(identifier: "en")
        for mode in ReviewSourceMode.allCases {
            let s = mode.label(locale: en)
            XCTAssertFalse(s.isEmpty)
            XCTAssertFalse(s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                           "审查模式名 en 含中文残留：\(s)")
        }
        for tab in RightPanelTab.allCases {
            let s = tab.label(locale: en)
            XCTAssertFalse(s.isEmpty)
            XCTAssertFalse(s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        }
    }
}
