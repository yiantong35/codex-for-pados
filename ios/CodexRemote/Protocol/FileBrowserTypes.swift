import Foundation

// fs/* 只读方法的 Codable 类型。协议形状来自 app-server ClientRequest.ts。
// 注意：readDirectory 与 getMetadata 均无 size 字段。

// MARK: fs/readDirectory
struct FsReadDirectoryParams: Encodable { let path: String }
struct FsReadDirectoryEntry: Decodable {
    let fileName: String
    let isDirectory: Bool
    let isFile: Bool
}
struct FsReadDirectoryResponse: Decodable { let entries: [FsReadDirectoryEntry] }

// MARK: fs/readFile
struct FsReadFileParams: Encodable { let path: String }
struct FsReadFileResponse: Decodable { let dataBase64: String }

// MARK: fs/getMetadata（本 change 未直接消费，先备类型；无 size）
struct FsGetMetadataParams: Encodable { let path: String }
struct FsGetMetadataResponse: Decodable {
    let isDirectory: Bool
    let isFile: Bool
    let isSymlink: Bool
    let createdAtMs: Int
    let modifiedAtMs: Int
}
