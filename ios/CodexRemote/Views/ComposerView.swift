import SwiftUI
import PhotosUI

struct PhotoDataLoader {
    let load: @MainActor (PhotosPickerItem) async throws -> Data

    static let live = PhotoDataLoader { item in
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw PhotoDataLoaderError.noData
        }
        return data
    }
}

private enum PhotoDataLoaderError: Error { case noData }

/// 底部 composer（设计 §3）：多行文本 + 图片附件（PhotosPicker）+ 模型/推理强度选择器 + 发送。
/// 图片选取后转 base64 data URL 作 `UserInput.image`（v2 协议 image 走内联 url）。
/// 模型/推理映射到 `ConversationStore.send(input:model:effort:)` → `turn/start` 的 `model`/`effort`。
/// 中途控制（turn 进行中 steer/排队/interrupt）在 Task 17 实现，本视图只做基础发送。
struct ComposerView: View {
    let store: ConversationStore
    let isEnabled: Bool
    let handlesWorkspaceShortcuts: Bool
    private let photoDataLoader: PhotoDataLoader
    // 服务器驱动的模型数据（model/list + config/read）。绝不硬编码——两种登录（账号/API）
    // 可用模型不同，daemon 已按登录返回真实数据（见 memory: pados-model-server-driven）。
    @Environment(EnvironmentStore.self) private var env
    @Environment(ShortcutStore.self) private var shortcuts
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var draft: ComposerDraft
    @State private var showModelPopover = false
    // Enter 发送（fallback b）：@FocusState → @State——UIViewRepresentable 不接 SwiftUI 焦点系统，
    // 改由 ComposerTextEditor 双向桥接 UIKit first responder（focusComposer 快捷键置 true 仍生效）。
    @State private var inputFocused: Bool = false

    init(store: ConversationStore, draft: ComposerDraft? = nil, isEnabled: Bool = true,
         handlesWorkspaceShortcuts: Bool = true,
         photoDataLoader: PhotoDataLoader = .live) {
        self.store = store
        self.isEnabled = isEnabled
        self.handlesWorkspaceShortcuts = handlesWorkspaceShortcuts
        self.photoDataLoader = photoDataLoader
        _draft = State(initialValue: draft ?? ComposerDraft())
    }

    /// 推理强度可选项（ReasoningEffort 全部 case）。
    private static let efforts: [ReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh]

    /// 当前生效模型 slug（显式选择或账号默认），用于 UI 显示与发送。
    private var effectiveModel: String? { draft.selection.effectiveModel(config: env.config) }
    private var effectiveEffort: ReasoningEffort? { draft.selection.effectiveEffort(config: env.config) }
    private var imageDataURL: String? { draft.imageAttachment.dataURL }
    private var imageError: String? {
        guard let error = draft.imageAttachment.error else { return nil }
        return String(
            format: L10n.string("composer.image.tooLarge", locale: locale),
            Self.mb(error.bytes), Self.mb(error.limit)
        )
    }

    private var canSend: Bool {
        Self.canSend(text: draft.text, imageDataURL: imageDataURL,
                     isImageLoading: draft.imageAttachment.isLoading)
    }

    static func canSend(text: String, imageDataURL: String?, isImageLoading: Bool) -> Bool {
        guard !isImageLoading else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageDataURL != nil
    }

