import SwiftUI
import PhotoHubCore

struct MacThumbnailCacheSettings: View {
    @EnvironmentObject private var model: MacModel
    @State private var used: Int64 = 0
    @State private var limit: Int64 = 256 * 1024 * 1024
    @State private var clearing = false
    private struct Stats: Decodable { let bytes: Int64; let limit: Int64 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用中 \(size(used)) / 上限 \(size(limit))")
            Text("通常フォルダの小画像だけを保存します。PIN付きは毎回アクセス権を確認します。原本と暗号化内容は対象外です。")
                .font(.callout).foregroundStyle(.secondary)
            Button("サムネイルキャッシュを削除") { Task { await load(clear: true) } }.disabled(clearing)
        }.task { await load(clear: false) }
    }
    private func load(clear: Bool) async {
        clearing = true
        defer { clearing = false }
        do {
            let stats: Stats = try await model.runtime.request(clear ? "/folder-library/cache/clear" : "/folder-library/cache", method: clear ? "POST" : "GET")
            used = stats.bytes; limit = stats.limit
            if clear { model.notice = "サムネイルキャッシュを削除しました。" }
        } catch { model.handle(error) }
    }
}

struct LibrarySortPicker: View {
    @Binding var order: LibraryOrder
    var body: some View {
        Picker("並び替え", selection: $order) { ForEach(LibraryOrder.allCases) { Text($0.title).tag($0) } }.frame(width: 170)
    }
}
