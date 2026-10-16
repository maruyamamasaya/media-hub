import AppKit
import AssetLibraryContract
import SwiftUI
import PhotoHubCore

@MainActor
final class MacModel: ObservableObject {
    let runtime: MacRuntime
    @Published var library: [FolderUpload] = []
    @Published var trash: [CloudTrashEntry] = []
    @Published var uploads: [FolderUpload] = []
    @Published var encryptedUploads: [FolderUpload] = []
    @Published var encryptionReady = false
    @Published var videos: [LightVideo] = []
    @Published var error = ""
    @Published var notice = ""
    @Published var showAWSLogin = false
    @Published private(set) var awsLoginRequired = false
    @Published private(set) var hasFolderUnlock = false
    @Published private(set) var refreshing = false
    @Published private(set) var refreshPhase = ""
    @Published var busy = false
    @Published var scanName = ""
    @Published var scanBytes: Int64 = 0
    @Published var scanTotalBytes: Int64 = 0
    @Published var scanRemainingSeconds: Int64?
    @Published var scanning = false
    @Published private(set) var uploadBatch: UploadBatch?
    @Published private(set) var uploadBatchStopping = false
    private var uploadBatchEncrypted = false
    @Published var privacyID = UUID()
    @Published var hiddenPagesOpen = false
    @Published var concealed = false
    @Published var bucket = "photo-hub-storage-bucket-ajgsbh5jtcvp"
    @Published var profile = "photo-hub"
    @Published var region = "ap-northeast-1"
    private var needsRefresh = true
    private var refreshSerial: UInt64 = 0
    private var loadedDestination = false
    private var keychainInteractions = 0
    private var unlockTimer: Task<Void, Never>?
    init(runtime: MacRuntime) { self.runtime = runtime; encryptionReady = (try? MediaSecretStore.load()) != nil }
    var usageScope: String { bucket + "|" + profile + "|" + region }
    func recordVideoStart() { UsageActivityStore.shared.record(scope: usageScope, videoStarts: 1) }
    func beginKeychainInteraction() { keychainInteractions += 1 }
    func endKeychainInteraction() async {
        // SecurityAgent can return the Keychain result before macOS reactivates us.
        for _ in 0..<10 where !NSApplication.shared.isActive {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        keychainInteractions = max(0, keychainInteractions - 1)
        if !NSApplication.shared.isActive { await applicationDeactivated() }
    }
    func withKeychainInteraction<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        beginKeychainInteraction()
        let result = await Task.detached { Result { try work() } }.value
        await endKeychainInteraction()
        guard !concealed else { throw CancellationError() }
        return try result.get()
    }
    func applicationDeactivated() async {
        guard keychainInteractions == 0 else { return }
        concealed = true
        await relock()
    }
    func applicationActivated() async {
        // Activation alone must not destroy a PIN sheet or a newly unlocked view.
        guard concealed else { return }
        concealed = false
        await relock()
    }
    func run(_ work: () async throws -> Void) async {
        guard !busy else { return }
        refreshSerial &+= 1
        busy = true; error = ""
        let identity = privacyID
        defer { busy = false }
        do { try await work() } catch is CancellationError {} catch { if identity == privacyID { handle(error) } }
    }
    func handle(_ failure: Error) {
        error = failure.localizedDescription
        if case MacAPIError.awsLoginRequired = failure {
            if !awsLoginRequired { showAWSLogin = true }
            awsLoginRequired = true
        }
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var loginCommand: String { "aws login --profile \(Self.shellQuote(profile)) --region \(Self.shellQuote(region))" }
    func openAWSLogin() {
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("media-hub-login-\(UUID().uuidString).command")
            let script = "#!/bin/sh\nexport PATH=/opt/homebrew/bin:/usr/local/bin:$PATH\n\(loginCommand)\nprintf '\\nログイン後、Media Hubに戻り「接続を確認」を押してください。\\n'\nrm -- \(Self.shellQuote(file.path))\n"
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard NSWorkspace.shared.open(file) else { throw MacAPIError.message("ターミナルを開けません。設定画面のログインコマンドを実行してください。") }
        } catch { self.error = error.localizedDescription }
    }
    func checkAWSLogin() async {
        guard !busy else { return }
        awsLoginRequired = false
        await run { try await refresh() }
    }
    func refresh() async throws {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; refreshPhase = "" }
        refreshPhase = "アップロード履歴を取得しています…"
        refreshSerial &+= 1
        let serial = refreshSerial
        let identity = privacyID
        let newUploads: [FolderUpload] = try await runtime.request("/folder-uploads")
        if !loadedDestination, let plan = newUploads.first {
            bucket = plan.bucket; profile = plan.profile; region = plan.region; loadedDestination = true
        }
        let newEncrypted: [FolderUpload] = try await runtime.request("/encrypted-uploads")
        let newVideos: [LightVideo] = try await runtime.request("/light-videos")
        guard identity == privacyID, serial == refreshSerial, !concealed else { return }
        uploads = newUploads; encryptedUploads = newEncrypted; videos = newVideos
        refreshPhase = "S3のフォルダ情報と鍵設定を確認しています…"
        let newLibrary: [FolderUpload] = try await runtime.request("/folder-library")
        guard identity == privacyID, serial == refreshSerial, !concealed else { return }
        library = newLibrary
        needsRefresh = false
    }
    func refreshTrash() async throws {
        let identity = privacyID
        let value: [CloudTrashEntry] = try await runtime.request("/folder-library/trash")
        guard identity == privacyID, !concealed else { return }
        trash = value
    }
    func poll() async {
        while !Task.isCancelled {
            let working = (uploads + encryptedUploads).contains { ["uploading", "queued"].contains($0.state) } || videos.contains { $0.state == "creating" }
            if runtime.ready && !concealed && !busy && !awsLoginRequired && (needsRefresh || working) {
                let identity = privacyID
                let serial = refreshSerial &+ 1
                do {
                    if working {
                        try await refreshUploads()
                        if videos.contains(where: { $0.state == "creating" }) {
                            let value: [LightVideo] = try await runtime.request("/light-videos")
                            if identity == privacyID, serial == refreshSerial, !concealed { videos = value }
                        }
                        if serial == refreshSerial && !(uploads + encryptedUploads).contains(where: { ["uploading", "queued"].contains($0.state) }) && !videos.contains(where: { $0.state == "creating" }) { needsRefresh = true }
                    } else { try await refresh() }
                } catch {
                    if identity == privacyID, serial == refreshSerial, !concealed { handle(error) }
                }

            }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }
    func refreshUploads() async throws {
        refreshSerial &+= 1
        let serial = refreshSerial
        let identity = privacyID
        let normal: [FolderUpload] = try await runtime.request("/folder-uploads")
        let sealed: [FolderUpload] = try await runtime.request("/encrypted-uploads")
        guard identity == privacyID, serial == refreshSerial, !concealed else { return }
        uploads = normal; encryptedUploads = sealed
    }
    func scan(_ path: String, encrypted: Bool = false) async throws -> FolderUpload {
        let identity = privacyID
        let prefix = encrypted ? "/encrypted-uploads" : "/folder-uploads"
        scanning = true; scanBytes = 0; scanTotalBytes = 0; scanRemainingSeconds = nil; scanName = URL(fileURLWithPath: path).lastPathComponent
        defer { scanning = false }
        var job: UploadScanJob = try await runtime.request(prefix + "/scan-jobs", method: "POST", body: ["path": path, "bucket": bucket, "profile": profile, "region": region])
        while job.state == "scanning" {
            try await Task.sleep(nanoseconds: 300_000_000)
            job = try await runtime.request(prefix + "/scan-jobs/" + job.id)
            guard identity == privacyID, !concealed else { throw CancellationError() }
            scanName = job.name; scanBytes = job.bytes; scanTotalBytes = job.totalBytes; scanRemainingSeconds = job.remainingSeconds
        }
        guard job.state == "complete", let planID = job.planId else { throw MacAPIError.message(job.error) }
        try await refreshUploads()
        guard identity == privacyID, !concealed else { throw CancellationError() }
        guard let plan = (encrypted ? encryptedUploads : uploads).first(where: { $0.id == planID }) else {
            throw MacAPIError.message("フォルダの確認結果を取得できません。")
        }
        return plan
    }
    func prepareUploads(_ paths: [String], encrypted: Bool,
                        onPrepared: (FolderUpload) -> Void) async throws {
        let batch = UploadBatch()
        let identity = privacyID
        uploadBatch = batch; uploadBatchEncrypted = encrypted; uploadBatchStopping = false
        defer { uploadBatch = nil; uploadBatchStopping = false }
        var plans: [String: FolderUpload] = [:]
        func check() throws {
            try batch.check()
            guard identity == privacyID, !concealed else { throw CancellationError() }
        }
        do {
            try await batch.execute(paths, prepare: { path in
                try check()
                let plan = try await self.scan(path, encrypted: encrypted)
                try check()
                plans[plan.id] = plan; onPrepared(plan)
                return plan.id
            }, start: { id in
                try check()
                guard let plan = plans[id] else { throw CancellationError() }
                try await self.upload(plan, encrypted: encrypted)
                // Stop may arrive while Keychain or the start request is awaiting.
                if batch.stopped || identity != self.privacyID || self.concealed {
                    try await self.runtime.action("/\(encrypted ? "encrypted-uploads" : "folder-uploads")/\(id)/pause")
                    throw CancellationError()
                }
            }, wait: { id in
                while true {
                    try check()
                    try await self.refreshUploads()
                    try check()
                    guard let plan = (encrypted ? self.encryptedUploads : self.uploads).first(where: { $0.id == id }) else {
                        throw MacAPIError.message("送信履歴を確認できません。残りの追加を停止しました。")
                    }
                    if plan.state == "complete" { return }
                    if !["uploading", "queued"].contains(plan.state) {
                        throw MacAPIError.message(plan.error.isEmpty ? "送信が停止したため、残りの追加も停止しました。" : plan.error)
                    }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            })
        } catch {
            // No later folder is sent after a preparation or transfer failure.
            if let id = batch.activeID {
                try? await runtime.action("/\(encrypted ? "encrypted-uploads" : "folder-uploads")/\(id)/pause")
            }
            throw error
        }
    }
    func stopUploadPreparation() async {
        guard let batch = uploadBatch else { return }
        batch.stopped = true; uploadBatchStopping = true
        if let id = batch.activeID {
            do { try await runtime.action("/\(uploadBatchEncrypted ? "encrypted-uploads" : "folder-uploads")/\(id)/pause") }
            catch { handle(error) }
        }
    }
    func uploadQueue(_ plans: [FolderUpload], encrypted: Bool) async throws {
        var body: [String: Any] = ["confirmUpload": true, "planIds": plans.map(\.id)]
        if encrypted {
            guard let secret = try await withKeychainInteraction({ try MediaSecretStore.load() }) else { throw SealedError.wrongKey }
            body["keyID"] = secret.keyID; body["masterKey"] = secret.masterKey.base64EncodedString()
        }
        try await runtime.action((encrypted ? "/encrypted-uploads" : "/folder-uploads") + "/queue", body: body)
        try await refreshUploads()
    }
    func chooseFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true; panel.prompt = "追加"
        return panel.runModal() == .OK ? panel.urls : []
    }
    func upload(_ plan: FolderUpload, pause: Bool = false, encrypted: Bool = false) async throws {
        var body: [String: Any] = pause ? [:] : ["confirmUpload": true]
        if encrypted && !pause {
            guard let secret = try await withKeychainInteraction({ try MediaSecretStore.load() }) else { throw SealedError.wrongKey }
            body["keyID"] = secret.keyID; body["masterKey"] = secret.masterKey.base64EncodedString()
        }
        try await runtime.action("/\(encrypted ? "encrypted-uploads" : "folder-uploads")/\(plan.id)/\(pause ? "pause" : "start")", body: body)
        try await refreshUploads()
    }
    func moveToTrash(plan: String, items: [String] = [], folder: String? = nil) async throws {
        try await runtime.action("/folder-library/\(plan)/trash", body: ["action": "trash", "confirm": true, "itemIds": items, "folderId": folder as Any? ?? NSNull()])
        try await refresh()
    }
    func trashAction(_ entry: CloudTrashEntry, action: String) async throws {
        try await runtime.action("/folder-library/\(entry.planId)/trash", body: ["action": action, "confirm": true, "entryId": entry.id])
        try await refreshTrash()
        try await refresh()
    }
    @Published var trashProgress = ""
    func purgeTrash(_ entries: [CloudTrashEntry]) async {
        await run {
            let identity = privacyID
            var completed = 0
            defer { trashProgress = "" }
            do {
                try await TrashBatch.execute(entries, authorized: { identity == privacyID && !concealed }) { entry in
                    trashProgress = "完全削除中 \(completed + 1) / \(entries.count)件"
                    try await runtime.action("/folder-library/\(entry.planId)/trash", body: ["action": "purge", "confirm": true, "entryId": entry.id])
                    completed += 1
                }
            } catch {
                // Refresh once after partial success; retain the original failure.
                if identity == privacyID, !concealed {
                    try? await refreshTrash()
                    handle(error)
                    self.error = "\(completed) / \(entries.count)件の削除が完了。残りはごみ箱で確認して再試行してください。\n" + self.error
                }
                return
            }
            guard identity == privacyID, !concealed else { return }
            notice = "ごみ箱の\(completed)件を完全削除しました。"
            try await refreshTrash()
            try await refresh()
        }
    }
    func unlock(_ password: String) async throws {
        let identity = privacyID
        try await runtime.action("/folder-locks/unlock", body: ["password": password])
        guard identity == privacyID, !concealed else { runtime.clearUnlock(); throw CancellationError() }
        hasFolderUnlock = true
        privacyID = UUID()
        unlockTimer?.cancel()
        unlockTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
            await self?.relock()
        }
        try await refresh()
    }
    func relock() async {
        unlockTimer?.cancel(); unlockTimer = nil
        needsRefresh = true
        hasFolderUnlock = false
        hiddenPagesOpen = false
        privacyID = UUID(); library = []; trash = []; uploads = []; encryptedUploads = []; videos = []; error = ""; notice = ""
        runtime.clearUnlock()
        // Removing the local cookie immediately invalidates this client's grant; no network required.
        // poll refreshes the library without blocking upload controls.
        // The cookie and all visible private data have already been cleared.
    }
    func lock(plan: String, folder: String, password: String?, reuseExistingPIN: Bool = false) async throws {
        var body: [String: Any] = ["planId": plan, "folderId": folder, "confirmSave": true]
        if reuseExistingPIN { body["reuseExistingPIN"] = true }
        else { body["password"] = password as Any? ?? NSNull() }
        try await runtime.action("/folder-locks/settings", body: body)
        await relock()
    }
    func choose(directory: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        return panel.runModal() == .OK ? panel.url : nil
    }
    func export(_ path: String, name: String) async throws {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let identity = privacyID
        let temporary = try await runtime.download(path)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard identity == privacyID, !concealed else { throw CancellationError() }
        // NSSavePanel confirms replacement; atomic write avoids a partial destination.
        let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
        try data.write(to: destination, options: .atomic)
    }
}
func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) }
func stateName(_ value: String) -> String {
    ["queued": "順番待ち", "planned": "確認待ち", "uploading": "送信中", "paused": "停止中", "interrupted": "中断", "failed": "失敗", "complete": "完了", "creating": "作成中", "cancelled": "停止"][value] ?? value
}

struct UploadScanJob: Decodable {
    let id: String
    let state: String
    let bytes: Int64
    let name: String
    let planId: String?
    let totalBytes: Int64
    let remainingSeconds: Int64?
    let error: String
}
