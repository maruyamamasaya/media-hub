import XCTest
import UIKit
import PDFKit
import ImageIO
import AVFoundation
import PhotoHubCore
import AssetLibraryContract
import CryptoKit
@testable import PhotoHub

@MainActor
final class IntegrationTests: XCTestCase {
    func testPDFDownloadIntegrityRelockAndMemoryDecryption() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderBatchProtocol.self]
        let authentication = Authentication(network: URLSession(configuration: configuration), storage: FixtureRefreshTokens())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CloudViewerModel(cacheRoot: directory, authentication: authentication, networkConfiguration: configuration)
        model.configuration.api = "https://fixture.invalid"; model.configuration.domain = "https://fixture.invalid"
        model.configuration.clientID = "test-client"; model.configuration.owner = UUID().uuidString; model.signedIn = true
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            for title in ["First page", "Second page"] {
                context.beginPage()
                (title as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let catalog = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "id": "catalog", "rootId": "root", "name": "PDF",
            "folders": [["id": "folder", "name": "Folder", "parentId": NSNull(), "isLocked": false]],
            "items": [["id": "item", "name": "Book.pdf", "folderId": "folder", "sha256": digest,
                       "mimeType": "application/pdf", "byteSize": bytes.count, "hasThumbnail": false]]
        ]))
        model.catalogs[model.catalogKey("root", "catalog")] = catalog
        ReaderBatchProtocol.imageData = bytes
        let downloaded = try await model.pdfData(catalog, catalog.items[0])
        let document = try XCTUnwrap(PDFDocument(data: downloaded))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Second page") == true)
        XCTAssertNotNil(document.page(at: 1)?.thumbnail(of: CGSize(width: 100, height: 100), for: .mediaBox).cgImage)
        ReaderBatchProtocol.imageData = Data(repeating: 0, count: bytes.count)
        do { _ = try await model.pdfData(catalog, catalog.items[0]); XCTFail("Damaged PDF must fail integrity") }
        catch ViewerError.integrity { }
        model.relock()
        do { _ = try await model.pdfData(catalog, catalog.items[0]); XCTFail("Relock must reject old PDF access") }
        catch ViewerError.login { }
        let key = Data(repeating: 0x21, count: 32), id = UUID().uuidString
        let header = try SealedMedia.header(length: Int64(bytes.count), objectID: id)
        let cipher = header.data + (try SealedMedia.sealChunk(bytes, index: 0, header: header, master: key))
        let reader = SealedRangeReader(objectID: id, master: key, expectedLength: Int64(bytes.count)) { range in
            cipher.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        let restored = try await reader.allData()
        XCTAssertEqual(restored, bytes)
        XCTAssertEqual(PDFDocument(data: restored)?.pageCount, 2)
        await reader.close()
    }

    func testSwipePrefetchStopsAtTenSkipsVideosAndReusesCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderBatchProtocol.self]
        let authentication = Authentication(network: URLSession(configuration: configuration), storage: FixtureRefreshTokens())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CloudViewerModel(cacheRoot: directory, authentication: authentication, networkConfiguration: configuration)
        model.configuration.api = "https://fixture.invalid"
        model.configuration.domain = "https://fixture.invalid"
        model.configuration.clientID = "test-client"
        model.configuration.owner = UUID().uuidString
        model.signedIn = true
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData())
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let catalog = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "id": "catalog", "rootId": "root", "name": "Test",
            "folders": [["id": "folder", "name": "Folder", "parentId": NSNull(), "isLocked": false]],
            "items": (0..<35).map { index in
                ["id": "item-\(index)", "name": "Media", "folderId": "folder", "sha256": digest,
                 "mimeType": index % 2 == 0 ? "image/png" : "video/mp4", "byteSize": bytes.count,
                 "hasThumbnail": true] as [String: Any]
            }
        ]))
        model.catalogs[model.catalogKey("root", "catalog")] = catalog
        let entries = catalog.items.map { ReaderEntry(catalog: catalog, item: $0) }
        XCTAssertEqual(ReaderSwipeScreen.upcomingPhotos(entries, after: 0).map { $0.item.id },
                       stride(from: 2, through: 20, by: 2).map { "item-\($0)" })
        XCTAssertTrue(ReaderSwipeScreen.upcomingPhotos(entries, after: 34).isEmpty)
        XCTAssertTrue(ReaderSwipeScreen.upcomingPhotos([], after: 0).isEmpty)
        ReaderBatchProtocol.imageCount = 0
        ReaderBatchProtocol.imageData = bytes
        let cancelled = Task { await model.prefetchSwipeImages(entries, after: 0) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 0)
        await model.prefetchSwipeImages(entries, after: 0)
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 10, "Never download the entire queue")
        _ = try await model.image(catalog, catalog.items[2])
        await model.prefetchSwipeImages(entries, after: 0)
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 10, "Display and repeated prefetch reuse the cache")
        await model.prefetchSwipeImages(entries, after: 2)
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 11, "Moving adds only the new photo in the window")
        model.relock()
        await model.prefetchSwipeImages(entries, after: 22)
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 11, "Relocking prevents further downloads")
    }
    func testOverviewSeparatesMediaAndKeepsIdentityAcrossFolders() throws {
        func catalog(_ id: String) throws -> ReadCatalog {
            try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: [
                "id": id, "rootId": "root", "name": "Library", "folders": [],
                "items": ["image/jpeg", "video/mp4", "application/pdf"].enumerated().map { index, mime in
                    ["id": "item-\(index)", "name": "Media", "folderId": "folder", "sha256": String(repeating: "a", count: 64),
                     "mimeType": mime, "byteSize": 1, "hasThumbnail": true] as [String: Any]
                }
            ]))
        }
        let first = try catalog("one"), second = try catalog("two")
        XCTAssertEqual(first.items.filter { ReaderOverviewMode.photos.includes($0) }.count, 1)
        XCTAssertEqual(first.items.filter { ReaderOverviewMode.videos.includes($0) }.count, 1)
        XCTAssertEqual(first.items.filter { ReaderOverviewMode.swipe.includes($0) }.count, 2)
        XCTAssertNotEqual(ReaderEntry(catalog: first, item: first.items[0]).id,
                          ReaderEntry(catalog: second, item: second.items[0]).id)
        let refreshed = try catalog("one")
        XCTAssertEqual(ReaderEntry(catalog: first, item: first.items[0]).id,
                       ReaderEntry(catalog: refreshed, item: refreshed.items[0]).id)
    }

    func testFullScreenPhotoZoomCentersAndSeparatesPagingFromPanning() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let scroll = PhoneImageScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        scroll.imageView.image = image
        scroll.addSubview(scroll.imageView)
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        let coordinator = PhoneZoomableImage.Coordinator(PhoneZoomableImage(image: image, onTap: {}, onSwipe: { _ in }))
        scroll.delegate = coordinator
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.imageView.frame.width, 300, accuracy: 0.1)
        XCTAssertEqual(scroll.imageView.frame.height, 150, accuracy: 0.1)
        XCTAssertEqual(scroll.contentInset.top, 225, accuracy: 0.1)
        let swipe = UISwipeGestureRecognizer()
        scroll.addGestureRecognizer(swipe)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(swipe))
        scroll.setZoomScale(3, animated: false)
        XCTAssertEqual(scroll.imageView.frame.width, 900, accuracy: 0.1)
        XCTAssertFalse(coordinator.gestureRecognizerShouldBegin(swipe))
        scroll.setZoomScale(1, animated: false)
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(swipe))
        scroll.frame.size = CGSize(width: 600, height: 300)
        scroll.setNeedsLayout(); scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.imageView.frame.size, CGSize(width: 600, height: 300))
    }

    func testPhotoPagingAllowsOneFingerButRejectsPinchAndZoomedPan() {
        let allowsPaging = PhoneZoomableImage.Coordinator.allowsPaging
        XCTAssertTrue(allowsPaging(1, 1, .possible), "One finger tracked by the pinch recognizer must still page")
        XCTAssertFalse(allowsPaging(1, 2, .possible), "Two fingers are reserved for pinch")
        XCTAssertFalse(allowsPaging(1, 1, .began))
        XCTAssertFalse(allowsPaging(1, 1, .changed), "Lifting one pinch finger must not page")
        XCTAssertFalse(allowsPaging(3, 1, .possible), "Zoomed images pan instead of paging")
        XCTAssertFalse(allowsPaging(0.9, 2, .changed), "Pinching below minimum during bounce must not page")
        XCTAssertTrue(allowsPaging(1, 1, .ended), "Paging resumes after returning to minimum zoom")
    }

    func testReaderRequestGateCancellationDoesNotReserveFutureSlots() async throws {
        let gate = SealedRequestGate()
        try await gate.wait()
        let cancelled = (0..<30).map { _ in Task { try await gate.wait() } }
        // Let all waiters enter the gate before cancelling them.
        try await Task.sleep(for: .milliseconds(10))
        for task in cancelled { task.cancel() }
        for task in cancelled {
            do { try await task.value; XCTFail("Cancelled waiter should fail") }
            catch is CancellationError { }
        }
        let clock = ContinuousClock(), start = clock.now
        try await gate.wait()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testConcurrentThumbnailURLsShareOneBatchAndReuseUntilRelock() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderBatchProtocol.self]
        let authentication = Authentication(network: URLSession(configuration: configuration), storage: FixtureRefreshTokens())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CloudViewerModel(cacheRoot: directory, authentication: authentication, networkConfiguration: configuration)
        model.configuration.api = "https://fixture.invalid"
        model.configuration.domain = "https://fixture.invalid"
        model.configuration.clientID = "test-client"
        model.configuration.owner = UUID().uuidString
        model.signedIn = true
        let root = UUID().uuidString, catalogID = UUID().uuidString, folder = UUID().uuidString
        let ids = (0..<30).map { _ in UUID().uuidString }
        let catalog = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "id": catalogID, "rootId": root, "name": "Test",
            "folders": [["id": folder, "name": "Folder", "parentId": NSNull(), "isLocked": false]],
            "items": ids.map { ["id": $0, "name": "Image", "folderId": folder, "sha256": String(repeating: "a", count: 64),
                                 "mimeType": "image/png", "byteSize": 1, "hasThumbnail": true] as [String: Any] }
        ]))
        model.catalogs[model.catalogKey(root, catalogID)] = catalog
        ReaderBatchProtocol.batchCount = 0
        ReaderBatchProtocol.imageCount = 0
        ReaderBatchProtocol.imageData = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData())
        let requests = catalog.items.map { item in Task { try await model.mediaURL(catalog, item, thumbnail: true) } }
        for task in requests { _ = try await task.value }
        XCTAssertEqual(ReaderBatchProtocol.batchCount, 1)
        _ = try await model.mediaURL(catalog, catalog.items[0], thumbnail: true)
        XCTAssertEqual(ReaderBatchProtocol.batchCount, 1)
        var statuses = Array(repeating: [String](), count: 12)
        let images = (0..<12).map { index in
            Task {
                try await model.image(catalog, catalog.items[0], thumbnail: true) { status in
                    statuses[index].append(status)
                }
            }
        }
        for task in images { _ = try await task.value }
        for updates in statuses {
            XCTAssertEqual(updates.first, "保存済みの画像を確認中…")
            XCTAssertTrue(updates.contains("画像を受信中…"))
            XCTAssertTrue(updates.contains("画像を照合・表示準備中…"))
            XCTAssertEqual(updates.last, "画像を端末にキャッシュ中…")
        }
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 1)
        _ = try await model.image(catalog, catalog.items[0], thumbnail: true)
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 1)
        XCTAssertEqual(ReaderBatchProtocol.batchCount, 1)
        model.relock()
        // Restore only the ordinary catalog to exercise the saved disk cache.
        model.catalogs[model.catalogKey(root, catalogID)] = catalog
        _ = try await model.image(catalog, catalog.items[0], thumbnail: true)
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 1)
        XCTAssertEqual(ReaderBatchProtocol.batchCount, 1)
        model.relock()
        do { _ = try await model.mediaURL(catalog, catalog.items[0], thumbnail: true); XCTFail("Relocked URL must fail") }
        catch ViewerError.login { }
        XCTAssertEqual(ReaderBatchProtocol.batchCount, 1)
    }

    func testReaderCacheDisplaysWithoutNetworkAndRelockRejectsOldCatalog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CloudViewerModel(cacheRoot: directory)
        // Deliberately invalid connection: cache hits must never wait for the API.
        model.configuration = CloudConfiguration()
        model.signedIn = true
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData())
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let catalog = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "id": "catalog", "rootId": "root", "name": "Test",
            "folders": [["id": "folder", "name": "Folder", "parentId": NSNull(), "isLocked": false]],
            "items": [["id": "item", "name": "Image", "folderId": "folder", "sha256": digest,
                       "mimeType": "image/png", "byteSize": bytes.count, "hasThumbnail": true]]
        ]))
        let root = try JSONDecoder().decode(ReadRoot.self, from: Data(#"{"id":"catalog","rootId":"root","name":"Test","itemCount":1,"byteSize":1}"#.utf8))
        model.catalogs[model.catalogKey("root", "catalog")] = catalog
        let components = [model.configuration.api, model.configuration.owner, model.configuration.clientID, "root", "catalog", "item", digest]
        let key = SHA256.hash(data: try JSONEncoder().encode(components)).map { String(format: "%02x", $0) }.joined()
        let disk = try DiskCache(root: directory)
        try bytes.write(to: disk.file(id: key, kind: .display))
        let cached = try await model.catalog(root)
        XCTAssertEqual(cached.id, catalog.id)
        var statuses: [String] = []
        let image = try await model.image(catalog, catalog.items[0]) { statuses.append($0) }
        XCTAssertEqual(statuses, ["保存済みの画像を確認中…"], "Cached images must not report a network download")
        XCTAssertEqual(image.size, try XCTUnwrap(UIImage(data: bytes)).size)
        var lockedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        lockedJSON["folders"] = [["id": "folder", "name": "Folder", "parentId": NSNull(), "isLocked": true]]
        model.catalogs[model.catalogKey("root", "catalog")] = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: lockedJSON))
        do { _ = try await model.image(catalog, catalog.items[0]); XCTFail("Locked folder must reject even a memory cache hit") }
        catch ViewerError.unlock { }
        model.relock()
        XCTAssertTrue(model.catalogs.isEmpty)
        do { _ = try await model.image(catalog, catalog.items[0]); XCTFail("Stale catalog must not authorize cached bytes") }
        catch ViewerError.login { }
        model.signedIn = false
        do { _ = try await model.catalog(root); XCTFail("Signed out cache access must fail") }
        catch ViewerError.login { }
    }
    func testFolderBatchLimitAndExternalSymlinkExclusion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external/sub")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        for index in 0..<101 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
                UIColor(red: CGFloat(index) / 101, green: 0, blue: 0, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            try XCTUnwrap(image.pngData()).write(to: external.appendingPathComponent("\(index).png"))
        }
        let outside = root.appendingPathComponent("outside.png")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: external.appendingPathComponent("link.png"), withDestinationURL: outside)
        let model = LibraryModel(baseURL: root.appendingPathComponent("library"), cacheURL: root.appendingPathComponent("cache"))
        await model.registerFolder(external.deletingLastPathComponent())
        XCTAssertEqual(model.photos.count, 100)
        XCTAssertTrue(model.folderResults.values.first?.contains("新規100件") == true)
        await model.syncFolder(try XCTUnwrap(model.folders.first))
        XCTAssertEqual(model.photos.count, 101)
        XCTAssertFalse(model.photos.contains { $0.filename == "link.png" })
        XCTAssertTrue(model.photos.allSatisfy { $0.folderSource?.relativePath.hasPrefix("sub/") == true })
    }
    func testFolderSyncRenameChangeMissingReconnectionAndSafeDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let originalData = try XCTUnwrap(image.pngData())
        let original = external.appendingPathComponent("one.png")
        try originalData.write(to: original)
        let base = root.appendingPathComponent("library"), cache = root.appendingPathComponent("cache")
        let model = LibraryModel(baseURL: base, cacheURL: cache)
        await model.registerFolder(external)
        let first = try XCTUnwrap(model.photos.first), folder = try XCTUnwrap(model.folders.first)
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertNotNil(first.folderSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.source(first, .original).path))
        model.setFavorite(first); model.addAlbum(name: "フォルダ")
        model.toggleMembership(photo: first, album: try XCTUnwrap(model.albums.first))
        let preview = await model.image(first, kind: .display)
        XCTAssertNotNil(preview)
        let renamed = external.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: original, to: renamed)
        await model.syncFolder(folder)
        XCTAssertEqual(model.photos.first?.id, first.id)
        XCTAssertEqual(model.photos.first?.filename, "renamed.png")
        XCTAssertEqual(model.photos.first?.favorite, true)
        XCTAssertEqual(model.members.count, 1)
        let differentImage = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        try XCTUnwrap(differentImage.pngData()).write(to: renamed)
        await model.syncFolder(folder)
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertEqual(model.photos.first?.sha256, first.sha256)
        XCTAssertNotNil(model.photos.first?.error)
        try FileManager.default.removeItem(at: renamed)
        await model.syncFolder(folder)
        XCTAssertTrue(model.photos.first?.error?.contains("見つかりません") == true)
        try originalData.write(to: renamed)
        await model.syncFolder(folder)
        XCTAssertNil(model.photos.first?.error)
        let movedRoot = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: external, to: movedRoot)
        await model.registerFolder(movedRoot, replacing: folder.id)
        let reopened = LibraryModel(baseURL: base, cacheURL: root.appendingPathComponent("new-cache"))
        XCTAssertEqual(reopened.folders.first?.id, folder.id)
        await reopened.syncFolder(try XCTUnwrap(reopened.folders.first))
        XCTAssertEqual(reopened.photos.first?.id, first.id)
        XCTAssertEqual(reopened.photos.first?.favorite, true)
        let regenerated = await reopened.image(try XCTUnwrap(reopened.photos.first), kind: .thumbnail)
        XCTAssertNotNil(regenerated)
        await reopened.requestDelete(try XCTUnwrap(reopened.photos.first))
        XCTAssertTrue(reopened.photos.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedRoot.appendingPathComponent("renamed.png").path))
    }
    func testImageUploadBackupEmptyDatabaseRestoreAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let objectRoot = root.appendingPathComponent("objects")
        let model = LibraryModel(baseURL: root.appendingPathComponent("one"), cacheURL: root.appendingPathComponent("cache-one"), developmentRoot: objectRoot)
        model.localMode = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500)).image { context in UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500)) }
        let id = UUID().uuidString.lowercased(), directory = model.pending.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original"); try XCTUnwrap(image.pngData()).write(to: original)
        try PhotoImporter.derivatives(original: original, directory: directory)
        let photo = try Photo(id: id, assetID: "test-asset", filename: "test.png", capturedAt: Date(), mime: "image/png", bytes: Digest.bytes(file: original), width: 3000, height: 1500, sha256: Digest.checksum(file: original))
        try XCTUnwrap(model.repository).save(photo); try model.refresh()
        await model.uploadPending(); XCTAssertEqual(model.photos.first?.state, .uploaded)
        model.setFavorite(try XCTUnwrap(model.photos.first)); model.addAlbum(name: "旅行")
        model.toggleMembership(photo: try XCTUnwrap(model.photos.first), album: try XCTUnwrap(model.albums.first))
        await model.backup(); XCTAssertTrue(FileManager.default.fileExists(atPath: model.support.appendingPathComponent("backup.json").path))
        await model.backup() // latest pointer replacement, older snapshots retained
        let restored = LibraryModel(baseURL: root.appendingPathComponent("two"), cacheURL: root.appendingPathComponent("cache-two"), developmentRoot: objectRoot); restored.localMode = true
        await restored.restore()
        XCTAssertEqual(restored.photos.count, 1); XCTAssertEqual(restored.albums.first?.name, "旅行"); XCTAssertEqual(restored.members.count, 1); XCTAssertEqual(restored.photos.first?.favorite, true)
        let restoredPhoto = try XCTUnwrap(restored.photos.first)
        let imageFile = await restored.image(restoredPhoto, kind: .display)
        let file = try XCTUnwrap(imageFile), source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth] as? Int) ?? 9999, 2048)
        await restored.requestDelete(restoredPhoto); XCTAssertTrue(restored.photos.isEmpty); XCTAssertTrue(restored.members.isEmpty)
        let store = try LocalObjectStore(root: objectRoot)
        let absent = try await store.head(key: ObjectKeys.photo(owner: store.owner, id: id, kind: .original)); XCTAssertNil(absent)
    }
    func testUnconfiguredProductionNeverFallsBackToLocalStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(baseURL: root, cacheURL: root.appendingPathComponent("cache"))
        let previous = model.localMode; defer { model.localMode = previous }
        model.localMode = false; model.configuration = CloudConfiguration()
        let photo = Photo(assetID: "test", filename: "test.jpg", capturedAt: Date(), mime: "image/jpeg", bytes: 1, width: 1, height: 1, sha256: "pending")
        try XCTUnwrap(model.repository).save(photo); try model.refresh()
        await model.uploadPending()
        XCTAssertEqual(model.photos.first?.state, .pending); XCTAssertNotNil(model.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("DevelopmentObjects").path))
    }
    func testFailedUploadPreservesPendingOriginalAndRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(baseURL: root, cacheURL: root.appendingPathComponent("cache")); model.localMode = true
        let id = UUID().uuidString.lowercased(), directory = model.pending.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original"); try Data("pending-original".utf8).write(to: original)
        let photo = try Photo(id: id, assetID: "test", filename: "test.jpg", capturedAt: Date(), mime: "image/jpeg", bytes: Digest.bytes(file: original), width: 1, height: 1, sha256: Digest.checksum(file: original))
        try XCTUnwrap(model.repository).save(photo); try model.refresh()
        await model.uploadPending()
        XCTAssertEqual(model.photos.first?.state, .failed); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        for name in ["thumbnail", "display"] { try Data(name.utf8).write(to: directory.appendingPathComponent(name + ".jpg")) }
        await model.uploadPending(); XCTAssertEqual(model.photos.first?.state, .uploaded); XCTAssertEqual(model.photos.first?.id, id)
        await model.releaseOriginals(); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path)) // development copies are protected
    }
    func testVideoFailurePreservesOriginalAndHasNoOriginalPlaybackFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(baseURL: root, cacheURL: root.appendingPathComponent("cache"))
        let previous = model.localMode; model.localMode = true; defer { model.localMode = previous }
        let id = UUID().uuidString.lowercased(), directory = model.pending.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original")
        try Data("unsupported-video-original".utf8).write(to: original)
        let before = try Digest.checksum(file: original)
        do { try await PhotoImporter.videoDerivatives(original: original, directory: directory); XCTFail("Corrupt video should fail") } catch { }
        XCTAssertEqual(try Digest.checksum(file: original), before)
        let photo = try Photo(id: id, assetID: "video", filename: "private.mov", capturedAt: Date(), mime: "video/quicktime", bytes: Digest.bytes(file: original), width: 160, height: 100, sha256: before)
        try XCTUnwrap(model.repository).save(photo); try model.refresh()
        XCTAssertNil(model.playbackURL(photo))
        await model.uploadPending()
        XCTAssertEqual(model.photos.first?.state, .failed)
        XCTAssertNil(model.photos.first?.keys["playback"])
        XCTAssertEqual(try Digest.checksum(file: original), before)
        let derived = directory.appendingPathComponent("playback.mp4")
        try Data("test-derived".utf8).write(to: derived)
        XCTAssertEqual(model.playbackURL(photo), derived)
        let playback = ShortPlayback(); playback.open(derived)
        XCTAssertTrue(playback.player?.isMuted == true)
        let player = try XCTUnwrap(playback.player)
        playback.stop(); XCTAssertNil(playback.player); XCTAssertNil(player.currentItem)
    }

    func testLocalVideoTransferBackupRestoreUsesOnlyPlaybackDerivative() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let objects = root.appendingPathComponent("objects")
        let model = LibraryModel(baseURL: root.appendingPathComponent("one"), cacheURL: root.appendingPathComponent("cache-one"), developmentRoot: objects)
        let previous = model.localMode; model.localMode = true; defer { model.localMode = previous }
        let id = UUID().uuidString.lowercased(), directory = model.pending.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original")
        try Data("test-video-original".utf8).write(to: original)
        for name in ["thumbnail.jpg", "display.jpg"] { try Data("test-poster".utf8).write(to: directory.appendingPathComponent(name)) }
        let videoBytes = Data("test-derived-video".utf8)
        try videoBytes.write(to: directory.appendingPathComponent("playback.mp4"))
        let photo = try Photo(id: id, assetID: "local-video", filename: "test.mov", capturedAt: Date(), mime: "video/quicktime", bytes: Digest.bytes(file: original), width: 160, height: 100, sha256: Digest.checksum(file: original))
        try XCTUnwrap(model.repository).save(photo); try model.refresh()
        await model.uploadPending(); XCTAssertEqual(model.photos.first?.state, .uploaded)
        await model.backup()
        let restored = LibraryModel(baseURL: root.appendingPathComponent("two"), cacheURL: root.appendingPathComponent("cache-two"), developmentRoot: objects)
        restored.localMode = true; await restored.restore()
        let restoredPhoto = try XCTUnwrap(restored.photos.first)
        let fetched = await restored.loadPlayback(restoredPhoto)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fetched)), videoBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.source(restoredPhoto, .original).path))
        await restored.requestDelete(restoredPhoto)
        let store = try LocalObjectStore(root: objects)
        let absent = try await store.head(key: "users/\(store.owner)/photos/\(id)/playback.mp4")
        XCTAssertNil(absent)
    }

}

