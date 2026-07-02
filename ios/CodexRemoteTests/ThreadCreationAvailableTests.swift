import XCTest
@testable import CodexRemote

@MainActor
final class ThreadCreationAvailableTests: XCTestCase {
    /// 反转 follower 的「禁发起」守护：iPad 作为对等客户端，建会话能力必须可用。
    /// 防止「恢复入口」被未来改动悄悄删回从端定位。
    func testSourceHasThreadCreationSymbols() throws {
        let root = URL(fileURLWithPath: #filePath)        // .../ios/CodexRemoteTests/ThreadCreationAvailableTests.swift
            .deletingLastPathComponent()                  // CodexRemoteTests
            .deletingLastPathComponent()                  // ios
        let conv = try String(contentsOf: root.appendingPathComponent("CodexRemote/Stores/ConversationStore.swift"), encoding: .utf8)
        XCTAssertTrue(conv.contains("func start("), "ConversationStore.start() 应已恢复")
        XCTAssertTrue(conv.contains("func fork("), "ConversationStore.fork() 应已新增")
        XCTAssertTrue(conv.contains("threadStart"), "应引用 RPCMethod.threadStart")
        let types = try String(contentsOf: root.appendingPathComponent("CodexRemote/Protocol/ThreadTypes.swift"), encoding: .utf8)
        XCTAssertTrue(types.contains("ThreadStartParams"), "ThreadStartParams 应已恢复")
        XCTAssertTrue(types.contains("ThreadForkParams"), "ThreadForkParams 应已新增")
    }
}
