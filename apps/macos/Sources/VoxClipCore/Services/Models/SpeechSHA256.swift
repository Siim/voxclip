import Foundation

public struct SpeechSHA256: Sendable {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var count: UInt64 = 0
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    public init() {}
    public mutating func update(_ data: Data) {
        count &+= UInt64(data.count)
        let bytes = pending + data
        var offset = 0
        while offset + 64 <= bytes.count { compress(bytes, offset: offset); offset += 64 }
        pending = Array(bytes[offset...])
    }
    public func hexDigest() -> String {
        var copy = self
        var suffix = Data([0x80])
        while (copy.pending.count + suffix.count) % 64 != 56 { suffix.append(0) }
        let bits = count &* 8
        for shift in stride(from: 56, through: 0, by: -8) { suffix.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        copy.update(suffix)
        return copy.state.map { String(format: "%08x", $0) }.joined()
    }
    public static func hex(_ data: Data) -> String { var hash = Self(); hash.update(data); return hash.hexDigest() }
    public static func file(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Self()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data) }
        return hash.hexDigest()
    }
    private mutating func compress(_ bytes: [UInt8], offset: Int) {
        func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 { (value >> bits) | (value << (32 - bits)) }
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = offset + index * 4
            schedule[index] = UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16 | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
        }
        for index in 16..<64 {
            let left = schedule[index - 15], right = schedule[index - 2]
            schedule[index] = schedule[index - 16] &+ (rotate(left, 7) ^ rotate(left, 18) ^ (left >> 3)) &+ schedule[index - 7] &+ (rotate(right, 17) ^ rotate(right, 19) ^ (right >> 10))
        }
        var stateA = state[0], stateB = state[1], stateC = state[2], stateD = state[3]
        var stateE = state[4], stateF = state[5], stateG = state[6], stateH = state[7]
        for index in 0..<64 {
            let choice = (stateE & stateF) ^ (~stateE & stateG)
            let majority = (stateA & stateB) ^ (stateA & stateC) ^ (stateB & stateC)
            let first = stateH &+ (rotate(stateE, 6) ^ rotate(stateE, 11) ^ rotate(stateE, 25)) &+ choice &+ Self.constants[index] &+ schedule[index]
            let second = (rotate(stateA, 2) ^ rotate(stateA, 13) ^ rotate(stateA, 22)) &+ majority
            stateH = stateG; stateG = stateF; stateF = stateE; stateE = stateD &+ first
            stateD = stateC; stateC = stateB; stateB = stateA; stateA = first &+ second
        }
        let working = [stateA, stateB, stateC, stateD, stateE, stateF, stateG, stateH]
        for index in 0..<8 { state[index] &+= working[index] }
    }
}
