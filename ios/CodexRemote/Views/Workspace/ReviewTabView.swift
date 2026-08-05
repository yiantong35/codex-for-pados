import SwiftUI

/// 审查 tab：数据源切换（本轮/全量）+ 逐行红绿 diff（ReviewPanelView）+ AI 审查发起入口。
/// 发起入口跟随当前数据源（设计 D1）：本轮→custom{turnDiff}、全量→uncommittedChanges，
/// 经注入的 activeConversation.startReview 回调调 review/start（inline，结果回主对话回显）。
struct ReviewTabView: View {
    @Environment(ActiveConversationHolder.self) private var activeConversation
    @Environment(\.locale) private var locale
    /// 全量 diff 拉取所需的工作目录（取自选中 thread；缺失则「全量」不可用）。
    var cwd: String?

    @State private var mode: ReviewSourceMode = .turn
    @State private var fullDiff: String?
    /// #2：fullDiff 当前所属 cwd；切 thread（cwd 变）后与选中 cwd 不符即失效重取。
    @State private var fullDiffCwd: String?
    @State private var loadingFull = false

    private var turnDiff: String { activeConversation.state?.turnDiff ?? "" }
    private var source: ReviewDiffSource {
        ReviewDiffSource.resolve(mode: mode, turnDiff: turnDiff, fullDiff: fullDiff, locale: locale)
    }

    /// 当前数据源能否发起审查：回调已接线 + 对应数据源有效。
    private var canStartReview: Bool {
        guard activeConversation.startReview != nil else { return false }
        switch mode {
        case .turn: return !turnDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .full: return cwd != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("review.source", selection: $mode) {
                    ForEach(ReviewSourceMode.allCases) { m in Text(m.label(locale: locale)).tag(m) }
                }
                .pickerStyle(.segmented)

                // startReview 是 fire-and-forget（设计 D4）：内部 Task 发出 review/start 后立即返回，
                // 不 await 网络往返。因此不设 isStarting 防抖态——它无法覆盖请求生命周期（await 微秒即返回），
                // 只会是形同虚设的假防抖。快速连点最多触发多次 review/start，属 D4 已接受的低危行为。
                Button {
                    Task { _ = await activeConversation.startReview?(mode) }
                } label: {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(!canStartReview)
                .accessibilityLabel(Text("review.start"))
            }
            .padding(8)

            if loadingFull {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReviewPanelView(source: source)
            }
        }
        // #2：绑定 mode + cwd 复合键；cwd 变即重跑 task。取指纹 String(describing:) 避免依赖 rawValue。
        .task(id: "\(String(describing: mode))|\(cwd ?? "")") {
            guard mode == .full, let cwd, let fetch = activeConversation.fetchFullDiff else { return }
            // 同 cwd 已缓存则不重复拉取；换 cwd 则失效重取（纯函数单一真源）。
            guard Self.shouldRefetchFullDiff(mode: mode, cachedCwd: fullDiffCwd, currentCwd: cwd) else { return }
            loadingFull = true
            fullDiff = await fetch(cwd)
            fullDiffCwd = cwd
            loadingFull = false
        }
    }

    /// #2：全量 diff 是否需重取——`.full` 且 cwd 非空且与已缓存 cwd 不同才重取。
    /// cwd 为空不请求；`.turn` 不走全量。纯函数便于单测。
    static func shouldRefetchFullDiff(mode: ReviewSourceMode, cachedCwd: String?, currentCwd: String?) -> Bool {
        guard mode == .full, let currentCwd else { return false }
        return cachedCwd != currentCwd
    }
}
