import Foundation
import Synchronization

package final class ExportInterruptTiming: Sendable {
    package enum Phase: String, CaseIterable, Sendable {
        case handler, exportStart, cancelRequest, pumpsStopped, teardownStart
        case videoReaderCancelStart, videoReaderCancelEnd, audioReaderCancelStart, audioReaderCancelEnd
        case readersStopped, writerCancelStart, writerCancelEnd, partialDeleted, exportReturned
    }

    private static let isEnabled = Atomic<Bool>(false)
    private static let enabledTiming = Mutex<ExportInterruptTiming?>(nil)

    package static var testOnly: ExportInterruptTiming? {
        guard isEnabled.load(ordering: .acquiring) else { return nil }
        return enabledTiming.withLock { $0 }
    }

    package static func enable() {
        enabledTiming.withLock { timing in
            if timing == nil { timing = ExportInterruptTiming() }
        }
        isEnabled.store(true, ordering: .releasing)
    }

    private let state = Mutex<[Phase: UInt64]>([:])

    package func mark(_ phase: Phase) {
        let now: UInt64 = DispatchTime.now().uptimeNanoseconds
        state.withLock { stamps in
            guard phase == .handler || phase == .exportStart || stamps[.handler] != nil else { return }
            if stamps[phase] == nil { stamps[phase] = now }
        }
    }

    package var stamps: [Phase: UInt64] { state.withLock { $0 } }
}
