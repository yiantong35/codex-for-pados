import Foundation

/// fail-closed 信任列表：记住已配对 iPad 的 Ed25519 身份公钥 + 每台各自的稳定 sessionId。
/// 文件存在但不可读/损坏时显式报错、绝不静默用空列表覆盖（延续 DevKeyStore 语义）。
public final class TrustStore {
    public enum TrustStoreError: Error, Equatable {
        case unreadableTrustFile(String)
        case corruptedTrustFile(String)
    }
    public struct Record: Codable, Sendable, Equatable {
        public var ipadPubB64: String
        public var stableSessionId: String
        public var addedAt: Int64
        public var label: String?
    }

    private let fileURL: URL
    private var records: [Record]

    public init(dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        self.fileURL = dir.appendingPathComponent("trusted-ipads.json")
        if fm.fileExists(atPath: fileURL.path) {
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch { throw TrustStoreError.unreadableTrustFile(fileURL.path) }
            guard let recs = try? JSONDecoder().decode([Record].self, from: data) else {
                throw TrustStoreError.corruptedTrustFile(fileURL.path)
            }
            self.records = recs
        } else {
            self.records = []
        }
    }

    public func record(forPubB64 pub: String) -> Record? { records.first { $0.ipadPubB64 == pub } }
    public func all() -> [Record] { records }

    public func trust(ipadPubB64 pub: String, stableSessionId sid: String, label: String?) throws {
        if let idx = records.firstIndex(where: { $0.ipadPubB64 == pub }) {
            records[idx].stableSessionId = sid
            if let label { records[idx].label = label }
        } else {
            records.append(Record(ipadPubB64: pub, stableSessionId: sid,
                                  addedAt: Int64(Date().timeIntervalSince1970), label: label))
        }
        try persist()
    }
    public func revoke(ipadPubB64 pub: String) throws { records.removeAll { $0.ipadPubB64 == pub }; try persist() }
    public func clearAll() throws { records.removeAll(); try persist() }

    /// 以 0600 权限原子写入信任列表。
    private func persist() throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
