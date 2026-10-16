import SwiftUI
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
    private func sealedPhotoFixture(_ bytes: Data, size: Int64? = nil, mime: String = "image/png", digest: String? = nil) throws -> SealedItem {
        try JSONDecoder().decode(SealedItem.self, from: JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "name": "Synthetic", "folderId": UUID().uuidString,
            "mimeType": mime, "byteSize": size ?? Int64(bytes.count),
            "sha256": digest ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "objectID": UUID().uuidString
        ]))
    }
    func testSealedPhotoMemoryPrefetchJoinsForegroundAndDecryptsWithoutDisk() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20), format: format).image { UIColor.blue.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 30, height: 20)) }.pngData())
        let item = try sealedPhotoFixture(bytes), current = UUID().uuidString
        let master = Data(repeating: 0x37, count: 32)
        let header = try SealedMedia.header(length: item.byteSize, objectID: item.objectID)
        let cipher = header.data + (try SealedMedia.sealChunk(bytes, index: 0, header: header, master: master))
        let session = PhoneSealedImageSession(monitorNetwork: false)
        session.select(current: current, next: item.objectID, previous: nil)
        var downloads = 0
        let started = expectation(description: "Prefetch started")
        let load: () async throws -> Data = {
            downloads += 1; started.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000)
            let reader = SealedRangeReader(objectID: item.objectID, master: master, expectedLength: item.byteSize) { range in
                cipher.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            }
            let result = try await reader.allData(); await reader.close(); return result
        }
        let prefetch = Task { try await session.image(item, authorized: { true }, load: load) }
        await fulfillment(of: [started], timeout: 2)
        session.select(current: item.objectID, next: nil, previous: current)
        prefetch.cancel()
        let visible = try await session.image(item, authorized: { true }, load: load)
        _ = try? await prefetch.value
        XCTAssertEqual(downloads, 1, "Entering the prefetched page must not download/decrypt twice")
        XCTAssertEqual(visible.size.width, 30)
        XCTAssertNotNil(session.images[item.objectID])
        _ = try await session.image(item, authorized: { true }) { XCTFail("Memory hit must not fetch again"); return bytes }
        session.close()
        XCTAssertTrue(session.images.isEmpty)
        do { _ = try await session.image(item, authorized: { true }, load: load); XCTFail("Closed viewer cannot restore plaintext") } catch { }
    }
    func testInactiveSealedPageDisplaysMemoryPreviewAndReleasesItOnClose() async throws {
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }.pngData())
        let item = try sealedPhotoFixture(bytes)
        let root = try JSONDecoder().decode(SealedRoot.self, from: JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "keyID": UUID().uuidString, "cipherBytes": 1]))
        let secret = try MediaSecret(masterKey: Data(repeating: 0x12, count: 32))
        let session = PhoneSealedImageSession(monitorNetwork: false)
        session.select(current: UUID().uuidString, next: item.objectID, previous: nil)
        _ = try await session.image(item, authorized: { true }) { bytes }
        let model = CloudViewerModel()
        let page = PhoneSealedMedia(root: root, item: item, secret: secret, photos: session,
            controls: .constant(true), active: false, onZoom: { _ in }).environmentObject(model)
        let host = UIHostingController(rootView: page)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let old = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { session.close(); window.isHidden = true; old?.makeKey() }
        func hasImage(_ view: UIView) -> Bool {
            view.accessibilityIdentifier == "media-image-zoom" || view.subviews.contains { hasImage($0) }
        }
        for _ in 0..<20 { host.view.layoutIfNeeded(); if hasImage(host.view) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(hasImage(host.view), "The incoming page must show its prepared photo before becoming active")
        session.close()
        for _ in 0..<20 { host.view.layoutIfNeeded(); if !hasImage(host.view) { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(hasImage(host.view), "Clearing the shared session must also remove the hosted image")
    }

    func testSealedPhotoRejectsCorruptionRevocationAndLateCompletion() async throws {
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.pngData())
        let broken = try sealedPhotoFixture(bytes, digest: String(repeating: "0", count: 64))
        let session = PhoneSealedImageSession(monitorNetwork: false)
        session.select(current: broken.objectID, next: nil, previous: nil)
        do { _ = try await session.image(broken, authorized: { true }) { bytes }; XCTFail("Corrupt photo must fail") } catch { }
        XCTAssertTrue(session.images.isEmpty)
        let item = try sealedPhotoFixture(bytes)
        session.select(current: item.objectID, next: nil, previous: broken.objectID)
        var authorized = true
        let started = expectation(description: "Download in progress")
        var finish: CheckedContinuation<Data, Never>?
        let pending = Task {
            try await session.image(item, authorized: { authorized }) {
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        authorized = false; session.close(); finish?.resume(returning: bytes)
        do { _ = try await pending.value; XCTFail("Late download must not repopulate a closed/relocked viewer") } catch { }
        XCTAssertTrue(session.images.isEmpty)
        XCTAssertTrue(session.errors.isEmpty)
    }
    func testSealedPrefetchPolicyAndCiphertextBudget() throws {
        XCTAssertTrue(PhoneSealedImageSession.allowsPrefetch(satisfied: true, wifi: true, wired: false, expensive: false, constrained: false))
        for policy in [(false, true, false, false, false), (true, false, false, false, false), (true, true, false, true, false), (true, true, false, false, true)] {
            XCTAssertFalse(PhoneSealedImageSession.allowsPrefetch(satisfied: policy.0, wifi: policy.1, wired: policy.2, expensive: policy.3, constrained: policy.4))
        }
        let model = CloudViewerModel()
        model.signedIn = true; model.hiddenPagesOpen = true
        let root = try JSONDecoder().decode(SealedRoot.self, from: JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "keyID": UUID().uuidString, "cipherBytes": 1]))
        let mib: Int64 = 1024 * 1024
        let first = try sealedPhotoFixture(Data(), size: 5 * mib)
        XCTAssertTrue(model.reserveSealedPhotoPrefetch(root, item: first))
        XCTAssertFalse(model.reserveSealedPhotoPrefetch(root, item: first), "Attempted photos are never automatically retried")
        for _ in 0..<8 { XCTAssertTrue(model.reserveSealedPhotoPrefetch(root, item: try sealedPhotoFixture(Data(), size: 5 * mib))) }
        XCTAssertFalse(model.reserveSealedPhotoPrefetch(root, item: try sealedPhotoFixture(Data(), size: 5 * mib)), "Cipher header/tags count toward 50MiB")
        XCTAssertFalse(model.reserveSealedPhotoPrefetch(root, item: try sealedPhotoFixture(Data(), size: 5 * mib + 1)))
        XCTAssertFalse(model.reserveSealedPhotoPrefetch(root, item: try sealedPhotoFixture(Data(), size: 1, mime: "video/mp4")))
        XCTAssertFalse(model.reserveSealedPhotoPrefetch(root, item: try sealedPhotoFixture(Data(), size: 1, mime: "application/pdf")))
        model.relock()
        XCTAssertFalse(model.reserveSealedPhotoPrefetch(root, item: try sealedPhotoFixture(Data(), size: 1)))
        model.signedIn = true; model.hiddenPagesOpen = true
        XCTAssertTrue(model.reserveSealedPhotoPrefetch(root, item: first), "Relocking starts a new bounded unlock session")
    }
    func testSealedPhotoBoundsDecodedPixelsAndEvictsDistantPages() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4200, height: 10), format: format).image { _ in }.pngData())
        let first = try sealedPhotoFixture(bytes), second = try sealedPhotoFixture(bytes), third = try sealedPhotoFixture(bytes)
        let session = PhoneSealedImageSession(monitorNetwork: false)
        session.select(current: first.objectID, next: second.objectID, previous: nil)
        let decoded = try await session.image(first, authorized: { true }) { bytes }
        XCTAssertLessThanOrEqual(try XCTUnwrap(decoded.cgImage).width, 4096)
        _ = try await session.image(second, authorized: { true }) { bytes }
        session.select(current: third.objectID, next: nil, previous: second.objectID)
        XCTAssertNil(session.images[first.objectID])
        XCTAssertNotNil(session.images[second.objectID])
        let used = session.images.values.reduce(0) { $0 + ($1.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) }
        XCTAssertLessThanOrEqual(used, PhoneSealedImageSession.maximumMemoryBytes)
        session.close()
    }

    func testForegroundJoinsPrefetchAndSurvivesPrefetchCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderBatchProtocol.self]
        let auth = Authentication(network: URLSession(configuration: configuration), storage: FixtureRefreshTokens())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); ReaderBatchProtocol.imageDelay = 0 }
        let model = CloudViewerModel(cacheRoot: directory, authentication: auth, networkConfiguration: configuration)
        model.configuration.api = "https://fixture.invalid"; model.configuration.domain = "https://fixture.invalid"
        model.configuration.clientID = "test-client"; model.configuration.owner = UUID().uuidString; model.signedIn = true
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { UIColor.red.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }.pngData())
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        ReaderBatchProtocol.imageData = bytes; ReaderBatchProtocol.imageCount = 0; ReaderBatchProtocol.imageDelay = 0.2
        let catalog = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "id": "catalog", "rootId": "root", "name": "Test",
            "folders": [["id": "folder", "name": "Folder", "parentId": NSNull(), "isLocked": false]],
            "items": ["one", "two"].map { ["id": $0, "name": "Image", "folderId": "folder", "sha256": digest, "mimeType": "image/png", "byteSize": bytes.count, "hasThumbnail": true] as [String: Any] }
        ]))
        model.catalogs[model.catalogKey("root", "catalog")] = catalog
        let entries = catalog.items.map { ReaderEntry(catalog: catalog, item: $0) }
        let prefetch = Task { await model.prefetchSwipeImages(entries, after: 0) }
        try await Task.sleep(nanoseconds: 80_000_000)
        let foreground = Task { try await model.image(catalog, catalog.items[1]) }
        try await Task.sleep(nanoseconds: 20_000_000)
        prefetch.cancel()
        let image = try await foreground.value
        await prefetch.value
        XCTAssertEqual(image.size, try XCTUnwrap(UIImage(data: bytes)).size)
        XCTAssertEqual(ReaderBatchProtocol.imageCount, 1, "Swiping into an in-flight prefetch must reuse its download")
        XCTAssertNotNil(model.pagingPreview(catalog, catalog.items[1]))
        model.relock()
        XCTAssertNil(model.pagingPreview(catalog, catalog.items[1]))
    }

    func testNativePagerCommitsOnlyCompletedTransitionsAndKeepsCurrentPageOnCancellation() throws {
        var selected = 0
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let pager = NativeMediaPager(count: 4, selection: binding) { index, active in Text("\(index)/\(active)") }
        let coordinator = pager.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        coordinator.controller = controller
        let first = try XCTUnwrap(coordinator.page(0)), next = try XCTUnwrap(coordinator.page(1))
        controller.setViewControllers([first], direction: .forward, animated: false)
        coordinator.pageViewController(controller, willTransitionTo: [next])
        XCTAssertEqual(selected, 0)
        XCTAssertEqual(coordinator.activeIndex, 0, "The outgoing media must stay active while dragging")
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [next], transitionCompleted: false)
        XCTAssertEqual(selected, 0)
        XCTAssertTrue(coordinator.page(0) === first, "Cancelled drags must keep the same loaded page")
        controller.setViewControllers([next], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [first], transitionCompleted: true)
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(coordinator.activeIndex, 1)
        XCTAssertNil(coordinator.page(-1)); XCTAssertNil(coordinator.page(4))
        _ = coordinator.page(3)
        coordinator.trim(around: 1)
        XCTAssertTrue(coordinator.pages.keys.allSatisfy { abs($0 - 1) <= 1 })
    }

    func testNativePagerStartsAtSelectedMediaAndZoomOnlyEnablesImagePanWhenEnlarged() throws {
        let pager = NativeMediaPager(count: 5, selection: .constant(3), vertical: true) { index, _ in Text("\(index)") }
        XCTAssertEqual(pager.makeCoordinator().activeIndex, 3)
        var zoomStates: [Bool] = []
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { $0.cgContext.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let zoom = PhoneZoomableImage(image: image, onTap: {}, onZoomChanged: { zoomStates.append($0) })
        let coordinator = zoom.makeCoordinator()
        let scroll = PhoneImageScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.imageView.image = image; scroll.addSubview(scroll.imageView); scroll.delegate = coordinator
        scroll.layoutIfNeeded(); zoomStates = []
        coordinator.scrollViewWillBeginZooming(scroll, with: scroll.imageView)
        scroll.setZoomScale(3, animated: false)
        coordinator.scrollViewDidEndZooming(scroll, with: scroll.imageView, atScale: 3)
        scroll.setZoomScale(1, animated: false)
        coordinator.scrollViewDidEndZooming(scroll, with: scroll.imageView, atScale: 1)
        XCTAssertFalse(scroll.gestureRecognizerShouldBegin(scroll.panGestureRecognizer))
        XCTAssertTrue(zoomStates.contains(true))
        XCTAssertEqual(zoomStates.last, false)
    }

    func testFavoritesShareBetweenDevicesAndFailedWriteDoesNotChangeStar() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FavoriteProtocol.self]
        FavoriteProtocol.entries = []; FavoriteProtocol.failWrite = false
        func device() -> CloudViewerModel {
            let auth = Authentication(network: URLSession(configuration: configuration), storage: FixtureRefreshTokens())
            let model = CloudViewerModel(authentication: auth, networkConfiguration: configuration)
            model.configuration.api = "https://fixture.invalid"; model.configuration.domain = "https://fixture.invalid"
            model.configuration.clientID = "test-client"; model.configuration.owner = UUID().uuidString
            model.signedIn = true
            return model
        }
        let mac = device(), phone = device()
        let ref = FavoriteReference(root: UUID().uuidString, catalog: UUID().uuidString, target: UUID().uuidString, kind: "item")
        await mac.toggleFavorite(ref)
        XCTAssertTrue(mac.isFavorite(ref))
        await phone.refreshFavorites()
        XCTAssertTrue(phone.isFavorite(ref))
        FavoriteProtocol.failWrite = true
        await phone.toggleFavorite(ref)
        XCTAssertTrue(phone.isFavorite(ref))
        XCTAssertFalse(phone.favoriteError.isEmpty)
        FavoriteProtocol.failWrite = false
        await phone.toggleFavorite(ref)
        await mac.refreshFavorites()
        XCTAssertFalse(mac.isFavorite(ref))
        phone.favorites = [ref]
        phone.relock()
        XCTAssertTrue(phone.favorites.isEmpty)
    }

    func testSixteenMiBCatalogDownloadAndCorruptionRejection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReaderBatchProtocol.self]
        let authentication = Authentication(network: URLSession(configuration: configuration), storage: FixtureRefreshTokens())
        let model = CloudViewerModel(authentication: authentication, networkConfiguration: configuration)
        model.configuration.api = "https://fixture.invalid"
        model.configuration.domain = "https://fixture.invalid"
        model.configuration.clientID = "test-client"
        model.configuration.owner = UUID().uuidString
        model.signedIn = true
        let root = try JSONDecoder().decode(ReadRoot.self, from: Data(#"{"id":"catalog","rootId":"root","name":"Large","itemCount":0,"byteSize":0}"#.utf8))
        var value: [String: Any] = ["id": "catalog", "rootId": "root", "name": "Large", "items": [],
                                  "folders": [["id": "folder", "name": "Folder", "parentId": NSNull(), "isLocked": false]]]
        let base = try JSONSerialization.data(withJSONObject: value).count
        value["name"] = "Large" + String(repeating: "x", count: CatalogLimits.maximumBytes - base)
        ReaderBatchProtocol.catalogData = try JSONSerialization.data(withJSONObject: value)
        ReaderBatchProtocol.catalogCount = 0
        ReaderBatchProtocol.corruptCatalog = false
        defer { ReaderBatchProtocol.catalogData = nil; ReaderBatchProtocol.corruptCatalog = false }
        XCTAssertEqual(ReaderBatchProtocol.catalogData?.count, CatalogLimits.maximumBytes)
        let catalog = try await model.catalog(root)
        XCTAssertEqual(catalog.id, "catalog")
        XCTAssertEqual(ReaderBatchProtocol.catalogCount, 16)
        XCTAssertEqual(model.catalogs[model.catalogKey("root", "catalog")]?.name, value["name"] as? String)
        model.relock()
        ReaderBatchProtocol.corruptCatalog = true
        do { _ = try await model.catalog(root); XCTFail("Corrupted chunks must not become a cached catalog") }
        catch { }
        XCTAssertTrue(model.catalogs.isEmpty)
    }

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
        var preparedCounts: [Int] = []
        await model.prefetchSwipeImages(entries, after: 0) {
            preparedCounts.append(ReaderBatchProtocol.imageCount)
            XCTAssertNotNil(model.pagingPreview(catalog, catalog.items[preparedCounts.count * 2]))
        }
        XCTAssertEqual(preparedCounts, Array(1...10), "Publish every image before waiting for the remaining window")
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
    func testSwipePrefetchByteLimitsAndSessionBudget() throws {
        let mib: Int64 = 1024 * 1024
        let sizes: [Int64] = [1, 11 * mib, 10 * mib, 10 * mib, 1, -1, 0]
        let catalog = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "id": "catalog", "rootId": "root", "name": "Test", "folders": [],
            "items": sizes.enumerated().map { index, size in
                ["id": "item-\(index)", "name": "Photo", "folderId": "folder", "sha256": String(repeating: "a", count: 64),
                 "mimeType": "image/png", "byteSize": size, "hasThumbnail": true] as [String: Any]
            }
        ]))
        let entries = catalog.items.map { ReaderEntry(catalog: catalog, item: $0) }
        XCTAssertEqual(ReaderSwipeScreen.upcomingPhotos(entries, after: 0).map { $0.item.id }, ["item-2", "item-3"])
        var budget = ReaderPrefetchBudget()
        XCTAssertFalse(budget.reserve("invalid", bytes: -1))
        for index in 0..<10 { XCTAssertTrue(budget.reserve("id-\(index)", bytes: 10 * mib)) }
        XCTAssertEqual(budget.remainingBytes, 0)
        XCTAssertFalse(budget.reserve("one-more", bytes: 1))
        XCTAssertFalse(budget.reserve("id-0", bytes: 1))
        var repeated = ReaderPrefetchBudget()
        XCTAssertTrue(repeated.reserve("same", bytes: 1))
        XCTAssertFalse(repeated.reserve("same", bytes: 1))
        XCTAssertEqual(repeated.remainingBytes, 100 * mib - 1)
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
        let coordinator = PhoneZoomableImage.Coordinator(PhoneZoomableImage(image: image, onTap: {}))
        scroll.delegate = coordinator
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.imageView.frame.width, 300, accuracy: 0.1)
        XCTAssertEqual(scroll.imageView.frame.height, 150, accuracy: 0.1)
        XCTAssertEqual(scroll.contentInset.top, 225, accuracy: 0.1)
        coordinator.scrollViewDidZoom(scroll)
        XCTAssertFalse(scroll.gestureRecognizerShouldBegin(scroll.panGestureRecognizer))
        scroll.setZoomScale(3, animated: false)
        XCTAssertEqual(scroll.imageView.frame.width, 900, accuracy: 0.1)
        XCTAssertTrue(scroll.gestureRecognizerShouldBegin(scroll.panGestureRecognizer))
        scroll.setZoomScale(1, animated: false)
        XCTAssertFalse(scroll.gestureRecognizerShouldBegin(scroll.panGestureRecognizer))
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
        let restoredPreview = await model.cachedPagingPreview(catalog, catalog.items[0])
        XCTAssertNotNil(restoredPreview, "An inactive neighbor must restore disk cache without a network request")
        var statuses: [String] = []
        let image = try await model.image(catalog, catalog.items[0]) { statuses.append($0) }
        XCTAssertEqual(statuses, ["保存済みの画像を確認中…"], "Cached images must not report a network download")
        XCTAssertEqual(image.size, try XCTUnwrap(UIImage(data: bytes)).size)
        var lockedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        lockedJSON["folders"] = [["id": "folder", "name": "Folder", "parentId": NSNull(), "isLocked": true]]
        model.catalogs[model.catalogKey("root", "catalog")] = try JSONDecoder().decode(ReadCatalog.self, from: JSONSerialization.data(withJSONObject: lockedJSON))
        do { _ = try await model.image(catalog, catalog.items[0]); XCTFail("Locked folder must reject even a memory cache hit") }
        catch ViewerError.unlock { }
        let lockedPreview = await model.cachedPagingPreview(catalog, catalog.items[0])
        XCTAssertNil(lockedPreview, "Neighbor previews must enforce current folder access")
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
    static var imageDelay: TimeInterval = 0
    static var imageData = Data()
    static var catalogData: Data?
    static var catalogCount = 0
    static var corruptCatalog = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        if request.url!.path.contains("oauth2/token") {
            data = Data(#"{"access_token":"test-only-access"}"#.utf8)
        } else if let catalog = Self.catalogData,
                  let offsetText = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "catalogOffset" })?.value,
                  let offset = Int(offsetText) {
            Self.catalogCount += 1
            let end = min(offset + CatalogLimits.chunkBytes, catalog.count)
            var part = catalog.subdata(in: offset..<end)
            if Self.corruptCatalog, end == catalog.count { part[0] ^= 1 }
            let digest = SHA256.hash(data: catalog).map { String(format: "%02x", $0) }.joined()
            data = try! JSONSerialization.data(withJSONObject: [
                "data": part.base64EncodedString(), "offset": offset, "totalBytes": catalog.count,
                "sha256": digest, "nextOffset": end < catalog.count ? end as Any : NSNull()])
        } else if request.url!.path.hasPrefix("/image/") {
            Self.imageCount += 1
            if Self.imageDelay > 0 { Thread.sleep(forTimeInterval: Self.imageDelay) }
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

private final class FavoriteProtocol: URLProtocol {
    static var entries: [FavoriteReference] = []
    static var failWrite = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var status = 200
        let data: Data
        if request.url!.path.contains("oauth2/token") { data = Data(#"{"access_token":"test-only-access"}"#.utf8) }
        else if request.httpMethod == "POST" {
            if Self.failWrite { status = 502; data = Data("{}".utf8) }
            else {
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(buffer, count: count) }
                    body = bytes
                }
                let value = try! JSONSerialization.jsonObject(with: body!) as! [String: Any]
                let ref = try! JSONDecoder().decode(FavoriteReference.self, from: JSONSerialization.data(withJSONObject: value["reference"]!))
                Self.entries.removeAll { $0.identity == ref.identity }
                if value["favorite"] as? Bool == true { Self.entries.append(ref) }
                data = Data(#"{"saved":true}"#.utf8)
            }
        } else { data = try! JSONEncoder().encode(Self.entries) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
