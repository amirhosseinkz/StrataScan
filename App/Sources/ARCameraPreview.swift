import ARKit
import SceneKit
import StrataCore
import SwiftUI
import UIKit
import simd

/// Presentation-only AR surface. The injected capture service owns session
/// configuration, lifecycle, delegate callbacks, and persistence; this view
/// only renders the camera feed and current AR scene.
@MainActor
struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession
    let showsLiveMesh: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = true
        // The capture adapter owns the sensor cadence. Fifteen FPS is enough
        // for live mesh feedback while leaving headroom for ARKit tracking and
        // reconstruction on physical devices.
        view.preferredFramesPerSecond = 15
        view.delegate = context.coordinator
        _ = context.coordinator.setLiveMeshVisible(showsLiveMesh)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session {
            view.session = session
        }
        if context.coordinator.setLiveMeshVisible(showsLiveMesh), !showsLiveMesh {
            view.scene.rootNode.enumerateChildNodes { node, _ in
                if node.name == "stratascan.liveMesh" {
                    node.removeFromParentNode()
                }
            }
        }
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        view.delegate = nil
    }

    /// This is a renderer delegate, not an ARSession delegate. The capture
    /// adapter remains the sole owner of ARKit lifecycle and persisted events.
    final class Coordinator: NSObject, ARSCNViewDelegate {
        private var showsLiveMesh = false

        @discardableResult
        func setLiveMeshVisible(_ isVisible: Bool) -> Bool {
            guard showsLiveMesh != isVisible else {
                return false
            }
            showsLiveMesh = isVisible
            return true
        }

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard showsLiveMesh, let meshAnchor = anchor as? ARMeshAnchor else {
                return nil
            }
            let node = SCNNode(geometry: Self.geometry(from: meshAnchor.geometry))
            node.name = "stratascan.liveMesh"
            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard showsLiveMesh, let meshAnchor = anchor as? ARMeshAnchor else {
                return
            }
            node.geometry = Self.geometry(from: meshAnchor.geometry)
            node.name = "stratascan.liveMesh"
        }

        private static func geometry(from mesh: ARMeshGeometry) -> SCNGeometry {
            let sources = [
                SCNGeometrySource(
                    buffer: mesh.vertices.buffer,
                    vertexFormat: mesh.vertices.format,
                    semantic: .vertex,
                    vertexCount: mesh.vertices.count,
                    dataOffset: mesh.vertices.offset,
                    dataStride: mesh.vertices.stride
                ),
                SCNGeometrySource(
                    buffer: mesh.normals.buffer,
                    vertexFormat: mesh.normals.format,
                    semantic: .normal,
                    vertexCount: mesh.normals.count,
                    dataOffset: mesh.normals.offset,
                    dataStride: mesh.normals.stride
                )
            ]
            let surfaceElement = SCNGeometryElement(
                buffer: mesh.faces.buffer,
                primitiveType: .triangles,
                primitiveCount: mesh.faces.count,
                bytesPerIndex: mesh.faces.bytesPerIndex
            )
            let edgeElement = SCNGeometryElement(
                buffer: mesh.faces.buffer,
                primitiveType: .triangles,
                primitiveCount: mesh.faces.count,
                bytesPerIndex: mesh.faces.bytesPerIndex
            )
            // These are ARKit's real triangle faces, not a resampled point
            // cloud. A filled, low-opacity surface communicates the captured
            // shape; the second element provides just enough topology to make
            // new surfaces and gaps legible against the camera feed.
            let geometry = SCNGeometry(sources: sources, elements: [surfaceElement, edgeElement])
            let surfaceMaterial = SCNMaterial()
            surfaceMaterial.lightingModel = .constant
            surfaceMaterial.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.22)
            surfaceMaterial.emission.contents = UIColor.systemTeal.withAlphaComponent(0.08)
            surfaceMaterial.blendMode = .alpha
            surfaceMaterial.transparency = 0.72
            surfaceMaterial.isDoubleSided = true
            surfaceMaterial.fillMode = .fill
            surfaceMaterial.writesToDepthBuffer = false

            let edgeMaterial = SCNMaterial()
            edgeMaterial.lightingModel = .constant
            edgeMaterial.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.62)
            edgeMaterial.emission.contents = UIColor.systemTeal.withAlphaComponent(0.24)
            edgeMaterial.blendMode = .alpha
            edgeMaterial.isDoubleSided = true
            edgeMaterial.fillMode = .lines
            edgeMaterial.writesToDepthBuffer = false
            geometry.materials = [surfaceMaterial, edgeMaterial]
            return geometry
        }
    }
}

/// Presents RoomPlan's own capture view. Semantic capture must not attach the
/// RoomPlan-owned AR session to ARSCNView, because that would create a second
/// renderer/session owner while RoomPlan is running.
@MainActor
struct RoomPlanCapturePreview: UIViewRepresentable {
    let captureView: UIView

    func makeUIView(context: Context) -> UIView {
        captureView
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// Presentation-only SceneKit surface for immutable raw mesh snapshots. Package
/// loading and decoding remain in the injected detail service.
@MainActor
struct RawMeshSceneView: UIViewRepresentable {
    let snapshots: [MeshSnapshot]
    let vertexColors: [UUID: [MeshVertexColor?]]
    let cameraFrustums: [SavedCameraFrustum]
    let resetToken: UUID?

    init(
        snapshots: [MeshSnapshot],
        vertexColors: [UUID: [MeshVertexColor?]] = [:],
        cameraFrustums: [SavedCameraFrustum] = [],
        resetToken: UUID? = nil
    ) {
        self.snapshots = snapshots
        self.vertexColors = vertexColors
        self.cameraFrustums = cameraFrustums
        self.resetToken = resetToken
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "3D scan view"
        view.accessibilityHint = "Use standard gestures to move and zoom."
        view.accessibilityLanguage = "en-US"
        view.accessibilityIdentifier = AccessibilityID.scanDetailMesh
        installScene(in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard
            context.coordinator.snapshots != snapshots
                || context.coordinator.vertexColors != vertexColors
                || context.coordinator.cameraFrustums != cameraFrustums
                || context.coordinator.resetToken != resetToken
        else {
            return
        }
        view.accessibilityLabel = "3D scan view"
        installScene(in: view, coordinator: context.coordinator)
    }

    private func installScene(in view: SCNView, coordinator: Coordinator) {
        coordinator.snapshots = snapshots
        coordinator.vertexColors = vertexColors
        coordinator.cameraFrustums = cameraFrustums
        coordinator.resetToken = resetToken
        let scene = RawMeshSceneBuilder.makeScene(
            from: snapshots,
            vertexColors: vertexColors,
            cameraFrustums: cameraFrustums
        )
        view.scene = scene
        // Do not rely on SceneKit's implicit camera selection. In particular,
        // camera-control views can otherwise show only the background on device.
        view.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        view.isPlaying = true
    }

    final class Coordinator {
        var snapshots: [MeshSnapshot] = []
        var vertexColors: [UUID: [MeshVertexColor?]] = [:]
        var cameraFrustums: [SavedCameraFrustum] = []
        var resetToken: UUID?
    }
}

/// A presentation-only raw-mesh viewer that returns only points selected by a
/// SceneKit hit test. The view never writes source geometry or owns scan I/O.
@MainActor
struct RawMeshLandmarkSceneView: UIViewRepresentable {
    let snapshots: [MeshSnapshot]
    let selectedPoints: [Point3D]
    let onWorldPointSelected: (Point3D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onWorldPointSelected: onWorldPointSelected)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "3D mesh for landmark selection"
        view.accessibilityHint = "Tap a point on the mesh to select a landmark."
        view.accessibilityLanguage = "en-US"
        installScene(in: view, coordinator: context.coordinator)

        let recognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectPoint(_:)))
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.snapshots != snapshots || context.coordinator.selectedPoints != selectedPoints else {
            return
        }
        context.coordinator.onWorldPointSelected = onWorldPointSelected
        installScene(in: view, coordinator: context.coordinator)
    }

