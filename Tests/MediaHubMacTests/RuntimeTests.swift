import XCTest
@testable import MediaHubMac

final class RuntimeTests: XCTestCase {
    @MainActor
    func testAWSLoginErrorPromptsOnceAndPausesRefresh() async throws {
        let root = FileManager.default.temporaryDirectory
        let model = MacModel(runtime: MacRuntime(root: root, dataRoot: root))
        let response = HTTPURLResponse(url: URL(string: "http://127.0.0.1:1234")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"code":"aws_login_required","message":"Login required"}"#.utf8)
        do { try MacRuntime.validate(response, data: data); XCTFail("Expected login error") }
        catch { model.handle(error) }
        XCTAssertTrue(model.awsLoginRequired)
        XCTAssertTrue(model.showAWSLogin)
        model.showAWSLogin = false
        model.handle(MacAPIError.awsLoginRequired)
        XCTAssertFalse(model.showAWSLogin)
        await model.relock()
        XCTAssertTrue(model.awsLoginRequired)
        model.handle(MacAPIError.message("Permission denied"))
        XCTAssertFalse(model.showAWSLogin)
        XCTAssertEqual(MacModel.shellQuote("a'b;$(echo unsafe)"), "'a'\\''b;$(echo unsafe)'")
    }
    @MainActor
    func testPrivateChildAuthenticationLockAndShutdown() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(".venv/bin/python").path) else { throw XCTSkip("Python API environment is not installed") }
        let data = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: data) }
        let runtime = MacRuntime(root: root, dataRoot: data)
        runtime.start()
        for _ in 0..<150 {
            if runtime.ready || !runtime.error.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard runtime.ready else { await runtime.stop(); XCTFail(runtime.error); return }
        struct Status: Decodable { let mode: String }
        do {
            let status: Status = try await runtime.request("/status")
            XCTAssertEqual(status.mode, "local")
            let url = try XCTUnwrap(runtime.origin).appendingPathComponent("api/v1/status")
            let (_, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
            let second = MacRuntime(root: root, dataRoot: data)
            second.start()
            for _ in 0..<100 {
                if !second.error.isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertFalse(second.ready)
            XCTAssertFalse(second.error.isEmpty)
            await second.stop()
        } catch { await runtime.stop(); throw error }
        await runtime.stop()
        XCTAssertFalse(runtime.ready)
        XCTAssertNil(runtime.origin)
        XCTAssertEqual(runtime.token, "")
        let restarted = MacRuntime(root: root, dataRoot: data)
        restarted.start()
        for _ in 0..<150 {
            if restarted.ready || !restarted.error.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(restarted.ready, restarted.error)
        await restarted.stop()
    }
    @MainActor
    func testRelockDropsEphemeralGrantAndInvalidatesViews() async throws {
        let root = FileManager.default.temporaryDirectory
        let runtime = MacRuntime(root: root, dataRoot: root)
        let model = MacModel(runtime: runtime)
        let original = model.privacyID
        let storage = try XCTUnwrap(runtime.network.configuration.httpCookieStorage)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/api/v1", .name: "folder_grant", .value: "test-only", .expires: Date().addingTimeInterval(300)]))
        storage.setCookie(cookie)
        XCTAssertTrue(storage.cookies?.contains { $0.name == "folder_grant" } == true)
        // A ready runtime with no origin makes any inline refresh fail.
        // Relocking must clear secrets immediately and leave network work to polling.
        runtime.ready = true
        await model.relock()
        XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(model.busy)
        XCTAssertFalse(model.refreshing)
        XCTAssertNotEqual(model.privacyID, original)
        XCTAssertTrue(storage.cookies?.isEmpty ?? true)
        XCTAssertTrue(model.library.isEmpty)
    }
    @MainActor
    func testActivationPreservesPINSheetIdentityAndKeychainFocusChanges() async throws {
        let root = FileManager.default.temporaryDirectory
        let model = MacModel(runtime: MacRuntime(root: root, dataRoot: root))
        let identity = model.privacyID
        await model.applicationActivated()
        XCTAssertEqual(model.privacyID, identity)
        model.beginKeychainInteraction()
        await model.applicationDeactivated()
        await model.applicationActivated()
        XCTAssertFalse(model.concealed)
        XCTAssertEqual(model.privacyID, identity)
        await model.endKeychainInteraction()
        // Once the interaction ends, a real application switch still locks immediately.
        model.hiddenPagesOpen = true
        let unlockedIdentity = model.privacyID
        await model.applicationDeactivated()
        XCTAssertTrue(model.concealed)
        XCTAssertFalse(model.hiddenPagesOpen)
        XCTAssertNotEqual(model.privacyID, unlockedIdentity)
        await model.applicationActivated()
        XCTAssertFalse(model.concealed)
        XCTAssertFalse(model.hiddenPagesOpen)
    }
    @MainActor
    func testHTTPFailuresNeverDecodeAsSuccess() async throws {
        let url = URL(string: "http://127.0.0.1:1234")!
        let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try MacRuntime.validate(response, data: nil))
    }
}
