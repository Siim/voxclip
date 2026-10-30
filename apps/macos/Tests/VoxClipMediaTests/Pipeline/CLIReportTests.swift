import Foundation
import Testing

struct CLIReportTests {
    @Test func watchdogFailureIsNotReportedAsMalformedJSON() throws {
        let result = CLIResult(status: 137, stdout: Data(), stderr: "", interruptLatency: nil,
            watchdogFired: true, interruptReadinessObserved: false)
        #expect(throws: CLIResult.ReportError.watchdogTimeout(status: 137)) { try result.json }
        let empty = CLIResult(status: 9, stdout: Data(), stderr: "", interruptLatency: nil,
            watchdogFired: false, interruptReadinessObserved: false)
        #expect(throws: CLIResult.ReportError.emptyOutput(status: 9)) { try empty.json }
        let success = CLIResult(status: 0, stdout: Data("{\"frames\":120}".utf8), stderr: "", interruptLatency: nil,
            watchdogFired: false, interruptReadinessObserved: false)
        #expect(try success.json["frames"] as? Int == 120)
    }
}
