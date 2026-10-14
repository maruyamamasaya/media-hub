import XCTest
import CryptoKit
import AVFoundation
import AssetLibraryContract
@testable import PhotoHubCore

final class SealedMediaTests: XCTestCase {
    @MainActor
    func testAWSInteroperabilityWhenFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["MEDIA_HUB_SEALED_FIXTURE"] else { throw XCTSkip("Explicit AWS fixture not requested") }
        struct Fixture: Decodable { let root: SealedRoot; let catalogURL: URL; let objectURLs: [String: URL] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // Known synthetic integration-test key, never saved to the user's Keychain.
        let secret = try MediaSecret(keyID: fixture.root.keyID, masterKey: Data(repeating: 0x31, count: 32))
        let catalogHTTP = SealedHTTP { fixture.catalogURL }
        let catalogReader = SealedRangeReader(objectID: fixture.root.id, master: secret.masterKey, maximumLength: 4 * 1024 * 1024) { range in try await catalogHTTP.bytes(range) }
        let catalog = try JSONDecoder().decode(SealedCatalog.self, from: await catalogReader.allData())
        try catalog.validate(root: fixture.root, secret: secret)
        XCTAssertEqual(catalog.name, "SyntheticEncryptionCheck")
        for item in catalog.items {
            let url = try XCTUnwrap(fixture.objectURLs[item.objectID])
            let http = SealedHTTP { url }
            let reader = SealedRangeReader(objectID: item.objectID, master: secret.masterKey, expectedLength: item.byteSize) { range in try await http.bytes(range) }
            if item.mimeType.hasPrefix("video/") {
                let loader = SealedPlayerLoader(reader: reader, mime: item.mimeType)
                let duration = try await loader.asset.load(.duration)
                XCTAssertGreaterThan(duration.seconds, 0); loader.close()
            } else {
                let data = try await reader.allData()
                XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), item.sha256)
            }
            await reader.close()
            if let id = item.thumbnailID, let bytes = item.thumbnailBytes {
                let thumbURL = try XCTUnwrap(fixture.objectURLs[id]); let thumbHTTP = SealedHTTP { thumbURL }
                let thumb = SealedRangeReader(objectID: id, master: secret.masterKey, expectedLength: bytes, maximumLength: 50000) { range in try await thumbHTTP.bytes(range) }
                let data = try await thumb.allData(); XCTAssertEqual(data.prefix(8), Data([137,80,78,71,13,10,26,10])); await thumb.close()
            }
        }
        await catalogReader.close()
    }
    func testRecoveryFilePasswordAndTamperingNeverExposeMasterKey() throws {
        let secret = try MediaSecret(masterKey: Data(repeating: 0x7b, count: 32))
        let file = try RecoveryFile.export(secret, password: "test-password-long-123")
        XCTAssertFalse(String(decoding: file, as: UTF8.self).contains(secret.masterKey.base64EncodedString()))
        let restored = try RecoveryFile.restore(file, password: "test-password-long-123")
        XCTAssertEqual(restored.keyID, secret.keyID); XCTAssertEqual(restored.masterKey, secret.masterKey)
        XCTAssertThrowsError(try RecoveryFile.restore(file, password: "wrong-test-password"))
        XCTAssertThrowsError(try RecoveryFile.export(secret, password: "123456"))
        var values = try JSONSerialization.jsonObject(with: file) as! [String: Any]
        values["rounds"] = 1
        XCTAssertThrowsError(try RecoveryFile.restore(JSONSerialization.data(withJSONObject: values), password: "test-password-long-123"))
    }
    func testChunksBindIdentityOrderHeaderAndKey() throws {
        let id = UUID().uuidString, key = Data(repeating: 0x12, count: 32)
        let header = try SealedMedia.header(length: Int64(SealedMedia.chunkSize + 7), objectID: id)
        let first = Data(repeating: 41, count: SealedMedia.chunkSize), last = Data(repeating: 42, count: 7)
        let cipher = try SealedMedia.sealChunk(first, index: 0, header: header, master: key)
        XCTAssertThrowsError(try SealedMedia.chunkRange(Int.max, header: header))
        XCTAssertThrowsError(try SealedMedia.chunkRange(-1, header: header))
        XCTAssertEqual(try SealedMedia.openChunk(cipher, index: 0, header: header, master: key), first)
        XCTAssertThrowsError(try SealedMedia.openChunk(cipher, index: 0, header: header, master: Data(repeating: 7, count: 32)))
        var damaged = cipher; damaged[50] ^= 1
        XCTAssertThrowsError(try SealedMedia.openChunk(damaged, index: 0, header: header, master: key))
        XCTAssertThrowsError(try SealedMedia.openChunk(cipher.dropLast(), index: 0, header: header, master: key))
        let end = try SealedMedia.sealChunk(last, index: 1, header: header, master: key)
        XCTAssertEqual(try SealedMedia.openChunk(end, index: 1, header: header, master: key), last)
        XCTAssertThrowsError(try SealedMedia.parse(header.data, objectID: UUID().uuidString, length: header.length))
        var changedHeader = header.data; changedHeader[40] ^= 1
        let changed = try SealedMedia.parse(changedHeader, objectID: id, length: header.length)
        XCTAssertThrowsError(try SealedMedia.openChunk(cipher, index: 0, header: changed, master: key))
        let repeated = try SealedMedia.header(length: header.length, objectID: id)
        XCTAssertNotEqual(repeated.data, header.data)
    }
    func testRangeReadsCrossChunkBoundariesAndCloseDropsAccess() async throws {
        let key = Data(repeating: 0x67, count: 32), id = UUID().uuidString
        let plain = Data((0..<(SealedMedia.chunkSize * 2 + 137)).map { UInt8(truncatingIfNeeded: $0) })
        let header = try SealedMedia.header(length: Int64(plain.count), objectID: id)
        var encrypted = header.data
        for index in 0..<3 {
            let start = index * SealedMedia.chunkSize, end = min(plain.count, start + SealedMedia.chunkSize)
            encrypted.append(try SealedMedia.sealChunk(plain.subdata(in: start..<end), index: index, header: header, master: key))
        }
        let all = encrypted
        let reader = SealedRangeReader(objectID: id, master: key, expectedLength: Int64(plain.count)) { range in
            XCTAssertLessThanOrEqual(range.count, SealedMedia.chunkSize + 16)
            return all.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        let offset = SealedMedia.chunkSize - 10
        let crossing = try await reader.read(offset: Int64(offset), count: 100)
        XCTAssertEqual(crossing, plain.subdata(in: offset..<(offset + 100)))
        let tail = try await reader.read(offset: Int64(plain.count - 20), count: 100)
        XCTAssertEqual(tail, plain.suffix(20))
        let result = try await reader.allData(); XCTAssertEqual(result, plain)
        await reader.close()
        do { _ = try await reader.read(offset: 0, count: 1); XCTFail("Closed reader must reject access") } catch { }
    }
    @MainActor
    func testEncryptedVideoLoadsDurationThroughRangeDecryptor() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("sample.mp4"), output = directory.appendingPathComponent("encrypted.bin")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x64:d=0.3", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-y", input.path]
        process.standardError = FileHandle.nullDevice; try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let key = Data(repeating: 0x27, count: 32), id = UUID().uuidString
        _ = try SealedMedia.encryptFile(input, output: output, objectID: id, master: key)
        let ciphertext = try Data(contentsOf: output), length = Int64(try Data(contentsOf: input).count)
        let reader = SealedRangeReader(objectID: id, master: key, expectedLength: length) { range in ciphertext.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
        let loader = SealedPlayerLoader(reader: reader, mime: "video/mp4")
        let duration = try await loader.asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        loader.close()
    }
}
