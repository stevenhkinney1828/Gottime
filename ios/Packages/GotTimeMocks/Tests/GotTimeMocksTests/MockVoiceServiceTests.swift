import XCTest
@testable import GotTimeMocks
import GotTimeCore

/// Thread-safe mutable box for capturing state written from MockVoiceService's onCallEnded
/// callback (which can fire from a background Task) back into the test's assertions.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
    func get() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// AsyncStream never terminates on its own here (no continuation.finish() call anywhere in
/// MockVoiceService, deliberately — a real call session's event stream stays open for the
/// next call), so collecting "everything that happened" needs an explicit stop condition and
/// a timeout backstop against a test hanging forever if that condition is never met.
private func collectEvents(
    from stream: AsyncStream<VoiceEvent>,
    until predicate: @escaping ([VoiceEvent]) -> Bool,
    timeoutSeconds: Double = 8
) async -> [VoiceEvent] {
    let collector = Task<[VoiceEvent], Never> {
        var collected: [VoiceEvent] = []
        for await event in stream {
            collected.append(event)
            if predicate(collected) { break }
        }
        return collected
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(timeoutSeconds))
        collector.cancel()
    }
    let result = await collector.value
    timeoutTask.cancel()
    return result
}

private func hasCallEnded(_ events: [VoiceEvent]) -> Bool {
    events.contains { if case .callEnded = $0 { return true } else { return false } }
}

final class MockVoiceServiceTests: XCTestCase {
    let chrisPerson = ConnectedPerson(connectionId: UUID(), profile: MockData.chris)

    func testStartCallEntersOutgoingImmediately() async throws {
        let service = MockVoiceService()
        let session = try await service.startCall(to: chrisPerson, durationSeconds: 600)
        XCTAssertEqual(session.status, .outgoing)
        XCTAssertEqual(session.requestedDurationSeconds, 600)
    }

    func testAutoConnectHappyPathReachesCompletedAndRecordsHistoryExactlyOnce() async throws {
        let service = MockVoiceService()
        #if DEBUG
        service.devTimeScale = 60 // a "1 minute" call runs in ~1 real second
        #endif

        let recordedEntries = Box<[CallHistoryEntry]>([])
        service.onCallEnded = { entry in
            recordedEntries.mutate { $0.append(entry) }
        }

        let session = try await service.startCall(to: chrisPerson, durationSeconds: 60)
        let events = await collectEvents(from: service.events, until: hasCallEnded)

        let statuses: [CallStatus] = events.compactMap {
            if case .statusChanged(let callUUID, let status, _) = $0, callUUID == session.callUUID { return status }
            return nil
        }
        XCTAssertEqual(statuses, [.ringing, .connected, .timedOut, .completed])

        let finalEntries = recordedEntries.get()
        XCTAssertEqual(finalEntries.count, 1, "onCallEnded must fire exactly once, not zero or twice")
        XCTAssertEqual(finalEntries.first?.session.status, .completed)
        XCTAssertEqual(finalEntries.first?.otherPerson.id, MockData.chris.id)
        XCTAssertTrue(finalEntries.first?.isOutgoing ?? false)
    }

    func testExplicitCancelWhileOutgoingEndsTheCallImmediately() async throws {
        let service = MockVoiceService()
        let recordedEntries = Box<[CallHistoryEntry]>([])
        service.onCallEnded = { entry in recordedEntries.mutate { $0.append(entry) } }

        let session = try await service.startCall(to: chrisPerson, durationSeconds: 600)
        try await service.cancel(callUUID: session.callUUID)

        // Give any (incorrect, if present) auto-progression a moment to fire before asserting
        // it did not override the explicit cancel.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(recordedEntries.get().first?.session.status, .canceled)
    }

    func testCancelOnUnknownCallThrows() async {
        let service = MockVoiceService()
        do {
            try await service.cancel(callUUID: UUID())
            XCTFail("expected unknownCall to be thrown")
        } catch {
            XCTAssertEqual(error as? MockServiceError, .unknownCall)
        }
    }

