import XCTest
@testable import StrataScan
import StrataCore
import SceneKit
import UIKit
#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
#endif
#if canImport(ARKit)
import ARKit

private final class ARSessionDelegateProbe: NSObject, ARSessionDelegate {}
#endif

final class AppPresentationTests: XCTestCase {
#if canImport(AVFoundation)
    @MainActor
    func testVideoRecorderWritesPortraitDisplayOrientationMetadata() async throws {
        let outputURL = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanVideo-\(UUID().uuidString).mov"
        )
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let recorder = try ARFrameVideoRecorder(outputURL: outputURL, orientation: .portrait)
        let pixelBuffer = try makeVideoPixelBuffer(width: 64, height: 48)
        _ = try recorder.append(pixelBuffer: pixelBuffer, timestamp: 1)
        _ = try recorder.append(pixelBuffer: pixelBuffer, timestamp: 1 + 1.0 / 30.0)
        let completedURL = try await recorder.finish()

        let asset = AVURLAsset(url: completedURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return XCTFail("Expected the MOV to contain a video track")
        }
        let transform = try await track.load(.preferredTransform)

        XCTAssertEqual(transform.a, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.b, 1, accuracy: 0.0001)
        XCTAssertEqual(transform.c, -1, accuracy: 0.0001)
        XCTAssertEqual(transform.d, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.tx, 48, accuracy: 0.0001)
        XCTAssertEqual(transform.ty, 0, accuracy: 0.0001)
    }

    private func makeVideoPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CocoaError(.fileWriteUnknown)
        }
        baseAddress.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetDataSize(pixelBuffer))
        return pixelBuffer
    }
#endif

    @MainActor
    func testRawMeshSceneBuilderRendersVertexOnlySnapshotAsPoints() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: [],
            faces: []
        )

        let scene = RawMeshSceneBuilder.makeScene(from: [snapshot])
        let geometry = scene.rootNode.childNodes.first(where: { $0.geometry != nil })?.geometry

        XCTAssertEqual(geometry?.elements.first?.primitiveType, .point)
        XCTAssertNotNil(scene.rootNode.childNodes.first(where: { $0.camera != nil }))
    }

    @MainActor
    func testRawMeshSceneBuilderUsesProjectedCameraColorsOnlyWhenProvided() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
        let colors = [
            MeshVertexColor(red: 255, green: 0, blue: 0),
            MeshVertexColor(red: 0, green: 255, blue: 0),
            MeshVertexColor(red: 0, green: 0, blue: 255)
        ]

        let plainGeometry = RawMeshSceneBuilder.makeScene(from: [snapshot])
            .rootNode.childNodes.first(where: { $0.geometry != nil })?.geometry
        let coloredScene = RawMeshSceneBuilder.makeScene(
            from: [snapshot],
            vertexColors: [snapshot.anchorID: colors]
        )

        XCTAssertFalse(plainGeometry?.sources.contains(where: { $0.semantic == .color }) == true)
        XCTAssertNotNil(coloredScene.rootNode.childNode(
            withName: "scan-derived-camera-color-atlas",
            recursively: true
        ))
    }

    @MainActor
    func testRawMeshSceneBuilderLeavesPartiallyProjectedFacesAsGeometry() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
        let colors: [MeshVertexColor?] = [
            MeshVertexColor(red: 255, green: 0, blue: 0),
            nil,
            MeshVertexColor(red: 0, green: 0, blue: 255)
        ]

        let scene = RawMeshSceneBuilder.makeScene(
            from: [snapshot],
            vertexColors: [snapshot.anchorID: colors]
        )

        XCTAssertFalse(sceneContainsVertexColorSource(scene))
        XCTAssertNil(scene.rootNode.childNode(withName: "scan-derived-camera-color-atlas", recursively: true))
    }

    @MainActor
    func testRawMeshSceneBuilderRendersOnlySuppliedCalibratedCameraFrustums() throws {
        let snapshot = try makeTestMeshSnapshot()
        let frustum = SavedCameraFrustum(
            id: URL(filePath: "/tmp/retained-frame.jpg"),
            worldFromCamera: .translation(x: 2, y: 3, z: 4),
            intrinsics: CameraIntrinsics(
                imageWidth: 640,
                imageHeight: 480,
                fx: 500,
                fy: 500,
                cx: 320,
                cy: 240
            ),
            imageWidth: 640,
            imageHeight: 480
        )

        let plainScene = RawMeshSceneBuilder.makeScene(from: [snapshot])
        let scene = RawMeshSceneBuilder.makeScene(
            from: [snapshot],
            cameraFrustums: [frustum]
        )

        XCTAssertNil(plainScene.rootNode.childNode(withName: "scan-retained-keyframe-frustum", recursively: true))
        let node = try XCTUnwrap(
            scene.rootNode.childNode(withName: "scan-retained-keyframe-frustum", recursively: true)
        )
        XCTAssertEqual(node.geometry?.elements.first?.primitiveType, .line)
        XCTAssertEqual(node.position.x, 2, accuracy: 0.0001)
        XCTAssertEqual(node.position.y, 3, accuracy: 0.0001)
        XCTAssertEqual(node.position.z, 4, accuracy: 0.0001)
    }

    func testSavedWorkspaceDefaultsToProcessedSurfaceAndFiltersUncalibratedFrustums() throws {
        let valid = makeTestCameraFrustum(id: 1, worldFromCamera: .identity)
        let nonFiniteTransform = try Transform4x4(columns: [
            .nan, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ])
        let invalidPose = makeTestCameraFrustum(id: 2, worldFromCamera: nonFiniteTransform)
        let invalidIntrinsics = SavedCameraFrustum(
            id: URL(filePath: "/tmp/invalid-calibration.jpg"),
            worldFromCamera: .identity,
            intrinsics: CameraIntrinsics(
                imageWidth: 640,
                imageHeight: 480,
                fx: 500,
                fy: 500,
                cx: .nan,
                cy: 240
            ),
            imageWidth: 640,
            imageHeight: 480
        )

        let calibrated = SavedScanWorkspacePresentation.calibratedCameraFrustums(
            from: [invalidPose, invalidIntrinsics, valid]
        )

        XCTAssertEqual(SavedScanWorkspacePresentation.defaultSurface, .processedSurface)
        XCTAssertEqual(calibrated, [valid])
        XCTAssertTrue(
            SavedScanWorkspacePresentation.calibratedCameraFrustums(
                from: [invalidPose, invalidIntrinsics]
            ).isEmpty
        )
    }

    func testSavedWorkspacePrefersColoredProcessedSurfaceAndFallsBackDeterministically() throws {
        let bounds = try TSDFSurfaceBounds(
            minimum: Point3D(x: 0, y: 0, z: 0),
            maximum: Point3D(x: 1, y: 1, z: 0)
        )
        let prefix = makeProcessedSurfacePrefix()
        let coloredSurface = SavedProcessedSurfacePresentation(
            surface: ProcessedSurfaceLOD(
                prefix: prefix,
                sourceVertexCount: 3,
                sourceTriangleCount: 1,
                vertices: [
                    Point3D(x: 0, y: 0, z: 0),
                    Point3D(x: 1, y: 0, z: 0),
                    Point3D(x: 0, y: 1, z: 0)
                ],
                normals: Array(repeating: Point3D(x: 0, y: 0, z: 1), count: 3),
                colors: [PointCloudColor(red: 20, green: 40, blue: 60), nil, nil],
                indices: [0, 1, 2],
                robustBounds: bounds,
                hasObservedColors: true
            )
        )
        let geometryOnlySurface = SavedProcessedSurfacePresentation(
            surface: ProcessedSurfaceLOD(
                prefix: prefix,
                sourceVertexCount: 3,
                sourceTriangleCount: 1,
                vertices: coloredSurface.surface.vertices,
                normals: coloredSurface.surface.normals,
                colors: Array(repeating: nil, count: 3),
                indices: [0, 1, 2],
                robustBounds: bounds,
                hasObservedColors: false
            )
        )
        let coloredPointCloud = SavedPointCloudPresentation(
            source: PointCloudPLYReadResult(
                header: PointCloudPLYHeader(vertexCount: 1, containsRGBColor: true),
                points: [
                    PointCloudPLYPoint(
                        position: Point3D(x: 0, y: 0, z: 0),
                        confidence: 2,
                        color: PointCloudColor(red: 90, green: 100, blue: 110)
                    )
                ]
            ),
            observedColors: [MeshVertexColor(red: 90, green: 100, blue: 110)]
        )

        XCTAssertEqual(
            SavedScanWorkspacePresentation.preferredSurface(
                processedSurface: .available(coloredSurface),
                pointCloudState: .available(coloredPointCloud),
                hasPointCloud: true,
                hasRawMesh: true,
                hasSemanticRoom: true
            ),
            .processedSurface
        )
        XCTAssertEqual(
            SavedScanWorkspacePresentation.preferredSurface(
                processedSurface: .available(geometryOnlySurface),
                pointCloudState: .available(coloredPointCloud),
                hasPointCloud: true,
                hasRawMesh: true,
                hasSemanticRoom: true
            ),
            .pointCloud
        )
        XCTAssertEqual(
            SavedScanWorkspacePresentation.preferredSurface(
                processedSurface: .available(geometryOnlySurface),
                pointCloudState: .unavailable(message: "missing"),
                hasPointCloud: true,
                hasRawMesh: true,
                hasSemanticRoom: false
            ),
            .processedSurface
        )
        XCTAssertEqual(
            SavedScanWorkspacePresentation.preferredSurface(
                processedSurface: .unavailable(message: "missing"),
                pointCloudState: .unavailable(message: "missing"),
                hasPointCloud: false,
                hasRawMesh: true,
                hasSemanticRoom: false
            ),
            .rawMesh
        )
    }

    @MainActor
    func testProcessedSurfaceSceneUsesPromotedRobustBoundsForCameraFraming() throws {
        let robustBounds = try TSDFSurfaceBounds(
            minimum: Point3D(x: 100, y: 10, z: 20),
            maximum: Point3D(x: 102, y: 12, z: 22)
        )
        let surface = ProcessedSurfaceLOD(
            prefix: makeProcessedSurfacePrefix(),
            sourceVertexCount: 3,
            sourceTriangleCount: 1,
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: Array(repeating: Point3D(x: 0, y: 0, z: 1), count: 3),
            colors: Array(repeating: nil, count: 3),
            indices: [0, 1, 2],
            robustBounds: robustBounds,
            hasObservedColors: false
        )

        let scene = ProcessedSurfaceSceneBuilder.makeScene(from: surface)
        let camera = try XCTUnwrap(
            scene.rootNode.childNode(withName: "processed-surface-camera", recursively: true)
        )

        XCTAssertGreaterThan(camera.position.x, 100)
        XCTAssertGreaterThan(camera.position.y, 10)
        XCTAssertGreaterThan(camera.position.z, 20)
        XCTAssertNotNil(scene.rootNode.childNode(withName: "processed-surface", recursively: true))
    }

    func testSavedWorkspaceRemapsColorsOntoSanitizedMeshPresentation() throws {
        let anchorID = UUID()
        let source = try MeshSnapshot(
            anchorID: anchorID,
            worldFromAnchor: .translation(x: 3, y: 4, z: 5),
            vertices: [
                Point3D(x: -1, y: -1, z: 0),
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (1, 2, 3))]
        )
        let firstColor = MeshVertexColor(red: 10, green: 20, blue: 30)
        let lastColor = MeshVertexColor(red: 40, green: 50, blue: 60)
        let sourceColors: [MeshVertexColor?] = [nil, firstColor, nil, lastColor]

        let presentation = SavedRawMeshPresentationBuilder.make(
            snapshots: [source],
            vertexColors: [anchorID: sourceColors]
        )

        XCTAssertEqual(presentation.snapshots.count, 1)
        XCTAssertEqual(presentation.snapshots[0].worldFromAnchor, source.worldFromAnchor)
        XCTAssertEqual(presentation.snapshots[0].vertices, Array(source.vertices.dropFirst()))
        XCTAssertEqual(presentation.snapshots[0].faces, [MeshFace(indices: (0, 1, 2))])
        XCTAssertEqual(
            presentation.vertexColors[anchorID],
            Optional([firstColor, nil, lastColor])
        )
        XCTAssertEqual(source.vertices.count, 4)
        XCTAssertEqual(source.faces, [MeshFace(indices: (1, 2, 3))])
    }

    @MainActor
    func testRawMeshSceneBuilderBoundsCameraFrustumsWithoutInventingCameraPoses() throws {
        let snapshot = try makeTestMeshSnapshot()
        let frustums = (0..<12).map { index in
            makeTestCameraFrustum(
                id: index,
                worldFromCamera: .translation(x: Float(index), y: 0, z: 0)
            )
        }

        let scene = RawMeshSceneBuilder.makeScene(
            from: [snapshot],
            cameraFrustums: frustums
        )
        let nodes = cameraFrustumNodes(in: scene)
        let xPositions = nodes.map(\.position.x).sorted()
        let firstNode = try XCTUnwrap(nodes.first)

        XCTAssertEqual(nodes.count, 6)
        XCTAssertEqual(xPositions, [0, 2, 4, 6, 8, 11])
        XCTAssertEqual(firstNode.boundingBox.min.z, -0.12, accuracy: 0.0001)
        XCTAssertEqual(firstNode.boundingBox.max.z, 0, accuracy: 0.0001)
    }

    @MainActor
    func testRawMeshSceneBuilderSuppressesNearbyRetainedCameraDuplicates() throws {
        let snapshot = try makeTestMeshSnapshot()
        let frustums = [0, 0.1, 0.2, 0.6, 0.7].enumerated().map { index, x in
            makeTestCameraFrustum(
                id: index,
                worldFromCamera: .translation(x: Float(x), y: 0, z: 0)
            )
        }

        let scene = RawMeshSceneBuilder.makeScene(
            from: [snapshot],
            cameraFrustums: frustums
        )

        XCTAssertEqual(cameraFrustumNodes(in: scene).map(\.position.x).sorted(), [0, 0.6])
    }

    @MainActor
    func testRawMeshSceneBuilderUsesMatteLightingWhenNormalsExist() throws {
        let snapshot = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: 0), Point3D(x: 1, y: 0, z: 0), Point3D(x: 0, y: 1, z: 0)],
            normals: [Point3D(x: 0, y: 0, z: 1), Point3D(x: 0, y: 0, z: 1), Point3D(x: 0, y: 0, z: 1)],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
        let material = RawMeshSceneBuilder.makeScene(from: [snapshot])
            .rootNode.childNodes.first(where: { $0.geometry != nil })?.geometry?.firstMaterial
        XCTAssertEqual(material?.lightingModel, .physicallyBased)
    }

    @MainActor
    func testRawMeshSceneBuilderFramesDenseGeometryDespiteDistantAnchor() throws {
        var nearbyVertices: [Point3D] = []
        nearbyVertices.reserveCapacity(30)
        for index in 0..<30 {
            nearbyVertices.append(
                Point3D(
                    x: Float(index % 5) * 0.1,
                    y: Float(index / 5) * 0.1,
                    z: Float(index % 3) * 0.1
                )
            )
        }
        let nearby = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: nearbyVertices,
            normals: [],
            faces: []
        )
        let distant = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .translation(x: 1_000, y: 1_000, z: 1_000),
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 0.1, y: 0, z: 0),
                Point3D(x: 0, y: 0.1, z: 0)
            ],
            normals: [],
            faces: []
        )

        let scene = RawMeshSceneBuilder.makeScene(from: [nearby, distant])
        guard let camera = scene.rootNode.childNodes.first(where: { $0.camera != nil }) else {
            return XCTFail("Expected an initial camera")
        }

        XCTAssertLessThan(camera.position.x, 10)
        XCTAssertLessThan(camera.position.y, 10)
        XCTAssertLessThan(camera.position.z, 10)
    }

