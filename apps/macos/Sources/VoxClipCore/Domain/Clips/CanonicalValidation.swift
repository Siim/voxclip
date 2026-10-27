import Foundation

extension CanonicalResponseParser {
    /// ai.md §4.5 and voice-lab §8.1: drop a code fence, parse the whole text, and only when that fails take the first balanced
    /// object. It reads Unicode scalars, never Characters, so a combining mark cannot hide a delimiter, and every parse is strict.
    public static func extract(_ text: String) throws -> JSONValue { try extract(text, maxDepth: StrictJSON.maxDepth) }

    static func extract(_ text: String, maxDepth: Int) throws -> JSONValue {
        let fence = Array("```".unicodeScalars)
        var body = Array(AIText.trim(text).unicodeScalars)
        if body.starts(with: fence) {
            // A fence with no line break is all opening line, so nothing is left to parse.
            body = body.firstIndex(of: "\n").map { Array(body[($0 + 1)...]) } ?? []
            let rest = Array(AIText.trim(string(body)).unicodeScalars)
            if rest.suffix(3).elementsEqual(fence) { body = Array(rest.dropLast(3)) }
        }
        if let whole = strictDecode(string(body), maxDepth: maxDepth) { return whole }
        guard let first = body.firstIndex(of: "{") else { throw LLMError.invalidOutput(reason: "not JSON") }
        var depth = 0
        var inString = false
        var escaped = false
        for position in first..<body.count {
            let scalar = body[position]
            if inString {
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { inString = false }
            } else if scalar == "\"" { inString = true }
            else if scalar == "{" { depth += 1 }
            else if scalar == "}" {
                depth -= 1
                if depth == 0 {
                    if let found = strictDecode(string(body[first...position]), maxDepth: maxDepth) { return found }
                    break
                }
            }
        }
        throw LLMError.invalidOutput(reason: "not JSON")
    }

    /// One strict parse (ai.md §4.5): the value StrictJSON builds while it checks the text.
    static func strictDecode(_ text: String, maxDepth: Int = StrictJSON.maxDepth) -> JSONValue? {
        StrictJSON.parse(text, maxDepth: maxDepth)
    }

    /// A transport envelope (ai.md §4.5): an HTTP response body, the Claude CLI result, a Codex exec or app-server line, the
    /// model cache file or Claude auth output. It is one strict parse of the whole text after jsTrim, at most 512 levels deep,
    /// with no code fence or balanced-object scan.
    static func envelope(_ text: String) -> JSONValue? {
        strictDecode(AIText.trim(text), maxDepth: StrictJSON.envelopeMaxDepth)
    }

    static func envelope(_ data: Data) -> JSONValue? { envelope(String(decoding: data, as: UTF8.self)) }

    private static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var text = ""
        text.unicodeScalars.append(contentsOf: scalars)
        return text
    }

    public static func validate(_ completion: RawCompletion, schema: JSONValue) throws -> (object: JSONValue, droppedItems: Int) {
        switch completion.stop {
        case .truncated: throw LLMError.truncated
        case .refused(let category): throw LLMError.refused(category: category)
        case .complete: break
        }
        // A reply object a connector parsed out of its envelope still holds at most 64 levels (ai.md §4.5).
        let value = try completion.object ?? extract(completion.text ?? "")
        guard let object = value.aiObject, !StrictJSON.nests(value, deeperThan: StrictJSON.maxDepth) else { throw LLMError.invalidOutput(reason: "not JSON") }
        let properties = schema[ai: "properties"].aiObject ?? [:]
        var result: [String: JSONValue] = [:]
        var dropped = 0
        for key in properties.keys.sorted() {
            let property = properties[key]!
            guard let content = object[key] else { throw LLMError.invalidOutput(reason: "missing \"\(key)\"") }
            if property[ai: "type"].aiString == "array" {
                guard case .array(let items) = content else { throw LLMError.invalidOutput(reason: "missing \"\(key)\"") }
                let valid = items.filter { conforms($0, to: property[ai: "items"]) }
                dropped += items.count - valid.count
                result[key] = .array(valid)
            } else {
                guard conforms(content, to: property) else { throw LLMError.invalidOutput(reason: "missing \"\(key)\"") }
                result[key] = content
            }
        }
        return (.object(result), dropped)
    }

    private static func conforms(_ value: JSONValue, to schema: JSONValue) -> Bool {
        switch schema[ai: "type"].aiString {
        case "object":
            guard let object = value.aiObject else { return false }
            return schema[ai: "required"].aiArray.allSatisfy { required in
                guard let key = required.aiString, let item = object[key] else { return false }
                return conforms(item, to: schema[ai: "properties"][ai: key])
            }
        case "array":
            guard case .array(let items) = value else { return false }
            return items.allSatisfy { conforms($0, to: schema[ai: "items"]) }
        case "number", "integer": return value.aiDouble != nil
        case "string":
            guard let string = value.aiString else { return false }
            let values = schema[ai: "enum"].aiArray
            return values.isEmpty || values.contains(.string(string))
        case "boolean": return value.aiBool != nil
        default: return false
        }
    }

    public static func validateSchemaSubset(_ schema: JSONValue) -> Bool {
        guard let object = schema.aiObject, Set(object.keys).isSubset(of: ["type", "properties", "required", "additionalProperties", "items", "enum"]) else { return false }
        switch schema[ai: "type"].aiString {
        case "object":
            guard schema[ai: "additionalProperties"].aiBool == false, let properties = schema[ai: "properties"].aiObject else { return false }
            return Set(schema[ai: "required"].aiArray.compactMap(\.aiString)) == Set(properties.keys) && properties.values.allSatisfy(validateSchemaSubset)
        case "array": return validateSchemaSubset(schema[ai: "items"])
        case "string": return schema[ai: "enum"] == .null || (!schema[ai: "enum"].aiArray.isEmpty && schema[ai: "enum"].aiArray.allSatisfy { $0.aiString != nil })
        case "integer", "number", "boolean": return schema[ai: "enum"] == .null
        default: return false
        }
    }
}

