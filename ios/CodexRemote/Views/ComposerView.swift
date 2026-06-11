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
                    Image(systemName: "photo").foregroundStyle(.blue)
                    Text("已附加图片").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("移除") { imageDataURL = nil; photoItem = nil }
                        .font(.footnote)
                }
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "plus.circle").font(.title3)
                }
                Menu {
                    Picker("模型", selection: $model) {
                        ForEach(Self.models, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("推理强度", selection: $effort) {
                        ForEach(Self.efforts, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                }

                TextField("发消息…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(!canSend)
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

    private func send() async {
        var input: [UserInput] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { input.append(.text(trimmed)) }
        if let url = imageDataURL { input.append(.image(url: url, detail: .high)) }
        guard !input.isEmpty else { return }

        await store.send(input: input, model: model, effort: effort)   // → turn/start model/effort
        text = ""
        imageDataURL = nil
        photoItem = nil
    }
}
