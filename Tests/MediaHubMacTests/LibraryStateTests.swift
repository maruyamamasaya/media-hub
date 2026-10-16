import XCTest
import AssetLibraryContract
@testable import MediaHubMac

final class LibraryStateTests: XCTestCase {
    private func fixture() throws -> FolderUpload {
        let object: [String: Any] = [
            "id": "catalog", "name": "Library", "bucket": "bucket", "profile": "profile", "region": "region", "state": "complete", "error": "",
            "byteSize": 30, "completed": 2, "skipped": 0,
            "folders": [
                ["id": "root", "name": "Root", "parentId": NSNull(), "isLocked": false],
                ["id": "secret", "name": "Secret", "parentId": "root", "isLocked": true],
                ["id": "child", "name": "Child", "parentId": "secret", "isLocked": false]],
            "items": [
                ["id": "visible", "name": "Visible", "folderId": "root", "relativePath": "v", "byteSize": 10, "state": "verified"],
                ["id": "hidden", "name": "Hidden", "folderId": "child", "relativePath": "h", "byteSize": 20, "state": "verified"]]]
        return try JSONDecoder().decode(FolderUpload.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor
    func testOrdinaryAppSwitchKeepsLibraryHistoryAndViewIdentity() async throws {
        let model = MacModel(runtime: MacRuntime(root: .temporaryDirectory, dataRoot: .temporaryDirectory))
        model.library = [try fixture()]; model.uploads = model.library
        let identity = model.privacyID
        await model.applicationDeactivated()
        await model.applicationActivated()
        XCTAssertEqual(model.privacyID, identity)
        XCTAssertEqual(model.library.count, 1)
        XCTAssertEqual(model.uploads.count, 1)
        XCTAssertFalse(model.concealed)
    }
    @MainActor
    func testRelockDropsProtectedDescendantsButKeepsOrdinaryRoot() async throws {
        let model = MacModel(runtime: MacRuntime(root: .temporaryDirectory, dataRoot: .temporaryDirectory))
        model.library = [try fixture()]; model.uploads = model.library
        model.hiddenPagesOpen = true
        let identity = model.privacyID
        await model.applicationDeactivated()
        XCTAssertNotEqual(model.privacyID, identity)
        XCTAssertEqual(model.library.first?.folders.map(\.id), ["root"])
        XCTAssertEqual(model.library.first?.items.map(\.id), ["visible"])
        XCTAssertEqual(model.library.first?.byteSize, 10)
        XCTAssertEqual(model.uploads.first?.items.map(\.id), ["visible"])
        XCTAssertFalse(model.hiddenPagesOpen)
    }
}