/// The strict JSON of ai.md §4.5, which both platforms read every reply and transport envelope with: one RFC 8259 value with at
/// most `maxDepth` levels of nesting, where the outermost container is level 1, every string escape is well formed with no
/// unpaired surrogate, in key names too, and every number is a finite double; a non-zero number that rounds to zero does not
/// fit either. The whole text is checked, the values of repeated keys included, and the value built keeps a key's first value.
struct StrictJSON {
    static let maxDepth = 64
    /// A transport envelope may nest a reply one level down, so it may go 512 levels deep.
    static let envelopeMaxDepth = 512
    /// The byte each simple escape stands for: `" \ / b f n r t`.
    private static let simpleEscapes: [UInt8: UInt8] = [0x22: 0x22, 0x5C: 0x5C, 0x2F: 0x2F, 0x62: 0x08, 0x66: 0x0C, 0x6E: 0x0A, 0x72: 0x0D, 0x74: 0x09]
    private static let hexDigits = Set("0123456789abcdefABCDEF".utf8)
    private static let literals: [(word: [UInt8], value: JSONValue)] = [(Array("true".utf8), .bool(true)), (Array("false".utf8), .bool(false)),
                                                                         (Array("null".utf8), .null)]
    private let bytes: [UInt8]
    private let maxDepth: Int
    private var at = 0

    /// The value of `text` when it is one strict JSON value, else nil.
    static func parse(_ text: String, maxDepth: Int = StrictJSON.maxDepth) -> JSONValue? {
        var reader = StrictJSON(bytes: Array(text.utf8), maxDepth: maxDepth)
        reader.space()
        guard let value = reader.document() else { return nil }
        reader.space()
        return reader.at == reader.bytes.count ? value : nil
    }

    /// True when `value` nests deeper than `levels`. It looks at most one level past them, so a deep connector object never
    /// takes a deep recursion.
    static func nests(_ value: JSONValue, deeperThan levels: Int) -> Bool {
        let children: [JSONValue]
        switch value {
        case .object(let object): children = Array(object.values)
        case .array(let array): children = array
        default: return false
        }
        return levels <= 0 || children.contains { nests($0, deeperThan: levels - 1) }
    }

    private init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    private var head: UInt8? { at < bytes.count ? bytes[at] : nil }

    private static func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    private mutating func space() {
        while let byte = head, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { at += 1 }
    }

    /// One open object or array: what it holds so far and, in an object, the key whose value comes next.
    private struct Frame {
        let isObject: Bool
        var members: [String: JSONValue] = [:]
        var items: [JSONValue] = []
        var key = ""

        var close: UInt8 { isObject ? UInt8(ascii: "}") : UInt8(ascii: "]") }
        var value: JSONValue { isObject ? .object(members) : .array(items) }

        /// A repeated key keeps its first value; the later one was still checked.
        mutating func add(_ item: JSONValue) {
            if !isObject { items.append(item) } else if members[key] == nil { members[key] = item }
        }
    }