#if canImport(ARKit)
    @MainActor
    func testLivePreviewDoesNotDisplaceCaptureSessionDelegate() {
        let session = ARSession()
        let captureDelegate = ARSessionDelegateProbe()
        session.delegate = captureDelegate

        let preview = ARSCNView(frame: .zero)
        preview.session = session

        XCTAssertTrue(session.delegate === captureDelegate)
    }
#endif

    func testEnglishPresentationUsesLatinDigitsAndDurationUnits() {
        XCTAssertEqual(EnglishFormat.duration(seconds: 125), "2 min 5 sec")
        XCTAssertEqual(EnglishFormat.byteCount(148_000_000), "148 MB")
        XCTAssertEqual(EnglishFormat.byteCount(999_999), "1 MB")
        XCTAssertEqual(EnglishFormat.byteCount(1_000_000_000_000), "1 TB")
        XCTAssertEqual(EnglishFormat.number(1_234), "1,234")
        XCTAssertEqual(EnglishFormat.duration(seconds: -1), "0 sec")
        XCTAssertEqual(EnglishFormat.locale.language.languageCode?.identifier, "en")
        XCTAssertTrue(EnglishFormat.dateTime(Date(timeIntervalSince1970: 0)).contains("1970"))
    }

    @MainActor
    func testNormalCompositionUsesLocalServices() throws {
        let rootURL = try makeTemporaryDirectory()
        try assertNormalCompositionUsesLocalServices(rootURL: rootURL)
        try FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testUITestingArgumentsSelectDeterministicDemoComposition() {
        let composition = AppComposition.make(arguments: ["-uiTesting"])

        XCTAssertTrue(composition.isDemo)
        XCTAssertTrue(composition.libraryService is DemoScanLibraryService)
        XCTAssertTrue(composition.detailService is DemoScanDetailService)
        XCTAssertTrue(composition.scannerService is DemoScannerWorkflowService)
    }

    @MainActor
    func testLiveScannerRequestsCameraOnlyAfterExplicitCommand() async throws {
        let rootURL = try makeTemporaryDirectory()
        try await assertLiveScannerRequestsCameraOnlyAfterExplicitCommand(rootURL: rootURL)
        try FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    private func assertLiveScannerRequestsCameraOnlyAfterExplicitCommand(rootURL: URL) async throws {
        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .notDetermined)
        )
        let service = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await service.begin()
        let permissionRequired = await service.resolveCapabilities()

        XCTAssertEqual(permissionRequired.lifecycle, .requestingPermissions)
        XCTAssertEqual(permissionRequired.capability, .requiresCameraPermission)
        XCTAssertEqual(adapter.cameraAuthorizationRequestCount, 0)

        let ready = await service.perform(.requestCameraPermission)

        XCTAssertEqual(adapter.cameraAuthorizationRequestCount, 1)
        XCTAssertEqual(ready.lifecycle, .ready)
        XCTAssertEqual(ready.capability, .available([]))
        XCTAssertFalse(ready.isDemo)
    }

    @MainActor
    func testLiveScannerFinalizesLocalPackageAndLibraryReadsActualSize() async throws {
        let rootURL = try makeTemporaryDirectory()
        try await assertLiveScannerFinalizesLocalPackageAndLibraryReadsActualSize(rootURL: rootURL)
        try FileManager.default.removeItem(at: rootURL)
    }

    @MainActor
    func testLiveScannerRejectsAnEmptySpatialCaptureWithoutCreatingAScan() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: TestCaptureAdapter(
                capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized)
            )
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        let scanning = await scanner.perform(.startPreview)
        let stillScanning = await scanner.perform(.finishPreview)
        let cancelled = await scanner.perform(.cancel)
        let savedScans = try await stores.repository.list()
        let captureWorkDirectory = stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory)
        let stagedDirectories = (try? FileManager.default.contentsOfDirectory(
            at: captureWorkDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        XCTAssertEqual(scanning.lifecycle, .scanning)
        XCTAssertEqual(stillScanning.lifecycle, .scanning)
        XCTAssertEqual(stillScanning.rawCoverage, .waitingForSpatialData)
        XCTAssertEqual(cancelled.lifecycle, .cancelled)
        XCTAssertTrue(savedScans.isEmpty)
        XCTAssertTrue(stagedDirectories.isEmpty)
    }

    @MainActor
    func testLiveScannerFinalizesSpatialScanWithoutContinuousVideo() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.mesh(try makeReadyTestMeshSnapshot())]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let readyToFinish = await waitForScannerSnapshot(scanner) {
            $0.canFinishActiveCapture
        }
        let processing = await scanner.perform(.finishPreview)

        XCTAssertTrue(readyToFinish.canFinishActiveCapture)
        XCTAssertEqual(processing.lifecycle, .processing)
        XCTAssertEqual(processing.pendingReview?.artifacts.map(\.kind), [.frameMetadata, .meshRaw, .pointCloud])
        XCTAssertEqual(adapter.videoConfigurationCount, 0)
    }

    @MainActor
    func testRawFinalizationConsumesTerminalMeshReplacement() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let anchorID = UUID()
        let initialMesh = try makeReadyTestMeshSnapshot(anchorID: anchorID)
        let finalMesh = try makeTestMeshSnapshot(anchorID: anchorID)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.mesh(initialMesh)],
            eventsOnStop: [.mesh(finalMesh)]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        _ = await waitForScannerSnapshot(scanner) { $0.canFinishActiveCapture }
        let processing = await scanner.perform(.finishPreview)

        XCTAssertEqual(processing.pendingReview?.statistics.meshVertexCount, finalMesh.vertices.count)
        XCTAssertEqual(processing.pendingReview?.statistics.meshFaceCount, finalMesh.faces.count)
    }

    @MainActor
    func testEssentialPersistenceSurvivesDisposableStreamPressure() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let anchorID = UUID()
        let liveMesh = try makeReadyTestMeshSnapshot(anchorID: anchorID)
        let finalMesh = try makeTestMeshSnapshot(anchorID: anchorID)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: Array(repeating: .mesh(liveMesh), count: 100),
            eventsOnStop: [.meshRegistrySnapshot([finalMesh])],
            presentationBufferLimit: 1
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        _ = await waitForScannerSnapshot(scanner) { $0.canFinishActiveCapture }
        let processing = await scanner.perform(.finishPreview)

        XCTAssertEqual(processing.lifecycle, .processing)
        XCTAssertEqual(processing.pendingReview?.statistics.meshVertexCount, finalMesh.vertices.count)
        XCTAssertEqual(processing.pendingReview?.statistics.meshFaceCount, finalMesh.faces.count)
    }

    @MainActor
    func testRawCaptureCoverageReportsOnlyObservedMesh() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let mesh = try makeTestMeshSnapshot()
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: TestCaptureAdapter(
                capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
                eventsOnStart: [.mesh(mesh)]
            )
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let observed = await waitForScannerSnapshot(scanner) {
            $0.rawCoverage == .meshObserved(meshAnchorCount: 1)
        }

        XCTAssertEqual(observed.lifecycle, .scanning)
        XCTAssertEqual(observed.rawCoverage, .meshObserved(meshAnchorCount: 1))
        XCTAssertEqual(observed.rawObservationFootprint, .broadObservedSurface)
    }

    @MainActor
    func testRawCaptureFootprintExpandsOnlyWhenObservedMeshExpands() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.mesh(try makeMeshFragment(faceCount: 6, translatedX: 0))]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let initial = await waitForScannerSnapshot(scanner) {
            $0.rawObservationFootprint == .initialSurface
        }

        adapter.emit(.mesh(try makeMeshFragment(faceCount: 6, translatedX: 0.6)))
        let expanded = await waitForScannerSnapshot(scanner) {
            $0.rawObservationFootprint == .expandingSurface
        }

        XCTAssertEqual(initial.rawObservationFootprint, .initialSurface)
        XCTAssertEqual(expanded.rawObservationFootprint, .expandingSurface)
    }

    @MainActor
    func testRawFinishRequiresGeometryBeyondASmallMeshFragment() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let anchorID = UUID()
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.mesh(try makeTestMeshSnapshot(anchorID: anchorID))]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let fragment = await waitForScannerSnapshot(scanner) {
            $0.rawCoverage == .meshObserved(meshAnchorCount: 1)
        }
        let rejectedFinish = await scanner.perform(.finishPreview)

        adapter.emit(.mesh(try makeReadyTestMeshSnapshot(anchorID: anchorID)))
        let ready = await waitForScannerSnapshot(scanner) {
            $0.canFinishActiveCapture
        }

        XCTAssertEqual(fragment.rawReadiness, .gatheringGeometry)
        XCTAssertFalse(fragment.canFinishActiveCapture)
        XCTAssertEqual(rejectedFinish.lifecycle, .scanning)
        XCTAssertEqual(ready.rawReadiness, .readyToFinish)
        XCTAssertTrue(ready.canFinishActiveCapture)
    }

    @MainActor
    func testRawFinishAllowsTwoObservedMeshSurfaces() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.mesh(try makeMeshFragment(faceCount: 6, translatedX: 0))]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let fragment = await waitForScannerSnapshot(scanner) {
            $0.rawCoverage == .meshObserved(meshAnchorCount: 1)
        }

        adapter.emit(.mesh(try makeMeshFragment(faceCount: 6, translatedX: 0.2)))
        let ready = await waitForScannerSnapshot(scanner) {
            $0.canFinishActiveCapture
        }

        XCTAssertFalse(fragment.canFinishActiveCapture)
        XCTAssertEqual(ready.rawCoverage, .meshObserved(meshAnchorCount: 2))
        XCTAssertTrue(ready.canFinishActiveCapture)
    }

    @MainActor
    func testRawCaptureGuidanceUsesObservedDepthInsteadOfAQualityScore() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let metadata = FrameMetadata(
            timestamp: 1,
            videoTimestamp: nil,
            imageWidth: 2,
            imageHeight: 2,
            intrinsics: CameraIntrinsics(imageWidth: 2, imageHeight: 2, fx: 1, fy: 1, cx: 1, cy: 1),
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: false
        )
        let depth = DepthFrameSample(
            width: 2,
            height: 2,
            depthMeters: [0.12, 0.14, 0.13, 0.15],
            confidence: [2, 2, 2, 2],
            calibration: metadata.intrinsics,
            worldFromCamera: .identity,
            timestamp: 1
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: TestCaptureAdapter(
                capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
                eventsOnStart: [.frame(CaptureFramePacket(metadata: metadata, depth: depth, featurePoints: []))]
            )
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let guided = await waitForScannerSnapshot(scanner) {
            $0.rawGuidance == .moveFarther
        }

        XCTAssertEqual(guided.rawCoverage, .depthObserved)
        XCTAssertEqual(guided.rawGuidance, .moveFarther)
    }

    @MainActor
    func testLiveRawCaptureResumesAdapterExactlyOnce() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized))
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        _ = await scanner.perform(.pausePreview)
        let resumed = await scanner.perform(.resumePreview)

        XCTAssertEqual(resumed.lifecycle, .scanning)
        XCTAssertEqual(adapter.resumeCount, 1)
        XCTAssertEqual(adapter.videoConfigurationCount, 0)
    }

    @MainActor
    func testTrackingRecoveryDoesNotRestartAnActiveARSession() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.tracking(.notAvailable)]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let trackingLost = await waitForScannerSnapshot(scanner) {
            $0.lifecycle == .trackingLost
        }
        let afterRecoveryRequest = await scanner.perform(.recoverTracking)

        XCTAssertEqual(trackingLost.lifecycle, .trackingLost)
        XCTAssertEqual(afterRecoveryRequest.lifecycle, .trackingLost)
        XCTAssertEqual(adapter.resumeCount, 0)
    }

    @MainActor
    func testRequiredSensorFailureIsPresentedAsRetryableCameraProblem() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.failed("sensorUnavailable")]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let failed = await waitForScannerSnapshot(scanner) {
            $0.lifecycle == .failed(.sensorUnavailable)
        }
        XCTAssertEqual(failed.lifecycle, .failed(.sensorUnavailable))
    }

    @MainActor
    func testLiveSemanticRoomCapturePersistsOnlyRoomPlanUSDZ() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let rawAdapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized)
        )
        let semanticAdapter = TestSemanticRoomCaptureAdapter()
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: rawAdapter,
            semanticCaptureAdapter: semanticAdapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        let semanticReady = await scanner.perform(.selectCaptureMode(.semanticRoom))
        let scanning = await scanner.perform(.startPreview)
        let readyToFinish = await waitForScannerSnapshot(scanner) {
            $0.canFinishActiveCapture
        }
        let processing = await scanner.perform(.finishPreview)
        guard let review = processing.pendingReview else {
            return XCTFail("Expected a semantic-room review before saving")
        }
        let saving = await scanner.perform(.finishProcessing)
        let completed = await scanner.perform(.finishSaving)

        XCTAssertEqual(semanticReady.captureMode, .semanticRoom)
        XCTAssertEqual(semanticReady.lifecycle, .ready)
        XCTAssertEqual(scanning.lifecycle, .scanning)
        XCTAssertTrue(readyToFinish.canFinishActiveCapture)
        XCTAssertEqual(processing.lifecycle, .processing)
        XCTAssertEqual(processing.completedScanID, nil)
        XCTAssertEqual(review.captureMode, .semanticRoom)
        XCTAssertEqual(review.artifacts.map(\.kind), [.semanticRoom])
        XCTAssertEqual(review.artifacts.map(\.relativePath), ["room/semantic-room.usdz"])
        XCTAssertGreaterThan(review.totalByteCount, 0)
        XCTAssertEqual(saving.lifecycle, .saving)
        XCTAssertEqual(saving.pendingReview, review)
        XCTAssertEqual(saving.completedScanID, nil)
        XCTAssertEqual(completed.lifecycle, .completed)
        XCTAssertNil(completed.pendingReview)
        XCTAssertEqual(completed.completedScanID, review.id)
        XCTAssertEqual(rawAdapter.startCount, 0)
        XCTAssertEqual(rawAdapter.videoConfigurationCount, 0)
        XCTAssertEqual(semanticAdapter.startCount, 1)
        XCTAssertEqual(semanticAdapter.finishCount, 1)

        let savedMetadata = try await stores.repository.list()
        guard let savedID = savedMetadata.first?.id,
              let storedScan = try await stores.repository.reopen(id: savedID)
        else {
            return XCTFail("Expected the saved semantic room package")
        }

        XCTAssertEqual(savedID, review.id)
        XCTAssertTrue(storedScan.integrity.isValid)
        XCTAssertEqual(storedScan.manifest.assets.map(\.kind), [.semanticRoom])
        XCTAssertEqual(storedScan.manifest.assets.first?.relativePath, "room/semantic-room.usdz")
        XCTAssertEqual(storedScan.manifest.assets.first?.spatialReference, .scanLocal)
        XCTAssertEqual(
            storedScan.manifest.coordinateSystem,
            "RoomPlan semantic room coordinates; no ARKit world transform is inferred."
        )
        XCTAssertEqual(
            storedScan.manifest.cameraMetadataDescription,
            "No raw ARKit frame metadata is retained for this semantic room capture."
        )

        let detailService = LocalScanDetailService(repository: stores.repository, assetStore: stores.assetStore)
        guard case let .success(detail) = await detailService.loadDetail(id: storedScan.scan.id) else {
            return XCTFail("Expected semantic room detail")
        }
        XCTAssertEqual(detail.exportableAssets.map(\.reference.kind), [.semanticRoom])
        XCTAssertTrue(FileManager.default.fileExists(atPath: detail.exportableAssets[0].url.path))
    }

    @MainActor
    func testSemanticCancellationWaitsForFinalizationBeforeDiscardingStaging() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let semanticAdapter = SuspendingSemanticRoomCaptureAdapter()
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: TestCaptureAdapter(
                capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized)
            ),
            semanticCaptureAdapter: semanticAdapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.selectCaptureMode(.semanticRoom))
        let scanning = await scanner.perform(.startPreview)
        XCTAssertEqual(scanning.lifecycle, .scanning)

        let finishing = Task { await scanner.perform(.finishPreview) }
        await semanticAdapter.waitForFinishToStart()

        let cancelling = Task { await scanner.perform(.cancel) }
        await Task.yield()
        XCTAssertEqual(semanticAdapter.cancelCount, 0)

        semanticAdapter.completeFinish()
        await semanticAdapter.waitForCancellationToStart()

        let captureWorkRoot = stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory)
        let stagingDirectoriesWhileCancellationIsPending = (try? FileManager.default.contentsOfDirectory(
            at: captureWorkRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        XCTAssertEqual(
            semanticAdapter.operationOrder,
            [.finishStarted, .finishCompleted, .cancellationStarted]
        )
        XCTAssertEqual(stagingDirectoriesWhileCancellationIsPending.count, 1)

        semanticAdapter.completeCancellation()
        let processing = await finishing.value
        let cancelled = await cancelling.value
        let remainingStagingDirectories = (try? FileManager.default.contentsOfDirectory(
            at: captureWorkRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        XCTAssertEqual(processing.lifecycle, .processing)
        XCTAssertEqual(cancelled.lifecycle, .cancelled)
        XCTAssertEqual(semanticAdapter.operationOrder.last, .cancellationCompleted)
        XCTAssertTrue(remainingStagingDirectories.isEmpty)
    }

    @MainActor
    func testRawCancellationCancelsVideoRecordingBeforeRemovingStaging() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized)
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let cancellationsBeforeDiscard = adapter.cancelVideoRecordingCount
        let cancelled = await scanner.perform(.cancel)
        let captureWorkRoot = stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory)
        let remainingStagingDirectories = (try? FileManager.default.contentsOfDirectory(
            at: captureWorkRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        XCTAssertEqual(cancelled.lifecycle, .cancelled)
        XCTAssertEqual(adapter.cancelVideoRecordingCount, cancellationsBeforeDiscard + 1)
        XCTAssertTrue(remainingStagingDirectories.isEmpty)
    }

    @MainActor
    private func assertLiveScannerFinalizesLocalPackageAndLibraryReadsActualSize(rootURL: URL) async throws {
        let stores = try makeLocalStores(rootURL: rootURL)
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [.mesh(try makeReadyTestMeshSnapshot())]
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )
        let library = LocalScanLibraryService(repository: stores.repository, assetStore: stores.assetStore)

        _ = await scanner.begin()
        let ready = await scanner.resolveCapabilities()
        XCTAssertEqual(ready.lifecycle, .ready)

        let scanning = await scanner.perform(.startPreview)
        let readyToFinish = await waitForScannerSnapshot(scanner) {
            $0.canFinishActiveCapture
        }
        let processing = await scanner.perform(.finishPreview)
        guard let review = processing.pendingReview else {
            return XCTFail("Expected a raw LiDAR review before saving")
        }
        let saving = await scanner.perform(.finishProcessing)
        let completed = await scanner.perform(.finishSaving)

        XCTAssertEqual(scanning.lifecycle, .scanning)
        XCTAssertTrue(readyToFinish.canFinishActiveCapture)
        XCTAssertEqual(processing.lifecycle, .processing)
        XCTAssertEqual(processing.completedScanID, nil)
        XCTAssertEqual(review.captureMode, .rawLiDAR)
        XCTAssertEqual(review.artifacts.map(\.kind), [.frameMetadata, .meshRaw, .pointCloud])
        XCTAssertEqual(
            review.artifacts.map(\.relativePath),
            ["frames/frame-metadata.ndjson", "mesh/raw-mesh.json", "pointcloud/cloud.ply"]
        )
        XCTAssertGreaterThan(review.totalByteCount, 0)
        XCTAssertEqual(saving.lifecycle, .saving)
        XCTAssertEqual(saving.pendingReview, review)
        XCTAssertEqual(saving.completedScanID, nil)
        XCTAssertEqual(completed.lifecycle, .completed)
        XCTAssertNil(completed.pendingReview)
        XCTAssertEqual(completed.completedScanID, review.id)

        guard case let .success(items) = await library.loadLibrary(), let item = items.first else {
            return XCTFail("Expected the saved local scan in the library")
        }

        let storedScan = try await stores.repository.reopen(id: item.id)
        let packageBytes = try await stores.assetStore.packageByteCount(id: item.id)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.id, review.id)
        XCTAssertEqual(item.scan.status, .completed)
        XCTAssertEqual(
            item.storageByteCount,
            packageBytes
        )
        XCTAssertGreaterThan(packageBytes, 0)
        XCTAssertTrue(storedScan?.integrity.isValid == true)
        XCTAssertEqual(storedScan?.manifest.assets.count, 5)
        XCTAssertEqual(
            storedScan?.manifest.assets
                .filter { $0.kind == .manifestAttachment }
                .map(\.relativePath),
            ["capture/keyframes/index.ndjson", "capture/spatial-chunks.bin"]
        )
        XCTAssertEqual(adapter.startCount, 1)
        XCTAssertEqual(adapter.finishKeyframeCaptureCount, 1)
    }

    @MainActor
    func testSuccessfulRawSaveEnqueuesEligibleReconstructionAfterArchiveVerification() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let stores = try makeLocalStores(rootURL: rootURL)
        let metadata = FrameMetadata(
            timestamp: 1,
            videoTimestamp: nil,
            imageWidth: 1,
            imageHeight: 1,
            intrinsics: CameraIntrinsics(imageWidth: 1, imageHeight: 1, fx: 1, fy: 1, cx: 0, cy: 0),
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: true
        )
        let depth = DepthFrameSample(
            width: 1,
            height: 1,
            depthMeters: [1],
            confidence: [2],
            observedColors: [PointCloudColor(red: 20, green: 40, blue: 60)],
            calibration: metadata.intrinsics,
            worldFromCamera: .identity,
            timestamp: 1
        )
        let admissionEvidence = CalibratedKeyframeEvidence(
            timestamp: 1,
            confidenceRatio: 1,
            overlapRatio: 0,
            newCoverageRatio: 1,
            poseBaselineMeters: 0,
            cadenceSeconds: 0
        )
        let evidenceContract = CaptureEvidenceContract(
            source: .arkitWorldTracking,
            depthSource: .smoothedSceneDepth,
            rgbSource: .capturedImageNearestNeighborToDepthGrid,
            synchronization: .sameARFrame,
            timestamps: CaptureEvidenceTimestamps(
                capture: 1,
                cameraImage: 1,
                depth: 1,
                confidence: 1,
                pose: 1,
                maximumSourceDeltaSeconds: 0
            ),
            cameraImageWidth: 1,
            cameraImageHeight: 1,
            depthWidth: 1,
            depthHeight: 1,
            exposure: CaptureExposureEvidence(
                availability: .measured,
                exposureDurationSeconds: 0.01,
                exposureTargetOffsetEV: 0,
                sampledLuminanceMean: 0.5,
                sampledLuminanceVariance: 0.1,
                sampledAdjacentDifference: 0.1
            ),
            acceptanceEvidence: admissionEvidence
        )
        let coordinator = RecordingAppReconstructionCoordinator()
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [
                .frame(
                    CaptureFramePacket(
                        metadata: metadata,
                        depth: depth,
                        featurePoints: [],
                        calibratedKeyframe: CalibratedRGBDKeyframeSample(
                            metadata: metadata,
                            depth: depth,
                            acceptanceReason: .initialFrame,
                            evidence: admissionEvidence,
                            evidenceContract: evidenceContract
                        ),
                        textureSourceImageData: try makeTestJPEG(),
                        thumbnailImageData: nil
                    )
                ),
                .mesh(try makeReadyTestMeshSnapshot())
            ]
        )
        let sourceDevice = SourceDeviceInfo(
            modelIdentifier: "iPhone18,4",
            operatingSystemVersion: "iOS 26.6.1",
            appVersion: "2.0 (42)"
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            assetStore: stores.assetStore,
            captureWorkingRootURL: rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter,
            reconstructionCoordinator: coordinator,
            sourceDeviceInfo: sourceDevice
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        _ = await waitForScannerSnapshot(scanner) { $0.canFinishActiveCapture }
        _ = await scanner.perform(.finishPreview)
        _ = await scanner.perform(.finishProcessing)
        let completed = await scanner.perform(.finishSaving)

        let scanID = try XCTUnwrap(completed.completedScanID)
        let enqueuedScanIDs = await coordinator.enqueuedScanIDs()
        let stored = try await stores.repository.reopen(id: scanID)
        let finalized = try XCTUnwrap(stored)
        let packageURL = try await stores.assetStore.packageURL(for: scanID)
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: finalized.manifest,
            integrity: finalized.integrity
        )
        XCTAssertEqual(enqueuedScanIDs, [scanID])
        XCTAssertGreaterThan(archive.reconstructionSource.keyframeCount, 0)
        XCTAssertTrue(finalized.integrity.isValid)
        XCTAssertEqual(finalized.manifest.sourceDevice, sourceDevice)
    }

    func testReopenWithoutRGBDArchiveKeepsFallbackAndStopsAutomaticRetry() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let stores = try makeLocalStores(rootURL: rootURL)
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Legacy fallback",
            status: .completed,
            createdAt: .now,
            updatedAt: .now
        )
        try await stores.repository.save(
            scan: scan,
            manifest: ScanPackageManifest(
                localScanID: scan.id,
                status: .completed,
                createdAt: scan.createdAt,
                updatedAt: scan.updatedAt
            ),
            assets: [
                AssetInput(
                    kind: .pointCloud,
                    relativePath: "pointcloud/cloud.ply",
                    data: Data("ply\nformat ascii 1.0\nelement vertex 0\nend_header\n".utf8),
                    spatialReference: .arWorld
                )
            ]
        )
        let processingRoot = rootURL.appending(path: "processing", directoryHint: .isDirectory)
        let derivedRoot = rootURL.appending(path: "derived", directoryHint: .isDirectory)
        let processedStore = try ProcessedSurfaceStore(
            rootURL: derivedRoot,
            processingRootURL: processingRoot
        )
        let runner = LocalScanReconstructionRunner(
            repository: stores.repository,
            assetStore: stores.assetStore,
            processedSurfaceStore: processedStore,
            processingRootURL: processingRoot,
            derivedRootURL: derivedRoot
        )
        let coordinator = try ScanReconstructionCoordinator(
            runner: runner,
            resourceMonitor: SystemScanReconstructionResourceMonitor(volumeURL: rootURL),
            processingRootURL: processingRoot,
            minimumAvailableStorageBytes: 1
        )
        let service = LocalScanDetailService(
            repository: stores.repository,
            assetStore: stores.assetStore,
            processedSurfaceStore: processedStore,
            reconstructionCoordinator: coordinator
        )

        guard case let .success(detail) = await service.loadDetail(id: scan.id) else {
            return XCTFail("Expected the legacy scan detail")
        }
        let finalStatus = await waitForReconstructionStatus(coordinator, scanID: scan.id) {
            $0.stage == .unavailable
        }
        _ = await service.loadDetail(id: scan.id)
        let startedJobCount = await coordinator.startedJobCount()

        XCTAssertEqual(detail.capabilities.capability(for: .pointCloud)?.availability, .available)
        XCTAssertEqual(finalStatus.failureCategory, .missingArchive)
        XCTAssertEqual(startedJobCount, 1)
    }

    @MainActor
    func testRawFinishDrainsSelectedKeyframeBeforeFinalizingPackage() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let stores = try makeLocalStores(rootURL: rootURL)
        let keyframeMetadata = FrameMetadata(
            timestamp: 1,
            videoTimestamp: nil,
            imageWidth: 1,
            imageHeight: 1,
            intrinsics: CameraIntrinsics(imageWidth: 1, imageHeight: 1, fx: 1, fy: 1, cx: 0, cy: 0),
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: true
        )
        let jpeg = try makeTestJPEG()
        let adapter = TestCaptureAdapter(
            capabilities: DeviceCapabilities.supported(cameraAuthorization: .authorized),
            eventsOnStart: [
                .frame(
                    CaptureFramePacket(
                        metadata: keyframeMetadata,
                        depth: nil,
                        featurePoints: [],
                        textureSourceImageData: jpeg,
                        thumbnailImageData: jpeg
                    )
                ),
                .mesh(try makeReadyTestMeshSnapshot())
            ],
            eventsOnStop: []
        )
        let scanner = LocalScannerWorkflowService(
            repository: stores.repository,
            captureWorkingRootURL: stores.rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
            captureAdapter: adapter
        )

        _ = await scanner.begin()
        _ = await scanner.resolveCapabilities()
        _ = await scanner.perform(.startPreview)
        let readyToFinish = await waitForScannerSnapshot(scanner) {
            $0.canFinishActiveCapture
        }
        let processing = await scanner.perform(.finishPreview)

        XCTAssertTrue(readyToFinish.canFinishActiveCapture)
        XCTAssertEqual(processing.lifecycle, .processing)
        XCTAssertEqual(adapter.finishKeyframeCaptureCount, 1)
        XCTAssertEqual(
            processing.pendingReview?.artifacts.map(\.kind),
            [.frameMetadata, .textureSource, .meshRaw, .pointCloud, .thumbnail]
        )

        let saving = await scanner.perform(.finishProcessing)
        let completed = await scanner.perform(.finishSaving)
        let detailService = LocalScanDetailService(repository: stores.repository, assetStore: stores.assetStore)
        guard let scanID = completed.completedScanID,
              case let .success(detail) = await detailService.loadDetail(id: scanID)
        else {
            return XCTFail("Expected the saved scan detail")
        }

        XCTAssertEqual(saving.lifecycle, .saving)
        XCTAssertEqual(completed.lifecycle, .completed)
        XCTAssertEqual(detail.retainedKeyframeURLs.count, 1)
        XCTAssertEqual(detail.workspaceKeyframeURLs, detail.retainedKeyframeURLs)
        XCTAssertEqual(try Data(contentsOf: detail.retainedKeyframeURLs[0]), jpeg)
    }

    func testSavedDetailBoundsWorkspaceKeyframeGalleryToEvenlyDistributedSourceImages() {
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Keyframes",
            status: .completed,
            createdAt: .now,
            updatedAt: .now
        )
        let assets = (0..<12).map { index in
            ScanExportAsset(
                reference: ScanAssetReference(
                    kind: .textureSource,
                    relativePath: String(format: "frames/keyframe-%02d.jpg", index),
                    byteCount: 1,
                    sha256: "valid"
                ),
                url: URL(filePath: "/tmp/keyframe-\(index).jpg")
            )
        } + [
            ScanExportAsset(
                reference: ScanAssetReference(
                    kind: .video,
                    relativePath: "video/capture.mov",
                    byteCount: 1,
                    sha256: "valid"
                ),
                url: URL(filePath: "/tmp/capture.mov")
            )
        ]
        let detail = SavedScanDetail(
            scan: scan,
            manifest: ScanPackageManifest(
                localScanID: scan.id,
                status: .completed,
                createdAt: scan.createdAt,
                updatedAt: scan.updatedAt
            ),
            integrity: PackageIntegrityReport(scanID: scan.id),
            rawMesh: .available([]),
            exportableAssets: assets
        )

        XCTAssertEqual(detail.retainedKeyframeURLs.count, 12)
        XCTAssertEqual(detail.workspaceKeyframeURLs.count, 8)
        XCTAssertEqual(
            detail.workspaceKeyframeURLs.map(\.lastPathComponent),
            [
                "keyframe-0.jpg", "keyframe-1.jpg", "keyframe-3.jpg", "keyframe-4.jpg",
                "keyframe-6.jpg", "keyframe-7.jpg", "keyframe-9.jpg", "keyframe-11.jpg"
            ]
        )
    }

    func testSavedSemanticRoomDetailExposesItsVerifiedUSDZForWorkspacePreview() {
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Room",
            status: .completed,
            createdAt: .now,
            updatedAt: .now
        )
        let roomURL = URL(filePath: "/tmp/semantic-room.usdz")
        let detail = SavedScanDetail(
            scan: scan,
            manifest: ScanPackageManifest(
                localScanID: scan.id,
                status: .completed,
                createdAt: scan.createdAt,
                updatedAt: scan.updatedAt
            ),
            integrity: PackageIntegrityReport(scanID: scan.id),
            rawMesh: .unavailable(message: "No raw mesh for semantic capture."),
            exportableAssets: [
                ScanExportAsset(
                    reference: ScanAssetReference(
                        kind: .semanticRoom,
                        relativePath: "room/semantic-room.usdz",
                        byteCount: 1,
                        sha256: "valid"
                    ),
                    url: roomURL
                )
            ]
        )

        XCTAssertEqual(detail.semanticRoomURL, roomURL)
    }

    @MainActor
    func testLibraryModelPresentsEmptyStateFromInjectedService() async {
        let model = LibraryViewModel(service: DemoScanLibraryService(scenario: .empty))

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .empty)
    }

    @MainActor
    func testLibraryModelPresentsFailureFromInjectedService() async {
        let model = LibraryViewModel(service: DemoScanLibraryService(scenario: .failure))

        await model.loadIfNeeded()

        guard case let .failure(error) = model.state else {
            return XCTFail("Expected the injected failure state")
        }

        XCTAssertEqual(error.title, "Could not load scans")
    }

    func testUnavailableDemoUsesCoreCapabilityStateWithoutClaimingHardwareAccess() async {
        let service = DemoScannerWorkflowService(scenario: .unavailable)

        let checking = await service.begin()
        let resolved = await service.resolveCapabilities()

        XCTAssertEqual(checking.lifecycle, .capabilityChecking)
        XCTAssertEqual(resolved.lifecycle, .failed(.unsupportedDevice))
        XCTAssertEqual(resolved.capability, .unavailable([.lidarUnavailable]))
        XCTAssertTrue(resolved.isDemo)
    }

    func testReadyDemoAdvancesThroughCoreLifecycle() async {
        let service = DemoScannerWorkflowService(scenario: .ready)

        _ = await service.begin()
        let ready = await service.resolveCapabilities()
        let scanning = await service.perform(.startPreview)
        let processing = await service.perform(.finishPreview)
        let saving = await service.perform(.finishProcessing)
        let completed = await service.perform(.finishSaving)

        XCTAssertEqual(ready.lifecycle, .ready)
        XCTAssertEqual(scanning.lifecycle, .scanning)
        XCTAssertEqual(processing.lifecycle, .processing)
        XCTAssertEqual(saving.lifecycle, .saving)
        XCTAssertEqual(completed.lifecycle, .completed)
    }

    @MainActor
    func testContentDemoSuppliesPresentationMetadataWithoutAssetAccess() async {
        let model = LibraryViewModel(service: DemoScanLibraryService(scenario: .content))

        await model.loadIfNeeded()

        guard case let .content(scans) = model.state else {
            return XCTFail("Expected demo scan content")
        }

        XCTAssertEqual(scans.first?.storageByteCount, 148_000_000)
        XCTAssertEqual(scans.first?.thumbnailState, .ready)
    }

    @MainActor
    func testDetailModelUsesInjectedServiceAndSurfacesDeleteFailure() async throws {
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Test scan",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_735_603_200),
            updatedAt: Date(timeIntervalSince1970: 1_735_603_580),
            durationSeconds: 120
        )
        let detail = SavedScanDetail(
            scan: scan,
            manifest: ScanPackageManifest(
                localScanID: scan.id,
                status: .completed,
                createdAt: scan.createdAt,
                updatedAt: scan.updatedAt,
                durationSeconds: scan.durationSeconds
            ),
            integrity: PackageIntegrityReport(scanID: scan.id),
            rawMesh: .available([]),
            exportableAssets: []
        )
        let deleteFailure = ScanDetailFailureState(
            title: "Unable to delete scan",
            message: "The injected service rejected deletion."
        )
        let renameFailure = ScanDetailFailureState(
            title: "Unable to rename scan",
            message: "The injected service rejected renaming."
        )
        let service = TestScanDetailService(
            loadResult: .success(detail),
            deleteResult: .failure(deleteFailure),
            renameResult: .failure(renameFailure)
        )
        let model = ScanDetailViewModel(scanID: scan.id, service: service)

        await model.loadIfNeeded()

        XCTAssertEqual(model.state, .content(detail))
        XCTAssertEqual(model.navigationTitle, scan.displayName)
        let loadedIDs = await service.loadedIDs()
        XCTAssertEqual(loadedIDs, [scan.id])

        await model.loadPointCloudIfNeeded()
        guard case .unavailable = model.pointCloudState else {
            return XCTFail("Expected the test detail service to report point-cloud data as unavailable")
        }

        let didRename = await model.rename(to: "Renamed scan")
        XCTAssertFalse(didRename)
        XCTAssertEqual(model.renameFailure, renameFailure)
        let failedRenameDisplayNames = await service.renamedDisplayNames()
        XCTAssertEqual(failedRenameDisplayNames, ["Renamed scan"])

        model.requestDeletionConfirmation()
        XCTAssertTrue(model.isShowingDeleteConfirmation)

        let didDelete = await model.delete()
        XCTAssertFalse(didDelete)
        XCTAssertFalse(model.isShowingDeleteConfirmation)
        XCTAssertEqual(model.deleteFailure, deleteFailure)
        let deletedIDs = await service.deletedIDs()
        XCTAssertEqual(deletedIDs, [scan.id])
    }

    @MainActor
    func testDetailModelReloadsAfterSuccessfulRename() async {
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Original scan",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_735_603_200),
            updatedAt: Date(timeIntervalSince1970: 1_735_603_580)
        )
        let detail = SavedScanDetail(
            scan: scan,
            manifest: ScanPackageManifest(
                localScanID: scan.id,
                status: .completed,
                createdAt: scan.createdAt,
                updatedAt: scan.updatedAt
            ),
            integrity: PackageIntegrityReport(scanID: scan.id),
            rawMesh: .available([]),
            exportableAssets: []
        )
        let service = TestScanDetailService(loadResult: .success(detail), deleteResult: .success)
        let model = ScanDetailViewModel(scanID: scan.id, service: service)

        await model.loadIfNeeded()
        let didRename = await model.rename(to: "  Renamed scan  ")

        XCTAssertTrue(didRename)
        XCTAssertNil(model.renameFailure)
        let renamedDisplayNames = await service.renamedDisplayNames()
        let loadedIDs = await service.loadedIDs()
        XCTAssertEqual(renamedDisplayNames, ["Renamed scan"])
        XCTAssertEqual(loadedIDs, [scan.id, scan.id])
    }

    @MainActor
    func testDetailModelReloadsWhenReconstructionBecomesReady() async {
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Processing scan",
            status: .completed,
            createdAt: .now,
            updatedAt: .now
        )
        let manifest = ScanPackageManifest(
            localScanID: scan.id,
            status: .completed,
            createdAt: scan.createdAt,
            updatedAt: scan.updatedAt
        )
        let queued = SavedScanDetail(
            scan: scan,
            manifest: manifest,
            integrity: PackageIntegrityReport(scanID: scan.id),
            reconstructionStatus: ScanReconstructionStatus(scanID: scan.id, stage: .queued),
            rawMesh: .available([]),
            exportableAssets: []
        )
        let refreshed = SavedScanDetail(
            scan: scan,
            manifest: manifest,
            integrity: PackageIntegrityReport(scanID: scan.id),
            reconstructionStatus: nil,
            rawMesh: .available([]),
            exportableAssets: []
        )
        let service = TestScanDetailService(
            loadResults: [.success(queued), .success(refreshed)],
            deleteResult: .success,
            reconstructionStatuses: [ScanReconstructionStatus(scanID: scan.id, stage: .ready)]
        )
        let model = ScanDetailViewModel(scanID: scan.id, service: service)

        await model.loadIfNeeded()
        await model.observeReconstruction()
        let loadedIDs = await service.loadedIDs()

        XCTAssertEqual(model.state, .content(refreshed))
        XCTAssertEqual(loadedIDs, [scan.id, scan.id])
    }

    @MainActor
    func testDetailModelMapsMissingScanToAccessibleFailureState() async {
        let service = TestScanDetailService(loadResult: .notFound, deleteResult: .success)
        let model = ScanDetailViewModel(scanID: UUID(), service: service)

        await model.loadIfNeeded()

        guard case let .failure(error) = model.state else {
            return XCTFail("Expected a missing scan failure")
        }
        XCTAssertEqual(error.title, "Scan not found")
    }

    func testLocalDetailServiceLoadsRawMeshManifestIntegrityAndDeletesPackage() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Saved mesh",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_735_603_200),
            updatedAt: Date(timeIntervalSince1970: 1_735_603_580),
            durationSeconds: 120
        )
        let snapshot = try makeTestMeshSnapshot()
        let meshData = try JSONEncoder().encode([snapshot])
        let manifest = ScanPackageManifest(
            localScanID: scan.id,
            status: .completed,
            createdAt: scan.createdAt,
            updatedAt: scan.updatedAt,
            durationSeconds: scan.durationSeconds,
            captureStatistics: CaptureStatistics(
                sampledFrameCount: 4,
                featurePointCount: 12,
                depthPointCount: 8,
                meshVertexCount: 3,
                meshFaceCount: 1
            )
        )
        try await stores.repository.save(
            scan: scan,
            manifest: manifest,
            assets: [
                AssetInput(
                    kind: .meshRaw,
                    relativePath: "mesh/raw-mesh.json",
                    data: meshData,
                    spatialReference: .arWorld
                ),
                AssetInput(
                    kind: .pointCloud,
                    relativePath: "pointcloud/cloud.ply",
                    data: Data("ply\n".utf8),
                    spatialReference: .arWorld
                )
            ]
        )
        let derivedRoot = rootURL.appending(path: "derived", directoryHint: .isDirectory)
        let processingRoot = rootURL.appending(path: "processing", directoryHint: .isDirectory)
        let derivedScanDirectory = derivedRoot.appending(
            path: scan.id.uuidString,
            directoryHint: .isDirectory
        )
        let processingScanDirectory = processingRoot.appending(
            path: scan.id.uuidString,
            directoryHint: .isDirectory
        )
        let processedSurfaceStore = try ProcessedSurfaceStore(
            rootURL: derivedRoot,
            processingRootURL: processingRoot
        )
        try FileManager.default.createDirectory(
            at: derivedScanDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: processingScanDirectory,
            withIntermediateDirectories: true
        )
        let service = LocalScanDetailService(
            repository: stores.repository,
            assetStore: stores.assetStore,
            processedSurfaceStore: processedSurfaceStore
        )

        guard case let .success(detail) = await service.loadDetail(id: scan.id) else {
            return XCTFail("Expected a saved local detail")
        }

        XCTAssertEqual(detail.scan, scan)
        XCTAssertEqual(detail.manifest.localScanID, scan.id)
        XCTAssertTrue(detail.integrity.isValid)
        XCTAssertEqual(detail.rawMesh, .available([snapshot]))
        XCTAssertEqual(detail.manifest.captureStatistics.meshFaceCount, 1)
        XCTAssertEqual(detail.exportableAssets.count, 2)
        XCTAssertTrue(
            detail.exportableAssets.allSatisfy {
                FileManager.default.fileExists(atPath: $0.url.path)
            }
        )

        let deleteResult = await service.deleteScan(id: scan.id)
        XCTAssertEqual(deleteResult, .success)
        let deletedScan = try await stores.repository.reopen(id: scan.id)
        XCTAssertNil(deletedScan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedScanDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: processingScanDirectory.path))
    }

    @MainActor
    func testLocalDetailServiceProjectsVerifiedKeyframeColorOntoRawMeshPreview() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Color fixture",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_735_603_200),
            updatedAt: Date(timeIntervalSince1970: 1_735_603_580)
        )
        let mesh = try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: [Point3D(x: 0, y: 0, z: -1)],
            normals: [],
            faces: []
        )
        let metadata = FrameMetadata(
            timestamp: 1,
            videoTimestamp: nil,
            imageWidth: 1,
            imageHeight: 1,
            intrinsics: CameraIntrinsics(imageWidth: 1, imageHeight: 1, fx: 1, fy: 1, cx: 0, cy: 0),
            worldFromCamera: .identity,
            tracking: .normal,
            worldMapping: .mapped,
            isTextureSourceCandidate: true
        )
        let manifest = ScanPackageManifest(
            localScanID: scan.id,
            status: .completed,
            createdAt: scan.createdAt,
            updatedAt: scan.updatedAt
        )
        try await stores.repository.save(
            scan: scan,
            manifest: manifest,
            assets: [
                AssetInput(
                    kind: .frameMetadata,
                    relativePath: "frames/frame-metadata.ndjson",
                    data: try JSONEncoder().encode(metadata) + Data([0x0A]),
                    spatialReference: .arWorld
                ),
                AssetInput(
                    kind: .textureSource,
                    relativePath: "frames/images/frame-000001.jpg",
                    data: try makeTestJPEG(),
                    spatialReference: .arWorld
                ),
                AssetInput(
                    kind: .meshRaw,
                    relativePath: "mesh/raw-mesh.json",
                    data: try JSONEncoder().encode([mesh]),
                    spatialReference: .arWorld
                )
            ]
        )

        let service = LocalScanDetailService(repository: stores.repository, assetStore: stores.assetStore)
        guard case let .success(detail) = await service.loadDetail(id: scan.id) else {
            return XCTFail("Expected projected mesh detail")
        }
        XCTAssertNotNil(detail.rawMeshVertexColors[mesh.anchorID]?.first ?? nil)
    }

    func testLocalDetailServicePreparesOnlySelectedOriginalAssetForExport() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Export fixture",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_735_603_200),
            updatedAt: Date(timeIntervalSince1970: 1_735_603_580),
            durationSeconds: 120
        )
        let frameMetadataData = Data("{\"frame\":1}\n".utf8)
        let meshData = try JSONEncoder().encode([try makeTestMeshSnapshot()])
        let manifest = ScanPackageManifest(
            localScanID: scan.id,
            status: .completed,
            createdAt: scan.createdAt,
            updatedAt: scan.updatedAt,
            durationSeconds: scan.durationSeconds,
            captureStatistics: CaptureStatistics(
                sampledFrameCount: 4,
                featurePointCount: 12,
                depthPointCount: 8,
                meshVertexCount: 3,
                meshFaceCount: 1
            )
        )
        try await stores.repository.save(
            scan: scan,
            manifest: manifest,
            assets: [
                AssetInput(
                    kind: .frameMetadata,
                    relativePath: "frames/frame-metadata.ndjson",
                    data: frameMetadataData,
                    spatialReference: .arWorld
                ),
                AssetInput(
                    kind: .meshRaw,
                    relativePath: "mesh/raw-mesh.json",
                    data: meshData,
                    spatialReference: .arWorld
                ),
                AssetInput(
                    kind: .pointCloud,
                    relativePath: "pointcloud/cloud.ply",
                    data: Data("ply\n".utf8),
                    spatialReference: .arWorld
                )
            ]
        )
        guard let storedScan = try await stores.repository.reopen(id: scan.id),
              let selectedAsset = storedScan.manifest.assets.first(where: { $0.kind == .frameMetadata })
        else {
            return XCTFail("Expected a saved frame-metadata asset")
        }

        let packageURL = try await stores.assetStore.packageURL(for: scan.id)
        let expectedAssetURL = packageURL.appending(path: selectedAsset.relativePath)
        let originalAssetData = try Data(contentsOf: expectedAssetURL)
        let selection = ScanExportSelection(assetIDs: [selectedAsset.id])
        let service = LocalScanDetailService(repository: stores.repository, assetStore: stores.assetStore)

        let result = await service.prepareOriginalAssetExport(id: scan.id, selection: selection)
        guard case let .success(preparedExport) = result else {
            return XCTFail("Expected selected original asset export preparation to succeed")
        }

        let writtenManifestData = try Data(contentsOf: preparedExport.manifestURL)
        let expectedManifestData = try OriginalAssetScanExporter().encodeManifest(preparedExport.preview.manifest)

        XCTAssertEqual(preparedExport.preview.selection, selection)
        XCTAssertEqual(preparedExport.preview.selectedOriginalAssets, [selectedAsset])
        XCTAssertEqual(preparedExport.assetURLs, [expectedAssetURL])
        XCTAssertEqual(preparedExport.manifestURL.lastPathComponent, "export-manifest.json")
        XCTAssertEqual(preparedExport.manifestURL.pathExtension, "json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedExport.manifestURL.path))
        XCTAssertEqual(writtenManifestData, expectedManifestData)
        XCTAssertEqual(preparedExport.preview.assetByteCount, Int64(frameMetadataData.count))
        XCTAssertEqual(
            preparedExport.preview.estimatedByteCount,
            preparedExport.preview.assetByteCount + preparedExport.preview.manifestByteCount
        )
        XCTAssertEqual(
            preparedExport.preview.privacy,
            ScanExportPrivacyReport(
                warnings: [
                    ScanExportPrivacyWarning(
                        category: .cameraPoses,
                        assetIDs: [selectedAsset.id]
                    )
                ]
            )
        )
        XCTAssertFalse(preparedExport.preview.manifest.locationIncluded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedAssetURL.path))
        XCTAssertEqual(try Data(contentsOf: expectedAssetURL), originalAssetData)

        let missingSelection = ScanExportSelection(assetIDs: [UUID()])
        let missingResult = await service.prepareOriginalAssetExport(
            id: scan.id,
            selection: missingSelection
        )
        guard case .failure = missingResult else {
            return XCTFail("Expected a selection without a package asset to fail")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedAssetURL.path))
        XCTAssertEqual(try Data(contentsOf: expectedAssetURL), originalAssetData)
    }

    func testLocalDetailServicePreparesCanonicalPointExportsWithoutSharingCompatibilityAssets() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let stores = try makeLocalStores(rootURL: rootURL)
        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Interchange fixture",
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_735_603_200),
            updatedAt: Date(timeIntervalSince1970: 1_735_603_580),
            durationSeconds: 120
        )
        let pointCloudSourceURL = rootURL.appending(path: "pointcloud-source.ply")
        let writer = try PointCloudPLYWriter(destinationURL: pointCloudSourceURL)
        try await writer.append([
            DepthPoint(
                position: Point3D(x: 1, y: 2, z: 3),
                confidence: 2,
                timestamp: 0,
                sourcePixel: PixelCoordinate(x: 0, y: 0)
            )
        ])
        try await writer.finish()
        let pointCloudData = try Data(contentsOf: pointCloudSourceURL)
        let canonicalSourceURL = rootURL.appending(path: "canonical-spatial-chunks.bin")
        let canonicalStore = try CanonicalSpatialChunkStore(destinationURL: canonicalSourceURL)
        try await canonicalStore.append([
            RGBDPointSample(
                position: Point3D(x: 10, y: 20, z: 30),
                confidence: 2,
                color: PointCloudColor(red: 40, green: 50, blue: 60)
            )
        ])
        _ = try await canonicalStore.finish()
        let canonicalData = try Data(contentsOf: canonicalSourceURL)
        let rawMeshData = try JSONEncoder().encode([try makeTestMeshSnapshot()])
        let manifest = ScanPackageManifest(
            localScanID: scan.id,
            status: .completed,
            createdAt: scan.createdAt,
            updatedAt: scan.updatedAt,
            durationSeconds: scan.durationSeconds,
            captureStatistics: CaptureStatistics(
                sampledFrameCount: 1,
                featurePointCount: 1,
                depthPointCount: 1,
                meshVertexCount: 3,
                meshFaceCount: 1
            )
        )
        try await stores.repository.save(
            scan: scan,
            manifest: manifest,
            assets: [
                AssetInput(
                    kind: .meshRaw,
                    relativePath: "mesh/raw-mesh.json",
                    data: rawMeshData,
                    spatialReference: .arWorld
                ),
                AssetInput(
                    kind: .pointCloud,
                    relativePath: "pointcloud/cloud.ply",
                    data: pointCloudData,
                    spatialReference: .arWorld
                ),
                AssetInput(
                    kind: .manifestAttachment,
                    relativePath: CanonicalSpatialChunkStore.relativePath,
                    data: canonicalData,
                    spatialReference: .arWorld
                )
            ]
        )
        let packageURL = try await stores.assetStore.packageURL(for: scan.id)
        let rawMeshURL = packageURL.appending(path: "mesh/raw-mesh.json")
        let pointCloudURL = packageURL.appending(path: "pointcloud/cloud.ply")
        let originalRawMeshData = try Data(contentsOf: rawMeshURL)
        let service = LocalScanDetailService(repository: stores.repository, assetStore: stores.assetStore)

        let formats = await service.availableInterchangeFormats(id: scan.id)
        XCTAssertEqual(formats, [.ply, .opf])

        let plyResult = await service.prepareInterchangeExport(id: scan.id, format: .ply)
        guard case let .success(plyExport) = plyResult else {
            return XCTFail("Expected PLY export preparation to succeed")
        }
        XCTAssertNotEqual(plyExport.shareURL, pointCloudURL)
        XCTAssertEqual(plyExport.shareURL.pathExtension.lowercased(), "ply")
        let exportedPLY = try PointCloudPLYReader().read(
            from: plyExport.shareURL,
            maximumPointCount: 10
        )
        XCTAssertEqual(exportedPLY.header.vertexCount, 1)
        XCTAssertEqual(exportedPLY.points.first?.position, Point3D(x: 10, y: 20, z: 30))
        XCTAssertEqual(exportedPLY.points.first?.color, PointCloudColor(red: 40, green: 50, blue: 60))

        let glbResult = await service.prepareInterchangeExport(id: scan.id, format: .glb)
        guard case .failure = glbResult else {
            return XCTFail("Expected raw mesh to be ineligible for complete glTF export")
        }

        let tilesResult = await service.prepareInterchangeExport(id: scan.id, format: .cesium3DTiles)
        guard case .failure = tilesResult else {
            return XCTFail("Expected raw mesh to be ineligible for complete 3D Tiles export")
        }

        let opfResult = await service.prepareInterchangeExport(id: scan.id, format: .opf)
        guard case let .success(opfExport) = opfResult else {
            return XCTFail("Expected OPF export preparation to succeed")
        }
        XCTAssertEqual(opfExport.shareURL.lastPathComponent, "scan-opf.zip")
        XCTAssertGreaterThan(try fileByteCount(at: opfExport.shareURL), 0)

        XCTAssertEqual(try Data(contentsOf: rawMeshURL), originalRawMeshData)
        XCTAssertEqual(try Data(contentsOf: pointCloudURL), pointCloudData)
    }

    @MainActor
    private func assertNormalCompositionUsesLocalServices(rootURL: URL) throws {
        let composition = AppComposition.make(arguments: [], dataRootURL: rootURL)

        XCTAssertFalse(composition.isDemo)
        XCTAssertTrue(composition.libraryService is LocalScanLibraryService)
        XCTAssertTrue(composition.detailService is LocalScanDetailService)
        XCTAssertTrue(composition.scannerService is LocalScannerWorkflowService)
    }

    private func makeLocalStores(rootURL: URL) throws -> LocalStores {
        let assetStore = try FileAssetStore(
            rootURL: rootURL.appending(path: "scan-packages", directoryHint: .isDirectory)
        )
        let metadataStore = try SQLiteMetadataStore(
            databaseURL: rootURL.appending(path: "scan-metadata.sqlite")
        )
        return LocalStores(
            rootURL: rootURL,
            repository: LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore),
            assetStore: assetStore
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    @MainActor
    private func waitForScannerSnapshot(
        _ scanner: LocalScannerWorkflowService,
        matching predicate: (ScannerWorkflowSnapshot) -> Bool
    ) async -> ScannerWorkflowSnapshot {
        for _ in 0..<100 {
            let current = await scanner.currentSnapshot()
            if predicate(current) {
                return current
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await scanner.currentSnapshot()
    }

    private func makeTestJPEG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard let data = image.jpegData(compressionQuality: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(size)
    }

    private func makeTestMeshSnapshot(anchorID: UUID = UUID()) throws -> MeshSnapshot {
        try MeshSnapshot(
            anchorID: anchorID,
            worldFromAnchor: .translation(x: 1, y: 2, z: 3),
            vertices: [
                Point3D(x: 0, y: 0, z: 0),
                Point3D(x: 1, y: 0, z: 0),
                Point3D(x: 0, y: 1, z: 0)
            ],
            normals: [],
            faces: [MeshFace(indices: (0, 1, 2))]
        )
    }

    private func makeTestCameraFrustum(
        id: Int,
        worldFromCamera: Transform4x4
    ) -> SavedCameraFrustum {
        SavedCameraFrustum(
            id: URL(filePath: "/tmp/retained-frame-\(id).jpg"),
            worldFromCamera: worldFromCamera,
            intrinsics: CameraIntrinsics(
                imageWidth: 640,
                imageHeight: 480,
                fx: 500,
                fy: 500,
                cx: 320,
                cy: 240
            ),
            imageWidth: 640,
            imageHeight: 480
        )
    }

    private func makeProcessedSurfacePrefix() -> TSDFCompletedPrefixIdentity {
        TSDFCompletedPrefixIdentity(
            source: TSDFReconstructionSource(
                scanID: UUID(uuid: (0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x82, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42)),
                keyframeIndexSHA256: String(repeating: "a", count: 64),
                calibratedArchiveSHA256: String(repeating: "b", count: 64),
                keyframeCount: 1
            ),
            configuration: .default,
            completedFrameCount: 1,
            sha256: String(repeating: "c", count: 64)
        )
    }

    private func waitForReconstructionStatus(
        _ coordinator: ScanReconstructionCoordinator,
        scanID: UUID,
        predicate: @escaping (ScanReconstructionStatus) -> Bool
    ) async -> ScanReconstructionStatus {
        for _ in 0..<200 {
            let status = await coordinator.status(scanID: scanID)
            if predicate(status) { return status }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await coordinator.status(scanID: scanID)
    }

    private func cameraFrustumNodes(in scene: SCNScene) -> [SCNNode] {
        var nodes: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            guard node.name == "scan-retained-keyframe-frustum" else {
                return
            }
            nodes.append(node)
        }
        return nodes
    }

    private func sceneContainsVertexColorSource(_ scene: SCNScene) -> Bool {
        var containsColorSource = false
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.geometry?.sources.contains(where: { $0.semantic == .color }) == true {
                containsColorSource = true
            }
        }
        return containsColorSource
    }

    private func makeReadyTestMeshSnapshot(anchorID: UUID = UUID()) throws -> MeshSnapshot {
        let vertices = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 0.5, y: 0, z: 0),
            Point3D(x: 0.5, y: 0.5, z: 0),
            Point3D(x: 0, y: 0.5, z: 0)
        ]
        let faces = (0..<24).map { index in
            index.isMultiple(of: 2)
                ? MeshFace(indices: (0, 1, 2))
                : MeshFace(indices: (0, 2, 3))
        }
        return try MeshSnapshot(
            anchorID: anchorID,
            worldFromAnchor: .identity,
            vertices: vertices,
            normals: [],
            faces: faces
        )
    }

    private func makeMeshFragment(faceCount: Int, translatedX: Float) throws -> MeshSnapshot {
        let vertices = [
            Point3D(x: 0, y: 0, z: 0),
            Point3D(x: 0.1, y: 0, z: 0),
            Point3D(x: 0.1, y: 0.1, z: 0),
            Point3D(x: 0, y: 0.1, z: 0)
        ]
        let faces = (0..<faceCount).map { index in
            index.isMultiple(of: 2)
                ? MeshFace(indices: (0, 1, 2))
                : MeshFace(indices: (0, 2, 3))
        }
        return try MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .translation(x: translatedX, y: 0, z: 0),
            vertices: vertices,
            normals: [],
            faces: faces
        )
    }
}

