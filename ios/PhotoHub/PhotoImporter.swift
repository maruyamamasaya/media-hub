import Foundation
import Photos
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import PhotoHubCore

struct ImportedPhoto {
    let photo: Photo
    let directory: URL
}
enum PhotoImporter {
    static func importAsset(id: String, pending: URL, cache: DiskCache) async throws -> ImportedPhoto {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw NSError(domain: "PhotoHub", code: 1, userInfo: [NSLocalizedDescriptionKey: "選択写真の原本へアクセスするため、写真へのアクセスを許可してください。"] ) }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw HubError.unsupported }
        let isVideo = asset.mediaType == .video
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == (isVideo ? .video : .photo) }),
              let type = UTType(resource.uniformTypeIdentifier), (isVideo ? type.conforms(to: .movie) : [UTType.jpeg, .heic, .png].contains(where: { type.conforms(to: $0) })) else { throw HubError.unsupported }
        let photoID = UUID().uuidString.lowercased()
        let directory = pending.appendingPathComponent(photoID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original")
        do {
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: original, options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let result = try await Task.detached(priority: .userInitiated) {
                var previewError: String?
                if isVideo {
                    do { try await videoDerivatives(original: original, directory: directory) }
                    catch { previewError = "閲覧用動画を生成できません。原本は保管されています。" }
                } else { try derivatives(original: original, directory: directory) }
                return try (Digest.checksum(file: original), Digest.bytes(file: original), previewError)
            }.value
            var photo = Photo(id: photoID, assetID: id, filename: resource.originalFilename, capturedAt: asset.creationDate ?? Date(), mime: type.preferredMIMEType ?? (isVideo ? "video/quicktime" : "application/octet-stream"), bytes: result.1, width: asset.pixelWidth, height: asset.pixelHeight, sha256: result.0)
            photo.state = .pending; photo.error = result.2
            for kind in [ImageKind.thumbnail, .display] {
                let destination = cache.file(id: photoID, kind: kind)
                let preview = directory.appendingPathComponent("\(kind.rawValue).jpg")
                if isVideo { if FileManager.default.fileExists(atPath: preview.path) { try? FileManager.default.copyItem(at: preview, to: destination) } }
                else { try FileManager.default.copyItem(at: preview, to: destination) }
            }
            if isVideo { try? cache.trim() } else { try cache.trim() }
            return ImportedPhoto(photo: photo, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func videoDerivatives(original: URL, directory: URL) async throws {
        let asset = AVURLAsset(url: original)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let frame = try await generator.image(at: .zero).image
        for name in ["thumbnail", "display"] {
            guard let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(name).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw HubError.unsupported }
            CGImageDestinationAddImage(output, frame, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw HubError.integrity }
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720), exporter.supportedFileTypes.contains(.mp4) else { throw HubError.unsupported }
        let playback = directory.appendingPathComponent("playback.mp4")
        let temporary = directory.appendingPathComponent("playback-export.mp4")
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        exporter.outputURL = temporary; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                if exporter.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: exporter.error ?? HubError.unsupported) }
            }
        }
        if FileManager.default.fileExists(atPath: playback.path) { _ = try FileManager.default.replaceItemAt(playback, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: playback) }
    }
    static func derivatives(original: URL, directory: URL) throws {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else { throw HubError.unsupported }
        for (name, size, quality) in [("thumbnail", 512, 0.75), ("display", 2048, 0.85)] {
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
                  let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("\(name).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw HubError.unsupported }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw HubError.integrity }
        }
    }
}
