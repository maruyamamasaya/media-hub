import XCTest
@testable import PhotoHubCore

final class UsageTests: XCTestCase {
    func testDailyScopePersistenceAndNoIdentifiers() throws {
        let suite = "UsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageActivityStore(defaults: defaults)
        // UTC 15:00 is the next day in Japan.
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-14T15:00:00Z"))
        store.record(scope: "private-endpoint|owner", requests: 2, receivedBytes: 100, now: now)
        store.record(scope: "private-endpoint|owner", requests: 1, receivedBytes: 20, videoStarts: 1, now: now)
        let value = try XCTUnwrap(UsageActivityStore(defaults: defaults).history(scope: "private-endpoint|owner").first)
        XCTAssertEqual(value.date, "2026-10-15")
        XCTAssertEqual(value.requests, 3); XCTAssertEqual(value.receivedBytes, 120); XCTAssertEqual(value.videoStarts, 1)
        XCTAssertTrue(store.history(scope: "other").isEmpty)
        let raw = String(data: try JSONEncoder().encode(defaults.dictionaryRepresentation().keys.sorted()), encoding: .utf8)!
        XCTAssertFalse(raw.contains("private-endpoint")); XCTAssertFalse(raw.contains("owner"))
    }
    func testRetentionAndConcurrentUpdates() throws {
        let suite = "UsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageActivityStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for offset in 0..<100 { store.record(scope: "scope", requests: 1, now: now.addingTimeInterval(Double(offset) * 86400)) }
        XCTAssertEqual(store.history(scope: "scope").count, 90)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in store.record(scope: "other", requests: 1, now: now) }
        XCTAssertEqual(store.history(scope: "other").first?.requests, 100)
    }
}
