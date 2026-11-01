import Foundation

public enum PermissionAuthorization: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

public enum ScanCaptureMode: String, Codable, CaseIterable, Hashable, Sendable {
    case rawLiDAR
    case semanticRoom
}

public enum ScanCapabilityIssue: String, Codable, CaseIterable, Sendable {
    case lidarUnavailable
    case sceneReconstructionUnavailable
    case sceneDepthUnavailable
    case roomPlanUnavailable
    case cameraPermissionDenied
    case motionTrackingUnavailable
    case insufficientStorage
}

public enum ScanCapabilityAdvisory: String, Codable, CaseIterable, Sendable {
    case roomPlanUnavailable
}

public enum ScanAvailability: Equatable, Sendable {
    case available
    case requiresCameraPermission
    case unavailable([ScanCapabilityIssue])
}

/// Complete capability snapshot captured at the composition boundary. Location
/// is intentionally represented but is not a scan-capture prerequisite.
public struct DeviceCapabilities: Equatable, Sendable {
    public var lidarAvailable: Bool
    public var sceneReconstructionAvailable: Bool
    public var sceneDepthAvailable: Bool
    public var roomPlanAvailable: Bool
    public var cameraAuthorization: PermissionAuthorization
    public var motionTrackingAvailable: Bool
    public var locationAuthorization: PermissionAuthorization
    public var availableStorageBytes: Int64
    public var minimumRequiredStorageBytes: Int64

    public init(
        lidarAvailable: Bool,
        sceneReconstructionAvailable: Bool,
        sceneDepthAvailable: Bool,
        roomPlanAvailable: Bool,
        cameraAuthorization: PermissionAuthorization,
        motionTrackingAvailable: Bool,
        locationAuthorization: PermissionAuthorization,
        availableStorageBytes: Int64,
        minimumRequiredStorageBytes: Int64
    ) {
        self.lidarAvailable = lidarAvailable
        self.sceneReconstructionAvailable = sceneReconstructionAvailable
        self.sceneDepthAvailable = sceneDepthAvailable
        self.roomPlanAvailable = roomPlanAvailable
        self.cameraAuthorization = cameraAuthorization
        self.motionTrackingAvailable = motionTrackingAvailable
        self.locationAuthorization = locationAuthorization
        self.availableStorageBytes = availableStorageBytes
        self.minimumRequiredStorageBytes = minimumRequiredStorageBytes
    }

    public static func supported(
        cameraAuthorization: PermissionAuthorization,
        locationAuthorization: PermissionAuthorization = .notDetermined,
        availableStorageBytes: Int64 = 1_000_000_000,
        minimumRequiredStorageBytes: Int64 = 250_000_000
    ) -> DeviceCapabilities {
        DeviceCapabilities(
            lidarAvailable: true,
            sceneReconstructionAvailable: true,
            sceneDepthAvailable: true,
            roomPlanAvailable: true,
            cameraAuthorization: cameraAuthorization,
            motionTrackingAvailable: true,
            locationAuthorization: locationAuthorization,
            availableStorageBytes: availableStorageBytes,
            minimumRequiredStorageBytes: minimumRequiredStorageBytes
        )
    }

    public var scanAvailability: ScanAvailability {
        availability(for: .rawLiDAR)
    }

    public func availability(for mode: ScanCaptureMode) -> ScanAvailability {
        var blockers: [ScanCapabilityIssue] = []
        switch mode {
        case .rawLiDAR:
            if !lidarAvailable { blockers.append(.lidarUnavailable) }
            if !sceneReconstructionAvailable { blockers.append(.sceneReconstructionUnavailable) }
            if !sceneDepthAvailable { blockers.append(.sceneDepthUnavailable) }
            if !motionTrackingAvailable { blockers.append(.motionTrackingUnavailable) }
        case .semanticRoom:
            if !roomPlanAvailable { blockers.append(.roomPlanUnavailable) }
        }
        if availableStorageBytes < minimumRequiredStorageBytes { blockers.append(.insufficientStorage) }
        if cameraAuthorization == .denied || cameraAuthorization == .restricted {
            blockers.append(.cameraPermissionDenied)
        }
        if !blockers.isEmpty { return .unavailable(blockers) }
        if cameraAuthorization == .notDetermined { return .requiresCameraPermission }
        return .available
    }

    public var advisories: [ScanCapabilityAdvisory] {
        advisories(for: .rawLiDAR)
    }

    public func advisories(for mode: ScanCaptureMode) -> [ScanCapabilityAdvisory] {
        mode == .rawLiDAR && !roomPlanAvailable ? [.roomPlanUnavailable] : []
    }

    public var isLocationOptional: Bool { true }
}

public protocol DeviceCapabilityProviding: Sendable {
    func currentCapabilities() async -> DeviceCapabilities
}
