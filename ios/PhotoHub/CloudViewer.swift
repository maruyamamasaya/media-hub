import SwiftUI
import AVKit
import CryptoKit
import AssetLibraryContract
import PhotoHubCore

extension ReadRoot: Identifiable {}
extension ReadItem: Identifiable {}
extension MediaFolder: Identifiable {}

@MainActor
final class CloudViewerModel: ObservableObject {
    @Published var roots: [ReadRoot] = []
    @Published var error = ""
    @Published var busy = false
    @Published var signedIn = false
    @Published private(set) var restoringLogin = false
    private var attemptedRestore = false
    @Published var configuration: CloudConfiguration
    private let authentication: Authentication
    private var network: URLSession!
    var usageScope: String { configuration.api + "|" + configuration.owner }
    func usageReport() async throws -> UsageReport { try await get("/usage", as: UsageReport.self) }
    @Published var favorites: [FavoriteReference] = []
    @Published var favoriteError = ""
    @Published var favoriteBusy = false
    func favorite(_ catalog: ReadCatalog, target: String, kind: String) -> FavoriteReference {
        FavoriteReference(root: catalog.rootId, catalog: catalog.id, target: target, kind: kind)
    }
    func isFavorite(_ ref: FavoriteReference) -> Bool { favorites.contains { $0.identity == ref.identity } }
    func refreshFavorites() async {
        let identity = sessionID
        do {
            let value = try await get("/favorites", as: [FavoriteReference].self)
            guard identity == sessionID else { return }
            favorites = value; favoriteError = ""
        } catch { if identity == sessionID { favoriteError = "お気に入りを更新できません。接続を確認して再試行してください。" } }
    }
    func toggleFavorite(_ ref: FavoriteReference) async {
        guard !favoriteBusy else { return }
        favoriteBusy = true
        defer { favoriteBusy = false }
        let identity = sessionID, active = !isFavorite(ref)
        struct Saved: Decodable { let saved: Bool }
        do {
            let data = try JSONSerialization.data(withJSONObject: ref.updateBody(active: active))
            let result = try await get("/favorites", as: Saved.self, method: "POST", body: data)
            guard result.saved, identity == sessionID else { return }
            favorites.removeAll { $0.identity == ref.identity }
            if active { favorites.append(ref) }
            favoriteError = ""
        } catch { if identity == sessionID { favoriteError = "お気に入りを保存できません。接続を確認して再試行してください。" } }
    }
    func recordVideoStart() { UsageActivityStore.shared.record(scope: usageScope, videoStarts: 1) }
    private let sealedRequests = SealedRequestGate()
    private var swipePrefetchBudget = ReaderPrefetchBudget()
    private var sealedPhotoPrefetchBudget = ReaderPrefetchBudget(maximumBytes: 50 * 1024 * 1024)
    // Only ordinary reader images enter this cache; sealed media uses a separate reader.
    private let images = NSCache<NSString, UIImage>()
    private var imageCacheGeneration = UUID()
    private var imageLoads: [String: (UUID, Task<UIImage, Error>)] = [:]
    private var imageWaiters: [String: Set<UUID>] = [:]
    private var imageLoadStatuses: [String: String] = [:]
    private var imageLoadObservers: [String: [UUID: (String) -> Void]] = [:]
    private func reportImageStatus(_ status: String, key: String) {
        imageLoadStatuses[key] = status
        for observer in imageLoadObservers[key]?.values ?? [:].values { observer(status) }
    }
    private let cacheRoot: URL?
    private lazy var imageCache = ReaderImageDiskStore(
        root: cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudReaderImages", isDirectory: true), generation: imageCacheGeneration)
    private func imageCacheID(_ catalog: ReadCatalog, _ item: ReadItem) -> String {
        let components = [configuration.api, configuration.owner, configuration.clientID,
                          catalog.rootId, catalog.id, item.id, item.sha256]
        let data = (try? JSONEncoder().encode(components)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func clearImageCache() {
        let cache = imageCache
        imageCacheGeneration = UUID()
        images.removeAllObjects()
        for (_, task) in imageLoads.values { task.cancel() }
        imageLoads = [:]; imageWaiters = [:]; imageLoadObservers = [:]; imageLoadStatuses = [:]
        let generation = imageCacheGeneration
        Task { await cache.clear(generation: generation) }
    }
    @Published var catalogs: [String: ReadCatalog] = [:]
    private var catalogDates: [String: Date] = [:]
    private var catalogUpdates: [String: UUID] = [:]
    func catalogKey(_ rootID: String, _ id: String) -> String { "\(rootID)/\(id)" }
    private func updateCatalog(_ root: ReadRoot) {
        let key = catalogKey(root.rootId, root.id)
        guard catalogUpdates[key] == nil,
              Date().timeIntervalSince(catalogDates[key] ?? .distantPast) >= 30 else { return }
        let identity = sessionID, update = UUID()
        catalogUpdates[key] = update
        catalogDates[key] = Date()
        Task {
            defer { if catalogUpdates[key] == update { catalogUpdates[key] = nil } }
            do {
                let value = try await fetchCatalog(key)
                guard identity == sessionID else { return }
                catalogs[key] = value; catalogDates[key] = Date()
            } catch is CancellationError { }
            catch { /* Keep cached content through temporary network failures. */ }
        }
    }
    private func requireCachedAccess(_ catalog: ReadCatalog, _ item: ReadItem) throws {
        guard signedIn,
              let current = catalogs[catalogKey(catalog.rootId, catalog.id)],
              current.items.contains(where: { $0.id == item.id && $0.sha256 == item.sha256 && $0.folderId == item.folderId }) else { throw ViewerError.login }
        var folderID: String? = item.folderId
        var visited = Set<String>()
        while let id = folderID, visited.insert(id).inserted {
            guard let folder = current.folders.first(where: { $0.id == id }) else { throw ViewerError.unlock }
            if folder.isLocked && !hasFolderUnlock { throw ViewerError.unlock }
            folderID = folder.parentId
        }
    }
    private struct ThumbnailURLs: Decodable { let urls: [String: String]; let expiresIn: Int }
    private var thumbnailBatches: [String: (Date, Task<ThumbnailURLs, Error>)] = [:]
    private var lockRevision: String?
    @Published var hiddenPagesOpen = false
    @Published private(set) var hasFolderUnlock = false
    private var folderToken: String?
    private var folderTimer: Timer?
    func relock() {
        swipePrefetchBudget = ReaderPrefetchBudget()
        sealedPhotoPrefetchBudget = ReaderPrefetchBudget(maximumBytes: 50 * 1024 * 1024)
        images.removeAllObjects()
        for (_, task) in imageLoads.values { task.cancel() }
        imageLoads = [:]; imageWaiters = [:]; imageLoadObservers = [:]; imageLoadStatuses = [:]
        for (_, task) in thumbnailBatches.values { task.cancel() }
        thumbnailBatches = [:]
        favorites = []
        catalogs = [:]; catalogDates = [:]; catalogUpdates = [:]
        folderTimer?.invalidate(); folderTimer = nil; folderToken = nil; hasFolderUnlock = false; hiddenPagesOpen = false; roots = []; sessionID = UUID()
    }
    func unlockFolder(_ password: String) async throws {
        let result = try await get("/folder-unlock", as: FolderUnlock.self, method: "POST", body: try JSONSerialization.data(withJSONObject: ["password": password]))
        folderToken = result.token; hasFolderUnlock = true; sessionID = UUID()
        folderTimer?.invalidate()
        let identity = sessionID
        let timer = Timer(timeInterval: Double(result.expiresIn), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionID == identity else { return }
                self.relock(); await self.refresh()
            }
        }
        folderTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        await refresh()
    }
    private var accessToken: String?
    private var accessDeadline = Date.distantPast
    @Published private(set) var sessionID = UUID()
    init(cacheRoot: URL? = nil, authentication: Authentication? = nil, networkConfiguration: URLSessionConfiguration? = nil) {
        self.authentication = authentication ?? Authentication()
        self.cacheRoot = cacheRoot
        images.totalCostLimit = 64 * 1024 * 1024
        configuration = UserDefaults.standard.data(forKey: "readerConfiguration").flatMap { try? JSONDecoder().decode(CloudConfiguration.self, from: $0) } ?? CloudConfiguration()
        if let values = Bundle.main.infoDictionary?["MediaHubReader"] as? [String: String], !configuration.valid {
            configuration.api = values["api"] ?? ""
            configuration.domain = values["domain"] ?? ""
            configuration.clientID = values["clientID"] ?? ""
            configuration.owner = values["owner"] ?? ""
        }
        network = URLSession(configuration: networkConfiguration ?? .ephemeral, delegate: UsageNetworkObserver(scope: usageScope), delegateQueue: nil)
    }
    func signOut() {
        relock(); clearImageCache(); lockRevision = nil
        authentication.signOut(configuration)
        sessionID = UUID()
        accessToken = nil
        accessDeadline = .distantPast
        signedIn = false
        roots = []
        error = ""
        URLCache.shared.removeAllCachedResponses()
    }
    func saveConfiguration(_ value: CloudConfiguration) {
        signOut()
        configuration = value
        network.finishTasksAndInvalidate()
        network = URLSession(configuration: .ephemeral, delegate: UsageNetworkObserver(scope: usageScope), delegateQueue: nil)
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "readerConfiguration") }
    }
    func restoreLogin() async {
        guard !attemptedRestore, configuration.valid else { return }
        attemptedRestore = true; restoringLogin = true
        defer { restoringLogin = false }
        let identity = sessionID
        do {
            let token = try await authentication.token(configuration)
            guard identity == sessionID else { return }
            accessToken = token; accessDeadline = Date().addingTimeInterval(240)
            signedIn = true; await refresh()
        } catch StoredSessionError.missing { }
        catch StoredSessionError.expired {
            if identity == sessionID { error = "ログインの有効期限が切れました。本人ログインしてください。" }
        } catch {
            if identity == sessionID { self.error = "ログインを復帰できません。通信を確認して再試行してください。" }
        }
    }
    func login() async {
        busy = true; error = ""
        defer { busy = false }
        do {
            let identity = sessionID
            do {
                let token = try await authentication.token(configuration)
                guard identity == sessionID else { return }
                accessToken = token; accessDeadline = Date().addingTimeInterval(240)
            } catch StoredSessionError.missing {
                try await authentication.login(configuration)
            } catch StoredSessionError.expired {
                try await authentication.login(configuration)
            }
            guard identity == sessionID else { return }
            signedIn = true; await refresh()
        }
        catch { self.error = "ログインできませんでした。接続設定と本人アカウントを確認してください。" }
    }
    private func get<T: Decodable>(_ path: String, as type: T.Type, method: String = "GET", body: Data? = nil) async throws -> T {
        guard configuration.valid, signedIn else { throw ViewerError.login }
        let identity = sessionID
        if accessToken == nil || Date() >= accessDeadline {
            let token = try await authentication.token(configuration)
            guard identity == sessionID else { throw CancellationError() }
            accessToken = token; accessDeadline = Date().addingTimeInterval(240)
        }
        guard let url = URL(string: configuration.api.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else { throw ViewerError.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let folderToken { request.setValue(folderToken, forHTTPHeaderField: "X-Folder-Unlock") }
        request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
        let (data, response) = try await network.data(for: request)
        guard identity == sessionID else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw ViewerError.connection }
        if let revision = response.value(forHTTPHeaderField: "X-Folder-Lock-Revision") {
            if let previous = lockRevision, previous != revision {
                lockRevision = revision; relock()
                Task { await refresh() }
                throw CancellationError()
            }
            lockRevision = revision
        }
        if path == "/folder-unlock" && response.statusCode != 200 { throw ViewerError.unlock }
        if response.statusCode == 401 || response.statusCode == 403 {
            accessToken = nil; relock()
            throw ViewerError.login
        }
        if response.statusCode == 404, path.hasPrefix("/catalogs/") {
            relock(); Task { await refresh() }; throw ViewerError.connection
        }
        guard response.statusCode == 200, data.count <= 5 * 1024 * 1024 else { throw ViewerError.connection }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func fetchCatalog(_ key: String) async throws -> ReadCatalog {
        let identity = sessionID
        var download = CatalogDownload()
        while let offset = download.nextOffset {
            try Task.checkCancellation()
            let digest = download.digest.map { "&catalogDigest=\($0)" } ?? ""
            let chunk = try await get("/catalogs/\(key)?catalogOffset=\(offset)\(digest)", as: CatalogChunk.self)
            guard identity == sessionID else { throw CancellationError() }
            try download.append(chunk)
        }
        return try JSONDecoder().decode(ReadCatalog.self, from: download.data)
    }
    func refresh() async {
        error = ""
        do {
            let identity = sessionID
            let value = try await get("/library", as: [ReadRoot].self)
            guard identity == sessionID else { return }
            roots = value
            let keys = Set(value.map { catalogKey($0.rootId, $0.id) })
            catalogs = catalogs.filter { keys.contains($0.key) }
            for root in value where catalogs[catalogKey(root.rootId, root.id)] != nil { updateCatalog(root) }
            await refreshFavorites()
        }
        catch is CancellationError { }
        catch { self.error = "フォルダを取得できません。ログイン・接続設定・通信を確認してください。" }
    }
    func catalog(_ root: ReadRoot) async throws -> ReadCatalog {
        guard signedIn else { throw ViewerError.login }
        let key = catalogKey(root.rootId, root.id)
        if let cached = catalogs[key] { updateCatalog(root); return cached }
        let identity = sessionID
        try await sealedRequests.wait()
        guard identity == sessionID else { throw CancellationError() }
        let value = try await fetchCatalog(key)
        guard identity == sessionID else { throw CancellationError() }
        catalogs[key] = value; catalogDates[key] = Date()
        return value
    }
    func reserveSealedPhotoPrefetch(_ root: SealedRoot, item: SealedItem) -> Bool {
        guard signedIn, hiddenPagesOpen, item.mimeType.hasPrefix("image/"),
              item.byteSize > 0, item.byteSize <= 5 * 1024 * 1024 else { return false }
        let chunks = (item.byteSize + Int64(SealedMedia.chunkSize) - 1) / Int64(SealedMedia.chunkSize)
        let encryptedBytes = item.byteSize + Int64(SealedMedia.headerSize) + chunks * 16
        return sealedPhotoPrefetchBudget.reserve("\(root.keyID)/\(root.id)/\(item.objectID)/\(item.sha256)", bytes: encryptedBytes)
    }
    func encryptedRoots() async throws -> [SealedRoot] {
        guard hiddenPagesOpen else { throw CancellationError() }
        let identity = sessionID; try await sealedRequests.wait()
        guard identity == sessionID, hiddenPagesOpen else { throw CancellationError() }
        return try await get("/encrypted-library", as: [SealedRoot].self)
    }
    func encryptedURL(_ root: SealedRoot, objectID: String?) async throws -> URL {
        guard hiddenPagesOpen else { throw CancellationError() }
        let identity = sessionID; try await sealedRequests.wait()
        guard identity == sessionID else { throw CancellationError() }
        let path = objectID.map { "/encrypted-objects/\(root.keyID)/\(root.id)/\($0)/url" } ?? "/encrypted-catalogs/\(root.keyID)/\(root.id)/url"
        let value = try await get(path, as: ReadURL.self)
        guard let url = URL(string: value.url), url.scheme == "https", url.host?.hasSuffix(".amazonaws.com") == true, url.user == nil, url.password == nil else { throw ViewerError.configuration }
        return url
    }
    func mediaURL(_ catalog: ReadCatalog, _ item: ReadItem, thumbnail: Bool = false) async throws -> URL {
        if thumbnail {
            try requireCachedAccess(catalog, item)
            let candidates = catalog.items.filter { $0.folderId == item.folderId && $0.hasThumbnail }
            guard let index = candidates.firstIndex(where: { $0.id == item.id }) else { throw ViewerError.connection }
            let first = (index / 60) * 60
            let ids = candidates[first..<min(first + 60, candidates.count)].map(\.id)
            let signature = candidates[first..<min(first + 60, candidates.count)].map { $0.id + $0.sha256 }.joined()
            let key = catalogKey(catalog.rootId, catalog.id) + "/" + signature
            let identity = sessionID
            let task: Task<ThumbnailURLs, Error>
            if let (deadline, pending) = thumbnailBatches[key], Date() < deadline {
                task = pending
            } else {
                task = Task {
                    try await sealedRequests.wait()
                    guard identity == sessionID else { throw CancellationError() }
                    return try await get("/catalogs/\(catalog.rootId)/\(catalog.id)?thumbnailIds=\(ids.joined(separator: ","))", as: ThumbnailURLs.self)
                }
                thumbnailBatches[key] = (Date().addingTimeInterval(240), task)
            }
            let value: ThumbnailURLs
            do { value = try await task.value }
            catch { if identity == sessionID { thumbnailBatches[key] = nil }; throw error }
            try Task.checkCancellation()
            guard identity == sessionID else { throw CancellationError() }
            try requireCachedAccess(catalog, item)
            guard let raw = value.urls[item.id], let url = URL(string: raw), url.scheme == "https",
                  url.host?.hasSuffix(".amazonaws.com") == true, url.user == nil, url.password == nil else { throw ViewerError.configuration }
            return url
        }
        try await sealedRequests.wait()
        try Task.checkCancellation()
        let value = try await get("/catalogs/\(catalog.rootId)/\(catalog.id)/items/\(item.id)/url?role=\(thumbnail ? "thumbnail" : "original")", as: ReadURL.self)
        guard let url = URL(string: value.url), url.scheme == "https", let host = url.host,
              host.hasSuffix(".amazonaws.com"), url.user == nil, url.password == nil else { throw ViewerError.configuration }
        return url
    }
    func pagingPreview(_ catalog: ReadCatalog, _ item: ReadItem) -> UIImage? {
        do { try requireCachedAccess(catalog, item) } catch { return nil }
        return images.object(forKey: "\(imageCacheID(catalog, item))-\(ImageKind.display.rawValue)" as NSString)
    }
    // Neighbors may restore already verified files, but never start a network request.
    func cachedPagingPreview(_ catalog: ReadCatalog, _ item: ReadItem) async -> UIImage? {
        guard item.mimeType.hasPrefix("image/") else { return nil }
        if let image = pagingPreview(catalog, item) { return image }
        let identity = sessionID, generation = imageCacheGeneration
        do { try requireCachedAccess(catalog, item) } catch { return nil }
        let cacheID = imageCacheID(catalog, item)
        let image = await imageCache.image(id: cacheID, kind: .display, item: item, generation: generation)
        guard !Task.isCancelled, identity == sessionID, generation == imageCacheGeneration else { return nil }
        do { try requireCachedAccess(catalog, item) } catch { return nil }
        if let image {
            images.setObject(image, forKey: "\(cacheID)-\(ImageKind.display.rawValue)" as NSString,
                             cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        return image
    }
    func image(_ catalog: ReadCatalog, _ item: ReadItem, thumbnail: Bool = false, onStatus: ((String) -> Void)? = nil) async throws -> UIImage {
        try requireCachedAccess(catalog, item)
        try Task.checkCancellation()
        let identity = sessionID, generation = imageCacheGeneration
        let key = identity.uuidString + generation.uuidString + imageCacheID(catalog, item) + (thumbnail ? "thumbnail" : "original")
        let observerID = UUID()
        if let onStatus {
            imageLoadObservers[key, default: [:]][observerID] = onStatus
            onStatus(imageLoadStatuses[key] ?? "保存済みの画像を確認中…")
        }
        defer {
            imageLoadObservers[key]?[observerID] = nil
            if imageLoadObservers[key]?.isEmpty == true { imageLoadObservers[key] = nil }
        }
        let task: Task<UIImage, Error>
        let ticket: UUID
        if let (existing, pending) = imageLoads[key] { ticket = existing; task = pending }
        else {
            ticket = UUID()
            task = Task {
                defer { if imageLoads[key]?.0 == ticket { imageLoadStatuses[key] = nil } }
                return try await loadImage(catalog, item, thumbnail: thumbnail) { status in
                    self.reportImageStatus(status, key: key)
                }
            }
            imageLoads[key] = (ticket, task)
        }
        imageWaiters[key, default: []].insert(observerID)
        defer { releaseImageWaiter(key, observerID, ticket) }
        let image = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { @MainActor in self.releaseImageWaiter(key, observerID, ticket) }
        }
        try Task.checkCancellation()
        guard identity == sessionID, generation == imageCacheGeneration else { throw CancellationError() }
        try requireCachedAccess(catalog, item)
        return image
    }
    private func releaseImageWaiter(_ key: String, _ waiter: UUID, _ ticket: UUID) {
        guard imageWaiters[key]?.remove(waiter) != nil else { return }
        imageLoadObservers[key]?[waiter] = nil
        if imageWaiters[key]?.isEmpty == true {
            imageWaiters[key] = nil
            if let (current, task) = imageLoads[key], current == ticket {
                task.cancel(); imageLoads[key] = nil
            }
        }
    }
    func prefetchSwipeImages(_ entries: [ReaderEntry], after index: Int, maximumCount: Int = 10, onPrepared: () -> Void = {}) async {
        let identity = sessionID
        for entry in ReaderSwipeScreen.upcomingPhotos(entries, after: index).prefix(maximumCount) {
            guard !Task.isCancelled, identity == sessionID else { return }
            guard swipePrefetchBudget.reserve(imageCacheID(entry.catalog, entry.item), bytes: entry.item.byteSize) else { continue }
            do {
                // Foreground display joins this download. Cancelling prefetch only
                // cancels the network task when there are no remaining viewers.
                _ = try await image(entry.catalog, entry.item)
                guard !Task.isCancelled, identity == sessionID else { return }
                onPrepared()
            } catch {
                if Task.isCancelled || identity != sessionID { return }
                // A failed photo must not prevent the rest of the bounded window loading.
            }
        }
    }
    func pdfData(_ catalog: ReadCatalog, _ item: ReadItem) async throws -> Data {
        guard item.mimeType == "application/pdf", item.byteSize <= PDFLimits.maximumBytes else { throw ViewerError.tooLarge }
        let identity = sessionID
        try requireCachedAccess(catalog, item)
        let url = try await mediaURL(catalog, item)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("bytes=0-\(item.byteSize - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await network.data(for: request)
        try Task.checkCancellation()
        guard identity == sessionID else { throw CancellationError() }
        try requireCachedAccess(catalog, item)
        guard let status = (response as? HTTPURLResponse)?.statusCode, [200, 206].contains(status) else { throw ViewerError.connection }
        guard Int64(data.count) == item.byteSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw ViewerError.integrity }
        return data
    }
    private func loadImage(_ catalog: ReadCatalog, _ item: ReadItem, thumbnail: Bool, onStatus: (String) -> Void) async throws -> UIImage {
        guard thumbnail || item.byteSize <= 100 * 1024 * 1024 else { throw ViewerError.tooLarge }
        let identity = sessionID
        let cacheGeneration = imageCacheGeneration
        try requireCachedAccess(catalog, item)
        try Task.checkCancellation()
        if let root = roots.first(where: { $0.rootId == catalog.rootId && $0.id == catalog.id }) { updateCatalog(root) }
        let cacheID = imageCacheID(catalog, item)
        let kind: ImageKind = thumbnail ? .thumbnail : .display
        let memoryID = "\(cacheID)-\(kind.rawValue)" as NSString
        if let image = images.object(forKey: memoryID) { return image }
        if let image = await imageCache.image(id: cacheID, kind: kind, item: item, generation: cacheGeneration) {
            guard identity == sessionID, cacheGeneration == imageCacheGeneration else { throw CancellationError() }
            try requireCachedAccess(catalog, item)
            try Task.checkCancellation()
            images.setObject(image, forKey: memoryID, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
            return image
        }
        onStatus("画像の接続先を取得中…")
        let url = try await mediaURL(catalog, item, thumbnail: thumbnail)
        guard identity == sessionID else { throw CancellationError() }
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let maximumBytes: Int = thumbnail ? 1_048_576 : 104_857_600
        let lastByte: Int = maximumBytes - 1
        request.setValue("bytes=0-\(lastByte)", forHTTPHeaderField: "Range")
        onStatus("画像を受信中…")
        let (data, response) = try await network.data(for: request)
        guard identity == sessionID else { throw CancellationError() }
        guard let status = (response as? HTTPURLResponse)?.statusCode, [200, 206].contains(status), data.count <= maximumBytes else { throw ViewerError.connection }
        onStatus("画像を照合・表示準備中…")
        let image = try await imageCache.decode(data, item: item, thumbnail: thumbnail)
        guard identity == sessionID else { throw CancellationError() }
        try requireCachedAccess(catalog, item)
        try Task.checkCancellation()
        if cacheGeneration == imageCacheGeneration {
            onStatus("画像を端末にキャッシュ中…")
            await imageCache.store(data, id: cacheID, kind: kind, generation: cacheGeneration)
        }
        guard identity == sessionID else { throw CancellationError() }
        try requireCachedAccess(catalog, item)
        if cacheGeneration == imageCacheGeneration {
            images.setObject(image, forKey: memoryID, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count)
        }
        return image
    }
}

// Serialize disk operations away from the UI. Generation checks prevent a cache clear
// from being undone by an image download that started before the clear.
private actor ReaderImageDiskStore {
    private let root: URL
    private var cache: DiskCache?
    private var storedBytes: Int64 = 0
    private var generation: UUID
    init(root: URL, generation: UUID) { self.root = root; self.generation = generation }
    private func disk() -> DiskCache? {
        if cache == nil {
            cache = try? DiskCache(root: root, limit: 1024 * 1024 * 1024)
            try? cache?.trim()
            storedBytes = sizeOnDisk()
        }
        return cache
    }
    private func sizeOnDisk() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { total, file in
            total + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    func clear(generation: UUID) {
        self.generation = generation
        try? FileManager.default.removeItem(at: root)
        cache = nil; storedBytes = 0
    }
    func image(id: String, kind: ImageKind, item: ReadItem, generation: UUID) -> UIImage? {
        guard generation == self.generation, let file = disk()?.cached(id: id, kind: kind),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? decode(data, item: item, thumbnail: kind == .thumbnail)
    }
    func decode(_ data: Data, item: ReadItem, thumbnail: Bool) throws -> UIImage {
        if !thumbnail {
            guard Int64(data.count) == item.byteSize,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw ViewerError.integrity }
        }
        guard let image = UIImage(data: data) else { throw ViewerError.format }
        return image.preparingForDisplay() ?? image
    }
    func store(_ data: Data, id: String, kind: ImageKind, generation: UUID) {
        guard generation == self.generation, let cache = disk() else { return }
        let file = cache.file(id: id, kind: kind)
        let previous = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            storedBytes += Int64(data.count) - previous
            // Avoid scanning and sorting the entire cache after every thumbnail.
            if storedBytes > cache.limit {
                try cache.trim()
                storedBytes = sizeOnDisk()
            }
        } catch { storedBytes = sizeOnDisk() }
    }
}

enum ViewerError: Error { case login, configuration, connection, tooLarge, integrity, format, unlock }

struct CloudViewerRoot: View {
    @StateObject private var model = CloudViewerModel()
    @State private var tab = 0
    @State private var browseMode = 0
    @State private var query = ""
    @State private var order: LibraryOrder = .name
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { libraryScreen }
                .tabItem { Label("見る", systemImage: "folder") }.tag(0)
            NavigationStack { ReaderFavoritesScreen() }
                .tabItem { Label("お気に入り", systemImage: "heart") }.tag(5)
            NavigationStack { ReaderOverview(mode: .swipe, active: tab == 3) }
                .tabItem { Label("スワイプ", systemImage: "rectangle.portrait") }.tag(3)
            NavigationStack { ReaderSettings() }
                .tabItem { Label("設定", systemImage: "gearshape") }.tag(4)
        }.environmentObject(model).id(model.sessionID)
        .safeAreaInset(edge: .bottom) {
            if !model.favoriteError.isEmpty {
                HStack {
                    Text(model.favoriteError).font(.caption)
                    Button("再試行") { Task { await model.refreshFavorites() } }
                    Button("閉じる") { model.favoriteError = "" }
                }.padding(10).background(.regularMaterial)
            }
        }
        .task { await model.restoreLogin() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.relock() }
            if phase == .active && model.signedIn { Task { await model.refresh() } }
        }
        .overlay { if scenePhase != .active { Color(.systemBackground).ignoresSafeArea() } }
        .tint(Color(red: 0.20, green: 0.40, blue: 0.31))
    }
    private var libraryScreen: some View {
        Group {
            if model.restoringLogin { ProgressView("ログインを復帰中…") }
            else if model.signedIn {
                VStack(spacing: 0) {
                    Picker("表示するメディア", selection: $browseMode) {
                        Text("フォルダ").tag(0)
                        Text("写真").tag(1)
                        Text("動画").tag(2)
                    }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 10)
                    if browseMode == 0 { folderList }
                    else { ReaderOverview(mode: browseMode == 1 ? .photos : .videos, active: tab == 0).id(browseMode) }
                }
            }
            else { signedOutScreen }
        }.navigationTitle("ライブラリ").navigationBarTitleDisplayMode(.inline)
    }
    private var signedOutScreen: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.icloud").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("あなただけのメディア").font(.title2.bold())
            Text(model.configuration.valid ? "本人ログインで、Macから保存した写真や動画を閲覧できます。" : "閲覧用の接続を準備中です。設定で接続先を登録できます。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("本人ログイン") { Task { await model.login() } }
                .buttonStyle(.borderedProminent).disabled(!model.configuration.valid || model.busy)
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
        }.padding(28)
    }
    private var folderList: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).padding() }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                    ForEach(order.arrange(model.roots, query: query, name: { $0.name }, size: { $0.byteSize })) { root in ReaderRootTile(root: root) }
                }.padding(16)
                if model.roots.isEmpty && model.error.isEmpty { ContentUnavailableView("フォルダはまだありません", systemImage: "folder") }
            }
        }.refreshable { await model.refresh() }
        .searchable(text: $query, prompt: "フォルダ名で検索")
        .toolbar { ToolbarItem { ReaderSortPicker(order: $order) } }
    }
}

