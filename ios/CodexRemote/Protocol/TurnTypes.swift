import Foundation

enum ImageDetail: String, Codable { case high, original }

// 取自 v2/UserInput.ts：text | image | localImage | skill | mention
enum UserInput: Codable {
    case text(String)
    case image(url: String, detail: ImageDetail?)
    case localImage(path: String, detail: ImageDetail?)

    private enum Keys: String, CodingKey { case type, text, text_elements, url, detail, path }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
            try c.encode([String](), forKey: .text_elements)   // 必填，空数组
        case .image(let url, let d):
            try c.encode("image", forKey: .type)
            try c.encode(url, forKey: .url)
            try c.encodeIfPresent(d, forKey: .detail)
        case .localImage(let path, let d):
            try c.encode("localImage", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(d, forKey: .detail)
        }
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "image": self = .image(url: try c.decode(String.self, forKey: .url),
                                    detail: try c.decodeIfPresent(ImageDetail.self, forKey: .detail))
        case "localImage": self = .localImage(path: try c.decode(String.self, forKey: .path),
                                    detail: try c.decodeIfPresent(ImageDetail.self, forKey: .detail))
        default: self = .text("")
        }
    }
}

struct TurnStartParams: Codable {
    let threadId: String
    let input: [UserInput]
    var model: String?
    var effort: ReasoningEffort?        // 注意 v2 字段名是 effort，非 reasoningEffort
    var cwd: String?
}

struct TurnSteerParams: Codable {
    let threadId: String
    let input: [UserInput]
    let expectedTurnId: String
}

struct TurnInterruptParams: Codable {
    let threadId: String
}

enum NonSteerableTurnKind: String, Codable { case review, compact }
