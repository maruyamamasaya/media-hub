import SwiftUI
import AssetLibraryContract
import PhotoHubCore

struct MacFavoriteButton: View {
    @EnvironmentObject private var model: MacModel
    let reference: FavoriteReference
    var body: some View {
        Button { Task { await model.toggleFavorite(reference) } } label: {
            Image(systemName: model.isFavorite(reference) ? "heart.fill" : "heart")
                .foregroundStyle(model.isFavorite(reference) ? .pink : .primary)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22).background(.regularMaterial, in: Circle())
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.favoriteBusy)
        .help(model.isFavorite(reference) ? "お気に入りから外す" : "お気に入りに追加")
        .accessibilityLabel(model.isFavorite(reference) ? "お気に入りから外す" : "お気に入りに追加")
    }
}

struct MacFavoritesScreen: View {
    @EnvironmentObject private var model: MacModel
    @State private var query = ""
    @State private var order: LibraryOrder = .name
    @State private var selection: FavoriteMediaSelection?
    private struct FavoriteMediaSelection: Identifiable {
        let plan: FolderUpload
        let item: FolderUploadItem
        var id: String { item.id }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("MacとiPhoneで共有するお気に入りです。隠した素材は解除後だけ表示します。").foregroundStyle(.secondary)
                    if !model.favoriteError.isEmpty { Text(model.favoriteError).foregroundStyle(.red) }
                    ForEach(model.library, id: \.id) { plan in
                        let folders = order.arrange(plan.folders.filter { model.isFavorite(model.favorite(plan, target: $0.id, kind: "folder")) }, query: query, name: { $0.name }, size: { folder in plan.items.filter { $0.folderId == folder.id }.reduce(0) { $0 + $1.byteSize } })
                        let items = order.arrange(plan.items.filter { model.isFavorite(model.favorite(plan, target: $0.id, kind: "item")) }, query: query, name: { $0.name }, size: { $0.byteSize })
                        if !folders.isEmpty || !items.isEmpty {
                            Text(plan.name).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210))], spacing: 16) {
                                ForEach(folders, id: \.id) { folder in
                                    NavigationLink { FolderScreen(plan: plan, folderID: folder.id) } label: { FolderTile(name: folder.name, protection: "通常保存") }
                                        .buttonStyle(.plain)
                                        .overlay(alignment: .topTrailing) { MacFavoriteButton(reference: model.favorite(plan, target: folder.id, kind: "folder")) }
                                }
                                ForEach(items, id: \.id) { item in
                                    Button { selection = FavoriteMediaSelection(plan: plan, item: item) } label: { SquareTile(title: item.name) { MediaThumbnail(plan: plan, item: item) } }
                                        .buttonStyle(.plain)
                                        .overlay(alignment: .topTrailing) { MacFavoriteButton(reference: model.favorite(plan, target: item.id, kind: "item")) }
                                }
                            }
                        }
                    }
                    if model.favorites.filter({ $0.space == "normal" }).isEmpty { Text("通常フォルダのお気に入りはまだありません。♡から追加できます。").foregroundStyle(.secondary) }
                    if model.hiddenPagesOpen { NavigationLink("暗号化したお気に入り") { SealedLibraryScreen(favoritesOnly: true) } }
                }.padding(24)
            }.searchable(text: $query, prompt: "お気に入りを検索")
            .toolbar { LibrarySortPicker(order: $order); Button("更新", systemImage: "arrow.clockwise") { Task { await model.run { try await model.refresh() } } } }
            .sheet(item: $selection) { value in MediaGallery(plan: value.plan, items: [value.item], initialID: value.item.id) }
            .onChange(of: model.privacyID) { _ in selection = nil }
            .task { await model.refreshFavorites() }
        }
    }
}