struct ReaderRootTile: View {
    @EnvironmentObject private var model: CloudViewerModel
    let root: ReadRoot
    @State private var catalog: ReadCatalog?
    var body: some View {
        NavigationLink {
            if let catalog { ReaderFolderScreen(catalog: catalog, folderID: catalog.folders.first { $0.parentId == nil }?.id) }
            else { ReaderCatalogScreen(root: root) }
        } label: {
            ReaderFolderTile(name: root.name, catalog: catalog, folderID: catalog?.folders.first { $0.parentId == nil }?.id)
        }.buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let catalog, let folder = catalog.folders.first(where: { $0.parentId == nil }) { PhoneFavoriteButton(reference: model.favorite(catalog, target: folder.id, kind: "folder")).padding(4) }
        }
        .task {
            let identity = model.sessionID
            do { let value = try await model.catalog(root); if identity == model.sessionID, !Task.isCancelled { catalog = value } }
            catch { }
        }
        .onReceive(model.$catalogs) { values in
            catalog = values[model.catalogKey(root.rootId, root.id)]
        }
    }
}

struct ReaderFolderTile: View {
    let name: String
    let catalog: ReadCatalog?
    let folderID: String?
    private var cover: ReadItem? {
        guard let catalog else { return nil }
        var ids = Set<String>(); if let folderID { ids.insert(folderID) }
        for _ in 0..<catalog.folders.count {
            let children = catalog.folders.filter { $0.parentId.map { ids.contains($0) } == true }.map(\.id)
            let before = ids.count; ids.formUnion(children); if ids.count == before { break }
        }
        let candidates = catalog.items.filter { ids.contains($0.folderId) && $0.hasThumbnail }
        return candidates.first { $0.mimeType.hasPrefix("image/") } ?? candidates.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let catalog, let cover { ReaderThumbnail(catalog: catalog, item: cover) }
                else { ZStack { Color.secondary.opacity(0.10); Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.secondary) }.aspectRatio(1, contentMode: .fit) }
            }.clipShape(RoundedRectangle(cornerRadius: 16))
            Text(name).font(.caption.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
        }.accessibilityElement(children: .combine)
    }
}

