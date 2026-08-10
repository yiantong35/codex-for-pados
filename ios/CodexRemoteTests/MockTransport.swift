import Foundation
@testable import CodexRemote

/// 测试替身：记录发出的帧，并允许测试模拟服务端推帧。供 Task 8/9/10/18/19 复用。
///
/// 注意：本工程是 xcodegen 生成的 Xcode target（非 SPM module），`Bundle.module` 不可用。
/// fixture 加载用测试 bundle（`Bundle(for:)` 锚定到测试类所在 bundle），或直接 feed 字符串内容。
actor MockTransport: MessageTransport {
    private(set) var sent: [String] = []
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private nonisolated let stream: AsyncThrowingStream<String, Error>

    /// 自动应答开关（默认关）。开启后 `send` 解析发出的请求 id，自动回一条匹配的 response，
    /// 使 `rpc.send(...)` 的请求-响应调用（如 ProjectsStore.sendThenRefresh）能解挂。
    /// 默认关闭以免影响刻意保持请求挂起的测试（如 failPending / rejoin）。
    var autoRespond = false
    private var nextSendError: TransportError?

    func setAutoRespond(_ enabled: Bool) { autoRespond = enabled }
    func failNextSend(with error: TransportError) { nextSendError = error }

    /// 定制 `thread/start` 的应答体（默认 nil → 回 `{}`）。开启 autoRespond。
    /// 用于验证新建会话解析响应 `{thread:{id}}` 后切换 threadId 的逻辑。
    private var threadStartResponse: String?
    func setAutoRespondThreadStart(_ json: String) { autoRespond = true; threadStartResponse = json }

    /// 定制 `thread/list` 的应答体（默认 nil → 回空 data 数组）。
    /// 用于验证 thread/started 未知 id 触发重拉后由 ingest 归一化出现的逻辑。
    private var threadListResponse: String?
    func setThreadListResponse(_ json: String) { threadListResponse = json }
    private var loadedThreadListResponse: String?
    private var threadResumeResponse: String?
    func setLoadedThreadListResponse(_ json: String) { loadedThreadListResponse = json }
    func setThreadResumeResponse(_ json: String) { threadResumeResponse = json }

    /// 按 cursor 分页应答 `thread/list`：key 为请求携带的 cursor（首页 nil → "" ），value 为该页
    /// 完整 result JSON（含 data + nextCursor）。用于 #7 分页测试：驱动多页翻页。
    private var threadListPages: [String: String] = [:]
    func setThreadListPages(_ pages: [String: String]) { threadListPages = pages }
    private var threadListFailuresRemaining = 0
    func failNextThreadListRequests(_ count: Int) { threadListFailuresRemaining = count }

    /// thread/start 响应延迟（纳秒，默认 0）。用于测试并发防抖：首个请求延迟应答，
    /// 制造「创建进行中」窗口，验证第二次调用被拦下——且请求最终会回，测试不悬挂。
    private var threadStartDelayNanos: UInt64 = 0
    func setThreadStartDelay(_ nanos: UInt64) { threadStartDelayNanos = nanos }

    /// close() 被调用次数（断言超时/失效时在途 transport 被关闭恰好一次）。
    private(set) var closeCount = 0
    /// 握手阻塞开关（默认关）。开启后 `awaitHandshake()` 挂起直到 `close()` 被调用才抛出，
    /// 用于复现「远端接受 exec 但永不发 101 也不关流」导致 doEstablish 永久挂起的泄漏路径。
    private var blockHandshake = false
    private var closed = false
    private var handshakeWaiter: CheckedContinuation<Void, Error>?

    func setBlockHandshake(_ enabled: Bool) { blockHandshake = enabled }

    init() {
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    // MARK: MessageTransport

    func send(_ text: String) async throws {
        sent.append(text)
        if let error = nextSendError {
            nextSendError = nil
            throw error
        }
        guard autoRespond,
              let data = text.data(using: .utf8),
              case .request(let req)? = try? JSONDecoder().decode(JSONRPCMessage.self, from: data)
        else { return }
        // thread/list 回空列表（满足 loadFromServer 的 ThreadListResponse 解码）；
        // thread/start 回定制体（若设了 threadStartResponse）；其余回空对象。
        let resultJSON: String
        if req.method == RPCMethod.threadList {
            if threadListFailuresRemaining > 0 {
                threadListFailuresRemaining -= 1
                throw MockTransportError.scriptedFailure
            }
            if !threadListPages.isEmpty {
                // 按请求 cursor 选页（首页 cursor 为 nil → key ""）。
                let cursor = (req.params?.value as? [String: Any])?["cursor"] as? String ?? ""
                resultJSON = threadListPages[cursor]
                    ?? #"{"data":[],"nextCursor":null,"backwardsCursor":null}"#
            } else {
                resultJSON = threadListResponse ?? #"{"data":[],"nextCursor":null,"backwardsCursor":null}"#
            }
        } else if req.method == RPCMethod.threadLoadedList, let r = loadedThreadListResponse {
            resultJSON = r
        } else if req.method == RPCMethod.threadResume, let r = threadResumeResponse {
            resultJSON = r
        } else if req.method == RPCMethod.threadStart, let r = threadStartResponse {
            resultJSON = r
        } else {
            resultJSON = "{}"
        }
        let idJSON: String
        switch req.id {
        case .string(let s): idJSON = "\"\(s)\""
        case .int(let i): idJSON = "\(i)"
        }
        let response = #"{"id":\#(idJSON),"result":\#(resultJSON)}"#
        if req.method == RPCMethod.threadStart, threadStartDelayNanos > 0 {
            let delay = threadStartDelayNanos
            let cont = continuation
            Task { try? await Task.sleep(nanoseconds: delay); cont?.yield(response) }
        } else {
            continuation?.yield(response)
        }
    }
    nonisolated func incoming() -> AsyncThrowingStream<String, Error> { stream }

    /// 覆写协议默认空实现：blockHandshake 开启时挂起直到 close()（模拟永不到达的 101 握手）。
    func awaitHandshake() async throws {
        guard blockHandshake else { return }
        if closed { throw TransportError.channelClosed(reason: "closed before handshake") }
        try await withCheckedThrowingContinuation { cont in
            self.handshakeWaiter = cont
        }
    }

    func close() async {
        closeCount += 1
        closed = true
        continuation?.finish()
        continuation = nil
        if let w = handshakeWaiter {
            handshakeWaiter = nil
            w.resume(throwing: TransportError.channelClosed(reason: "连接主动关闭"))
        }
    }

    // MARK: 测试驱动

    /// 模拟服务端推来一条 JSON 帧。
    func feed(_ json: String) {
        continuation?.yield(json)
    }

    /// 模拟服务端连续推多条 JSON 帧。
    func feed(lines: [String]) {
        for line in lines { continuation?.yield(line) }
    }

    /// 模拟传输错误中断。
    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    /// 从 fixture 文件加载 JSON 文本并按行 feed（每行一帧，跳过空行）。
    /// 用测试 bundle 定位资源：`feedFile("name", bundle: Bundle(for: SomeTestCase.self))`。
    func feedFile(_ name: String, bundle: Bundle) throws {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw MockTransportError.fixtureNotFound(name)
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        feed(lines: lines)
    }
}

enum MockTransportError: Error, Equatable {
    case fixtureNotFound(String)
    case scriptedFailure
}
