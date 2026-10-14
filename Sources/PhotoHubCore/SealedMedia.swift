import Foundation
import CryptoKit
import CommonCrypto
import Security
import AssetLibraryContract

public enum SealedError: LocalizedError {
    case invalid, wrongKey, password, keychain(OSStatus), tooLarge
    public var errorDescription: String? {
        switch self {
        case .password: return "復旧ファイルのパスワードは12文字以上にしてください。"
        case .keychain: return "暗号化の鍵をKeychainで確認できません。"
        case .tooLarge: return "暗号化データが対応上限を超えています。"
        default: return "鍵・パスワード・暗号化データを確認してください。"
        }
    }
}
public struct MediaSecret: Codable, Sendable {
    public let keyID: String
    public let masterKey: Data
    public init(keyID: String = UUID().uuidString.lowercased(), masterKey: Data? = nil) throws {
        let bytes = try masterKey ?? Self.random(32)
        guard UUID(uuidString: keyID) != nil, bytes.count == 32 else { throw SealedError.invalid }
        self.keyID = keyID.lowercased(); self.masterKey = bytes
    }
    public static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw SealedError.invalid }
        return Data(bytes)
    }
}
public enum MediaSecretStore {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "personal.mediahub.sealed-media.v1", kSecAttrAccount as String: "library", kSecAttrSynchronizable as String: false] }
    public static func load() throws -> MediaSecret? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new } as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SealedError.keychain(status) }
        let decoded = try JSONDecoder().decode(MediaSecret.self, from: data)
        return try MediaSecret(keyID: decoded.keyID, masterKey: decoded.masterKey)
    }
    public static func save(_ secret: MediaSecret) throws {
        if let previous = try load() {
            guard previous.keyID == secret.keyID, previous.masterKey == secret.masterKey else { throw SealedError.wrongKey }
            return
        }
        let values = query.merging([kSecValueData as String: try JSONEncoder().encode(secret), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { _, new in new }
        let status = SecItemAdd(values as CFDictionary, nil)
        guard status == errSecSuccess else { throw SealedError.keychain(status) }
    }
}
public enum RecoveryFile {
    private struct Envelope: Codable { let version: Int; let rounds: Int; let salt: Data; let sealed: Data }
    private static func passwordKey(_ password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        guard salt.count == 16, rounds == 600_000, password.utf8.count <= 1024 else { throw SealedError.invalid }
        var result = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { text in
            salt.withUnsafeBytes { bytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), text, password.utf8.count,
                    bytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &result, result.count)
            }
        }
        guard status == kCCSuccess else { throw SealedError.invalid }
        return SymmetricKey(data: result)
    }
    public static func export(_ secret: MediaSecret, password: String) throws -> Data {
        guard password.count >= 12 else { throw SealedError.password }
        let salt = try MediaSecret.random(16)
        let key = try passwordKey(password, salt: salt, rounds: 600_000)
        let box = try AES.GCM.seal(JSONEncoder().encode(secret), using: key, authenticating: Data("media-hub/recovery/v1".utf8))
        guard let combined = box.combined else { throw SealedError.invalid }
        return try JSONEncoder().encode(Envelope(version: 1, rounds: 600_000, salt: salt, sealed: combined))
    }
    public static func restore(_ data: Data, password: String) throws -> MediaSecret {
        guard data.count <= 65_536 else { throw SealedError.tooLarge }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw SealedError.invalid }
        let key = try passwordKey(password, salt: envelope.salt, rounds: envelope.rounds)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: Data("media-hub/recovery/v1".utf8))
        let secret = try JSONDecoder().decode(MediaSecret.self, from: plain)
        return try MediaSecret(keyID: secret.keyID, masterKey: secret.masterKey)
    }
}
public enum SealedMedia {
    public static let headerSize = 60
    public static let chunkSize = 1_048_576
    public struct Header: Sendable {
        public let data: Data
        public let objectID: String
        public let length: Int64
        fileprivate let salt: Data
        fileprivate let prefix: Data
        public var encryptedLength: Int64 { Int64(headerSize) + length + ((length + Int64(chunkSize) - 1) / Int64(chunkSize)) * 16 }
    }
    private static func integer(_ value: UInt64, width: Int) -> Data { Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func number(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func uuidBytes(_ value: String) throws -> Data {
        guard let value = UUID(uuidString: value) else { throw SealedError.invalid }
        var raw = value.uuid
        return withUnsafeBytes(of: &raw) { Data($0) }
    }
    public static func header(length: Int64, objectID: String) throws -> Header {
        guard length > 0, length <= 5 * 1024 * 1024 * 1024 else { throw SealedError.tooLarge }
        let bytes = try Data("MHSEAL01".utf8) + uuidBytes(objectID) + MediaSecret.random(16) + MediaSecret.random(8) + integer(UInt64(chunkSize), width: 4) + integer(UInt64(length), width: 8)
        return try parse(bytes, objectID: objectID, length: length)
    }
    public static func parse(_ data: Data, objectID: String, length: Int64) throws -> Header {
        guard data.count == headerSize, data.prefix(8) == Data("MHSEAL01".utf8),
              data.subdata(in: 8..<24) == (try uuidBytes(objectID)),
              number(data.subdata(in: 48..<52)) == UInt64(chunkSize), length > 0,
              length <= 5 * 1024 * 1024 * 1024, number(data.subdata(in: 52..<60)) == UInt64(length) else { throw SealedError.invalid }
        return Header(data: data, objectID: objectID.lowercased(), length: length, salt: data.subdata(in: 24..<40), prefix: data.subdata(in: 40..<48))
    }
    private static func derived(_ header: Header, master: Data) throws -> SymmetricKey {
        guard master.count == 32 else { throw SealedError.wrongKey }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: master), salt: header.salt,
            info: Data("media-hub/chunk/v1/\(header.objectID)".utf8), outputByteCount: 32)
    }
    public static func chunkRange(_ index: Int, header: Header) throws -> Range<Int64> {
        guard index >= 0, index < Int((header.length + Int64(chunkSize) - 1) / Int64(chunkSize)) else { throw SealedError.invalid }
        let start = Int64(index) * Int64(chunkSize)
        guard index >= 0, start < header.length else { throw SealedError.invalid }
        let cipherStart = Int64(headerSize) + Int64(index) * Int64(chunkSize + 16)
        return cipherStart..<(cipherStart + min(Int64(chunkSize), header.length - start) + 16)
    }
    public static func sealChunk(_ data: Data, index: Int, header: Header, master: Data) throws -> Data {
        let range = try chunkRange(index, header: header)
        guard data.count == Int(range.count) - 16 else { throw SealedError.invalid }
        let nonce = try AES.GCM.Nonce(data: header.prefix + integer(UInt64(index), width: 4))
        let box = try AES.GCM.seal(data, using: derived(header, master: master), nonce: nonce, authenticating: header.data + integer(UInt64(index), width: 4))
        return box.ciphertext + box.tag
    }
    public static func openChunk(_ data: Data, index: Int, header: Header, master: Data) throws -> Data {
        let range = try chunkRange(index, header: header)
        guard data.count == Int(range.count) else { throw SealedError.invalid }
        let nonce = try AES.GCM.Nonce(data: header.prefix + integer(UInt64(index), width: 4))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try AES.GCM.open(box, using: derived(header, master: master), authenticating: header.data + integer(UInt64(index), width: 4))
    }
    public static func encryptFile(_ input: URL, output: URL, objectID: String, master: Data) throws -> Int64 {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let length = Int64(try reader.seekToEnd()); try reader.seek(toOffset: 0)
        let header = try self.header(length: length, objectID: objectID)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SealedError.invalid }
        let writer = try FileHandle(forWritingTo: output); defer { try? writer.close() }
        do {
            try writer.write(contentsOf: header.data)
            var index = 0, total: Int64 = 0
            while let bytes = try reader.read(upToCount: chunkSize), !bytes.isEmpty {
                try writer.write(contentsOf: sealChunk(bytes, index: index, header: header, master: master))
                index += 1; total += Int64(bytes.count)
            }
            guard total == length else { throw SealedError.invalid }
            try writer.synchronize()
            return header.encryptedLength
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}

extension SealedRoot: Identifiable {}
extension SealedFolder: Identifiable {}
extension SealedItem: Identifiable {}
public extension SealedCatalog {
    func validate(root: SealedRoot, secret: MediaSecret) throws {
        guard schemaVersion == 1, id == root.id, keyID == root.keyID, keyID == secret.keyID,
              UUID(uuidString: id) != nil, !folders.isEmpty, folders.count <= 10000, items.count <= 10000,
              Set(folders.map(\.id)).count == folders.count, Set(items.map(\.id)).count == items.count else { throw SealedError.invalid }
        let ids = Set(folders.map(\.id))
        guard folders.filter({ $0.parentId == nil }).count == 1 else { throw SealedError.invalid }
        let parents = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.parentId) })
        for folder in folders {
            guard UUID(uuidString: folder.id) != nil else { throw SealedError.invalid }
            var visited = Set<String>(), node: String? = folder.id
            while let value = node {
                guard ids.contains(value), visited.insert(value).inserted else { throw SealedError.invalid }
                node = parents[value] ?? nil
            }
        }
        for item in items {
            guard UUID(uuidString: item.id) != nil, UUID(uuidString: item.objectID) != nil, ids.contains(item.folderId),
                  item.byteSize > 0, item.byteSize <= 5 * 1024 * 1024 * 1024,
                  item.sha256.utf8.count == 64, item.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  item.thumbnailID == nil || (UUID(uuidString: item.thumbnailID!) != nil && (item.thumbnailBytes ?? 0) > 0 && (item.thumbnailBytes ?? 0) <= 50000) else { throw SealedError.invalid }
        }
    }
}
