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
    func recordVideoStart() { UsageActivityStore.shared.record(scope: usageScope, videoStarts: 1) }
    private let sealedRequests = SealedRequestGate()
    // Only ordinary reader images enter this cache; sealed media uses a separate reader.
    private let images = NSCache<NSString, UIImage>()
    private var imageCacheGeneration = UUID()
    private var imageLoads: [String: (UUID, Task<UIImage, Error>)] = [:]
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
        imageLoads = [:]
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
                let value = try await get("/catalogs/\(key)", as: ReadCatalog.self)
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
        images.removeAllObjects()
        for (_, task) in imageLoads.values { task.cancel() }
        imageLoads = [:]
        for (_, task) in thumbnailBatches.values { task.cancel() }
        thumbnailBatches = [:]
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
        let value = try await get("/catalogs/\(key)", as: ReadCatalog.self)
        guard identity == sessionID else { throw CancellationError() }
        catalogs[key] = value; catalogDates[key] = Date()
        return value
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
                defer { imageLoadStatuses[key] = nil }
                return try await loadImage(catalog, item, thumbnail: thumbnail) { status in
                    self.reportImageStatus(status, key: key)
                }
            }
            imageLoads[key] = (ticket, task)
        }
        defer { if imageLoads[key]?.0 == ticket { imageLoads[key] = nil } }
        let image = try await task.value
        try Task.checkCancellation()
        guard identity == sessionID, generation == imageCacheGeneration else { throw CancellationError() }
        try requireCachedAccess(catalog, item)
        return image
    }
    func prefetchSwipeImages(_ entries: [ReaderEntry], after index: Int) async {
        let identity = sessionID
        for entry in ReaderSwipeScreen.upcomingPhotos(entries, after: index) {
            guard !Task.isCancelled, identity == sessionID else { return }
            do {
                // Keep this work in the view's task so paging/dismissal cancels its download.
                // Sequential requests leave bandwidth available for the displayed media.
                _ = try await loadImage(entry.catalog, entry.item, thumbnail: false, onStatus: { _ in })
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
        return image
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
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { libraryScreen }
                .tabItem { Label("見る", systemImage: "folder") }.tag(0)
            NavigationStack { ReaderOverview(mode: .swipe, active: tab == 3) }
                .tabItem { Label("スワイプ", systemImage: "rectangle.portrait") }.tag(3)
            NavigationStack { ReaderSettings() }
                .tabItem { Label("設定", systemImage: "gearshape") }.tag(4)
        }.environmentObject(model).id(model.sessionID)
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
                    ForEach(model.roots) { root in ReaderRootTile(root: root) }
                }.padding(16)
                if model.hiddenPagesOpen {
                    NavigationLink { PhoneSealedLibrary() } label: { Label("暗号化フォルダ", systemImage: "lock.shield") }.padding(.horizontal)
                }
                if model.roots.isEmpty && model.error.isEmpty { ContentUnavailableView("フォルダはまだありません", systemImage: "folder") }
            }
        }.refreshable { await model.refresh() }
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
    @State private var selected: ReadItem?
    private var items: [ReadItem] { latestCatalog.items.filter { $0.folderId == folderID } }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let children = latestCatalog.folders.filter { $0.parentId == folderID }
                if !children.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                        ForEach(children) { folder in
                            NavigationLink { ReaderFolderScreen(catalog: latestCatalog, folderID: folder.id) } label: {
                                ReaderFolderTile(name: folder.name, catalog: latestCatalog, folderID: folder.id)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 12)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(items) { item in
                        Button { selected = item } label: { ReaderThumbnail(catalog: latestCatalog, item: item) }
                            .buttonStyle(.plain).accessibilityLabel(item.mimeType == "application/pdf" ? item.name : (item.mimeType.hasPrefix("video/") ? "動画" : "写真"))
                    }
                }
                if children.isEmpty && items.isEmpty { ContentUnavailableView("空のフォルダ", systemImage: "folder") }
            }.padding(.vertical, 8)
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selected) { item in ReaderMediaScreen(catalog: latestCatalog, items: items, initialID: item.id) }
        .navigationBarBackButtonHidden(protectedChild)
        .toolbar {
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
    @State private var index = 0
    @State private var controls = true
    @State private var image: UIImage?
    @State private var pdf: Data?
    @State private var player: AVPlayer?
    @State private var loadingStatus = "読み込みを準備中…"
    @State private var error = ""
    private var item: ReadItem { items[index] }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let pdf { MediaPDFReader(data: pdf).padding(.top, 64) }
                else if let image { PhoneZoomableImage(image: image, onTap: { controls.toggle() }, onSwipe: move) }
                else if let player { ReaderVideoPlayer(player: player).id(ObjectIdentifier(player)) }
                else if !error.isEmpty { VStack { Text(error); Button("再試行") { Task { await load() } } }.foregroundStyle(.white).padding() }
                else { ReaderLoadingView(status: loadingStatus) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                    guard image == nil, item.mimeType != "application/pdf", abs(value.translation.width) > abs(value.translation.height) else { return }
                    move(value.translation.width < 0 ? 1 : -1)
                })
            if controls || player != nil {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("閉じる")
                        Spacer()
                        if item.mimeType.hasPrefix("video/") { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("再生用の接続を更新") }
                    }.foregroundStyle(.white).padding()
                    Spacer()
                }
            }
        }.onAppear { index = items.firstIndex { $0.id == initialID } ?? 0 }
        .task(id: item.id) { await load() }
        .onDisappear { clear() }
    }
    private func move(_ direction: Int) {
        let next = index + direction
        if items.indices.contains(next) { clear(); index = next; controls = true }
    }
    private func clear() { player?.pause(); player = nil; image = nil; pdf = nil; error = ""; loadingStatus = "読み込みを準備中…" }
    private func load() async {
        let current = item; let identity = model.sessionID
        clear()
        do {
            if current.mimeType.hasPrefix("video/") {
                loadingStatus = "動画の接続先を取得中…"
                let url = try await model.mediaURL(catalog, current)
                guard !Task.isCancelled, identity == model.sessionID, current.id == item.id else { return }
                player = AVPlayer(url: url)
                model.recordVideoStart()
            } else if current.mimeType == "application/pdf" {
                loadingStatus = "PDFを受信・照合中…"
                let data = try await model.pdfData(catalog, current)
                guard !Task.isCancelled, identity == model.sessionID, current.id == item.id else { return }
                pdf = data
            } else {
                let value = try await model.image(catalog, current) { status in
                    guard identity == model.sessionID, current.id == item.id else { return }
                    loadingStatus = status
                }
                guard !Task.isCancelled, identity == model.sessionID, current.id == item.id else { return }
                image = value
            }
        } catch { if !Task.isCancelled, identity == model.sessionID, current.id == item.id { self.error = "表示できません。通信を確認してください。" } }
    }
}

