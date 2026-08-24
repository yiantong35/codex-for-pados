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
    @Environment(\.openURL) private var openURL
    @Environment(TextScaleManager.self) private var textScale

    @State private var vm = RelayPairingImportViewModel()
    @State private var errorText: String?
    @State private var showScanner = false
    @State private var isImporting = false
    @State private var cameraAccessDenied = false
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
        // 本视图经 .sheet 呈现，拥有独立 hosting controller，不继承根部注入的字号钳制
        // （对象型环境能穿透 sheet，trait 型的 dynamicTypeSize 不能）。故自读 textScale 再施加，
        // 让设置页的字号设置也能控制本弹窗（与 SettingsPageView 同款绕过）。
        .modifier(AppDynamicTypeSizeModifier(size: textScale.overrideSize))
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("relayImport.hint")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)   // 多语言/多行不截断

            editor

            // 扫码 / 粘贴：一左一右两个等宽按钮；窄屏或超大字号放不下时回退为上下堆叠（仍等宽）。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { pairingActionButtons }
                VStack(spacing: 8) { pairingActionButtons }
            }

            // 报错放在按钮下方：出现/消失只在底部增删，不再把按钮相对编辑器顶下去。
            // 字号与顶部说明一致（同为默认 body，随 AppDynamicTypeSizeModifier 一起缩放），
            // 并允许多语言下多行换行。
            if let errorText {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if cameraAccessDenied,
                       let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        Button {
                            openURL(settingsURL)
                        } label: {
                            Label("relayImport.openSettings", systemImage: "gear")
                        }
                        .buttonStyle(StablePairingButtonStyle())
                        .minimumHitTarget44()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var pairingActionButtons: some View {
        Button { beginScan() } label: {
            Label("relayImport.scan", systemImage: "qrcode.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(StablePairingButtonStyle())
        .minimumHitTarget44()

        Button {
            if let s = UIPasteboard.general.string {
                vm.pasted = s
                errorText = nil
                cameraAccessDenied = false
            }
        } label: {
            Label("relayImport.paste", systemImage: "doc.on.clipboard")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(StablePairingButtonStyle())
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
                cameraAccessDenied = false
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
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $vm.pasted)
                .font(.system(.body, design: .monospaced))
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
        cameraAccessDenied = false
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
                        cameraAccessDenied = true
                    }
                }
            }
        default:
            // denied / restricted → 明确提示前往设置或手动粘贴，手动入口始终可用。
            errorText = L10n.string("relayImport.error.cameraDenied", locale: locale)
            cameraAccessDenied = true
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

/// 配对按钮的固定填充底色：一个只随深浅色（userInterfaceStyle）变的**实心**动态色。
///
/// 背景：RelayPairingImportView 经 `.sheet` 呈现，「扫码/粘贴」按钮此前用 `.buttonStyle(.bordered)`。
/// 系统 `.bordered` 的灰底是一层**材质（material/vibrancy）**，需与背板合成后才成灰；呈现首帧材质尚未
/// 合成完 → 显白，下一帧合成后才转灰，即用户看到的「先白后灰」（与 AppearanceManagers 里记录的分组框
/// late-blit 首帧晚绘同源）。改用**实心 fill** 后无材质合成、首帧即终态，天然无此中间态；落定外观仍是
/// 原本的浅灰底 + 强调色文字。抽为 internal 便于复用与检视。
enum PairingButtonAppearance {
    static let stableFillColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.12)
            : UIColor(white: 0.0, alpha: 0.06)
    }
}

/// 与系统 `.bordered` 视觉等价，但填充用上面的固定实心色，落定后外观仍是原本的浅灰底 + 强调色文字。
private struct StablePairingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(PairingButtonAppearance.stableFillColor))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.55 : 1.0)
    }
}
