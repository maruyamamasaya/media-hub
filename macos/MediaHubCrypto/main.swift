import Foundation
import PhotoHubCore
import CryptoKit
import PDFKit
import AppKit
struct Request: Decodable { let source: String; let output: String; let objectID: String; let masterKey: String }
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
    let bytes = try SealedMedia.encryptFile(URL(fileURLWithPath: request.source), output: URL(fileURLWithPath: request.output), objectID: request.objectID, master: key)
    let output = try FileHandle(forReadingFrom: URL(fileURLWithPath: request.output)); defer { try? output.close() }
    var digest = SHA256()
    while let bytes = try output.read(upToCount: 1048576), !bytes.isEmpty { digest.update(data: bytes) }
    let hash = Data(digest.finalize()).base64EncodedString()
    let result = try JSONSerialization.data(withJSONObject: ["byteSize": bytes, "checksum": hash])
    FileHandle.standardOutput.write(result)
} catch {
    FileHandle.standardError.write(Data("暗号化処理に失敗しました。\n".utf8))
    exit(1)
}
