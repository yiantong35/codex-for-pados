import SwiftUI
import PhotosUI

/// 底部 composer（设计 §3）：多行文本 + 图片附件（PhotosPicker）+ 模型/推理强度选择器 + 发送。
/// 图片选取后转 base64 data URL 作 `UserInput.image`（v2 协议 image 走内联 url）。
/// 模型/推理映射到 `ConversationStore.send(input:model:effort:)` → `turn/start` 的 `model`/`effort`。
/// 中途控制（turn 进行中 steer/排队/interrupt）在 Task 17 实现，本视图只做基础发送。
struct ComposerView: View {
    let store: ConversationStore

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var imageDataURL: String?
    @State private var model = "gpt-5-codex"
    @State private var effort: ReasoningEffort = .medium

    /// 可选模型（MVP 硬编码常见名；后续可改为从 thread 元信息拉取）。
    private static let models = ["gpt-5", "gpt-5-codex", "gpt-5-mini"]
    /// 推理强度可选项（ReasoningEffort 全部 case）。
    private static let efforts: [ReasoningEffort] = [.none, .minimal, .low, .medium, .high, .xhigh]

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageDataURL != nil
    }

    var body: some View {
        VStack(spacing: 6) {
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
                Menu {
                    Picker("composer.model", selection: $model) {
                        ForEach(Self.models, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("composer.effort", selection: $effort) {
                        ForEach(Self.efforts, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                }
                .foregroundStyle(.secondary)

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
        await store.send(input: input, model: model, effort: effort)   // → turn/start model/effort
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
