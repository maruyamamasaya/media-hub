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
    let http = SealedHTTP { [weak model] in
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
        List {
            if !model.signedIn { Text("「見る」から本人ログインしてください。") }
            else {
                PhoneSealedKeyImport()
                if let secret {
                    ForEach(roots.filter { $0.keyID == secret.keyID }) { root in PhoneSealedRootRow(root: root, secret: secret) }
                    if roots.isEmpty { Text("暗号化して保存したフォルダはまだありません。") }
                } else { Text("最初にMacの復旧ファイルを読み込んでください。") }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }.navigationTitle("暗号化フォルダ").task { await load() }
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
                NavigationLink { PhoneSealedFolder(root: root, catalog: catalog, secret: secret, folderID: catalog.folders.first { $0.parentId == nil }?.id) } label: { Label(catalog.name, systemImage: "lock.shield") }
            } else if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else { ProgressView("暗号化フォルダを復号中…") }
        }.task {
            let identity = model.sessionID
            let reader = phoneSealedReader(model, root: root, secret: secret, objectID: nil, length: nil, maximum: 4 * 1024 * 1024)
            do {
                let bytes = try await reader.allData()
                let value = try JSONDecoder().decode(SealedCatalog.self, from: bytes); try value.validate(root: root, secret: secret)
                if identity == model.sessionID, !Task.isCancelled { catalog = value }
            } catch { if identity == model.sessionID { self.error = "復旧ファイル・ログイン・通信を確認してください。" } }
            await reader.close()
        }
    }
}
struct PhoneSealedFolder: View {
    let root: SealedRoot; let catalog: SealedCatalog; let secret: MediaSecret; let folderID: String?
    var body: some View {
        List {
            ForEach(catalog.folders.filter { $0.parentId == folderID }) { folder in
                NavigationLink { PhoneSealedFolder(root: root, catalog: catalog, secret: secret, folderID: folder.id) } label: { Label(folder.name, systemImage: "folder") }
            }
            ForEach(catalog.items.filter { $0.folderId == folderID }) { item in
                NavigationLink { PhoneSealedMedia(root: root, item: item, secret: secret) } label: {
                    HStack { PhoneSealedThumbnail(root: root, item: item, secret: secret); Text(item.name) }
                }
            }
        }.navigationTitle(catalog.folders.first { $0.id == folderID }?.name ?? catalog.name)
    }
}
struct PhoneSealedThumbnail: View {
    @EnvironmentObject private var model: CloudViewerModel
    let root: SealedRoot; let item: SealedItem; let secret: MediaSecret
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: item.mimeType.hasPrefix("video/") ? "play.rectangle" : "photo").foregroundStyle(.secondary) }
        }.frame(width: 52, height: 52).task {
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
    @State private var player: AVPlayer?
    @State private var loader: SealedPlayerLoader?
    @State private var reader: SealedRangeReader?
    @State private var error = ""
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if let player { VideoPlayer(player: player) }
            else if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else { ProgressView("復号して読み込み中…") }
        }.navigationTitle(item.name).navigationBarTitleDisplayMode(.inline).task {
            let identity = model.sessionID
            let reader = phoneSealedReader(model, root: root, secret: secret, objectID: item.objectID, length: item.byteSize, maximum: item.mimeType.hasPrefix("video/") ? 5 * 1024 * 1024 * 1024 : 100 * 1024 * 1024)
            self.reader = reader
            do {
                if item.mimeType.hasPrefix("video/") {
                    let loader = SealedPlayerLoader(reader: reader, mime: item.mimeType)
                    if identity == model.sessionID, !Task.isCancelled { self.loader = loader; player = AVPlayer(playerItem: AVPlayerItem(asset: loader.asset)) }
                } else {
                    let bytes = try await reader.allData()
                    guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == item.sha256, let value = UIImage(data: bytes) else { throw SealedError.invalid }
                    if identity == model.sessionID, !Task.isCancelled { image = value }
                }
            } catch { if identity == model.sessionID { self.error = "鍵・通信・画像サイズを確認してください。" } }
        }.onDisappear { player?.pause(); player = nil; loader?.close(); loader = nil; image = nil; if let reader { Task { await reader.close() } }; reader = nil }
    }
}

// Pace URL issuance to the existing 2 requests/second owner API without changing server limits.
actor SealedRequestGate {
    private var next = ContinuousClock.now
    func wait() async throws {
        let clock = ContinuousClock(), now = ContinuousClock.now
        let start = max(now, next)
        next = start.advanced(by: .milliseconds(600))
        try await clock.sleep(until: start)
    }
}
