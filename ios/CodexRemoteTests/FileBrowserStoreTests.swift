import Testing
import Foundation
@testable import CodexRemote

@MainActor
struct FileBrowserStoreTests {

    private func makeStore() async -> (MockTransport, JSONRPCClient, FileBrowserStore) {
        let mock = MockTransport()
        let rpc = JSONRPCClient(transport: mock)
        await rpc.start()
        let store = FileBrowserStore()
        store.attach(rpc: rpc)
        return (mock, rpc, store)
    }

    private func respond(_ mock: MockTransport, to method: String, resultJSON: String) -> Task<Void, Never> {
        Task {
            var answered = Set<String>()
            for _ in 0..<400 {
                if Task.isCancelled { return }
                let sent = await mock.sent
                for frame in sent {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                          let id = obj["id"] as? String,
                          obj["method"] as? String == method,
                          !answered.contains(id) else { continue }
                    answered.insert(id)
                    await mock.feed(#"{"jsonrpc":"2.0","id":"\#(id)","result":\#(resultJSON)}"#)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    private func count(_ mock: MockTransport, method: String) async -> Int {
        let sent = await mock.sent
        return sent.filter {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["method"] as? String == method
        }.count
    }

    private func requestID(_ mock: MockTransport, method: String, path: String) async -> String? {
        for _ in 0..<200 {
            let sent = await mock.sent
            for frame in sent {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any],
                      obj["method"] as? String == method,
                      let params = obj["params"] as? [String: Any],
                      params["path"] as? String == path
                else { continue }
                return obj["id"] as? String
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    @Test func noCwdIsEmptyAndSendsNothing() async {
        let (mock, _, store) = await makeStore()
        await store.setRoot(nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.isEmpty == true)
        #expect(await count(mock, method: RPCMethod.fsReadDirectory) == 0)
    }

    @Test func setRootFetchesRootOnce() async {
        let (mock, _, store) = await makeStore()
        let responder = respond(mock, to: RPCMethod.fsReadDirectory,
            resultJSON: #"{"entries":[{"fileName":"src","isDirectory":true,"isFile":false}]}"#)
        await store.setRoot("/repo")
        try? await Task.sleep(nanoseconds: 100_000_000)
        responder.cancel()
        #expect(store.isEmpty == false)
        #expect(store.nodes["/repo"]?.entries?.count == 1)
        #expect(await count(mock, method: RPCMethod.fsReadDirectory) == 1)
    }

    @Test func settingSameRootPreservesBrowserState() async {
        let (mock, _, store) = await makeStore()
        let responder = respond(mock, to: RPCMethod.fsReadDirectory,
            resultJSON: #"{"entries":[{"fileName":"src","isDirectory":true,"isFile":false}]}"#)
        await store.setRoot("/repo")
        await store.setRoot("/repo")
        try? await Task.sleep(nanoseconds: 50_000_000)
        responder.cancel()
        #expect(await count(mock, method: RPCMethod.fsReadDirectory) == 1)
        #expect(store.nodes["/repo"]?.entries?.count == 1)
    }

    @Test func expandLoadedDirReusesCache() async {
        let (mock, _, store) = await makeStore()
        let responder = respond(mock, to: RPCMethod.fsReadDirectory,
            resultJSON: #"{"entries":[{"fileName":"a.txt","isDirectory":false,"isFile":true}]}"#)
        await store.setRoot("/repo")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await store.toggleExpand("/repo") // collapse
        await store.toggleExpand("/repo") // expand（复用缓存）
        try? await Task.sleep(nanoseconds: 50_000_000)
        responder.cancel()
        #expect(await count(mock, method: RPCMethod.fsReadDirectory) == 1)
    }

    @Test func refreshClearsAndRefetches() async {
        let (mock, _, store) = await makeStore()
        let responder = respond(mock, to: RPCMethod.fsReadDirectory,
            resultJSON: #"{"entries":[{"fileName":"src","isDirectory":true,"isFile":false}]}"#)
        await store.setRoot("/repo")
        try? await Task.sleep(nanoseconds: 100_000_000)
        await store.refresh()
        try? await Task.sleep(nanoseconds: 100_000_000)
        responder.cancel()
        #expect(await count(mock, method: RPCMethod.fsReadDirectory) == 2)
        #expect(store.nodes["/repo"]?.entries?.count == 1)
    }

    @Test func openTextFileClassifiesText() async {
        let (mock, _, store) = await makeStore()
        let responder = respond(mock, to: RPCMethod.fsReadFile, resultJSON: #"{"dataBase64":"aGk="}"#)
        await store.openFile("/repo/a.txt")
        responder.cancel()
        #expect(store.selectedFile?.path == "/repo/a.txt")
        #expect(store.selectedFile?.content == .text("hi"))
    }

    @Test func openBinaryFileClassifiesBinary() async {
        let (mock, _, store) = await makeStore()
        let responder = respond(mock, to: RPCMethod.fsReadFile, resultJSON: #"{"dataBase64":"AA=="}"#)
        await store.openFile("/repo/blob.bin")
        responder.cancel()
        #expect(store.selectedFile?.content == .binary(Data([0])))
    }

    @Test func readFailureHasRetryableFailedState() async {
        let (mock, _, store) = await makeStore()
        let responder = respond(mock, to: RPCMethod.fsReadFile, resultJSON: #"{}"#)
        await store.openFile("/repo/missing.txt")
        responder.cancel()
        #expect(store.fileOpenState == .failed("/repo/missing.txt"))
        #expect(store.selectedFile == nil)
    }

    @Test func lateResponseFromPreviousSelectionCannotReplaceCurrentFile() async {
        let (mock, _, store) = await makeStore()
        let first = Task { await store.openFile("/repo/a.txt") }
        guard let firstID = await requestID(mock, method: RPCMethod.fsReadFile, path: "/repo/a.txt") else {
            Issue.record("first file request was not sent")
            first.cancel()
            return
        }

        let second = Task { await store.openFile("/repo/b.txt") }
        guard let secondID = await requestID(mock, method: RPCMethod.fsReadFile, path: "/repo/b.txt") else {
            Issue.record("second file request was not sent")
            first.cancel(); second.cancel()
            return
        }

        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(secondID)","result":{"dataBase64":"Qg=="}}"#)
        await second.value
        await mock.feed(#"{"jsonrpc":"2.0","id":"\#(firstID)","result":{"dataBase64":"QQ=="}}"#)
        await first.value

        #expect(store.selectedFile?.path == "/repo/b.txt")
        #expect(store.selectedFile?.content == .text("B"))
    }
}