    func testSimulateIncomingCallThenDecline() async throws {
        let service = MockVoiceService()
        let recordedEntries = Box<[CallHistoryEntry]>([])
        service.onCallEnded = { entry in recordedEntries.mutate { $0.append(entry) } }

        let session = service.simulateIncomingCall(from: MockData.chris, requestedDurationSeconds: 300)
        XCTAssertEqual(session.status, .ringing)

        try await service.decline(callUUID: session.callUUID)

        let entries = recordedEntries.get()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.session.status, .declined)
        XCTAssertFalse(entries.first?.isOutgoing ?? true, "a call Chris placed to me is not outgoing from my perspective")
    }

    func testSimulateIncomingCallThenAnswerThenEndEarly() async throws {
        let service = MockVoiceService()
        let recordedEntries = Box<[CallHistoryEntry]>([])
        service.onCallEnded = { entry in recordedEntries.mutate { $0.append(entry) } }

        let session = service.simulateIncomingCall(from: MockData.chris, requestedDurationSeconds: 600)
        try await service.answer(callUUID: session.callUUID)
        try await service.endEarly(callUUID: session.callUUID)

        let entries = recordedEntries.get()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.session.status, .endedEarly)
        XCTAssertNotNil(entries.first?.session.connectedAt)
        XCTAssertNotNil(entries.first?.session.actualDurationSeconds)
    }

    func testEndEarlyBeforeConnectingIsRejected() async throws {
        let service = MockVoiceService()
        let recordedEntries = Box<[CallHistoryEntry]>([])
        service.onCallEnded = { entry in recordedEntries.mutate { $0.append(entry) } }

        let session = try await service.startCall(to: chrisPerson, durationSeconds: 600)
        // Still `.outgoing` — endEarly is only valid from `.connected`. tryApply's design is
        // to silently no-op an invalid transition rather than throw, so the real assertion is
        // behavioral: this must NOT have finalized the call as ended.
        try await service.endEarly(callUUID: session.callUUID)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(recordedEntries.get().isEmpty, "endEarly on a not-yet-connected call must not end it")

        // And the call must still be alive enough to legitimately cancel — proving state
        // wasn't corrupted into some in-between condition by the rejected endEarly attempt.
        try await service.cancel(callUUID: session.callUUID)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recordedEntries.get().first?.session.status, .canceled)
    }

    func testAutoOutcomeDecline() async throws {
        let service = MockVoiceService()
        service.nextCallOutcome = .autoDecline
        let session = try await service.startCall(to: chrisPerson, durationSeconds: 600)

        let events = await collectEvents(from: service.events, until: hasCallEnded)
        let statuses: [CallStatus] = events.compactMap {
            if case .statusChanged(let callUUID, let status, _) = $0, callUUID == session.callUUID { return status }
            return nil
        }
        XCTAssertEqual(statuses, [.ringing, .declined])
    }

    func testAutoOutcomeMissed() async throws {
        let service = MockVoiceService()
        service.nextCallOutcome = .autoMissed
        let session = try await service.startCall(to: chrisPerson, durationSeconds: 600)

        let events = await collectEvents(from: service.events, until: hasCallEnded)
        let statuses: [CallStatus] = events.compactMap {
            if case .statusChanged(let callUUID, let status, _) = $0, callUUID == session.callUUID { return status }
            return nil
        }
        XCTAssertEqual(statuses, [.ringing, .missed])
    }

    func testAutoOutcomeFailed() async throws {
        let service = MockVoiceService()
        service.nextCallOutcome = .autoFail
        let session = try await service.startCall(to: chrisPerson, durationSeconds: 600)

        let events = await collectEvents(from: service.events, until: hasCallEnded)
        let statuses: [CallStatus] = events.compactMap {
            if case .statusChanged(let callUUID, let status, _) = $0, callUUID == session.callUUID { return status }
            return nil
        }
        XCTAssertEqual(statuses, [.ringing, .failed])
    }

    func testMuteAndSpeakerDoNotThrow() async throws {
        let service = MockVoiceService()
        try await service.setMuted(true)
        try await service.setSpeakerEnabled(true)
        try await service.setMuted(false)
    }
}
