import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import AVKit
import ImageIO
import Network
import PhotoHubCore
import AssetLibraryContract

struct PhoneSealedKeyImport: View {
    @State private var choosing = false
    @State private var file: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Macで保存したパスワード付き復旧ファイルを読み込みます。鍵はこのiPhoneのKeychainへ保管します。").font(.callout).foregroundStyle(.secondary)
            Button("復旧ファイルを読み込む") { choosing = true }
        }.fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { result in if case .success(let url) = result { file = url } }
            .sheet(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } })) { if let file { PhoneSealedKeySheet(file: file) } }
    }
}
struct PhoneSealedKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: URL
    @State private var password = ""
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                Text("復旧ファイルのパスワードを入力してください。")
                SecureField("パスワード", text: $password)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                if busy { ProgressView("鍵を読み込み中…") }
                Button("読み込む") { load() }.disabled(password.isEmpty || busy)
            }.navigationTitle("暗号化の鍵")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { password = ""; dismiss() }.disabled(busy) } }
        }.interactiveDismissDisabled(busy)
    }
    private func load() {
        busy = true; error = ""
        let entered = password; password = ""
        Task {
            defer { busy = false }
            do {
                let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65536 else { throw SealedError.tooLarge }
                let data = try Data(contentsOf: file)
                let secret = try await Task.detached { try RecoveryFile.restore(data, password: entered) }.value
                try MediaSecretStore.save(secret)
                NotificationCenter.default.post(name: Notification.Name("MediaHubEncryptionKeyChanged"), object: nil)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
@MainActor
func phoneSealedReader(_ model: CloudViewerModel, root: SealedRoot, secret: MediaSecret, objectID: String?, length: Int64?, maximum: Int64) -> SealedRangeReader {
    let identity = model.sessionID
    let http = SealedHTTP(usageScope: model.usageScope) { [weak model] in
        guard let model, await model.sessionID == identity else { throw CancellationError() }
        return try await model.encryptedURL(root, objectID: objectID)
    }
    return SealedRangeReader(objectID: objectID ?? root.id, master: secret.masterKey, expectedLength: length, maximumLength: maximum) { range in try await http.bytes(range) }
}
// HiddenPagePINSheet verifies the stored PIN before invoking its open callback.
// Setup is disabled here: this second step must use the existing device PIN.
struct PhoneSealedEntry: View {
    let favoritesOnly: Bool
    let onOpen: () -> Void
    @EnvironmentObject private var model: CloudViewerModel
    @State private var showingPIN = false
    @State private var verified = false
    private var title: String { favoritesOnly ? "暗号化したお気に入り" : "暗号化したファイルを見る" }

    var body: some View {
        Button {
            verified = false
            showingPIN = true
        } label: {
            HStack {
                Label(title, systemImage: favoritesOnly ? "heart" : "lock.shield")
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: $showingPIN, onDismiss: {
            if verified && model.signedIn && model.hiddenPagesOpen { onOpen() }
            verified = false
        }) {
            let identity = model.sessionID
            HiddenPagePINSheet(title: title, allowsSetup: false) { _ in
                guard identity == model.sessionID, model.signedIn, model.hiddenPagesOpen else { return }
                verified = true
            }
        }
    }
}

struct PhoneSealedLibrary: View {
    var favoritesOnly = false
    @EnvironmentObject private var model: CloudViewerModel
    @State private var secret: MediaSecret?
    @State private var roots: [SealedRoot] = []
    @State private var error = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.signedIn { Text("「見る」から本人ログインしてください。") }
                else {
                    if let secret {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                            ForEach(roots.filter { root in root.keyID == secret.keyID && (!favoritesOnly || model.favorites.contains { $0.space == "sealed" && $0.rootId == root.keyID && $0.catalogId == root.id }) }) { root in PhoneSealedRootRow(root: root, secret: secret, favoritesOnly: favoritesOnly) }
                        }
                        if roots.filter({ $0.keyID == secret.keyID }).isEmpty { ContentUnavailableView("フォルダはまだありません", systemImage: "folder") }
                        DisclosureGroup("暗号化の鍵") { PhoneSealedKeyImport() }
                    } else { PhoneSealedKeyImport() }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.padding(16)
        }.navigationTitle(favoritesOnly ? "暗号化したお気に入り" : "暗号化したファイル").navigationBarTitleDisplayMode(.inline).task { await load() }
            .refreshable { await load() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MediaHubEncryptionKeyChanged"))) { _ in Task { await load() } }
            .toolbar { Button("更新", systemImage: "arrow.clockwise") { Task { await load() } } }
    }
    private func load() async {
        guard model.signedIn, model.hiddenPagesOpen else { secret = nil; roots = []; return }
        let identity = model.sessionID
        do {
            let loadedSecret = try MediaSecretStore.load()
            let loadedRoots = loadedSecret == nil ? [] : try await model.encryptedRoots()
            guard identity == model.sessionID, model.signedIn, model.hiddenPagesOpen, !Task.isCancelled else { return }
            secret = loadedSecret; roots = loadedRoots
            error = ""
        } catch { if identity == model.sessionID { self.error = error.localizedDescription } }
    }
}
struct PhoneSealedRootRow: View {
    @EnvironmentObject private var model: CloudViewerModel
    let root: SealedRoot; let secret: MediaSecret
    var favoritesOnly = false
    @State private var catalog: SealedCatalog?
    @State private var error = ""
    var body: some View {
        Group {
            if let catalog {
                NavigationLink { PhoneSealedFolder(root: root, catalog: catalog, secret: secret, folderID: catalog.folders.first { $0.parentId == nil }?.id, favoritesOnly: favoritesOnly) } label: {
                    PhoneSealedFolderTile(root: root, catalog: catalog, secret: secret, name: catalog.name, folderID: catalog.folders.first { $0.parentId == nil }?.id)
                }.buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    if let folder = catalog.folders.first(where: { $0.parentId == nil }) { PhoneFavoriteButton(reference: FavoriteReference(space: "sealed", root: root.keyID, catalog: root.id, target: folder.id, kind: "folder")).padding(4) }
                }
            } else if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else { ProgressView("暗号化フォルダを復号中…") }
        }.task {
            let identity = model.sessionID
            let reader = phoneSealedReader(model, root: root, secret: secret, objectID: nil, length: nil, maximum: Int64(CatalogLimits.maximumBytes))
            do {
                let bytes = try await reader.allData()
                let value = try JSONDecoder().decode(SealedCatalog.self, from: bytes); try value.validate(root: root, secret: secret)
                if identity == model.sessionID, !Task.isCancelled { catalog = value }
            } catch { if identity == model.sessionID { self.error = "復旧ファイル・ログイン・通信を確認してください。" } }
            await reader.close()
        }
    }
}
struct PhoneSealedFolderTile: View {
    let root: SealedRoot; let catalog: SealedCatalog; let secret: MediaSecret
    let name: String; let folderID: String?
    private var cover: SealedItem? {
        var ids = Set<String>(); if let folderID { ids.insert(folderID) }
        for _ in 0..<catalog.folders.count {
            let children = catalog.folders.filter { $0.parentId.map { ids.contains($0) } == true }.map(\.id)
            let before = ids.count; ids.formUnion(children); if ids.count == before { break }
        }
        let candidates = catalog.items.filter { ids.contains($0.folderId) && $0.thumbnailID != nil }
        return candidates.first { $0.mimeType.hasPrefix("image/") } ?? candidates.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let cover { PhoneSealedThumbnail(root: root, item: cover, secret: secret) }
                else { ZStack { Color.secondary.opacity(0.10); Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.secondary) }.aspectRatio(1, contentMode: .fit) }
            }.clipShape(RoundedRectangle(cornerRadius: 16))
            Text(name).font(.caption.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
        }.accessibilityElement(children: .combine)
    }
}
struct PhoneSealedFolder: View {
    @EnvironmentObject private var model: CloudViewerModel
    let root: SealedRoot; let catalog: SealedCatalog; let secret: MediaSecret; let folderID: String?
    var favoritesOnly = false
    @State private var query = ""
    @State private var order: LibraryOrder = .name
    private func ref(_ id: String, _ kind: String) -> FavoriteReference { FavoriteReference(space: "sealed", root: root.keyID, catalog: root.id, target: id, kind: kind) }
    @State private var selected: SealedItem?
    private var items: [SealedItem] { order.arrange(catalog.items.filter { favoritesOnly ? model.isFavorite(ref($0.id, "item")) : $0.folderId == folderID }, query: query, name: { $0.name }, size: { $0.byteSize }) }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let children = order.arrange(catalog.folders.filter { favoritesOnly ? model.isFavorite(ref($0.id, "folder")) : $0.parentId == folderID }, query: query, name: { $0.name }, size: { folder in catalog.items.filter { $0.folderId == folder.id }.reduce(0) { $0 + $1.byteSize } })
                if !children.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                        ForEach(children) { folder in
                            NavigationLink { PhoneSealedFolder(root: root, catalog: catalog, secret: secret, folderID: folder.id) } label: {
                                PhoneSealedFolderTile(root: root, catalog: catalog, secret: secret, name: folder.name, folderID: folder.id)
                            }.buttonStyle(.plain)
                            .overlay(alignment: .topTrailing) { PhoneFavoriteButton(reference: ref(folder.id, "folder")).padding(4) }
                        }
                    }.padding(.horizontal, 12)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(items) { item in
                        Button { selected = item } label: { PhoneSealedThumbnail(root: root, item: item, secret: secret) }
                            .buttonStyle(.plain).accessibilityLabel(item.mimeType == "application/pdf" ? item.name : (item.mimeType.hasPrefix("video/") ? "動画" : "写真"))
                    }
                }
                if children.isEmpty && items.isEmpty { ContentUnavailableView("空のフォルダ", systemImage: "folder") }
            }.padding(.vertical, 8)
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "このフォルダ内を検索")
        .toolbar {
            ToolbarItem { ReaderSortPicker(order: $order) }
            ToolbarItem { if let folderID { PhoneFavoriteButton(reference: ref(folderID, "folder")) } }
        }
        .fullScreenCover(item: $selected) { item in PhoneSealedMediaScreen(root: root, items: items, secret: secret, initialID: item.id) }
    }
}
/// Screen-scoped plaintext only. No URLCache, DiskCache or file writes.
@MainActor
final class PhoneSealedImageSession: ObservableObject {
    static let maximumMemoryBytes = 128 * 1024 * 1024
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var errors: Set<String> = []
    @Published private(set) var networkAllowsPrefetch = false
    private var pending: [String: (UUID, Task<UIImage, Error>)] = [:]
    private var order: [String] = []
    private var generation = UUID()
    private var closed = false
    private let monitor = NWPathMonitor()

