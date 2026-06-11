import Foundation

struct ClientInfo: Codable {
    let name: String
    let title: String?
    let version: String
}

struct InitializeParams: Codable {
    let clientInfo: ClientInfo
    let capabilities: AnyCodable?   // InitializeCapabilities | null
}

struct InitializeResponse: Codable {
    let userAgent: String
    let codexHome: String          // AbsolutePathBuf
    let platformFamily: String
    let platformOs: String
}