    private func installScene(in view: SCNView, coordinator: Coordinator) {
        coordinator.snapshots = snapshots
        coordinator.selectedPoints = selectedPoints
        let scene = RawMeshSceneBuilder.makeScene(from: snapshots)
        for (index, point) in selectedPoints.enumerated() {
            scene.rootNode.addChildNode(landmarkMarker(at: point, ordinal: index + 1))
        }
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        view.isPlaying = true
    }

    private func landmarkMarker(at point: Point3D, ordinal: Int) -> SCNNode {
        let marker = SCNSphere(radius: 0.035)
        marker.segmentCount = 16
        marker.firstMaterial?.diffuse.contents = UIColor.systemOrange
        marker.firstMaterial?.emission.contents = UIColor.systemOrange
        let node = SCNNode(geometry: marker)
        node.name = "alignment-landmark-\(ordinal)"
        node.position = SCNVector3(point.x, point.y, point.z)
        return node
    }

    final class Coordinator: NSObject {
        var snapshots: [MeshSnapshot] = []
        var selectedPoints: [Point3D] = []
        var onWorldPointSelected: (Point3D) -> Void

        init(onWorldPointSelected: @escaping (Point3D) -> Void) {
            self.onWorldPointSelected = onWorldPointSelected
        }

        @MainActor @objc func selectPoint(_ recognizer: UITapGestureRecognizer) {
            guard
                recognizer.state == .ended,
                let view = recognizer.view as? SCNView,
                let result = view.hitTest(recognizer.location(in: view), options: [SCNHitTestOption.firstFoundOnly: true]).first
            else {
                return
            }
            let point = result.worldCoordinates
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
            onWorldPointSelected(Point3D(x: point.x, y: point.y, z: point.z))
        }
    }
}

/// Presentation-only mesh editor for choosing two opposite corners of an
/// axis-aligned work area. It returns hit-tested points only; persistence stays
/// in the injected comparison service.
@MainActor
struct RawMeshWorkAreaSceneView: UIViewRepresentable {
    let snapshots: [MeshSnapshot]
    let firstCorner: Point3D?
    let oppositeCorner: Point3D?
    let onWorldPointSelected: (Point3D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onWorldPointSelected: onWorldPointSelected)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "3D mesh for work area selection"
        view.accessibilityHint = "Tap two opposite corners on the mesh."
        view.accessibilityLanguage = "en-US"
        installScene(in: view, coordinator: context.coordinator)

        let recognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectPoint(_:)))
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard
            context.coordinator.snapshots != snapshots
                || context.coordinator.firstCorner != firstCorner
                || context.coordinator.oppositeCorner != oppositeCorner
        else {
            context.coordinator.onWorldPointSelected = onWorldPointSelected
            return
        }
        context.coordinator.onWorldPointSelected = onWorldPointSelected
        installScene(in: view, coordinator: context.coordinator)
    }

    private func installScene(in view: SCNView, coordinator: Coordinator) {
        coordinator.snapshots = snapshots
        coordinator.firstCorner = firstCorner
        coordinator.oppositeCorner = oppositeCorner
        let scene = RawMeshSceneBuilder.makeScene(from: snapshots)
        if let firstCorner {
            scene.rootNode.addChildNode(cornerMarker(at: firstCorner, color: .systemOrange, name: "work-area-first-corner"))
        }
        if let oppositeCorner {
            scene.rootNode.addChildNode(cornerMarker(at: oppositeCorner, color: .systemTeal, name: "work-area-opposite-corner"))
        }
        if let firstCorner, let oppositeCorner, let box = workAreaBox(first: firstCorner, second: oppositeCorner) {
            scene.rootNode.addChildNode(box)
        }
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        view.isPlaying = true
    }

    private func cornerMarker(at point: Point3D, color: UIColor, name: String) -> SCNNode {
        let marker = SCNSphere(radius: 0.04)
        marker.segmentCount = 16
        marker.firstMaterial?.diffuse.contents = color
        marker.firstMaterial?.emission.contents = color
        let node = SCNNode(geometry: marker)
        node.name = name
        node.position = SCNVector3(point.x, point.y, point.z)
        return node
    }

    private func workAreaBox(first: Point3D, second: Point3D) -> SCNNode? {
        let width = abs(second.x - first.x)
        let height = abs(second.y - first.y)
        let length = abs(second.z - first.z)
        guard width > 0, height > 0, length > 0 else { return nil }
        let box = SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(length),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemTeal
        material.emission.contents = UIColor.systemTeal
        material.fillMode = .lines
        material.isDoubleSided = true
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.name = "work-area-boundary"
        node.position = SCNVector3(
            (first.x + second.x) / 2,
            (first.y + second.y) / 2,
            (first.z + second.z) / 2
        )
        return node
    }

    final class Coordinator: NSObject {
        var snapshots: [MeshSnapshot] = []
        var firstCorner: Point3D?
        var oppositeCorner: Point3D?
        var onWorldPointSelected: (Point3D) -> Void

        init(onWorldPointSelected: @escaping (Point3D) -> Void) {
            self.onWorldPointSelected = onWorldPointSelected
        }

        @MainActor @objc func selectPoint(_ recognizer: UITapGestureRecognizer) {
            guard
                recognizer.state == .ended,
                let view = recognizer.view as? SCNView,
                let result = view.hitTest(recognizer.location(in: view), options: [SCNHitTestOption.firstFoundOnly: true]).first
            else {
                return
            }
            let point = result.worldCoordinates
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
            onWorldPointSelected(Point3D(x: point.x, y: point.y, z: point.z))
        }
    }
}

