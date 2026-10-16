import AppKit
import AssetLibraryContract
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import PhotoHubCore

struct MacRootView: View {
    @ObservedObject var model: MacModel
    @ObservedObject var runtime: MacRuntime
    @State private var page = "S3フォルダ"
    var body: some View {
        NavigationSplitView {
            List(["S3フォルダ", "アップロード"] + (model.hiddenPagesOpen ? ["暗号化フォルダ", "暗号化アップロード"] : []) + ["軽量版を作る", "容量と費用", "設定"], id: \.self, selection: $page) { Text($0) }
                .navigationTitle("media-hub").frame(minWidth: 180)
        } detail: {
            if model.concealed { Text("アプリに戻るとフォルダを再確認します。") }
            else if !runtime.ready { VStack(spacing: 16) { if runtime.error.isEmpty { ProgressView("起動中…") } else { Text(runtime.error).foregroundStyle(.red) } }.padding() }
            else {
                VStack(spacing: 0) {
                    if !model.notice.isEmpty { Label(model.notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding() }
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).padding().textSelection(.enabled) }
                    if model.awsLoginRequired {
                        HStack {
                            Button("AWSにログイン") { model.openAWSLogin() }
                            Button("接続を確認") { Task { await model.checkAWSLogin() } }.disabled(model.busy)
                        }.padding()
                    }
                    if model.refreshing {
                        HStack { ProgressView().controlSize(.small); Text(model.refreshPhase).font(.caption); Spacer() }.padding(.horizontal).padding(.vertical, 8)
                    }
                    Group {
                        switch page {
                        case "アップロード": UploadScreen()
                        case "暗号化フォルダ": if model.hiddenPagesOpen { SealedLibraryScreen() }
                        case "暗号化アップロード": if model.hiddenPagesOpen { UploadScreen(encrypted: true) }
                        case "軽量版を作る": NavigationStack { LightVideoScreen() }
                        case "設定": SettingsScreen()
                        case "容量と費用": MacUsageScreen()
                        default: LibraryScreen()
                        }
                    }.environmentObject(model).id(model.privacyID)
                }.navigationTitle(page)
            }
        }
        .frame(minWidth: 850, minHeight: 600)
        .tint(Color(red: 0.2, green: 0.4, blue: 0.31))
        .task { runtime.start(); await model.poll() }
        .alert("AWSへの再ログインが必要です", isPresented: $model.showAWSLogin) {
            Button("ログインする") { model.openAWSLogin() }
            Button("あとで", role: .cancel) { }
        } message: {
            Text("ターミナルとブラウザでAWSにログインしてください。完了したら、この画面の「接続を確認」を押してください。")
        }
        .onChange(of: model.hiddenPagesOpen) { open in
            if !open && page.hasPrefix("暗号化") { page = "S3フォルダ" }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            Task { await model.applicationDeactivated() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.applicationActivated() }
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
            Section("AWSログイン") {
                Button("AWSにログイン") { model.openAWSLogin() }
                Text(model.loginCommand).textSelection(.enabled)
                Button("接続を確認") { Task { await model.checkAWSLogin() } }.disabled(model.busy)
            }
        }.formStyle(.grouped)
    }
}
struct UploadScreen: View {
    @EnvironmentObject var model: MacModel
    var encrypted = false
    private var uploads: [FolderUpload] { encrypted ? model.encryptedUploads : model.uploads }
    @State private var selectedID: String?
    @State private var draft: FolderUpload?
    private var pending: [FolderUpload] { uploads.filter { $0.state != "complete" } }
    private var finished: [FolderUpload] { uploads.filter { $0.state == "complete" }.sorted { ($0.completedAt ?? 0) > ($1.completedAt ?? 0) } }
    private var plan: FolderUpload? { uploads.first { $0.id == model.uploadBatch?.activeID } ?? uploads.first { $0.id == selectedID } ?? draft ?? pending.first }
    private var choosingDisabled: Bool { model.busy || sending || model.awsLoginRequired }
    private var sending: Bool { uploads.contains { ["uploading", "queued"].contains($0.state) } }
    private func chooseFolder() { addFolders(model.chooseFolders()) }
    private func addFolders(_ urls: [URL]) {
        guard !choosingDisabled, !urls.isEmpty, !encrypted || model.encryptionReady else { return }
        Task { await model.run {
            // Ignore duplicates and nested selections; selecting a parent already includes its children.
            let unique = Array(Set(urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
            let roots = unique.filter { url in !unique.contains { $0 != url && url.path.hasPrefix($0.path + "/") } }
            guard roots.count <= 50 else { throw MacAPIError.message("1回に50フォルダまで選択してください。") }
            try await model.prepareUploads(roots.map(\.path), encrypted: encrypted) { value in
                draft = value; selectedID = value.id
            }
        } }
    }
    private func discard(_ value: FolderUpload) {
        Task { await model.run {
            try await model.runtime.action("/\(encrypted ? "encrypted-uploads" : "folder-uploads")/\(value.id)/discard")
            // Clear locally before cloud refresh, so a connection error cannot revive this plan.
            if encrypted { model.encryptedUploads.removeAll { $0.id == value.id } } else { model.uploads.removeAll { $0.id == value.id } }
            if plan?.id == value.id || selectedID == value.id {
                draft = nil; selectedID = nil
            }
            model.notice = "アップロード予定を取り消しました。"
        } }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(encrypted ? "鍵をかけて追加" : "写真・動画・PDFを追加").font(.system(size: 26, weight: .semibold))
                        Text("フォルダを選ぶか、ここへドラッグ。準備できたフォルダから順に送ります。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if plan != nil {
                        Button("フォルダを追加", systemImage: "plus") { chooseFolder() }
                            .controlSize(.large).disabled(choosingDisabled || (encrypted && !model.encryptionReady))
                    }
                }
                if encrypted {
                    Text("写真・動画・PDFの中身と名前を暗号化して保存します。開くには、このMacやiPhoneに同じ鍵が必要です。")
                        .font(.callout).foregroundStyle(.secondary)
                    SealedKeyManagement()
                }
                if model.uploadBatch != nil {
                    HStack {
                        Text(model.uploadBatchStopping ? "停止しています。準備中の読み取りと処理中の送信が終わるまでお待ちください。" : "送信しながら次のフォルダを準備します。")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("追加と送信を停止") { Task { await model.stopUploadPreparation() } }
                            .disabled(model.uploadBatchStopping)
                    }
                }
                if model.scanning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("フォルダを読み取り、内容を照合しています…").font(.headline)
                        if model.scanTotalBytes > 0 {
                            ProgressView(value: Double(model.scanBytes), total: Double(model.scanTotalBytes))
                            Text("\(size(model.scanBytes)) / \(size(model.scanTotalBytes))").font(.caption)
                        } else { ProgressView() }
                        if let seconds = model.scanRemainingSeconds {
                            Text("残り約\(max(1, (seconds + 59) / 60))分（目安）").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Macの原本は変更しません。準備できたフォルダから送信します。")
                        Text("\(model.scanName) · 読み取り済み \(size(model.scanBytes))").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let plan {
                    UploadPlanView(plan: plan, encrypted: encrypted)
                    if plan.state == "planned" {
                        Button("このアップロード予定を取り消す", role: .destructive) { discard(plan) }
                            .buttonStyle(.borderless).disabled(model.busy)
                    }
                    DisclosureGroup("ファイルを確認") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(plan.folders, id: \.id) { folder in
                                DisclosureGroup(folder.name) {
                                    ForEach(plan.items.filter { $0.folderId == folder.id }, id: \.id) { item in
                                        HStack {
                                            Image(systemName: isVideo(item.name) ? "film" : "photo").foregroundStyle(.secondary)
                                            Text(item.relativePath).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Text(size(item.byteSize)).foregroundStyle(.secondary)
                                            if item.state == "verified" { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                        }.padding(.vertical, 3)
                                    }
                                    if !plan.items.contains(where: { $0.folderId == folder.id }) { Text("空のフォルダ").foregroundStyle(.secondary) }
                                }
                            }
                        }.padding(.top, 12)
                    }.font(.callout)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 44, weight: .light)).foregroundStyle(Color.accentColor)
                        Text("追加するフォルダを選んでください").font(.headline)
                        Text(encrypted ? "原本・小画像・ファイル名を暗号化して保存します。" : "写真・動画・PDFとフォルダ構成をそのまま保存します。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("フォルダを選んで追加", systemImage: "folder.badge.plus") { chooseFolder() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(choosingDisabled || (encrypted && !model.encryptionReady))
                    }.frame(maxWidth: .infinity).padding(.vertical, 44)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                }
                if !pending.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("進行中・再開が必要な追加").font(.headline)
                        VStack(spacing: 0) {
                            ForEach(pending, id: \.id) { value in
                                HStack(spacing: 12) {
                                    Button {
                                        selectedID = value.id; draft = nil
                                    } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: "folder.fill").font(.title3).foregroundStyle(Color.accentColor)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(value.name).fontWeight(.medium).foregroundStyle(.primary).lineLimit(1)
                                                Text("\(value.items.count)件 · \(size(value.byteSize))").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            UploadStatus(state: value.state)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if value.state == "planned" {
                                        Button { discard(value) } label: { Image(systemName: "trash") }
                                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                                            .help("アップロード予定を取り消す").accessibilityLabel("\(value.name)のアップロード予定を取り消す")
                                    }
                                }.padding(16).disabled(model.busy)
                                if value.id != pending.last?.id { Divider().padding(.leading, 16) }
                            }
                        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if let latest = finished.first {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("最近の保存結果", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                        UploadReceipt(plan: latest, encrypted: encrypted)
                        DisclosureGroup("過去の保存結果（\(finished.count)件）") {
                            ForEach(finished, id: \.id) { value in
                                UploadReceipt(plan: value, encrypted: encrypted).padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }.padding(24).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                }
                DisclosureGroup("アップロードについて") {
                    Text("Macの原本は残ります。自動同期は行いません。1ファイル5GiB・1回20GiB・10,000件まで。隠しファイル・リンク・対象外形式は送信しません。確認待ちの予定は取り消せます。")
                        .padding(.top, 8)
                }.font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 800, alignment: .leading).padding(32).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor)).controlSize(.large)
            .onChange(of: finished.map(\.id)) { ids in
                if let selectedID, ids.contains(selectedID) { self.selectedID = nil; draft = nil }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !choosingDisabled, !encrypted || model.encryptionReady else { return false }
                let directories = urls.filter { $0.isFileURL && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                guard !directories.isEmpty else { return false }
                addFolders(directories)
                return true
            }
    }
}
struct UploadReceipt: View {
    let plan: FolderUpload
    var encrypted = false
    private var timestamp: String {
        guard let value = plan.completedAt else { return "完了日時：旧履歴のため記録なし" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: value)) + " 保存完了（日本時間）"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.name).font(.headline)
            Text(timestamp).foregroundStyle(.secondary)
            Text("登録 \(plan.completed)件 · \(size(plan.byteSize))").font(.title3).monospacedDigit()
            Text(encrypted ? "内容・ファイル名：暗号化済み" : "通常保存（内容の暗号化なし）").font(.callout)
            if let count = plan.duplicateCount, count > 0 { Text("重複のため追加なし \(count)件").foregroundStyle(.secondary) }
            if plan.skipped > 0 { Text("対象外 \(plan.skipped)件").foregroundStyle(.secondary) }
        }
    }
}
struct UploadStatus: View {
    let state: String
    private var color: Color { state == "complete" ? .green : state == "failed" ? .red : .secondary }
    var body: some View {
        Text(stateName(state)).font(.caption.weight(.medium))
            .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }
}
struct UploadPlanView: View {
    @EnvironmentObject var model: MacModel
    let plan: FolderUpload
    var encrypted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: "folder.fill").font(.system(size: 32)).foregroundStyle(Color.accentColor)
                    .frame(width: 60, height: 60).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.name).font(.title2.weight(.semibold)).lineLimit(2)
                    Text("\(plan.items.count)件 · \(size(plan.byteSize)) · \(plan.folders.count)フォルダ").foregroundStyle(.secondary)
                }
                Spacer()
                UploadStatus(state: plan.state)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label(encrypted ? "保存先 · 暗号化して非公開S3へ" : "保存先 · 非公開S3", systemImage: "lock.shield").font(.callout.weight(.medium))
                DisclosureGroup("保存先の詳細") {
                    Text(plan.bucket).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("\(plan.region) · \(plan.profile)").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if plan.skipped > 0 { Text("対象外の\(plan.skipped)件は送信しません。").font(.callout).foregroundStyle(.secondary) }
            if let count = plan.duplicateCount, count > 0 { Text("内容が同じ\(count)件は送信しません。").font(.callout).foregroundStyle(.secondary) }
            if !plan.error.isEmpty { Label(plan.error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
            if plan.state != "planned" {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(plan.completed), total: Double(max(plan.items.count, 1)))
                    Text("照合済み \(plan.completed) / \(plan.items.count)件").font(.caption).foregroundStyle(.secondary)
                    if let progress = plan.progress {
                        Text(uploadPhase(progress.phase) + (progress.name.isEmpty ? "" : " · " + progress.name)).font(.caption)
                        ProgressView(value: Double(progress.bytes), total: Double(max(progress.totalBytes, 1)))
                        Text("\(size(progress.bytes)) / \(size(progress.totalBytes)) · 同時処理 \(progress.activeFiles)件").font(.caption).foregroundStyle(.secondary)
                        if let seconds = progress.remainingSeconds, progress.phase != "catalog" {
                            Text("残り約\(max(1, (seconds + 59) / 60))分（目安）").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                }
            }
            if ["uploading", "queued"].contains(plan.state) {
                Button("送信と予約を停止") { Task { await model.run { try await model.upload(plan, pause: true, encrypted: encrypted) } } }
            } else if plan.state == "complete" {
                UploadReceipt(plan: plan, encrypted: encrypted)
                Text("Macの原本はそのまま残っています。").font(.caption).foregroundStyle(.secondary)
            } else {
                if encrypted {
                    Text("同じ鍵で保存済みの素材と内容を比較し、重複は送信しません。途中から続ける場合は履歴の再開を使ってください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Macの原本は残ります。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(plan.state == "planned" ? "アップロードを開始" : "アップロードを再開") {
                        Task { await model.run { try await model.upload(plan, encrypted: encrypted) } }
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.awsLoginRequired || (encrypted ? model.encryptedUploads : model.uploads).contains { ["uploading", "queued"].contains($0.state) })
                }
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .disabled(model.busy)
    }
}
struct LibraryScreen: View {
    @EnvironmentObject var model: MacModel
    @State private var unlocking = false
    @State private var showingTrash = false
    @State private var rootTrash: FolderUpload?
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
            NavigationLink(value: key) { FolderTile(name: plan.name, protection: root.isLocked ? "通常保存 · PIN解除中" : "通常保存 · 内容暗号化なし", detail: "\(plan.items.count)件 · \(size(plan.byteSize))") }.buttonStyle(.plain)
                .contextMenu { Button("フォルダをごみ箱へ", role: .destructive) { rootTrash = plan } }
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("通常保存のフォルダです。PINは一覧を隠すための鍵で、内容の暗号化とは別です。")
                        .font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 210), spacing: 12)], spacing: 12) {
                        ForEach(model.library, id: \.id) { plan in
                            rootLink(plan)
                        }
                    }
                    if model.library.isEmpty {
                        Text(model.refreshing ? "S3のフォルダ情報を確認しています…" : "表示できるフォルダはありません。鍵付きフォルダは「隠したフォルダを開く」から表示できます。")
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
                Button("ごみ箱", systemImage: "trash") { showingTrash = true }
                Button("隠したフォルダを開く", systemImage: "lock.open") { unlocking = true }
                if model.hiddenPagesOpen || model.hasFolderUnlock { Button("閉じて隠す", systemImage: "lock") { Task { await model.relock() } } }
                Button("更新", systemImage: "arrow.clockwise") { Task { await model.run { try await model.refresh() } } }
            }
        }
        .onChange(of: model.library.flatMap { plan in plan.folders.map { "\(plan.id):\($0.id)" } }) { available in
            if let invalid = path.firstIndex(where: { !available.contains($0) }) { path = Array(path.prefix(invalid)) }
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
        .sheet(isPresented: $showingTrash) { CloudTrashScreen() }
        .confirmationDialog("「\(rootTrash?.name ?? "フォルダ")」全体をごみ箱へ移しますか？", isPresented: Binding(get: { rootTrash != nil }, set: { if !$0 { rootTrash = nil } }), titleVisibility: .visible) {
            if let plan = rootTrash, let root = plan.folders.first(where: { $0.parentId == nil }) {
                Button("ごみ箱へ移す", role: .destructive) { Task { await model.run { try await model.moveToTrash(plan: plan.id, folder: root.id); rootTrash = nil } } }
            }
        } message: { Text("Macの元ファイルは保持します。S3の一覧から外し、ごみ箱から復元できます。") }
        .sheet(isPresented: $unlocking) {
            let identity = model.privacyID
            HiddenPagePINSheet(beginKeychainInteraction: model.beginKeychainInteraction, endKeychainInteraction: model.endKeychainInteraction) { pin in
                guard !model.concealed, model.privacyID == identity else { return }
                try? await model.unlock(pin)
                guard !model.concealed, model.privacyID == identity || model.hasFolderUnlock else { return }
                model.hiddenPagesOpen = true
            }
        }
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
    @State private var specifyPIN = false
    @State private var processing = false
    @State private var operationError = ""
    private func submit(_ entered: String?, reuseExistingPIN: Bool = false) {
        guard !processing, !model.busy else { return }
        processing = true; operationError = ""; model.error = ""; model.notice = ""
        model.busy = true
        Task {
            defer { processing = false; model.busy = false }
            do {
                if let plan, let folder {
                    try await model.lock(plan: plan, folder: folder, password: entered, reuseExistingPIN: reuseExistingPIN)
                    model.notice = entered == nil && !reuseExistingPIN ? "鍵なしに変更しました。" : "鍵を設定し、フォルダを隠しました。"
                } else {
                    try await model.unlock(entered ?? "")
                    model.notice = "鍵を解除しました。フォルダを表示しています。"
                }
                dismiss()
            } catch is CancellationError { }
            catch {
                guard !model.concealed else { return }
                operationError = error.localizedDescription
                model.handle(error)
            }
        }
    }
    private var pinHint: String? {
        guard plan != nil, specifyPIN else { return nil }
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
            if plan != nil { Toggle("PINを指定する", isOn: $specifyPIN) }
            if plan == nil || specifyPIN {
            SecureField(plan == nil ? "PIN（以前のパスワードも使用可）" : "PIN（半角数字6桁）", text: $password)
            if plan != nil { SecureField("もう一度", text: $confirmation) }
            }
            if plan != nil {
                if !specifyPIN { Text("既存のフォルダ用PINで鍵を設定します。開くときは同じPINを使います。") }
                Text("このフォルダと子の中身を隠します。設定は非公開S3へ保存し、iPhoneにも反映します。原本は変更しません。") }
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
                    submit(entered, reuseExistingPIN: plan != nil && !specifyPIN)
                }.buttonStyle(.borderedProminent)
                    .disabled((plan == nil || specifyPIN) && (password.isEmpty || (plan != nil && (password.count != 6 || !password.utf8.allSatisfy { (48...57).contains($0) } || password != confirmation))))
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
    @State private var pdf: Data?
    @State private var player: AVPlayer?
    @State private var temporary: URL?
    @State private var error = ""
    var body: some View {
        VStack {
            if let pdf { MediaPDFReader(data: pdf) }
            else if let image { Image(nsImage: image).resizable().scaledToFit() }
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
                if isVideo(name) { player = AVPlayer(url: file); model.recordVideoStart() }
                else if URL(fileURLWithPath: name).pathExtension.lowercased() == "pdf" { pdf = try Data(contentsOf: file) }
                else if let loaded = NSImage(contentsOf: file) { image = loaded }
                else { error = "この形式は表示できません。" }
            } catch { if identity == model.privacyID { self.error = error.localizedDescription; model.handle(error) } }
        }
        .onDisappear { player?.pause(); player = nil; image = nil; pdf = nil; if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil }
    }
}
struct LightVideoScreen: View {
    @EnvironmentObject var model: MacModel
    @State private var selectedID: String?
    @State private var uploadID: String?
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
                        selectedID = value.id; uploadID = nil; try await model.refresh()
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
                                uploadID = plan.id; try await model.refresh()
                            } }
                        }
                        if let plan = model.uploads.first(where: { $0.id == uploadID }) { UploadPlanView(plan: plan) }
                    } else {
                        Button("軽量版を作る（Mac内）") { videoAction(job, action: "start") }.disabled(model.videos.contains { $0.state == "creating" })
                    }
                }
                Divider(); Text("作成履歴").font(.headline)
                ForEach(model.videos, id: \.id) { job in
                    Button("\(job.name) · \(stateName(job.state))") { selectedID = job.id; uploadID = nil }
                }
                Text("自動送信・自動削除は行いません。作成結果はアプリの作業領域に残ります。原本5GiB・2時間・60fpsまで。").font(.caption).foregroundStyle(.secondary)
            }.padding(28).disabled(model.busy)
        }
    }
    func videoAction(_ job: LightVideo, action: String) {
        Task { await model.run { try await model.runtime.action("/light-videos/\(job.id)/\(action)"); try await model.refresh() } }
    }
}

