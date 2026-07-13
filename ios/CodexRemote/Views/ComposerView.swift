import SwiftUI
import PhotosUI

/// 底部 composer（设计 §3）：多行文本 + 图片附件（PhotosPicker）+ 模型/推理强度选择器 + 发送。
/// 图片选取后转 base64 data URL 作 `UserInput.image`（v2 协议 image 走内联 url）。
/// 模型/推理映射到 `ConversationStore.send(input:model:effort:)` → `turn/start` 的 `model`/`effort`。
/// 中途控制（turn 进行中 steer/排队/interrupt）在 Task 17 实现，本视图只做基础发送。
struct ComposerView: View {
    let store: ConversationStore
    // 服务器驱动的模型数据（model/list + config/read）。绝不硬编码——两种登录（账号/API）
    // 可用模型不同，daemon 已按登录返回真实数据（见 memory: pados-model-server-driven）。
    @Environment(EnvironmentStore.self) private var env

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageDataURL: String?
    /// 模型/强度选择：nil override = 跟随账号默认（config），用户可显式覆盖。
    @State private var selection = ModelSelection()
    @State private var showModelPopover = false

    /// 推理强度可选项（ReasoningEffort 全部 case）。
    private static let efforts: [ReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh]

    /// 当前生效模型 slug（显式选择或账号默认），用于 UI 显示与发送。
    private var effectiveModel: String? { selection.effectiveModel(config: env.config) }
    private var effectiveEffort: ReasoningEffort? { selection.effectiveEffort(config: env.config) }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageDataURL != nil
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
            if imageDataURL != nil {
                HStack(spacing: 6) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text("composer.imageAttached").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("composer.remove") { imageDataURL = nil; photoItem = nil }
                        .font(.footnote)
                }
            }
            HStack(spacing: 8) {
                // 次级控件用中性色（选择性用橙：只有主操作发送用主题色）。
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "plus.circle").font(.title3)
                }
                .foregroundStyle(.secondary)
                // 模型/推理用 .popover 而非 Menu：Menu+Picker 收起时会闪现（#7），且会遮挡按钮（#8）。
                // popover 带箭头指向按钮、不遮挡，inline picker 一屏列出可选项。
                Button { showModelPopover.toggle() } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                }
                .foregroundStyle(.secondary)
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
                    Menu {
                        Button("composer.steer") { Task { await trySteer() } }
                            .disabled(store.state.activeTurnKind != nil)
                        Button("composer.enqueue") { enqueueCurrent() }
                        if let kind = store.state.activeTurnKind {
                            Text("composer.noSteer \(kind.rawValue)")
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(!canSend)
                } else {
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(8)
        .background(.bar)
        .onChange(of: photoItem) { _, item in
            Task {
                guard let item,
                      let data = try? await item.loadTransferable(type: Data.self) else { return }
                imageDataURL = "data:image/jpeg;base64," + data.base64EncodedString()
            }
        }
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
        imageDataURL = nil
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

    /// 排队：turn 结束后由 store 自动出队发送。
    private func enqueueCurrent() {
        let input = currentInput()
        guard !input.isEmpty else { return }
        store.enqueue(input: input)
        clearComposer()
    }
}