private struct LocalStores {
    let rootURL: URL
    let repository: LocalScanRepository
    let assetStore: FileAssetStore
}

@MainActor
private final class TestCaptureAdapter: ScanCaptureSessionServing {
    let essentialEvents: AsyncStream<ScanCaptureEvent>
    let events: AsyncStream<ScanCaptureEvent>

    private let essentialEventContinuation: AsyncStream<ScanCaptureEvent>.Continuation
    private let eventContinuation: AsyncStream<ScanCaptureEvent>.Continuation
    private var capabilities: DeviceCapabilities
    private let eventsOnStop: [ScanCaptureEvent]
    private let eventsOnStart: [ScanCaptureEvent]
    private let shouldFailVideoFinalization: Bool
    private var videoOutputURL: URL?
    private var isCapturing = false
    private(set) var cameraAuthorizationRequestCount = 0
    private(set) var startCount = 0
    private(set) var resumeCount = 0
    private(set) var videoConfigurationCount = 0
    private(set) var cancelVideoRecordingCount = 0
    private(set) var finishKeyframeCaptureCount = 0

    init(
        capabilities: DeviceCapabilities,
        eventsOnStart: [ScanCaptureEvent] = [],
        eventsOnStop: [ScanCaptureEvent] = [],
        shouldFailVideoFinalization: Bool = false,
        presentationBufferLimit: Int? = nil
    ) {
        self.capabilities = capabilities
        self.eventsOnStart = eventsOnStart
        self.eventsOnStop = eventsOnStop
        self.shouldFailVideoFinalization = shouldFailVideoFinalization
        var capturedEssentialContinuation: AsyncStream<ScanCaptureEvent>.Continuation?
        essentialEvents = AsyncStream { continuation in
            capturedEssentialContinuation = continuation
        }
        guard let capturedEssentialContinuation else {
            preconditionFailure("AsyncStream must synchronously provide its continuation")
        }
        essentialEventContinuation = capturedEssentialContinuation
        var capturedContinuation: AsyncStream<ScanCaptureEvent>.Continuation?
        if let presentationBufferLimit {
            events = AsyncStream(bufferingPolicy: .bufferingNewest(presentationBufferLimit)) { continuation in
                capturedContinuation = continuation
            }
        } else {
            events = AsyncStream { continuation in
                capturedContinuation = continuation
            }
        }
        guard let capturedContinuation else {
            preconditionFailure("AsyncStream must synchronously provide its continuation")
        }
        eventContinuation = capturedContinuation
    }

