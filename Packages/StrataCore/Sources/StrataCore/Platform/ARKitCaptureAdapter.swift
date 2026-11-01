#if os(iOS) && canImport(ARKit)
@preconcurrency import ARKit
@preconcurrency import AVFoundation
@preconcurrency import UIKit
#if canImport(RoomPlan)
@preconcurrency import RoomPlan
#endif
import CoreVideo
import Foundation
import Metal
import simd

public enum ARKitCaptureAdapterError: Error, Equatable, Sendable {
    case unsupportedConfiguration
    case recordingNotConfigured
    case captureAlreadyActive
    case captureNotStopped
    case recordingFinalizationInProgress
}

/// The sole owner of an ARKit raw-capture session. It separates lossless copied
/// persistence values from bounded live presentation; callers own structured
/// consumption, cancellation, and asset finalization.
@MainActor
// ARSessionDelegate predates Swift concurrency. The adapter is main-actor owned;
// the preconcurrency boundary is intentionally limited to Apple's callbacks.
public final class ARKitCaptureAdapter: NSObject, @preconcurrency ARSessionDelegate, DeviceCapabilityProviding {
    public let session: ARSession
    /// Lossless persistence path. Its sole consumer drains into disk-backed
    /// staging before finalization.
    public let essentialEvents: AsyncStream<ScanCaptureEvent>
    /// Coalescible live-presentation path. Values may be displaced under UI
    /// pressure and must never be treated as persistence authority.
    public let events: AsyncStream<ScanCaptureEvent>

    private let essentialEventContinuation: AsyncStream<ScanCaptureEvent>.Continuation
    private let eventContinuation: AsyncStream<ScanCaptureEvent>.Continuation
    private let assetRootURL: URL
    private let minimumRequiredStorageBytes: Int64
    private let locationAuthorizationProvider: (any LocationAuthorizationProviding)?
    private var configuration: ARWorldTrackingConfiguration?
    private var recorder: ARFrameVideoRecorder?
    private var finalizingRecorder: ARFrameVideoRecorder?
    private var recordingLifecycle = CaptureRecordingLifecycle()
    private let keyframeEncoder = ARFrameKeyframeEncoder()
    // Geometry always owns the high-frequency budget. Retained RGB is copied
    // only once every two seconds and encoded outside this callback.
    private let spatialFrameCadence = CaptureEventCadence(maximumFrequency: 3)
    private let keyframeCadence = CaptureEventCadence(maximumFrequency: 0.5)
    private var keyframePoseAdmission = KeyframePoseAdmission()
    // Essential RGB-D evidence is adaptive in the admission policy; this is
    // only its hard upper bound. Optional JPEGs remain independently sparse.
    private let calibratedKeyframeCadence = CaptureEventCadence(maximumFrequency: 2)
    private var calibratedKeyframeAdmission = CalibratedKeyframeAdmission()
    private let meshSnapshotCadence = CaptureEventCadence(maximumFrequency: 1)
    // Two fairly selected anchors retain a more coherent reconstruction during
    // a normal walk-around while remaining bounded: collection still keeps only
    // the latest immutable snapshot per anchor and image/video work is unchanged.
    private let maximumMeshSnapshotsPerCallback = 2
    private var lastSpatialFrameTimestamp = -Double.infinity
    private var lastKeyframeTimestamp = -Double.infinity
    private var lastCalibratedKeyframeTimestamp = -Double.infinity
    private var lastMeshSnapshotTimestampByAnchorID: [UUID: TimeInterval] = [:]
    private var trackingState: FrameTrackingState = .notAvailable
    private var lastReportedTrackingState: FrameTrackingState?
    private var hasEmittedThumbnail = false
    /// Synchronously owned by this type's MainActor isolation. Preview cadence
    /// never participates in authoritative latest-anchor state.
    private var meshAnchorRegistry = MeshAnchorRegistry()

