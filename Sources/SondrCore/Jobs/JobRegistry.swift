import Foundation

public enum JobKind: String, Sendable, CaseIterable {
    case scan, index, retag
}

public enum JobError: Error, Equatable, LocalizedError {
    case alreadyRunning(JobKind)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning(let kind): return "A \(kind.rawValue) job is already running."
        }
    }
}

/// Lets at most one job of each kind run per database (legacy had no lock between jobs).
public final class JobRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Set<JobKind> = []

    public init() {}

    /// Marks `kind` as running. Call ``end(_:)`` when the job is over.
    /// - Throws: ``JobError/alreadyRunning(_:)``
    public func begin(_ kind: JobKind) throws {
        lock.lock()
        defer { lock.unlock() }
        guard running.insert(kind).inserted else { throw JobError.alreadyRunning(kind) }
    }

    public func end(_ kind: JobKind) {
        lock.lock()
        running.remove(kind)
        lock.unlock()
    }

    public func isRunning(_ kind: JobKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.contains(kind)
    }
}