    func currentCapabilities() async -> DeviceCapabilities {
        capabilities
    }

    func requestCameraAuthorization() async -> PermissionAuthorization {
        cameraAuthorizationRequestCount += 1
        capabilities.cameraAuthorization = .authorized
        return .authorized
    }

    func configureVideoRecording(outputURL: URL) throws {
        videoConfigurationCount += 1
        videoOutputURL = outputURL
    }

    func start() throws {
        startCount += 1
        isCapturing = true
        let startEvents = eventsOnStart
        Task { @MainActor [weak self] in
            // ARKit callbacks arrive after `start()` returns. Mirroring that
            // ordering keeps lifecycle tests from treating a synchronous mock
            // delivery as an app-level event-ordering guarantee.
            await Task.yield()
            guard let self, self.isCapturing else { return }
            for event in startEvents {
                self.publish(event)
            }
        }
    }

    func pause() {}

    func resume() throws {
        resumeCount += 1
    }

    func finishKeyframeCapture() async {
        finishKeyframeCaptureCount += 1
    }

    func stop() {
        guard isCapturing else {
            return
        }
        isCapturing = false
        for event in eventsOnStop {
            publish(event)
        }
        essentialEventContinuation.yield(.captureEnded)
        eventContinuation.yield(.captureEnded)
    }