    /// One value, read with a stack of open containers rather than recursion, so 512 levels never reach the thread's stack.
    private mutating func document() -> JSONValue? {
        var open: [Frame] = []
        while true {
            var finished: JSONValue
            if head == UInt8(ascii: "{") || head == UInt8(ascii: "[") {
                // The outermost container is level 1.
                guard open.count < maxDepth else { return nil }
                var frame = Frame(isObject: head == UInt8(ascii: "{"))
                at += 1
                space()
                if head != frame.close {
                    if frame.isObject {
                        guard let key = memberKey() else { return nil }
                        frame.key = key
                    }
                    open.append(frame)
                    continue
                }
                at += 1
                finished = frame.value
            } else if head == UInt8(ascii: "\"") {
                guard let text = string() else { return nil }
                finished = .string(text)
            } else {
                guard let scalar = scalar() else { return nil }
                finished = scalar
            }
            // The value goes into its container; a closing bracket finishes that container in turn.
            while true {
                guard var frame = open.popLast() else { return finished }
                frame.add(finished)
                space()
                if head == UInt8(ascii: ",") {
                    at += 1
                    space()
                    if frame.isObject {
                        guard let key = memberKey() else { return nil }
                        frame.key = key
                    }
                    open.append(frame)
                    break
                }
                guard head == frame.close else { return nil }
                at += 1
                finished = frame.value
            }
        }
    }

    /// An object member's key, then its colon.
    private mutating func memberKey() -> String? {
        guard head == UInt8(ascii: "\""), let name = string() else { return nil }
        space()
        guard head == UInt8(ascii: ":") else { return nil }
        at += 1
        space()
        return name
    }

    private mutating func scalar() -> JSONValue? {
        for literal in Self.literals where bytes[at...].starts(with: literal.word) {
            at += literal.word.count
            return literal.value
        }
        return number().map(JSONValue.number)
    }

    /// The string at `at`, built from the bytes as written and the scalars of the checked escapes.
    private mutating func string() -> String? {
        at += 1
        var text = ""
        var run = at
        while let byte = head {
            if byte == UInt8(ascii: "\"") {
                text += String(decoding: bytes[run..<at], as: UTF8.self)
                at += 1
                return text
            }
            if byte < 0x20 { return nil }
            guard byte == UInt8(ascii: "\\") else { at += 1; continue }
            text += String(decoding: bytes[run..<at], as: UTF8.self)
            if at + 1 < bytes.count, let simple = Self.simpleEscapes[bytes[at + 1]] {
                text.unicodeScalars.append(Unicode.Scalar(simple))
                at += 2
                run = at
                continue
            }
            guard let first = unit(at), !(0xDC00...0xDFFF).contains(first) else { return nil }
            at += 6
            var scalar = UInt32(first)
            if (0xD800...0xDBFF).contains(first) {
                guard let second = unit(at), (0xDC00...0xDFFF).contains(second) else { return nil }
                at += 6
                scalar = 0x10000 + (UInt32(first - 0xD800) << 10) + UInt32(second - 0xDC00)
            }
            guard let decoded = Unicode.Scalar(scalar) else { return nil }
            text.unicodeScalars.append(decoded)
            run = at
        }
        return nil
    }

    /// The UTF-16 unit of the six-character escape at `position`, if there is one.
    private func unit(_ position: Int) -> UInt16? {
        guard position + 6 <= bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") else { return nil }
        let digits = bytes[(position + 2)..<(position + 6)]
        // UInt16(_:radix:) would also take a sign.
        guard digits.allSatisfy(Self.hexDigits.contains) else { return nil }
        return UInt16(String(decoding: digits, as: UTF8.self), radix: 16)
    }

    /// RFC 8259 number grammar; a fraction or exponent counts only when complete, and what follows must then fit the grammar.
    /// The value is `Double(String)` of the number's text, which takes an exact zero with any exponent.
    private mutating func number() -> Double? {
        let start = at
        if head == UInt8(ascii: "-") { at += 1 }
        guard let lead = head, Self.isDigit(lead) else { return nil }
        at += 1
        if lead != UInt8(ascii: "0") { while let byte = head, Self.isDigit(byte) { at += 1 } }
        if head == UInt8(ascii: "."), at + 1 < bytes.count, Self.isDigit(bytes[at + 1]) {
            at += 1
            while let byte = head, Self.isDigit(byte) { at += 1 }
        }
        let mantissa = bytes[start..<at]
        if head == UInt8(ascii: "e") || head == UInt8(ascii: "E") {
            var next = at + 1
            if next < bytes.count, bytes[next] == UInt8(ascii: "+") || bytes[next] == UInt8(ascii: "-") { next += 1 }
            if next < bytes.count, Self.isDigit(bytes[next]) {
                at = next
                while let byte = head, Self.isDigit(byte) { at += 1 }
            }
        }
        guard at - start <= 1_024, let value = Double(String(decoding: bytes[start..<at], as: UTF8.self)), value.isFinite else { return nil }
        let roundsToZero = value == 0 && mantissa.contains { (UInt8(ascii: "1")...UInt8(ascii: "9")).contains($0) }
        return roundsToZero ? nil : value
    }
}
