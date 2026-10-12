import Foundation
import ImageIO
import UniformTypeIdentifiers
import PhotoHubCore

struct LibraryFolder: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var bookmark: Data

    static func selected(_ url: URL, id: String = UUID().uuidString.lowercased()) throws -> LibraryFolder {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try LibraryFolder(id: id, name: url.lastPathComponent,
                                 bookmark: url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    func resolve() throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

struct FolderScan: Sendable {
    var photos: [Photo] = []
    var seenPaths: Set<String> = []
    var waiting = 0
    var failures = 0
    var complete = true
}

enum FolderSync {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
    static func error(_ message: String) -> NSError {
        NSError(domain: "PhotoHub.Folder", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // Keep synchronous file-provider work and image inspection off the main actor.
    static func scan(_ folder: LibraryFolder) throws -> FolderScan {
        let root = try folder.resolve(), manager = FileManager.default
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw error("フォルダが見つかりません。設定から同じ登録先のフォルダを選び直してください。")
        }
        var result = FolderScan()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
            result.failures += 1; result.complete = false; return true
        }) else { throw error("フォルダを読み込めません。アクセス権と通信を確認してください。") }
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result.seenPaths.insert(relative)
            do {
                guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                    throw error("登録フォルダの外を指すファイルは読み込めません。")
                }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try manager.startDownloadingUbiquitousItem(at: url)
                    result.waiting += 1
                    continue
                }
                let photo = try coordinated(url) { readable in
                    guard let source = CGImageSourceCreateWithURL(readable as CFURL, nil),
                          let typeID = CGImageSourceGetType(source), let type = UTType(typeID as String),
                          [UTType.jpeg, .png, .heic].contains(where: { type.conforms(to: $0) }),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw HubError.unsupported }
                    let date = (try readable.resourceValues(forKeys: [.creationDateKey])).creationDate ?? Date()
                    var photo = try Photo(assetID: "folder:\(folder.id):\(UUID().uuidString.lowercased())",
                                          filename: url.lastPathComponent, capturedAt: date,
                                          mime: type.preferredMIMEType ?? "image/jpeg", bytes: Digest.bytes(file: readable),
                                          width: width, height: height, sha256: Digest.checksum(file: readable))
                    photo.folderSource = FolderSource(rootID: folder.id, relativePath: relative)
                    // Referenced originals are already stored by the chosen file provider.
                    photo.state = .uploaded
                    return photo
                }
                result.photos.append(photo)
            } catch { result.failures += 1 }
        }
        return result
    }

    static func coordinated<T>(_ url: URL, read: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try read(readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw HubError.missingOriginal }
        return try result.get()
    }

    static func read<T>(_ photo: Photo, folder: LibraryFolder, operation: (URL) throws -> T) throws -> T {
        guard let source = photo.folderSource, source.rootID == folder.id,
              !source.relativePath.hasPrefix("/"),
              !source.relativePath.split(separator: "/").contains("..") else { throw HubError.missingOriginal }
        let root = try folder.resolve()
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let url = root.appendingPathComponent(source.relativePath)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw HubError.missingOriginal }
        return try coordinated(url) { readable in
            guard try Digest.checksum(file: readable) == photo.sha256 else {
                throw error("原本の内容が変更されています。以前の画像と整理情報は保持しています。")
            }
            return try operation(readable)
        }
    }

    static func preview(_ photo: Photo, folder: LibraryFolder, kind: ImageKind, destination: URL) throws {
        guard kind != .original else { throw HubError.unsupported }
        try read(photo, folder: folder) { original in
            guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: kind == .thumbnail ? 512 : 2048
                  ] as CFDictionary) else { throw HubError.unsupported }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".preview-" + UUID().uuidString + ".jpg")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw HubError.integrity }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw HubError.integrity }
            // Atomic replacement avoids partial previews when a scan and view overlap.
            try Data(contentsOf: temporary).write(to: destination, options: .atomic)
        }
    }
}
