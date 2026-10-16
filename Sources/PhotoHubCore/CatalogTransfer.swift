import Foundation
import CryptoKit

public enum CatalogLimits {
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumEncryptedBytes = maximumBytes + 60 + ((maximumBytes + chunkBytes - 1) / chunkBytes) * 16
    public static let maximumResponseBytes = 20 * 1024 * 1024
    public static let chunkBytes = 1024 * 1024
}

public struct CatalogChunk: Decodable {
    public let data: Data
    public let offset: Int
    public let totalBytes: Int
    public let sha256: String
    public let nextOffset: Int?
}

/// Assembles only a complete, bounded, single-revision public catalog in memory.
public struct CatalogDownload {
    public private(set) var data = Data()
    public private(set) var digest: String?
    public private(set) var nextOffset: Int? = 0
    private var totalBytes: Int?

    public init() {}

    public mutating func append(_ chunk: CatalogChunk) throws {
        guard nextOffset == chunk.offset, chunk.offset == data.count,
              chunk.totalBytes > 0, chunk.totalBytes <= CatalogLimits.maximumResponseBytes,
              chunk.sha256.count == 64, chunk.sha256.allSatisfy({ $0.isHexDigit }),
              totalBytes == nil || totalBytes == chunk.totalBytes,
              digest == nil || digest == chunk.sha256,
              chunk.offset < chunk.totalBytes,
              chunk.data.count == min(CatalogLimits.chunkBytes, chunk.totalBytes - chunk.offset)
        else { throw SealedError.invalid }
        let end = chunk.offset + chunk.data.count
        guard chunk.nextOffset == (end < chunk.totalBytes ? end : nil) else { throw SealedError.invalid }
        data.append(chunk.data)
        digest = chunk.sha256; totalBytes = chunk.totalBytes; nextOffset = chunk.nextOffset
        if nextOffset == nil {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == digest else { throw SealedError.invalid }
        }
    }
}
