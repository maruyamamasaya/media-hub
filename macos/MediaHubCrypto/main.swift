import Foundation
import PhotoHubCore
import CryptoKit
struct Request: Decodable { let source: String; let output: String; let objectID: String; let masterKey: String }
do {
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
