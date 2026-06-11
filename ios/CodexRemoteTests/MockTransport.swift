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

    init() {
        var cont: AsyncThrowingStream<String, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    // MARK: MessageTransport

    func send(_ text: String) async throws { sent.append(text) }
    nonisolated func incoming() -> AsyncThrowingStream<String, Error> { stream }
    func close() async {
        continuation?.finish()
        continuation = nil
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
}
