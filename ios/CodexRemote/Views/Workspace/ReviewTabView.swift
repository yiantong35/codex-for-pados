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
    @State private var fullSnapshot = FullDiffSnapshotModel()
    /// #9：发起审查后的一次性可见反馈（true = 短时显示「审查已发起」Capsule）。
    @State private var showReviewStarted = false

    private var turnDiff: String { activeConversation.state?.turnDiff ?? "" }
    private var source: ReviewDiffSource {
        let currentFullDiff = fullSnapshot.context == fullContext ? fullSnapshot.diff : nil
        return ReviewDiffSource.resolve(mode: mode, turnDiff: turnDiff, fullDiff: currentFullDiff, locale: locale)
    }

    /// 当前数据源能否发起审查：回调已接线 + 对应数据源有效。
    private var canStartReview: Bool {
        guard activeConversation.startReview != nil else { return false }
        switch mode {
        case .turn: return !turnDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .full: return fullContext != nil && activeConversation.fetchFullDiff != nil
        }
    }

    private var fullContext: FullDiffContextKey? {
        guard let cwd, let identity = activeConversation.contextIdentity else { return nil }
        return .init(cwd: cwd, conversationIdentity: identity)
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
                    // #9：消费 startReview 的 Bool 返回事件驱动可见反馈；不改 D4 fire-and-forget
                    // （内部仍立即返回），不加假防抖。
                    Task {
                        let requestedMode = mode
                        if requestedMode == .full {
                            guard await refreshFullDiff() else { return }
                        }
                        let ok = await activeConversation.startReview?(requestedMode) ?? false
                        guard ok else { return }
                        showReviewStarted = true
                        // 一次性延时收起（单次挂起，无周期唤醒；先例 ConversationView.swift:156）。
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        showReviewStarted = false
                    }
                } label: {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(!canStartReview)
                .accessibilityLabel(Text("review.start"))

                if mode == .full {
                    Button {
                        Task { await refreshFullDiff() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(fullContext == nil || activeConversation.fetchFullDiff == nil || fullSnapshot.isLoading)
                    .accessibilityLabel(Text("review.refresh"))
                }
            }
            .padding(8)

            Group {
                if mode == .full && fullSnapshot.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReviewPanelView(source: source)
                }
            }
            .overlay(alignment: .top) {
                if showReviewStarted {
                    // 连接横幅同款 Capsule 样式 inline 提示（无 toast）。
                    Label("review.started", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.opacity)
                        .accessibilityLabel(Text("review.started"))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showReviewStarted)
        }
        .task(id: "\(String(describing: mode))|\(fullContext?.cwd ?? "")|\(fullContext?.conversationIdentity ?? "")") {
            fullSnapshot.invalidate(for: fullContext)
            guard mode == .full, let context = fullContext,
                  let fetch = activeConversation.fetchFullDiff else { return }
            await fullSnapshot.ensureLoaded(context: context, fetch: fetch)
        }
    }

    /// #2：全量 diff 是否需重取——`.full` 且 cwd 非空且与已缓存 cwd 不同才重取。
    /// cwd 为空不请求；`.turn` 不走全量。纯函数便于单测。
    static func shouldRefetchFullDiff(mode: ReviewSourceMode, cachedCwd: String?, currentCwd: String?) -> Bool {
        guard mode == .full, let currentCwd else { return false }
        return cachedCwd != currentCwd
    }

    @discardableResult
    private func refreshFullDiff() async -> Bool {
        guard let context = fullContext, let fetch = activeConversation.fetchFullDiff else { return false }
        return await fullSnapshot.refresh(context: context, fetch: fetch)
    }
}
