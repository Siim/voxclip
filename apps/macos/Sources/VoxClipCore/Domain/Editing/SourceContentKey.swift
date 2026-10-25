import Foundation

public enum SourceContentKey {
    public static func hash(sizeBytes: Int64, head: Data, tail: Data = Data()) -> String {
        var payload = Data("voxclip-source-v1\n\(sizeBytes)\n".utf8)
        payload.append(head)
        if sizeBytes >= 2_097_152 { payload.append(tail) }
        return sha256(payload)
    }

    static func sha256(_ data: Data) -> String {
        let constants: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]
        func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }
        var bytes = Array(data)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bitCount >> shift)) }
        var hash: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var schedule = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let position = offset + index * 4
                schedule[index] = UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 | UInt32(bytes[position + 2]) << 8 | UInt32(bytes[position + 3])
            }
            for index in 16..<64 {
                let earlier = schedule[index - 15], later = schedule[index - 2]
                let small0 = rotate(earlier, 7) ^ rotate(earlier, 18) ^ (earlier >> 3)
                let small1 = rotate(later, 17) ^ rotate(later, 19) ^ (later >> 10)
                schedule[index] = schedule[index - 16] &+ small0 &+ schedule[index - 7] &+ small1
            }
            var working = hash
            for index in 0..<64 {
                let big1 = rotate(working[4], 6) ^ rotate(working[4], 11) ^ rotate(working[4], 25)
                let choice = (working[4] & working[5]) ^ (~working[4] & working[6])
                let first = working[7] &+ big1 &+ choice &+ constants[index] &+ schedule[index]
                let big0 = rotate(working[0], 2) ^ rotate(working[0], 13) ^ rotate(working[0], 22)
                let majority = (working[0] & working[1]) ^ (working[0] & working[2]) ^ (working[1] & working[2])
                working = [first &+ big0 &+ majority, working[0], working[1], working[2], working[3] &+ first, working[4], working[5], working[6]]
            }
            for index in hash.indices { hash[index] = hash[index] &+ working[index] }
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }
}