struct ReaderSettings: View {
    @EnvironmentObject private var model: CloudViewerModel
    @State private var value = CloudConfiguration()
    var body: some View {
        Form {
            if model.signedIn {
                Section { NavigationLink("容量と費用", destination: PhoneUsageScreen()) }
            }
            if model.signedIn { Section { FolderUnlockControl() } }
            Section { if model.signedIn { Button("ログアウト") { model.signOut() } } else { Button("本人ログイン") { Task { await model.login() } }.disabled(!model.configuration.valid || model.busy) } }
            if model.hiddenPagesOpen { Section("暗号化の鍵") { PhoneSealedKeyImport() } }
            Section("キャッシュ") {
                Text("通常の写真とサムネイルを最大1GB保存します。容量が増えると古いものから削除します。暗号化した内容は長期保存しません。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("キャッシュを削除") { model.clearImageCache() }
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
        }
    }
}

struct PhoneZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    let onSwipe: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PhoneImageScrollView {
        let view = PhoneImageScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 6
        view.bouncesZoom = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.imageView.image = image
        view.imageView.contentMode = .scaleAspectFit
        view.addSubview(view.imageView)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        view.addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
            swipe.direction = direction
            swipe.delegate = context.coordinator
            view.addGestureRecognizer(swipe)
            view.panGestureRecognizer.require(toFail: swipe)
            tap.require(toFail: swipe)
        }
        return view
    }
    func updateUIView(_ view: PhoneImageScrollView, context: Context) {
        context.coordinator.parent = self
        if view.imageView.image !== image {
            view.setZoomScale(1, animated: false)
            view.imageView.image = image
            view.fittedSize = .zero
            view.setNeedsLayout()
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: PhoneZoomableImage
        init(_ parent: PhoneZoomableImage) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PhoneImageScrollView)?.imageView
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PhoneImageScrollView)?.centerImage()
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let scroll = gestureRecognizer.view as? UIScrollView else { return false }
            let pinch = scroll.pinchGestureRecognizer
            return Self.allowsPaging(zoomScale: scroll.zoomScale,
                                     pinchTouches: pinch?.numberOfTouches ?? 0,
                                     pinchState: pinch?.state ?? .possible)
        }
        static func allowsPaging(zoomScale: CGFloat, pinchTouches: Int, pinchState: UIGestureRecognizer.State) -> Bool {
            // A possible pinch also tracks a single finger; that is still a paging gesture.
            // Keep blocking an active pinch when one finger lifts before the other.
            zoomScale <= 1.001 && pinchTouches < 2 && pinchState != .began && pinchState != .changed
        }
        @objc func tap() { parent.onTap() }
        @objc func swipe(_ gesture: UISwipeGestureRecognizer) {
            parent.onSwipe(gesture.direction == .left ? 1 : -1)
        }
    }
}

