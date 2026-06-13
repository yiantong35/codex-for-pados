import Foundation

struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any
    init(_ v: Any) { value = v }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int64.self) { value = i }
        else if let dbl = try? c.decode(Double.self) { value = dbl }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: AnyCodable].self) {
            value = o.mapValues(\.value)
        } else { value = NSNull() }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int64: try c.encode(i)
        case let i as Int: try c.encode(Int64(i))
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}
