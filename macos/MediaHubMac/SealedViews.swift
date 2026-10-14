import AppKit
import SwiftUI
import AVKit
import CryptoKit
import PhotoHubCore
import AssetLibraryContract

struct SealedKeyManagement: View {
    @EnvironmentObject var model: MacModel
    @State private var operation: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("暗号化の鍵", systemImage: "key.fill").font(.title2.weight(.semibold))
            Text(model.encryptionReady ? "鍵はこのMacのKeychainで保管しています。iPhoneには復旧ファイルを読み込んでください。" : "最初に鍵を作成し、パスワード付きの復旧ファイルを保存してください。")
                .foregroundStyle(.secondary)
            HStack {
                if model.encryptionReady { Button("復旧ファイルを保存") { operation = "export" } }
                else { Button("鍵を作って復旧ファイルを保存") { operation = "create" }.buttonStyle(.borderedProminent) }
                Button("復旧ファイルを読み込む") { operation = "import" }
            }
            Text("復旧ファイルとパスワードの両方を失うと、鍵のない端末では復号できません。パスワードはファイルと別に保管してください。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: 800, alignment: .leading)
            .sheet(isPresented: Binding(get: { operation != nil }, set: { if !$0 { operation = nil } })) {
                SealedKeySheet(operation: operation ?? "import")
            }
    }
}
struct SealedKeySheet: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    let operation: String
    @State private var password = ""
    @State private var confirmation = ""
    @State private var processing = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(operation == "import" ? "復旧ファイルを読み込む" : "復旧ファイルを保存").font(.title2.weight(.semibold))
            Text(operation == "import" ? "Macで保存した復旧ファイルのパスワードを入力してください。" : "12文字以上の長いパスワードを設定してください。6桁のフォルダPINとは別です。")
                .foregroundStyle(.secondary)
            SecureField("復旧ファイルのパスワード", text: $password)
            if operation != "import" { SecureField("もう一度", text: $confirmation) }
            if processing { ProgressView("鍵を処理しています…") }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button("閉じる", role: .cancel) { password = ""; confirmation = ""; dismiss() }
                Spacer()
                Button(operation == "import" ? "ファイルを選んで読み込む" : "保存先を選ぶ") { perform() }
                    .buttonStyle(.borderedProminent)
                    .disabled(processing || password.isEmpty || (operation != "import" && (password.count < 12 || password != confirmation)))
            }.disabled(processing)
        }.padding(28).frame(width: 480).interactiveDismissDisabled(processing)
    }
    private func perform() {
        let entered = password
        let file: URL
        if operation == "import" {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let value = panel.url else { return }; file = value
        } else {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Media Hub 復旧ファイル.mediahubkey"
            guard panel.runModal() == .OK, let value = panel.url else { return }; file = value
        }
        password = ""; confirmation = ""; processing = true; error = ""
        Task {
            defer { processing = false }
            do {
                let mode = operation
                let secret = try await Task.detached {
                    if mode == "import" {
                        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 65536 else { throw SealedError.tooLarge }
                        return try RecoveryFile.restore(Data(contentsOf: file), password: entered)
                    }
                    let key = mode == "create" ? try MediaSecret() : try MediaSecretStore.load()
                    guard let key else { throw SealedError.wrongKey }
                    let bytes = try RecoveryFile.export(key, password: entered)
                    try bytes.write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    return key
                }.value
                try MediaSecretStore.save(secret)
                model.encryptionReady = true; model.notice = operation == "import" ? "暗号化の鍵を読み込みました。" : "復旧ファイルを保存しました。"
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
@MainActor
func macSealedReader(_ model: MacModel, root: SealedRoot, secret: MediaSecret, objectID: String?, length: Int64?, maximum: Int64) -> SealedRangeReader {
    let identity = model.privacyID
    let path = "/encrypted-library/\(root.keyID)/\(root.id)" + (objectID.map { "/items/\($0)" } ?? "") + "/url"
    let http = SealedHTTP { [weak model] in
        guard let model, await model.privacyID == identity, await !model.concealed, await model.hiddenPagesOpen else { throw CancellationError() }
        do {
            let response: ReadURL = try await model.runtime.request(path)
            guard let url = URL(string: response.url) else { throw SealedError.invalid }
            return url
        } catch {
            if await model.privacyID == identity { await model.handle(error) }
            throw error
        }
    }
    return SealedRangeReader(objectID: objectID ?? root.id, master: secret.masterKey, expectedLength: length, maximumLength: maximum) { range in try await http.bytes(range) }
}
struct SealedLibraryScreen: View {
    @EnvironmentObject var model: MacModel
    @State private var roots: [SealedRoot] = []
    @State private var secret: MediaSecret?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SealedKeyManagement()
                    if let secret {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 210), spacing: 12)], spacing: 12) {
                            ForEach(roots.filter { $0.keyID == secret.keyID }) { root in SealedRootTile(root: root, secret: secret) }
                        }.padding(.horizontal, 24)
                        if roots.isEmpty { Text("暗号化して保存したフォルダはまだありません。").foregroundStyle(.secondary).padding(24) }
                    }
                }.padding(20)
            }.toolbar { Button("更新", systemImage: "arrow.clockwise") { Task { await load() } } }
        }.task { await load() }
            .onChange(of: model.encryptionReady) { _ in Task { await load() } }
    }
    private func load() async {
        await model.run {
            secret = try MediaSecretStore.load()
            if secret != nil { roots = try await model.runtime.request("/encrypted-library") }
        }
    }
}
struct SealedRootTile: View {
    @EnvironmentObject var model: MacModel
    let root: SealedRoot
    let secret: MediaSecret
    @State private var catalog: SealedCatalog?
    @State private var failed = false
    var body: some View {
        Group {
            if let catalog {
                NavigationLink { SealedFolderScreen(root: root, catalog: catalog, secret: secret, folderID: catalog.folders.first { $0.parentId == nil }?.id) } label: { FolderTile(name: catalog.name) }.buttonStyle(.plain)
            } else { FolderTile(name: failed ? "復号できません" : "暗号化フォルダを読込中…") }
        }.task {
            let identity = model.privacyID
            let reader = macSealedReader(model, root: root, secret: secret, objectID: nil, length: nil, maximum: 4 * 1024 * 1024)
            do {
                let value = try JSONDecoder().decode(SealedCatalog.self, from: await reader.allData())
                try value.validate(root: root, secret: secret)
                if identity == model.privacyID, !Task.isCancelled { catalog = value }
            } catch { if identity == model.privacyID { failed = true; model.handle(error) } }
            await reader.close()
        }
    }
}
struct SealedFolderScreen: View {
    let root: SealedRoot
    let catalog: SealedCatalog
    let secret: MediaSecret
    let folderID: String?
    @State private var selected: SealedItem?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 210), spacing: 12)], spacing: 12) {
                ForEach(catalog.folders.filter { $0.parentId == folderID }) { folder in
                    NavigationLink { SealedFolderScreen(root: root, catalog: catalog, secret: secret, folderID: folder.id) } label: { FolderTile(name: folder.name) }.buttonStyle(.plain)
                }
                ForEach(catalog.items.filter { $0.folderId == folderID }) { item in
                    Button { selected = item } label: { SquareTile(title: item.name) { SealedThumbnail(root: root, item: item, secret: secret) } }.buttonStyle(.plain)
                }
            }.padding(20)
        }.navigationTitle(catalog.folders.first { $0.id == folderID }?.name ?? catalog.name)
            .sheet(item: $selected) { item in SealedMediaScreen(root: root, item: item, secret: secret) }
    }
}
struct SealedThumbnail: View {
    @EnvironmentObject var model: MacModel
    let root: SealedRoot; let item: SealedItem; let secret: MediaSecret
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: item.mimeType.hasPrefix("video/") ? "play.rectangle" : "photo").font(.system(size: 32)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task {
            guard let id = item.thumbnailID, let bytes = item.thumbnailBytes else { return }
            let identity = model.privacyID
            let reader = macSealedReader(model, root: root, secret: secret, objectID: id, length: bytes, maximum: 50000)
            do {
                let data = try await reader.allData()
                if identity == model.privacyID, !Task.isCancelled { image = NSImage(data: data) }
            } catch { if identity == model.privacyID, case MacAPIError.awsLoginRequired = error { model.handle(error) } }
            await reader.close()
        }.onDisappear { image = nil }
    }
}
struct SealedMediaScreen: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    let root: SealedRoot; let item: SealedItem; let secret: MediaSecret
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loader: SealedPlayerLoader?
    @State private var reader: SealedRangeReader?
    @State private var error = ""
    var body: some View {
        VStack {
            HStack { Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Text(item.name).lineLimit(1); Spacer() }.padding()
            Group {
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else if let player { VideoPlayer(player: player) }
                else if !error.isEmpty { Text(error).foregroundStyle(.red) }
                else { ProgressView("復号して読み込み中…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 700, minHeight: 500).task {
            let identity = model.privacyID
            let reader = macSealedReader(model, root: root, secret: secret, objectID: item.objectID, length: item.byteSize, maximum: item.mimeType.hasPrefix("video/") ? 5 * 1024 * 1024 * 1024 : 100 * 1024 * 1024)
            self.reader = reader
            do {
                if item.mimeType.hasPrefix("video/") {
                    let loader = SealedPlayerLoader(reader: reader, mime: item.mimeType)
                    if identity == model.privacyID, !Task.isCancelled { self.loader = loader; player = AVPlayer(playerItem: AVPlayerItem(asset: loader.asset)) }
                } else {
                    let data = try await reader.allData()
                    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == item.sha256, let image = NSImage(data: data) else { throw SealedError.invalid }
                    if identity == model.privacyID, !Task.isCancelled { self.image = image }
                }
            } catch { if identity == model.privacyID { self.error = error.localizedDescription; model.handle(error) } }
        }.onDisappear { player?.pause(); player = nil; loader?.close(); loader = nil; image = nil; if let reader { Task { await reader.close() } }; reader = nil }
    }
}
