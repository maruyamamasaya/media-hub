import Foundation
import AVFoundation
import UniformTypeIdentifiers

public actor SealedHTTP {
    private let network: URLSession
    private let provider: @Sendable () async throws -> URL
    private var current: URL?
    private var expires = Date.distantPast
    public init(usageScope: String? = nil, provider: @escaping @Sendable () async throws -> URL) {
        self.provider = provider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 120
        network = URLSession(configuration: configuration, delegate: usageScope.map { UsageNetworkObserver(scope: $0) }, delegateQueue: nil)
    }
    public func bytes(_ range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.count > 0, range.count <= SealedMedia.chunkSize + 16 else { throw SealedError.invalid }
        for attempt in 0..<2 {
            if current == nil || expires < Date() { current = try await provider(); expires = Date().addingTimeInterval(240) }
            guard let url = current, url.scheme == "https", url.host?.hasSuffix(".amazonaws.com") == true, url.user == nil, url.password == nil else { throw SealedError.invalid }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            let data: Data, response: URLResponse
            do { (data, response) = try await network.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw SealedError.invalid }
            guard let response = response as? HTTPURLResponse else { throw SealedError.invalid }
            if [401, 403].contains(response.statusCode), attempt == 0 { current = nil; continue }
            guard response.statusCode == 206, data.count == range.count,
                  response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(range.lowerBound)-\(range.upperBound - 1)/") == true else { throw SealedError.invalid }
            return data
        }
        throw SealedError.invalid
    }
}
public actor SealedRangeReader {
    private let objectID: String
    private let master: Data
    private let expectedLength: Int64?
    private let maximumLength: Int64
    private let fetch: @Sendable (Range<Int64>) async throws -> Data
    private var header: SealedMedia.Header?
    private var chunks: [Int: Data] = [:]
    private var order: [Int] = []
    private var closed = false
    public init(objectID: String, master: Data, expectedLength: Int64? = nil, maximumLength: Int64 = 5 * 1024 * 1024 * 1024,
                fetch: @escaping @Sendable (Range<Int64>) async throws -> Data) {
        self.objectID = objectID; self.master = master; self.expectedLength = expectedLength
        self.maximumLength = maximumLength; self.fetch = fetch
    }
    private func prepare() async throws -> SealedMedia.Header {
        guard !closed else { throw CancellationError() }
        if let header { return header }
        let data = try await fetch(0..<Int64(SealedMedia.headerSize))
        guard data.count == SealedMedia.headerSize else { throw SealedError.invalid }
        let length = data.suffix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= UInt64(maximumLength), expectedLength == nil || length == UInt64(expectedLength!) else { throw SealedError.invalid }
        let value = try SealedMedia.parse(data, objectID: objectID, length: Int64(length))
        guard !closed, !Task.isCancelled else { throw CancellationError() }
        header = value; return value
    }
    public func length() async throws -> Int64 { try await prepare().length }
    public func read(offset: Int64, count: Int) async throws -> Data {
        let header = try await prepare()
        guard offset >= 0, offset <= header.length, count >= 0, count <= SealedMedia.chunkSize else { throw SealedError.invalid }
        let end = min(header.length, offset + Int64(count))
        var cursor = offset, result = Data()
        while cursor < end {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let index = Int(cursor / Int64(SealedMedia.chunkSize))
            let plain: Data
            if let cached = chunks[index] { plain = cached }
            else {
                let encrypted = try await fetch(SealedMedia.chunkRange(index, header: header))
                plain = try SealedMedia.openChunk(encrypted, index: index, header: header, master: master)
                guard !closed, !Task.isCancelled else { throw CancellationError() }
                chunks[index] = plain; order.removeAll { $0 == index }; order.append(index)
                while order.count > 2 { chunks.removeValue(forKey: order.removeFirst()) }
            }
            let start = Int(cursor % Int64(SealedMedia.chunkSize))
            let amount = min(plain.count - start, Int(end - cursor))
            guard amount > 0 else { throw SealedError.invalid }
            result.append(plain.subdata(in: start..<(start + amount))); cursor += Int64(amount)
        }
        return result
    }
    public func allData() async throws -> Data {
        let size = try await length()
        guard size <= 100 * 1024 * 1024 else { throw SealedError.tooLarge }
        var bytes = Data(), cursor: Int64 = 0
        while cursor < size {
            let part = try await read(offset: cursor, count: Int(min(Int64(SealedMedia.chunkSize), size - cursor)))
            bytes.append(part); cursor += Int64(part.count)
        }
        return bytes
    }
    public func close() { closed = true; chunks = [:]; order = []; header = nil }
}
/// A retained loader decrypts bounded ranges in memory. AVPlayer never receives an S3 ciphertext URL.
@MainActor
public final class SealedPlayerLoader: NSObject, AVAssetResourceLoaderDelegate {
    public let asset: AVURLAsset
    private let reader: SealedRangeReader
    private let mime: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    public init(reader: SealedRangeReader, mime: String) {
        self.reader = reader; self.mime = mime
        asset = AVURLAsset(url: URL(string: "mediahub-sealed://\(UUID().uuidString)/media")!)
        super.init(); asset.resourceLoader.setDelegate(self, queue: .main)
    }
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(request)
        tasks[id] = Task { [weak self] in
            guard let self else { request.finishLoading(with: SealedError.invalid); return }
            defer { tasks.removeValue(forKey: id) }
            do {
                let size = try await reader.length()
                // Authenticate a chunk before presenting even the content information.
                _ = try await reader.read(offset: 0, count: 1)
                if let info = request.contentInformationRequest {
                    info.contentType = UTType(mimeType: mime)?.identifier ?? UTType.movie.identifier
                    info.contentLength = size; info.isByteRangeAccessSupported = true
                }
                if let data = request.dataRequest {
                    guard data.requestedOffset >= 0, data.requestedLength >= 0, data.currentOffset >= 0 else { throw SealedError.invalid }
                    var offset = max(data.requestedOffset, data.currentOffset)
                    let end = data.requestsAllDataToEndOfResource || data.requestedOffset >= size ? size : data.requestedOffset + min(size - data.requestedOffset, Int64(data.requestedLength))
                    while offset < end {
                        try Task.checkCancellation()
                        let bytes = try await reader.read(offset: offset, count: Int(min(Int64(SealedMedia.chunkSize), end - offset)))
                        guard !Task.isCancelled, !request.isCancelled else { throw CancellationError() }
                        data.respond(with: bytes); offset += Int64(bytes.count)
                    }
                }
                if !request.isCancelled { request.finishLoading() }
            } catch { if !request.isCancelled { request.finishLoading(with: error) } }
        }
        return true
    }
    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    public func close() { for task in tasks.values { task.cancel() }; tasks = [:]; Task { await reader.close() } }
}
