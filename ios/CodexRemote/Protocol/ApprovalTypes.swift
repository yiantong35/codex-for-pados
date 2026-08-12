import Foundation

// ===== v2 命令执行审批 decision(取自 CommandExecutionRequestApprovalResponse.json)=====
enum CommandExecutionApprovalDecision: Codable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(execpolicyAmendment: [String])
    case decline
    case cancel

    private enum AmendKeys: String, CodingKey { case acceptWithExecpolicyAmendment }
    private enum InnerKeys: String, CodingKey { case execpolicy_amendment }
    func encode(to e: Encoder) throws {
        switch self {
        case .accept: var c = e.singleValueContainer(); try c.encode("accept")
        case .acceptForSession: var c = e.singleValueContainer(); try c.encode("acceptForSession")
        case .decline: var c = e.singleValueContainer(); try c.encode("decline")
        case .cancel: var c = e.singleValueContainer(); try c.encode("cancel")
        case .acceptWithExecpolicyAmendment(let amend):
            var outer = e.container(keyedBy: AmendKeys.self)
            var inner = outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .acceptWithExecpolicyAmendment)
            try inner.encode(amend, forKey: .execpolicy_amendment)
        }
    }
    init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) {
            switch s {
            case "accept": self = .accept
            case "acceptForSession": self = .acceptForSession
            case "decline": self = .decline
            case "cancel": self = .cancel
            default: self = .decline
            }
            return
        }
        let outer = try d.container(keyedBy: AmendKeys.self)
        let inner = try outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .acceptWithExecpolicyAmendment)
        self = .acceptWithExecpolicyAmendment(
            execpolicyAmendment: try inner.decode([String].self, forKey: .execpolicy_amendment))
    }
}

struct CommandExecutionApprovalResponse: Codable {
    let decision: CommandExecutionApprovalDecision
}

// ===== v2 文件改动审批 decision(取自 FileChangeRequestApprovalResponse.json)=====
enum FileChangeApprovalDecision: String, Codable {
    case accept, acceptForSession, decline, cancel
}
struct FileChangeApprovalResponse: Codable { let decision: FileChangeApprovalDecision }

// ===== legacy ReviewDecision(取自 ReviewDecision.ts)=====
enum ReviewDecision: Codable {
    case approved
    case approvedExecpolicyAmendment(proposed: [String])
    case approvedForSession
    case denied
    case abort

    private enum AmendKeys: String, CodingKey { case approved_execpolicy_amendment }
    private enum InnerKeys: String, CodingKey { case proposed_execpolicy_amendment }
    func encode(to e: Encoder) throws {
        switch self {
        case .approved: var c = e.singleValueContainer(); try c.encode("approved")
        case .approvedForSession: var c = e.singleValueContainer(); try c.encode("approved_for_session")
        case .denied: var c = e.singleValueContainer(); try c.encode("denied")
        case .abort: var c = e.singleValueContainer(); try c.encode("abort")
        case .approvedExecpolicyAmendment(let p):
            var outer = e.container(keyedBy: AmendKeys.self)
            var inner = outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .approved_execpolicy_amendment)
            try inner.encode(p, forKey: .proposed_execpolicy_amendment)
        }
    }
    init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) {
            switch s {
            case "approved": self = .approved
            case "approved_for_session": self = .approvedForSession
            case "denied": self = .denied
            case "abort", "timed_out": self = .abort
            default: self = .denied
            }
            return
        }
        let outer = try d.container(keyedBy: AmendKeys.self)
        let inner = try outer.nestedContainer(keyedBy: InnerKeys.self,
                                              forKey: .approved_execpolicy_amendment)
        self = .approvedExecpolicyAmendment(
            proposed: try inner.decode([String].self, forKey: .proposed_execpolicy_amendment))
    }
}
struct ExecCommandApprovalResponse: Codable { let decision: ReviewDecision }

// ===== 审批请求参数（严格对齐当前生成 schema）=====
enum NetworkApprovalProtocol: String, Codable, Equatable {
    case http, https, socks5Tcp, socks5Udp
}