struct ReaderCatalogScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CloudViewerModel
    let root: ReadRoot
    @State private var catalog: ReadCatalog?
    @State private var error = ""
    var body: some View {
        Group {
            if let catalog { ReaderFolderScreen(catalog: catalog, folderID: catalog.folders.first(where: { $0.parentId == nil })?.id) }
            else if !error.isEmpty { ContentUnavailableView("読み込みに失敗しました", systemImage: "wifi.exclamationmark", description: Text(error)) }
            else { ProgressView("フォルダを読み込み中…") }
        }.navigationTitle("").task { do { catalog = try await model.catalog(root) } catch { self.error = "ログインと通信を確認して、フォルダを開き直してください。" } }
        .onReceive(model.$catalogs) { values in catalog = values[model.catalogKey(root.rootId, root.id)] }
        .navigationBarBackButtonHidden(model.hasFolderUnlock)
        .toolbar {
            if model.hasFolderUnlock {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じて隠す", systemImage: "chevron.backward") {
                        model.relock(); dismiss(); Task { await model.refresh() }
                    }
                }
            }
        }
    }
}

struct ReaderFolderScreen: View {
    @EnvironmentObject private var model: CloudViewerModel
    @Environment(\.dismiss) private var dismiss
    let catalog: ReadCatalog
    let folderID: String?
    private var latestCatalog: ReadCatalog { model.catalogs[model.catalogKey(catalog.rootId, catalog.id)] ?? catalog }
    private var protectedChild: Bool {
        latestCatalog.folders.contains { $0.id == folderID && $0.parentId != nil && $0.isLocked }
    }
    @State private var query = ""
    @State private var order: LibraryOrder = .name
    @State private var selected: ReadItem?
    private var items: [ReadItem] { order.arrange(latestCatalog.items.filter { $0.folderId == folderID }, query: query, name: { $0.name }, size: { $0.byteSize }) }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let children = order.arrange(latestCatalog.folders.filter { $0.parentId == folderID }, query: query, name: { $0.name }, size: { folder in latestCatalog.items.filter { $0.folderId == folder.id }.reduce(0) { $0 + $1.byteSize } })
                if !children.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                        ForEach(children) { folder in
                            NavigationLink { ReaderFolderScreen(catalog: latestCatalog, folderID: folder.id) } label: {
                                ReaderFolderTile(name: folder.name, catalog: latestCatalog, folderID: folder.id)
                            }.buttonStyle(.plain)
                            .overlay(alignment: .topTrailing) { PhoneFavoriteButton(reference: model.favorite(latestCatalog, target: folder.id, kind: "folder")).padding(4) }
                        }
                    }.padding(.horizontal, 12)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(items) { item in
                        Button { selected = item } label: { ReaderThumbnail(catalog: latestCatalog, item: item) }
                            .buttonStyle(.plain).accessibilityLabel(item.mimeType == "application/pdf" ? item.name : (item.mimeType.hasPrefix("video/") ? "動画" : "写真"))
                            .contextMenu { Button(model.isFavorite(model.favorite(latestCatalog, target: item.id, kind: "item")) ? "お気に入りから外す" : "お気に入りに追加", systemImage: "heart") { Task { await model.toggleFavorite(model.favorite(latestCatalog, target: item.id, kind: "item")) } } }
                    }
                }
                if children.isEmpty && items.isEmpty { ContentUnavailableView("空のフォルダ", systemImage: "folder") }
            }.padding(.vertical, 8)
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "このフォルダ内を検索")
        .fullScreenCover(item: $selected) { item in ReaderMediaScreen(catalog: latestCatalog, items: items, initialID: item.id) }
        .navigationBarBackButtonHidden(protectedChild)
        .toolbar {
            ToolbarItem { ReaderSortPicker(order: $order) }
            ToolbarItem { if let folderID { PhoneFavoriteButton(reference: model.favorite(latestCatalog, target: folderID, kind: "folder")) } }
            if protectedChild {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じて隠す", systemImage: "chevron.backward") {
                        model.relock(); dismiss(); Task { await model.refresh() }
                    }
                }
            }
        }
    }
}

