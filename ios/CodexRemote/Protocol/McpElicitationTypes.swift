import Foundation

enum McpElicitationLimits {
    static let maximumFields = 24
    static let maximumOptionsPerField = 32
    static let maximumIdentifierBytes = 128
    static let maximumTitleBytes = 256
    static let maximumDescriptionBytes = 1_024
    static let maximumMessageBytes = 4_096
    static let maximumURLBytes = 4_096
    static let maximumInputBytes = 4_096
}

enum McpServerElicitationAction: String, Codable, Sendable, Equatable {
    case accept
    case decline
    case cancel
}

struct McpServerElicitationRequestResponse: Encodable, Sendable {
    let action: McpServerElicitationAction
    let content: AnyCodable?
    let meta: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case action, content
        case meta = "_meta"
    }
}

struct McpFormOption: Sendable, Equatable, Identifiable {
    let value: String
    let title: String
    var id: String { value }
}

enum McpFormFieldKind: Sendable, Equatable {
    case string(format: String?, minLength: Int?, maxLength: Int?)
    case number(integer: Bool, minimum: Double?, maximum: Double?)
    case boolean
    case single([McpFormOption])
    case multiple([McpFormOption], minItems: Int?, maxItems: Int?)
}

struct McpFormField: Sendable, Identifiable {
    let name: String
    let title: String
    let description: String?
    let required: Bool
    let kind: McpFormFieldKind
    let defaultValue: AnyCodable?
    var id: String { name }
}

enum McpElicitationMode: Sendable {
    case url(URL, String)
    case form([McpFormField])

}

enum McpFormDraft: Sendable, Equatable {
    case text(String)
    case boolean(Bool)
    case multiple(Set<String>)
    case unset
}

struct McpElicitationCard: Identifiable, Sendable {
    let id: RequestId
    let threadId: String
    let turnId: String?
    let serverName: String
    let message: String
    let mode: McpElicitationMode
    let meta: AnyCodable?
    var awaitingRecovery = false

    init(request: JSONRPCRequest) throws {
        guard request.method == ServerRequestMethod.mcpElicitation,
              let params = request.params?.value as? [String: Any],
              let threadId = params["threadId"] as? String,
              let serverName = params["serverName"] as? String,
              let message = params["message"] as? String,
              let modeName = params["mode"] as? String,
              Self.validString(threadId, maximumBytes: McpElicitationLimits.maximumIdentifierBytes),
              Self.validString(serverName, maximumBytes: McpElicitationLimits.maximumTitleBytes),
              Self.validString(message, maximumBytes: McpElicitationLimits.maximumMessageBytes),
              (params["turnId"] as? String).map({
                  Self.validString($0, maximumBytes: McpElicitationLimits.maximumIdentifierBytes)
              }) ?? true
        else { throw McpElicitationError.invalidRequest }

        id = request.id
        self.threadId = threadId
        turnId = params["turnId"] as? String
        self.serverName = serverName
        self.message = message
        meta = params["_meta"].flatMap { $0 is NSNull ? nil : AnyCodable($0) }

        switch modeName {
        case "url":
            guard let rawURL = params["url"] as? String,
                  Self.validString(rawURL, maximumBytes: McpElicitationLimits.maximumURLBytes),
                  let url = URL(string: rawURL),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let elicitationId = params["elicitationId"] as? String,
                  Self.validString(elicitationId, maximumBytes: McpElicitationLimits.maximumIdentifierBytes)
            else { throw McpElicitationError.invalidURL }
            mode = .url(url, elicitationId)
        case "form":
            mode = .form(try Self.parseForm(params["requestedSchema"]))
        default:
            throw McpElicitationError.unsupportedMode(modeName)
        }
    }

    func response(action: McpServerElicitationAction) -> McpServerElicitationRequestResponse {
        .init(action: action, content: nil, meta: nil)
    }

