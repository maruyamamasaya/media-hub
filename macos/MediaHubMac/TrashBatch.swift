import Foundation

/// Only the confirmed snapshot is processed; authorization is checked before each mutation.
@MainActor
enum TrashBatch {
    static func execute<Entry>(_ entries: [Entry], authorized: () -> Bool,
                               operation: (Entry) async throws -> Void) async throws {
        for entry in entries {
            try Task.checkCancellation()
            guard authorized() else { throw CancellationError() }
            try await operation(entry)
        }
    }
}
