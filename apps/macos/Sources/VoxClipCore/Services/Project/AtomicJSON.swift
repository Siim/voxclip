import Foundation

enum AtomicJSON {
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try ProjectJSON.encoder().encode(value)
        data.append(10)
        return data
    }
}