    var body: some View {
        @Bindable var draft = draft
        VStack(spacing: 6) {
            if let err = store.state.lastSendError {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(verbatim: err)
                            .font(.footnote).multilineTextAlignment(.leading)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    if store.lastSendErrorIsRetryable {
                        HStack(spacing: 8) {
                            Button("common.retry") { Task { await store.retryLastSend() } }
                            Button("common.edit") {
                                if let entry = store.takeFailedSendForEditing() { draft.restore(entry) }
                            }
                            Button("common.discard", role: .destructive) { store.discardFailedSend() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
            }
            if let err = imageError {
                // F7：图片超出 relay 单帧上限，非阻塞提示（不像发送失败那样可重试——需换图）。
                // `err` 已是 `String(format:)` 拼好的最终文案（含具体 MB 数字），直接展示，
                // 不再当作新的本地化 key 查表（否则会去找不存在的 "composer.image.tooLarge %@"）。
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err)
                        .font(.footnote).multilineTextAlignment(.leading)
                    Spacer()
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 4)
            }
            if draft.imageAttachment.isLoading {
                attachmentStatusRow(
                    label: "composer.image.preparing",
                    systemImage: nil,
                    isProgress: true,
                    foreground: .secondary
                )
            } else if draft.imageAttachment.loadFailed {
                attachmentStatusRow(
                    label: "composer.image.loadFailed",
                    systemImage: "exclamationmark.triangle.fill",
                    isProgress: false,
                    foreground: .red
                )
            }
            if imageDataURL != nil {
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text("composer.imageAttached").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("composer.remove") {
                        draft.imageAttachment.clear()
                        draft.photoItem = nil
                    }
                    .font(.footnote)
                    .minimumHitTarget44()
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    composerUtilityControls(photoItem: $draft.photoItem)
                    composerTextField(text: $draft.text)
                        .frame(minWidth: 160)
                    turnControls
                }

                VStack(spacing: 6) {
                    composerTextField(text: $draft.text)
                    HStack(spacing: 8) {
                        composerUtilityControls(photoItem: $draft.photoItem)
                        Spacer(minLength: 8)
                        turnControls
                    }
                }
            }
            .disabled(!isEnabled)
        }
        .padding(8)
        .background(.bar)
        .background { composerShortcutLayer }
        .onChange(of: draft.photoItem) { _, item in
            guard let item else {
                draft.imageAttachment.clear()
                return
            }
            loadImage(item)
        }
        .onDisappear { draft.imageAttachment.cancelLoadingForDisappearance() }
    }