struct CloudTrashScreen: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var targets: [CloudTrashEntry] = []
    @State private var confirming = false
    @State private var loaded = false
    private var selectedEntries: [CloudTrashEntry] { model.trash.filter { selected.contains($0.id) } }
    private func confirm(_ entries: [CloudTrashEntry]) { targets = entries; confirming = true }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("ごみ箱").font(.title2); Spacer(); Button("閉じる") { dismiss() }.disabled(model.busy) }
            Text("通常フォルダの表示中の対象だけを操作します。暗号化フォルダは対象外です。Macの元ファイルは保持します。")
                .foregroundStyle(.secondary)
            HStack {
                Text("\(model.trash.count)件 · \(size(model.trash.reduce(0) { $0 + $1.byteSize }))").monospacedDigit()
                Spacer()
                Button("選択した\(selected.count)件を完全削除", role: .destructive) { confirm(selectedEntries) }.disabled(selectedEntries.isEmpty || !loaded)
                Button("表示中をすべて完全削除", role: .destructive) { confirm(model.trash) }.disabled(model.trash.isEmpty || !loaded)
            }
            Button("ごみ箱を更新", systemImage: "arrow.clockwise") { Task { await model.run { try await model.refreshTrash(); loaded = true } } }
            if !loaded && model.error.isEmpty { ProgressView("ごみ箱を確認しています…") }
            else if model.trash.isEmpty { Text("ごみ箱は空です。").padding() }
            List(model.trash, id: \.id, selection: $selected) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                        Text("\(entry.itemIds.count)ファイル · \(size(entry.byteSize))" + (entry.state == "deleting" ? " · 完全削除中（再試行可能）" : "")).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("復元") { Task { await model.run { try await model.trashAction(entry, action: "restore") } } }.disabled(entry.state != "trashed")
                    Button(entry.state == "deleting" ? "完全削除を再試行" : "完全削除", role: .destructive) { confirm([entry]) }
                }.padding(.vertical, 6).tag(entry.id)
            }
            Text("⌘クリックで複数選択できます。削除・復元は更新後のiPhoneの一覧にも反映されます。操作はMacから行います。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.trashProgress.isEmpty { ProgressView(model.trashProgress) }
            if !model.error.isEmpty { Text(model.error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.notice.isEmpty { Text(model.notice).foregroundStyle(.green) }
        }.padding(24).frame(minWidth: 760, minHeight: 460).controlSize(.large)
        .interactiveDismissDisabled(model.busy)
        .disabled(model.busy)
        .task { await model.run { try await model.refreshTrash(); loaded = true } }
        .onChange(of: model.trash.map(\.id)) { ids in selected.formIntersection(Set(ids)) }
        .confirmationDialog("\(targets.count)件を完全削除しますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("\(targets.count)件を完全削除する", role: .destructive) {
                let snapshot = targets
                Task { await model.purgeTrash(snapshot) }
            }
            Button("キャンセル", role: .cancel) { targets = [] }
        } message: {
            Text("対象の原本 \(targets.reduce(0) { $0 + $1.itemIds.count })ファイル・\(size(targets.reduce(0) { $0 + $1.byteSize }))と、小画像・過去バージョンを削除します。復元できません。表示されていない鍵付き項目は対象外です。")
        }
    }
}

private func uploadPhase(_ phase: String) -> String {
    ["duplicates": "保存済み素材と重複を確認中", "preparing": "原本を準備・照合中", "encrypting": "暗号化中", "uploading": "送信中", "thumbnail": "小画像を作成・照合中", "catalog": "フォルダ情報を保存中"][phase] ?? "処理中"
}
