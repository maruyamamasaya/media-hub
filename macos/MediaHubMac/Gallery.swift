import AppKit
import AssetLibraryContract
import SwiftUI
import PhotoHubCore

private let mediaColumns = [GridItem(.adaptive(minimum: 130, maximum: 210), spacing: 12)]

/// One square visual surface for folders and media; the only caption is a small filename.
struct SquareTile<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(nsColor: .controlBackgroundColor)
            GeometryReader { geometry in
                content.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.55))
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(hovering ? Color.accentColor.opacity(0.7) : .primary.opacity(0.08), lineWidth: hovering ? 2 : 1) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .help(title)
    }
}
struct FolderTile: View {
    let name: String
    var protection: String = ""
    var detail: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        SquareTile(title: name) {
            Image(systemName: "folder.fill").font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if !protection.isEmpty { Text(protection).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
        if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}
struct GallerySelection: Identifiable { let id: String }

struct FolderScreen: View {
    @EnvironmentObject var model: MacModel
    let plan: FolderUpload
    let folderID: String?
    @State private var query = ""
    @State private var order: LibraryOrder = .name
    @State private var selecting = false
    @State private var selectedItems: Set<String> = []
    @State private var trashFolder: String?
    @State private var confirmingTrash = false
    @State private var locking = false
    @State private var selection: GallerySelection?
    private var folders: [MediaFolder] { order.arrange(plan.folders.filter { $0.parentId == folderID }, query: query, name: { $0.name }, size: { folder in plan.items.filter { $0.folderId == folder.id }.reduce(0) { $0 + $1.byteSize } }) }
    private var files: [FolderUploadItem] { order.arrange(plan.items.filter { $0.folderId == folderID }, query: query, name: { $0.name }, size: { $0.byteSize }) }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: mediaColumns, spacing: 12) {
                ForEach(folders, id: \.id) { folder in
                    NavigationLink(value: "\(plan.id):\(folder.id)") { FolderTile(name: folder.name, protection: folder.isLocked ? "通常保存 · PIN解除中" : "通常保存 · 内容暗号化なし") }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) { MacFavoriteButton(reference: model.favorite(plan, target: folder.id, kind: "folder")).padding(6) }
                        .contextMenu { Button("フォルダをごみ箱へ", role: .destructive) { trashFolder = folder.id; confirmingTrash = true } }
                }
                ForEach(files, id: \.id) { item in
                    Button {
                        if selecting {
                            if selectedItems.contains(item.id) { selectedItems.remove(item.id) } else { selectedItems.insert(item.id) }
                        } else { selection = GallerySelection(id: item.id) }
                    } label: {
                        SquareTile(title: item.name) {
                            MediaThumbnail(plan: plan, item: item)
                        }
                    }.buttonStyle(.plain)
                    .overlay(alignment: .topTrailing) {
                        if selecting { Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).padding(8).foregroundStyle(Color.accentColor).allowsHitTesting(false) }
                    }
                    .overlay(alignment: .topLeading) { if !selecting { MacFavoriteButton(reference: model.favorite(plan, target: item.id, kind: "item")).padding(6) } }
                    .contextMenu { Button("ごみ箱へ", role: .destructive) { selectedItems = [item.id]; trashFolder = nil; confirmingTrash = true } }
                }
            }.padding(20)
            if folders.isEmpty && files.isEmpty { Text("このフォルダは空です。").foregroundStyle(.secondary).padding(40) }
            Text(plan.folders.first(where: { $0.id == folderID })?.isLocked == true ? "このフォルダ：鍵あり・解除中" : "このフォルダ自身：鍵なし（親に鍵がある場合は親の保護が適用されます）")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
        }.navigationTitle(plan.folders.first { $0.id == folderID }?.name ?? plan.name)
        .searchable(text: $query, prompt: "このフォルダ内を検索")
        .toolbar {
            LibrarySortPicker(order: $order)
            Button(selecting ? "選択を終了" : "選択") { selecting.toggle(); selectedItems = [] }
            if selecting {
                Button("選択した\(selectedItems.count)件をごみ箱へ", systemImage: "trash") { trashFolder = nil; confirmingTrash = true }.disabled(selectedItems.isEmpty || model.busy)
            }
            Button("このフォルダをごみ箱へ", systemImage: "trash") { trashFolder = folderID; confirmingTrash = true }.disabled(folderID == nil || model.busy)
            if folderID != nil { Button("フォルダの鍵を確認・設定", systemImage: "lock") { locking = true } }
        }
        .confirmationDialog("S3の対象をごみ箱へ移しますか？", isPresented: $confirmingTrash, titleVisibility: .visible) {
            Button("ごみ箱へ移す", role: .destructive) {
                let ids = Array(selectedItems), folder = trashFolder
                Task { await model.run { try await model.moveToTrash(plan: plan.id, items: folder == nil ? ids : [], folder: folder); selectedItems = []; selecting = false } }
            }
        } message: { Text("Macの元ファイルは保持します。ごみ箱から復元できます。") }
        .onChange(of: model.privacyID) { _ in query = ""; selection = nil; locking = false; confirmingTrash = false; selectedItems = [] }
        .sheet(isPresented: $locking) { FolderPasswordSheet(plan: plan.id, folder: folderID, folderLocked: plan.folders.first(where: { $0.id == folderID })?.isLocked == true) }
        .sheet(item: $selection) { selected in
            MediaGallery(plan: plan, items: files, initialID: selected.id)
        }
    }
}
struct MediaThumbnail: View {
    @EnvironmentObject var model: MacModel
    let plan: FolderUpload
    let item: FolderUploadItem
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: URL(fileURLWithPath: item.name).pathExtension.lowercased() == "pdf" ? "doc.richtext" : (isVideo(item.name) ? "play.rectangle" : "photo"))
                    .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let identity = model.privacyID
            do {
                let data = try await model.runtime.bytes("/folder-library/\(plan.id)/items/\(item.id)/content?thumbnail=true")
                if !Task.isCancelled, identity == model.privacyID { image = NSImage(data: data) }
            } catch {
                if identity == model.privacyID, case MacAPIError.awsLoginRequired = error { model.handle(error) }
            }
        }.onDisappear { image = nil }
    }
}
struct MediaGallery: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    let plan: FolderUpload
    let items: [FolderUploadItem]
    @State private var selectedID: String
    init(plan: FolderUpload, items: [FolderUploadItem], initialID: String) {
        self.plan = plan; self.items = items; _selectedID = State(initialValue: initialID)
    }
    private var index: Int? { items.firstIndex { $0.id == selectedID } }
    private var current: FolderUploadItem? { index.map { items[$0] } }
    private var hasPrevious: Bool { (index ?? 0) > 0 }
    private var hasNext: Bool { index.map { $0 + 1 < items.count } ?? false }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction).help("閉じる（Esc）").accessibilityLabel("一覧に戻る")
                Text(current?.name ?? "ファイル").font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let index { Text("\(index + 1) / \(items.count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                if let current {
                    MacFavoriteButton(reference: model.favorite(plan, target: current.id, kind: "item"))
                    Button { Task { await model.run { try await model.export(path(current), name: current.name) } } } label: { Image(systemName: "square.and.arrow.down") }
                        .help("ファイルを保存").accessibilityLabel("ファイルを保存").disabled(model.busy)
                }
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ZStack {
                Color.black.opacity(0.94)
                if let current {
                    MediaScreen(path: path(current), name: current.name, showSave: false)
                        .id(current.id).padding(.horizontal, 56)
                }
                HStack {
                    Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                        .keyboardShortcut(.leftArrow, modifiers: []).disabled(!hasPrevious)
                        .help("前のファイル（←）").accessibilityLabel("前のファイル")
                    Spacer()
                    Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 44) }
                        .keyboardShortcut(.rightArrow, modifiers: []).disabled(!hasNext)
                        .help("次のファイル（→）").accessibilityLabel("次のファイル")
                }.buttonStyle(.bordered).padding(.horizontal, 12).tint(.white)
            }
        }.frame(minWidth: 700, idealWidth: 980, minHeight: 500, idealHeight: 700)
    }
    private func path(_ item: FolderUploadItem) -> String { "/folder-library/\(plan.id)/items/\(item.id)/content" }
    private func move(_ step: Int) {
        guard let index, items.indices.contains(index + step) else { return }
        selectedID = items[index + step].id
    }
}
