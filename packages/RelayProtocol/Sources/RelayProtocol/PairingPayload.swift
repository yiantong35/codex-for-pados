import Foundation
import Crypto

public enum PairingError: Error, Equatable { case badFormat, missingField(String) }

/// 手动配对载荷：codexrelay://pair?relay=&sid=&pk=&pc=&exp=
public struct PairingPayload: Codable, Sendable, Equatable {
    public static let maximumEncodedBytes = 8 * 1024
    public static let maximumRelayURLBytes = 2 * 1024
    public static let maximumSessionIDBytes = 256
    public static let maximumPairingCodeBytes = 512

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
        guard !s.isEmpty, s.utf8.count <= Self.maximumEncodedBytes else {
            throw PairingError.badFormat
        }
        guard let c = URLComponents(string: s), c.scheme == "codexrelay", c.host == "pair"
        else { throw PairingError.badFormat }
        func q(_ n: String, maximumBytes: Int) throws -> String {
            let matches = c.queryItems?.filter { $0.name == n } ?? []
            guard matches.count == 1, let v = matches[0].value else {
                throw PairingError.missingField(n)
            }
            guard !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  v.utf8.count <= maximumBytes,
                  !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw PairingError.badFormat }
            return v
        }

        relayURL = try q("relay", maximumBytes: Self.maximumRelayURLBytes)
        sessionId = try q("sid", maximumBytes: Self.maximumSessionIDBytes)
        devIdentityPubB64 = try q("pk", maximumBytes: 128)
        pairingCode = try q("pc", maximumBytes: Self.maximumPairingCodeBytes)
        let expiration = try q("exp", maximumBytes: 20)
        guard let exp = Int64(expiration) else { throw PairingError.badFormat }
        expiresAt = exp

        guard let relay = URLComponents(string: relayURL),
              relay.scheme == "ws" || relay.scheme == "wss",
              let host = relay.host, !host.isEmpty,
              let identity = Data(base64Encoded: devIdentityPubB64), identity.count == 32,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: identity)) != nil
        else { throw PairingError.badFormat }
    }
}