    init(monitorNetwork: Bool = true) {
        if monitorNetwork {
            monitor.pathUpdateHandler = { [weak self] path in
                let allowed = Self.allowsPrefetch(satisfied: path.status == .satisfied,
                    wifi: path.usesInterfaceType(.wifi), wired: path.usesInterfaceType(.wiredEthernet),
                    expensive: path.isExpensive, constrained: path.isConstrained)
                Task { @MainActor [weak self] in
                    guard let self, !self.closed else { return }
                    self.networkAllowsPrefetch = allowed
                }
            }
            monitor.start(queue: DispatchQueue(label: "media-hub.sealed-prefetch-path"))
        }
    }
    nonisolated static func allowsPrefetch(satisfied: Bool, wifi: Bool, wired: Bool, expensive: Bool, constrained: Bool) -> Bool {
        satisfied && (wifi || wired) && !expensive && !constrained
    }
    func select(current: String, next: String?, previous: String?) {
        guard !closed else { return }
        order = [current] + [next, previous].compactMap { $0 }
        let allowed = Set(order)
        let activeLoads = Set([current] + [next].compactMap { $0 })
        for (id, task) in pending where !activeLoads.contains(id) { task.1.cancel(); pending[id] = nil }
        images = images.filter { allowed.contains($0.key) }
        errors = errors.intersection(allowed)
        trim()
    }
    private func trim() {
        var remaining = Self.maximumMemoryBytes
        images = order.reduce(into: [:]) { kept, id in
            guard let image = images[id], let cg = image.cgImage else { return }
            let bytes = cg.bytesPerRow * cg.height
            if bytes <= remaining { kept[id] = image; remaining -= bytes }
        }
    }
    func image(_ item: SealedItem, authorized: @escaping () -> Bool,
               load: @escaping () async throws -> Data) async throws -> UIImage {
        guard !closed, authorized(), order.contains(item.objectID) else { throw CancellationError() }
        if let cached = images[item.objectID] { return cached }
        let task: Task<UIImage, Error>
        if let existing = pending[item.objectID] { task = existing.1 }
        else {
            let ticket = UUID(), epoch = generation
            errors.remove(item.objectID)
            task = Task {
                defer { if self.pending[item.objectID]?.0 == ticket { self.pending[item.objectID] = nil } }
                do {
                    let bytes = try await load()
                    try Task.checkCancellation()
                    let value = try await Self.prepare(bytes, item: item)
                    try Task.checkCancellation()
                    guard !self.closed, self.generation == epoch, authorized(), self.order.contains(item.objectID) else { throw CancellationError() }
                    self.images[item.objectID] = value
                    self.trim()
                    return value
                } catch {
                    if !Task.isCancelled, !self.closed, self.generation == epoch, authorized(), self.order.contains(item.objectID) {
                        self.errors.insert(item.objectID)
                    }
                    throw error
                }
            }
            pending[item.objectID] = (ticket, task)
        }
        let value = try await task.value
        try Task.checkCancellation()
        guard !closed, authorized() else { throw CancellationError() }
        return value
    }
    nonisolated static func prepare(_ bytes: Data, item: SealedItem) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            guard Int64(bytes.count) == item.byteSize,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == item.sha256,
                  let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) else { throw SealedError.invalid }
            return UIImage(cgImage: cg)
        }.value
    }
    func close() {
        closed = true; generation = UUID()
        monitor.cancel(); monitor.pathUpdateHandler = nil
        for task in pending.values { task.1.cancel() }
        pending = [:]; images = [:]; errors = []; order = []; networkAllowsPrefetch = false
    }
    deinit { monitor.cancel() }
}

