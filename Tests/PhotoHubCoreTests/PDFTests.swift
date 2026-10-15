import XCTest
import CryptoKit
import PDFKit
import AppKit
import SwiftUI
@testable import PhotoHubCore

final class PDFTests: XCTestCase {
    func test164MiBDecryptsWithPDFLimitButKeepsDefaultImageLimit() async throws {
        let size = 164 * 1024 * 1024 + 31
        let key = Data(repeating: 0x23, count: 32), id = UUID().uuidString
        let header = try SealedMedia.header(length: Int64(size), objectID: id)
        let chunk = Data(repeating: 0x5a, count: SealedMedia.chunkSize)
        let reader = SealedRangeReader(objectID: id, master: key, expectedLength: Int64(size), maximumLength: PDFLimits.maximumBytes) { range in
            if range.lowerBound == 0 { return header.data }
            let index = Int((range.lowerBound - Int64(SealedMedia.headerSize)) / Int64(SealedMedia.chunkSize + 16))
            let count = min(SealedMedia.chunkSize, size - index * SealedMedia.chunkSize)
            return try SealedMedia.sealChunk(Data(chunk.prefix(count)), index: index, header: header, master: key)
        }
        do { _ = try await reader.allData(); XCTFail("Default image limit must stay at 100MiB") }
        catch SealedError.tooLarge { }
        let bytes = try await reader.allData(maximumBytes: PDFLimits.maximumBytes)
        XCTAssertEqual(bytes.count, size)
        var expected = SHA256()
        for start in stride(from: 0, to: size, by: SealedMedia.chunkSize) {
            expected.update(data: chunk.prefix(min(SealedMedia.chunkSize, size - start)))
        }
        XCTAssertEqual(Data(SHA256.hash(data: bytes)), Data(expected.finalize()))
        await reader.close()
    }

    func testPDFAbove250MiBIsRejectedBeforeDownloadingChunks() async throws {
        let size = PDFLimits.maximumBytes + 1
        let id = UUID().uuidString, key = Data(repeating: 0x24, count: 32)
        let header = try SealedMedia.header(length: size, objectID: id)
        let reader = SealedRangeReader(objectID: id, master: key, expectedLength: size, maximumLength: PDFLimits.maximumBytes) { range in
            XCTAssertEqual(range, 0..<Int64(SealedMedia.headerSize))
            return header.data
        }
        do { _ = try await reader.allData(maximumBytes: PDFLimits.maximumBytes); XCTFail("PDF above limit must be rejected") }
        catch { }
        await reader.close()
    }

    @MainActor
    func testMultipagePDFDecryptsAndPasswordProtectionSurvives() async throws {
        let original = PDFDocument()
        for _ in 0..<2 {
            let image = NSImage(size: NSSize(width: 300, height: 400), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                ("PDF test page" as NSString).draw(at: NSPoint(x: 20, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
                return true
            }
            original.insert(try XCTUnwrap(PDFPage(image: image)), at: original.pageCount)
        }
        for protected in [false, true] {
            let options: [PDFDocumentWriteOption: Any] = protected ? [.userPasswordOption: "test-only", .ownerPasswordOption: "test-owner"] : [:]
            let plain = try XCTUnwrap(original.dataRepresentation(options: options))
            let id = UUID().uuidString, key = Data(repeating: 0x42, count: 32)
            let header = try SealedMedia.header(length: Int64(plain.count), objectID: id)
            var cipher = header.data
            for start in stride(from: 0, to: plain.count, by: SealedMedia.chunkSize) {
                cipher.append(try SealedMedia.sealChunk(plain.subdata(in: start..<min(start + SealedMedia.chunkSize, plain.count)), index: start / SealedMedia.chunkSize, header: header, master: key))
            }
            let encrypted = cipher
            let reader = SealedRangeReader(objectID: id, master: key, expectedLength: Int64(plain.count)) { range in encrypted.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
            let data = try await reader.allData()
            XCTAssertEqual(data, plain)
            let document = try XCTUnwrap(PDFDocument(data: data))
            if protected {
                XCTAssertTrue(document.isLocked); XCTAssertFalse(document.unlock(withPassword: "wrong"))
                XCTAssertTrue(document.unlock(withPassword: "test-only"))
            }
            XCTAssertEqual(document.pageCount, 2)
            if !protected {
                let host = NSHostingView(rootView: MediaPDFReader(data: data))
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
                host.layoutSubtreeIfNeeded()
                func findPDF(_ view: NSView) -> PDFView? {
                    if let pdf = view as? PDFView { return pdf }
                    return view.subviews.compactMap { findPDF($0) }.first
                }
                let view = try XCTUnwrap(findPDF(host))
                XCTAssertEqual(view.document?.pageCount, 2)
                XCTAssertEqual(view.displayMode, .singlePageContinuous)
                XCTAssertTrue(view.autoScales)
                view.go(to: try XCTUnwrap(view.document?.page(at: 1)))
                XCTAssertEqual(view.currentPage, view.document?.page(at: 1))
            }
            XCTAssertNotNil(document.page(at: 1)?.thumbnail(of: NSSize(width: 100, height: 100), for: .mediaBox).tiffRepresentation)
            await reader.close()
        }
    }
}
