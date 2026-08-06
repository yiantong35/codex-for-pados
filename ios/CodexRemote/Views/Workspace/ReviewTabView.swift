import SwiftUI

/// 审查 tab：数据源切换（本轮/全量）+ 逐行红绿 diff（ReviewPanelView）+ AI 审查发起入口。
/// 发起入口跟随当前数据源（设计 D1）：本轮→custom{turnDiff}、全量→uncommittedChanges，
/// 经注入的 activeConversation.startReview 回调调 review/start（inline，结果回主对话回显）。
struct ReviewTabView: View {
    @Environment(ActiveConversationHolder.self) private var activeConversation
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 全量 diff 拉取所需的工作目录（取自选中 thread；缺失则「全量」不可用）。
    var cwd: String?

    @State private var mode: ReviewSourceMode = .turn
    @State private var fullSnapshot = FullDiffSnapshotModel()
    @State private var isSubmittingReview = false
    @State private var reviewFeedback: ReviewStartFeedback?

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
        return .init(
            cwd: cwd,
            conversationIdentity: identity,
            fetchGeneration: activeConversation.fetchGeneration
        )
    }

    static func canSubmitReview(sourceAvailable: Bool, isSubmitting: Bool) -> Bool {
        sourceAvailable && !isSubmitting
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("review.source", selection: $mode) {
                    ForEach(ReviewSourceMode.allCases) { m in Text(m.label(locale: locale)).tag(m) }
                }
                .pickerStyle(.segmented)

                Button(action: submitReview) {
                    if isSubmittingReview {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkle.magnifyingglass")
                    }
                }
                .buttonStyle(.plain)
                .minimumHitTarget44()
                .disabled(!Self.canSubmitReview(
                    sourceAvailable: canStartReview,
                    isSubmitting: isSubmittingReview))
                .accessibilityLabel(Text("review.start"))

                if mode == .full {
                    Button {
                        Task { await refreshFullDiff() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .minimumHitTarget44()
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
                if let reviewFeedback {
                    Label(reviewFeedback.labelKey, systemImage: reviewFeedback.systemImage)
                        .font(.caption)
                        .foregroundStyle(reviewFeedback == .failed ? .red : .primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.opacity)
                        .accessibilityLabel(Text(reviewFeedback.labelKey))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: reviewFeedback)
        }
        .task(id: "\(String(describing: mode))|\(fullContext?.cwd ?? "")|\(fullContext?.conversationIdentity ?? "")|\(fullContext?.fetchGeneration ?? -1)") {
            fullSnapshot.invalidate(for: fullContext)
            guard mode == .full, let context = fullContext,
                  let fetch = activeConversation.fetchFullDiff else { return }
            await fullSnapshot.ensureLoaded(context: context, fetch: fetch)
        }
    }

    private func submitReview() {
        guard Self.canSubmitReview(sourceAvailable: canStartReview, isSubmitting: isSubmittingReview) else { return }
        isSubmittingReview = true
        Task { @MainActor in
            let requestedMode = mode
            if requestedMode == .full, !(await refreshFullDiff()) {
                reviewFeedback = .failed
            } else {
                let ok = await activeConversation.startReview?(requestedMode) ?? false
                reviewFeedback = ok ? .started : .failed
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            reviewFeedback = nil
            isSubmittingReview = false
        }
    }

    /// #2：全量 diff 是否需重取——`.full` 且 cwd 非空且与已缓存 cwd 不同才重取。
    /// cwd 为空不请求；`.turn` 不走全量。纯函数便于单测。
    static func shouldRefetchFullDiff(mode: ReviewSourceMode,
                                      cachedCwd: String?,
                                      currentCwd: String?,
                                      cachedGeneration: Int? = nil,
                                      currentGeneration: Int = 0) -> Bool {
        guard mode == .full, let currentCwd else { return false }
        return cachedCwd != currentCwd || cachedGeneration != currentGeneration
    }

    @discardableResult
    private func refreshFullDiff() async -> Bool {
        guard let context = fullContext, let fetch = activeConversation.fetchFullDiff else { return false }
        return await fullSnapshot.refresh(context: context, fetch: fetch)
    }
}

private enum ReviewStartFeedback: Equatable {
    case started
    case failed

    var labelKey: LocalizedStringKey {
        switch self {
        case .started: "review.started"
        case .failed: "review.startFailed"
        }
    }

    var systemImage: String {
        switch self {
        case .started: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}
