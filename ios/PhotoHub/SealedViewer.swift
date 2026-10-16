import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import AVKit
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
struct PhoneSealedLibrary: View {
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
                            ForEach(roots.filter { $0.keyID == secret.keyID }) { root in PhoneSealedRootRow(root: root, secret: secret) }
                        }
                        if roots.filter({ $0.keyID == secret.keyID }).isEmpty { ContentUnavailableView("フォルダはまだありません", systemImage: "folder") }
                        DisclosureGroup("暗号化の鍵") { PhoneSealedKeyImport() }
                    } else { PhoneSealedKeyImport() }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.padding(16)
        }.navigationTitle("暗号化フォルダ").navigationBarTitleDisplayMode(.inline).task { await load() }
            .refreshable { await load() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MediaHubEncryptionKeyChanged"))) { _ in Task { await load() } }
            .toolbar { Button("更新", systemImage: "arrow.clockwise") { Task { await load() } } }
    }
    private func load() async {
        do {
            secret = try MediaSecretStore.load()
            if model.signedIn, secret != nil { roots = try await model.encryptedRoots() }
            error = ""
        } catch { self.error = error.localizedDescription }
    }
}
struct PhoneSealedRootRow: View {
    @EnvironmentObject private var model: CloudViewerModel
    let root: SealedRoot; let secret: MediaSecret
    @State private var catalog: SealedCatalog?
    @State private var error = ""
    var body: some View {
        Group {
            if let catalog {
                NavigationLink { PhoneSealedFolder(root: root, catalog: catalog, secret: secret, folderID: catalog.folders.first { $0.parentId == nil }?.id) } label: {
                    PhoneSealedFolderTile(root: root, catalog: catalog, secret: secret, name: catalog.name, folderID: catalog.folders.first { $0.parentId == nil }?.id)
                }.buttonStyle(.plain)
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
    let root: SealedRoot; let catalog: SealedCatalog; let secret: MediaSecret; let folderID: String?
    @State private var selected: SealedItem?
    private var items: [SealedItem] { catalog.items.filter { $0.folderId == folderID } }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let children = catalog.folders.filter { $0.parentId == folderID }
                if !children.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 14) {
                        ForEach(children) { folder in
                            NavigationLink { PhoneSealedFolder(root: root, catalog: catalog, secret: secret, folderID: folder.id) } label: {
                                PhoneSealedFolderTile(root: root, catalog: catalog, secret: secret, name: folder.name, folderID: folder.id)
                            }.buttonStyle(.plain)
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
        .fullScreenCover(item: $selected) { item in PhoneSealedMediaScreen(root: root, items: items, secret: secret, initialID: item.id) }
    }
}
struct PhoneSealedMediaScreen: View {
    @Environment(\.dismiss) private var dismiss
    let root: SealedRoot; let items: [SealedItem]; let secret: MediaSecret; let initialID: String
    @State private var index = 0
    @State private var controls = true
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhoneSealedMedia(root: root, item: items[index], secret: secret, controls: $controls, onSwipe: move)
                .id(items[index].id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                    guard items[index].mimeType.hasPrefix("video/"), abs(value.translation.width) > abs(value.translation.height) else { return }
                    move(value.translation.width < 0 ? 1 : -1)
                })
            if controls || items[index].mimeType.hasPrefix("video/") {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("閉じる")
                        Spacer()
                    }.foregroundStyle(.white).padding()
                    Spacer()
                }
            }
        }.onAppear { index = items.firstIndex { $0.id == initialID } ?? 0 }
    }
    private func move(_ direction: Int) {
        let next = index + direction
        if items.indices.contains(next) { index = next; controls = true }
    }
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
    @State private var image: UIImage?
    @State private var pdf: Data?
    @State private var player: AVPlayer?
    @Binding var controls: Bool
    let onSwipe: (Int) -> Void
    @State private var loader: SealedPlayerLoader?
    @State private var reader: SealedRangeReader?
    @State private var error = ""
    @State private var loadingStatus = "暗号化データの読み込みを準備中…"
    var body: some View {
        Group {
            if let pdf { MediaPDFReader(data: pdf).padding(.top, 64) }
            else if let image { PhoneZoomableImage(image: image, onTap: { controls.toggle() }, onSwipe: onSwipe) }
            else if let player { ReaderVideoPlayer(player: player).id(ObjectIdentifier(player)) }
            else if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else { ReaderLoadingView(status: loadingStatus) }
        }.task {
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
                    if item.mimeType == "application/pdf" { pdf = bytes }
                    else {
                        guard let value = UIImage(data: bytes) else { throw SealedError.invalid }
                        image = value
                    }
                }
            } catch { if identity == model.sessionID { self.error = "鍵・通信・ファイルサイズを確認してください。" } }
        }.onDisappear { player?.pause(); player = nil; loader?.close(); loader = nil; image = nil; pdf = nil; if let reader { Task { await reader.close() } }; reader = nil }
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