/// Read-only SceneKit view for inspecting baseline and comparison mesh geometry
/// in the same baseline frame. The service prepares the geometry first; this
/// view never applies persistence or calculates a surface result.
@MainActor
struct RawMeshComparisonSceneView: UIViewRepresentable {
    enum DisplayMode: Equatable {
        case baseline
        case comparison
        case overlay
    }

    let baselineSnapshots: [MeshSnapshot]
    let alignedComparisonSnapshots: [MeshSnapshot]
    let workArea: ScanComparisonWorkArea
    let mode: DisplayMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "Aligned scan geometry review"
        view.accessibilityHint = "Use standard gestures to move and zoom."
        view.accessibilityLanguage = "en-US"
        installScene(in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard
            context.coordinator.baselineSnapshots != baselineSnapshots
                || context.coordinator.alignedComparisonSnapshots != alignedComparisonSnapshots
                || context.coordinator.workArea != workArea
                || context.coordinator.mode != mode
        else {
            return
        }
        installScene(in: view, coordinator: context.coordinator)
    }

    private func installScene(in view: SCNView, coordinator: Coordinator) {
        coordinator.baselineSnapshots = baselineSnapshots
        coordinator.alignedComparisonSnapshots = alignedComparisonSnapshots
        coordinator.workArea = workArea
        coordinator.mode = mode
        let layers: [RawMeshSceneBuilder.RenderLayer]
        switch mode {
        case .baseline:
            layers = [
                .init(snapshots: baselineSnapshots, color: .systemTeal, opacity: 1)
            ]
        case .comparison:
            layers = [
                .init(snapshots: alignedComparisonSnapshots, color: .systemOrange, opacity: 1)
            ]
        case .overlay:
            layers = [
                .init(snapshots: baselineSnapshots, color: .systemTeal, opacity: 0.62),
                .init(snapshots: alignedComparisonSnapshots, color: .systemOrange, opacity: 0.62)
            ]
        }
        let scene = RawMeshSceneBuilder.makeScene(layers: layers)
        scene.rootNode.addChildNode(workAreaBoundaryNode())
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        view.isPlaying = true
    }

    private func workAreaBoundaryNode() -> SCNNode {
        let width = workArea.maximum.x - workArea.minimum.x
        let height = workArea.maximum.y - workArea.minimum.y
        let length = workArea.maximum.z - workArea.minimum.z
        let box = SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(length),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGray
        material.emission.contents = UIColor.systemGray
        material.fillMode = .lines
        material.isDoubleSided = true
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.name = "comparison-work-area-boundary"
        node.position = SCNVector3(
            (workArea.minimum.x + workArea.maximum.x) / 2,
            (workArea.minimum.y + workArea.maximum.y) / 2,
            (workArea.minimum.z + workArea.maximum.z) / 2
        )
        return node
    }

    final class Coordinator {
        var baselineSnapshots: [MeshSnapshot] = []
        var alignedComparisonSnapshots: [MeshSnapshot] = []
        var workArea: ScanComparisonWorkArea?
        var mode: DisplayMode?
    }
}

/// Read-only surface-difference preview. The injected service performs all
/// correspondence checks; this view only renders observations that were
/// already classified from captured, normal-consistent local geometry.
@MainActor
struct RawMeshSurfaceDifferenceSceneView: UIViewRepresentable {
    enum DisplayMode: Equatable {
        case baselineContext
        case alignedComparison
        case observedDifferences
    }

    let baselineContextSnapshots: [MeshSnapshot]
    let alignedComparisonContextSnapshots: [MeshSnapshot]
    let preview: ScanComparisonSurfaceDifferencePreview
    let workArea: ScanComparisonWorkArea
    let mode: DisplayMode

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "Scan surface difference preview"
        view.accessibilityHint = "Use standard gestures to move and zoom."
        view.accessibilityLanguage = "en-US"
        installScene(in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard
            context.coordinator.baselineContextSnapshots != baselineContextSnapshots
                || context.coordinator.alignedComparisonContextSnapshots != alignedComparisonContextSnapshots
                || context.coordinator.preview != preview
                || context.coordinator.workArea != workArea
                || context.coordinator.mode != mode
        else {
            return
        }
        installScene(in: view, coordinator: context.coordinator)
    }

    private func installScene(in view: SCNView, coordinator: Coordinator) {
        coordinator.baselineContextSnapshots = baselineContextSnapshots
        coordinator.alignedComparisonContextSnapshots = alignedComparisonContextSnapshots
        coordinator.preview = preview
        coordinator.workArea = workArea
        coordinator.mode = mode

        let layers = renderLayers()

        let scene = RawMeshSceneBuilder.makeScene(layers: layers)
        scene.rootNode.addChildNode(workAreaBoundaryNode())
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        view.accessibilityValue = accessibilityValue
        view.isPlaying = true
    }

    private func renderLayers() -> [RawMeshSceneBuilder.RenderLayer] {
        switch mode {
        case .baselineContext:
            return [
                .init(snapshots: baselineContextSnapshots, color: .systemGray, opacity: 0.85)
            ]
        case .alignedComparison:
            return [
                .init(snapshots: alignedComparisonContextSnapshots, color: .systemBlue, opacity: 0.85)
            ]
        case .observedDifferences:
            var layers: [RawMeshSceneBuilder.RenderLayer] = [
                .init(snapshots: baselineContextSnapshots, color: .systemGray, opacity: 0.20)
            ]
            for observationClass in [
                ObservedSurfaceDifferenceClass.coincident,
                .towardBaselineNormal,
                .againstBaselineNormal
            ] {
                let points = preview.observations
                    .filter { $0.classification == observationClass }
                    .map(\.point)
                guard let pointSnapshot = pointSnapshot(for: points) else { continue }
                layers.append(
                    .init(
                        snapshots: [pointSnapshot],
                        color: color(for: observationClass),
                        opacity: 1
                    )
                )
            }
            return layers
        }
    }

    private var accessibilityValue: String {
        switch mode {
        case .baselineContext:
            "Before scan surface inside the work area"
        case .alignedComparison:
            "Aligned after scan surface inside the work area"
        case .observedDifferences:
            "Only observed differences between nearby, aligned surfaces"
        }
    }