struct ReaderThumbnail: View {
    @EnvironmentObject private var model: CloudViewerModel
    let catalog: ReadCatalog
    let item: ReadItem
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Color.secondary.opacity(0.10)
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else { Image(systemName: item.mimeType == "application/pdf" ? "doc.richtext" : (item.mimeType.hasPrefix("video/") ? "play.rectangle" : "photo")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if item.mimeType == "application/pdf" {
                    Text(item.name).font(.caption2).lineLimit(2).foregroundStyle(.white).padding(5)
                        .frame(maxWidth: .infinity).background(.black.opacity(0.65))
                }
                if item.mimeType.hasPrefix("video/") { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(7).background(.black.opacity(0.45), in: Circle()).padding(6) }
            }
        }.aspectRatio(1, contentMode: .fit)
        .task {
            let identity = model.sessionID
            if item.hasThumbnail, let value = try? await model.image(catalog, item, thumbnail: true), identity == model.sessionID, !Task.isCancelled { image = value }
        }.onDisappear { image = nil }
    }
}

struct ReaderMediaScreen: View {
    @EnvironmentObject private var model: CloudViewerModel
    @Environment(\.dismiss) private var dismiss
    let catalog: ReadCatalog
    let items: [ReadItem]
    let initialID: String
    @State private var index: Int
    @State private var controls = true
    @State private var zoomed = false
    @State private var readyID = ""
    @State private var previewRevision = 0
    @State private var refreshToken = 0
    init(catalog: ReadCatalog, items: [ReadItem], initialID: String) {
        self.catalog = catalog; self.items = items; self.initialID = initialID
        _index = State(initialValue: items.firstIndex { $0.id == initialID } ?? 0)
    }
    private var item: ReadItem { items[index] }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativeMediaPager(count: items.count, selection: $index, enabled: !zoomed && item.mimeType != "application/pdf") { position, active in
                ReaderMediaPage(catalog: catalog, item: items[position], active: active,
                                previewRevision: previewRevision, refreshToken: refreshToken, controls: $controls,
                                onZoom: { if active { zoomed = $0 } },
                                onReady: { if active { readyID = items[position].id } })
                    .environmentObject(model)
            }.ignoresSafeArea()
            if controls || item.mimeType.hasPrefix("video/") {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("閉じる")
                        Spacer()
                        Text("\(index + 1) / \(items.count)").font(.caption.monospacedDigit())
                        PhoneFavoriteButton(reference: model.favorite(catalog, target: item.id, kind: "item"))
                        if item.mimeType.hasPrefix("video/") {
                            Button { refreshToken += 1 } label: { Image(systemName: "arrow.clockwise").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("再生用の接続を更新")
                        }
                        if item.mimeType == "application/pdf" {
                            Button { move(-1) } label: { Image(systemName: "chevron.left").padding(10) }.disabled(index == 0).accessibilityLabel("前のファイル")
                            Button { move(1) } label: { Image(systemName: "chevron.right").padding(10) }.disabled(index + 1 == items.count).accessibilityLabel("次のファイル")
                        }
                    }.foregroundStyle(.white).padding()
                    Spacer()
                }
            }
        }.onChange(of: index) { _, _ in controls = true; zoomed = false; readyID = "" }
        .task(id: readyID) {
            guard readyID == item.id else { return }
            await model.prefetchSwipeImages(items.map { ReaderEntry(catalog: catalog, item: $0) }, after: index, maximumCount: 3) { previewRevision += 1 }
        }
    }
    private func move(_ direction: Int) { let next = index + direction; if items.indices.contains(next) { index = next } }
}

