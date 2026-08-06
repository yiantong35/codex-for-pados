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
    private let photoDataLoader: PhotoDataLoader
    // 服务器驱动的模型数据（model/list + config/read）。绝不硬编码——两种登录（账号/API）
    // 可用模型不同，daemon 已按登录返回真实数据（见 memory: pados-model-server-driven）。
    @Environment(EnvironmentStore.self) private var env

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageAttachment = ComposerImageAttachmentState()
    /// 模型/强度选择：nil override = 跟随账号默认（config），用户可显式覆盖。
    @State private var selection = ModelSelection()
    @State private var showModelPopover = false

    init(store: ConversationStore, photoDataLoader: PhotoDataLoader = .live) {
        self.store = store
        self.photoDataLoader = photoDataLoader
    }

    /// 推理强度可选项（ReasoningEffort 全部 case）。
    private static let efforts: [ReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh]

    /// 当前生效模型 slug（显式选择或账号默认），用于 UI 显示与发送。
    private var effectiveModel: String? { selection.effectiveModel(config: env.config) }
    private var effectiveEffort: ReasoningEffort? { selection.effectiveEffort(config: env.config) }
    private var imageDataURL: String? { imageAttachment.dataURL }
    private var imageError: String? {
        guard let error = imageAttachment.error else { return nil }
        return String(
            format: String(localized: "composer.image.tooLarge"),
            Self.mb(error.bytes), Self.mb(error.limit)
        )
    }

    private var canSend: Bool {
        Self.canSend(text: text, imageDataURL: imageDataURL, isImageLoading: imageAttachment.isLoading)
    }

    static func canSend(text: String, imageDataURL: String?, isImageLoading: Bool) -> Bool {
        guard !isImageLoading else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageDataURL != nil
    }

    var body: some View {
        VStack(spacing: 6) {
            if let err = store.state.lastSendError {
                // D2：发送失败显式提示，点按清错并重发上次输入（不再假"生成中"）。
                Button {
                    Task { await store.retryLastSend() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("composer.sendFailed \(err)")
                            .font(.footnote).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
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
            if imageAttachment.isLoading {
                attachmentStatusRow(
                    label: "composer.image.preparing",
                    systemImage: nil,
                    isProgress: true,
                    foreground: .secondary
                )
            } else if imageAttachment.loadFailed {
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
                        imageAttachment.clear()
                        photoItem = nil
                    }
                        .font(.footnote)
                }
            }
            HStack(spacing: 8) {
                // 次级控件用中性色（选择性用橙：只有主操作发送用主题色）。
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "plus.circle").font(.title3)
                }
                .foregroundStyle(.secondary)
                .minimumHitTarget44()
                .accessibilityLabel(Text("composer.a11y.pickImage"))
                // 模型/推理用 .popover 而非 Menu：Menu+Picker 收起时会闪现（#7），且会遮挡按钮（#8）。
                // popover 带箭头指向按钮、不遮挡，inline picker 一屏列出可选项。
                Button { showModelPopover.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                }
                .foregroundStyle(.secondary)
                .minimumHitTarget44()
                .accessibilityLabel(Text("composer.a11y.model"))
                .popover(isPresented: $showModelPopover) {
                    modelPopover.presentationCompactAdaptation(.popover)
                }

                TextField("composer.placeholder", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                if store.state.isTurnRunning {
                    // turn 进行中：提供「中断」+「转向/排队」菜单。
                    Button(role: .destructive) {
                        Task { await store.interrupt() }
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
        }
        .padding(8)
        .background(.bar)
        .onChange(of: photoItem) { _, item in
            guard let item else {
                imageAttachment.clear()
                return
            }
            loadImage(item)
        }
        .onDisappear { imageAttachment.clear() }
    }

    private func loadImage(_ item: PhotosPickerItem) {
        imageAttachment.load { try await photoDataLoader.load(item) }
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
            if imageAttachment.loadFailed, let photoItem {
                Button("common.retry") { loadImage(photoItem) }
                    .font(.footnote)
            }
            Button("composer.remove") {
                imageAttachment.clear()
                photoItem = nil
            }
            .font(.footnote)
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
    private var modelPopover: some View {
        List {
            Section("composer.model") {
                Picker("composer.model", selection: $selection.modelOverride) {
                    // nil = 跟随账号默认；显示当前默认 slug 便于用户知道会用哪个。
                    Text("composer.model.default \(env.config?.model ?? "—")")
                        .tag(String?.none)
                    ForEach(env.models, id: \.slug) { m in
                        Text(m.displayName ?? m.slug).tag(String?.some(m.slug))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("composer.effort") {
                Picker("composer.effort", selection: $selection.effortOverride) {
                    Text("composer.effort.default \(env.config?.modelReasoningEffort ?? "—")")
                        .tag(ReasoningEffort?.none)
                    ForEach(Self.efforts, id: \.self) { e in
                        Text(e.rawValue).tag(ReasoningEffort?.some(e))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .listStyle(.insetGrouped)
        .frame(width: 260, height: 380)
    }

    /// 构造当前输入（文本 + 可选图片），供 send/steer/enqueue 复用。
    private func currentInput() -> [UserInput] {
        var input: [UserInput] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { input.append(.text(trimmed)) }
        if let url = imageDataURL { input.append(.image(url: url, detail: .high)) }
        return input
    }

    private func clearComposer() {
        text = ""
        imageAttachment.clear()
        photoItem = nil
    }

    private func send() async {
        let input = currentInput()
        guard !input.isEmpty else { return }
        // 服务器驱动：生效模型/强度（显式选择或账号默认）；都无则 nil，让服务器用其默认。
        await store.send(input: input, model: effectiveModel, effort: effectiveEffort)
        clearComposer()
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
        await store.send(input: input, model: effectiveModel, effort: effectiveEffort)
        clearComposer()
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
