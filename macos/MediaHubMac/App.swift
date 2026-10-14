import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: MacRuntime?
    private var quitApproved = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitApproved, let runtime else { return .terminateNow }
        Task { await runtime.stop(); quitApproved = true; sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }
}
@main
struct MediaHubMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var runtime: MacRuntime
    @StateObject private var model: MacModel
    init() {
        let path = ProcessInfo.processInfo.environment["MEDIA_HUB_ROOT"] ?? Bundle.main.object(forInfoDictionaryKey: "MediaHubDevelopmentRoot") as? String ?? FileManager.default.currentDirectoryPath
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let dataRoot = root.appendingPathComponent(CommandLine.arguments.contains("--smoke-test") ? ".local/native-smoke-library" : CommandLine.arguments.contains("--web-library") ? ".local/asset-library" : ".local/desktop-library")
        let runtime = MacRuntime(root: root, dataRoot: dataRoot)
        _runtime = StateObject(wrappedValue: runtime); _model = StateObject(wrappedValue: MacModel(runtime: runtime))
    }
    var body: some Scene {
        Window("media-hub", id: "main") {
            MacRootView(model: model, runtime: runtime).environmentObject(model).onAppear { delegate.runtime = runtime }
        }.defaultSize(width: 1100, height: 800)
    }
}
