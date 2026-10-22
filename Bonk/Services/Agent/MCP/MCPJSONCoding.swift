//
//  MCPJSONCoding.swift
//  Bonk
//
//  Turning `MCPJSONValue` into bytes and back.
//
//  The protocol's shapes are ordinary JSON, so this is a hand-written
//  encoder/decoder over `JSONSerialization` rather than `Codable`: the
//  wire carries values whose shape depends on the method, and a
//  per-method `Codable` type would mean one type per method for no gain.
//
//  Decoding is strict about the things a hostile peer could use to
//  confuse the client: a message that is not an object, an `id` that is
//  neither a string nor a number, a request without a method.
//

import Foundation

enum MCPJSONCoding {
    // MARK: - Encoding

    static func data(from value: MCPJSONValue) throws -> Data {
        let object = try FoundationJSON.object(from: value)
        // Slashes are not escaped. JSON allows `\/` and `/` to mean the
        // same thing, but a method name or a tool name is full of
        // slashes, and a server that matches the raw line rather than
        // the parsed value would not recognise `tools\/call`.
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
    }

    static func string(from value: MCPJSONValue) throws -> String {
        let data = try data(from: value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPJSONCodingError.notUTF8
        }
        return text
    }

    // MARK: - Decoding

    static func value(from data: Data) throws -> MCPJSONValue {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw MCPJSONCodingError.notJSON(error.localizedDescription)
        }
        return try value(from: any)
    }

    static func value(from text: String) throws -> MCPJSONValue {
        guard let data = text.data(using: .utf8) else {
            throw MCPJSONCodingError.notUTF8
        }
        return try value(from: data)
    }

    static func value(from any: Any) throws -> MCPJSONValue {
        switch any {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // `NSNumber` covers bools too, and CFBoolean is not a Bool in
            // a cast on every platform, so the object identity is checked.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let text as String:
            return .string(text)
        case let list as [Any]:
            return .array(try list.map { try value(from: $0) })
        case let dictionary as [String: Any]:
            var result: [String: MCPJSONValue] = [:]
            for (key, item) in dictionary {
                result[key] = try value(from: item)
            }
            return .object(result)
        default:
            throw MCPJSONCodingError.unsupportedType
        }
    }

    // MARK: - Messages

    /// Read one message off the wire.
    static func message(from data: Data) throws -> MCPJSONRPCMessage {
        let root = try value(from: data)
        return try message(from: root)
    }

    /// Read one message off the wire, as text.
    static func message(from text: String) throws -> MCPJSONRPCMessage {
        let root = try value(from: text)
        return try message(from: root)
    }

    /// Read one message off a parsed value.
    static func message(from root: MCPJSONValue) throws -> MCPJSONRPCMessage {
        guard let object = root.objectValue else {
            throw MCPJSONCodingError.notAnObject
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            throw MCPJSONCodingError.notJSONRPC2
        }
        // A response carries an id and either a result or an error; a
        // request carries an id and a method; a notification carries a
        // method and no id.
        if let idValue = object["id"] {
            guard let id = identifier(from: idValue) else {
                throw MCPJSONCodingError.badIdentifier
            }
            if let errorValue = object["error"], let error = error(from: errorValue) {
                return .failure(id: id, error: error)
            }
            guard let method = object["method"]?.stringValue else {
                // A response without a method and without an error is a
                // result; the spec allows `result: null`.
                return .response(id: id, result: object["result"] ?? .null)
            }
            return .request(id: id, method: method, params: object["params"])
        }
        guard let method = object["method"]?.stringValue else {
            throw MCPJSONCodingError.notARequest
        }
        return .notification(method: method, params: object["params"])
    }

    /// The identifier of a request, as a string.
    ///
    /// A number is written in its shortest whole form, so `1` and `1.0`
    /// name the same request.
    static func identifier(from value: MCPJSONValue) -> String? {
        if let text = value.stringValue { return text }
        return value.numericText
    }

    private static func error(from value: MCPJSONValue) -> MCPJSONRPCError? {
        guard let object = value.objectValue,
              let code = object["code"]?.numberValue,
              let message = object["message"]?.stringValue
        else { return nil }
        return MCPJSONRPCError(code: Int(code), message: message, data: object["data"])
    }

    // MARK: - Writing a request

    /// A request, ready for the wire.
    static func request(id: String, method: String, params: MCPJSONValue?) -> MCPJSONValue {
        var object: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "method": .string(method)
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    /// A notification, ready for the wire.
    static func notification(method: String, params: MCPJSONValue?) -> MCPJSONValue {
        var object: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    /// A successful answer, ready for the wire.
    static func response(id: String, result: MCPJSONValue) -> MCPJSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "result": result
        ])
    }

    /// A failed answer, ready for the wire.
    static func failure(id: String, error: MCPJSONRPCError) -> MCPJSONValue {
        var details: [String: MCPJSONValue] = [
            "code": .number(Double(error.code)),
            "message": .string(error.message)
        ]
        if let data = error.data { details["data"] = data }
        return .object([
            "jsonrpc": .string("2.0"),
            "id": .string(id),
            "error": .object(details)
        ])
    }
}

/// Failures of the wire format itself.
enum MCPJSONCodingError: Error, Equatable {
    case notJSON(String)
    case notUTF8
    case notAnObject
    case notJSONRPC2
    case notARequest
    case badIdentifier
    case unsupportedType
}

/// The `Any` shapes `JSONSerialization` wants.
private enum FoundationJSON {
    static func object(from value: MCPJSONValue) throws -> Any {
        switch value {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(value): return try value.map { try object(from: $0) }
        case let .object(value):
            var result: [String: Any] = [:]
            for (key, item) in value {
                result[key] = try object(from: item)
            }
            return result
        }
    }
}
