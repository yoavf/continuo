import Foundation

public enum AgentSyncError: Error, CustomStringConvertible {
    case encodingFailed(String)
    case unsafeWrite(String)
    case commandFailed(String)
    case invalidArguments(String)

    public var description: String {
        switch self {
        case .encodingFailed(let message):
            return message
        case .unsafeWrite(let message):
            return message
        case .commandFailed(let message):
            return message
        case .invalidArguments(let message):
            return message
        }
    }
}
