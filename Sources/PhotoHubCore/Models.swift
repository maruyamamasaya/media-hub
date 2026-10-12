import Foundation

public enum UploadState: String, Codable, Sendable { case pending, uploading, uploaded, failed, deleting }
public enum ImageKind: String, CaseIterable, Codable, Sendable { case original, thumbnail, display }
public struct FolderSource: Codable, Equatable, Sendable {
    public var rootID: String
    public var relativePath: String
    public init(rootID: String, relativePath: String) { self.rootID = rootID; self.relativePath = relativePath }
}
public struct Photo: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var assetID: String
    public var filename: String
    public var capturedAt: Date
    public var importedAt: Date
    public var mime: String
    public var bytes: Int64
    public var width: Int
    public var height: Int
    public var sha256: String
    public var state: UploadState
    public var favorite: Bool
    public var error: String?
    public var keys: [String: String]
    public var folderSource: FolderSource?
    public init(id: String = UUID().uuidString.lowercased(), assetID: String, filename: String, capturedAt: Date, mime: String, bytes: Int64, width: Int, height: Int, sha256: String) {
        self.id = id; self.assetID = assetID; self.filename = filename; self.capturedAt = capturedAt
        self.importedAt = Date(); self.mime = mime; self.bytes = bytes; self.width = width; self.height = height
        self.sha256 = sha256; self.state = .pending; self.favorite = false; self.keys = [:]
    }
}
public struct Album: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String = UUID().uuidString.lowercased(), name: String) { self.id = id; self.name = name }
}
public struct Membership: Codable, Equatable, Sendable {
    public var albumID: String
    public var photoID: String
    public init(albumID: String, photoID: String) { self.albumID = albumID; self.photoID = photoID }
}
public struct Backup: Codable, Sendable {
    public var schemaVersion = 1
    public var createdAt = Date()
    public var owner: String
    public var photos: [Photo]
    public var albums: [Album]
    public var memberships: [Membership]
    public init(owner: String, photos: [Photo], albums: [Album], memberships: [Membership]) { self.owner = owner; self.photos = photos; self.albums = albums; self.memberships = memberships }
    public func validate(owner expected: String) throws {
        guard schemaVersion == 1, owner == expected else { throw HubError.invalidBackup }
        let ids = Set(photos.map(\.id)), albumIDs = Set(albums.map(\.id))
        guard ids.count == photos.count, albumIDs.count == albums.count, albums.allSatisfy({ UUID(uuidString: $0.id)?.uuidString.lowercased() == $0.id && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw HubError.invalidBackup }
        for photo in photos {
            guard UUID(uuidString: photo.id)?.uuidString.lowercased() == photo.id, photo.state == .uploaded, photo.folderSource == nil else { throw HubError.invalidBackup }
            for kind in ImageKind.allCases {
                guard photo.keys[kind.rawValue] == ObjectKeys.photo(owner: owner, id: photo.id, kind: kind) else { throw HubError.invalidBackup }
            }
        }
        guard memberships.allSatisfy({ ids.contains($0.photoID) && albumIDs.contains($0.albumID) }), Set(memberships.map { "\($0.albumID)/\($0.photoID)" }).count == memberships.count else { throw HubError.invalidBackup }
    }
}
public enum HubError: LocalizedError {
    case database(String), invalidBackup, notEmpty, configuration, missingOriginal, unsupported, integrity
    public var errorDescription: String? {
        switch self {
        case .database(let value): return "SQLite: \(value)"
        case .invalidBackup: return "バックアップのバージョン・所有者・写真情報が不正です。"
        case .notEmpty: return "復元は空のライブラリでのみ実行できます。"
        case .configuration: return "クラウド設定と本人ログインが必要です。"
        case .missingOriginal: return "原本がありません。再取り込みするか通信状態を確認してください。"
        case .unsupported: return "JPEG・HEIC・PNGの静止画のみ対応しています。"
        case .integrity: return "保存データのサイズまたはチェックサムが一致しません。"
        }
    }
}
public enum ObjectKeys {
    public static func photo(owner: String, id: String, kind: ImageKind) -> String {
        "users/\(owner)/photos/\(id)/" + (kind == .original ? "original" : "\(kind.rawValue).jpg")
    }
}