/// Page state survives a cancelled drag. Inactive neighbors never request video or original data.
struct ReaderMediaPage: View {
    @EnvironmentObject private var model: CloudViewerModel
    let catalog: ReadCatalog
    let item: ReadItem
    let active: Bool
    var previewRevision = 0
    var refreshToken = 0
    @Binding var controls: Bool
    let onZoom: (Bool) -> Void
    let onReady: () -> Void
    @State private var image: UIImage?
    @State private var pdf: Data?
    @State private var player: AVPlayer?
    @State private var loadingStatus = "読み込みを準備中…"
    @State private var error = ""
    @State private var retry = 0
    var body: some View {
        Group {
            if let pdf { MediaPDFReader(data: pdf).padding(.top, 64) }
            else if let image { PhoneZoomableImage(image: image, onTap: { controls.toggle() }, onZoomChanged: onZoom) }
            else if let player { ReaderVideoPlayer(player: player).id(ObjectIdentifier(player)) }
            else if !error.isEmpty { VStack { Text(error); Button("再試行") { retry += 1 } }.foregroundStyle(.white).padding() }
            else { ReaderLoadingView(status: loadingStatus) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        .task(id: "\(active)/\(retry)/\(active ? refreshToken : previewRevision)") {
            if active { await load() }
            else if image == nil { image = await model.cachedPagingPreview(catalog, item) }
        }
        .onChange(of: active) { _, active in if !active {
            player?.pause(); player = nil; pdf = nil
            if let cg = image?.cgImage, cg.bytesPerRow * cg.height > 20 * 1024 * 1024 { image = nil }
        } }
        .onDisappear { player?.pause(); player = nil }
    }
    private func load() async {
        let identity = model.sessionID
        error = ""
        do {
            if item.mimeType.hasPrefix("video/") {
                player?.pause(); player = nil
                loadingStatus = "動画の接続先を取得中…"
                let url = try await model.mediaURL(catalog, item)
                guard !Task.isCancelled, identity == model.sessionID else { return }
                player = AVPlayer(url: url); model.recordVideoStart()
            } else if item.mimeType == "application/pdf" {
                if pdf == nil {
                    loadingStatus = "PDFを受信・照合中…"
                    let data = try await model.pdfData(catalog, item)
                    guard !Task.isCancelled, identity == model.sessionID else { return }; pdf = data
                }
            } else if image == nil {
                let value = try await model.image(catalog, item) { status in
                    if identity == model.sessionID { loadingStatus = status }
                }
                guard !Task.isCancelled, identity == model.sessionID else { return }; image = value
            }
            guard !Task.isCancelled, identity == model.sessionID else { return }; onReady()
        } catch { if !Task.isCancelled, identity == model.sessionID { self.error = "表示できません。通信を確認してください。" } }
    }
}

struct ReaderSettings: View {
    @AppStorage("sealedPhotoPrefetch") private var sealedPhotoPrefetch = true
    @State private var sealedFavoritesOnly: Bool?
    @EnvironmentObject private var model: CloudViewerModel
    @State private var value = CloudConfiguration()
    var body: some View {
        Form {
            if model.signedIn {
                Section { NavigationLink("容量と費用", destination: PhoneUsageScreen()) }
            }
            if model.signedIn { Section { FolderUnlockControl() } }
            Section { if model.signedIn { Button("ログアウト") { model.signOut() } } else { Button("本人ログイン") { Task { await model.login() } }.disabled(!model.configuration.valid || model.busy) } }
            if model.signedIn && model.hiddenPagesOpen {
                Section("暗号化") {
                    PhoneSealedEntry(favoritesOnly: false) { sealedFavoritesOnly = false }
                    PhoneSealedEntry(favoritesOnly: true) { sealedFavoritesOnly = true }
                }
            }
            Section("キャッシュ") {
                Text("通常の写真とサムネイルを最大1GB保存します。容量が増えると古いものから削除します。暗号化した内容は長期保存しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("キャッシュを削除") { model.clearImageCache() }
                Toggle("暗号化写真をWi-Fiで先読み", isOn: $sealedPhotoPrefetch)
                Text("次の1枚・5MB以下。解除中は先読み合計50MBまで。復号画像は閲覧画面のメモリだけで保持し、閉じると破棄します。省データモードでは先読みしません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("接続設定") {
                TextField("閲覧API URL", text: $value.api).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Cognito domain", text: $value.domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Client ID", text: $value.clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("本人sub", text: $value.owner).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("接続先を保存") { model.saveConfiguration(value) }.disabled(!value.valid)
                }
            }
        }.navigationTitle("設定").onAppear { value = model.configuration }
        .navigationDestination(item: $sealedFavoritesOnly) { favoritesOnly in
            if model.signedIn && model.hiddenPagesOpen { PhoneSealedLibrary(favoritesOnly: favoritesOnly) }
        }
    }
}

struct FolderUnlockControl: View {
    @EnvironmentObject private var model: CloudViewerModel
    @State private var showing = false
    var body: some View {
        Button("隠したフォルダを開く") { showing = true }
            .sheet(isPresented: $showing) {
                let identity = model.sessionID
                HiddenPagePINSheet { pin in
                    guard model.sessionID == identity else { return }
                    try? await model.unlockFolder(pin)
                    guard model.sessionID == identity || model.hasFolderUnlock else { return }
                    model.hiddenPagesOpen = true
                }
            }
        if model.hiddenPagesOpen {
            Button("閉じて隠す") { model.relock(); Task { await model.refresh() } }
        }
    }
}

struct FolderUnlockScreen: View {
    @EnvironmentObject private var model: CloudViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                SecureField("PIN", text: $password).textContentType(.none)
                Button("解除する") {
                    let entered = password; password = ""; busy = true; error = ""
                    Task {
                        do { try await model.unlockFolder(entered); dismiss() }
                        catch { self.error = "解除できませんでした。パスワードを確認し、少し待ってから再試行してください。" }
                        busy = false
                    }
                }.disabled(busy || password.isEmpty)
                if busy { ProgressView("処理中…") }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.navigationTitle("隠したフォルダを開く")
            .toolbar { Button("閉じる") { password = ""; dismiss() } }
        }
    }
}


struct PhoneUsageScreen: View {
    @EnvironmentObject private var model: CloudViewerModel
    @State private var report: UsageReport?
    @State private var activity: [UsageActivity] = []
    @State private var loading = false
    @State private var error = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if loading { ProgressView("集計を読み込み中…") }
                if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
                UsageDashboard(report: report, activity: activity, device: "このiPhone")
            }.padding()
        }.navigationTitle("容量と費用")
            .toolbar { Button("更新", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading || !model.signedIn) }
            .task { await load() }
            .onChange(of: model.sessionID) { _ in report = nil; activity = []; error = "" }
    }
    private func load() async {
        guard !loading, model.signedIn else { return }
        loading = true; error = ""
        let identity = model.sessionID
        defer { loading = false }
        do {
            let value = try await model.usageReport()
            guard identity == model.sessionID, model.signedIn, !Task.isCancelled else { return }
            report = value
        } catch is CancellationError { }
        catch { if identity == model.sessionID { self.error = "集計を取得できません。MacでAWSから更新し、通信を確認してください。" } }
        if identity == model.sessionID, model.signedIn { activity = UsageActivityStore.shared.history(scope: model.usageScope) }
    }
}