    private func pointSnapshot(for points: [Point3D]) -> MeshSnapshot? {
        guard !points.isEmpty else { return nil }
        return try? MeshSnapshot(
            anchorID: UUID(),
            worldFromAnchor: .identity,
            vertices: points,
            normals: [],
            faces: []
        )
    }

    private func color(for classification: ObservedSurfaceDifferenceClass) -> UIColor {
        switch classification {
        case .coincident:
            .systemTeal
        case .towardBaselineNormal:
            .systemOrange
        case .againstBaselineNormal:
            .systemPurple
        }
    }

    private func workAreaBoundaryNode() -> SCNNode {
        let box = SCNBox(
            width: CGFloat(workArea.maximum.x - workArea.minimum.x),
            height: CGFloat(workArea.maximum.y - workArea.minimum.y),
            length: CGFloat(workArea.maximum.z - workArea.minimum.z),
            chamferRadius: 0
        )
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGray
        material.emission.contents = UIColor.systemGray
        material.fillMode = .lines
        material.isDoubleSided = true
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.name = "surface-difference-work-area-boundary"
        node.position = SCNVector3(
            (workArea.minimum.x + workArea.maximum.x) / 2,
            (workArea.minimum.y + workArea.maximum.y) / 2,
            (workArea.minimum.z + workArea.maximum.z) / 2
        )
        return node
    }

    final class Coordinator {
        var baselineContextSnapshots: [MeshSnapshot] = []
        var alignedComparisonContextSnapshots: [MeshSnapshot] = []
        var preview: ScanComparisonSurfaceDifferencePreview?
        var workArea: ScanComparisonWorkArea?
        var mode: DisplayMode?
    }
}

/// Presentation-only SceneKit surface for the bounded point-cloud sample read
/// by the injected detail service. The source PLY file remains untouched.
@MainActor
struct PointCloudSceneView: UIViewRepresentable {
    let result: PointCloudPLYReadResult
    let vertexColors: [MeshVertexColor?]
    let cameraFrustums: [SavedCameraFrustum]

    init(
        result: PointCloudPLYReadResult,
        vertexColors: [MeshVertexColor?] = [],
        cameraFrustums: [SavedCameraFrustum] = []
    ) {
        self.result = result
        self.vertexColors = vertexColors
        self.cameraFrustums = cameraFrustums
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .black
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "Scan point cloud view"
        view.accessibilityHint = "Use standard gestures to move and zoom."
        view.accessibilityLanguage = "en-US"
        installScene(in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.result != result
            || context.coordinator.vertexColors != vertexColors
            || context.coordinator.cameraFrustums != cameraFrustums
        else {
            return
        }
        view.accessibilityLabel = "Scan point cloud view"
        installScene(in: view, coordinator: context.coordinator)
    }

    private func installScene(in view: SCNView, coordinator: Coordinator) {
        coordinator.result = result
        coordinator.vertexColors = vertexColors
        coordinator.cameraFrustums = cameraFrustums
        let scene = PointCloudSceneBuilder.makeScene(
            from: result.points,
            vertexColors: vertexColors,
            cameraFrustums: cameraFrustums
        )
        view.scene = scene
        view.pointOfView = scene.rootNode.childNodes.first(where: { $0.camera != nil })
        view.isPlaying = true
    }

    final class Coordinator {
        var result: PointCloudPLYReadResult?
        var vertexColors: [MeshVertexColor?] = []
        var cameraFrustums: [SavedCameraFrustum] = []
    }
}

/// Presentation-only SceneKit surface for one integrity-checked promoted LOD.
/// Discovery and binary reads remain in the injected detail service.
@MainActor
struct ProcessedSurfaceSceneView: UIViewRepresentable {
    let surface: ProcessedSurfaceLOD
    let resetToken: UUID?

    init(surface: ProcessedSurfaceLOD, resetToken: UUID? = nil) {
        self.surface = surface
        self.resetToken = resetToken
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .secondarySystemBackground
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.antialiasingMode = .multisampling4X
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = "Bounded processed scan surface view"
        view.accessibilityHint = "Use standard gestures to move and zoom."
        view.accessibilityLanguage = "en-US"
        installScene(in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.surface != surface
            || context.coordinator.resetToken != resetToken
        else { return }
        installScene(in: view, coordinator: context.coordinator)
    }

    private func installScene(in view: SCNView, coordinator: Coordinator) {
        coordinator.surface = surface
        coordinator.resetToken = resetToken
        let scene = ProcessedSurfaceSceneBuilder.makeScene(from: surface)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(
            withName: "processed-surface-camera",
            recursively: true
        )
        view.isPlaying = true
    }

    final class Coordinator {
        var surface: ProcessedSurfaceLOD?
        var resetToken: UUID?
    }
}

@MainActor
struct ScanShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ viewController: UIActivityViewController, context: Context) {}
}

@MainActor
enum RawMeshSceneBuilder {
    struct RenderLayer {
        let snapshots: [MeshSnapshot]
        let color: UIColor
        let opacity: CGFloat
    }

    static func makeScene(
        from snapshots: [MeshSnapshot],
        vertexColors: [UUID: [MeshVertexColor?]] = [:],
        cameraFrustums: [SavedCameraFrustum] = []
    ) -> SCNScene {
        let scene = SCNScene()
        var framingSamples: [Point3D] = []
        framingSamples.reserveCapacity(4_096)
        let totalVertexCount = snapshots.reduce(0) { $0 + $1.vertices.count }
        // The source mesh may contain a transient distant AR anchor. Keep a
        // bounded, evenly sampled set only for the initial camera fit; every
        // source node remains in the scene unchanged and can still be reached
        // with SceneKit's normal pan/zoom controls.
        let framingStride = max(1, totalVertexCount / 4_096)
        var vertexOrdinal = 0

        for snapshot in snapshots {
            guard let node = meshNode(from: snapshot, vertexColors: vertexColors[snapshot.anchorID]) else {
                continue
            }
            scene.rootNode.addChildNode(node)
            for vertex in snapshot.vertices {
                defer { vertexOrdinal += 1 }
                guard vertexOrdinal.isMultiple(of: framingStride) else { continue }
                let worldVertex = snapshot.worldFromAnchor.applying(to: vertex)
                guard worldVertex.x.isFinite, worldVertex.y.isFinite, worldVertex.z.isFinite else {
                    continue
                }
                framingSamples.append(worldVertex)
            }
        }

        SavedCameraFrustumSceneBuilder.add(cameraFrustums, to: scene)
        addLighting(to: scene)
        if let bounds = RawMeshBounds.robustFramingBounds(from: framingSamples) {
            addCamera(to: scene, bounds: bounds)
        }
        return scene
    }

