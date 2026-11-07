import CoreFoundation
import Foundation
import Synchronization
import Testing

private final class SpeechStubLoadingLoop: Sendable {
    /// The reference is immutable and used only for thread-safe run-loop scheduling or identity checks.
    private struct Reference: @unchecked Sendable { let value: CFRunLoop }
    private struct State {
        var reference: Reference?
        var stopped = false
    }
    private let state = Mutex(State())

    init() {
        Thread.detachNewThread { [self] in
            let current = CFRunLoopGetCurrent()!
            var context = CFRunLoopSourceContext()
            let source = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(current, source, speechStubDefaultRunLoopMode)
            let shouldRun = state.withLock { state in
                guard !state.stopped else { return false }
                state.reference = Reference(value: current)
                return true
            }
            if shouldRun { CFRunLoopRun() }
            state.withLock { $0.reference = nil }
            CFRunLoopRemoveSource(current, source, speechStubDefaultRunLoopMode)
        }
    }

    var ready: Bool { state.withLock { $0.reference != nil } }
    var isCurrent: Bool { state.withLock { $0.reference?.value === CFRunLoopGetCurrent() } }
    func perform(_ action: @escaping @Sendable () -> Void) {
        state.withLock { state in
            guard let reference = state.reference else { return }
            CFRunLoopPerformBlock(reference.value, speechStubSchedulingMode(speechStubDefaultRunLoopMode), action)
            CFRunLoopWakeUp(reference.value)
        }
    }
    func stop() {
        state.withLock { state in
            state.stopped = true
            guard let reference = state.reference else { return }
            CFRunLoopPerformBlock(reference.value, speechStubSchedulingMode(speechStubDefaultRunLoopMode)) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            CFRunLoopWakeUp(reference.value)
        }
    }
}

private final class SpeechStubClient: NSObject, URLProtocolClient, Sendable {
    struct Snapshot: Sendable {
        var events: [String] = []
        var body = Data()
        var failure: URLError.Code?
        var onLoadingLoop = true
    }
    private let state = Mutex(Snapshot())
    let stoppedDeliveryDrained = Mutex(false)
    let loop: SpeechStubLoadingLoop
    let stopsAtResponse: Bool
    init(loop: SpeechStubLoadingLoop, stopsAtResponse: Bool = false) {
        self.loop = loop
        self.stopsAtResponse = stopsAtResponse
    }
    var snapshot: Snapshot { state.withLock { $0 } }
    private func record(_ event: String, body: Data = Data(), error: (any Error)? = nil) {
        state.withLock { state in
            state.events.append(event)
            state.body.append(body)
            state.failure = (error as? URLError)?.code
            state.onLoadingLoop = state.onLoadingLoop && loop.isCurrent
        }
    }
    func urlProtocol(_ protocolInstance: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy) {
        record("response")
        if stopsAtResponse {
            protocolInstance.stopLoading()
            loop.perform { self.stoppedDeliveryDrained.withLock { $0 = true } }
        }
    }
    func urlProtocol(_ protocolInstance: URLProtocol, didLoad data: Data) { record("body", body: data) }
    func urlProtocolDidFinishLoading(_ protocolInstance: URLProtocol) { record("finish") }
    func urlProtocol(_ protocolInstance: URLProtocol, didFailWithError error: any Error) { record("failure", error: error) }
    func urlProtocol(_ protocolInstance: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) { record("redirect") }
    func urlProtocol(_ protocolInstance: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) { record("cached") }
    func urlProtocol(_ protocolInstance: URLProtocol, didReceive challenge: URLAuthenticationChallenge) { record("challenge") }
    func urlProtocol(_ protocolInstance: URLProtocol, didCancel challenge: URLAuthenticationChallenge) { record("cancelChallenge") }
}

