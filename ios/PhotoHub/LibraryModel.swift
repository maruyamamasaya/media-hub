import SwiftUI
import Photos
import PhotoHubCore

@MainActor
final class LibraryModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var albums: [Album] = []
    @Published var members: [Membership] = []
    @Published var message: String?
    @Published var busy = false
    @Published var progress: [String: Double] = [:]
    @Published var localMode: Bool { didSet { UserDefaults.standard.set(localMode, forKey: "localMode") } }
    @Published var configuration: CloudConfiguration { didSet { if let data = try? JSONEncoder().encode(configuration) { UserDefaults.standard.set(data, forKey: "cloudConfiguration") } } }
    let authentication = Authentication()
    private(set) var repository: Repository?
    private(set) var cache: DiskCache?
    let support: URL
    let pending: URL
    private let developmentRoot: URL?
    private var imagesInFlight: [String: Task<URL?, Never>] = [:]
    var objectStore: ObjectStore? {
        if localMode { return try? LocalObjectStore(root: developmentRoot ?? support.appendingPathComponent("DevelopmentObjects")) }
        guard configuration.valid else { return nil }; return S3ObjectStore(configuration: configuration, authentication: authentication)
    }
    init(baseURL: URL? = nil, cacheURL: URL? = nil, developmentRoot: URL? = nil) {
        self.developmentRoot = developmentRoot
        support = baseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoHub")
        pending = support.appendingPathComponent("Pending")
        localMode = UserDefaults.standard.object(forKey: "localMode") as? Bool ?? true
        configuration = UserDefaults.standard.data(forKey: "cloudConfiguration").flatMap { try? JSONDecoder().decode(CloudConfiguration.self, from: $0) } ?? CloudConfiguration()
        do {
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            repository = try Repository(url: support.appendingPathComponent("library.sqlite"))
            cache = try DiskCache(root: cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoHub"))
            try repository?.recoverInterruptedUploads(); try refresh()
        } catch { message = error.localizedDescription }
    }
    func refresh() throws { guard let repository else { return }; photos = try repository.photos(); albums = try repository.albums(); members = try repository.memberships() }
    func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await operation(); try refresh() } catch { message = error.localizedDescription; try? refresh() }
    }
    func importPhotos(ids: [String]) async {
        await run {
            guard let repository, let cache else { throw HubError.configuration }
            var failures: [String] = []
            for id in ids {
                if photos.contains(where: { $0.assetID == id }) { continue }
                do {
                    let imported = try await PhotoImporter.importAsset(id: id, pending: pending, cache: cache)
                    if try repository.photos().contains(where: { $0.sha256 == imported.photo.sha256 }) {
                        try? FileManager.default.removeItem(at: imported.directory); continue
                    }
                    do { try repository.save(imported.photo) } catch { try? FileManager.default.removeItem(at: imported.directory); throw error }
                    try refresh()
                } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { message = "\(failures.count)件の取り込みに失敗: \(failures[0])" }
        }
    }
    func source(_ photo: Photo, _ kind: ImageKind) -> URL {
        pending.appendingPathComponent(photo.id).appendingPathComponent(kind == .original ? "original" : "\(kind.rawValue).jpg")
    }
    func image(_ photo: Photo, kind: ImageKind) async -> URL? {
        guard let cache else { return nil }
        if let cached = cache.cached(id: photo.id, kind: kind) { return cached }
        let local = source(photo, kind)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let identifier = photo.id + kind.rawValue
        if let task = imagesInFlight[identifier] { return await task.value }
        let task = Task<URL?, Never> { [self] in
            guard let store = objectStore, let key = photo.keys[kind.rawValue], key == ObjectKeys.photo(owner: store.owner, id: photo.id, kind: kind) else { return nil }
            do {
                let destination = cache.file(id: photo.id, kind: kind)
                try await store.get(key: key, destination: destination)
                // The visible image can outlive its cache file; trim after each fetch.
                let result = cache.cached(id: photo.id, kind: kind); try cache.trim(); return result
            } catch { return nil }
        }
        imagesInFlight[identifier] = task
        let result = await task.value; imagesInFlight.removeValue(forKey: identifier); return result
    }
    func playbackURL(_ photo: Photo) -> URL? {
        // No original fallback and no network transfer for the legacy video model.
        guard photo.mime.hasPrefix("video/") else { return nil }
        let file = pending.appendingPathComponent(photo.id).appendingPathComponent("playback.mp4")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if let cached = cache?.root.appendingPathComponent("\(photo.id)-playback.mp4"), FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
            return cached
        }
        return nil
    }
    func loadPlayback(_ photo: Photo) async -> URL? {
        if let file = playbackURL(photo) { return file }
        guard photo.mime.hasPrefix("video/"), let cache, let store = objectStore,
              let key = photo.keys["playback"], key == "users/\(store.owner)/photos/\(photo.id)/playback.mp4" else { return nil }
        let destination = cache.root.appendingPathComponent("\(photo.id)-playback.mp4")
        do {
            try await store.get(key: key, destination: destination)
            let bytes = try Digest.bytes(file: destination), sha = try Digest.checksum(file: destination)
            guard let info = try await store.head(key: key), info.bytes == bytes, info.checksum == sha else { throw HubError.integrity }
            try cache.trim()
            return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
        } catch { try? FileManager.default.removeItem(at: destination); return nil }
    }
    func uploadPending() async {
        await run {
            guard let repository, let store = objectStore else { throw HubError.configuration }
            for var photo in try repository.photos() where photo.state != .uploaded && photo.state != .deleting {
                do {
                    guard localMode || !photo.mime.hasPrefix("video/") else { throw NSError(domain: "PhotoHub", code: 4, userInfo: [NSLocalizedDescriptionKey: "動画は端末内に保管しています。クラウド転送は未対応です。原本と再生用動画は保持します。"]) }
                    // Never migrate existing objects silently between development and AWS owners.
                    guard photo.keys.isEmpty || photo.keys.values.allSatisfy({ $0.hasPrefix("users/\(store.owner)/") }) else { throw HubError.configuration }
                    for kind in ImageKind.allCases { photo.keys[kind.rawValue] = ObjectKeys.photo(owner: store.owner, id: photo.id, kind: kind) }
                    photo.state = .uploading; photo.error = nil; progress[photo.id] = 0; try repository.save(photo); try refresh()
                    let id = photo.id
                    try await PhotoTransfer.upload(photo: photo, directory: pending.appendingPathComponent(photo.id), store: store) { fraction in
                        Task { @MainActor [weak self] in self?.progress[id] = fraction }
                    }
                    if photo.mime.hasPrefix("video/") {
                        guard let playback = playbackURL(photo) else { throw HubError.missingOriginal }
                        let key = "users/\(store.owner)/photos/\(photo.id)/playback.mp4"
                        photo.keys["playback"] = key
                        let sha = try Digest.checksum(file: playback), size = try Digest.bytes(file: playback)
                        try await store.put(file: playback, key: key, mime: "video/mp4", checksum: sha, progress: { _ in })
                        guard let info = try await store.head(key: key), info.bytes == size, info.checksum == sha else { throw HubError.integrity }
                    }
                    photo.state = .uploaded; progress[photo.id] = 1
                } catch { photo.state = .failed; photo.error = error.localizedDescription }
                try repository.save(photo); try refresh()
            }
            let count = photos.filter { $0.state == .failed }.count
            message = count == 0 ? "保存を確認しました。" : "\(count)件失敗。状態を確認して再試行してください。"
        }
    }
    func setFavorite(_ photo: Photo) { guard !busy else { return }; do { var updated = photo; updated.favorite.toggle(); try repository?.save(updated); try refresh() } catch { message = error.localizedDescription } }
    func addAlbum(name: String) { guard !busy, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; do { try repository?.save(Album(name: name)); try refresh() } catch { message = error.localizedDescription } }
    func toggleMembership(photo: Photo, album: Album) {
        guard !busy else { return }
        do { if members.contains(where: { $0.photoID == photo.id && $0.albumID == album.id }) { try repository?.remove(photoID: photo.id, albumID: album.id) } else { try repository?.add(photoID: photo.id, albumID: album.id) }; try refresh() } catch { message = error.localizedDescription }
    }
    func requestDelete(_ photo: Photo) async {
        await run { var updated = photo; updated.state = .deleting; try repository?.save(updated); try refresh(); try await finishDelete(updated) }
    }
    private func finishDelete(_ photo: Photo) async throws {
        if !photo.keys.isEmpty {
            guard let store = objectStore else { throw HubError.configuration }
            for kind in ImageKind.allCases {
                guard let key = photo.keys[kind.rawValue], key == ObjectKeys.photo(owner: store.owner, id: photo.id, kind: kind) else { throw HubError.configuration }
                try await store.delete(key: key)
            }
        }
        if let key = photo.keys["playback"] {
            guard let store = objectStore, key == "users/\(store.owner)/photos/\(photo.id)/playback.mp4" else { throw HubError.configuration }
            try await store.delete(key: key)
        }
        // Persisted deleting state survives partial remote deletion.
        try repository?.delete(photoID: photo.id)
        try? FileManager.default.removeItem(at: pending.appendingPathComponent(photo.id))
        for kind in [ImageKind.thumbnail, .display] { if let cache { try? FileManager.default.removeItem(at: cache.file(id: photo.id, kind: kind)) } }
        if let cache { try? FileManager.default.removeItem(at: cache.root.appendingPathComponent("\(photo.id)-playback.mp4")) }
    }
    func retryDeletes() async { await run { for photo in photos where photo.state == .deleting { try await finishDelete(photo) }; message = "削除を完了しました。" } }
    func releaseOriginals() async {
        await run {
            guard let store = objectStore else { throw HubError.configuration }
            guard !localMode else { throw NSError(domain: "PhotoHub", code: 2, userInfo: [NSLocalizedDescriptionKey: "開発用保存は同じ端末内です。原本の容量解放はAWS保存の確認後に利用できます。"] ) }
            for photo in photos where photo.state == .uploaded {
                for kind in ImageKind.allCases {
                    guard let key = photo.keys[kind.rawValue], key == ObjectKeys.photo(owner: store.owner, id: photo.id, kind: kind), let info = try await store.head(key: key), info.bytes > 0 else { throw HubError.integrity }
                    if kind == .original { guard info.bytes == photo.bytes && info.checksum == photo.sha256 else { throw HubError.integrity } }
                }
                let directory = pending.appendingPathComponent(photo.id)
                if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            }
            message = "確認済みの端末内コピーを解放しました。写真ライブラリは変更していません。"
        }
    }
    func saveOriginal(_ photo: Photo) async {
        await run {
            let file = source(photo, .original)
            if !FileManager.default.fileExists(atPath: file.path) {
                guard let store = objectStore, let key = photo.keys[ImageKind.original.rawValue], key == ObjectKeys.photo(owner: store.owner, id: photo.id, kind: .original) else { throw HubError.configuration }
                try await store.get(key: key, destination: file)
            }
            guard try Digest.checksum(file: file) == photo.sha256 else { throw HubError.integrity }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw HubError.configuration }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset(); let options = PHAssetResourceCreationOptions(); options.originalFilename = photo.filename
                request.addResource(with: photo.mime.hasPrefix("video/") ? .video : .photo, fileURL: file, options: options)
            }
            message = "写真ライブラリに原本を保存しました。"
        }
    }
    func backup() async {
        await run {
            guard let repository, let store = objectStore else { throw HubError.configuration }
            guard photos.allSatisfy({ $0.state == .uploaded }) else { throw NSError(domain: "PhotoHub", code: 3, userInfo: [NSLocalizedDescriptionKey: "未完了のアップロードと削除を完了してからバックアップしてください。"]) }
            let snapshot = try repository.snapshot(owner: store.owner), encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = support.appendingPathComponent("backup.json"); try encoder.encode(snapshot).write(to: file, options: .atomic)
            let id = UUID().uuidString.lowercased(), key = "users/\(store.owner)/backups/\(id).json"
            let checksum = try Digest.checksum(file: file), bytes = try Digest.bytes(file: file)
            try await store.put(file: file, key: key, mime: "application/json", checksum: checksum, progress: { _ in })
            guard let info = try await store.head(key: key), info.bytes == bytes, info.checksum == checksum else { throw HubError.integrity }
            // Latest is a pointer; immutable snapshots preserve the previous normal backup.
            let pointer = support.appendingPathComponent("latest.json")
            try JSONSerialization.data(withJSONObject: ["key": key, "checksum": checksum]).write(to: pointer, options: .atomic)
            try await store.put(file: pointer, key: "users/\(store.owner)/backups/latest.json", mime: "application/json", checksum: Digest.checksum(file: pointer), progress: { _ in })
            let pointerBytes = try Digest.bytes(file: pointer), pointerChecksum = try Digest.checksum(file: pointer)
            guard let pointerInfo = try await store.head(key: "users/\(store.owner)/backups/latest.json"), pointerInfo.bytes == pointerBytes, pointerInfo.checksum == pointerChecksum else { throw HubError.integrity }
            message = localMode ? "開発用JSON保存を確認しました。アプリ削除では失われます。" : "クラウドバックアップを保存しました。"
        }
    }
    func restore() async {
        await run {
            guard let repository, let store = objectStore else { throw HubError.configuration }
            guard try repository.photos().isEmpty, try repository.albums().isEmpty else { throw HubError.notEmpty }
            let pointer = support.appendingPathComponent("restore-pointer.json"), file = support.appendingPathComponent("restore.json")
            try await store.get(key: "users/\(store.owner)/backups/latest.json", destination: pointer)
            guard let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: pointer)) as? [String: String], let key = payload["key"], key.hasPrefix("users/\(store.owner)/backups/"), let checksum = payload["checksum"] else { throw HubError.invalidBackup }
            try await store.get(key: key, destination: file)
            guard try Digest.checksum(file: file) == checksum else { throw HubError.integrity }
            let snapshot = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: file)); try repository.restore(snapshot, owner: store.owner)
            message = "バックアップ時点へ復元しました。以降の変更は含まれません。欠損画像は再取得時に確認します。"
        }
    }
}
