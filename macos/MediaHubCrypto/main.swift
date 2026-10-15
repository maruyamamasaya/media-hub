import Foundation
import PhotoHubCore
import AssetLibraryContract
import CryptoKit
import PDFKit
import AppKit
struct Request: Decodable { let source: String; let output: String?; let operation: String?; let keyID: String?; let objectID: String; let masterKey: String }
do {
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--pdf-thumbnail" {
        guard let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])),
              !document.isLocked, let page = document.page(at: 0),
              let tiff = page.thumbnail(of: NSSize(width: 320, height: 320), for: .mediaBox).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw SealedError.invalid }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        exit(0)
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 65536 else { throw SealedError.invalid }
    let request = try JSONDecoder().decode(Request.self, from: data)
    guard let key = Data(base64Encoded: request.masterKey), key.count == 32 else { throw SealedError.wrongKey }
    if request.operation == "catalog" {
        let url = URL(fileURLWithPath: request.source)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 4 * 1024 * 1024 + 124 else { throw SealedError.tooLarge }
        let cipher = try Data(contentsOf: url)
        guard cipher.count >= SealedMedia.headerSize else { throw SealedError.invalid }
        let length = cipher.subdata(in: 52..<60).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length > 0, length <= 4 * 1024 * 1024 else { throw SealedError.tooLarge }
        let header = try SealedMedia.parse(Data(cipher.prefix(SealedMedia.headerSize)), objectID: request.objectID, length: Int64(length))
        guard cipher.count == header.encryptedLength, let keyID = request.keyID else { throw SealedError.invalid }
        var plain = Data()
        for index in 0..<Int((Int64(length) + Int64(SealedMedia.chunkSize) - 1) / Int64(SealedMedia.chunkSize)) {
            let range = try SealedMedia.chunkRange(index, header: header)
            plain.append(try SealedMedia.openChunk(cipher.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)), index: index, header: header, master: key))
        }
        let secret = try MediaSecret(keyID: keyID, masterKey: key)
        let catalog = try JSONDecoder().decode(SealedCatalog.self, from: plain)
        let rootData = try JSONSerialization.data(withJSONObject: ["id": request.objectID, "keyID": keyID, "cipherBytes": cipher.count])
        let root = try JSONDecoder().decode(SealedRoot.self, from: rootData)
        try catalog.validate(root: root, secret: secret)
        FileHandle.standardOutput.write(plain)
        exit(0)
    }
    guard request.operation == nil, let outputPath = request.output else { throw SealedError.invalid }
    let bytes = try SealedMedia.encryptFile(URL(fileURLWithPath: request.source), output: URL(fileURLWithPath: outputPath), objectID: request.objectID, master: key)
    let output = try FileHandle(forReadingFrom: URL(fileURLWithPath: outputPath)); defer { try? output.close() }
    var digest = SHA256()
    while let bytes = try output.read(upToCount: 1048576), !bytes.isEmpty { digest.update(data: bytes) }
    let hash = Data(digest.finalize()).base64EncodedString()
    let result = try JSONSerialization.data(withJSONObject: ["byteSize": bytes, "checksum": hash])
    FileHandle.standardOutput.write(result)
} catch {
    FileHandle.standardError.write(Data("暗号化処理に失敗しました。\n".utf8))
    exit(1)
}
