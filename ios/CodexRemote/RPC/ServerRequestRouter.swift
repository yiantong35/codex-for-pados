import Foundation

enum ServerRequestOwner: Sendable, Hashable {
    case approval
    case userInput
    case mcpElicitation
}

enum ServerRequestOutcome: Sendable, Equatable {
    case deferred(ServerRequestOwner)
    case methodNotSupported
}

enum ServerRequestRouter {
    static func outcome(for method: String) -> ServerRequestOutcome {
        switch method {
        case ServerRequestMethod.cmdApprovalV2,
             ServerRequestMethod.fileApprovalV2,
             ServerRequestMethod.permsApprovalV2,
             ServerRequestMethod.execApprovalLegacy,
             ServerRequestMethod.applyPatchApprovalLegacy:
            return .deferred(.approval)
        case ServerRequestMethod.userInput:
            return .deferred(.userInput)
        case ServerRequestMethod.mcpElicitation:
            return .deferred(.mcpElicitation)
        case ServerRequestMethod.dynamicToolCall,
             ServerRequestMethod.authTokensRefresh,
             ServerRequestMethod.attestationGenerate:
            return .methodNotSupported
        default:
            return .methodNotSupported
        }
    }
}
