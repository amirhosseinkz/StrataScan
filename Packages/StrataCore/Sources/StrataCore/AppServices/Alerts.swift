import Foundation

public enum AlertPresentation: String, Codable, CaseIterable, Sendable {
    case inlineError
    case transientBanner
    case modalConfirmation
    case persistentNotification
    case systemPushNotification
}

public enum AlertSource: String, Codable, CaseIterable, Sendable {
    case storage
    case processing
    case sync
    case capability
    case authentication
}

public enum AlertSeverity: String, Codable, CaseIterable, Sendable {
    case information
    case warning
    case error
}

public enum AlertActionRole: String, Codable, CaseIterable, Sendable {
    case normal
    case cancel
    case destructive
}

public enum AlertActionIntent: String, Codable, CaseIterable, Sendable {
    case dismiss
    case retrySync
    case resolveSyncConflict
    case signIn
    case openSettings
}

public struct AlertAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var role: AlertActionRole
    public var intent: AlertActionIntent
    public var targetID: UUID?

    public init(
        id: String,
        title: String,
        role: AlertActionRole = .normal,
        intent: AlertActionIntent,
        targetID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.intent = intent
        self.targetID = targetID
    }
}

/// UI-independent alert value. Feature services can emit these values while a
/// SwiftUI boundary decides how to present the requested presentation style.
public struct AppAlert: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var source: AlertSource
    public var presentation: AlertPresentation
    public var severity: AlertSeverity
    public var title: String
    public var message: String
    public var actions: [AlertAction]
    public var deduplicationKey: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        source: AlertSource,
        presentation: AlertPresentation,
        severity: AlertSeverity,
        title: String,
        message: String,
        actions: [AlertAction] = [],
        deduplicationKey: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.source = source
        self.presentation = presentation
        self.severity = severity
        self.title = title
        self.message = message
        self.actions = actions
        self.deduplicationKey = deduplicationKey
        self.createdAt = createdAt
    }
}

public enum AlertCatalog {
    public static func sync(for item: SyncQueueItem) -> AppAlert? {
        let key = "sync.\(item.id.uuidString)"
        switch item.state {
        case .retryScheduled:
            return AppAlert(
                source: .sync,
                presentation: .transientBanner,
                severity: .warning,
                title: "Upload delayed",
                message: "The scan will retry automatically when connectivity returns.",
                actions: [dismissAction()],
                deduplicationKey: key,
                createdAt: item.updatedAt
            )
        case .failed:
            return AppAlert(
                source: .sync,
                presentation: .persistentNotification,
                severity: .error,
                title: "Upload failed",
                message: "The scan remains safely available on this device.",
                actions: [
                    AlertAction(id: "retry-\(item.id.uuidString)", title: "Retry", intent: .retrySync, targetID: item.id),
                    dismissAction()
                ],
                deduplicationKey: key,
                createdAt: item.updatedAt
            )
        case .conflict:
            return AppAlert(
                source: .sync,
                presentation: .modalConfirmation,
                severity: .warning,
                title: "Sync conflict",
                message: "A newer remote version needs review before this scan can upload.",
                actions: [
                    AlertAction(id: "resolve-\(item.id.uuidString)", title: "Review", intent: .resolveSyncConflict, targetID: item.id),
                    dismissAction()
                ],
                deduplicationKey: key,
                createdAt: item.updatedAt
            )
        case .pending, .uploading, .succeeded, .cancelled:
            return nil
        }
    }

    public static func authentication(for failure: AuthenticationFailure, at date: Date = .now) -> AppAlert {
        AppAlert(
            source: .authentication,
            presentation: .inlineError,
            severity: .error,
            title: "Authentication unavailable",
            message: authenticationMessage(for: failure),
            actions: [AlertAction(id: "sign-in", title: "Sign In", intent: .signIn)],
            deduplicationKey: "authentication.\(failure.rawValue)",
            createdAt: date
        )
    }

    private static func dismissAction() -> AlertAction {
        AlertAction(id: "dismiss", title: "Dismiss", role: .cancel, intent: .dismiss)
    }

    private static func authenticationMessage(for failure: AuthenticationFailure) -> String {
        switch failure {
        case .invalidCredentials:
            "The supplied credentials could not be accepted."
        case .cancelled:
            "Sign in was cancelled."
        case .unavailable:
            "Sign in is not currently available."
        case .credentialStorage:
            "Secure credential storage is unavailable."
        }
    }
}
