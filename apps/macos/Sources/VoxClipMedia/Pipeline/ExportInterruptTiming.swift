import Foundation
import Synchronization

package final class ExportInterruptTiming: Sendable {
    package enum Phase: String, CaseIterable, Sendable {
        case handler, exportStart, cancelRequest, pumpsStopped, teardownStart
        case videoReaderCancelStart, videoReaderCancelEnd, audioReaderCancelStart, audioReaderCancelEnd
        case readersStopped, writerCancelStart, writerCancelEnd, partialDeleted, exportReturned
    }

    package static let testOnly: ExportInterruptTiming? = ProcessInfo.processInfo.environment["VOXCLIP_TEST_INTERRUPT_TIMING"] == "1"
        ? ExportInterruptTiming() : nil
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
