enum RPCMethod {
    static let initialize = "initialize"
    static let initialized = "initialized"      // notification
    static let threadList = "thread/list"
    static let threadResume = "thread/resume"
    static let threadStart = "thread/start"
    static let turnStart = "turn/start"
    static let turnSteer = "turn/steer"
    static let turnInterrupt = "turn/interrupt"
    static let modelList = "model/list"
}

enum ServerRequestMethod {
    static let cmdApprovalV2 = "item/commandExecution/requestApproval"
    static let fileApprovalV2 = "item/fileChange/requestApproval"
    static let permsApprovalV2 = "item/permissions/requestApproval"
    static let execApprovalLegacy = "execCommandApproval"
    static let applyPatchApprovalLegacy = "applyPatchApproval"
}

enum ServerNotificationMethod {
    static let itemStarted = "item/started"
    static let itemCompleted = "item/completed"
    static let agentMessageDelta = "item/agentMessage/delta"
    static let commandOutputDelta = "item/commandExecution/outputDelta"
    // 思考/推理流式增量（字段扁平 itemId/delta，见 protocol/ts/v2/Reasoning*Notification.ts）。
    static let reasoningTextDelta = "item/reasoning/textDelta"
    static let reasoningSummaryTextDelta = "item/reasoning/summaryTextDelta"
    static let reasoningSummaryPartAdded = "item/reasoning/summaryPartAdded"
    static let fileChangePatchUpdated = "item/fileChange/patchUpdated"
    static let turnStarted = "turn/started"
    static let turnCompleted = "turn/completed"
    static let statusChanged = "thread/status/changed"
    static let turnDiffUpdated = "turn/diff/updated"
    static let turnPlanUpdated = "turn/plan/updated"
    static let threadStarted = "thread/started"
    static let serverRequestResolved = "serverRequest/resolved"
    static let error = "error"
    static let warning = "warning"
}