@MainActor
private func phoneSealedPhoto(_ model: CloudViewerModel, root: SealedRoot, secret: MediaSecret, item: SealedItem) async throws -> Data {
    let reader = phoneSealedReader(model, root: root, secret: secret, objectID: item.objectID, length: item.byteSize, maximum: 100 * 1024 * 1024)
    return try await withTaskCancellationHandler {
        do {
            let bytes = try await reader.allData()
            await reader.close()
            return bytes
        } catch { await reader.close(); throw error }
    } onCancel: { Task { await reader.close() } }
}

struct PhoneSealedMediaScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sealedPhotoPrefetch") private var prefetchEnabled = true
    @StateObject private var photos = PhoneSealedImageSession()
    @State private var retry = 0
    @State private var prefetchSuspended = false
    @EnvironmentObject private var model: CloudViewerModel
    @Environment(\.dismiss) private var dismiss
    let root: SealedRoot; let items: [SealedItem]; let secret: MediaSecret; let initialID: String
    @State private var index: Int
    @State private var controls = true
    @State private var zoomed = false
    init(root: SealedRoot, items: [SealedItem], secret: MediaSecret, initialID: String) {
        self.root = root; self.items = items; self.secret = secret; self.initialID = initialID
        _index = State(initialValue: items.firstIndex { $0.id == initialID } ?? 0)
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativeMediaPager(count: items.count, selection: $index, enabled: !zoomed && items[index].mimeType != "application/pdf") { position, active in
                PhoneSealedMedia(root: root, item: items[position], secret: secret, photos: photos, controls: $controls,
                                 active: active && scenePhase == .active, onZoom: { if active { zoomed = $0 } }, onRetry: { retry += 1 })
                    .environmentObject(model)
            }.ignoresSafeArea()
            if controls || items[index].mimeType.hasPrefix("video/") {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("閉じる")
                        Spacer()
                        Text("\(index + 1) / \(items.count)").font(.caption.monospacedDigit())
                        PhoneFavoriteButton(reference: FavoriteReference(space: "sealed", root: root.keyID, catalog: root.id, target: items[index].id, kind: "item"))
                        if items[index].mimeType == "application/pdf" {
                            Button { move(-1) } label: { Image(systemName: "chevron.left").padding(10) }.disabled(index == 0).accessibilityLabel("前のファイル")
                            Button { move(1) } label: { Image(systemName: "chevron.right").padding(10) }.disabled(index + 1 == items.count).accessibilityLabel("次のファイル")
                        }
                    }.foregroundStyle(.white).padding()
                    Spacer()
                }
            }
        }.onChange(of: index) { _, _ in controls = true; zoomed = false }
        .task(id: "\(index)/\(photos.networkAllowsPrefetch)/\(prefetchEnabled)/\(retry)/\(prefetchSuspended)") { await preparePhotos() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { photos.close(); dismiss() } }
        .onChange(of: model.sessionID) { _, _ in photos.close(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MediaHubEncryptionKeyChanged"))) { _ in photos.close(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            prefetchSuspended = true
            photos.select(current: items[index].objectID, next: nil, previous: nil)
        }
        .onDisappear { photos.close() }
    }
    private func preparePhotos() async {
        guard scenePhase == .active, model.signedIn, model.hiddenPagesOpen else { return }
        let identity = model.sessionID
        let current = items[index]
        let next = items.indices.contains(index + 1) && prefetchEnabled && !prefetchSuspended && photos.networkAllowsPrefetch ? items[index + 1] : nil
        let previous = !prefetchSuspended && items.indices.contains(index - 1) ? items[index - 1].objectID : nil
        photos.select(current: current.objectID, next: next?.objectID, previous: previous)
        let authorized = { model.sessionID == identity && model.signedIn && model.hiddenPagesOpen }
        guard !current.mimeType.hasPrefix("video/"), current.mimeType != "application/pdf" else { return }
        do {
            _ = try await photos.image(current, authorized: authorized) { try await phoneSealedPhoto(model, root: root, secret: secret, item: current) }
            guard !Task.isCancelled, authorized(), let next, photos.images[next.objectID] == nil,
                  model.reserveSealedPhotoPrefetch(root, item: next) else { return }
            _ = try await photos.image(next, authorized: authorized) { try await phoneSealedPhoto(model, root: root, secret: secret, item: next) }
        } catch { /* Display failure is published by the screen-scoped session. */ }
    }
    private func move(_ direction: Int) { let next = index + direction; if items.indices.contains(next) { index = next } }
}

