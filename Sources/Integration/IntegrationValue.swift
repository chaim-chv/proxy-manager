import Foundation

/// A JSON-compatible value used on both sides of the integration boundary.
///
/// URL query arguments arrive as strings and are coerced by the action schema;
/// XPC and JSON callers must send the exact type. Keeping one value type for
/// requests, results and audit entries means every adapter and the router share
/// a single encoding.
enum IntegrationValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([IntegrationValue])
    case object([String: IntegrationValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [IntegrationValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: IntegrationValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension IntegrationValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([IntegrationValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: IntegrationValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
