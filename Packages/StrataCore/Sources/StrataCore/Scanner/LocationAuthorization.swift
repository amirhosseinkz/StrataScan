public protocol LocationAuthorizationProviding: Sendable {
    func currentAuthorization() async -> PermissionAuthorization
    func requestWhenInUseAuthorization() async -> PermissionAuthorization
}
