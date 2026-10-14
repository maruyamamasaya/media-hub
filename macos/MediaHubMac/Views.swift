import AppKit
import AssetLibraryContract
import AVKit
import SwiftUI

struct MacRootView: View {
    @ObservedObject var model: MacModel
    @ObservedObject var runtime: MacRuntime
    @State private var page = "S3フォルダ"
    var body: some View {
        NavigationSplitView {
            List(["S3フォルダ", "アップロード", "軽量版を作る", "設定"], id: \.self, selection: $page) { Text($0) }
                .navigationTitle("media-hub").frame(minWidth: 180)
        } detail: {
            if model.concealed { Text("アプリに戻るとフォルダを再確認します。") }
            else if !runtime.ready { VStack(spacing: 16) { if runtime.error.isEmpty { ProgressView("起動中…") } else { Text(runtime.error).foregroundStyle(.red) } }.padding() }
            else {
                VStack(spacing: 0) {
                    if !model.notice.isEmpty { Label(model.notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding() }
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).padding().textSelection(.enabled) }
                    Group {
                        switch page {
                        case "アップロード": UploadScreen()
                        case "軽量版を作る": NavigationStack { LightVideoScreen() }
                        case "設定": SettingsScreen()
                        default: LibraryScreen()
                        }
                    }.environmentObject(model).id(model.privacyID)
                }.navigationTitle(page)
            }
        }
        .frame(minWidth: 850, minHeight: 600)
        .tint(Color(red: 0.2, green: 0.4, blue: 0.31))
        .task { runtime.start(); await model.poll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.concealed = true; Task { await model.relock() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.concealed = false; Task { await model.relock() }
        }
    }
}
struct SettingsScreen: View {
    @EnvironmentObject var model: MacModel
    var body: some View {
        Form {
            Section("本人専用・非公開") {
                Text("Macから手動送信し、iPhoneで閲覧します。原本の正本はS3です。自動同期は行いません。")
                Text("Macの元ファイルと以前のローカル素材は保持します。")
            }
            Section("送信先") {
                TextField("S3バケット", text: $model.bucket)
                TextField("AWSプロファイル", text: $model.profile)
                TextField("リージョン", text: $model.region)
                Text("通常は変更不要です。AWS秘密鍵は入力しません。")
            }
            Section("作業領域") { Text(model.runtime.dataRoot.path).textSelection(.enabled) }
        }.formStyle(.grouped)
    }
}
struct UploadScreen: View {
    @EnvironmentObject var model: MacModel
    @State private var selectedID: String?
    @State private var draft: FolderUpload?
    @State private var confirmed = false
    private var plan: FolderUpload? { model.uploads.first { $0.id == selectedID } ?? draft }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("フォルダをそのまま、あなただけのクラウドへ。").font(.title2)
                Text("① 選ぶ　→　② 内容を確認　→　③ 手動送信").foregroundStyle(.secondary)
                Button("フォルダを選ぶ", systemImage: "folder.badge.plus") {
                    guard let url = model.choose(directory: true) else { return }
                    Task { await model.run {
                        let value = try await model.scan(url.path)
                        draft = value; selectedID = value.id; confirmed = false
                        try await model.refresh()
                    } }
                }.disabled(model.busy || model.uploads.contains { $0.state == "uploading" })
                if let plan {
                    UploadPlanView(plan: plan, confirmed: $confirmed)
                    DisclosureGroup("フォルダの中身を確認") {
                        ForEach(plan.folders, id: \.id) { folder in
                            DisclosureGroup(folder.name) {
                                ForEach(plan.items.filter { $0.folderId == folder.id }, id: \.id) { item in
                                    HStack { Text(item.relativePath); Spacer(); Text(size(item.byteSize)); if item.state == "verified" { Image(systemName: "checkmark.seal") } }
                                }
                                if !plan.items.contains(where: { $0.folderId == folder.id }) { Text("この階層にファイルはありません。") }
                            }
                        }
                    }
                }
                Divider()
                Text("これまでのアップロード").font(.headline)
                ForEach(model.uploads, id: \.id) { value in
                    Button { selectedID = value.id; draft = nil; confirmed = false } label: {
                        HStack { Image(systemName: "folder"); Text(value.name); Spacer(); Text("\(value.items.count)件 · \(size(value.byteSize)) · \(stateName(value.state))") }
                    }.disabled(model.busy || plan?.state == "uploading")
                }
                Text("原本は残ります。自動同期なし。1ファイル5GiB・1回20GiB・10,000件まで。隠しファイル・リンク・対象外形式は送信しません。").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}
