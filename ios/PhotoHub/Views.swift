import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import Photos
import PhotoHubCore

struct RootView: View {
    @EnvironmentObject var library: LibraryModel
    var body: some View {
        TabView {
            NavigationStack { PhotoGrid() }.tabItem { Label("写真", systemImage: "photo.on.rectangle") }
            NavigationStack { AlbumsView() }.tabItem { Label("アルバム", systemImage: "rectangle.stack") }
            NavigationStack { SettingsView() }.tabItem { Label("設定", systemImage: "gearshape") }
        }
        .alert("Photo Hub", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) { Button("OK") { library.message = nil } } message: { Text(library.message ?? "") }
    }
}
struct PhotoGrid: View {
    @EnvironmentObject var library: LibraryModel
    @State private var selection: [PhotosPickerItem] = []
    @ScaledMetric(relativeTo: .caption2) private var tileTitleSize = 10
    @ScaledMetric(relativeTo: .caption2) private var tileFormatSize = 7
    var album: Album?
    @State private var listSettings = false
    @State private var selectedExtensions: Set<String> = []
    @State private var favoritesOnly = false
    @State private var sortField = "added"
    @State private var ascending = false
    private func fileExtension(_ photo: Photo) -> String { (photo.filename as NSString).pathExtension.lowercased() }
    private var extensions: [String] { Array(Set(library.photos.map { fileExtension($0) }.filter { !$0.isEmpty })).sorted() }
    private var visible: [Photo] {
        library.photos.filter { photo in
            photo.state != .deleting && (!favoritesOnly || photo.favorite)
            && (selectedExtensions.isEmpty || selectedExtensions.contains(fileExtension(photo)))
            && (album == nil || library.members.contains { $0.albumID == album?.id && $0.photoID == photo.id })
        }.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortField {
            case "captured": comparison = lhs.capturedAt.compare(rhs.capturedAt)
            case "name": comparison = lhs.filename.compare(rhs.filename, options: .caseInsensitive)
            case "size": comparison = lhs.bytes == rhs.bytes ? .orderedSame : lhs.bytes < rhs.bytes ? .orderedAscending : .orderedDescending
            default: comparison = lhs.importedAt.compare(rhs.importedAt)
            }
            if comparison == .orderedSame { return ascending ? lhs.id < rhs.id : lhs.id > rhs.id }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
    var body: some View {
        ScrollView {
            if visible.isEmpty { ContentUnavailableView("写真がありません", systemImage: "photo", description: Text("右上の＋から写真を取り込むか、設定で画像フォルダを登録できます。")) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(visible) { photo in
                    NavigationLink { PhotoDetail(initialID: photo.id, photoIDs: visible.map(\.id)) } label: {
                        PhotoImage(photo: photo, kind: .thumbnail)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .bottomLeading) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Spacer(minLength: 0)
                                        Text(photo.mime.replacingOccurrences(of: "image/", with: "").uppercased())
                                            .font(.system(size: tileFormatSize, weight: .semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(Color(red: 0.36, green: 0.41, blue: 0.35))
                                            .padding(.horizontal, 4).padding(.vertical, 2)
                                            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 2))
                                    }.padding(.trailing, 6)
                                    Text(photo.filename)
                                        .font(.system(size: tileTitleSize, weight: .medium))
                                        .lineLimit(1)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.black.opacity(0.58))
                                }
                                .allowsHitTesting(false)
                            }
                            .overlay(alignment: .topTrailing) {
                                HStack(spacing: 4) {
                                    if photo.favorite { Image(systemName: "heart.fill") }
                                    if photo.folderSource != nil { Image(systemName: photo.error == nil ? "folder" : "exclamationmark.triangle") }
                                    else if photo.state != .uploaded { Image(systemName: photo.state == .failed ? "exclamationmark.icloud" : "icloud.and.arrow.up") }
                                }
                                .font(.caption2).foregroundStyle(.white)
                                .padding(6).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                                .opacity(photo.favorite || photo.folderSource != nil || photo.state != .uploaded ? 1 : 0)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(album?.name ?? "写真")
        .toolbar {
            Button { listSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(favoritesOnly || !selectedExtensions.isEmpty ? Color.accentColor : Color.primary)
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("フィルターと並び替え")
            if album == nil {
                PhotosPicker(selection: $selection, maxSelectionCount: 100, matching: .images, preferredItemEncoding: .current, photoLibrary: .shared()) { Image(systemName: "plus") }.disabled(library.busy)
            }
        }
        .sheet(isPresented: $listSettings) {
            NavigationStack {
                Form {
                    Section("フィルター") {
                        Toggle("お気に入りのみ", isOn: $favoritesOnly)
                        ForEach(extensions, id: \.self) { ext in
                            Toggle(".\(ext)", isOn: Binding(get: { selectedExtensions.contains(ext) }, set: { enabled in
                                if enabled { selectedExtensions.insert(ext) } else { selectedExtensions.remove(ext) }
                            }))
                        }
                        Button("条件を解除") { favoritesOnly = false; selectedExtensions.removeAll() }
                    }
                    Section("並び替え") {
                        Picker("項目", selection: $sortField) {
                            Text("追加日").tag("added")
                            Text("撮影日").tag("captured")
                            Text("タイトル").tag("name")
                            Text("原本サイズ").tag("size")
                        }
                        Picker("並び順", selection: $ascending) {
                            Text("降順").tag(false)
                            Text("昇順").tag(true)
                        }
                    }
                }
                .navigationTitle("フィルターと並び替え")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { listSettings = false } } }
            }
        }
        .onChange(of: selection) { _, items in
            let ids = items.compactMap(\.itemIdentifier)
            Task {
                if !items.isEmpty && ids.isEmpty { library.message = "選択した写真の識別子を取得できません。写真へのアクセスを確認してください。" }
                else { await library.importPhotos(ids: ids) }
                selection = []
            }
        }
        .overlay(alignment: .bottom) { if library.busy { ProgressView("処理中…").padding().background(.regularMaterial, in: Capsule()) } }
    }
}
struct PhotoImage: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    let kind: ImageKind
    @State private var image: UIImage?
    @State private var loading = true
    var body: some View {
        GeometryReader { geometry in
            if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
            else { ZStack { Color.secondary.opacity(0.12); if loading { ProgressView() } else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) } }.frame(width: geometry.size.width, height: geometry.size.height) }
        }
        .task(id: photo.id + kind.rawValue) {
            loading = true
            if let file = await library.image(photo, kind: kind) {
                let loaded = await Task.detached { UIImage(contentsOfFile: file.path) }.value
                if !Task.isCancelled { image = loaded }
            }
            loading = false
        }
        .accessibilityLabel(photo.filename)
    }
}
struct ZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ZoomScrollView(); scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator; scroll.photoView = context.coordinator.imageView; scroll.addSubview(context.coordinator.imageView)
        context.coordinator.imageView.contentMode = .scaleAspectFit
        scroll.bouncesZoom = true; return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.imageView.frame = scroll.bounds
        scroll.contentSize = scroll.bounds.size
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
final class ZoomScrollView: UIScrollView {
    weak var photoView: UIImageView?
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize { previousSize = bounds.size; zoomScale = 1; photoView?.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
    }
}
struct DetailImage: View {
    @EnvironmentObject var library: LibraryModel
    let photo: Photo
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { ZoomImage(image: image) }
            else if failed { ContentUnavailableView("画像を読み込めません", systemImage: "wifi.slash", description: Text("キャッシュがないか、通信・保存オブジェクトを確認してください。")) }
            else { ProgressView() }
        }.task(id: photo.id) {
            if let file = await library.image(photo, kind: .display) {
                image = await Task.detached { UIImage(contentsOfFile: file.path) }.value
            }
            failed = image == nil
        }
    }
}
struct PhotoDetail: View {
    @EnvironmentObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let initialID: String
    let photoIDs: [String]
    @State private var current = ""
    @State private var confirmDelete = false
    var photo: Photo? { library.photos.first { $0.id == current } }
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $current) {
                ForEach(photoIDs, id: \.self) { id in if let photo = library.photos.first(where: { $0.id == id }) { DetailImage(photo: photo).tag(id) } }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            if let photo {
                VStack(spacing: 5) {
                    Text(photo.capturedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption)
                    Text("\(photo.filename) · \(ByteCountFormatter.string(fromByteCount: photo.bytes, countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                    if photo.folderSource != nil { Text(photo.error ?? "登録フォルダの原本を参照しています").font(.caption).foregroundStyle(photo.error == nil ? Color.secondary : Color.orange) }
                    else if photo.state != .uploaded { Text(photo.error ?? "保存先へ未送信です").font(.caption).foregroundStyle(.orange) }
                    if let progress = library.progress[photo.id], photo.state == .uploading { ProgressView(value: progress) }
                    HStack {
                        Button { library.setFavorite(photo) } label: { Image(systemName: photo.favorite ? "heart.fill" : "heart") }
                        Spacer()
                        Menu { ForEach(library.albums) { album in Button { library.toggleMembership(photo: photo, album: album) } label: { Label(album.name, systemImage: library.members.contains { $0.photoID == photo.id && $0.albumID == album.id } ? "checkmark" : "plus") } } } label: { Image(systemName: "rectangle.stack.badge.plus") }
                        Spacer()
                        Button { Task { await library.saveOriginal(photo) } } label: { Image(systemName: "square.and.arrow.down") }
                        Spacer()
                        Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    }.font(.title3).padding().disabled(library.busy)
                }
            }
        }.navigationTitle("写真").navigationBarTitleDisplayMode(.inline)
        .onAppear { if current.isEmpty { current = initialID } }
        .confirmationDialog(photo?.folderSource != nil ? "アプリの登録と整理情報を削除しますか？選択フォルダの原本は残ります。次回の同期で再登録されます。" : "アプリから写真を削除しますか？原本・派生画像・整理情報を削除します。iPhoneの写真ライブラリは変更しません。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { if let photo { Task { await library.requestDelete(photo); dismiss() } } }
        }
    }
}
struct AlbumsView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var name = ""
    @State private var creating = false
    var body: some View {
        List { ForEach(library.albums) { album in NavigationLink(album.name) { PhotoGrid(album: album) } } }
        .navigationTitle("アルバム")
        .toolbar { Button { creating = true } label: { Image(systemName: "plus") }.disabled(library.busy) }
        .alert("新しいアルバム", isPresented: $creating) { TextField("名前", text: $name); Button("作成") { library.addAlbum(name: name); name = "" }; Button("キャンセル", role: .cancel) {} }
    }
}
struct SettingsView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var restoreConfirmation = false
    @State private var releaseConfirmation = false
    var body: some View {
        Form {
            Section {
                NavigationLink("フォルダ同期") { FolderSettingsView() }
                Text("iCloud DriveやこのiPhone内の画像フォルダを選んで読み込みます。").font(.caption)
            }
            Section("保存先") {
                Toggle("開発用ローカル保存", isOn: $library.localMode)
                Text(library.localMode ? "このiPhone内のテスト用保存です。機種変更・再インストールには使えません。" : "AWSへの保存には設定と本人ログインが必要です。").font(.caption)
                if !library.localMode {
                    TextField("HTTPS API URL", text: $library.configuration.api).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Cognito HTTPS domain", text: $library.configuration.domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Client ID", text: $library.configuration.clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("本人のCognito sub", text: $library.configuration.owner).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("本人ログイン") { Task { await library.run { try await library.authentication.login(library.configuration); library.message = "ログインしました。" } } }
                    Button("ログアウト") { library.authentication.signOut(library.configuration) }
                }
            }
            Section("保存と再試行") {
                Text("写真 \(library.photos.count)件 · 未完了 \(library.photos.filter { $0.state != .uploaded }.count)件")
                Button("未完了のアップロードを実行") { Task { await library.uploadPending() } }
                Button("未完了の削除を再試行") { Task { await library.retryDeletes() } }
                Button("確認済みの端末内原本コピーを解放") { releaseConfirmation = true }.disabled(library.localMode)
            }
            Section("キャッシュ") {
                Text("上限512MB。古いサムネイル・閲覧画像から削除します。未送信原本は対象外です。").font(.caption)
                Button("キャッシュを削除") { do { if let cache = library.cache { let previous = cache.limit; cache.limit = 0; try cache.trim(); cache.limit = previous }; library.message = "キャッシュを削除しました。" } catch { library.message = error.localizedDescription } }
            }
            Section("バックアップ") {
                Button("JSONバックアップを保存") { Task { await library.backup() } }
                ShareLink("最後に書き出したJSONを共有", item: library.support.appendingPathComponent("backup.json"))
                Button("空のライブラリに復元") { restoreConfirmation = true }
                Text("アップロード・削除が全て完了してから保存してください。復元はバックアップ時点に戻り、以降の変更は含まれません。").font(.caption)
            }
        }.navigationTitle("設定").disabled(library.busy)
        .confirmationDialog("最新の正常なバックアップから復元します。バックアップ後の変更は含まれません。", isPresented: $restoreConfirmation, titleVisibility: .visible) { Button("復元") { Task { await library.restore() } } }
        .confirmationDialog("S3保存を再確認してアプリ内の原本コピーを解放します。iPhoneの写真ライブラリは変更しません。", isPresented: $releaseConfirmation, titleVisibility: .visible) { Button("解放") { Task { await library.releaseOriginals() } } }
    }
}

