import SwiftUI
import Observation
import AVFoundation
import RelayProtocol

/// relay 配对导入的错误（面向用户的明确文案 key）。
enum PairingImportError: LocalizedError, Equatable {
    case empty
    case badFormat
    case expired
    case insecureScheme

    var errorDescription: String? {
        description(locale: LocaleManager.currentLocale)
    }

    func description(locale: Locale) -> String {
        switch self {
        case .empty:          return L10n.string("relayImport.error.empty", locale: locale)
        case .badFormat:      return L10n.string("relayImport.error.badFormat", locale: locale)
        case .expired:        return L10n.string("relayImport.error.expired", locale: locale)
        case .insecureScheme: return L10n.string("relayImport.error.insecureScheme", locale: locale)
        }
    }
}

/// iPad 侧粘贴导入 relay 配对载荷的 ViewModel（批次 D 末 task）。
/// 纯逻辑，`makeMachineConfig(now:)` 便于测试注入时钟；生产默认取当前时间戳。
/// 解析走 RelayProtocol.PairingPayload(parsing:)，过期走 isExpired(now:)。
@Observable
@MainActor
final class RelayPairingImportViewModel {
    var pasted: String = ""

    /// 从粘贴串解析并校验，成功返回 relay-only 的 MachineConfig + 单独的配对码。
    /// - 空/纯空白 → `.empty`
    /// - 解析失败（scheme/host/缺字段）→ `.badFormat`
    /// - 已过期 → `.expired`
    /// - `now`：当前 Unix 秒；默认取系统时间，测试可注入。
    /// pc（配对码）绝不进 MachineConfig 持久化，单独返回交调用方暂存内存 PendingPairingStore。
    func makeMachineConfig(now: Int64 = Int64(Date().timeIntervalSince1970),
                           replacing existing: MachineConfig? = nil) throws -> (config: MachineConfig, pairingCode: String) {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingImportError.empty }

        let payload: PairingPayload
        do {
            payload = try PairingPayload(parsing: text)
        } catch {
            throw PairingImportError.badFormat
        }

        guard !payload.isExpired(now: now) else { throw PairingImportError.expired }
        guard let url = URL(string: payload.relayURL) else { throw PairingImportError.badFormat }

        // 6.2：导入即校验 scheme——生产明文 ws 早报错（不等到连接时才失败）。
        do { try RelaySchemeValidator.validate(url: url) }
        catch { throw PairingImportError.insecureScheme }

        // displayName 回落到 relayURL 的 host（无则用 relayURL 原串），保证 MachineConfig 非空显示名。
        let name = url.host ?? payload.relayURL
        let config = MachineConfig(id: existing?.id ?? UUID(),
            displayName: existing?.displayName ?? (name.isEmpty ? nil : name),
            relayURL: payload.relayURL, sessionId: payload.sessionId,
            devIdentityPubB64: payload.devIdentityPubB64,
            lastActiveAt: existing?.lastActiveAt)
        return (config, payload.pairingCode)   // pc 单独返回，绝不进 MachineConfig 持久化
    }
}

