enum RPCMethod {
    static let initialize = "initialize"
    static let initialized = "initialized"      // notification
    static let threadList = "thread/list"
    static let threadLoadedList = "thread/loaded/list"  // 当前 app-server 内存中运行的 thread ids
    static let threadResume = "thread/resume"
    static let threadStart = "thread/start"
    static let threadFork = "thread/fork"
    static let threadArchive = "thread/archive"
    static let threadUnarchive = "thread/unarchive"
    static let threadDelete = "thread/delete"
    static let threadNameSet = "thread/name/set"
    static let threadRollback = "thread/rollback"
    static let threadCompactStart = "thread/compact/start"
    static let threadGoalSet = "thread/goal/set"
    static let threadGoalGet = "thread/goal/get"
    static let threadGoalClear = "thread/goal/clear"
    static let turnStart = "turn/start"
    static let turnSteer = "turn/steer"
    static let turnInterrupt = "turn/interrupt"
    static let modelList = "model/list"
    static let accountRead = "account/read"
    static let accountUsageRead = "account/usage/read"
    static let accountRateLimitsRead = "account/rateLimits/read"
    static let configRead = "config/read"
    static let configValueWrite = "config/value/write"
    static let commandExec = "command/exec"
    static let commandExecWrite = "command/exec/write"
    static let commandExecResize = "command/exec/resize"
    static let commandExecTerminate = "command/exec/terminate"
    static let gitDiffToRemote = "gitDiffToRemote"
    static let reviewStart = "review/start"
    static let fsReadDirectory = "fs/readDirectory"
    static let fsReadFile = "fs/readFile"
    static let fsGetMetadata = "fs/getMetadata"
    static let getAuthStatus = "getAuthStatus"
    static let mcpServerStatusList = "mcpServerStatus/list"
    static let mcpServerReload = "config/mcpServer/reload"
    static let skillsList = "skills/list"
    static let skillsConfigWrite = "skills/config/write"
    static let pluginList = "plugin/list"
    static let pluginRead = "plugin/read"
    static let pluginSkillRead = "plugin/skill/read"
    static let hooksList = "hooks/list"
}

enum ServerRequestMethod {
    static let cmdApprovalV2 = "item/commandExecution/requestApproval"
    static let fileApprovalV2 = "item/fileChange/requestApproval"
    static let userInput = "item/tool/requestUserInput"
    static let mcpElicitation = "mcpServer/elicitation/request"
    static let permsApprovalV2 = "item/permissions/requestApproval"
    static let dynamicToolCall = "item/tool/call"
    static let authTokensRefresh = "account/chatgptAuthTokens/refresh"
    static let attestationGenerate = "attestation/generate"
    static let execApprovalLegacy = "execCommandApproval"
    static let applyPatchApprovalLegacy = "applyPatchApproval"

    /// Mirrors protocol/schema/ServerRequest.json. Keep the router test exhaustive
    /// so a regenerated method cannot silently become an unanswered request.
    static let generatedMethods = [
        cmdApprovalV2, fileApprovalV2, userInput, mcpElicitation,
        permsApprovalV2, dynamicToolCall, authTokensRefresh,
        attestationGenerate, applyPatchApprovalLegacy, execApprovalLegacy,
    ]
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
    static let turnDiffUpdated = "turn/diff/updated"
    static let turnPlanUpdated = "turn/plan/updated"
    static let threadStarted = "thread/started"
    static let threadArchived = "thread/archived"
    static let threadUnarchived = "thread/unarchived"
    static let threadDeleted = "thread/deleted"
    static let threadNameUpdated = "thread/name/updated"
    static let threadGoalUpdated = "thread/goal/updated"
    static let threadGoalCleared = "thread/goal/cleared"
    static let threadStatusChanged = "thread/status/changed"
    static let accountUpdated = "account/updated"
    static let accountRateLimitsUpdated = "account/rateLimits/updated"
    static let commandExecOutputDelta = "command/exec/outputDelta"
    static let serverRequestResolved = "serverRequest/resolved"
    static let error = "error"
    static let warning = "warning"
    // 线格式 method 为小写斜杠式（对齐现有 account/updated）；schema 定义名 McpServerStatusUpdatedNotification
    // 只是类型名，真实 wire method = "mcpServer/startupStatus/updated"（核实自 ServerNotification.json）。
    static let mcpServerStatusUpdated = "mcpServer/startupStatus/updated"
    // 本地 skill 文件变更失效信号（无 payload，收到即重拉 skills/list）。
    // 真实 wire method = "skills/changed"（核实自 ServerNotification.json；非 schema 定义名 SkillsChangedNotification）。
    static let skillsChanged = "skills/changed"
}
