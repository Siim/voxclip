import Foundation

public struct LipsyncWindow: Codable, Sendable, Equatable {
    public let startSample: Int64
    public let endSample: Int64
    public let phraseIDs: [Int]

    public static func make(seamIn: Int64, seamOut: Int64, totalSamples: Int64, sampleRate: Int,
                            phraseID: Int) throws -> LipsyncWindow {
        guard (8_000...192_000).contains(sampleRate), totalSamples >= Int64(sampleRate) * 3,
              totalSamples <= Int64(sampleRate) * 86_400, seamIn >= 0, seamOut > seamIn,
              seamOut <= totalSamples, phraseID >= 0 else { throw LipsyncError.invalidInput }
        let handle = Int64(sampleRate), minimum = handle * 3
        var start = max(0, seamIn - handle), end = min(totalSamples, seamOut + handle)
        if end - start < minimum {
            let missing = minimum - (end - start)
            start = max(0, start - (missing + 1) / 2)
            end = min(totalSamples, start + minimum)
            start = end - minimum
        }
        guard end - start <= handle * 300 else { throw LipsyncError.invalidInput }
        return LipsyncWindow(startSample: start, endSample: end, phraseIDs: [phraseID])
    }

    public static func merge(_ windows: [LipsyncWindow], sampleRate: Int) throws -> [LipsyncWindow] {
        guard (8_000...192_000).contains(sampleRate) else { throw LipsyncError.invalidInput }
        var merged: [LipsyncWindow] = []
        for window in windows.sorted(by: { $0.startSample == $1.startSample ? $0.endSample < $1.endSample : $0.startSample < $1.startSample }) {
            guard window.startSample >= 0, window.endSample > window.startSample,
                  !window.phraseIDs.isEmpty else { throw LipsyncError.invalidInput }
            if let last = merged.last, window.startSample <= last.endSample {
                merged[merged.count - 1] = LipsyncWindow(startSample: last.startSample,
                    endSample: max(last.endSample, window.endSample), phraseIDs: Array(Set(last.phraseIDs + window.phraseIDs)).sorted())
            } else { merged.append(window) }
        }
        guard merged.allSatisfy({ $0.endSample - $0.startSample <= Int64(sampleRate) * 300 }) else {
            throw LipsyncError.invalidInput
        }
        return merged
    }

    public func seconds(sampleRate: Int) -> Double { Double(endSample - startSample) / Double(sampleRate) }
}

public enum LipsyncFaceCheck {
    public static func passes(largestFaceHeights: [Double]) -> Bool {
        !largestFaceHeights.isEmpty && largestFaceHeights.allSatisfy({ $0.isFinite && (0...1).contains($0) }) &&
            largestFaceHeights.filter({ $0 >= 0.08 }).count * 5 >= largestFaceHeights.count * 4
    }
}

public enum LipsyncFrameBlend {
    public static func weight(time: Double, start: Double, end: Double, fps: Double) -> Double {
        guard time.isFinite, start.isFinite, end.isFinite, fps.isFinite, fps > 0,
              end > start, time >= start, time < end else { return 0 }
        let fade = min(3 / fps, (end - start) / 2)
        return min(1, max(0, min((time - start) / fade, (end - time) / fade)))
    }
}
