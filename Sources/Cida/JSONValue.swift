import Foundation

/// A JSON document Cida builds, stores or shows: request bodies, the `headers` and `body` fields
/// of the model configuration, and the command line's `--json` output. Objects keep the order
/// their members were added in, so a request reads `model`, `stream`, `messages` the way Cida
/// wrote it; objects parsed from text order their members by key.
enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  var objectValue: JSONObject? {
    if case .object(let object) = self { return object }
    return nil
  }

  var stringValue: String? {
    if case .string(let string) = self { return string }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let array) = self { return array }
    return nil
  }

  var intValue: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .number(let value): Int(exactly: value)
    default: nil
    }
  }

  subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  // MARK: Parsing

  /// Parses JSON text; nil when the text is not JSON.
  static func parse(_ text: String) -> JSONValue? {
    parse(Data(text.utf8))
  }

  static func parse(_ data: Data) -> JSONValue? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else {
      return nil
    }
    return JSONValue(foundationObject: object)
  }

  private init?(foundationObject object: Any) {
    switch object {
    case is NSNull:
      self = .null
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else if CFNumberIsFloatType(number) {
        self = .number(number.doubleValue)
      } else {
        self = .integer(number.int64Value)
      }
    case let string as String:
      self = .string(string)
    case let array as [Any]:
      var values: [JSONValue] = []
      for element in array {
        guard let value = JSONValue(foundationObject: element) else { return nil }
        values.append(value)
      }
      self = .array(values)
    case let dictionary as [String: Any]:
      var result = JSONObject()
      for key in dictionary.keys.sorted() {
        guard let value = JSONValue(foundationObject: dictionary[key]!) else { return nil }
        result[key] = value
      }
      self = .object(result)
    default:
      return nil
    }
  }

  // MARK: Writing

  /// Compact JSON for the wire and for storage.
  var compactText: String {
    var output = ""
    write(to: &output, memberSeparator: ",", keySeparator: ":")
    return output
  }

  /// One line with a space after every `,` and `:`, the way the command line shows a request.
  var displayText: String {
    var output = ""
    write(to: &output, memberSeparator: ", ", keySeparator: ": ")
    return output
  }

  fileprivate func write(to output: inout String, memberSeparator: String, keySeparator: String) {
    switch self {
    case .null:
      output += "null"
    case .bool(let value):
      output += value ? "true" : "false"
    case .integer(let value):
      output += String(value)
    case .number(let value):
      output += value.isFinite ? "\(value)" : "null"
    case .string(let value):
      Self.writeString(value, to: &output)
    case .array(let values):
      output += "["
      for (index, value) in values.enumerated() {
        if index > 0 { output += memberSeparator }
        value.write(to: &output, memberSeparator: memberSeparator, keySeparator: keySeparator)
      }
      output += "]"
    case .object(let object):
      output += "{"
      for (index, member) in object.members.enumerated() {
        if index > 0 { output += memberSeparator }
        Self.writeString(member.key, to: &output)
        output += keySeparator
        member.value.write(to: &output, memberSeparator: memberSeparator, keySeparator: keySeparator)
      }
      output += "}"
    }
  }

  private static func writeString(_ string: String, to output: inout String) {
    output += "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{8}": output += "\\b"
      case "\u{C}": output += "\\f"
      default:
        if scalar.value < 0x20 {
          output += String(format: "\\u%04x", scalar.value)
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    output += "\""
  }

  // MARK: Merging

  /// `override` laid over this value: objects merge member by member and recursively, a `null`
  /// member removes the key, and anything else replaces what was there.
  func merging(_ override: JSONValue) -> JSONValue {
    guard case .object(var base) = self, case .object(let overrides) = override else {
      return override
    }
    for member in overrides.members {
      if member.value == .null {
        base[member.key] = nil
      } else if let existing = base[member.key] {
        base[member.key] = existing.merging(member.value)
      } else {
        base[member.key] = member.value
      }
    }
    return .object(base)
  }
}

/// A JSON object whose members keep the order they were added in. Two objects are equal when
/// they hold the same members, in any order.
struct JSONObject: Equatable, Sendable, ExpressibleByDictionaryLiteral {
  struct Member: Sendable {
    let key: String
    var value: JSONValue
  }

  private(set) var members: [Member] = []

  init() {}

  init(dictionaryLiteral elements: (String, JSONValue)...) {
    for (key, value) in elements {
      self[key] = value
    }
  }

  var isEmpty: Bool { members.isEmpty }
  var keys: [String] { members.map(\.key) }

  subscript(key: String) -> JSONValue? {
    get { members.first { $0.key == key }?.value }
    set {
      if let index = members.firstIndex(where: { $0.key == key }) {
        if let newValue {
          members[index].value = newValue
        } else {
          members.remove(at: index)
        }
      } else if let newValue {
        members.append(Member(key: key, value: newValue))
      }
    }
  }

  static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
    guard lhs.members.count == rhs.members.count else { return false }
    return lhs.members.allSatisfy { rhs[$0.key] == $0.value }
  }

  /// The same members ordered by key, for fingerprints that must not depend on order.
  var sortedByKey: JSONObject {
    var sorted = JSONObject()
    for member in members.sorted(by: { $0.key < $1.key }) {
      sorted[member.key] = member.value.sortedByKey
    }
    return sorted
  }
}

extension JSONValue {
  fileprivate var sortedByKey: JSONValue {
    switch self {
    case .object(let object): .object(object.sortedByKey)
    case .array(let values): .array(values.map(\.sortedByKey))
    default: self
    }
  }
}

extension JSONValue: Codable {
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Settings store `headers` and `body` as their JSON text, which keeps member order.
    let text = try container.decode(String.self)
    guard let value = JSONValue.parse(text) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Stored JSON text is not JSON")
    }
    self = value
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(compactText)
  }
}