final class PhoneImageScrollView: UIScrollView {
    let imageView = UIImageView()
    var fittedSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedSize, bounds.width > 0, bounds.height > 0,
           let image = imageView.image, image.size.width > 0, image.size.height > 0 {
            fittedSize = bounds.size
            setZoomScale(1, animated: false)
            let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio))
            contentSize = imageView.frame.size
        }
        centerImage()
    }
    func centerImage() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - imageView.frame.height) / 2), left: max(0, (bounds.width - imageView.frame.width) / 2), bottom: 0, right: 0)
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

struct ReaderSwipeScreen: View {
    static func upcomingPhotos(_ entries: [ReaderEntry], after index: Int) -> [ReaderEntry] {
        guard entries.indices.contains(index) else { return [] }
        return Array(entries.dropFirst(index + 1).lazy.filter { $0.item.mimeType.hasPrefix("image/") }.prefix(10))
    }
    @EnvironmentObject private var model: CloudViewerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let entries: [ReaderEntry]
    @State private var index = 0
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loadingStatus = "読み込みを準備中…"
    @State private var error = ""
    @State private var retry = 0
    private var entry: ReaderEntry { entries[index] }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if let player { ReaderVideoPlayer(player: player).id(ObjectIdentifier(player)) }
                else if !error.isEmpty {
                    VStack { Text(error); Button("再試行") { retry += 1 } }.foregroundStyle(.white)
                } else { ReaderLoadingView(status: loadingStatus) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("閉じる")
                    Spacer()
                    Text("\(index + 1) / \(entries.count)").font(.caption.monospacedDigit())
                }
                Spacer()
                HStack {
                    Label(entry.item.mimeType.hasPrefix("video/") ? "動画" : "写真", systemImage: entry.item.mimeType.hasPrefix("video/") ? "video" : "photo")
                    Text(entry.catalog.name).lineLimit(1)
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "chevron.up").padding(12) }.disabled(index == 0).accessibilityLabel("前へ")
                    Button { move(1) } label: { Image(systemName: "chevron.down").padding(12) }.disabled(index == entries.count - 1).accessibilityLabel("次へ")
                }.font(.caption).padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }.foregroundStyle(.white).padding()
        }
        .simultaneousGesture(DragGesture(minimumDistance: 50).onEnded { value in
            guard abs(value.translation.height) > abs(value.translation.width) else { return }
            move(value.translation.height < 0 ? 1 : -1)
        })
        .task(id: entry.id + "/\(retry)/\(scenePhase)") {
            guard scenePhase == .active else { return }
            let position = index
            await load()
            guard !Task.isCancelled, position == index, scenePhase == .active else { return }
            await model.prefetchSwipeImages(entries, after: position)
        }
        .onDisappear { clear() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clear(); dismiss() } }
    }
    private func move(_ direction: Int) {
        let next = index + direction
        guard entries.indices.contains(next) else { return }
        clear(); index = next
    }
    private func clear() { player?.pause(); player = nil; image = nil; error = ""; loadingStatus = "読み込みを準備中…" }
    private func load() async {
        let current = entry, identity = model.sessionID
        clear()
        do {
            if current.item.mimeType.hasPrefix("video/") {
                loadingStatus = "動画の接続先を取得中…"
                let url = try await model.mediaURL(current.catalog, current.item)
                guard !Task.isCancelled, identity == model.sessionID, current.id == entry.id else { return }
                player = AVPlayer(url: url)
            } else {
                let value = try await model.image(current.catalog, current.item) { status in
                    guard identity == model.sessionID, current.id == entry.id else { return }
                    loadingStatus = status
                }
                guard !Task.isCancelled, identity == model.sessionID, current.id == entry.id else { return }
                image = value
            }
        } catch {
            if !Task.isCancelled, identity == model.sessionID, current.id == entry.id { self.error = "表示できません。通信を確認してください。" }
        }
    }
}
