import AppKit
import Foundation

/// Owns a private loopback API. Credentials remain in memory and travel only through stdin/headers.
@MainActor
final class MacRuntime: ObservableObject {
    @Published var ready = false
    @Published var error = ""
    private(set) var origin: URL?
    private(set) var token = ""
    private var child: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var startupData = Data()
    private var stopping = false
    private var startTask: Task<Void, Never>?
    let root: URL
    let dataRoot: URL
    let network: URLSession

    init(root: URL, dataRoot: URL) {
        self.root = root; self.dataRoot = dataRoot
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        network = URLSession(configuration: configuration)
    }
    func start() {
        guard child == nil else { return }
        error = ""; stopping = false
        token = UUID().uuidString + UUID().uuidString
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        let python = ProcessInfo.processInfo.environment["PHOTO_HUB_PYTHON"] ?? root.appendingPathComponent(".venv/bin/python").path
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", root.appendingPathComponent("local-api/desktop_run.py").path]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        // Finder-launched apps do not inherit the user's shell PATH.
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        input = stdin; output = stdout; child = process
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ready = false
                if !self.stopping { self.error = "処理が停止しました。アプリを終了して起動し直してください。" }
            }
        }
        do {
            try process.run()
            let config: [String: String] = ["token": token, "dataRoot": dataRoot.path, "fixtures": root.appendingPathComponent(".local/fixtures").path]
            var data = try JSONSerialization.data(withJSONObject: config); data.append(10)
            try stdin.fileHandleForWriting.write(contentsOf: data)
            startTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, !self.ready else { return }
                self.error = "起動できません。Python環境と、旧アプリが完全終了しているかを確認してください。"
                await self.stop()
            }
        } catch {
            self.error = "処理を起動できません。先にMac版の準備を実行してください。"
            process.terminationHandler = nil
            stdout.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            child = nil
        }
    }
    private func consume(_ data: Data) {
        guard !data.isEmpty, origin == nil, !stopping else { return }
        startupData.append(data)
        guard startupData.count < 4096 else { error = "起動応答が不正です。"; Task { await stop() }; return }
        guard let newline = startupData.firstIndex(of: 10) else { return }
        struct Startup: Decodable { let origin: String; let pid: Int32 }
        guard let info = try? JSONDecoder().decode(Startup.self, from: startupData[..<newline]),
              let url = URL(string: info.origin), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil, info.pid == child?.processIdentifier else {
            error = "起動応答が不正です。"; Task { await stop() }; return
        }
        origin = url
        Task {
            do {
                struct Status: Decodable { let mode: String }
                let status: Status = try await request("/status")
                guard status.mode == "local", !stopping, child?.isRunning == true else { throw MacAPIError.invalidResponse }
                ready = true; startTask?.cancel()
            } catch { self.error = "処理への接続を確認できません。"; await stop() }
        }
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let data = try await bytes(path, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func action(_ path: String, body: [String: Any] = [:]) async throws {
        _ = try await bytes(path, method: "POST", body: body)
    }
    private func makeRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let origin, path.hasPrefix("/"), let url = URL(string: origin.absoluteString + "/api/v1" + path),
              url.host == origin.host, url.port == origin.port, !stopping else { throw MacAPIError.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Photo-Hub-Token")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    func bytes(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let (data, response) = try await network.data(for: makeRequest(path, method: method, body: body))
        try Self.validate(response, data: data)
        return data
    }
    func download(_ path: String) async throws -> URL {
        let (file, response) = try await network.download(for: makeRequest(path))
        let errorData = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == false ? try? Data(contentsOf: file) : nil
        do { try Self.validate(response, data: errorData); return file }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    static func validate(_ response: URLResponse, data: Data?) throws {
        guard let response = response as? HTTPURLResponse else { throw MacAPIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if let data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let detail = (value["message"] ?? value["detail"]) as? String {
                if value["code"] as? String == "aws_login_required" { throw MacAPIError.awsLoginRequired }
                throw MacAPIError.message(detail)
            }
            throw MacAPIError.message("操作に失敗しました（\(response.statusCode)）。接続と本人認証を確認してください。")
        }
    }
    func clearUnlock() { network.configuration.httpCookieStorage?.cookies?.forEach { network.configuration.httpCookieStorage?.deleteCookie($0) } }
    func stop() async {
        stopping = true; ready = false; startTask?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let child {
            await Task.detached {
                let deadline = Date().addingTimeInterval(35)
                while child.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }.value
        }
        clearUnlock(); origin = nil; token = ""
    }
}
enum MacAPIError: LocalizedError {
    case unavailable, invalidResponse, awsLoginRequired, message(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "処理の起動を待ってください。"
        case .invalidResponse: return "処理からの応答を確認できません。"
        case .awsLoginRequired: return "AWSへの再ログインが必要です。ログイン後に接続を確認してください。"
        case .message(let value): return value
        }
    }
}