    func accept(drafts: [String: McpFormDraft]) throws -> McpServerElicitationRequestResponse {
        guard case .form(let fields) = mode else { return response(action: .accept) }
        var content: [String: Any] = [:]
        for field in fields {
            guard let value = try Self.value(for: field, draft: drafts[field.name]) else { continue }
            content[field.name] = value
        }
        return .init(action: .accept, content: AnyCodable(content), meta: nil)
    }

    func isSubmittable(drafts: [String: McpFormDraft]) -> Bool {
        (try? accept(drafts: drafts)) != nil
    }

    func validationErrors(drafts: [String: McpFormDraft]) -> [String: McpElicitationError] {
        guard case .form(let fields) = mode else { return [:] }
        return fields.reduce(into: [:]) { errors, field in
            do {
                _ = try Self.value(for: field, draft: drafts[field.name])
            } catch let error as McpElicitationError {
                errors[field.name] = error
            } catch {
                errors[field.name] = .invalidValue(field.name)
            }
        }
    }

    func defaultDrafts() -> [String: McpFormDraft] {
        guard case .form(let fields) = mode else { return [:] }
        return Dictionary(uniqueKeysWithValues: fields.map { field in
            let value = field.defaultValue?.value
            let draft: McpFormDraft
            switch field.kind {
            case .boolean:
                if let value = value as? Bool { draft = .boolean(value) }
                else { draft = field.required ? .boolean(false) : .unset }
            case .multiple:
                if let value = value as? [String] { draft = .multiple(Set(value)) }
                else { draft = field.required ? .multiple([]) : .unset }
            default:
                if let string = value as? String { draft = .text(string) }
                else if let number = value as? NSNumber { draft = .text(number.stringValue) }
                else { draft = .unset }
            }
            return (field.name, draft)
        })
    }

