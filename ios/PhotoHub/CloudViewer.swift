import SwiftUI
import AVKit
import CryptoKit
import AssetLibraryContract

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
    private let authentication = Authentication()
    private let network = URLSession(configuration: .ephemeral)
    private var lockRevision: String?
    @Published private(set) var hasFolderUnlock = false
    private var folderToken: String?
    private var folderTimer: Timer?
    func relock() {
        folderTimer?.invalidate(); folderTimer = nil; folderToken = nil; hasFolderUnlock = false; roots = []; sessionID = UUID()
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
    init() {
        configuration = UserDefaults.standard.data(forKey: "readerConfiguration").flatMap { try? JSONDecoder().decode(CloudConfiguration.self, from: $0) } ?? CloudConfiguration()
        if let values = Bundle.main.infoDictionary?["MediaHubReader"] as? [String: String], !configuration.valid {
            configuration.api = values["api"] ?? ""
            configuration.domain = values["domain"] ?? ""
            configuration.clientID = values["clientID"] ?? ""
            configuration.owner = values["owner"] ?? ""
        }
    }
    func signOut() {
        relock(); lockRevision = nil
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
        if response.statusCode == 401 || response.statusCode == 403 { accessToken = nil; throw ViewerError.login }
        guard response.statusCode == 200, data.count <= 5 * 1024 * 1024 else { throw ViewerError.connection }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func refresh() async {
        error = ""
        do { roots = try await get("/library", as: [ReadRoot].self) }
        catch is CancellationError { }
        catch { self.error = "フォルダを取得できません。ログイン・接続設定・通信を確認してください。" }
    }
    func catalog(_ root: ReadRoot) async throws -> ReadCatalog {
        try await get("/catalogs/\(root.rootId)/\(root.id)", as: ReadCatalog.self)
    }
    func mediaURL(_ catalog: ReadCatalog, _ item: ReadItem, thumbnail: Bool = false) async throws -> URL {
        let value = try await get("/catalogs/\(catalog.rootId)/\(catalog.id)/items/\(item.id)/url?role=\(thumbnail ? "thumbnail" : "original")", as: ReadURL.self)
        guard let url = URL(string: value.url), url.scheme == "https", let host = url.host,
              host.hasSuffix(".amazonaws.com"), url.user == nil, url.password == nil else { throw ViewerError.configuration }
        return url
    }
    func image(_ catalog: ReadCatalog, _ item: ReadItem, thumbnail: Bool = false) async throws -> UIImage {
        guard thumbnail || item.byteSize <= 100 * 1024 * 1024 else { throw ViewerError.tooLarge }
        let identity = sessionID
        let url = try await mediaURL(catalog, item, thumbnail: thumbnail)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        let maximumBytes: Int = thumbnail ? 1_048_576 : 104_857_600
        let lastByte: Int = maximumBytes - 1
        request.setValue("bytes=0-\(lastByte)", forHTTPHeaderField: "Range")
        let (data, response) = try await network.data(for: request)
        guard identity == sessionID else { throw CancellationError() }
        guard let status = (response as? HTTPURLResponse)?.statusCode, [200, 206].contains(status), data.count <= maximumBytes else { throw ViewerError.connection }
        if !thumbnail {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard Int64(data.count) == item.byteSize, digest == item.sha256 else { throw ViewerError.integrity }
        }
        guard let image = UIImage(data: data) else { throw ViewerError.format }
        return image
    }
}

enum ViewerError: Error { case login, configuration, connection, tooLarge, integrity, format, unlock }

struct CloudViewerRoot: View {
    @StateObject private var model = CloudViewerModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            NavigationStack { libraryScreen }
                .tabItem { Label("見る", systemImage: "folder") }
            NavigationStack { ReaderSettings() }
                .tabItem { Label("設定", systemImage: "gearshape") }
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
            else if model.signedIn { folderList }
            else { signedOutScreen }
        }.navigationTitle("S3フォルダ")
    }
    private var signedOutScreen: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.icloud").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("あなただけのメディア").font(.title2.bold())
            Text(model.configuration.valid ? "本人ログインで、Macから保存したS3フォルダを閲覧できます。" : "S3閲覧用の接続を準備中です。設定で接続先を登録できます。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("本人ログイン") { Task { await model.login() } }
                .buttonStyle(.borderedProminent).disabled(!model.configuration.valid || model.busy)
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
        }.padding(28)
    }
    private var folderList: some View {
        List {
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.red) }
            ForEach(model.roots) { root in
                NavigationLink { ReaderCatalogScreen(root: root) } label: {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text(root.name)
                            Text("\(root.itemCount)件").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.roots.isEmpty && model.error.isEmpty { Text("表示できるフォルダはありません。") }
        }.refreshable { await model.refresh() }
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
        }.navigationTitle(root.name).task { do { catalog = try await model.catalog(root) } catch { self.error = "ログインと通信を確認して、フォルダを開き直してください。" } }
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
    private var protectedChild: Bool {
        catalog.folders.contains { $0.id == folderID && $0.parentId != nil && $0.isLocked }
    }
    var body: some View {
        List {
            Label(catalog.folders.first(where: { $0.id == folderID })?.isLocked == true ? "鍵あり・解除中" : "このフォルダ自身の鍵なし", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(catalog.folders.filter { $0.parentId == folderID }) { folder in
                NavigationLink { ReaderFolderScreen(catalog: catalog, folderID: folder.id).navigationTitle(folder.name) } label: { Label(folder.name, systemImage: "folder") }
            }
            ForEach(catalog.items.filter { $0.folderId == folderID }) { item in
                NavigationLink { ReaderMediaScreen(catalog: catalog, item: item) } label: { HStack { ReaderThumbnail(catalog: catalog, item: item); VStack(alignment: .leading) { Text(item.name); Text(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .binary)).font(.caption).foregroundStyle(.secondary) } } }
            }
        }
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
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Image(systemName: item.mimeType.hasPrefix("video/") ? "play.rectangle" : "photo").foregroundStyle(.secondary) } }
            .frame(width: 52, height: 52)
            .task { if item.hasThumbnail { image = try? await model.image(catalog, item, thumbnail: true) } }
    }
}