    func emit(_ event: ScanCaptureEvent) {
        essentialEventContinuation.yield(event)
        eventContinuation.yield(event)
    }

    private func publish(_ event: ScanCaptureEvent) {
        essentialEventContinuation.yield(event)
        eventContinuation.yield(event)
    }

    func finishVideoRecording() async throws -> URL {
        if shouldFailVideoFinalization {
            throw TestCaptureAdapterError.recordingNotConfigured
        }
        guard let videoOutputURL else {
            throw TestCaptureAdapterError.recordingNotConfigured
        }
        return videoOutputURL
    }

    func cancelVideoRecording() {
        cancelVideoRecordingCount += 1
        videoOutputURL = nil
    }
}

private enum TestCaptureAdapterError: Error {
    case recordingNotConfigured
}

@MainActor
private final class TestSemanticRoomCaptureAdapter: SemanticRoomCaptureSessionServing {
    private(set) var startCount = 0
    private(set) var finishCount = 0

    func start() throws {
        startCount += 1
    }

    func finishAndExport(to outputURL: URL) async throws {
        finishCount += 1
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("semantic-room-usdz-fixture".utf8).write(to: outputURL, options: .atomic)
    }

    func cancel() async {}
}

@MainActor
private final class SuspendingSemanticRoomCaptureAdapter: SemanticRoomCaptureSessionServing {
    enum Operation: Equatable {
        case finishStarted
        case finishCompleted
        case cancellationStarted
        case cancellationCompleted
    }

