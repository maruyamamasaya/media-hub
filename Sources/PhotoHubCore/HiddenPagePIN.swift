import Foundation
import Security
import SwiftUI

public enum HiddenPINError: LocalizedError {
    case invalid, mismatch, wait
    public var errorDescription: String? {
        switch self {
        case .invalid: return "半角数字6桁のPINを入力してください。"
        case .mismatch: return "PINが違います。"
        case .wait: return "入力を繰り返したため、30秒待ってから再試行してください。"
        }
    }
}
public enum HiddenPagePIN {
    private struct Record: Codable {
        var verifier: Data
        var failures = 0
        var blockedUntil: Date = .distantPast
    }
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "personal.mediahub.hidden-page-pin.v1", kSecAttrAccount as String: "entry", kSecAttrSynchronizable as String: false] }
    public static func valid(_ pin: String) -> Bool { pin.utf8.count == 6 && pin.utf8.allSatisfy { (48...57).contains($0) } }
    private static func load() throws -> Record? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SealedError.keychain(status) }
        return try JSONDecoder().decode(Record.self, from: data)
    }
    public static func configured() throws -> Bool { try load() != nil }
    private static func save(_ record: Record, creating: Bool) throws {
        let data = try JSONEncoder().encode(record)
        let status: OSStatus
        if creating {
            status = SecItemAdd(query.merging([kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
        } else { status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        guard status == errSecSuccess else { throw SealedError.keychain(status) }
    }
    public static func create(_ pin: String) throws {
        guard valid(pin), try load() == nil else { throw HiddenPINError.invalid }
        let verifier = try RecoveryFile.export(MediaSecret(), password: "media-hub/hidden-pin/v1/" + pin)
        try save(Record(verifier: verifier), creating: true)
    }
    public static func verify(_ pin: String) throws {
        guard valid(pin), var record = try load() else { throw HiddenPINError.invalid }
        guard Date() >= record.blockedUntil else { throw HiddenPINError.wait }
        do { _ = try RecoveryFile.restore(record.verifier, password: "media-hub/hidden-pin/v1/" + pin) }
        catch {
            record.failures += 1
            if record.failures >= 5 { record.blockedUntil = Date().addingTimeInterval(30); record.failures = 0 }
            try save(record, creating: false)
            throw HiddenPINError.mismatch
        }
        record.failures = 0; record.blockedUntil = .distantPast
        try save(record, creating: false)
    }
}

public struct HiddenPagePINSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configured: Bool?
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var busy = false
    @State private var error = ""
    private let open: @MainActor (String) async -> Void
    private let beginKeychainInteraction: @MainActor () -> Void
    private let endKeychainInteraction: @MainActor () async -> Void
    public init(beginKeychainInteraction: @escaping @MainActor () -> Void = {}, endKeychainInteraction: @escaping @MainActor () async -> Void = {}, open: @escaping @MainActor (String) async -> Void) {
        self.beginKeychainInteraction = beginKeychainInteraction
        self.endKeychainInteraction = endKeychainInteraction
        self.open = open
    }
    @MainActor
    private func keychain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        beginKeychainInteraction()
        let result = await Task.detached { Result { try work() } }.value
        await endKeychainInteraction()
        return try result.get()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("隠したフォルダを開く").font(.title2)
            if configured == false { Text("この端末で使う6桁のPINを設定してください。復旧ファイルのパスワードとは別です。") }
            SecureField("PIN（半角数字6桁）", text: $pin)
            if configured == false { SecureField("もう一度", text: $confirmation) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if busy { ProgressView() }
            HStack {
                Button("閉じる") { pin = ""; confirmation = ""; dismiss() }
                Spacer()
                Button(configured == false ? "PINを設定して開く" : "開く") { submit() }
                    .disabled(configured == nil || busy || !HiddenPagePIN.valid(pin) || (configured == false && pin != confirmation))
            }.disabled(busy)
        }.padding(24).frame(maxWidth: 440)
            .task { do { configured = try await keychain { try HiddenPagePIN.configured() } } catch { self.error = error.localizedDescription } }
            .interactiveDismissDisabled(busy)
    }
    private func submit() {
        let entered = pin; let creating = configured == false
        pin = ""; confirmation = ""; busy = true; error = ""
        Task {
            do {
                try await keychain { if creating { try HiddenPagePIN.create(entered) } else { try HiddenPagePIN.verify(entered) } }
                await open(entered); dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
