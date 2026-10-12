import XCTest
@testable import PhotoHubCore

final class CoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func sample(_ asset: String = "asset") -> Photo { Photo(assetID: asset, filename: "test.heic", capturedAt: Date(timeIntervalSince1970: 100), mime: "image/heic", bytes: 42, width: 100, height: 100, sha256: asset) }
    func testLegacyPhotoDecodingAndFolderReferencePersistence() throws {
        let legacy = try JSONEncoder().encode(sample())
        XCTAssertNil(try JSONDecoder().decode(Photo.self, from: legacy).folderSource)
        var photo = sample()
        photo.folderSource = FolderSource(rootID: "root", relativePath: "images/test.heic")
        photo.state = .uploaded
        let db = try Repository(url: root.appendingPathComponent("folder.sqlite"))
        try db.save(photo)
        XCTAssertEqual(try db.photos(), [photo])
        // A file-provider reference cannot be restored as an S3 object backup.
        for kind in ImageKind.allCases { photo.keys[kind.rawValue] = ObjectKeys.photo(owner: "owner", id: photo.id, kind: kind) }
        XCTAssertThrowsError(try Backup(owner: "owner", photos: [photo], albums: [], memberships: []).validate(owner: "owner"))
    }
    func testPersistenceRecoveryAndDuplicatePrevention() throws {
        let url = root.appendingPathComponent("db.sqlite")
        do { let db = try Repository(url: url); var photo = sample(); photo.state = .uploading; try db.save(photo); XCTAssertThrowsError(try db.save(sample())); }
        let reopened = try Repository(url: url); try reopened.recoverInterruptedUploads()
        XCTAssertEqual(try reopened.photos().first?.state, .pending)
        var newer = sample("newer"); newer.capturedAt = Date(timeIntervalSince1970: 200); try reopened.save(newer)
        XCTAssertEqual(try reopened.photos().first?.id, newer.id)
    }
    func testAlbumCascadeAndBackupRoundTrip() throws {
        let db = try Repository(url: root.appendingPathComponent("one.sqlite")); var photo = sample(); photo.state = .uploaded; photo.favorite = true
        for kind in ImageKind.allCases { photo.keys[kind.rawValue] = ObjectKeys.photo(owner: "local-development", id: photo.id, kind: kind) }
        try db.save(photo); let album = Album(name: "旅行"); try db.save(album); try db.add(photoID: photo.id, albumID: album.id)
        let backup = try db.snapshot(owner: "local-development")
        let data = try JSONEncoder().encode(backup)
        let restored = try Repository(url: root.appendingPathComponent("two.sqlite")); try restored.restore(JSONDecoder().decode(Backup.self, from: data), owner: "local-development")
        XCTAssertEqual(try restored.photos(), [photo]); XCTAssertEqual(try restored.memberships().count, 1)
        XCTAssertThrowsError(try restored.restore(backup, owner: "local-development"))
        try restored.delete(photoID: photo.id); XCTAssertTrue(try restored.memberships().isEmpty)
    }
    func testInvalidBackupAndForeignKeys() throws {
        let db = try Repository(url: root.appendingPathComponent("db.sqlite"))
        XCTAssertThrowsError(try db.add(photoID: "missing", albumID: "missing"))
        var backup = Backup(owner: "owner", photos: [sample()], albums: [], memberships: [])
        XCTAssertThrowsError(try backup.validate(owner: "owner")); backup.photos = []; backup.schemaVersion = 99
        XCTAssertThrowsError(try backup.validate(owner: "owner")); backup.schemaVersion = 1
        XCTAssertThrowsError(try backup.validate(owner: "other"))
    }
    func testLocalStoreIntegrityIsolationAndIdempotentDelete() async throws {
        let store = try LocalObjectStore(root: root.appendingPathComponent("objects"))
        let source = root.appendingPathComponent("source"); try Data("original bytes".utf8).write(to: source)
        let key = ObjectKeys.photo(owner: store.owner, id: UUID().uuidString, kind: .original)
        let checksum = try Digest.checksum(file: source)
        try await store.put(file: source, key: key, mime: "image/heic", checksum: checksum, progress: { _ in })
        let info = try await store.head(key: key); XCTAssertEqual(info?.checksum, checksum)
        do { try await store.put(file: source, key: key, mime: "image/heic", checksum: "wrong", progress: { _ in }); XCTFail("must reject checksum") } catch {}
        do { _ = try await store.head(key: "users/other/photos/x/original"); XCTFail("must reject other owner") } catch {}
        do { _ = try await store.head(key: "users/local-development/../../escape"); XCTFail("must reject traversal") } catch {}
        try await store.delete(key: key); try await store.delete(key: key)
        let missing = try await store.head(key: key); XCTAssertNil(missing)
    }
    func testUploadAllRepresentationsAndRetryWithoutNewObjects() async throws {
        let store = try LocalObjectStore(root: root.appendingPathComponent("objects"))
        var photo = sample(); let directory = root.appendingPathComponent("pending")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in ImageKind.allCases {
            photo.keys[kind.rawValue] = ObjectKeys.photo(owner: store.owner, id: photo.id, kind: kind)
            try Data(kind.rawValue.utf8).write(to: directory.appendingPathComponent(kind == .original ? "original" : "\(kind.rawValue).jpg"))
        }
        photo.sha256 = try Digest.checksum(file: directory.appendingPathComponent("original")); photo.bytes = try Digest.bytes(file: directory.appendingPathComponent("original"))
        try await PhotoTransfer.upload(photo: photo, directory: directory, store: store, progress: { _ in })
        try await PhotoTransfer.upload(photo: photo, directory: directory, store: store, progress: { _ in })
        for kind in ImageKind.allCases { let info = try await store.head(key: photo.keys[kind.rawValue]!); XCTAssertNotNil(info) }
        try Data("changed".utf8).write(to: directory.appendingPathComponent("display.jpg"))
        do { try await PhotoTransfer.upload(photo: photo, directory: directory, store: store, progress: { _ in }); XCTFail("must reject mismatch") } catch {}
    }
    func testPartialUploadThenRetryKeepsStableID() async throws {
        let store = try LocalObjectStore(root: root.appendingPathComponent("objects"))
        var photo = sample(); let directory = root.appendingPathComponent("pending")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in ImageKind.allCases { photo.keys[kind.rawValue] = ObjectKeys.photo(owner: store.owner, id: photo.id, kind: kind) }
        try Data("original".utf8).write(to: directory.appendingPathComponent("original"))
        photo.sha256 = try Digest.checksum(file: directory.appendingPathComponent("original")); photo.bytes = try Digest.bytes(file: directory.appendingPathComponent("original"))
        do { try await PhotoTransfer.upload(photo: photo, directory: directory, store: store, progress: { _ in }); XCTFail("missing derivative must fail") } catch {}
        let originalBefore = try await store.head(key: photo.keys["original"]!)
        for name in ["thumbnail", "display"] { try Data(name.utf8).write(to: directory.appendingPathComponent(name + ".jpg")) }
        try await PhotoTransfer.upload(photo: photo, directory: directory, store: store, progress: { _ in })
        let originalAfter = try await store.head(key: photo.keys["original"]!)
        XCTAssertEqual(originalBefore?.checksum, originalAfter?.checksum)
    }
    func testAlteredOriginalIsNeverUploaded() async throws {
        let store = try LocalObjectStore(root: root.appendingPathComponent("objects")); var photo = sample()
        let directory = root.appendingPathComponent("pending"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for kind in ImageKind.allCases { photo.keys[kind.rawValue] = ObjectKeys.photo(owner: store.owner, id: photo.id, kind: kind) }
        try Data("altered original".utf8).write(to: directory.appendingPathComponent("original"))
        do { try await PhotoTransfer.upload(photo: photo, directory: directory, store: store, progress: { _ in }); XCTFail("must reject altered original") } catch {}
        let absent = try await store.head(key: photo.keys["original"]!); XCTAssertNil(absent)
    }
    func testTenThousandMetadataRowsRemainSortedAndReadable() throws {
        let db = try Repository(url: root.appendingPathComponent("large.sqlite"))
        let start = Date()
        for index in 0..<10_000 {
            var photo = sample("asset-\(index)"); photo.capturedAt = Date(timeIntervalSince1970: Double(index)); try db.save(photo)
        }
        let loadedAt = Date(), photos = try db.photos(), duration = Date().timeIntervalSince(loadedAt)
        XCTAssertEqual(photos.count, 10_000); XCTAssertEqual(photos.first?.assetID, "asset-9999"); XCTAssertEqual(photos.last?.assetID, "asset-0")
        print("Metadata benchmark: 10000 rows, insert=\(loadedAt.timeIntervalSince(start))s, load=\(duration)s; host-only, no image scrolling claim")
    }
    func testCacheEvictsOldestOnly() throws {
        let cache = try DiskCache(root: root.appendingPathComponent("cache"), limit: 5)
        let old = cache.file(id: "old", kind: .thumbnail), recent = cache.file(id: "recent", kind: .display)
        try Data(repeating: 1, count: 4).write(to: old); try Data(repeating: 2, count: 4).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try cache.trim(); XCTAssertFalse(FileManager.default.fileExists(atPath: old.path)); XCTAssertNotNil(cache.cached(id: "recent", kind: .display))
    }
}