    @ViewBuilder
    private func composerUtilityControls(photoItem: Binding<PhotosPickerItem?>) -> some View {
        PhotosPicker(selection: photoItem, matching: .images) {
            Image(systemName: "plus.circle").font(.title3)
        }
        .foregroundStyle(.secondary)
        .minimumHitTarget44()
        .accessibilityLabel(Text("composer.a11y.pickImage"))

        Button { showModelPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text(verbatim: modelChipLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 7)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .foregroundStyle(.secondary)
        .minimumHitTarget44()
        .accessibilityLabel(Text("composer.a11y.model"))
        .accessibilityValue(Text(verbatim: modelChipLabel))
        .popover(isPresented: $showModelPopover) {
            modelSelectionContent
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large])
        }
    }

    /// Enter 发送（fallback b）：TextField(axis:.vertical) → ComposerTextEditor（UITextView 桥接）。
    /// 裸 Return/软键盘 Return=发送、⇧Return=换行、⌘Return=既有别名、IME 组合态放行——拦截逻辑
    /// 见 ComposerTextEditor.returnInterceptDecision；两套布局与侧聊共用本函数，自然同行为。
    private func composerTextField(text: Binding<String>) -> some View {
        ComposerTextEditor(text: text, isFocused: $inputFocused,
                           onSubmitSend: { performSendShortcut() })
            .frame(minHeight: 36)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("composer.placeholder")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 9)
                        .padding(.top, 7)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.systemGray4), lineWidth: 0.5))
    }

    @ViewBuilder
    private var turnControls: some View {
        if store.state.isTurnRunning {
            Button(role: .destructive) {
                Task { _ = await store.interrupt() }
            } label: {
                Image(systemName: "stop.circle.fill").font(.title2)
            }
            .minimumHitTarget44()
            .accessibilityLabel(Text("composer.a11y.stop"))
            Menu {
                Button("composer.steer") { Task { await trySteer() } }
                    .disabled(store.state.activeTurnKind != nil)
                Button("composer.enqueue") { Task { await enqueueCurrent() } }
                if let kind = store.state.activeTurnKind {
                    Text("composer.noSteer \(kind.rawValue)")
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!canSend)
            .minimumHitTarget44()
            .accessibilityLabel(Text("composer.a11y.more"))
        } else {
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!canSend)
            .minimumHitTarget44()
            .accessibilityLabel(Text("composer.a11y.send"))
        }
    }

    private func loadImage(_ item: PhotosPickerItem) {
        draft.imageAttachment.load { try await photoDataLoader.load(item) }
    }

    private func attachmentStatusRow(
        label: LocalizedStringKey,
        systemImage: String?,
        isProgress: Bool,
        foreground: Color
    ) -> some View {
        HStack(spacing: 8) {
            if isProgress {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(label).font(.footnote).multilineTextAlignment(.leading)
            Spacer()
            if draft.imageAttachment.loadFailed, let photoItem = draft.photoItem {
                Button("common.retry") { loadImage(photoItem) }
                    .font(.footnote)
                    .minimumHitTarget44()
            }
            Button("composer.remove") {
                draft.imageAttachment.clear()
                draft.photoItem = nil
            }
            .font(.footnote)
            .minimumHitTarget44()
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 4)
    }

    /// 字节数格式化为 MB（保留 1 位小数，如 `1.3 MB`），用于超限提示带具体数字。
    static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    /// 模型 + 推理强度选择浮层（inline picker，一屏列出，选中带勾）。
    /// 模型列表来自服务器 model/list（env.models），含「跟随账号默认」项（override=nil）。
    private var modelSelectionContent: some View {
        ModelSelectionContent(
            selection: Binding(
                get: { draft.selection },
                set: { draft.selection = $0 }
            ),
            models: env.models,
            defaultModel: env.config?.model,
            defaultEffort: env.config?.modelReasoningEffort,
            locale: locale,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
    }

    @ViewBuilder
    private var composerShortcutLayer: some View {
        if handlesWorkspaceShortcuts {
            Group {
                Button("") { performSendShortcut() }
                    .keyboardShortcut(shortcuts.combo(for: .sendMessage).keyboardShortcut)
                Button("") {
                    guard store.state.isTurnRunning else { return }
                    Task { _ = await store.interrupt() }
                }
                .keyboardShortcut(shortcuts.combo(for: .stopTurn).keyboardShortcut)
                Button("") { inputFocused = true }
                    .keyboardShortcut(shortcuts.combo(for: .focusComposer).keyboardShortcut)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func performSendShortcut() {
        Task {
            await Self.executeSendShortcut(
                isEnabled: isEnabled,
                canSend: canSend,
                isTurnRunning: store.state.isTurnRunning,
                send: { await send() },
                enqueue: { await enqueueCurrent() }
            )
        }
    }

    static func executeSendShortcut(
        isEnabled: Bool,
        canSend: Bool,
        isTurnRunning: Bool,
        send: () async -> Void,
        enqueue: () async -> Void
    ) async {
        guard isEnabled, canSend else { return }
        if isTurnRunning { await enqueue() }
        else { await send() }
    }

    // MARK: - Enter 发送纯函数（narrow-right-panel-and-enter-send，design §2）

    /// 硬件 Return 判定（design §2a）：无组合修饰=发送；⇧/⌘/⌃/⌥ 任一=放行
    /// （⇧→系统插换行；⌘→隐形 Button keyboardShortcut 别名先吞，防御性放行）。
    /// 锁定键（alphaShift 大写锁定）非组合修饰意图，不挡发送。
    enum HardwareReturnAction: Equatable { case send, passthrough }

    static func hardwareReturnAction(modifiers: UIKeyModifierFlags) -> HardwareReturnAction {
        modifiers.intersection([.shift, .command, .control, .alternate]).isEmpty ? .send : .passthrough
    }

    /// 软键盘 Return 检测规格（design §2b）：末尾单 `\n` 追加=发送触发（剥后文本）；
    /// 粘贴多行/中间编辑/删除/IME 候选确认均为 normal。fallback b 下由
    /// `ComposerTextEditor.returnInterceptDecision`（shouldChangeTextIn）等价实现，本函数保留为行为规格。
    enum ComposerTextChange: Equatable {
        case normal
        case sendTriggered(strippedText: String)
    }

    static func classify(old: String, new: String) -> ComposerTextChange {
        guard new == old + "\n" else { return .normal }
        return .sendTriggered(strippedText: old)
    }
}

struct ModelSelectionContent: View {
    @Binding var selection: ModelSelection
    let models: [ModelSummary]
    let defaultModel: String?
    let defaultEffort: String?
    let locale: Locale
    let isAccessibilitySize: Bool
    // review P2-2：模型 popover 基线尺寸随字号缩放，避免大档裁切（ideal/max 与 accessibility 分支保留）。
    @ScaledMetric private var modelPopoverMinWidth: CGFloat = 260
    @ScaledMetric private var modelPopoverMinHeight: CGFloat = 340

    private static let efforts: [ReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh]

    var body: some View {
        List {
            Button("composer.model.reset") {
                selection = ModelSelection()
            }
            Section("composer.model") {
                Picker("composer.model", selection: $selection.modelOverride) {
                    // nil = 跟随账号默认；显示当前默认 slug 便于用户知道会用哪个。
                    Text("composer.model.default \(defaultModel ?? "—")")
                        .tag(String?.none)
                    ForEach(models, id: \.slug) { m in
                        Text(m.displayName ?? m.slug).tag(String?.some(m.slug))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("composer.effort") {
                Picker("composer.effort", selection: $selection.effortOverride) {
                    Text("composer.effort.default \(defaultEffortLabel)")
                        .tag(ReasoningEffort?.none)
                    ForEach(Self.efforts, id: \.self) { e in
                        Text(verbatim: effortLabel(e)).tag(ReasoningEffort?.some(e))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .listStyle(.insetGrouped)
        .frame(minWidth: modelPopoverMinWidth, idealWidth: 320, maxWidth: 420,
               minHeight: modelPopoverMinHeight, idealHeight: isAccessibilitySize ? 560 : 440, maxHeight: 620)
    }

    private func effortLabel(_ effort: ReasoningEffort) -> String {
        L10n.string("composer.effort.\(effort.rawValue)", locale: locale)
    }

    private var defaultEffortLabel: String {
        guard let raw = defaultEffort,
              let effort = ReasoningEffort(rawValue: raw) else { return "—" }
        return effortLabel(effort)
    }
}

private extension ComposerView {

    func effortLabel(_ effort: ReasoningEffort) -> String {
        L10n.string("composer.effort.\(effort.rawValue)", locale: locale)
    }

    var defaultEffortLabel: String {
        guard let raw = env.config?.modelReasoningEffort,
              let effort = ReasoningEffort(rawValue: raw) else { return "—" }
        return effortLabel(effort)
    }

    var modelChipLabel: String {
        let model = effectiveModel.flatMap { slug in
            env.models.first(where: { $0.slug == slug })?.displayName ?? slug
        } ?? L10n.string("composer.model.followDefault", locale: locale)
        let effort = effectiveEffort.map(effortLabel) ?? defaultEffortLabel
        return "\(model) · \(effort)"
    }

    /// 构造当前输入（文本 + 可选图片），供 send/steer/enqueue 复用。
    private func currentInput() -> [UserInput] {
        var input: [UserInput] = []
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { input.append(.text(trimmed)) }
        if let url = imageDataURL { input.append(.image(url: url, detail: .high)) }
        return input
    }

    private func clearComposer() {
        draft.clearInput()
    }

    private func send() async {
        let input = currentInput()
        guard !input.isEmpty else { return }
        // 服务器驱动：生效模型/强度（显式选择或账号默认）；都无则 nil，让服务器用其默认。
        if await store.send(input: input, model: effectiveModel, effort: effectiveEffort) {
            clearComposer()
        }
    }

    /// 转向：仅当可 steer 时清空 composer（失败保留输入，便于改走排队）。
    private func trySteer() async {
        let input = currentInput()
        guard !input.isEmpty else { return }
        let ok = await store.steer(input: input)
        if ok { clearComposer() }
    }

    /// 排队：走统一 outbox（turn 进行中时 drain 被 isTurnRunning 挡住，turn 结束后自动出队发送）。
    private func enqueueCurrent() async {
        let input = currentInput()
        guard !input.isEmpty else { return }
        if await store.send(input: input, model: effectiveModel, effort: effectiveEffort) {
            clearComposer()
        }
    }
}

extension View {
    /// D7（2.6）：保证控件命中目标 ≥44×44pt（HIG 最小可点区），并把整块矩形纳入命中测试。
    /// composer 五枚图标按钮共用——纯字号图标本身仅 ~26pt 宽，命中框不足难点按；
    /// 只扩大命中区、不改图标视觉大小/颜色（`.font`/`.foregroundStyle` 仍作用于图标本身）。
    func minimumHitTarget44() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}
