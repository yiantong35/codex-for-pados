import Foundation

@MainActor
final class UserInputCoordinator {
    let store: UserInputStore
    private var requestTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private let recoveryTimeoutNanos: UInt64

    init(store: UserInputStore, recoveryTimeoutNanos: UInt64 = 2_000_000_000) {
        self.store = store
        self.recoveryTimeoutNanos = recoveryTimeoutNanos
    }

    func bind(rpc: JSONRPCClient) async {
        store.resolver = { id, response in
            do {
                let data = try JSONEncoder().encode(response)
                let result = try JSONDecoder().decode(AnyCodable.self, from: data)
                return try await rpc.respond(to: id, result: result)
            } catch {
                return false
            }
        }

        let requests = await rpc.serverRequests(for: .userInput)
        let notifications = await rpc.notifications(methods: [ServerNotificationMethod.serverRequestResolved])
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            for await request in requests {
                guard let self else { return }
                do {
                    try self.store.handle(request: request)
                } catch {
                    _ = try? await rpc.respond(
                        to: request.id,
                        error: JSONRPCErrorBody(code: -32602, message: "Invalid request_user_input params")
                    )
                }
            }
        }

        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            for await notification in notifications {
                guard let self,
                      notification.method == ServerNotificationMethod.serverRequestResolved,
                      let params = notification.params?.value as? [String: Any],
                      let requestId = Self.requestId(from: params["requestId"])
                else { continue }
                await rpc.discardServerRequest(requestId)
                self.store.handleServerRequestResolved(requestId)
            }
        }
        recoveryTask?.cancel()
        if store.hasAwaitingRecovery {
            recoveryTask = Task { [weak self, recoveryTimeoutNanos] in
                do { try await Task.sleep(nanoseconds: recoveryTimeoutNanos) }
                catch { return }
                self?.store.expireAwaitingRecovery()
            }
        }
    }

    func connectionLost() {
        recoveryTask?.cancel()
        recoveryTask = nil
        store.handleConnectionLost()
    }

    private static func requestId(from value: Any?) -> RequestId? {
        if let string = value as? String { return .string(string) }
        if let integer = value as? Int64 { return .int(integer) }
        if let integer = value as? Int { return .int(Int64(integer)) }
        return nil
    }
}