// Shared by normal and memory-only encrypted full-screen photos.
struct ReaderLoadingView: View {
    let status: String
    @State private var started = Date()
    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(started)))
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(status).font(.callout)
                Text("待ち時間 \(seconds)秒").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                if seconds >= 15 {
                    Text("時間がかかっています。通信状況を確認するか、閉じて開き直してください。")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            .multilineTextAlignment(.center).foregroundStyle(.white)
            .padding(20).frame(maxWidth: 300)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        }.allowsHitTesting(false)
    }
}

struct ReaderVideoPlayer: View {
    @EnvironmentObject private var model: CloudViewerModel
    let player: AVPlayer
    var body: some View {
        VideoPlayer(player: player).overlay {
            // Inspect local player state only; this timer never requests media.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                if player.currentItem?.status == .failed || player.status == .failed {
                    Text("動画を再生できません。通信を確認して開き直してください。")
                        .font(.callout).multilineTextAlignment(.center).foregroundStyle(.white)
                        .padding(20).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                } else if player.currentItem?.status != .readyToPlay {
                    ReaderLoadingView(status: "動画を再生準備中…")
                } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    ReaderLoadingView(status: "動画の続きを受信待ち…")
                }
            }.allowsHitTesting(false)
        }.task(id: ObjectIdentifier(player)) {
            // Sealed media is measured by its URLSession; do not count decrypted bytes twice.
            guard let item = player.currentItem,
                  let asset = item.asset as? AVURLAsset, asset.url.scheme == "https" else { return }
            let scope = model.usageScope
            var counter = UsagePlayerDelta()
            func collect() {
                let bytes = counter.update(item.accessLog()?.events.map { $0.numberOfBytesTransferred } ?? [])
                if bytes > 0 { UsageActivityStore.shared.record(scope: scope, receivedBytes: bytes) }
            }
            defer { collect() }
            while !Task.isCancelled {
                collect()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { break }
            }
        }
    }
}

