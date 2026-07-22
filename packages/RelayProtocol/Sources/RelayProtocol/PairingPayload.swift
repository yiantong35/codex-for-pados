import Foundation

public enum PairingError: Error, Equatable { case badFormat, missingField(String) }

/// 手动配对载荷：codexrelay://pair?relay=&sid=&pk=&pc=&exp=
public struct PairingPayload: Codable, Sendable, Equatable {
    public var relayURL: String
    public var sessionId: String
    public var devIdentityPubB64: String
    public var pairingCode: String
    public var expiresAt: Int64

    public init(relayURL: String, sessionId: String, devIdentityPubB64: String,
                pairingCode: String, expiresAt: Int64) {
        self.relayURL = relayURL; self.sessionId = sessionId
        self.devIdentityPubB64 = devIdentityPubB64; self.pairingCode = pairingCode
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Int64) -> Bool { now >= expiresAt }

    public func toURLString() -> String {
        var c = URLComponents()
        c.scheme = "codexrelay"; c.host = "pair"
        c.queryItems = [
            .init(name: "relay", value: relayURL),
            .init(name: "sid", value: sessionId),
            .init(name: "pk", value: devIdentityPubB64),
            .init(name: "pc", value: pairingCode),
            .init(name: "exp", value: String(expiresAt)),
        ]
        return c.string ?? ""
    }

    public init(parsing s: String) throws {
        guard let c = URLComponents(string: s), c.scheme == "codexrelay", c.host == "pair"
        else { throw PairingError.badFormat }
        func q(_ n: String) throws -> String {
            guard let v = c.queryItems?.first(where: { $0.name == n })?.value else {
                throw PairingError.missingField(n)
            }
            return v
        }
        relayURL = try q("relay"); sessionId = try q("sid")
        devIdentityPubB64 = try q("pk"); pairingCode = try q("pc")
        guard let exp = Int64(try q("exp")) else { throw PairingError.missingField("exp") }
        expiresAt = exp
    }
}
