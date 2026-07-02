import Foundation

struct GitDiffToRemoteParams: Encodable { let cwd: String }
struct GitDiffToRemoteResponse: Decodable { let sha: String; let diff: String }