struct ReaderEntry: Identifiable {
    let catalog: ReadCatalog
    let item: ReadItem
    // Stable composite ID, available for future per-media viewing history.
    var id: String { "\(catalog.rootId)/\(catalog.id)/\(item.id)" }
}

enum ReaderOverviewMode {
    case photos, videos, swipe
    var title: String {
        switch self { case .photos: return "写真一覧"; case .videos: return "動画一覧"; case .swipe: return "スワイプ閲覧" }
    }
    func includes(_ item: ReadItem) -> Bool {
        switch self {
        case .photos: return item.mimeType.hasPrefix("image/")
        case .videos: return item.mimeType.hasPrefix("video/")
        case .swipe: return item.mimeType.hasPrefix("image/") || item.mimeType.hasPrefix("video/")
        }
    }
}

struct ReaderOverview: View {
    @EnvironmentObject private var model: CloudViewerModel
    let mode: ReaderOverviewMode
    let active: Bool
    @State private var loading = false
    @State private var failed = false
    @State private var loadID = UUID()
    @State private var selected: ReaderEntry?
    @State private var queue: [ReaderEntry] = []
    @State private var showSwipe = false
    private var entries: [ReaderEntry] {
        model.roots.flatMap { root -> [ReaderEntry] in
            guard let catalog = model.catalogs[model.catalogKey(root.rootId, root.id)] else { return [] }
            return catalog.items.filter { mode.includes($0) }.map { ReaderEntry(catalog: catalog, item: $0) }
        }
    }
    private var loadedCount: Int { model.roots.filter { model.catalogs[model.catalogKey($0.rootId, $0.id)] != nil }.count }
    private var loadKey: String { "\(active)/\(model.signedIn)/" + model.roots.map { model.catalogKey($0.rootId, $0.id) }.joined(separator: "|") }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !model.signedIn {
                    ContentUnavailableView("ログインが必要です", systemImage: "lock", description: Text("「見る」から本人ログインしてください。"))
                } else {
                    if loading { ProgressView("フォルダを読み込み中 \(loadedCount)/\(model.roots.count)").padding() }
                    if failed {
                        Text("読み込めなかったフォルダがあります。").font(.caption).foregroundStyle(.secondary)
                        Button("再試行") { Task { await loadCatalogs() } }.disabled(loading)
                    }
                    if mode == .swipe {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait").font(.system(size: 48)).foregroundStyle(.secondary).padding(.top, 40)
                        Text("フォルダを横断して、ランダムに").font(.headline)
                        Text("上下にスワイプして、写真や動画を楽しめます。").font(.subheadline).foregroundStyle(.secondary)
                        Text("\(entries.count)件 · \(loadedCount)フォルダ").font(.caption).foregroundStyle(.secondary)
                        Button("スワイプをはじめる") { queue = entries.shuffled(); showSwipe = true }
                            .buttonStyle(.borderedProminent).disabled(entries.isEmpty || loading)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                            ForEach(entries) { entry in
                                Button { selected = entry } label: { ReaderThumbnail(catalog: entry.catalog, item: entry.item) }
                                    .buttonStyle(.plain).accessibilityLabel("\(mode.title): \(entry.item.name)")
                            }
                        }
                    }
                    if !loading && entries.isEmpty && !failed {
                        ContentUnavailableView("表示できるメディアはまだありません", systemImage: mode == .videos ? "video" : "photo")
                    }
                }
            }.padding(.vertical)
        }.navigationTitle(mode.title).navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { if active && model.signedIn { await loadCatalogs() } }
        .fullScreenCover(item: $selected) { entry in
            ReaderMediaScreen(catalog: entry.catalog, items: entry.catalog.items.filter { mode.includes($0) }, initialID: entry.item.id)
        }
        .fullScreenCover(isPresented: $showSwipe, onDismiss: { queue = [] }) {
            if !queue.isEmpty { ReaderSwipeScreen(entries: queue) }
        }
    }
    private func loadCatalogs() async {
        let identity = model.sessionID, request = UUID()
        loadID = request; loading = true; failed = false
        defer { if loadID == request { loading = false } }
        // Read metadata serially; only visible cells/current media fetch image bytes.
        for root in model.roots {
            guard !Task.isCancelled, model.signedIn, identity == model.sessionID, loadID == request else { return }
            do { _ = try await model.catalog(root) }
            catch is CancellationError { return }
            catch { if identity == model.sessionID, loadID == request { failed = true } }
        }
    }
}

