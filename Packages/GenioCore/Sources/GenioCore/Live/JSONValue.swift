import Foundation

/// A JSON value: function-call arguments and tool responses, which have no
/// fixed shape.
public enum JSONValue: Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  /// From the output of JSONSerialization.
  public init(any value: Any?) {
    switch value {
    case let string as String: self = .string(string)
    case let number as NSNumber:
      // NSNumber wraps both booleans and numbers.
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
    case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
    case let object as [String: Any]: self = .object(object.mapValues { JSONValue(any: $0) })
    default: self = .null
    }
  }

  /// For JSONSerialization.
  public var any: Any {
    switch self {
    case .string(let value): return value
    case .number(let value): return value
    case .bool(let value): return value
    case .array(let values): return values.map(\.any)
    case .object(let values): return values.mapValues(\.any)
    case .null: return NSNull()
    }
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let values) = self { return values[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// Integers may arrive as 3, 3.0 or "3".
  public var intValue: Int? {
    switch self {
    case .number(let value) where value.rounded() == value: return Int(value)
    case .string(let value): return Int(value.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let values) = self { return values }
    return nil
  }
}
