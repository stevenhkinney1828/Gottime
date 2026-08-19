import Foundation
import GotTimeCore

/// Development-only CallHistoryService, seeded with entries covering all six user-facing
/// outcomes from spec section 8. MockVoiceService appends to the same backing store (when
/// constructed together via GotTimeMocks.makeDefaultEnvironment(), see MockEnvironment.swift)
/// so a call made during a test session shows up in History immediately afterward.
public final class MockCallHistoryService: CallHistoryService, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CallHistoryEntry]

    public init(entries: [CallHistoryEntry] = MockData.defaultHistory()) {
        self.entries = entries
    }

    public func fetchHistory() async throws -> [CallHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.session.initiatedAt > $1.session.initiatedAt }
    }

    /// Not part of the CallHistoryService protocol — an extra, mock-specific hook so
    /// MockVoiceService can record a just-completed call without needing a shared database.
    public func record(_ entry: CallHistoryEntry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }
}