struct NetworkApprovalContext: Codable, Equatable {
    let host: String
    let `protocol`: NetworkApprovalProtocol
}

enum NetworkPolicyRuleAction: String, Codable, Equatable {
    case allow, deny
}

struct NetworkPolicyAmendment: Codable, Equatable {
    let host: String
    let action: NetworkPolicyRuleAction
}

struct CommandExecutionApprovalParams: Codable {
    let threadId: String
    let turnId: String
    let itemId: String
    let startedAtMs: Int64
    let approvalId: String?
    let command: String?
    let commandActions: [AnyCodable]?
    let cwd: String?
    let reason: String?
    let networkApprovalContext: NetworkApprovalContext?
    let proposedExecpolicyAmendment: [String]?
    let proposedNetworkPolicyAmendments: [NetworkPolicyAmendment]?
}

struct FileChangeApprovalParams: Codable {
    let threadId: String
    let turnId: String
    let itemId: String
    let startedAtMs: Int64
    let reason: String?
    let grantRoot: String?
}

// ===== F4：v2 权限审批（item/permissions/requestApproval）=====
// 对齐 protocol/ts/v2：AdditionalNetworkPermissions / AdditionalFileSystemPermissions /
// GrantedPermissionProfile / RequestPermissionProfile / PermissionGrantScope /
// PermissionsRequestApprovalResponse / PermissionsRequestApprovalParams（MVP 子集）。

struct AdditionalNetworkPermissions: Codable, Equatable {
    let enabled: Bool?
}

struct AdditionalFileSystemPermissions: Codable, Equatable {
    let entries: [FileSystemSandboxEntry]?
    let globScanMaxDepth: UInt?
    let read: [String]?
    let write: [String]?

    init(entries: [FileSystemSandboxEntry]? = nil, globScanMaxDepth: UInt? = nil,
         read: [String]? = nil, write: [String]? = nil) {
        self.entries = entries
        self.globScanMaxDepth = globScanMaxDepth
        self.read = read
        self.write = write
    }
}

enum FileSystemAccessMode: String, Codable, Equatable {
    case read, write, deny
}

enum FileSystemPath: Codable, Equatable {
    case path(String)
    case globPattern(String)
    case special(FileSystemSpecialPath)

    var displayValue: String {
        switch self {
        case .path(let value), .globPattern(let value): value
        case .special(let value): value.displayValue
        }
    }

