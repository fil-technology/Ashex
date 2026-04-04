import Foundation

public actor CancellationToken {
    private var cancelled = false

    public init() {}

    public func cancel() {
        cancelled = true
    }

    public func checkCancellation() throws {
        if cancelled {
            throw AshexError.cancelled
        }
    }
}