struct ReaderPrefetchBudget {
    private(set) var remainingBytes: Int64
    init(maximumBytes: Int64 = 100 * 1024 * 1024) { remainingBytes = maximumBytes }
    private var attempted = Set<String>()
    mutating func reserve(_ id: String, bytes: Int64) -> Bool {
        guard bytes > 0, bytes <= remainingBytes, !attempted.contains(id) else { return false }
        remainingBytes -= bytes
        attempted.insert(id)
        return true
    }
}

struct ReaderSwipeScreen: View {
    static func upcomingPhotos(_ entries: [ReaderEntry], after index: Int) -> [ReaderEntry] {
        guard entries.indices.contains(index) else { return [] }
        var remaining: Int64 = 20 * 1024 * 1024
        var result: [ReaderEntry] = []
        for entry in entries.dropFirst(index + 1).lazy.filter({ $0.item.mimeType.hasPrefix("image/") }).prefix(10) {
            let bytes = entry.item.byteSize
            guard bytes > 0,
                  bytes <= 10 * 1024 * 1024, bytes <= remaining else { continue }
            result.append(entry); remaining -= bytes
            if result.count == 10 { break }
        }
        return result
    }
    @EnvironmentObject private var model: CloudViewerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let entries: [ReaderEntry]
    @State private var index = 0
    @State private var controls = true
    @State private var zoomed = false
    @State private var readyID = ""
    @State private var previewRevision = 0
    private var entry: ReaderEntry { entries[index] }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativeMediaPager(count: entries.count, selection: $index, vertical: true, enabled: !zoomed) { position, active in
                ReaderMediaPage(catalog: entries[position].catalog, item: entries[position].item,
                                active: active && scenePhase == .active,
                                previewRevision: previewRevision, controls: $controls,
                                onZoom: { if active { zoomed = $0 } },
                                onReady: { if active { readyID = entries[position].id } })
                    .environmentObject(model)
            }.ignoresSafeArea()
            if controls || entry.item.mimeType.hasPrefix("video/") {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("閉じる")
                        Spacer()
                        PhoneFavoriteButton(reference: model.favorite(entry.catalog, target: entry.item.id, kind: "item"))
                        Text("\(index + 1) / \(entries.count)").font(.caption.monospacedDigit())
                    }
                    Spacer()
                    HStack {
                        Text(entry.catalog.name).lineLimit(1)
                        Spacer()
                        Button { move(-1) } label: { Image(systemName: "chevron.up").padding(12) }.disabled(index == 0).accessibilityLabel("前へ")
                        Button { move(1) } label: { Image(systemName: "chevron.down").padding(12) }.disabled(index + 1 == entries.count).accessibilityLabel("次へ")
                    }.font(.caption).padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                }.foregroundStyle(.white).padding()
            }
        }.onChange(of: index) { _, _ in controls = true; zoomed = false; readyID = "" }
        .task(id: readyID) {
            guard readyID == entry.id, scenePhase == .active else { return }
            await model.prefetchSwipeImages(entries, after: index) { previewRevision += 1 }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dismiss() } }
    }
    private func move(_ direction: Int) { let next = index + direction; if entries.indices.contains(next) { index = next } }
}