/// relay 配对粘贴导入界面：粘贴框 + 粘贴/导入按钮 + 错误提示。
/// 由 MachineFormView 经 NavigationLink 进入，成功导入后回调交上层保存并 dismiss。
///
/// UI 基线（横竖屏 + 键盘）：ScrollView 包裹 + `.scrollDismissesKeyboard(.interactively)`
/// 防软键盘遮挡；表单 `maxWidth: 480` 居中，横竖屏都可用；TextEditor 走标准文本输入，
/// 外接键盘可正常输入，Esc 取消（继承 MachineFormView 工具栏的 cancelAction）。
struct RelayPairingImportView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var vm = RelayPairingImportViewModel()
    @State private var errorText: String?
    @State private var showScanner = false
    @State private var isImporting = false
    let replacingMachineID: UUID?
    private let onImported: (() -> Void)?

    init(replacingMachineID: UUID? = nil, onImported: (() -> Void)? = nil) {
        self.replacingMachineID = replacingMachineID
        self.onImported = onImported
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    VStack {
                        formContent.frame(maxWidth: 480)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(0, proxy.size.height - 48), alignment: .center)
                    .padding(24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationTitle("relayImport.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("relayImport.import") { importPairing() }
                    .disabled(isImporting || vm.pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        // 扫码用全屏，横竖屏均由 QRScannerView 自适应填满，扫码框不受表单布局挤压。
        .fullScreenCover(isPresented: $showScanner) {
            scannerSheet
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("relayImport.hint")
                .font(.footnote)
                .foregroundStyle(.secondary)

            editor

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { pairingActionButtons; Spacer() }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { pairingActionButtons }
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var pairingActionButtons: some View {
        Button { beginScan() } label: {
            Label("relayImport.scan", systemImage: "qrcode.viewfinder").font(.callout)
        }
        .minimumHitTarget44()

        Button {
            if let s = UIPasteboard.general.string {
                vm.pasted = s
                errorText = nil
            }
        } label: {
            Label("relayImport.paste", systemImage: "doc.on.clipboard").font(.callout)
        }
        .minimumHitTarget44()
    }

    /// 扫码全屏：相机预览铺满 + 顶部提示 + 取消按钮；扫到即写 vm.pasted 并走既有导入。
    private var scannerSheet: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            QRScannerView { scanned in
                showScanner = false
                vm.pasted = scanned
                errorText = nil
                importPairing()
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        showScanner = false
                    } label: {
                        Label("common.cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                    }
                    Spacer()
                }
                Text("relayImport.scan.hint")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.4), in: Capsule())
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
    }

    /// 多行粘贴框：TextEditor（配对串较长），带占位提示 + 圆角描边。
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if vm.pasted.isEmpty {
                Text("relayImport.placeholder")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $vm.pasted)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(height: 140)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityLabel(Text("relayImport.placeholder"))
                .onChange(of: vm.pasted) { errorText = nil }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
    }

    /// 扫码入口：先判相机可用性，再按授权状态处理；任何失败都回退手动粘贴（不阻断配对）。
    private func beginScan() {
        errorText = nil
        // 相机不可用（模拟器 / 无摄像头设备）→ 提示 + 保留手动粘贴，不 present 扫码。
        guard AVCaptureDevice.default(for: .video) != nil else {
            errorText = L10n.string("relayImport.error.cameraUnavailable", locale: locale)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        showScanner = true
                    } else {
                        errorText = L10n.string("relayImport.error.cameraDenied", locale: locale)
                    }
                }
            }
        default:
            // denied / restricted → 明确提示前往设置或手动粘贴，手动入口始终可用。
            errorText = L10n.string("relayImport.error.cameraDenied", locale: locale)
        }
    }

    /// 解析导入：成功交 addMachineAndConnect（切过去 + 连接），失败展示明确文案。
    private func importPairing() {
        guard !isImporting else { return }
        isImporting = true
        Task { await performImportPairing() }
    }

    private func performImportPairing() async {
        defer { isImporting = false }
        do {
            let existing = replacingMachineID.flatMap { id in
                sessions.machineStore.machines.first { $0.id == id }
            }
            let (m, pc) = try vm.makeMachineConfig(replacing: existing)
            let result: SessionsManager.DestructiveResult
            if existing != nil {
                result = await sessions.replaceMachineAndConnect(m, pairingCode: pc)
            } else if sessions.machineStore.canAddMore {
                PendingPairingStore.shared.stash(pc, for: m.id)
                result = sessions.addMachineAndConnect(m) ? .completed : .failed
            } else {
                result = .failed
            }
            switch result {
            case .completed:
                if let onImported { onImported() } else { dismiss() }
            case .interruptFailed(let ids):
                errorText = String.localizedStringWithFormat(
                    L10n.string("sideChat.cleanupFailed %@", locale: locale),
                    ids.joined(separator: ", ")
                )
            case .failed:
                errorText = L10n.string("relayImport.error.saveFailed", locale: locale)
            }
        } catch {
            errorText = (error as? PairingImportError)?.description(locale: locale)
                ?? L10n.string("relayImport.error.badFormat", locale: locale)
        }
    }
}
