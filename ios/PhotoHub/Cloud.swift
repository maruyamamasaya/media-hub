import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import PhotoHubCore

struct CloudConfiguration: Codable {
    var api = ""
    var domain = ""
    var clientID = ""
    var owner = ""
    var valid: Bool { [api, domain].allSatisfy { URL(string: $0)?.scheme == "https" && URL(string: $0)?.host?.isEmpty == false } && !clientID.isEmpty && UUID(uuidString: owner) != nil }
}
enum StoredSessionError: Error { case missing, expired }

protocol RefreshTokenStorage {
    func read(_ configuration: CloudConfiguration) throws -> String
    func save(_ token: String, configuration: CloudConfiguration) throws
    func delete(_ configuration: CloudConfiguration)
}
struct KeychainRefreshTokens: RefreshTokenStorage {
    private func query(_ configuration: CloudConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PhotoHub.Cognito", kSecAttrAccount as String: configuration.domain + configuration.clientID]
    }
    func read(_ configuration: CloudConfiguration) throws -> String {
        var values = query(configuration)
        values[kSecReturnData as String] = true; values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(values as CFDictionary, &result)
        if status == errSecItemNotFound { throw StoredSessionError.missing }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw HubError.configuration }
        return token
    }
    func save(_ token: String, configuration: CloudConfiguration) throws {
        let values = query(configuration)
        let data: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(values as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(values.merging(data) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw HubError.configuration }
        } else if status != errSecSuccess { throw HubError.configuration }
    }
    func delete(_ configuration: CloudConfiguration) { SecItemDelete(query(configuration) as CFDictionary) }
}

@MainActor
final class Authentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let network: URLSession
    private let storage: any RefreshTokenStorage
    init(network: URLSession = .shared, storage: any RefreshTokenStorage = KeychainRefreshTokens()) { self.network = network; self.storage = storage; super.init() }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    private func random() throws -> String { var bytes = [UInt8](repeating: 0, count: 32); guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw HubError.configuration }; return base64(Data(bytes)) }
    func signOut(_ configuration: CloudConfiguration) { storage.delete(configuration) }
    func login(_ configuration: CloudConfiguration) async throws {
        guard configuration.valid else { throw HubError.configuration }
        let verifier = try random(), state = try random()
        var url = URLComponents(string: configuration.domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth2/authorize")!
        url.queryItems = [URLQueryItem(name: "client_id", value: configuration.clientID), URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "redirect_uri", value: "photohub://callback"), URLQueryItem(name: "scope", value: "openid email"), URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "code_challenge", value: base64(Data(SHA256.hash(data: Data(verifier.utf8)))))]
        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "photohub") { callback, error in
                if let callback { continuation.resume(returning: callback) } else { continuation.resume(throwing: error ?? HubError.configuration) }
            }
            session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = true; self.session = session
            if !session.start() { self.session = nil; continuation.resume(throwing: HubError.configuration) }
        }
        session = nil
        let values = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard values.first(where: { $0.name == "state" })?.value == state, let code = values.first(where: { $0.name == "code" })?.value else { throw HubError.configuration }
        let tokens = try await exchange(configuration, fields: ["grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": "photohub://callback"])
        guard let refresh = tokens["refresh_token"] else { throw HubError.configuration }
        try storage.save(refresh, configuration: configuration)
    }
    func token(_ configuration: CloudConfiguration) async throws -> String {
        guard configuration.valid else { throw HubError.configuration }
        let refresh = try storage.read(configuration)
        let tokens = try await exchange(configuration, fields: ["grant_type": "refresh_token", "refresh_token": refresh])
        guard let token = tokens["access_token"] else { throw HubError.configuration }; return token
    }
    private func exchange(_ configuration: CloudConfiguration, fields: [String: String]) async throws -> [String: String] {
        var request = URLRequest(url: URL(string: configuration.domain.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/oauth2/token")!); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents(); form.queryItems = (fields.merging(["client_id": configuration.clientID]) { _, new in new }).map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await network.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HubError.configuration }
        if response.statusCode != 200 {
            if payload["error"] as? String == "invalid_grant" { throw StoredSessionError.expired }
            throw HubError.configuration
        }
        return payload.compactMapValues { $0 as? String }
    }
}
final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { report(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
}
final class S3ObjectStore: ObjectStore {
    var owner: String { configuration.owner }
    let configuration: CloudConfiguration
    let authentication: Authentication
    init(configuration: CloudConfiguration, authentication: Authentication) { self.configuration = configuration; self.authentication = authentication }
    private func call(_ action: String, key: String, extra: [String: Any] = [:]) async throws -> [String: Any] {
        let token = try await authentication.token(configuration)
        var request = URLRequest(url: URL(string: configuration.api.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/objects")!); request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Server validates this key against the owner and canonical allowed shape.
        request.httpBody = try JSONSerialization.data(withJSONObject: extra.merging(["action": action, "key": key]) { _, new in new })
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 409 { throw NSError(domain: "PhotoHub", code: 409, userInfo: [NSLocalizedDescriptionKey: "削除予約済みです。既存のアップロードURLの期限切れを待ち、6分後に削除を再試行してください。"]) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HubError.configuration }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HubError.integrity }; return payload
    }
    func head(key: String) async throws -> ObjectInfo? {
        let result = try await call("head", key: key)
        guard result["exists"] as? Bool == true else { return nil }
        guard let bytes = result["bytes"] as? Int64, let checksum = result["checksum"] as? String else { throw HubError.integrity }
        return ObjectInfo(bytes: bytes, checksum: checksum)
    }
    func put(file: URL, key: String, mime: String, checksum: String, progress: @escaping (Double) -> Void) async throws {
        let result = try await call("put", key: key, extra: ["mime": mime, "checksum": checksum, "bytes": Digest.bytes(file: file)])
        guard let raw = result["url"] as? String, let url = URL(string: raw), url.scheme == "https" else { throw HubError.integrity }
        var request = URLRequest(url: url); request.httpMethod = "PUT"
        request.setValue(mime, forHTTPHeaderField: "Content-Type"); request.setValue(checksum, forHTTPHeaderField: "x-amz-checksum-sha256")
        if !key.hasSuffix("/backups/latest.json") { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let delegate = UploadProgress(progress), session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) || status == 412 else { throw HubError.integrity }
    }
    func get(key: String, destination: URL) async throws {
        let result = try await call("get", key: key)
        guard let raw = result["url"] as? String, let url = URL(string: raw), url.scheme == "https" else { throw HubError.integrity }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HubError.missingOriginal }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    func delete(key: String) async throws { _ = try await call("delete", key: key) }
}