private final class SessionRestoreProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FixtureRefreshTokens: RefreshTokenStorage {
    var value: String? = "test-only-refresh"
    func read(_ configuration: CloudConfiguration) throws -> String {
        guard let value else { throw StoredSessionError.missing }; return value
    }
    func save(_ token: String, configuration: CloudConfiguration) throws { value = token }
    func delete(_ configuration: CloudConfiguration) { value = nil }
}

extension IntegrationTests {
    func testStoredLoginRefreshAndFailurePreserveKeychainUntilLogout() async throws {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [SessionRestoreProtocol.self]
        let store = FixtureRefreshTokens()
        let auth = Authentication(network: URLSession(configuration: session), storage: store)
        var config = CloudConfiguration()
        config.api = "https://fixture.invalid"
        config.domain = "https://" + UUID().uuidString + ".invalid"
        config.clientID = "test-client"
        config.owner = UUID().uuidString
        defer { auth.signOut(config) }
        SessionRestoreProtocol.status = 200
        SessionRestoreProtocol.body = Data(#"{"access_token":"test-only-access"}"#.utf8)
        let restored = try await auth.token(config)
        XCTAssertEqual(restored, "test-only-access")
        SessionRestoreProtocol.status = 503
        SessionRestoreProtocol.body = Data(#"{"error":"temporarily_unavailable"}"#.utf8)
        do { _ = try await auth.token(config); XCTFail("Expected service failure") } catch { }
        SessionRestoreProtocol.status = 200
        SessionRestoreProtocol.body = Data(#"{"access_token":"test-only-access"}"#.utf8)
        let retry = try await auth.token(config)
        XCTAssertEqual(retry, "test-only-access")
        SessionRestoreProtocol.status = 400
        SessionRestoreProtocol.body = Data(#"{"error":"invalid_grant"}"#.utf8)
        do { _ = try await auth.token(config); XCTFail("Expected expiry") }
        catch StoredSessionError.expired { }
        auth.signOut(config)
        do { _ = try await auth.token(config); XCTFail("Expected logged out session") }
        catch StoredSessionError.missing { }
    }
}

private final class ReaderBatchProtocol: URLProtocol {
    static var batchCount = 0
    static var imageCount = 0
    static var imageData = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        if request.url!.path.contains("oauth2/token") {
            data = Data(#"{"access_token":"test-only-access"}"#.utf8)
        } else if request.url!.path.hasPrefix("/image/") {
            Self.imageCount += 1
            data = Self.imageData
        } else if request.url!.path.contains("/items/") {
            let id = request.url!.deletingLastPathComponent().lastPathComponent
            data = try! JSONSerialization.data(withJSONObject: ["url": "https://fixture.s3.ap-northeast-1.amazonaws.com/image/" + id, "expiresIn": 300])
        } else {
            Self.batchCount += 1
            let ids = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "thumbnailIds" }!.value!.split(separator: ",")
            let urls = Dictionary(uniqueKeysWithValues: ids.map { (String($0), "https://fixture.s3.ap-northeast-1.amazonaws.com/image/" + $0) })
            data = try! JSONSerialization.data(withJSONObject: ["urls": urls, "expiresIn": 300])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
