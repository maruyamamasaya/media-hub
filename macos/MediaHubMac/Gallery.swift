import AppKit
import AssetLibraryContract
import SwiftUI

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
    var body: some View {
        SquareTile(title: name) {
            Image(systemName: "folder.fill").font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.65))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
struct GallerySelection: Identifiable { let id: String }

struct FolderScreen: View {
    @EnvironmentObject var model: MacModel
    let plan: FolderUpload
    let folderID: String?
    @State private var locking = false
    @State private var selection: GallerySelection?
    @State private var previewRevision = 0
    private var folders: [MediaFolder] { plan.folders.filter { $0.parentId == folderID } }
    private var files: [FolderUploadItem] { plan.items.filter { $0.folderId == folderID } }
    var body: some View {
        ScrollView {
            LazyVGrid(columns: mediaColumns, spacing: 12) {
                ForEach(folders, id: \.id) { folder in
                    NavigationLink(value: "\(plan.id):\(folder.id)") { FolderTile(name: folder.name) }
                        .buttonStyle(.plain)
                }
                ForEach(files, id: \.id) { item in
                    Button { selection = GallerySelection(id: item.id) } label: {
                        SquareTile(title: item.name) {
                            MediaThumbnail(plan: plan, item: item, revision: previewRevision)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(20)
            if folders.isEmpty && files.isEmpty { Text("このフォルダは空です。").foregroundStyle(.secondary).padding(40) }
            Text(plan.folders.first(where: { $0.id == folderID })?.isLocked == true ? "このフォルダ：鍵あり・解除中" : "このフォルダ自身：鍵なし（親に鍵がある場合は親の保護が適用されます）")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
        }.navigationTitle(plan.folders.first { $0.id == folderID }?.name ?? plan.name)
        .toolbar { if folderID != nil { Button("フォルダの鍵を確認・設定", systemImage: "lock") { locking = true } } }
        .sheet(isPresented: $locking) { FolderPasswordSheet(plan: plan.id, folder: folderID, folderLocked: plan.folders.first(where: { $0.id == folderID })?.isLocked == true) }
        .sheet(item: $selection, onDismiss: { previewRevision += 1 }) { selected in
            MediaGallery(plan: plan, items: files, initialID: selected.id)
        }
    }
}
struct MediaThumbnail: View {
    @EnvironmentObject var model: MacModel
    let plan: FolderUpload
    let item: FolderUploadItem
    let revision: Int
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Image(systemName: isVideo(item.name) ? "play.rectangle" : "photo")
                    .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(.secondary.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: revision) {
            let identity = model.privacyID
            guard !isVideo(item.name) else { return }
            if let data = try? await model.runtime.bytes("/folder-library/\(plan.id)/items/\(item.id)/content?thumbnail=true"),
               !Task.isCancelled, identity == model.privacyID { image = NSImage(data: data) }
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
