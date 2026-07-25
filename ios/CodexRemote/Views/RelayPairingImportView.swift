import SwiftUI
import Observation
import AVFoundation
import RelayProtocol

/// relay 配对导入的错误（面向用户的明确文案 key）。
enum PairingImportError: LocalizedError, Equatable {
    case empty
    case badFormat
    case expired

    var errorDescription: String? {
        switch self {
        case .empty:     return String(localized: "relayImport.error.empty")
        case .badFormat: return String(localized: "relayImport.error.badFormat")
        case .expired:   return String(localized: "relayImport.error.expired")
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

    /// 从粘贴串解析并校验，成功返回 `.relay(pairing:)` 的 MachineConfig。
    /// - 空/纯空白 → `.empty`
    /// - 解析失败（scheme/host/缺字段）→ `.badFormat`
    /// - 已过期 → `.expired`
    /// - `now`：当前 Unix 秒；默认取系统时间，测试可注入。
    func makeMachineConfig(now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> MachineConfig {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PairingImportError.empty }

        let payload: PairingPayload
        do {
            payload = try PairingPayload(parsing: text)
        } catch {
            throw PairingImportError.badFormat
        }

        guard !payload.isExpired(now: now) else { throw PairingImportError.expired }

        // displayName 回落到 relayURL 的 host（无则用 relayURL 原串），保证 MachineConfig 非空显示名。
        let name = URL(string: payload.relayURL)?.host ?? payload.relayURL
        return MachineConfig(displayName: name.isEmpty ? nil : name,
                             connection: .relay(pairing: text))
    }
}

/// relay 配对粘贴导入界面：粘贴框 + 粘贴/导入按钮 + 错误提示。
/// 由 MachineFormView 经 NavigationLink 进入，成功导入后回调交上层保存并 dismiss。
///
/// UI 基线（横竖屏 + 键盘）：ScrollView 包裹 + `.scrollDismissesKeyboard(.interactively)`
/// 防软键盘遮挡；卡片 `maxWidth: 480` 居中，横竖屏都可用；TextEditor 走标准文本输入，
/// 外接键盘可正常输入，Esc 取消（继承 MachineFormView 工具栏的 cancelAction）。
struct RelayPairingImportView: View {
    @Environment(SessionsManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    @State private var vm = RelayPairingImportViewModel()
    @State private var errorText: String?
    @State private var showScanner = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                card
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("relayImport.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("relayImport.import") { importPairing() }
                    .disabled(vm.pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        // 扫码用全屏，横竖屏均由 QRScannerView 自适应填满，扫码框不受表单布局挤压。
        .fullScreenCover(isPresented: $showScanner) {
            scannerSheet
        }
    }

    private var card: some View {
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

            HStack(spacing: 16) {
                // 扫码入口：请求相机权限；授权则 present 扫码，拒绝/不可用则回退手动粘贴（不阻断）。
                Button {
                    beginScan()
                } label: {
                    Label("relayImport.scan", systemImage: "qrcode.viewfinder")
                        .font(.callout)
                }

                Button {
                    if let s = UIPasteboard.general.string {
                        vm.pasted = s
                        errorText = nil
                    }
                } label: {
                    Label("relayImport.paste", systemImage: "doc.on.clipboard")
                        .font(.callout)
                }
                Spacer()
            }
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
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
            }
            TextEditor(text: $vm.pasted)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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
            errorText = String(localized: "relayImport.error.cameraUnavailable")
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
                        errorText = String(localized: "relayImport.error.cameraDenied")
                    }
                }
            }
        default:
            // denied / restricted → 明确提示前往设置或手动粘贴，手动入口始终可用。
            errorText = String(localized: "relayImport.error.cameraDenied")
        }
    }

    /// 解析导入：成功交 addMachineAndConnect（切过去 + 连接），失败展示明确文案。
    private func importPairing() {
        do {
            let m = try vm.makeMachineConfig()
            if sessions.addMachineAndConnect(m) {
                dismiss()
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "relayImport.error.badFormat")
        }
    }
}