    public init(
        session: ARSession = ARSession(),
        assetRootURL: URL,
        minimumRequiredStorageBytes: Int64 = 250_000_000,
        locationAuthorizationProvider: (any LocationAuthorizationProviding)? = nil
    ) {
        self.session = session
        self.assetRootURL = assetRootURL
        self.minimumRequiredStorageBytes = minimumRequiredStorageBytes
        self.locationAuthorizationProvider = locationAuthorizationProvider
        var capturedEssentialContinuation: AsyncStream<ScanCaptureEvent>.Continuation?
        essentialEvents = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            capturedEssentialContinuation = continuation
        }
        guard let capturedEssentialContinuation else {
            preconditionFailure("AsyncStream must synchronously provide its continuation")
        }
        essentialEventContinuation = capturedEssentialContinuation
        var capturedContinuation: AsyncStream<ScanCaptureEvent>.Continuation?
        events = AsyncStream(bufferingPolicy: .bufferingNewest(24)) { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else {
            preconditionFailure("AsyncStream must synchronously provide its continuation")
        }
        eventContinuation = capturedContinuation
        super.init()
        session.delegate = self
    }

    deinit {
        session.pause()
        session.delegate = nil
        essentialEventContinuation.finish()
        eventContinuation.finish()
    }

    public func currentCapabilities() async -> DeviceCapabilities {
        let cameraAuthorization = permission(from: AVCaptureDevice.authorizationStatus(for: .video))
        let locationAuthorization = await locationAuthorizationProvider?.currentAuthorization() ?? .notDetermined
        let supportsMesh = ARWorldTrackingConfiguration.isSupported
            && ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        let supportsDepth = ARWorldTrackingConfiguration.isSupported
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let roomPlanSupported: Bool
        #if canImport(RoomPlan)
        roomPlanSupported = RoomCaptureSession.isSupported
        #else
        roomPlanSupported = false
        #endif
        return DeviceCapabilities(
            lidarAvailable: supportsMesh,
            sceneReconstructionAvailable: supportsMesh,
            sceneDepthAvailable: supportsDepth,
            roomPlanAvailable: roomPlanSupported,
            cameraAuthorization: cameraAuthorization,
            motionTrackingAvailable: ARWorldTrackingConfiguration.isSupported,
            locationAuthorization: locationAuthorization,
            availableStorageBytes: availableStorageBytes(),
            minimumRequiredStorageBytes: minimumRequiredStorageBytes
        )
    }

