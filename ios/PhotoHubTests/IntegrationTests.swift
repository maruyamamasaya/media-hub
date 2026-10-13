import XCTest
import UIKit
import ImageIO
import AVFoundation
import PhotoHubCore
@testable import PhotoHub

@MainActor
final class IntegrationTests: XCTestCase {
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
