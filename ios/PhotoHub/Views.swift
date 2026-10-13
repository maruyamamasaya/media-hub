import SwiftUI
import PhotosUI
import Photos
import AVKit
import PhotoHubCore

struct RootView: View {
    @EnvironmentObject var library: LibraryModel
    var body: some View {
        TabView {
            NavigationStack { PhotoGrid() }.tabItem { Label("写真", systemImage: "photo.on.rectangle") }
            NavigationStack { MyShortView() }.tabItem { Label("マイショート", systemImage: "play.rectangle") }
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
            if visible.isEmpty { ContentUnavailableView("写真がありません", systemImage: "photo", description: Text("右上の＋から写真を取り込めます。")) }
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
                                    if photo.state != .uploaded { Image(systemName: photo.state == .failed ? "exclamationmark.icloud" : "icloud.and.arrow.up") }
                                }
                                .font(.caption2).foregroundStyle(.white)
                                .padding(6).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                                .padding(6)
                                .opacity(photo.favorite || photo.state != .uploaded ? 1 : 0)
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
                PhotosPicker(selection: $selection, maxSelectionCount: 100, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current, photoLibrary: .shared()) { Image(systemName: "plus") }.disabled(library.busy)
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
                ForEach(photoIDs, id: \.self) { id in if let photo = library.photos.first(where: { $0.id == id }) { Group { if photo.mime.hasPrefix("video/") { ShortVideo(photo: photo, active: current == id) } else { DetailImage(photo: photo) } }.tag(id) } }
            }.tabViewStyle(.page(indexDisplayMode: .never))
            if let photo {
                VStack(spacing: 5) {
                    Text(photo.capturedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption)
                    Text("\(photo.filename) · \(ByteCountFormatter.string(fromByteCount: photo.bytes, countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                    if photo.state != .uploaded { Text(photo.error ?? "保存先へ未送信です").font(.caption).foregroundStyle(.orange) }
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
        .confirmationDialog("アプリから写真を削除しますか？原本・派生画像・整理情報を削除します。iPhoneの写真ライブラリは変更しません。", isPresented: $confirmDelete, titleVisibility: .visible) {
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

// Legacy Photo library integration. Web metadata synchronization is a separate step.
struct MyShortView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var order: [String] = []
    @State private var currentID = ""
    @State private var albumID = ""
    @State private var detail = false
    @State private var visible = false
    @State private var lastMove = Date.distantPast
    private var ids: [String] {
        order.filter { id in library.photos.contains { $0.id == id && $0.state != .deleting }
            && (albumID.isEmpty || library.members.contains { $0.photoID == id && $0.albumID == albumID }) }
    }
    private var photo: Photo? { library.photos.first { $0.id == currentID && $0.state != .deleting } }
    private var index: Int { ids.firstIndex(of: currentID) ?? 0 }
    private func reset() {
        order = library.photos.filter { $0.state != .deleting }.map(\.id).shuffled()
        currentID = ids.first ?? ""
    }
    private func move(_ direction: Int) {
        guard Date().timeIntervalSince(lastMove) > 0.35 else { return }
        let next = index + direction
        guard ids.indices.contains(next) else { return }
        lastMove = Date(); currentID = ids[next]
    }
    var body: some View {
        VStack(spacing: 12) {
            Picker("アルバム", selection: $albumID) {
                Text("すべての素材").tag("")
                ForEach(library.albums) { Text($0.name).tag($0.id) }
            }.pickerStyle(.menu)
            if let photo {
                GeometryReader { geometry in
                    Group {
                        if photo.mime.hasPrefix("video/") { ShortVideo(photo: photo, active: visible && !detail) }
                        else { DetailImage(photo: photo) }
                    }
                    .id(photo.id)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 60).onEnded { gesture in
                        if abs(gesture.translation.height) > abs(gesture.translation.width) { move(gesture.translation.height < 0 ? 1 : -1) }
                    })
                }
                Text(photo.filename).lineLimit(1)
                Text("\(index + 1) / \(ids.count)").font(.caption)
                HStack {
                    Button("前へ") { move(-1) }.disabled(index == 0)
                    Button("次へ") { move(1) }.disabled(index + 1 >= ids.count)
                    Button { library.setFavorite(photo) } label: { Image(systemName: photo.favorite ? "heart.fill" : "heart") }.accessibilityLabel(photo.favorite ? "お気に入り解除" : "お気に入り")
                    Menu {
                        ForEach(library.albums) { album in
                            Button { library.toggleMembership(photo: photo, album: album) } label: {
                                Label(album.name, systemImage: library.members.contains { $0.photoID == photo.id && $0.albumID == album.id } ? "checkmark" : "plus")
                            }
                        }
                    } label: { Image(systemName: "rectangle.stack.badge.plus") }.accessibilityLabel("アルバムに追加")
                    Button("詳細") { detail = true }
                }.disabled(library.busy)
            } else {
                ContentUnavailableView("対象の素材がありません", systemImage: "photo", description: Text("写真タブから画像・動画を追加するか、アルバムを変えてください。"))
            }
            Button("新しい順で見る") { reset() }
        }
        .padding().navigationTitle("マイショート")
        .onAppear { visible = true; if order.isEmpty { reset() } }
        .onDisappear { visible = false }
        .onChange(of: albumID) { _, _ in reset() }
        .onChange(of: ids) { _, updated in if !updated.contains(currentID) { currentID = updated.first ?? "" } }
        .sheet(isPresented: $detail) { NavigationStack {
            PhotoDetail(initialID: currentID, photoIDs: [currentID])
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { detail = false } } }
        } }
    }
}

