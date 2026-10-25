import Foundation

/// Errors thrown while building or running an embedding.
public enum TSNEError: Error, CustomStringConvertible, Sendable {
    case noMetalDevice
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case bufferAllocationFailed
    case metalExecutionFailed(String)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal device is available on this system."
        case .shaderCompilationFailed(let msg):
            return "Metal shader compilation failed: \(msg)"
        case .pipelineCreationFailed(let name):
            return "Failed to create compute pipeline for '\(name)'."
        case .bufferAllocationFailed:
            return "Failed to allocate a Metal buffer."
        case .metalExecutionFailed(let msg):
            return "Metal command execution failed: \(msg)"
        case .invalidInput(let msg):
            return "Invalid input: \(msg)"
        }
    }
}
