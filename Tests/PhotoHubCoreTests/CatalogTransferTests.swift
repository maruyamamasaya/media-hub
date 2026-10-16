import XCTest
import CryptoKit
@testable import PhotoHubCore

final class CatalogTransferTests: XCTestCase {
    private func chunk(_ bytes: Data, offset: Int, digest: String? = nil, total: Int? = nil, next: Int? = nil) throws -> CatalogChunk {
        let end = min(offset + CatalogLimits.chunkBytes, bytes.count)
        let sha = digest ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try JSONDecoder().decode(CatalogChunk.self, from: JSONSerialization.data(withJSONObject: [
            "data": bytes.subdata(in: offset..<end).base64EncodedString(), "offset": offset,
            "totalBytes": total ?? bytes.count, "sha256": sha,
            "nextOffset": (next ?? (end < bytes.count ? end : nil)) as Any? ?? NSNull()
        ]))
    }

    func testSixteenMiBChunksAndIntegrity() throws {
        let bytes = Data(repeating: 0x61, count: CatalogLimits.maximumBytes)
        var download = CatalogDownload()
        while let offset = download.nextOffset { try download.append(chunk(bytes, offset: offset)) }
        XCTAssertEqual(download.data, bytes)
        XCTAssertNil(download.nextOffset)
        XCTAssertThrowsError(try download.append(chunk(bytes, offset: 0)))
    }

    func testMixedRevisionOrderSizeAndCorruptionRejected() throws {
        let bytes = Data(repeating: 0x61, count: CatalogLimits.chunkBytes + 10)
        var download = CatalogDownload()
        XCTAssertThrowsError(try download.append(chunk(bytes, offset: CatalogLimits.chunkBytes)))
        XCTAssertThrowsError(try download.append(chunk(bytes, offset: 0, total: CatalogLimits.maximumResponseBytes + 1)))
        XCTAssertThrowsError(try download.append(chunk(bytes, offset: 0, next: 1)))
        try download.append(chunk(bytes, offset: 0))
        XCTAssertThrowsError(try download.append(chunk(bytes, offset: CatalogLimits.chunkBytes, digest: String(repeating: "b", count: 64))))
        var damaged = CatalogDownload()
        XCTAssertThrowsError(try damaged.append(chunk(Data([1, 2, 3]), offset: 0, digest: String(repeating: "a", count: 64))))
    }

    func testEncryptedSixteenMiBCatalogAndOneByteOver() async throws {
        let key = Data(repeating: 0x31, count: 32), id = UUID().uuidString
        let plain = Data(repeating: 0x61, count: CatalogLimits.maximumBytes)
        let header = try SealedMedia.header(length: Int64(plain.count), objectID: id)
        var cipher = header.data
        for index in 0..<16 {
            let start = index * SealedMedia.chunkSize
            cipher.append(try SealedMedia.sealChunk(plain.subdata(in: start..<(start + SealedMedia.chunkSize)), index: index, header: header, master: key))
        }
        XCTAssertEqual(cipher.count, CatalogLimits.maximumEncryptedBytes)
        let encrypted = cipher
        let reader = SealedRangeReader(objectID: id, master: key, maximumLength: Int64(CatalogLimits.maximumBytes)) { range in
            encrypted.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
        }
        let restored = try await reader.allData(maximumBytes: Int64(CatalogLimits.maximumBytes))
        XCTAssertEqual(restored, plain)
        await reader.close()
        let overHeader = try SealedMedia.header(length: Int64(plain.count + 1), objectID: id)
        let over = SealedRangeReader(objectID: id, master: key, maximumLength: Int64(CatalogLimits.maximumBytes)) { _ in overHeader.data }
        do { _ = try await over.allData(); XCTFail("Over-limit catalog must fail before fetching content") }
        catch SealedError.invalid { }
        await over.close()
    }
}