    static func makeScene(layers: [RenderLayer]) -> SCNScene {
        let scene = SCNScene()
        var framingSamples: [Point3D] = []
        framingSamples.reserveCapacity(4_096)
        let totalVertexCount = layers.reduce(0) { partial, layer in
            partial + layer.snapshots.reduce(0) { $0 + $1.vertices.count }
        }
        let framingStride = max(1, totalVertexCount / 4_096)
        var vertexOrdinal = 0

        for layer in layers {
            for snapshot in layer.snapshots {
                guard let node = meshNode(
                    from: snapshot,
                    vertexColors: nil,
                    materialColor: layer.color,
                    opacity: layer.opacity
                ) else {
                    continue
                }
                scene.rootNode.addChildNode(node)
                for vertex in snapshot.vertices {
                    defer { vertexOrdinal += 1 }
                    guard vertexOrdinal.isMultiple(of: framingStride) else { continue }
                    let worldVertex = snapshot.worldFromAnchor.applying(to: vertex)
                    guard worldVertex.x.isFinite, worldVertex.y.isFinite, worldVertex.z.isFinite else {
                        continue
                    }
                    framingSamples.append(worldVertex)
                }
            }
        }

        addLighting(to: scene)
        if let bounds = RawMeshBounds.robustFramingBounds(from: framingSamples) {
            addCamera(to: scene, bounds: bounds)
        }
        return scene
    }

    private static func meshNode(
        from snapshot: MeshSnapshot,
        vertexColors: [MeshVertexColor?]?,
        materialColor: UIColor? = nil,
        opacity: CGFloat = 1
    ) -> SCNNode? {
        guard !snapshot.vertices.isEmpty else {
            return nil
        }

        let vertices = snapshot.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        let sources = geometrySources(for: snapshot, vertices: vertices)
        guard let geometry = baseGeometry(
            sources: sources,
            snapshot: snapshot,
            vertices: vertices
        ) else {
            return nil
        }
        geometry.materials = [baseMaterial(for: snapshot, color: materialColor, opacity: opacity)]

        let node = SCNNode(geometry: geometry)
        // Vertices remain anchor-local; this applies the persisted worldFromAnchor relation unchanged.
        node.simdTransform = simdTransform(from: snapshot.worldFromAnchor)
        if let textureOverlay = derivedTextureOverlay(
            snapshot: snapshot,
            vertexColors: vertexColors,
            opacity: opacity
        ) {
            node.addChildNode(textureOverlay)
        } else if let colorOverlay = projectedColorOverlay(
            sources: sources,
            snapshot: snapshot,
            vertices: vertices,
            vertexColors: vertexColors,
            opacity: opacity
        ) {
            node.addChildNode(colorOverlay)
        }
        return node
    }

    private static func geometrySources(for snapshot: MeshSnapshot, vertices: [SCNVector3]) -> [SCNGeometrySource] {
        var sources = [SCNGeometrySource(vertices: vertices)]
        if snapshot.normals.count == snapshot.vertices.count {
            let normals = snapshot.normals.map { SCNVector3($0.x, $0.y, $0.z) }
            sources.append(SCNGeometrySource(normals: normals))
        }
        return sources
    }

    private static func baseGeometry(
        sources: [SCNGeometrySource],
        snapshot: MeshSnapshot,
        vertices: [SCNVector3]
    ) -> SCNGeometry? {
        let validFaces = validFaces(in: snapshot)
        if !validFaces.isEmpty {
            guard let element = triangleElement(for: validFaces) else { return nil }
            return SCNGeometry(sources: sources, elements: [element])
        }

        guard let element = pointElement(for: vertices.indices) else { return nil }
        return SCNGeometry(sources: sources, elements: [element])
    }

    /// Camera color is an overlay, not a fallback material. A triangle is
    /// eligible only when every one of its vertices has a real projection into
    /// a retained calibrated image. The neutral base geometry remains visible
    /// beneath all unprojected areas.
    private static func projectedColorOverlay(
        sources: [SCNGeometrySource],
        snapshot: MeshSnapshot,
        vertices: [SCNVector3],
        vertexColors: [MeshVertexColor?]?,
        opacity: CGFloat
    ) -> SCNNode? {
        guard let vertexColors, vertexColors.count == snapshot.vertices.count else {
            return nil
        }

        let colorComponents = vertexColors.flatMap { color -> [Float] in
            guard let color else { return [0, 0, 0, 0] }
            let scale: Float = 1 / 255
            return [
                Float(color.red) * scale,
                Float(color.green) * scale,
                Float(color.blue) * scale,
                Float(color.alpha) * scale
            ]
        }
        let colorData = colorComponents.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: snapshot.vertices.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let geometry: SCNGeometry
        let validFaces = validFaces(in: snapshot)
        if !validFaces.isEmpty {
            let coloredFaces = validFaces.filter { face in
                face.indices.allSatisfy { vertexColors[$0] != nil }
            }
            guard let element = triangleElement(for: coloredFaces) else { return nil }
            geometry = SCNGeometry(sources: sources + [colorSource], elements: [element])
        } else {
            let coloredVertexIndices = vertices.indices.filter { vertexColors[$0] != nil }
            guard let element = pointElement(for: coloredVertexIndices) else { return nil }
            geometry = SCNGeometry(sources: sources + [colorSource], elements: [element])
        }

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.transparency = opacity
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]