    private static func parseForm(_ raw: Any?) throws -> [McpFormField] {
        guard let schema = raw as? [String: Any], schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String: Any],
              properties.count <= McpElicitationLimits.maximumFields
        else { throw McpElicitationError.invalidSchema("Form schema must be an object") }
        let requiredNames = schema["required"] as? [String] ?? []
        guard requiredNames.count <= McpElicitationLimits.maximumFields,
              Set(requiredNames).count == requiredNames.count,
              requiredNames.allSatisfy({
                  validString($0, maximumBytes: McpElicitationLimits.maximumIdentifierBytes)
              }) else {
            throw McpElicitationError.invalidSchema("Invalid required fields")
        }
        let required = Set(requiredNames)
        guard required.isSubset(of: Set(properties.keys)) else {
            throw McpElicitationError.invalidSchema("Required field is missing from properties")
        }
        return try properties.keys.sorted().map { name in
            guard validString(name, maximumBytes: McpElicitationLimits.maximumIdentifierBytes),
                  let node = properties[name] as? [String: Any], let type = node["type"] as? String else {
                throw McpElicitationError.invalidSchema(name)
            }
            let title = node["title"] as? String ?? name
            let description = node["description"] as? String
            guard validString(title, maximumBytes: McpElicitationLimits.maximumTitleBytes),
                  description.map({ validString($0, maximumBytes: McpElicitationLimits.maximumDescriptionBytes,
                                                 allowEmpty: true) }) ?? true
            else { throw McpElicitationError.invalidSchema(name) }
            let kind: McpFormFieldKind
            switch type {
            case "string":
                if node["oneOf"] != nil || node["enum"] != nil {
                    kind = .single(try parseOptions(node, field: name))
                } else {
                    let format = node["format"] as? String
                    if let format, !["email", "uri", "date", "date-time"].contains(format) {
                        throw McpElicitationError.invalidSchema(name)
                    }
                    let minimum = int(node["minLength"])
                    let maximum = int(node["maxLength"])
                    guard validBounds(minimum: minimum, maximum: maximum,
                                      upperBound: McpElicitationLimits.maximumInputBytes) else {
                        throw McpElicitationError.invalidSchema(name)
                    }
                    kind = .string(format: format, minLength: minimum, maxLength: maximum)
                }
            case "integer":
                let minimum = double(node["minimum"]), maximum = double(node["maximum"])
                guard validNumberBounds(minimum: minimum, maximum: maximum) else {
                    throw McpElicitationError.invalidSchema(name)
                }
                kind = .number(integer: true, minimum: minimum, maximum: maximum)
            case "number":
                let minimum = double(node["minimum"]), maximum = double(node["maximum"])
                guard validNumberBounds(minimum: minimum, maximum: maximum) else {
                    throw McpElicitationError.invalidSchema(name)
                }
                kind = .number(integer: false, minimum: minimum, maximum: maximum)
            case "boolean":
                kind = .boolean
            case "array":
                guard let items = node["items"] as? [String: Any] else {
                    throw McpElicitationError.invalidSchema(name)
                }
                let options = try parseArrayOptions(items, field: name)
                let minimum = int(node["minItems"]), maximum = int(node["maxItems"])
                guard validBounds(minimum: minimum, maximum: maximum, upperBound: options.count) else {
                    throw McpElicitationError.invalidSchema(name)
                }
                kind = .multiple(options, minItems: minimum, maxItems: maximum)
            default:
                throw McpElicitationError.unsupportedSchema(name)
            }
            guard validDefault(node["default"], kind: kind) else {
                throw McpElicitationError.invalidSchema(name)
            }
            return McpFormField(name: name, title: title, description: description,
                                required: required.contains(name), kind: kind,
                                defaultValue: node["default"].map(AnyCodable.init))
        }
    }

    private static func parseOptions(_ node: [String: Any], field: String) throws -> [McpFormOption] {
        if let entries = node["oneOf"] as? [[String: Any]] {
            guard entries.count <= McpElicitationLimits.maximumOptionsPerField else {
                throw McpElicitationError.invalidSchema(field)
            }
            let options = try entries.map { entry -> McpFormOption in
                guard let value = entry["const"] as? String else { throw McpElicitationError.invalidSchema(field) }
                return try validatedOption(value: value, title: entry["title"] as? String ?? value, field: field)
            }
            guard validOptions(options) else { throw McpElicitationError.invalidSchema(field) }
            return options
        }
        guard let values = node["enum"] as? [String], !values.isEmpty,
              values.count <= McpElicitationLimits.maximumOptionsPerField else {
            throw McpElicitationError.invalidSchema(field)
        }
        let names = node["enumNames"] as? [String]
        guard names == nil || names?.count == values.count else { throw McpElicitationError.invalidSchema(field) }
        let options = try values.enumerated().map {
            try validatedOption(value: $0.element, title: names?[$0.offset] ?? $0.element, field: field)
        }
        guard validOptions(options) else { throw McpElicitationError.invalidSchema(field) }
        return options
    }

    private static func parseArrayOptions(_ items: [String: Any], field: String) throws -> [McpFormOption] {
        guard items["type"] as? String == "string" || items["anyOf"] != nil else {
            throw McpElicitationError.unsupportedSchema(field)
        }
        if let entries = items["anyOf"] as? [[String: Any]] {
            guard entries.count <= McpElicitationLimits.maximumOptionsPerField else {
                throw McpElicitationError.invalidSchema(field)
            }
            let options = try entries.map { entry -> McpFormOption in
                guard let value = entry["const"] as? String else { throw McpElicitationError.invalidSchema(field) }
                return try validatedOption(value: value, title: entry["title"] as? String ?? value, field: field)
            }
            guard validOptions(options) else { throw McpElicitationError.invalidSchema(field) }
            return options
        }
        return try parseOptions(items, field: field)
    }

    private static func value(for field: McpFormField, draft: McpFormDraft?) throws -> Any? {
        if draft == nil || draft == .unset {
            if field.required { throw McpElicitationError.missingValue(field.name) }
            return nil
        }
        switch (field.kind, draft) {
        case let (.string(format, minLength, maxLength), .text(raw)):
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if field.required && value.isEmpty { throw McpElicitationError.missingValue(field.name) }
            if !field.required && value.isEmpty { return nil }
            guard minLength.map({ value.count >= $0 }) ?? true,
                  maxLength.map({ value.count <= $0 }) ?? true,
                  value.utf8.count <= McpElicitationLimits.maximumInputBytes,
                  valid(value, format: format)
            else { throw McpElicitationError.invalidValue(field.name) }
            return value
        case let (.number(integer, minimum, maximum), .text(raw)):
            guard let value = Double(raw), value.isFinite,
                  minimum.map({ value >= $0 }) ?? true,
                  maximum.map({ value <= $0 }) ?? true
            else { throw McpElicitationError.invalidValue(field.name) }
            if integer {
                guard value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) else {
                    throw McpElicitationError.invalidValue(field.name)
                }
                return Int(value)
            }
            return value
        case let (.boolean, .boolean(value)):
            return value
        case let (.single(options), .text(value)):
            guard options.contains(where: { $0.value == value }) else { throw McpElicitationError.invalidValue(field.name) }
            return value
        case let (.multiple(options, minItems, maxItems), .multiple(selected)):
            guard selected.isSubset(of: Set(options.map(\.value))),
                  minItems.map({ selected.count >= $0 }) ?? true,
                  maxItems.map({ selected.count <= $0 }) ?? true,
                  !field.required || !selected.isEmpty
            else { throw McpElicitationError.invalidValue(field.name) }
            return options.compactMap { selected.contains($0.value) ? $0.value : nil }
        default:
            throw McpElicitationError.invalidValue(field.name)
        }
    }

    private static func valid(_ value: String, format: String?) -> Bool {
        switch format {
        case nil: true
        case "email": value.contains("@") && !value.hasPrefix("@") && !value.hasSuffix("@")
        case "uri": URL(string: value)?.scheme != nil
        case "date": ISO8601DateFormatter().date(from: value + "T00:00:00Z") != nil
        case "date-time": ISO8601DateFormatter().date(from: value) != nil
        default: false
        }
    }

    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    private static func validString(_ value: String, maximumBytes: Int, allowEmpty: Bool = false) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= maximumBytes
    }

    private static func validBounds(minimum: Int?, maximum: Int?, upperBound: Int) -> Bool {
        guard minimum.map({ $0 >= 0 && $0 <= upperBound }) ?? true,
              maximum.map({ $0 >= 0 && $0 <= upperBound }) ?? true else { return false }
        return minimum == nil || maximum == nil || minimum! <= maximum!
    }

    private static func validNumberBounds(minimum: Double?, maximum: Double?) -> Bool {
        guard minimum.map(\.isFinite) ?? true, maximum.map(\.isFinite) ?? true else { return false }
        return minimum == nil || maximum == nil || minimum! <= maximum!
    }

    private static func validatedOption(value: String, title: String,
                                        field: String) throws -> McpFormOption {
        guard validString(value, maximumBytes: McpElicitationLimits.maximumIdentifierBytes),
              validString(title, maximumBytes: McpElicitationLimits.maximumTitleBytes) else {
            throw McpElicitationError.invalidSchema(field)
        }
        return .init(value: value, title: title)
    }

    private static func validOptions(_ options: [McpFormOption]) -> Bool {
        !options.isEmpty && Set(options.map(\.value)).count == options.count
    }

    private static func validDefault(_ value: Any?, kind: McpFormFieldKind) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        switch kind {
        case .string:
            guard let string = value as? String else { return false }
            return validString(string, maximumBytes: McpElicitationLimits.maximumInputBytes,
                               allowEmpty: true)
        case .number:
            return (value as? NSNumber)?.doubleValue.isFinite == true
        case .boolean:
            return value is Bool
        case .single(let options):
            guard let string = value as? String else { return false }
            return options.contains { $0.value == string }
        case .multiple(let options, _, _):
            guard let strings = value as? [String],
                  strings.count <= options.count,
                  Set(strings).count == strings.count else { return false }
            return Set(strings).isSubset(of: Set(options.map(\.value)))
        }
    }
}

enum McpElicitationError: Error, Equatable {
    case invalidRequest
    case invalidURL
    case unsupportedMode(String)
    case invalidSchema(String)
    case unsupportedSchema(String)
    case missingValue(String)
    case invalidValue(String)
}
