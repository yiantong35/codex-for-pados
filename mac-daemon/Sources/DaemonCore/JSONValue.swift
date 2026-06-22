import Foundation

/// 不透明 JSON 载体:原样承载任意 JSON,保证 round-trip 语义保真。
///
/// daemon 不解析 app-server 内部结构;`event`/`request` 帧的 payload
/// 用本类型透传。数字区分整型(`int`/`uint`)与浮点(`double`),
/// 避免大整数(超出 Double 53 位精度)被破坏。
public enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case bool(Bool)
    case null
}

extension JSONValue {
    /// 从 JSON 文本解析。
    public init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }

    /// 从 JSON 字节解析。
    public init(parsing data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = try JSONValue(foundation: obj)
    }

    /// 编码为 JSON 字节(单行,键序由 JSONSerialization 决定)。
    public func encode() throws -> Data {
        let obj = foundationObject
        if JSONSerialization.isValidJSONObject(obj) {
            return try JSONSerialization.data(withJSONObject: obj, options: [])
        }
        // 顶层为标量(string/number/bool/null)时需 fragmentsAllowed。
        return try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
    }

    // MARK: - Foundation 互转

    init(foundation value: Any) throws {
        switch value {
        case let dict as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = try JSONValue(foundation: v)
            }
            self = .object(out)
        case let arr as [Any]:
            self = .array(try arr.map { try JSONValue(foundation: $0) })
        case let num as NSNumber:
            self = JSONValue(number: num)
        case let str as String:
            self = .string(str)
        case is NSNull:
            self = .null
        default:
            throw EnvelopeError.invalidPayload
        }
    }

    /// NSNumber 在 JSONSerialization 下需区分 bool / 整型 / 浮点。
    private init(number: NSNumber) {
        // CFBoolean 的 objCType 为 "c";用此判定真布尔。
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }
        let type = String(cString: number.objCType)
        switch type {
        case "f", "d":
            self = .double(number.doubleValue)
        default:
            // 整型:优先 Int64,溢出(大正数)则 UInt64。
            let i = number.int64Value
            if NSNumber(value: i) == number {
                self = .int(i)
            } else {
                self = .uint(number.uint64Value)
            }
        }
    }

    var foundationObject: Any {
        switch self {
        case let .object(dict):
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict { out[k] = v.foundationObject }
            return out
        case let .array(arr):
            return arr.map { $0.foundationObject }
        case let .string(s):
            return s
        case let .int(i):
            return NSNumber(value: i)
        case let .uint(u):
            return NSNumber(value: u)
        case let .double(d):
            return NSNumber(value: d)
        case let .bool(b):
            return NSNumber(value: b)
        case .null:
            return NSNull()
        }
    }
}

// MARK: - Codable:透传嵌入 Envelope

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let u = try? c.decode(UInt64.self) {
            self = .uint(u)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .object(o): try c.encode(o)
        case let .array(a): try c.encode(a)
        case let .string(s): try c.encode(s)
        case let .int(i): try c.encode(i)
        case let .uint(u): try c.encode(u)
        case let .double(d): try c.encode(d)
        case let .bool(b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}