        let overlay = SCNNode(geometry: geometry)
        overlay.renderingOrder = 1
        return overlay
    }

    /// Builds a bounded, display-only textured surface from the already
    /// verified vertex colours. It duplicates just the fully observed faces so
    /// each receives a private atlas tile; source mesh files, UVs, and image
    /// keyframes remain unchanged. Point-only snapshots retain the vertex
    /// colour overlay path above because they have no faces to texture.
    private static func derivedTextureOverlay(
        snapshot: MeshSnapshot,
        vertexColors: [MeshVertexColor?]?,
        opacity: CGFloat
    ) -> SCNNode? {
        guard let vertexColors,
              let atlas = DerivedMeshTextureAtlasBuilder().build(
                snapshot: snapshot,
                vertexColors: vertexColors
              ),
              let textureImage = textureImage(from: atlas)
        else {
            return nil
        }

        var texturedVertices: [SCNVector3] = []
        var textureCoordinates: [CGPoint] = []
        texturedVertices.reserveCapacity(atlas.faces.count * 3)
        textureCoordinates.reserveCapacity(atlas.faces.count * 3)

        for face in atlas.faces {
            guard face.sourceVertexIndices.count == 3,
                  face.textureCoordinates.count == 3
            else {
                return nil
            }
            for index in 0..<3 {
                let sourceVertexIndex = face.sourceVertexIndices[index]
                guard snapshot.vertices.indices.contains(sourceVertexIndex) else {
                    return nil
                }
                let vertex = snapshot.vertices[sourceVertexIndex]
                let coordinate = face.textureCoordinates[index]
                texturedVertices.append(SCNVector3(vertex.x, vertex.y, vertex.z))
                // CoreGraphics images are top-left-origin while SceneKit UVs
                // are bottom-left-origin. Each atlas tile interpolates real
                // observed vertex colours, so retaining the proper mapping is
                // required for the bounded preview to stay truthful.
                textureCoordinates.append(
                    CGPoint(x: CGFloat(coordinate.u), y: CGFloat(1 - coordinate.v))
                )
            }
        }

        let indices = texturedVertices.indices.compactMap { Int32(exactly: $0) }
        guard indices.count == texturedVertices.count, !indices.isEmpty else {
            return nil
        }
        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: texturedVertices),
                SCNGeometrySource(textureCoordinates: textureCoordinates)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = textureImage
        material.diffuse.magnificationFilter = .nearest
        material.diffuse.minificationFilter = .nearest
        material.diffuse.mipFilter = .none
        material.transparency = opacity
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]

        let overlay = SCNNode(geometry: geometry)
        overlay.name = "scan-derived-camera-color-atlas"
        overlay.renderingOrder = 1
        return overlay
    }

    private static func textureImage(from atlas: DerivedMeshTextureAtlas) -> UIImage? {
        guard atlas.width > 0,
              atlas.height > 0,
              atlas.rgbaBytes.count == atlas.width * atlas.height * 4,
              let provider = CGDataProvider(data: Data(atlas.rgbaBytes) as CFData),
              let image = CGImage(
                  width: atlas.width,
                  height: atlas.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: atlas.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.last.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              )
        else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private static func validFaces(in snapshot: MeshSnapshot) -> [MeshFace] {
        snapshot.faces.filter { face in
            face.indices.allSatisfy { $0 >= 0 && $0 < snapshot.vertices.count }
        }
    }

    private static func triangleElement(for faces: [MeshFace]) -> SCNGeometryElement? {
        guard !faces.isEmpty else { return nil }
        let indices = faces.flatMap(\.indices).compactMap { Int32(exactly: $0) }
        guard indices.count == faces.count * 3 else { return nil }
        return SCNGeometryElement(indices: indices, primitiveType: .triangles)
    }

    private static func pointElement(for indices: some Collection<Int>) -> SCNGeometryElement? {
        let pointIndices = indices.compactMap { Int32(exactly: $0) }
        guard !pointIndices.isEmpty else { return nil }
        let element = SCNGeometryElement(indices: pointIndices, primitiveType: .point)
        element.pointSize = 5
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 7
        return element
    }

    private static func baseMaterial(for snapshot: MeshSnapshot, color: UIColor?, opacity: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        // A matte, lit material exposes real triangle form without inventing a texture.
        material.lightingModel = snapshot.normals.count == snapshot.vertices.count
            ? .physicallyBased
            : .constant
        material.diffuse.contents = color ?? UIColor.systemTeal
        material.roughness.contents = NSNumber(value: 0.82)
        material.metalness.contents = NSNumber(value: 0)
        material.transparency = opacity
        material.isDoubleSided = true
        return material
    }

    private static func addLighting(to scene: SCNScene) {
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 650
        ambientLight.color = UIColor(white: 0.78, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1_200
        keyLight.color = UIColor.white
        let keyNode = SCNNode()
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-0.55, 0.65, 0)
        scene.rootNode.addChildNode(keyNode)
    }

    private static func addCamera(to scene: SCNScene, bounds: RawMeshBounds) {
        let largestExtent = max(bounds.largestExtent, 0.1)
        let distance = max(largestExtent * 2.25, 0.8)
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.001
        camera.zFar = Double(max(distance * 20, 100))

        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(
            bounds.center.x + distance * 0.35,
            bounds.center.y + distance * 0.25,
            bounds.center.z + distance
        )
        node.look(at: bounds.center)
        scene.rootNode.addChildNode(node)
    }

    private static func simdTransform(from transform: Transform4x4) -> simd_float4x4 {
        let columns = transform.columns
        guard columns.count == 16 else {
            return matrix_identity_float4x4
        }
        return simd_float4x4(
            SIMD4(columns[0], columns[1], columns[2], columns[3]),
            SIMD4(columns[4], columns[5], columns[6], columns[7]),
            SIMD4(columns[8], columns[9], columns[10], columns[11]),
            SIMD4(columns[12], columns[13], columns[14], columns[15])
        )
    }
}

@MainActor
enum ProcessedSurfaceSceneBuilder {
    static func makeScene(from surface: ProcessedSurfaceLOD) -> SCNScene {
        let scene = SCNScene()
        guard !surface.vertices.isEmpty,
              surface.normals.count == surface.vertices.count,
              surface.colors.count == surface.vertices.count,
              !surface.indices.isEmpty,
              surface.indices.count.isMultiple(of: 3),
              surface.indices.allSatisfy({ Int($0) < surface.vertices.count })
        else { return scene }

        let positionSource = SCNGeometrySource(
            vertices: surface.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        )
        let normalSource = SCNGeometrySource(
            normals: surface.normals.map { SCNVector3($0.x, $0.y, $0.z) }
        )
        let triangleIndices = surface.indices.compactMap(Int32.init(exactly:))
        guard triangleIndices.count == surface.indices.count else { return scene }
        let element = SCNGeometryElement(indices: triangleIndices, primitiveType: .triangles)
        var sources = [positionSource, normalSource]
        if let colorSource = colorSource(surface: surface) {
            sources.append(colorSource)
        }
        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = surface.hasObservedColors ? UIColor.white : UIColor.systemTeal
        material.roughness.contents = NSNumber(value: 0.82)
        material.metalness.contents = NSNumber(value: 0)
        material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = "processed-surface"
        scene.rootNode.addChildNode(node)
        addLighting(to: scene)
        addCamera(to: scene, bounds: RawMeshBounds(surfaceBounds: surface.robustBounds))
        return scene
    }

