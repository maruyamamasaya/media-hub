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
    #if os(iOS)
    @FocusState private var focusedField: PINField?
    private enum PINField: Hashable { case pin, confirmation }
    #endif
    private let title: String
    private let allowsSetup: Bool
    private let open: @MainActor (String) async -> Void
    private let beginKeychainInteraction: @MainActor () -> Void
    private let endKeychainInteraction: @MainActor () async -> Void
    public init(title: String = "隠したフォルダを開く", allowsSetup: Bool = true, beginKeychainInteraction: @escaping @MainActor () -> Void = {}, endKeychainInteraction: @escaping @MainActor () async -> Void = {}, open: @escaping @MainActor (String) async -> Void) {
        self.title = title
        self.allowsSetup = allowsSetup
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
        #if os(iOS)
        phoneContent
            .task { await loadConfiguration() }
            .interactiveDismissDisabled(busy)
        #else
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
        #endif
    }

    #if os(iOS)
    private var phoneContent: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.tint)
                            .frame(width: 76, height: 76)
                            .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
                            .accessibilityHidden(true)
                        Text(configured == false ? "PINを設定" : title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(configured == false
                             ? "この端末で使う6桁のPINを設定してください。\n復旧ファイルのパスワードとは別です。"
                             : "6桁のPINを入力してください。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        pinInput("PIN", text: $pin, field: .pin)
                        if configured == false {
                            Divider()
                            pinInput("PINを確認", text: $confirmation, field: .confirmation)
                        }
                    }
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    .disabled(configured == nil || busy)

                    if !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Button(action: submit) {
                        HStack(spacing: 10) {
                            if busy { ProgressView().tint(.white) }
                            else { Image(systemName: "lock.open.fill") }
                            Text(busy ? "確認中…" : configured == false ? "PINを設定して開く" : "開く")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .disabled(configured == nil || busy || !HiddenPagePIN.valid(pin) || (configured == false && pin != confirmation))
                    if configured == nil && error.isEmpty { ProgressView("準備中…") }
                }
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { pin = ""; confirmation = ""; dismiss() }
                        .disabled(busy)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { focusedField = nil }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func pinInput(_ title: String, text: Binding<String>, field: PINField) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            SecureField("6桁の数字", text: text)
                .font(.title2.monospacedDigit())
                .keyboardType(.numberPad)
                .textContentType(.none)
                .focused($focusedField, equals: field)
                .accessibilityLabel(title)
                .accessibilityHint("半角数字6桁")
                .onChange(of: text.wrappedValue) { _, value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if value != digits { text.wrappedValue = digits }
                    if field == .pin && digits.count == 6 && configured == false { focusedField = .confirmation }
                }
        }
    }

    private func loadConfiguration() async {
        do {
            let exists = try await keychain { try HiddenPagePIN.configured() }
            guard exists || allowsSetup else { throw HiddenPINError.invalid }
            configured = exists
            focusedField = .pin
        } catch { self.error = error.localizedDescription }
    }
    #endif

    private func submit() {
        #if os(iOS)
        focusedField = nil
        #endif
        guard configured != nil, !busy, HiddenPagePIN.valid(pin),
              configured != false || (allowsSetup && pin == confirmation) else { return }
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