    private enum CodingKeys: String, CodingKey { case type, path, pattern, value }
    private enum Kind: String, Codable { case path, globPattern = "glob_pattern", special }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .path: self = .path(try container.decode(String.self, forKey: .path))
        case .globPattern: self = .globPattern(try container.decode(String.self, forKey: .pattern))
        case .special: self = .special(try container.decode(FileSystemSpecialPath.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .path(let value):
            try container.encode(Kind.path, forKey: .type)
            try container.encode(value, forKey: .path)
        case .globPattern(let value):
            try container.encode(Kind.globPattern, forKey: .type)
            try container.encode(value, forKey: .pattern)
        case .special(let value):
            try container.encode(Kind.special, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

struct FileSystemSpecialPath: Codable, Equatable {
    let kind: String
    let path: String?
    let subpath: String?

    var displayValue: String {
        [kind, path, subpath].compactMap { $0 }.joined(separator: ":")
    }
}

struct FileSystemSandboxEntry: Codable, Equatable {
    let access: FileSystemAccessMode
    let path: FileSystemPath
}

enum PermissionRequestLimits {
    static let maximumEntries = 256
    static let maximumPathBytes = 4 * 1_024
}

/// 授予档案（对齐 GrantedPermissionProfile.ts：network?/fileSystem? 均可选）。
struct GrantedPermissionProfile: Codable, Equatable {
    let network: AdditionalNetworkPermissions?
    let fileSystem: AdditionalFileSystemPermissions?
}

/// 请求档案（对齐 RequestPermissionProfile.ts：network/fileSystem 可为 null）。
struct RequestPermissionProfile: Codable, Equatable {
    let network: AdditionalNetworkPermissions?
    let fileSystem: AdditionalFileSystemPermissions?
}

/// 授权范围（对齐 PermissionGrantScope.ts："turn" | "session"）。
enum PermissionGrantScope: String, Codable, Equatable {
    case turn
    case session
}

/// 权限审批响应（对齐 PermissionsRequestApprovalResponse.ts）：
/// MUST 含 permissions + scope；MUST NOT 误用命令执行审批的 { decision }。
struct PermissionsRequestApprovalResponse: Codable {
    let permissions: GrantedPermissionProfile
    let scope: PermissionGrantScope
    let strictAutoReview: Bool?
}

/// 权限审批请求参数子集（对齐 PermissionsRequestApprovalParams.ts）：解析知情要素。
struct PermissionsRequestApprovalParams: Codable {
    let threadId: String
    let turnId: String
    let itemId: String
    let startedAtMs: Int64
    let reason: String?
    let permissions: RequestPermissionProfile
    let cwd: String
    let environmentId: String?
}

struct ExecCommandApprovalParams: Codable {
    let conversationId: String
    let callId: String
    let approvalId: String?
    let command: [String]
    let cwd: String
    let parsedCmd: [AnyCodable]
    let reason: String?
}

struct ApplyPatchApprovalParams: Codable {
    let conversationId: String
    let callId: String
    let fileChanges: [String: AnyCodable]
    let grantRoot: String?
    let reason: String?
}

enum ApprovalRequestPayload {
    case command(CommandExecutionApprovalParams)
    case file(FileChangeApprovalParams)
    case permissions(PermissionsRequestApprovalParams)
    case legacyCommand(ExecCommandApprovalParams)
    case legacyPatch(ApplyPatchApprovalParams)
}

enum ApprovalRequestDecoder {
    static func decode(_ request: JSONRPCRequest) throws -> ApprovalRequestPayload {
        guard let params = request.params else { throw ApprovalProtocolError.invalidParams }
        let data = try JSONEncoder().encode(params)
        do {
            switch request.method {
            case ServerRequestMethod.cmdApprovalV2:
                return .command(try JSONDecoder().decode(CommandExecutionApprovalParams.self, from: data))
            case ServerRequestMethod.fileApprovalV2:
                return .file(try JSONDecoder().decode(FileChangeApprovalParams.self, from: data))
            case ServerRequestMethod.permsApprovalV2:
                let params = try JSONDecoder().decode(PermissionsRequestApprovalParams.self, from: data)
                guard validate(params.permissions) else { throw ApprovalProtocolError.invalidParams }
                return .permissions(params)
            case ServerRequestMethod.execApprovalLegacy:
                return .legacyCommand(try JSONDecoder().decode(ExecCommandApprovalParams.self, from: data))
            case ServerRequestMethod.applyPatchApprovalLegacy:
                return .legacyPatch(try JSONDecoder().decode(ApplyPatchApprovalParams.self, from: data))
            default:
                throw ApprovalProtocolError.unsupportedMethod
            }
        } catch let error as ApprovalProtocolError {
            throw error
        } catch {
            throw ApprovalProtocolError.decodingFailed(String(describing: error))
        }
    }

    private static func validate(_ profile: RequestPermissionProfile) -> Bool {
        guard let fileSystem = profile.fileSystem else { return true }
        let legacy = (fileSystem.read ?? []) + (fileSystem.write ?? [])
        if let entries = fileSystem.entries {
            guard entries.count + legacy.count <= PermissionRequestLimits.maximumEntries,
                  entries.allSatisfy({ $0.path.displayValue.utf8.count <= PermissionRequestLimits.maximumPathBytes })
            else { return false }
        } else if legacy.count > PermissionRequestLimits.maximumEntries {
            return false
        }
        return legacy.allSatisfy { $0.utf8.count <= PermissionRequestLimits.maximumPathBytes }
    }
}

enum ApprovalProtocolError: Error, Equatable {
    case invalidParams
    case unsupportedMethod
    case decodingFailed(String)
}