    private static func colorSource(surface: ProcessedSurfaceLOD) -> SCNGeometrySource? {
        guard surface.hasObservedColors else { return nil }
        let colorComponents = surface.colors.flatMap { color -> [Float] in
            guard let color else { return [0.18, 0.58, 0.62, 1] }
            let scale: Float = 1 / 255
            return [
                Float(color.red) * scale,
                Float(color.green) * scale,
                Float(color.blue) * scale,
                1
            ]
        }
        return SCNGeometrySource(
            data: colorComponents.withUnsafeBytes { Data($0) },
            semantic: .color,
            vectorCount: surface.colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
    }

    private static func addLighting(to scene: SCNScene) {
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 650
        ambient.color = UIColor(white: 0.78, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1_200
        key.color = UIColor.white
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.55, 0.65, 0)
        scene.rootNode.addChildNode(keyNode)
    }

    private static func addCamera(to scene: SCNScene, bounds: RawMeshBounds) {
        let largestExtent = max(bounds.largestExtent, 0.1)
        let distance = max(largestExtent * 2.25, 0.8)
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.001
        camera.zFar = Double(max(distance * 20, 100))
        let node = SCNNode()
        node.name = "processed-surface-camera"
        node.camera = camera
        node.position = SCNVector3(
            bounds.center.x + distance * 0.35,
            bounds.center.y + distance * 0.25,
            bounds.center.z + distance
        )
        node.look(at: bounds.center)
        scene.rootNode.addChildNode(node)
    }
}

@MainActor
private enum PointCloudSceneBuilder {
    static func makeScene(
        from points: [PointCloudPLYPoint],
        vertexColors: [MeshVertexColor?] = [],
        cameraFrustums: [SavedCameraFrustum] = []
    ) -> SCNScene {
        let scene = SCNScene()
        let validIndices = points.indices.filter { index in
            let point = points[index]
            return point.position.x.isFinite && point.position.y.isFinite && point.position.z.isFinite
        }
        guard !validIndices.isEmpty else {
            return scene
        }

        let validPoints = validIndices.map { points[$0] }
        let visibleColors = validIndices.map { index in
            vertexColors.indices.contains(index) ? vertexColors[index] : nil
        }
        let vertices = validPoints.map { point in
            SCNVector3(point.position.x, point.position.y, point.position.z)
        }
        let indices = vertices.indices.compactMap { Int32(exactly: $0) }
        guard indices.count == vertices.count else {
            return scene
        }

        guard let element = pointElement(for: indices.indices) else {
            return scene
        }
        let positionSource = SCNGeometrySource(vertices: vertices)
        let geometry = SCNGeometry(
            sources: [positionSource],
            elements: [element]
        )

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemTeal
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        if let colorOverlay = projectedColorOverlay(
            positionSource: positionSource,
            vertexColors: visibleColors
        ) {
            node.addChildNode(colorOverlay)
        }
        scene.rootNode.addChildNode(node)
        SavedCameraFrustumSceneBuilder.add(cameraFrustums, to: scene)

        var bounds = RawMeshBounds(point: validPoints[0].position)
        for point in validPoints.dropFirst() {
            bounds.include(point.position)
        }
        addCamera(to: scene, bounds: bounds)
        return scene
    }

    /// Real calibrated keyframe colour is rendered separately from the neutral
    /// depth cloud so a point with no verified projection is never given an
    /// invented camera colour.
    private static func projectedColorOverlay(
        positionSource: SCNGeometrySource,
        vertexColors: [MeshVertexColor?]
    ) -> SCNNode? {
        guard !vertexColors.isEmpty,
              vertexColors.contains(where: { $0 != nil })
        else {
            return nil
        }

        let colorComponents = vertexColors.flatMap { color -> [Float] in
            guard let color else { return [0, 0, 0, 0] }
            let scale: Float = 1 / 255
            return [
                Float(color.red) * scale,
                Float(color.green) * scale,
                Float(color.blue) * scale,
                Float(color.alpha) * scale
            ]
        }
        let colorData = colorComponents.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertexColors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )
        let coloredIndices = vertexColors.indices.filter { vertexColors[$0] != nil }
        guard let element = pointElement(for: coloredIndices) else {
            return nil
        }

        let geometry = SCNGeometry(
            sources: [positionSource, colorSource],
            elements: [element]
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.writesToDepthBuffer = false
        geometry.materials = [material]

        let overlay = SCNNode(geometry: geometry)
        overlay.renderingOrder = 1
        return overlay
    }

    private static func pointElement(for indices: some Collection<Int>) -> SCNGeometryElement? {
        let pointIndices = indices.compactMap { Int32(exactly: $0) }
        guard !pointIndices.isEmpty else {
            return nil
        }
        let element = SCNGeometryElement(indices: pointIndices, primitiveType: .point)
        element.pointSize = 5
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 8
        return element
    }

    private static func addCamera(to scene: SCNScene, bounds: RawMeshBounds) {
        let largestExtent = max(bounds.largestExtent, 0.1)
        let distance = max(largestExtent * 2.25, 0.8)
        let camera = SCNCamera()
        camera.fieldOfView = 55
        camera.zNear = 0.001
        camera.zFar = Double(max(distance * 20, 100))

        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(
            bounds.center.x + distance * 0.35,
            bounds.center.y + distance * 0.25,
            bounds.center.z + distance
        )
        node.look(at: bounds.center)
        scene.rootNode.addChildNode(node)
    }
}

/// Renders capture-time camera poses as small blue frustums. Geometry is
/// defined in each camera's local coordinate system, then placed with the
/// exact persisted `worldFromCamera` transform—no coordinate conversion or
/// synthetic screen-space point pattern is involved.
@MainActor
private enum SavedCameraFrustumSceneBuilder {
    /// This is a display aid, not a physical camera model. A short, fixed
    /// depth keeps real retained-camera positions legible without letting the
    /// overlay obscure the scanned geometry.
    private static let previewDepth: Float = 0.12
    private static let maximumVisibleFrustums = 6
    private static let minimumCameraSeparationSquared: Float = 0.25 * 0.25
    private static let overlayOpacity: CGFloat = 0.58

    static func add(_ frustums: [SavedCameraFrustum], to scene: SCNScene) {
        let selectedFrustums = selectedFrustums(from: frustums)
        guard !selectedFrustums.isEmpty else {
            return
        }

        let overlay = SCNNode()
        overlay.name = "scan-retained-keyframe-frustum-overlay"
        overlay.opacity = overlayOpacity

        for frustum in selectedFrustums {
            guard let node = node(for: frustum) else {
                continue
            }
            overlay.addChildNode(node)
        }

        guard !overlay.childNodes.isEmpty else {
            return
        }
        scene.rootNode.addChildNode(overlay)
    }