@MainActor
final class ShortPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var failed = false
    @Published var loading = true
    private var observation: NSKeyValueObservation?
    func open(_ url: URL) {
        stop(); failed = false; loading = true
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item); player?.isMuted = true
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                self.loading = status == .unknown
                if status == .failed { self.failed = true; self.player?.pause() }
            }
        }
    }
    func stop() { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; observation = nil }
}

@MainActor
struct ShortVideo: View {
    @EnvironmentObject var library: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    let photo: Photo
    let active: Bool
    @StateObject private var playback = ShortPlayback()
    @State private var shown = false
    @State private var muted = true
    @State private var fetching = false
    @State private var attempts = 0
    private func sync() {
        if active && shown && scenePhase == .active {
            if playback.player == nil, let url = library.playbackURL(photo) { playback.open(url); muted = true }
            playback.player?.play()
        } else { playback.player?.pause() }
    }
    var body: some View {
        VStack {
            if let player = playback.player, !playback.failed {
                VideoPlayer(player: player).overlay { if playback.loading { ProgressView("読み込み中…") } }
                HStack {
                    Button("再生") { if active && scenePhase == .active { player.play() } }
                    Button("停止") { player.pause() }
                    Button(muted ? "音声オン" : "ミュート") { muted.toggle(); player.isMuted = muted }
                }
            } else if fetching { ProgressView("動画を読み込んでいます…") }
            else {
                ContentUnavailableView("動画を再生できません", systemImage: "video.slash", description: Text(photo.error ?? "閲覧用動画がありません。原本は詳細から明示的に保存できます。"))
                Button("再試行") { playback.stop(); attempts += 1 }
            }
        }
        .onAppear { shown = true; sync() }
        .task(id: "\(photo.id)-\(active)-\(attempts)") {
            guard active, playback.player == nil else { return }
            fetching = true
            let file = await library.loadPlayback(photo)
            guard !Task.isCancelled else { fetching = false; return }
            if let file, shown, scenePhase == .active { playback.open(file); muted = true; playback.player?.play() }
            fetching = false
        }
        .onDisappear { shown = false; playback.stop() }
        .onChange(of: active) { _, _ in sync() }
        .onChange(of: scenePhase) { _, _ in sync() }
    }
}