    public func requestCameraAuthorization() async -> PermissionAuthorization {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        guard current == .notDetermined else { return permission(from: current) }
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
        }
        return granted ? .authorized : .denied
    }

    public func configureVideoRecording(outputURL: URL) throws {
        switch recordingLifecycle.state {
        case .capturing:
            throw ARKitCaptureAdapterError.captureAlreadyActive
        case .finalizing:
            throw ARKitCaptureAdapterError.recordingFinalizationInProgress
        case .unconfigured, .ready, .stopped:
            break
        }

        let newRecorder = try ARFrameVideoRecorder(
            outputURL: outputURL,
            orientation: currentInterfaceOrientation()
        )
        recorder?.cancel()
        recorder = newRecorder
        try recordingLifecycle.configure()
    }

    public func start() throws {
        guard let configuration = makeConfiguration() else {
            throw ARKitCaptureAdapterError.unsupportedConfiguration
        }
        do {
            // The lifecycle also serializes the AR session when no optional
            // video recorder is configured for a geometry-first capture.
            try recordingLifecycle.configure()
            try recordingLifecycle.start()
        } catch let error as CaptureRecordingLifecycle.LifecycleError {
            throw adapterError(for: error)
        }
        self.configuration = configuration
        keyframeEncoder.cancel()
        lastSpatialFrameTimestamp = -Double.infinity
        lastKeyframeTimestamp = -Double.infinity
        lastCalibratedKeyframeTimestamp = -Double.infinity
        keyframePoseAdmission.reset()
        calibratedKeyframeAdmission.reset()
        lastMeshSnapshotTimestampByAnchorID.removeAll(keepingCapacity: true)
        trackingState = .notAvailable
        lastReportedTrackingState = nil
        hasEmittedThumbnail = false
        meshAnchorRegistry.removeAll()
        session.delegate = self
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        publishTrackingState(.notAvailable)
    }

    public func pause() {
        guard recordingLifecycle.isCapturing else { return }
        session.pause()
    }

    public func resume() throws {
        guard recordingLifecycle.isCapturing, let configuration else {
            throw ARKitCaptureAdapterError.unsupportedConfiguration
        }
        session.delegate = self
        session.run(configuration)
    }

    public func stop() {
        guard recordingLifecycle.isCapturing else { return }
        emitFinalMeshRegistry()
        guard recordingLifecycle.stop() else { return }
        keyframeEncoder.cancel()
        configuration = nil
        stopSessionAndEmitTerminalEvent()
    }

    /// Drains previously accepted low-rate keyframes after raw capture has been
    /// paused and before `stop()` sends `.captureEnded`.
    public func finishKeyframeCapture() async {
        await keyframeEncoder.drain()
    }

    /// Cancels any pending writer as part of an explicit discard path. Unlike
    /// `stop()`, this never preserves a video for normal capture finalization.
    public func cancelVideoRecording() {
        if recordingLifecycle.stop() {
            stopSessionAndEmitTerminalEvent()
        }
        recorder?.cancel()
        recorder = nil
        finalizingRecorder = nil
        keyframeEncoder.cancel()
        configuration = nil
        recordingLifecycle.cancel()
    }

    public func finishVideoRecording() async throws -> URL {
        guard !recordingLifecycle.isCapturing else {
            throw ARKitCaptureAdapterError.captureNotStopped
        }
        guard let recorder else { throw ARKitCaptureAdapterError.recordingNotConfigured }

        do {
            try recordingLifecycle.beginFinalization()
        } catch let error as CaptureRecordingLifecycle.LifecycleError {
            throw adapterError(for: error)
        }
        finalizingRecorder = recorder
        defer {
            if finalizingRecorder === recorder {
                finalizingRecorder = nil
                recordingLifecycle.completeFinalization()
            }
            if self.recorder === recorder {
                self.recorder = nil
            }
        }
        return try await recorder.finish()
    }

    private func stopSessionAndEmitTerminalEvent() {
        session.pause()
        session.delegate = nil
        essentialEventContinuation.yield(.captureEnded)
        eventContinuation.yield(.captureEnded)
    }

    private func terminateCapture(with event: ScanCaptureEvent) {
        guard recordingLifecycle.isCapturing else { return }
        emitFinalMeshRegistry()
        essentialEventContinuation.yield(event)
        eventContinuation.yield(event)
        guard recordingLifecycle.stop() else { return }
        configuration = nil
        session.pause()
        session.delegate = nil
        recorder?.cancel()
        recorder = nil
        finalizingRecorder = nil
        keyframeEncoder.cancel()
        recordingLifecycle.cancel()
        essentialEventContinuation.yield(.captureEnded)
        eventContinuation.yield(.captureEnded)
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard recordingLifecycle.isCapturing else { return }
        let currentTrackingState = tracking(from: frame.camera.trackingState)
        publishTrackingState(currentTrackingState)
        guard currentTrackingState == .normal else { return }
        guard spatialFrameCadence.admits(timestamp: frame.timestamp, after: lastSpatialFrameTimestamp) else {
            return
        }
        lastSpatialFrameTimestamp = frame.timestamp
        let metadata = FrameMetadata(
            timestamp: frame.timestamp,
            videoTimestamp: nil,
            imageWidth: Int(frame.camera.imageResolution.width),
            imageHeight: Int(frame.camera.imageResolution.height),
            intrinsics: intrinsics(from: frame.camera),
            worldFromCamera: transform(from: frame.camera.transform),
            tracking: tracking(from: frame.camera.trackingState),
            worldMapping: mapping(from: frame.worldMappingStatus),
            isTextureSourceCandidate: false
        )
        let selectedDepth: (data: ARDepthData, source: CaptureDepthSource)? = if let smoothed = frame.smoothedSceneDepth {
            (smoothed, .smoothedSceneDepth)
        } else if let raw = frame.sceneDepth {
            (raw, .sceneDepth)
        } else {
            nil
        }
        let depth = selectedDepth.flatMap { makeDepthSample(from: $0.data, frame: frame) }
        let calibratedKeyframe = makeCalibratedKeyframe(
            from: frame,
            metadata: metadata,
            depth: depth,
            depthSource: selectedDepth?.source
        )
        let featurePoints = frame.rawFeaturePoints.map { cloud in
            Array(cloud.points.prefix(1_000)).map { Point3D(x: $0.x, y: $0.y, z: $0.z) }
        } ?? []
        let packet = CaptureFramePacket(
            metadata: metadata,
            depth: depth,
            featurePoints: featurePoints,
            calibratedKeyframe: calibratedKeyframe,
            textureSourceImageData: nil,
            thumbnailImageData: nil
        )
        essentialEventContinuation.yield(.frame(packet))
        eventContinuation.yield(.frame(packet))
        enqueueKeyframe(from: frame)
    }

    public func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard recordingLifecycle.isCapturing else { return }
        updateMeshRegistry(from: anchors, timestamp: session.currentFrame?.timestamp)
        if trackingState == .normal {
            emitMeshSnapshots(from: anchors)
        }
    }

    public func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard recordingLifecycle.isCapturing else { return }
        updateMeshRegistry(from: anchors, timestamp: session.currentFrame?.timestamp)
        if trackingState == .normal {
            emitMeshSnapshots(from: anchors)
        }
    }

    public func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let anchorIDs = anchors.map(\.identifier)
        meshAnchorRegistry.remove(anchorIDs: anchorIDs)
        for anchorID in anchorIDs {
            lastMeshSnapshotTimestampByAnchorID.removeValue(forKey: anchorID)
        }
        essentialEventContinuation.yield(.meshRemoved(anchorIDs))
    }

    public func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        guard recordingLifecycle.isCapturing else { return }
        publishTrackingState(tracking(from: camera.trackingState))
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        terminateCapture(with: .interruptionBegan)
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        guard recordingLifecycle.isCapturing else { return }
        essentialEventContinuation.yield(.interruptionEnded)
        eventContinuation.yield(.interruptionEnded)
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        terminateCapture(with: .failed(captureFailureMessage(for: error)))
    }

    private func adapterError(
        for error: CaptureRecordingLifecycle.LifecycleError
    ) -> ARKitCaptureAdapterError {
        switch error {
        case .captureAlreadyActive:
            return .captureAlreadyActive
        case .recordingNotConfigured:
            return .recordingNotConfigured
        case .captureNotStopped:
            return .captureNotStopped
        case .finalizationInProgress:
            return .recordingFinalizationInProgress
        }
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration? {
        guard
            ARWorldTrackingConfiguration.isSupported,
            ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        else {
            return nil
        }
        let configuration = ARWorldTrackingConfiguration()
        // Raw capture does not persist plane anchors or semantic face classes.
        // Avoid requesting them because they compete with LiDAR reconstruction
        // and camera tracking on the same real-time session.
        configuration.sceneReconstruction = .mesh
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        return configuration
    }

    private func enqueueKeyframe(from frame: ARFrame) {
        guard keyframeCadence.admits(timestamp: frame.timestamp, after: lastKeyframeTimestamp) else {
            return
        }
        guard ARFrameKeyframeQualityGate.admits(frame.capturedImage) else { return }
        let metadata = FrameMetadata(
            timestamp: frame.timestamp,
            videoTimestamp: nil,
            imageWidth: Int(frame.camera.imageResolution.width),
            imageHeight: Int(frame.camera.imageResolution.height),
            intrinsics: intrinsics(from: frame.camera),
            worldFromCamera: transform(from: frame.camera.transform),
            tracking: .normal,
            worldMapping: mapping(from: frame.worldMappingStatus),
            isTextureSourceCandidate: true,
            displayOrientation: currentCapturedImageOrientation()
        )
        guard keyframePoseAdmission.admits(metadata) else { return }
        guard keyframeEncoder.enqueue(sourcePixelBuffer: frame.capturedImage, metadata: metadata, completion: { [weak self] metadata, jpegData in
            guard let self, self.recordingLifecycle.isCapturing else { return }
            guard let jpegData else {
                self.essentialEventContinuation.yield(
                    .telemetry(.optionalKeyframeImageDropped(.encodingFailure))
                )
                return
            }
            let thumbnailData = self.hasEmittedThumbnail ? nil : jpegData
            self.hasEmittedThumbnail = true
            self.essentialEventContinuation.yield(
                .frame(
                    CaptureFramePacket(
                        metadata: metadata,
                        depth: nil,
                        featurePoints: [],
                        textureSourceImageData: jpegData,
                        thumbnailImageData: thumbnailData
                    )
                )
            )
        }) else {
            essentialEventContinuation.yield(
                .telemetry(.optionalKeyframeImageDropped(.writerPressure))
            )
            return
        }
        lastKeyframeTimestamp = frame.timestamp
        keyframePoseAdmission.recordAccepted(metadata)
    }

    private func makeCalibratedKeyframe(
        from frame: ARFrame,
        metadata: FrameMetadata,
        depth: DepthFrameSample?,
        depthSource: CaptureDepthSource?
    ) -> CalibratedRGBDKeyframeSample? {
        guard calibratedKeyframeCadence.admits(
            timestamp: frame.timestamp,
            after: lastCalibratedKeyframeTimestamp
        ) else {
            essentialEventContinuation.yield(
                .telemetry(.calibratedKeyframeRejected(.minimumInterval))
            )
            return nil
        }
        let imageQuality = ARFrameKeyframeQualityGate.measurement(for: frame.capturedImage)
        if let rejection = imageQuality.rejectionReason {
            essentialEventContinuation.yield(
                .telemetry(.calibratedKeyframeRejected(rejection))
            )
            return nil
        }

        var calibratedMetadata = metadata
        calibratedMetadata.displayOrientation = currentCapturedImageOrientation()
        let decision = calibratedKeyframeAdmission.evaluate(
            metadata: calibratedMetadata,
            depth: depth
        )
        if let evidence = calibratedKeyframeAdmission.lastEvidence {
            essentialEventContinuation.yield(.telemetry(.calibratedKeyframeCandidate(evidence)))
        }
        switch decision {
        case let .accepted(reason):
            guard let depth,
                  let depthSource,
                  let evidence = calibratedKeyframeAdmission.lastEvidence,
                  frame.camera.exposureDuration.isFinite,
                  frame.camera.exposureDuration > 0,
                  frame.camera.exposureOffset.isFinite,
                  let luminanceMean = imageQuality.luminanceMean,
                  let luminanceVariance = imageQuality.luminanceVariance,
                  let adjacentDifference = imageQuality.adjacentDifference
            else {
                essentialEventContinuation.yield(
                    .telemetry(.calibratedKeyframeRejected(.exposure))
                )
                return nil
            }
            let contract = CaptureEvidenceContract(
                source: .arkitWorldTracking,
                depthSource: depthSource,
                rgbSource: .capturedImageNearestNeighborToDepthGrid,
                synchronization: .sameARFrame,
                timestamps: CaptureEvidenceTimestamps(
                    capture: frame.timestamp,
                    cameraImage: frame.timestamp,
                    depth: frame.timestamp,
                    confidence: frame.timestamp,
                    pose: frame.timestamp,
                    maximumSourceDeltaSeconds: 0
                ),
                cameraImageWidth: CVPixelBufferGetWidth(frame.capturedImage),
                cameraImageHeight: CVPixelBufferGetHeight(frame.capturedImage),
                depthWidth: depth.width,
                depthHeight: depth.height,
                exposure: CaptureExposureEvidence(
                    availability: .measured,
                    exposureDurationSeconds: frame.camera.exposureDuration,
                    exposureTargetOffsetEV: frame.camera.exposureOffset,
                    sampledLuminanceMean: luminanceMean,
                    sampledLuminanceVariance: luminanceVariance,
                    sampledAdjacentDifference: adjacentDifference
                ),
                acceptanceEvidence: evidence
            )
            lastCalibratedKeyframeTimestamp = frame.timestamp
            return CalibratedRGBDKeyframeSample(
                metadata: calibratedMetadata,
                depth: depth,
                acceptanceReason: reason,
                evidence: evidence,
                evidenceContract: contract
            )
        case let .rejected(reason):
            essentialEventContinuation.yield(
                .telemetry(.calibratedKeyframeRejected(reason))
            )
            return nil
        }
    }

    private func emitMeshSnapshots(from anchors: [ARAnchor]) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let eligibleAnchors = anchors
            .compactMap { $0 as? ARMeshAnchor }
            .filter { meshAnchor in
                let previousTimestamp = lastMeshSnapshotTimestampByAnchorID[meshAnchor.identifier] ?? -.infinity
                return meshSnapshotCadence.admits(timestamp: timestamp, after: previousTimestamp)
            }
        emitMeshSnapshots(
            from: eligibleAnchors,
            timestamp: timestamp,
            maximumCount: maximumMeshSnapshotsPerCallback
        )
    }

    /// Refreshes every valid active mesh anchor while ARKit is still owned,
    /// then publishes one immutable authoritative registry snapshot through the
    /// lossless persistence path. UI stream capacity is irrelevant.
    private func emitFinalMeshRegistry() {
        if let frame = session.currentFrame {
            let anchors = frame.anchors
            let snapshots = anchors.compactMap { anchor -> MeshSnapshot? in
                guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
                return makeMeshSnapshot(
                    from: meshAnchor,
                    timestamp: frame.timestamp,
                    provenance: .finalSessionSnapshot
                )
            }
            meshAnchorRegistry.replaceAll(snapshots)
        }
        essentialEventContinuation.yield(.meshRegistrySnapshot(meshAnchorRegistry.snapshots))
    }

    private func updateMeshRegistry(from anchors: [ARAnchor], timestamp: TimeInterval?) {
        for anchor in anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            if let timestamp,
               let snapshot = makeMeshSnapshot(
                   from: meshAnchor,
                   timestamp: timestamp,
                   provenance: .anchorUpdate
               ) {
                meshAnchorRegistry.replace(snapshot)
            } else {
                meshAnchorRegistry.remove(anchorIDs: [meshAnchor.identifier])
            }
        }
    }

    private func emitMeshSnapshots(
        from meshAnchors: [ARMeshAnchor],
        timestamp: TimeInterval,
        maximumCount: Int
    ) {
        let selector = MeshSnapshotAnchorSelector(maximumCount: maximumCount)
        let selectedAnchorIDs = selector.select(
            from: meshAnchors.map(\.identifier),
            lastSnapshotTimestampByAnchorID: lastMeshSnapshotTimestampByAnchorID
        )
        var anchorsByID: [UUID: ARMeshAnchor] = [:]
        for anchor in meshAnchors {
            anchorsByID[anchor.identifier] = anchor
        }

        for anchorID in selectedAnchorIDs {
            guard let meshAnchor = anchorsByID[anchorID] else { continue }
            guard let snapshot = makeMeshSnapshot(
                from: meshAnchor,
                timestamp: timestamp,
                provenance: .anchorUpdate
            ) else { continue }
            eventContinuation.yield(.mesh(snapshot))
            lastMeshSnapshotTimestampByAnchorID[meshAnchor.identifier] = timestamp
        }
    }

    private func publishTrackingState(_ state: FrameTrackingState) {
        trackingState = state
        guard lastReportedTrackingState != state else { return }
        lastReportedTrackingState = state
        essentialEventContinuation.yield(.tracking(state))
        eventContinuation.yield(.tracking(state))
    }

    private func captureFailureMessage(for error: Error) -> String {
        let error = error as NSError
        // ARKit error 102 is `sensorFailed`: AVFoundation could not provide a
        // required camera/sensor input. Keep this a stable internal token; the
        // presentation layer supplies localized, user-actionable copy.
        if error.domain == "com.apple.arkit.error", error.code == 102 {
            return "sensorUnavailable"
        }
        return "captureFailed"
    }

    private func currentInterfaceOrientation() -> CaptureVideoOrientation? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        guard let orientation = scene?.interfaceOrientation else {
            return nil
        }

        return switch orientation {
        case .landscapeRight:
            .landscapeRight
        case .portrait:
            .portrait
        case .landscapeLeft:
            .landscapeLeft
        case .portraitUpsideDown:
            .portraitUpsideDown
        case .unknown:
            nil
        @unknown default:
            nil
        }
    }

    private func currentCapturedImageOrientation() -> CapturedImageOrientation? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        guard let orientation = scene?.interfaceOrientation else { return nil }
        return switch orientation {
        case .portrait: .right
        case .portraitUpsideDown: .left
        case .landscapeLeft: .up
        case .landscapeRight: .down
        case .unknown: nil
        @unknown default: nil
        }
    }

    private func makeMeshSnapshot(
        from anchor: ARMeshAnchor,
        timestamp: TimeInterval,
        provenance: MeshSnapshotProvenance
    ) -> MeshSnapshot? {
        let geometry = anchor.geometry
        guard
            geometry.vertices.format == .float3,
            geometry.vertices.componentsPerVector == 3,
            geometry.faces.primitiveType == .triangle,
            geometry.faces.indexCountPerPrimitive == 3
        else {
            return nil
        }
        let vertices = (0..<geometry.vertices.count).map { point(from: geometry.vertices, index: $0) }
        let normals = geometry.normals.format == .float3 && geometry.normals.count == vertices.count
            ? (0..<geometry.normals.count).map { point(from: geometry.normals, index: $0) }
            : []
        var faces: [MeshFace] = []
        for faceIndex in 0..<geometry.faces.count {
            guard let first = meshIndex(from: geometry.faces, face: faceIndex, offset: 0),
                  let second = meshIndex(from: geometry.faces, face: faceIndex, offset: 1),
                  let third = meshIndex(from: geometry.faces, face: faceIndex, offset: 2)
            else { return nil }
            faces.append(MeshFace(indices: (first, second, third)))
        }
        let classifications = meshClassifications(from: geometry, faceCount: faces.count)
        return try? MeshSnapshot(
            anchorID: anchor.identifier,
            worldFromAnchor: transform(from: anchor.transform),
            vertices: vertices,
            normals: normals,
            faces: faces,
            classifications: classifications,
            captureTimestamp: timestamp,
            provenance: provenance
        )
    }

    private func point(from source: ARGeometrySource, index: Int) -> Point3D {
        let byteOffset = source.offset + source.stride * index
        let pointer = source.buffer.contents().advanced(by: byteOffset).assumingMemoryBound(to: Float.self)
        return Point3D(x: pointer[0], y: pointer[1], z: pointer[2])
    }

    private func meshIndex(from element: ARGeometryElement, face: Int, offset: Int) -> Int? {
        let byteOffset = (face * element.indexCountPerPrimitive + offset) * element.bytesPerIndex
        let pointer = element.buffer.contents().advanced(by: byteOffset)
        return switch element.bytesPerIndex {
        case 2:
            Int(pointer.assumingMemoryBound(to: UInt16.self).pointee)
        case 4:
            Int(pointer.assumingMemoryBound(to: UInt32.self).pointee)
        default:
            nil
        }
    }

    private func meshClassifications(from geometry: ARMeshGeometry, faceCount: Int) -> [MeshClassification] {
        guard let source = geometry.classification, source.count == faceCount else { return [] }
        return (0..<faceCount).map { index in
            let rawValue = source.buffer.contents().advanced(by: source.offset + source.stride * index).assumingMemoryBound(to: UInt8.self).pointee
            guard let classification = ARMeshClassification(rawValue: Int(rawValue)) else { return .unknown }
            switch classification {
            case .ceiling: return .ceiling
            case .door: return .door
            case .floor: return .floor
            case .seat: return .seat
            case .table: return .table
            case .wall: return .wall
            case .window: return .window
            case .none: return .none
            @unknown default: return .unknown
            }
        }
    }

    private func makeDepthSample(from depthData: ARDepthData, frame: ARFrame) -> DepthFrameSample? {
        let depthMap = depthData.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        var values: [Float] = []
        values.reserveCapacity(width * height)
        switch CVPixelBufferGetPixelFormatType(depthMap) {
        case kCVPixelFormatType_DepthFloat32:
            for row in 0..<height {
                let rowPointer = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float.self)
                values.append(contentsOf: UnsafeBufferPointer(start: rowPointer, count: width))
            }
        case kCVPixelFormatType_DepthFloat16:
            for row in 0..<height {
                let rowPointer = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                values.append(contentsOf: (0..<width).map { Float(Float16(bitPattern: rowPointer[$0])) })
            }
        default:
            return nil
        }
        guard let confidence = copyConfidenceMap(
            depthData.confidenceMap,
            width: width,
            height: height
        ) else { return nil }
        let observedColors = copyObservedColors(
            from: frame.capturedImage,
            depthWidth: width,
            depthHeight: height
        )
        return DepthFrameSample(
            width: width,
            height: height,
            depthMeters: values,
            confidence: confidence,
            observedColors: observedColors,
            calibration: intrinsics(from: frame.camera),
            worldFromCamera: transform(from: frame.camera.transform),
            timestamp: frame.timestamp
        )
    }

    private func copyConfidenceMap(_ confidenceMap: CVPixelBuffer?, width: Int, height: Int) -> [UInt8]? {
        guard let confidenceMap,
              CVPixelBufferGetWidth(confidenceMap) == width,
              CVPixelBufferGetHeight(confidenceMap) == height
        else {
            return nil
        }
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        var values: [UInt8] = []
        values.reserveCapacity(width * height)
        for row in 0..<height {
            let rowPointer = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            values.append(contentsOf: UnsafeBufferPointer(start: rowPointer, count: width))
        }
        return values
    }

    /// Copies only a low-resolution RGB observation grid aligned with the
    /// LiDAR depth pixels. This runs at the existing bounded spatial cadence;
    /// it does not retain an `ARFrame`, create JPEGs, or start video work.
    private func copyObservedColors(
        from capturedImage: CVPixelBuffer,
        depthWidth: Int,
        depthHeight: Int
    ) -> [PointCloudColor?] {
        guard depthWidth > 0,
              depthHeight > 0,
              CVPixelBufferGetPlaneCount(capturedImage) == 2
        else {
            return []
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(capturedImage)
        let isFullRange: Bool
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            isFullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            isFullRange = false
        default:
            return []
        }

        let imageWidth = CVPixelBufferGetWidth(capturedImage)
        let imageHeight = CVPixelBufferGetHeight(capturedImage)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(capturedImage, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(capturedImage, 1)
        guard imageWidth > 0,
              imageHeight > 0,
              chromaWidth > 0,
              chromaHeight > 0
        else {
            return []
        }

        CVPixelBufferLockBaseAddress(capturedImage, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(capturedImage, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(capturedImage, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(capturedImage, 1)
        else {
            return []
        }

        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(capturedImage, 0)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(capturedImage, 1)
        var colors: [PointCloudColor?] = []
        colors.reserveCapacity(depthWidth * depthHeight)

        for depthY in 0..<depthHeight {
            let imageY = min(imageHeight - 1, depthY * imageHeight / depthHeight)
            let chromaY = min(chromaHeight - 1, imageY / 2)
            let lumaRow = lumaBase.advanced(by: imageY * lumaBytesPerRow).assumingMemoryBound(to: UInt8.self)
            let chromaRow = chromaBase.advanced(by: chromaY * chromaBytesPerRow).assumingMemoryBound(to: UInt8.self)
            for depthX in 0..<depthWidth {
                let imageX = min(imageWidth - 1, depthX * imageWidth / depthWidth)
                let chromaX = min(chromaWidth - 1, imageX / 2)
                let y = Float(lumaRow[imageX])
                let cb = Float(chromaRow[chromaX * 2])
                let cr = Float(chromaRow[chromaX * 2 + 1])
                colors.append(yCbCrColor(y: y, cb: cb, cr: cr, isFullRange: isFullRange))
            }
        }
        return colors
    }

    private func yCbCrColor(
        y: Float,
        cb: Float,
        cr: Float,
        isFullRange: Bool
    ) -> PointCloudColor {
        let chromaBlue = cb - 128
        let chromaRed = cr - 128
        let luma = isFullRange ? y : 1.164_383_56 * (y - 16)
        let red = luma + (isFullRange ? 1.402 : 1.596_027) * chromaRed
        let green = luma - (isFullRange ? 0.344_136 : 0.391_762) * chromaBlue
            - (isFullRange ? 0.714_136 : 0.812_968) * chromaRed
        let blue = luma + (isFullRange ? 1.772 : 2.017_232) * chromaBlue
        return PointCloudColor(
            red: clampedColorComponent(red),
            green: clampedColorComponent(green),
            blue: clampedColorComponent(blue)
        )
    }

    private func clampedColorComponent(_ value: Float) -> UInt8 {
        let rounded = value.rounded()
        guard rounded.isFinite else {
            return 0
        }
        // Clamp while still in floating-point space. Besides being clearer at
        // the sensor boundary, this avoids converting an unexpected very large
        // finite camera value to `Int` before its range has been checked.
        if rounded <= 0 {
            return 0
        }
        if rounded >= 255 {
            return 255
        }
        return UInt8(rounded)
    }

    private func intrinsics(from camera: ARCamera) -> CameraIntrinsics {
        let matrix = camera.intrinsics
        return CameraIntrinsics(
            imageWidth: Int(camera.imageResolution.width),
            imageHeight: Int(camera.imageResolution.height),
            fx: matrix.columns.0.x,
            fy: matrix.columns.1.y,
            cx: matrix.columns.2.x,
            cy: matrix.columns.2.y
        )
    }

    private func transform(from matrix: simd_float4x4) -> Transform4x4 {
        let values: [Float] = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
        return (try? Transform4x4(columns: values)) ?? .identity
    }

    private func tracking(from state: ARCamera.TrackingState) -> FrameTrackingState {
        switch state {
        case .normal: .normal
        case .limited: .limited
        case .notAvailable: .notAvailable
        }
    }

    private func mapping(from status: ARFrame.WorldMappingStatus) -> WorldMappingState {
        switch status {
        case .mapped: .mapped
        case .extending: .extending
        case .limited: .limited
        case .notAvailable: .notAvailable
        @unknown default: .notAvailable
        }
    }

    private func permission(from status: AVAuthorizationStatus) -> PermissionAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }

    private func availableStorageBytes() -> Int64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey]
        let values = try? assetRootURL.resourceValues(forKeys: keys)
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        return 0
    }
}
#endif