@Suite("Speech HTTP stub scheduling", .timeLimit(.minutes(1)), .offlineFixtures)
struct SpeechStubHTTPTests {
    @Test func blockedHandlerDoesNotHoldOtherSessions() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = Mutex(false), returned = Mutex(false)
        let heldURL = SpeechStubHTTP.register { _ in
            entered.withLock { $0 = true }
            guard gate.wait(timeout: .now() + 10) == .success else { throw TestDeadlineFailure.timedOut("held HTTP handler") }
            returned.withLock { $0 = true }
            return (200, [:], Data("held".utf8))
        }
        let otherURL = SpeechStubHTTP.register { _ in (201, [:], Data("independent".utf8)) }
        let heldSession = URLSession(configuration: SpeechStubHTTP.configuration(for: heldURL))
        let otherSession = URLSession(configuration: SpeechStubHTTP.configuration(for: otherURL))
        let held = Task { try await heldSession.data(from: heldURL) }
        defer {
            gate.signal()
            held.cancel()
            heldSession.invalidateAndCancel()
            otherSession.invalidateAndCancel()
        }
        try await SpeechTestWait.until { entered.withLock { $0 } }
        let other = Task { try await otherSession.data(from: otherURL) }
        let (body, response) = try await SpeechTestWait.value(other)
        #expect(body == Data("independent".utf8))
        #expect((response as? HTTPURLResponse)?.statusCode == 201)
        #expect(!returned.withLock { $0 })
        gate.signal()
        let (heldBody, heldResponse) = try await SpeechTestWait.value(held)
        #expect(heldBody == Data("held".utf8))
        #expect((heldResponse as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func cancellingBlockedHandlerFinishesBeforeHandlerRelease() async throws {
        let gate = DispatchSemaphore(value: 0)
        let entered = Mutex(false), returned = Mutex(false)
        let url = SpeechStubHTTP.register { _ in
            entered.withLock { $0 = true }
            guard gate.wait(timeout: .now() + 10) == .success else { throw TestDeadlineFailure.timedOut("held HTTP handler") }
            returned.withLock { $0 = true }
            return (200, [:], Data("too late".utf8))
        }
        let session = URLSession(configuration: SpeechStubHTTP.configuration(for: url))
        let sending = Task { try await session.data(from: url) }
        defer { gate.signal(); sending.cancel(); session.invalidateAndCancel() }
        try await SpeechTestWait.until { entered.withLock { $0 } }
        sending.cancel()
        do {
            _ = try await SpeechTestWait.value(sending)
            Issue.record("A cancelled request delivered a response")
        } catch let error as URLError { #expect(error.code == .cancelled) }
        #expect(!returned.withLock { $0 })
        gate.signal()
        try await SpeechTestWait.until { returned.withLock { $0 } }
    }

    @Test(arguments: [false, true])
    func callbacksAndWriteAcknowledgedFailureStayOnLoadingRunLoop(failsAfterWrite: Bool) async throws {
        let loop = SpeechStubLoadingLoop()
        defer { loop.stop() }
        try await SpeechTestWait.until { loop.ready }
        let client = SpeechStubClient(loop: loop)
        let acknowledgement = SpeechStubHTTP.WriteAcknowledgement()
        let body = Data("fixture bytes".utf8)
        let url = SpeechStubHTTP.registerStream { _ in
            SpeechStubHTTP.Reply(status: 200, headers: [:], body: body,
                                 failure: failsAfterWrite ? .networkConnectionLost : nil,
                                 failureAfterWrite: failsAfterWrite ? acknowledgement : nil)
        }
        let stub = SpeechStubBox(SpeechStubHTTP(request: URLRequest(url: url), cachedResponse: nil, client: client))
        defer { loop.perform { stub.value?.stopLoading() } }
        loop.perform { stub.value?.startLoading() }
        if failsAfterWrite {
            try await SpeechTestWait.until { client.snapshot.events.contains("body") }
            #expect(client.snapshot.events == ["response", "body"])
            acknowledgement.acknowledge()
        }
        try await SpeechTestWait.until { client.snapshot.events.contains(failsAfterWrite ? "failure" : "finish") }
        let snapshot = client.snapshot
        #expect(snapshot.events == ["response", "body", failsAfterWrite ? "failure" : "finish"])
        #expect(snapshot.body == body)
        #expect(snapshot.failure == (failsAfterWrite ? URLError.Code.networkConnectionLost : nil))
        #expect(snapshot.onLoadingLoop)
    }

    @Test func stopDuringResponseDropsBodyAndCompletion() async throws {
        let loop = SpeechStubLoadingLoop()
        defer { loop.stop() }
        try await SpeechTestWait.until { loop.ready }
        let client = SpeechStubClient(loop: loop, stopsAtResponse: true)
        let url = SpeechStubHTTP.register { _ in (200, [:], Data("not delivered".utf8)) }
        let stub = SpeechStubBox(SpeechStubHTTP(request: URLRequest(url: url), cachedResponse: nil, client: client))
        loop.perform { stub.value?.startLoading() }
        try await SpeechTestWait.until { client.stoppedDeliveryDrained.withLock { $0 } }
        let snapshot = client.snapshot
        #expect(snapshot.events == ["response"])
        #expect(snapshot.body.isEmpty)
        #expect(snapshot.onLoadingLoop)
    }

    @Test func thrownHandlerErrorStaysOnLoadingRunLoop() async throws {
        let loop = SpeechStubLoadingLoop()
        defer { loop.stop() }
        try await SpeechTestWait.until { loop.ready }
        let client = SpeechStubClient(loop: loop)
        let url = SpeechStubHTTP.register { _ in throw URLError(.cannotDecodeRawData) }
        let stub = SpeechStubBox(SpeechStubHTTP(request: URLRequest(url: url), cachedResponse: nil, client: client))
        defer { loop.perform { stub.value?.stopLoading() } }
        loop.perform { stub.value?.startLoading() }
        try await SpeechTestWait.until { client.snapshot.events.contains("failure") }
        let snapshot = client.snapshot
        #expect(snapshot.events == ["failure"])
        #expect(snapshot.failure == .cannotDecodeRawData)
        #expect(snapshot.onLoadingLoop)
    }
}
