import XCTest
@testable import MediaHubMac

final class TrashBatchTests: XCTestCase {
    @MainActor
    func testOnlyConfirmedSnapshotIsDeletedAndFailureStopsRemainder() async throws {
        var visible = ["one", "two", "three"]
        let confirmed = visible
        visible.append("new-unconfirmed")
        var attempted: [String] = []
        do {
            try await TrashBatch.execute(confirmed, authorized: { true }) { entry in
                attempted.append(entry)
                if entry == "two" { throw CocoaError(.fileWriteUnknown) }
            }
            XCTFail("Expected failure")
        } catch is CocoaError { }
        XCTAssertEqual(attempted, ["one", "two"])
    }

    @MainActor
    func testRelockStopsBeforeNextDeletion() async throws {
        var unlocked = true
        var deleted: [String] = []
        do {
            try await TrashBatch.execute(["one", "two"], authorized: { unlocked }) { entry in
                deleted.append(entry)
                unlocked = false
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(deleted, ["one"])
    }

    @MainActor
    func testCompletesConfirmedEntriesInOrder() async throws {
        var deleted: [Int] = []
        try await TrashBatch.execute([1, 2, 3], authorized: { true }) { deleted.append($0) }
        XCTAssertEqual(deleted, [1, 2, 3])
    }
}
