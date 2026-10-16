import Foundation

/// Prepare only one folder ahead, without delaying the first transfer.
@MainActor
final class UploadBatch {
    private(set) var activeID: String?
    var stopped = false

    func check() throws {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
    }

    func execute(_ paths: [String], prepare: (String) async throws -> String,
                 start: (String) async throws -> Void,
                 wait: (String) async throws -> Void) async throws {
        for path in paths {
            try check()
            let next = try await prepare(path)
            try check()
            if let activeID { try await wait(activeID) }
            try check()
            // Set before awaiting so Stop can also cover an in-flight start request.
            activeID = next
            try await start(next)
            try check()
        }
    }
}