struct PhoneSealedThumbnail: View {
    @EnvironmentObject private var model: CloudViewerModel
    let root: SealedRoot; let item: SealedItem; let secret: MediaSecret
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
        }.aspectRatio(1, contentMode: .fit).task {
            guard let id = item.thumbnailID, let count = item.thumbnailBytes else { return }
            let identity = model.sessionID
            let reader = phoneSealedReader(model, root: root, secret: secret, objectID: id, length: count, maximum: 50000)
            if let bytes = try? await reader.allData(), identity == model.sessionID, !Task.isCancelled { image = UIImage(data: bytes) }
            await reader.close()
        }.onDisappear { image = nil }
    }
}
struct PhoneSealedMedia: View {
    @EnvironmentObject private var model: CloudViewerModel
    let root: SealedRoot; let item: SealedItem; let secret: MediaSecret
    @ObservedObject var photos: PhoneSealedImageSession
    @State private var pdf: Data?
    @State private var player: AVPlayer?
    @Binding var controls: Bool
    let active: Bool
    let onZoom: (Bool) -> Void
    var onRetry: () -> Void = {}
    @State private var loader: SealedPlayerLoader?
    @State private var reader: SealedRangeReader?
    @State private var error = ""
    @State private var loadingStatus = "暗号化データの読み込みを準備中…"
    var body: some View {
        Group {
            if let pdf { MediaPDFReader(data: pdf).padding(.top, 64) }
            else if let image = photos.images[item.objectID] { PhoneZoomableImage(image: image, onTap: { controls.toggle() }, onZoomChanged: onZoom) }
            else if let player { ReaderVideoPlayer(player: player).id(ObjectIdentifier(player)) }
            else if photos.errors.contains(item.objectID) {
                VStack { Text("鍵・通信・ファイルサイズを確認してください。"); Button("再試行", action: onRetry) }.foregroundStyle(.white)
            }
            else if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else { ReaderLoadingView(status: loadingStatus) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        .task(id: active) {
            guard active, item.mimeType.hasPrefix("video/") || item.mimeType == "application/pdf" else { return }
            let identity = model.sessionID
            let reader = phoneSealedReader(model, root: root, secret: secret, objectID: item.objectID, length: item.byteSize, maximum: item.mimeType.hasPrefix("video/") ? 5 * 1024 * 1024 * 1024 : (item.mimeType == "application/pdf" ? PDFLimits.maximumBytes : 100 * 1024 * 1024))
            self.reader = reader
            do {
                if item.mimeType.hasPrefix("video/") {
                    let loader = SealedPlayerLoader(reader: reader, mime: item.mimeType)
                    if identity == model.sessionID, !Task.isCancelled { self.loader = loader; player = AVPlayer(playerItem: AVPlayerItem(asset: loader.asset)); model.recordVideoStart() }
                } else {
                    loadingStatus = item.mimeType == "application/pdf" ? "PDFを受信・復号中…" : "画像を受信・復号中…"
                    let bytes = try await reader.allData(maximumBytes: item.mimeType == "application/pdf" ? PDFLimits.maximumBytes : 100 * 1024 * 1024)
                    loadingStatus = "照合・表示準備中…"
                    guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == item.sha256 else { throw SealedError.invalid }
                    guard identity == model.sessionID, !Task.isCancelled else { return }
                    pdf = bytes
                }
            } catch { if !Task.isCancelled, identity == model.sessionID { self.error = "鍵・通信・ファイルサイズを確認してください。" } }
        }.onChange(of: active) { _, active in if !active { clear() } }
        .onDisappear { clear() }
    }
    private func clear() {
        player?.pause(); player = nil; loader?.close(); loader = nil; pdf = nil; error = ""
        if let reader { Task { await reader.close() } }; reader = nil

    }
}

// Stay below the owner reader API's 20 requests/second limit.
// Reserve only when a request can start: cancelled tiles must not leave a backlog.
actor SealedRequestGate {
    private var next = ContinuousClock.now
    func wait() async throws {
        let clock = ContinuousClock()
        while true {
            try Task.checkCancellation()
            let now = clock.now
            if now >= next {
                next = now.advanced(by: .milliseconds(60))
                return
            }
            try await clock.sleep(until: next)
        }
    }
}