struct UploadPlanView: View {
    @EnvironmentObject var model: MacModel
    let plan: FolderUpload
    @Binding var confirmed: Bool
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text(plan.name).font(.title2.bold())
                Text("\(plan.items.count)件 · \(size(plan.byteSize)) · \(plan.folders.count)フォルダ")
                Text("非公開S3 · \(plan.region) · \(plan.bucket)").textSelection(.enabled)
                Text(stateName(plan.state)).font(.headline)
                if plan.skipped > 0 { Text("対象外 \(plan.skipped)件は送信しません。") }
                if !plan.error.isEmpty { Text(plan.error).foregroundStyle(.red) }
                ProgressView(value: Double(plan.completed), total: Double(max(plan.items.count, 1)))
                Text("照合済み \(plan.completed) / \(plan.items.count)件")
                if plan.state == "uploading" {
                    Button("このファイルの完了後に停止") { Task { await model.run { try await model.upload(plan, pause: true) } } }
                } else if plan.state == "complete" {
                    Label("保存と照合が完了しました。Macの原本は残っています。", systemImage: "checkmark.seal")
                } else {
                    Toggle("このメディアとフォルダ名を、上の保存先へ送信する", isOn: $confirmed)
                    Button(plan.state == "planned" ? "アップロードを開始" : "アップロードを再開") {
                        confirmed = false
                        Task { await model.run { try await model.upload(plan) } }
                    }.buttonStyle(.borderedProminent).disabled(!confirmed)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }.disabled(model.busy)
    }
}
struct LibraryScreen: View {
    @EnvironmentObject var model: MacModel
    @State private var unlocking = false
    @State private var path: [String] = []
    @State private var previousPath: [String] = []
    private func folder(_ key: String) -> MediaFolder? {
        let parts = key.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return nil }
        return model.library.first { $0.id == parts[0] }?.folders.first { $0.id == parts[1] }
    }
    @ViewBuilder
    private func rootLink(_ plan: FolderUpload) -> some View {
        if let root = plan.folders.first(where: { $0.parentId == nil }) {
            let key: String = plan.id + ":" + root.id
            NavigationLink(value: key) { FolderTile(name: plan.name) }.buttonStyle(.plain)
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("鍵なしのフォルダはそのまま開けます。鍵付きは、PINを入力するまで名前も表示しません。")
                        .font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 210), spacing: 12)], spacing: 12) {
                        ForEach(model.library, id: \.id) { plan in
                            rootLink(plan)
                        }
                    }
                    if model.library.isEmpty {
                        Text(model.busy ? "フォルダを読み込み中…" : "表示できるフォルダはありません。鍵付きフォルダは「隠したフォルダを開く」から表示できます。")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }.padding(20)
            }
            .navigationDestination(for: String.self) { key in
                let parts = key.split(separator: ":").map(String.init)
                if parts.count == 2, let plan = model.library.first(where: { $0.id == parts[0] }) {
                    FolderScreen(plan: plan, folderID: parts[1])
                }
            }
            .toolbar {
                Button("隠したフォルダを開く", systemImage: "lock.open") { unlocking = true }
                if model.hasFolderUnlock { Button("閉じて隠す", systemImage: "lock") { Task { await model.relock() } } }
                Button("更新", systemImage: "arrow.clockwise") { Task { await model.run { try await model.refresh() } } }
            }
        }
        .onChange(of: path) { new in
            let old = previousPath
            previousPath = new
            guard new.count < old.count, model.hasFolderUnlock else { return }
            let removed = old.dropFirst(new.count)
            if new.isEmpty || removed.contains(where: { folder($0)?.isLocked == true }) {
                Task { await model.relock() }
            }
        }
        .sheet(isPresented: $unlocking) { FolderPasswordSheet() }
    }
}
struct FolderPasswordSheet: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) var dismiss
    var plan: String? = nil
    var folder: String? = nil
    var folderLocked = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var processing = false
    @State private var operationError = ""
    private func submit(_ entered: String?) {
        guard !processing, !model.busy else { return }
        processing = true; operationError = ""; model.error = ""; model.notice = ""
        model.busy = true
        Task {
            defer { processing = false; model.busy = false }
            do {
                if let plan, let folder {
                    try await model.lock(plan: plan, folder: folder, password: entered)
                    model.notice = entered == nil ? "鍵なしに変更しました。" : "鍵を設定し、フォルダを隠しました。"
                } else {
                    try await model.unlock(entered ?? "")
                    model.notice = "鍵を解除しました。フォルダを表示しています。"
                }
                dismiss()
            } catch is CancellationError { }
            catch {
                guard !model.concealed else { return }
                operationError = error.localizedDescription
                model.error = error.localizedDescription
            }
        }
    }
    private var pinHint: String? {
        guard plan != nil else { return nil }
        if password.isEmpty { return "半角数字6桁を入力し、確認欄にも同じPINを入力してください。" }
        if !password.utf8.allSatisfy({ (48...57).contains($0) }) { return "半角の数字だけを使ってください。全角数字・空白は使えません。" }
        if password.count != 6 { return "PINは6桁です（現在\(password.count)桁）。" }
        if confirmation.isEmpty { return "「もう一度」に同じ6桁のPINを入力してください。" }
        if password != confirmation { return "2つの入力が一致していません。" }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(plan == nil ? "隠したフォルダを開く" : "フォルダの鍵").font(.title2)
            if plan != nil { Text(folderLocked ? "現在：鍵あり（解除中）" : "現在：このフォルダ自身の鍵なし") }
            SecureField(plan == nil ? "PIN（以前のパスワードも使用可）" : "PIN（半角数字6桁）", text: $password)
            if plan != nil { SecureField("もう一度", text: $confirmation); Text("このフォルダと子の中身を隠します。設定は非公開S3へ保存し、iPhoneにも反映します。原本は変更しません。") }
            else { Text("同じパスワードのフォルダを解除します。最長5分、アプリを離れると再ロックします。") }
            if let pinHint { Text(pinHint).font(.callout).foregroundStyle(.secondary) }
            if processing {
                ProgressView(plan == nil ? "処理中：鍵を確認してフォルダを取得しています…" : "処理中：鍵設定を保存しています…")
                    .accessibilityLabel("処理中")
            } else if model.busy { ProgressView("処理中：一覧を更新しています…") }
            HStack {
                Button("閉じる") { password = ""; confirmation = ""; dismiss() }
                Spacer()
                if plan != nil, folder != nil {
                    Button("鍵なしにする") { submit(nil) }
                }
                Button(processing ? "処理中…" : (plan == nil ? "解除" : "設定して隠す")) {
                    let entered = password; password = ""; confirmation = ""
                    submit(entered)
                }.buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || (plan != nil && (password.count != 6 || !password.utf8.allSatisfy { (48...57).contains($0) } || password != confirmation)))
            }.disabled(model.busy || processing)
            if !operationError.isEmpty { Label(operationError, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
        }.padding(28).frame(width: 460)
            .interactiveDismissDisabled(processing)
    }
}
func isVideo(_ name: String) -> Bool { ["mp4", "mov", "m4v", "mkv", "webm"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) }
struct MediaScreen: View {
    @EnvironmentObject var model: MacModel
    let path: String
    let name: String
    var showSave = true
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var temporary: URL?
    @State private var error = ""
    var body: some View {
        VStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if let player { VideoPlayer(player: player) }
            else if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else { ProgressView("読み込み中…") }
            if showSave { Button("ファイルを保存") { Task { await model.run { try await model.export(path, name: name) } } }.disabled(model.busy) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding().navigationTitle(name)
        .task {
            let identity = model.privacyID
            do {
                let file = try await model.runtime.download(path)
                guard !Task.isCancelled, identity == model.privacyID else { try? FileManager.default.removeItem(at: file); return }
                temporary = file
                if isVideo(name) { player = AVPlayer(url: file) }
                else if let loaded = NSImage(contentsOf: file) { image = loaded }
                else { error = "この形式は表示できません。" }
            } catch { if identity == model.privacyID { self.error = error.localizedDescription } }
        }
        .onDisappear { player?.pause(); player = nil; image = nil; if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil }
    }
}
struct LightVideoScreen: View {
    @EnvironmentObject var model: MacModel
    @State private var selectedID: String?
    @State private var uploadID: String?
    @State private var confirmed = false
    var job: LightVideo? { model.videos.first { $0.id == selectedID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("見るための動画を、軽く。").font(.title2)
                Text("原本を保持し、Mac内で1本ずつ作成します。1080p・60fpsまで。HDRは未対応。")
                Button("動画を選ぶ") {
                    guard let url = model.choose(directory: false) else { return }
                    Task { await model.run {
                        let value: LightVideo = try await model.runtime.request("/light-videos/inspect", method: "POST", body: ["path": url.path])
                        selectedID = value.id; uploadID = nil; confirmed = false; try await model.refresh()
                    } }
                }.disabled(model.busy || model.videos.contains { $0.state == "creating" })
                if let job {
                    Text(job.name).font(.headline)
                    Text("原本 \(size(job.originalBytes)) → 軽量版 \(size(job.outputBytes > 0 ? job.outputBytes : job.estimatedBytes)) · \(stateName(job.state))")
                    if !job.warning.isEmpty { Text(job.warning) }
                    if !job.error.isEmpty { Text(job.error).foregroundStyle(.red) }
                    if job.state == "creating" {
                        ProgressView(value: Double(job.progress), total: 100)
                        Button("作成を停止") { videoAction(job, action: "cancel") }
                    } else if job.state == "complete" {
                        NavigationLink("作成した動画を見る") { MediaScreen(path: "/light-videos/\(job.id)/content", name: job.name + ".mp4") }
                        Button("軽量版を保存") { Task { await model.run { try await model.export("/light-videos/\(job.id)/content", name: job.name + ".mp4") } } }
                        Button("S3へアップロード · 内容を確認") {
                            Task { await model.run {
                                let plan: FolderUpload = try await model.runtime.request("/light-videos/\(job.id)/prepare-upload", method: "POST", body: [:])
                                uploadID = plan.id; confirmed = false; try await model.refresh()
                            } }
                        }
                        if let plan = model.uploads.first(where: { $0.id == uploadID }) { UploadPlanView(plan: plan, confirmed: $confirmed) }
                    } else {
                        Button("軽量版を作る（Mac内）") { videoAction(job, action: "start") }.disabled(model.videos.contains { $0.state == "creating" })
                    }
                }
                Divider(); Text("作成履歴").font(.headline)
                ForEach(model.videos, id: \.id) { job in
                    Button("\(job.name) · \(stateName(job.state))") { selectedID = job.id; uploadID = nil; confirmed = false }
                }
                Text("自動送信・自動削除は行いません。作成結果はアプリの作業領域に残ります。原本5GiB・2時間・60fpsまで。").font(.caption).foregroundStyle(.secondary)
            }.padding(28).disabled(model.busy)
        }
    }
    func videoAction(_ job: LightVideo, action: String) {
        Task { await model.run { try await model.runtime.action("/light-videos/\(job.id)/\(action)"); try await model.refresh() } }
    }
}
