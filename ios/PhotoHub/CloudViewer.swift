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
    private let authentication = Authentication()
    private let network = URLSession(configuration: .ephemeral)
    private let sealedRequests = SealedRequestGate()
    private var lockRevision: String?
    @Published var hiddenPagesOpen = false
    @Published private(set) var hasFolderUnlock = false
    private var folderToken: String?
    private var folderTimer: Timer?
    func relock() {
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
        try await sealedRequests.wait()
        return try await get("/catalogs/\(root.rootId)/\(root.id)", as: ReadCatalog.self)
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
        try await sealedRequests.wait()
        try Task.checkCancellation()
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
            if model.hiddenPagesOpen {
                NavigationStack { PhoneSealedLibrary() }
                    .tabItem { Label("暗号化", systemImage: "lock.shield") }
            }
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
        ScrollView {
            VStack(spacing: 20) {
                if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).padding() }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    ForEach(model.roots) { root in ReaderRootTile(root: root) }
                }.padding(16)
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
            Text(name).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
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
    @State private var selected: ReadItem?
    private var items: [ReadItem] { catalog.items.filter { $0.folderId == folderID } }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                let children = catalog.folders.filter { $0.parentId == folderID }
                if !children.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(children) { folder in
                            NavigationLink { ReaderFolderScreen(catalog: catalog, folderID: folder.id) } label: {
                                ReaderFolderTile(name: folder.name, catalog: catalog, folderID: folder.id)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 12)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(items) { item in
                        Button { selected = item } label: { ReaderThumbnail(catalog: catalog, item: item) }
                            .buttonStyle(.plain).accessibilityLabel(item.mimeType.hasPrefix("video/") ? "動画" : "写真")
                    }
                }
                if children.isEmpty && items.isEmpty { ContentUnavailableView("空のフォルダ", systemImage: "folder") }
            }.padding(.vertical, 8)
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selected) { item in ReaderMediaScreen(catalog: catalog, items: items, initialID: item.id) }
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
                else { Image(systemName: item.mimeType.hasPrefix("video/") ? "play.rectangle" : "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
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
    @State private var player: AVPlayer?
    @State private var error = ""
    private var item: ReadItem { items[index] }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit().contentShape(Rectangle()).onTapGesture { controls.toggle() } }
                else if let player { VideoPlayer(player: player) }
                else if !error.isEmpty { VStack { Text(error); Button("再試行") { Task { await load() } } }.foregroundStyle(.white).padding() }
                else { ProgressView().tint(.white) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let next = index + (value.translation.width < 0 ? 1 : -1)
                    if items.indices.contains(next) { clear(); index = next; controls = true }
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
    private func clear() { player?.pause(); player = nil; image = nil; error = "" }
    private func load() async {
        let current = item; let identity = model.sessionID
        clear()
        do {
            if current.mimeType.hasPrefix("video/") {
                let url = try await model.mediaURL(catalog, current)
                guard !Task.isCancelled, identity == model.sessionID, current.id == item.id else { return }
                player = AVPlayer(url: url)
            } else {
                let value = try await model.image(catalog, current)
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
            if model.signedIn { Section { FolderUnlockControl() } }
            Section { if model.signedIn { Button("ログアウト") { model.signOut() } } else { Button("本人ログイン") { Task { await model.login() } }.disabled(!model.configuration.valid || model.busy) } }
            if model.hiddenPagesOpen { Section("暗号化の鍵") { PhoneSealedKeyImport() } }
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