struct FolderSettingsView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var selecting = false
    @State private var replacingID: String?
    var body: some View {
        Form {
            Section {
                Text("「ファイル」から画像フォルダを登録します。原本はフォルダに置いたまま、サブフォルダも含めて読み込みます。")
                Button("フォルダを追加") { replacingID = nil; selecting = true }
            }
            ForEach(library.folders) { folder in
                Section(folder.name) {
                    Button("同期する") { Task { await library.syncFolder(folder) } }
                    Button("フォルダを選び直す") { replacingID = folder.id; selecting = true }
                    if let result = library.folderResults[folder.id] { Text(result).font(.caption).accessibilityLabel(result) }
                }
            }
            Section {
                Text("同じ内容の改名・移動では、お気に入りとアルバムを引き継ぎます。欠損や内容変更は通知し、登録済みの画像情報を残します。新規登録は1回100件までです。")
                Text("iCloud上の未取得画像はダウンロードを要求します。取得待ちと表示された場合は、時間を置いてもう一度同期してください。")
                Text("フォルダの画像は端末ごとに登録します。お気に入り・アルバムなどの整理情報の端末間同期は準備中です。")
            }.font(.caption)
        }
        .navigationTitle("フォルダ同期")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(library.busy)
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let id = replacingID
                    Task { await library.registerFolder(url, replacing: id) }
                }
            case .failure(let error): library.message = error.localizedDescription
            }
        }
    }
}
