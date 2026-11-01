#if os(iOS) && canImport(CoreLocation)
@preconcurrency import CoreLocation

/// Location remains optional for scanning. This provider is invoked only from a
/// future explicit GIS/georeferencing action, never during app launch or capture.
@MainActor
// CLLocationManagerDelegate predates Swift concurrency; keep the compatibility
// boundary limited to this main-actor permission adapter.
public final class SystemLocationPermissionProvider: NSObject, LocationAuthorizationProviding, @preconcurrency CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<PermissionAuthorization, Never>?

    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
    }

    public func currentAuthorization() async -> PermissionAuthorization {
        authorization(from: manager.authorizationStatus)
    }

    public func requestWhenInUseAuthorization() async -> PermissionAuthorization {
        let current = authorization(from: manager.authorizationStatus)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = authorization(from: manager.authorizationStatus)
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    private func authorization(from status: CLAuthorizationStatus) -> PermissionAuthorization {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}
#endif
