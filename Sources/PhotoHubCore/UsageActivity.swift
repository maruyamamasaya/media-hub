import Foundation
import CryptoKit

public struct UsageActivity: Codable, Sendable, Identifiable {
    public var id: String { date }
    public let date: String
    public var requests: Int64
    public var receivedBytes: Int64
    public var videoStarts: Int64
    public init(date: String, requests: Int64 = 0, receivedBytes: Int64 = 0, videoStarts: Int64 = 0) {
        self.date = date; self.requests = requests; self.receivedBytes = receivedBytes; self.videoStarts = videoStarts
    }
}

/// Aggregate totals only. No media identifiers, URLs, names, tokens, or keys.
public final class UsageActivityStore: @unchecked Sendable {
    public static let shared = UsageActivityStore()
    private let defaults: UserDefaults
    private let lock = NSLock()
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ scope: String) -> String {
        "mediaHubUsage-" + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func history(scope: String) -> [UsageActivity] {
        lock.lock(); defer { lock.unlock() }
        return read(scope)
    }
    private func read(_ scope: String) -> [UsageActivity] {
        guard let data = defaults.data(forKey: key(scope)) else { return [] }
        return (try? JSONDecoder().decode([UsageActivity].self, from: data)) ?? []
    }
    public func record(scope: String, requests: Int64 = 0, receivedBytes: Int64 = 0, videoStarts: Int64 = 0, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Tokyo"); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        var values = read(scope)
        var value = values.first { $0.date == day } ?? UsageActivity(date: day)
        value.requests += max(0, requests); value.receivedBytes += max(0, receivedBytes); value.videoStarts += max(0, videoStarts)
        values.removeAll { $0.date == day }; values.append(value)
        values = Array(values.sorted { $0.date < $1.date }.suffix(90))
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key(scope)) }
    }
}

/// URLSession transaction metrics count network exchanges, including retries and errors.
public final class UsageNetworkObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let scope: String
    public init(scope: String) { self.scope = scope }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let remote = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad && $0.request.url?.scheme == "https" }
        UsageActivityStore.shared.record(scope: scope, requests: Int64(remote.count), receivedBytes: remote.reduce(0) { $0 + max(0, $1.countOfResponseBodyBytesReceived) })
    }
}

/// Each access-log entry reports an accumulating count; only persist new bytes.
public struct UsagePlayerDelta {
    private var maxima: [Int64] = []
    public init() {}
    public mutating func update(_ totals: [Int64]) -> Int64 {
        var delta: Int64 = 0
        for (index, total) in totals.enumerated() {
            if index == maxima.count { maxima.append(0) }
            guard total > maxima[index] else { continue }
            delta += total - maxima[index]
            maxima[index] = total
        }
        return delta
    }
}
