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

// ===== 审批请求参数(取自 CommandExecutionRequestApprovalParams.json 等，MVP 子集)=====
struct CommandExecutionApprovalParams: Codable {
    let threadId: String
    let turnId: String
    let itemId: String
    let approvalId: String?
    let command: String?
    let cwd: String?
    let proposedExecpolicyAmendment: [String]?
}

struct FileChangeApprovalParams: Codable {
    let threadId: String
    let turnId: String?
    let itemId: String?
    // 文件改动明细：MVP 用 AnyCodable 承载 patch/diff，Task 18 渲染时取所需字段
    let changes: AnyCodable?
}