struct ReaderMediaScreen: View {
    @EnvironmentObject private var model: CloudViewerModel
    let catalog: ReadCatalog
    let item: ReadItem
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error = ""
    var body: some View {
        VStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if let player { VideoPlayer(player: player) }
            else if !error.isEmpty { ContentUnavailableView("表示できません", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("読み込み中…") }
            if item.mimeType.hasPrefix("video/") { Button("再生用の接続を更新") { Task { await load() } }.font(.caption); Text("再生・シークが止まった場合に更新してください。自動再生は行いません。").font(.caption2).foregroundStyle(.secondary) }
        }.padding().navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player?.pause(); player = nil; image = nil }
    }
    private func load() async {
        error = ""
        do {
            if item.mimeType.hasPrefix("video/") { let url = try await model.mediaURL(catalog, item); player?.pause(); player = AVPlayer(url: url) }
            else { image = try await model.image(catalog, item) }
        } catch { self.error = "通信・対応形式・画像100MiBの上限を確認してください。ログインが切れた場合は入り直してください。" }
    }
}

struct ReaderSettings: View {
    @EnvironmentObject private var model: CloudViewerModel
    @State private var value = CloudConfiguration()
    var body: some View {
        Form {
            if model.signedIn { Section { FolderUnlockControl() } }
            Section { if model.signedIn { Button("ログアウト") { model.signOut() } } else { Button("本人ログイン") { Task { await model.login() } }.disabled(!model.configuration.valid || model.busy) } }
            Section("接続設定") {
                TextField("閲覧API URL", text: $value.api).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Cognito domain", text: $value.domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Client ID", text: $value.clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("本人sub", text: $value.owner).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("接続先を保存") { model.saveConfiguration(value) }.disabled(!value.valid)
            }
        }.navigationTitle("設定").onAppear { value = model.configuration }
    }
}

struct FolderUnlockControl: View {
    @EnvironmentObject private var model: CloudViewerModel
    @State private var showing = false
    var body: some View {
        Button("隠したフォルダを開く") { showing = true }
            .sheet(isPresented: $showing) { FolderUnlockScreen() }
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