    private var finishStartContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var cancellationStartContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var finishCanComplete = false
    private var cancellationCanComplete = false

    private(set) var cancelCount = 0
    private(set) var operationOrder: [Operation] = []

    func start() throws {}

    func finishAndExport(to outputURL: URL) async throws {
        operationOrder.append(.finishStarted)
        finishStartContinuation?.resume()
        finishStartContinuation = nil
        await withCheckedContinuation { continuation in
            if finishCanComplete {
                continuation.resume()
            } else {
                finishContinuation = continuation
            }
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("semantic-room-usdz-fixture".utf8).write(to: outputURL, options: .atomic)
        operationOrder.append(.finishCompleted)
    }

    func cancel() async {
        cancelCount += 1
        operationOrder.append(.cancellationStarted)
        cancellationStartContinuation?.resume()
        cancellationStartContinuation = nil
        await withCheckedContinuation { continuation in
            if cancellationCanComplete {
                continuation.resume()
            } else {
                cancellationContinuation = continuation
            }
        }
        operationOrder.append(.cancellationCompleted)
    }

    func waitForFinishToStart() async {
        guard !operationOrder.contains(.finishStarted) else {
            return
        }
        await withCheckedContinuation { continuation in
            finishStartContinuation = continuation
        }
    }

    func completeFinish() {
        finishCanComplete = true
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume()
    }

    func waitForCancellationToStart() async {
        guard !operationOrder.contains(.cancellationStarted) else {
            return
        }
        await withCheckedContinuation { continuation in
            cancellationStartContinuation = continuation
        }
    }

    func completeCancellation() {
        cancellationCanComplete = true
        let continuation = cancellationContinuation
        cancellationContinuation = nil
        continuation?.resume()
    }
}

private actor TestScanDetailService: ScanDetailServing {
    private let loadResults: [ScanDetailLoadResult]
    private let deleteResult: ScanDetailDeleteResult
    private let renameResult: ScanDetailRenameResult
    private let reconstructionStatuses: [ScanReconstructionStatus]
    private var loadRequests: [UUID] = []
    private var deleteRequests: [UUID] = []
    private var renameDisplayNameRequests: [String] = []

    init(
        loadResult: ScanDetailLoadResult,
        deleteResult: ScanDetailDeleteResult,
        renameResult: ScanDetailRenameResult = .success
    ) {
        self.loadResults = [loadResult]
        self.deleteResult = deleteResult
        self.renameResult = renameResult
        reconstructionStatuses = []
    }

    init(
        loadResults: [ScanDetailLoadResult],
        deleteResult: ScanDetailDeleteResult,
        renameResult: ScanDetailRenameResult = .success,
        reconstructionStatuses: [ScanReconstructionStatus]
    ) {
        self.loadResults = loadResults
        self.deleteResult = deleteResult
        self.renameResult = renameResult
        self.reconstructionStatuses = reconstructionStatuses
    }

    func loadDetail(id: UUID) async -> ScanDetailLoadResult {
        loadRequests.append(id)
        return loadResults[min(loadRequests.count - 1, loadResults.count - 1)]
    }

    func loadPointCloud(id: UUID) async -> PointCloudLoadResult {
        .unavailable(message: "The test detail service does not provide a persisted point cloud.")
    }

    func renameScan(id: UUID, displayName: String) async -> ScanDetailRenameResult {
        renameDisplayNameRequests.append(displayName)
        return renameResult
    }

    func deleteScan(id: UUID) async -> ScanDetailDeleteResult {
        deleteRequests.append(id)
        return deleteResult
    }

    func reconstructionUpdates(id: UUID) async -> AsyncStream<ScanReconstructionStatus> {
        let statuses = reconstructionStatuses
        return AsyncStream { continuation in
            statuses.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func loadedIDs() -> [UUID] {
        loadRequests
    }

    func deletedIDs() -> [UUID] {
        deleteRequests
    }

    func renamedDisplayNames() -> [String] {
        renameDisplayNameRequests
    }
}

private actor RecordingAppReconstructionCoordinator: AppReconstructionCoordinating {
    private var enqueued: [UUID] = []
    private var statuses: [UUID: ScanReconstructionStatus] = [:]

    func enqueue(scanID: UUID, automatic: Bool) async -> ScanReconstructionStatus {
        enqueued.append(scanID)
        let status = ScanReconstructionStatus(scanID: scanID)
        statuses[scanID] = status
        return status
    }

    func retry(scanID: UUID) async -> ScanReconstructionStatus {
        statuses[scanID] ?? ScanReconstructionStatus(scanID: scanID)
    }

    func status(scanID: UUID) async -> ScanReconstructionStatus {
        statuses[scanID] ?? ScanReconstructionStatus(scanID: scanID)
    }

    func updates(scanID: UUID) async -> AsyncStream<ScanReconstructionStatus> {
        let status = statuses[scanID] ?? ScanReconstructionStatus(scanID: scanID)
        return AsyncStream { continuation in
            continuation.yield(status)
            continuation.finish()
        }
    }

    func setApplicationActive(_ isActive: Bool) async {}
    func resumePendingJobs() async {}
    func cancelAndWait(scanID: UUID) async {}

    func enqueuedScanIDs() -> [UUID] { enqueued }
}
