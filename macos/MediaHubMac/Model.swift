import AppKit
import AssetLibraryContract
import SwiftUI

@MainActor
final class MacModel: ObservableObject {
    let runtime: MacRuntime
    @Published var library: [FolderUpload] = []
    @Published var uploads: [FolderUpload] = []
    @Published var videos: [LightVideo] = []
    @Published var error = ""
    @Published var notice = ""
    @Published private(set) var hasFolderUnlock = false
    @Published var busy = false
    @Published var privacyID = UUID()
    @Published var concealed = false
    @Published var bucket = "photo-hub-storage-bucket-ajgsbh5jtcvp"
    @Published var profile = "photo-hub"
    @Published var region = "ap-northeast-1"
    private var needsRefresh = true
    private var loadedDestination = false
    private var unlockTimer: Task<Void, Never>?
    init(runtime: MacRuntime) { self.runtime = runtime }
    func run(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = ""
        let identity = privacyID
        defer { busy = false }
        do { try await work() } catch is CancellationError {} catch { if identity == privacyID { self.error = error.localizedDescription } }
    }
    func refresh() async throws {
        let identity = privacyID
        let newUploads: [FolderUpload] = try await runtime.request("/folder-uploads")
        let newLibrary: [FolderUpload] = try await runtime.request("/folder-library")
        let newVideos: [LightVideo] = try await runtime.request("/light-videos")
        guard identity == privacyID, !concealed else { return }
        uploads = newUploads; library = newLibrary; videos = newVideos
        needsRefresh = false
        if !loadedDestination, let plan = newUploads.first {
            bucket = plan.bucket; profile = plan.profile; region = plan.region; loadedDestination = true
        }
    }
    func poll() async {
        while !Task.isCancelled {
            let working = uploads.contains { $0.state == "uploading" } || videos.contains { $0.state == "creating" }
            if runtime.ready && !concealed && !busy && (needsRefresh || working) {
                await run { try await refresh() }
            }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
    }
    func scan(_ path: String) async throws -> FolderUpload {
        try await runtime.request("/folder-uploads/scan", method: "POST", body: ["path": path, "bucket": bucket, "profile": profile, "region": region])
    }
    func upload(_ plan: FolderUpload, pause: Bool = false) async throws {
        try await runtime.action("/folder-uploads/\(plan.id)/\(pause ? "pause" : "start")", body: pause ? [:] : ["confirmUpload": true])
        try await refresh()
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
        privacyID = UUID(); library = []; uploads = []; videos = []; error = ""; notice = ""
        runtime.clearUnlock()
        // Removing the local cookie immediately invalidates this client's grant; no network required.
        if !concealed && runtime.ready { await run { try await refresh() } }
    }
    func lock(plan: String, folder: String, password: String?) async throws {
        try await runtime.action("/folder-locks/settings", body: ["planId": plan, "folderId": folder, "password": password as Any? ?? NSNull(), "confirmSave": true])
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
    ["planned": "確認待ち", "uploading": "送信中", "paused": "停止中", "interrupted": "中断", "failed": "失敗", "complete": "完了", "creating": "作成中", "cancelled": "停止"][value] ?? value
}
