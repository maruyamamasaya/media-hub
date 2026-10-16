import XCTest
@testable import MediaHubMac

final class UploadBatchTests: XCTestCase {
    @MainActor
    func testStartsFirstBeforePreparingNextAndWaitsBeforeNextTransfer() async throws {
        let batch = UploadBatch()
        var events: [String] = []
        try await batch.execute(["one", "two", "three"], prepare: { path in
            events.append("prepare:" + path); return path
        }, start: { events.append("start:" + $0) }, wait: { events.append("wait:" + $0) })
        XCTAssertEqual(events, ["prepare:one", "start:one", "prepare:two", "wait:one", "start:two",
                                "prepare:three", "wait:two", "start:three"])
    }

    @MainActor
    func testStopDuringNextPreparationNeverStartsThatFolder() async throws {
        let batch = UploadBatch()
        var started: [String] = []
        do {
            try await batch.execute(["one", "two", "three"], prepare: { path in
                if path == "two" { batch.stopped = true }
                return path
            }, start: { started.append($0) }, wait: { _ in XCTFail("Must stop before waiting") })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(started, ["one"])
        XCTAssertEqual(batch.activeID, "one")
    }

    @MainActor
    func testTransferFailureStopsRemainingFolders() async throws {
        let batch = UploadBatch()
        var started: [String] = [], prepared: [String] = []
        do {
            try await batch.execute(["one", "two", "three"], prepare: {
                prepared.append($0); return $0
            }, start: { started.append($0) }, wait: { _ in throw CocoaError(.fileReadUnknown) })
            XCTFail("Expected failure")
        } catch is CocoaError { }
        XCTAssertEqual(started, ["one"])
        XCTAssertEqual(prepared, ["one", "two"])
    }

    @MainActor
    func testStopDuringStartDoesNotPrepareAnotherFolder() async throws {
        let batch = UploadBatch()
        var prepared: [String] = []
        do {
            try await batch.execute(["one", "two"], prepare: { prepared.append($0); return $0 },
                                    start: { _ in batch.stopped = true }, wait: { _ in XCTFail() })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertEqual(prepared, ["one"])
        XCTAssertEqual(batch.activeID, "one")
    }
}
