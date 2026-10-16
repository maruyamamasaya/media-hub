import SwiftUI
import AssetLibraryContract
import PhotoHubCore

struct ReaderSortPicker: View {
    @Binding var order: LibraryOrder
    var body: some View {
        Menu { Picker("並び替え", selection: $order) { ForEach(LibraryOrder.allCases) { Text($0.title).tag($0) } } } label: {
            Image(systemName: "arrow.up.arrow.down").frame(minWidth: 36, minHeight: 36)
        }.accessibilityLabel("並び替え")
    }
}

struct PhoneFavoriteButton: View {
    @EnvironmentObject private var model: CloudViewerModel
    let reference: FavoriteReference
    var body: some View {
        Button { Task { await model.toggleFavorite(reference) } } label: {
            Image(systemName: model.isFavorite(reference) ? "heart.fill" : "heart")
                .foregroundStyle(model.isFavorite(reference) ? .pink : .primary)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26).background(.regularMaterial, in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.favoriteBusy)
        .accessibilityLabel(model.isFavorite(reference) ? "お気に入りから外す" : "お気に入りに追加")

    }
}

struct ReaderFavoritesScreen: View {
    @EnvironmentObject private var model: CloudViewerModel
    @State private var query = ""
    @State private var order: LibraryOrder = .name
    @State private var loading = false
    @State private var selected: Selection?
    private struct Selection: Identifiable {
        let catalog: ReadCatalog
        let item: ReadItem
        var id: String { item.id }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.signedIn { Text("本人ログインすると共有のお気に入りを表示します。").padding() }
                if loading { ProgressView("お気に入りを読み込み中…") }
                if !model.favoriteError.isEmpty { Text(model.favoriteError).foregroundStyle(.red) }
                ForEach(model.roots) { root in
                    if let catalog = model.catalogs[model.catalogKey(root.rootId, root.id)] {
                        let folders = order.arrange(catalog.folders.filter { model.isFavorite(model.favorite(catalog, target: $0.id, kind: "folder")) }, query: query, name: { $0.name }, size: { folder in catalog.items.filter { $0.folderId == folder.id }.reduce(0) { $0 + $1.byteSize } })
                        let items = order.arrange(catalog.items.filter { model.isFavorite(model.favorite(catalog, target: $0.id, kind: "item")) }, query: query, name: { $0.name }, size: { $0.byteSize })
                        if !folders.isEmpty || !items.isEmpty {
                            Text(catalog.name).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                                ForEach(folders) { folder in
                                    NavigationLink { ReaderFolderScreen(catalog: catalog, folderID: folder.id) } label: { ReaderFolderTile(name: folder.name, catalog: catalog, folderID: folder.id) }
                                        .buttonStyle(.plain)
                                }
                                ForEach(items) { item in
                                    Button { selected = Selection(catalog: catalog, item: item) } label: { ReaderThumbnail(catalog: catalog, item: item) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                if model.signedIn, !loading, model.favorites.filter({ $0.space == "normal" }).isEmpty { Text("♡からお気に入りを追加できます。MacとiPhoneで共有されます。").foregroundStyle(.secondary) }
            }.padding(16)
        }.navigationTitle("お気に入り")
        .searchable(text: $query, prompt: "お気に入りを検索")
        .toolbar { ToolbarItem { ReaderSortPicker(order: $order) } }
        .task { await load() }.refreshable { await load() }
        .fullScreenCover(item: $selected) { selection in ReaderMediaScreen(catalog: selection.catalog, items: [selection.item], initialID: selection.item.id) }
    }
    private func load() async {
        guard model.signedIn else { return }
        loading = true
        defer { loading = false }
        await model.refresh()
        let identity = model.sessionID
        // Only catalogs referenced by a visible favorite are needed here.
        for root in model.roots where model.favorites.contains(where: { $0.space == "normal" && $0.rootId == root.rootId }) {
            do { _ = try await model.catalog(root) }
            catch { if identity == model.sessionID { model.favoriteError = "一部のお気に入りを読み込めません。更新して再試行してください。" } }
            if identity != model.sessionID || Task.isCancelled { return }
        }
    }
}
