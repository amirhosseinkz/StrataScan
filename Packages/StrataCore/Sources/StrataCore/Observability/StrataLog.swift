import OSLog

public enum StrataLogCategory: String, CaseIterable, Sendable {
    case scanner
    case processing
    case storage
    case networking
    case sync
    case navigation
    case userInterface
}

/// A narrow logging boundary. Callers log state transitions and aggregate counts,
/// never RGB frames, depth maps, mesh coordinates, location values, or tokens.
public struct StrataLog: Sendable {
    private let logger: Logger

    public init(category: StrataLogCategory, subsystem: String = "com.stratascan.app") {
        logger = Logger(subsystem: subsystem, category: category.rawValue)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

@available(iOS 15.0, macOS 12.0, *)
public struct SpatialPerformanceSignposter: Sendable {
    private let signposter: OSSignposter

    public init(subsystem: String = "com.stratascan.app", category: String = "processing") {
        signposter = OSSignposter(subsystem: subsystem, category: category)
    }

    public func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    public func end(_ name: StaticString, state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
