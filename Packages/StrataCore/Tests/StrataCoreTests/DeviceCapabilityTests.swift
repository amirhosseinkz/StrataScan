import Testing
@testable import StrataCore

@Suite("Scan device capabilities")
struct DeviceCapabilityTests {
    @Test("LiDAR and reconstruction absence explains why scanning is unavailable")
    func reportsUnsupportedHardware() {
        let capabilities = DeviceCapabilities(
            lidarAvailable: false,
            sceneReconstructionAvailable: false,
            sceneDepthAvailable: false,
            roomPlanAvailable: false,
            cameraAuthorization: .authorized,
            motionTrackingAvailable: true,
            locationAuthorization: .notDetermined,
            availableStorageBytes: 10_000_000,
            minimumRequiredStorageBytes: 1_000_000
        )

        #expect(capabilities.scanAvailability == .unavailable([.lidarUnavailable, .sceneReconstructionUnavailable, .sceneDepthUnavailable]))
        #expect(capabilities.isLocationOptional)
    }

    @Test("Camera access is requested instead of treated as unsupported hardware")
    func requestsCameraPermission() {
        let capabilities = DeviceCapabilities.supported(cameraAuthorization: .notDetermined)

        #expect(capabilities.scanAvailability == .requiresCameraPermission)
    }

    @Test("Low storage blocks capture even on compatible hardware")
    func blocksForLowStorage() {
        var capabilities = DeviceCapabilities.supported(cameraAuthorization: .authorized)
        capabilities.availableStorageBytes = 200
        capabilities.minimumRequiredStorageBytes = 1_000

        #expect(capabilities.scanAvailability == .unavailable([.insufficientStorage]))
    }

    @Test("RoomPlan is optional to raw LiDAR capture")
    func allowsRawCaptureWithoutRoomPlan() {
        var capabilities = DeviceCapabilities.supported(cameraAuthorization: .authorized)
        capabilities.roomPlanAvailable = false

        #expect(capabilities.scanAvailability == .available)
        #expect(capabilities.advisories == [.roomPlanUnavailable])
    }

    @Test("Semantic RoomPlan capture requires RoomPlan but not raw mesh capability")
    func reportsSemanticRoomAvailabilityIndependently() {
        var capabilities = DeviceCapabilities.supported(cameraAuthorization: .authorized)
        capabilities.lidarAvailable = false
        capabilities.sceneReconstructionAvailable = false
        capabilities.sceneDepthAvailable = false
        capabilities.motionTrackingAvailable = false

        #expect(capabilities.availability(for: .semanticRoom) == .available)

        capabilities.roomPlanAvailable = false
        #expect(capabilities.availability(for: .semanticRoom) == .unavailable([.roomPlanUnavailable]))
    }
}