    private static func node(for frustum: SavedCameraFrustum) -> SCNNode? {
        guard hasUsableCalibration(frustum) else {
            return nil
        }
        let intrinsics = frustum.intrinsics.scaled(
            toWidth: frustum.imageWidth,
            height: frustum.imageHeight
        )
        guard intrinsics.fx.isFinite,
              intrinsics.fy.isFinite,
              intrinsics.fx > 0,
              intrinsics.fy > 0
        else {
            return nil
        }

        let corners = [
            localCameraPoint(x: 0, y: 0, intrinsics: intrinsics),
            localCameraPoint(x: Float(frustum.imageWidth - 1), y: 0, intrinsics: intrinsics),
            localCameraPoint(
                x: Float(frustum.imageWidth - 1),
                y: Float(frustum.imageHeight - 1),
                intrinsics: intrinsics
            ),
            localCameraPoint(x: 0, y: Float(frustum.imageHeight - 1), intrinsics: intrinsics)
        ]
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return nil
        }

        let vertices = [SCNVector3Zero] + corners.map { SCNVector3($0.x, $0.y, $0.z) }
        let indices: [Int32] = [
            0, 1, 0, 2, 0, 3, 0, 4,
            1, 2, 2, 3, 3, 4, 4, 1
        ]
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [element]
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemBlue
        material.emission.contents = UIColor.systemBlue.withAlphaComponent(0.12)
        // Allow scanned surfaces to naturally occlude the context overlay.
        // The frustums must never act like an opaque foreground layer.
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        geometry.materials = [material]

        guard let transform = simdTransform(from: frustum.worldFromCamera) else {
            return nil
        }
        let node = SCNNode(geometry: geometry)
        node.name = "scan-retained-keyframe-frustum"
        node.simdTransform = transform
        return node
    }

    /// Selects a small, deterministic subset of the retained frames. The
    /// source order is preserved, the first and last distinct pose are kept,
    /// and every selected item is an original calibrated frame. This does not
    /// interpolate a camera path or alter a stored pose.
    private static func selectedFrustums(from frustums: [SavedCameraFrustum]) -> [SavedCameraFrustum] {
        var distinctFrustums: [(frustum: SavedCameraFrustum, position: Point3D)] = []
        distinctFrustums.reserveCapacity(min(frustums.count, maximumVisibleFrustums))

        for frustum in frustums {
            guard hasUsableCalibration(frustum),
                  let position = cameraPosition(for: frustum)
            else {
                continue
            }
            let isNearExistingPosition = distinctFrustums.contains { candidate in
                squaredDistance(from: position, to: candidate.position) < minimumCameraSeparationSquared
            }
            guard !isNearExistingPosition else {
                continue
            }
            distinctFrustums.append((frustum, position))
        }

        guard distinctFrustums.count > maximumVisibleFrustums else {
            return distinctFrustums.map(\.frustum)
        }

        return (0..<maximumVisibleFrustums).map { index in
            let sourceIndex = index * (distinctFrustums.count - 1) / (maximumVisibleFrustums - 1)
            return distinctFrustums[sourceIndex].frustum
        }
    }

    private static func cameraPosition(for frustum: SavedCameraFrustum) -> Point3D? {
        let columns = frustum.worldFromCamera.columns
        guard columns.count == 16,
              columns.allSatisfy({ $0.isFinite })
        else {
            return nil
        }
        return Point3D(x: columns[12], y: columns[13], z: columns[14])
    }

    private static func hasUsableCalibration(_ frustum: SavedCameraFrustum) -> Bool {
        frustum.imageWidth > 0
            && frustum.imageHeight > 0
            && frustum.intrinsics.fx.isFinite
            && frustum.intrinsics.fy.isFinite
            && frustum.intrinsics.cx.isFinite
            && frustum.intrinsics.cy.isFinite
            && frustum.intrinsics.fx > 0
            && frustum.intrinsics.fy > 0
    }

    private static func squaredDistance(from lhs: Point3D, to rhs: Point3D) -> Float {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        let z = lhs.z - rhs.z
        return x * x + y * y + z * z
    }

    private static func localCameraPoint(
        x: Float,
        y: Float,
        intrinsics: CameraIntrinsics
    ) -> Point3D {
        Point3D(
            x: -((x - intrinsics.cx) / intrinsics.fx) * previewDepth,
            y: -((y - intrinsics.cy) / intrinsics.fy) * previewDepth,
            z: -previewDepth
        )
    }

    private static func simdTransform(from transform: Transform4x4) -> simd_float4x4? {
        let columns = transform.columns
        guard columns.count == 16,
              columns.allSatisfy({ $0.isFinite })
        else {
            return nil
        }
        return simd_float4x4(
            SIMD4(columns[0], columns[1], columns[2], columns[3]),
            SIMD4(columns[4], columns[5], columns[6], columns[7]),
            SIMD4(columns[8], columns[9], columns[10], columns[11]),
            SIMD4(columns[12], columns[13], columns[14], columns[15])
        )
    }
}

@MainActor
private struct RawMeshBounds {
    private var minimum: Point3D
    private var maximum: Point3D

    init(point: Point3D) {
        minimum = point
        maximum = point
    }

    init(surfaceBounds: TSDFSurfaceBounds) {
        minimum = surfaceBounds.minimum
        maximum = surfaceBounds.maximum
    }

    /// Provides a presentation-only initial fit. A small trimmed range keeps a
    /// single distant reconstruction outlier from making the useful mesh look
    /// microscopic, while never removing or transforming geometry in the scene.
    static func robustFramingBounds(from points: [Point3D]) -> RawMeshBounds? {
        guard !points.isEmpty else { return nil }
        guard points.count >= 12 else {
            var bounds = RawMeshBounds(point: points[0])
            for point in points.dropFirst() { bounds.include(point) }
            return bounds
        }

        let trimCount = max(1, Int(Float(points.count) * 0.15))
        guard trimCount * 2 < points.count else { return nil }
        let x = points.map(\.x).sorted()
        let y = points.map(\.y).sorted()
        let z = points.map(\.z).sorted()
        var bounds = RawMeshBounds(
            point: Point3D(x: x[trimCount], y: y[trimCount], z: z[trimCount])
        )
        bounds.include(
            Point3D(
                x: x[x.count - trimCount - 1],
                y: y[y.count - trimCount - 1],
                z: z[z.count - trimCount - 1]
            )
        )
        return bounds
    }

    mutating func include(_ point: Point3D) {
        minimum = Point3D(
            x: min(minimum.x, point.x),
            y: min(minimum.y, point.y),
            z: min(minimum.z, point.z)
        )
        maximum = Point3D(
            x: max(maximum.x, point.x),
            y: max(maximum.y, point.y),
            z: max(maximum.z, point.z)
        )
    }

    var center: SCNVector3 {
        SCNVector3(
            (minimum.x + maximum.x) / 2,
            (minimum.y + maximum.y) / 2,
            (minimum.z + maximum.z) / 2
        )
    }

    var largestExtent: Float {
        max(
            max(maximum.x - minimum.x, maximum.y - minimum.y),
            maximum.z - minimum.z
        )
    }
}
