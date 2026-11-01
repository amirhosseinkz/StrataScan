import CryptoKit
import Foundation

/// Formats that can be produced from the concrete scan artifacts captured by
/// StrataScan. Availability always depends on the referenced source asset
/// being present, checksum-valid, and nonempty.
public enum ScanInterchangeFormat: String, Codable, CaseIterable, Sendable {
    /// A generated full canonical binary PLY point cloud.
    case ply
    /// A glTF 2.0 binary container containing validated processed geometry.
    case glb
    /// A local-coordinate 3D Tiles 1.1 directory containing `tileset.json`
    /// and a glTF binary content file.
    case cesium3DTiles
    /// An Open Photogrammetry Format point-cloud project.
    case opf
}

/// A non-user-facing, typed reason an interchange export cannot be produced.
/// Presentation should expose only an appropriate localized unavailable state,
/// rather than manufacture an empty file.
public enum ScanInterchangeExportError: Error, Equatable, Sendable {
    case sourceUnreadable(String)
    case invalidPointCloud
    case emptyPointCloud
    case geometryTooLarge
    case invalidProjectName
    case destinationInsideSourcePackage
    case destinationAlreadyExists(String)
    case outputWriteFailed(String)
    case missingProcessedSurface
    case invalidProcessedSurface
    case outputValidationFailed(String)
}

public struct ScanInterchangeBounds: Equatable, Sendable {
    public var minimum: Point3D
    public var maximum: Point3D

    public init(minimum: Point3D, maximum: Point3D) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct ScanInterchangeFileValidation: Equatable, Sendable {
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String

    public init(relativePath: String, byteCount: Int64, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct ScanInterchangeArtifactValidation: Equatable, Sendable {
    public var format: ScanInterchangeFormat
    public var bounds: ScanInterchangeBounds
    public var hasObservedColors: Bool
    public var pointCount: Int
    public var triangleCount: Int
    public var files: [ScanInterchangeFileValidation]

    public init(
        format: ScanInterchangeFormat,
        bounds: ScanInterchangeBounds,
        hasObservedColors: Bool,
        pointCount: Int,
        triangleCount: Int,
        files: [ScanInterchangeFileValidation]
    ) {
        self.format = format
        self.bounds = bounds
        self.hasObservedColors = hasObservedColors
        self.pointCount = pointCount
        self.triangleCount = triangleCount
        self.files = files
    }
}

public struct CanonicalPLYExport: Equatable, Sendable {
    public var fileURL: URL
    public var validation: ScanInterchangeArtifactValidation

    public init(fileURL: URL, validation: ScanInterchangeArtifactValidation) {
        self.fileURL = fileURL
        self.validation = validation
    }
}

/// The paths constituting a Cesium-loadable, local-coordinate 3D Tiles export.
/// No georeference, ECEF transform, or geographic bounding region is present:
/// the consuming app must place this local-meter tileset explicitly.
public struct Cesium3DTilesExport: Equatable, Sendable {
    public var directoryURL: URL
    public var tilesetURL: URL
    public var contentGLBURL: URL
    public var validation: ScanInterchangeArtifactValidation

    public init(
        directoryURL: URL,
        tilesetURL: URL,
        contentGLBURL: URL,
        validation: ScanInterchangeArtifactValidation
    ) {
        self.directoryURL = directoryURL
        self.tilesetURL = tilesetURL
        self.contentGLBURL = contentGLBURL
        self.validation = validation
    }
}

/// The files constituting a minimal OPF point-cloud project. The project has an
/// intentionally resource-empty scene reference frame, so it makes no claim
/// about geographic placement or camera calibration that this capture lacks.
public struct OPFPointCloudExport: Equatable, Sendable {
    public var directoryURL: URL
    public var projectURL: URL
    public var pointCloudGLTFURL: URL
    public var pointCloudBinaryURL: URL
    public var validation: ScanInterchangeArtifactValidation

    public init(
        directoryURL: URL,
        projectURL: URL,
        pointCloudGLTFURL: URL,
        pointCloudBinaryURL: URL,
        validation: ScanInterchangeArtifactValidation
    ) {
        self.directoryURL = directoryURL
        self.projectURL = projectURL
        self.pointCloudGLTFURL = pointCloudGLTFURL
        self.pointCloudBinaryURL = pointCloudBinaryURL
        self.validation = validation
    }
}

/// Produces interoperable files only from integrity-validated canonical sources.
/// It never writes into or changes the source scan package.
public struct ScanInterchangeExporter {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns only formats whose complete canonical source can be preflighted.
    public func availableFormats(
        for package: ScanPackageManifest,
        packageURL: URL,
        integrity: PackageIntegrityReport,
        processedSurface: ValidatedProcessedSurface?
    ) -> [ScanInterchangeFormat] {
        var formats: [ScanInterchangeFormat] = []
        if (try? canonicalPointInput(
            from: package,
            packageURL: packageURL,
            integrity: integrity
        )) != nil {
            formats.append(.ply)
            formats.append(.opf)
        }
        if let processedSurface,
           (try? processedGeometry(from: processedSurface)) != nil {
            formats.append(.glb)
            formats.append(.cesium3DTiles)
        }
        return formats
    }

    /// Generates a full PLY from every integrity-valid canonical point record.
    public func writePLY(
        from package: ScanPackageManifest,
        packageURL: URL,
        integrity: PackageIntegrityReport,
        to destinationURL: URL
    ) throws -> CanonicalPLYExport {
        try requireOutputOutsideSourcePackage(destinationURL, packageURL: packageURL)
        let input = try canonicalPointInput(
            from: package,
            packageURL: packageURL,
            integrity: integrity
        )
        try writeCanonicalPLY(from: input, to: destinationURL)
        let readResult = try PointCloudPLYReader().read(from: destinationURL, maximumPointCount: 0)
        guard readResult.header.vertexCount == input.recordCount,
              readResult.header.containsRGBColor == input.allRecordsHaveObservedColor
        else { throw ScanInterchangeExportError.outputValidationFailed(destinationURL.path) }
        let bounds = InterchangeBounds.Finalized(input.bounds)
        return CanonicalPLYExport(
            fileURL: destinationURL,
            validation: try validation(
                format: .ply,
                bounds: bounds,
                hasColors: input.allRecordsHaveObservedColor,
                pointCount: input.recordCount,
                triangleCount: 0,
                files: [(destinationURL, destinationURL.lastPathComponent)]
            )
        )
    }

    /// Writes a glTF 2.0 GLB from a complete validated promoted surface.
    public func writeGLB(
        from surface: ValidatedProcessedSurface,
        packageURL: URL,
        to destinationURL: URL
    ) throws -> ScanInterchangeArtifactValidation {
        try requireOutputOutsideSourcePackage(destinationURL, packageURL: packageURL)
        try requireOutputOutsideSourcePackage(destinationURL, packageURL: surface.directoryURL)
        let geometry = try processedGeometry(from: surface)
        let data = try glbData(for: geometry)
        try writeNewFile(data, to: destinationURL)
        try validateGLB(at: destinationURL, geometry: geometry)
        return try validation(
            format: .glb,
            bounds: geometry.bounds,
            hasColors: geometry.colors != nil,
            pointCount: geometry.vertexCount,
            triangleCount: geometry.indexCount / 3,
            files: [(destinationURL, destinationURL.lastPathComponent)]
        )
    }

    /// Writes a self-contained 3D Tiles 1.1 directory at `destinationURL`:
    ///
    /// ```text
    /// destinationURL/
    ///   tileset.json
    ///   content/scan.glb
    /// ```
    ///
    /// The package is syntactically loadable by Cesium/3D Tiles consumers but
    /// intentionally uses only local meters. It contains no geographic region,
    /// ECEF transform, or inferred location.
    public func writeCesium3DTiles(
        from surface: ValidatedProcessedSurface,
        packageURL: URL,
        to destinationURL: URL
    ) throws -> Cesium3DTilesExport {
        try requireOutputOutsideSourcePackage(destinationURL, packageURL: packageURL)
        try requireOutputOutsideSourcePackage(destinationURL, packageURL: surface.directoryURL)
        let geometry = try processedGeometry(from: surface)
        let glb = try glbData(for: geometry)
        let tileset = try tilesetData(for: geometry.bounds)

        try writeNewDirectory(to: destinationURL) { stagingDirectory in
            let contentURL = stagingDirectory.appending(path: "content/scan.glb")
            try writeNewFile(glb, to: contentURL)
            let tilesetURL = stagingDirectory.appending(path: "tileset.json")
            try writeNewFile(tileset, to: tilesetURL)
            try validateGLB(at: contentURL, geometry: geometry)
            try validateTileset(at: tilesetURL, bounds: geometry.bounds)
        }

        let validation = try validation(
            format: .cesium3DTiles,
            bounds: geometry.bounds,
            hasColors: geometry.colors != nil,
            pointCount: geometry.vertexCount,
            triangleCount: geometry.indexCount / 3,
            files: [
                (destinationURL.appending(path: "tileset.json"), "tileset.json"),
                (destinationURL.appending(path: "content/scan.glb"), "content/scan.glb")
            ]
        )
        return Cesium3DTilesExport(
            directoryURL: destinationURL,
            tilesetURL: destinationURL.appending(path: "tileset.json"),
            contentGLBURL: destinationURL.appending(path: "content/scan.glb"),
            validation: validation
        )
    }

    /// Writes a minimal OPF 1.0 point-cloud project from canonical records.
    /// It emits an OPF-compatible external-buffer glTF point cloud,
    /// never converts confidence values into colors or fabricates camera,
    /// calibration, image, or geographic records.
    public func writeOPFPointCloud(
        from package: ScanPackageManifest,
        packageURL: URL,
        integrity: PackageIntegrityReport,
        to destinationURL: URL,
        projectName: String
    ) throws -> OPFPointCloudExport {
        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProjectName.isEmpty else {
            throw ScanInterchangeExportError.invalidProjectName
        }
        try requireOutputOutsideSourcePackage(destinationURL, packageURL: packageURL)
        let input = try canonicalPointInput(
            from: package,
            packageURL: packageURL,
            integrity: integrity
        )

        try writeNewDirectory(to: destinationURL) { stagingDirectory in
            let binaryURL = stagingDirectory.appending(path: "point-cloud.bin")
            let bounds = try writeCanonicalPointCloudBinary(from: input, to: binaryURL)
            let gltfData = try opfGLTFData(
                pointCount: input.recordCount,
                binaryByteCount: bounds.binaryByteCount,
                bounds: bounds
            )
            try writeNewFile(gltfData, to: stagingDirectory.appending(path: "point-cloud.gltf"))
            let projectData = try opfProjectData(
                projectName: normalizedProjectName
            )
            try writeNewFile(projectData, to: stagingDirectory.appending(path: "project.opf"))
            try validateOPFDirectory(
                stagingDirectory,
                input: input,
                binary: bounds
            )
        }

        let bounds = InterchangeBounds.Finalized(input.bounds)
        let validation = try validation(
            format: .opf,
            bounds: bounds,
            hasColors: input.allRecordsHaveObservedColor,
            pointCount: input.recordCount,
            triangleCount: 0,
            files: [
                (destinationURL.appending(path: "project.opf"), "project.opf"),
                (destinationURL.appending(path: "point-cloud.gltf"), "point-cloud.gltf"),
                (destinationURL.appending(path: "point-cloud.bin"), "point-cloud.bin")
            ]
        )
        return OPFPointCloudExport(
            directoryURL: destinationURL,
            projectURL: destinationURL.appending(path: "project.opf"),
            pointCloudGLTFURL: destinationURL.appending(path: "point-cloud.gltf"),
            pointCloudBinaryURL: destinationURL.appending(path: "point-cloud.bin"),
            validation: validation
        )
    }

    private func canonicalPointInput(
        from package: ScanPackageManifest,
        packageURL: URL,
        integrity: PackageIntegrityReport
    ) throws -> CanonicalSpatialChunkDescriptor {
        do {
            return try CanonicalSpatialChunkReader().open(
                packageURL: packageURL,
                manifest: package,
                integrity: integrity
            )
        } catch CanonicalSpatialChunkReadError.emptySource {
            throw ScanInterchangeExportError.emptyPointCloud
        } catch {
            throw ScanInterchangeExportError.invalidPointCloud
        }
    }

    private func writeCanonicalPLY(
        from input: CanonicalSpatialChunkDescriptor,
        to destinationURL: URL
    ) throws {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ScanInterchangeExportError.destinationAlreadyExists(destinationURL.path)
        }
        try createParentDirectory(for: destinationURL)
        let colorProperties = input.allRecordsHaveObservedColor
            ? "property uchar red\nproperty uchar green\nproperty uchar blue\n"
            : ""
        let header = """
        ply
        format binary_little_endian 1.0
        comment coordinate_system arWorld meters column-major worldFromLocal
        element vertex \(input.recordCount)
        property float x
        property float y
        property float z
        \(colorProperties)property uchar confidence
        end_header

        """
        do {
            try Data(header.utf8).write(to: destinationURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try CanonicalSpatialChunkReader().forEachBatch(in: input) { samples in
                var data = Data()
                let stride = input.allRecordsHaveObservedColor ? 16 : 13
                data.reserveCapacity(samples.count * stride)
                for sample in samples {
                    appendLittleEndian(sample.position.x, to: &data)
                    appendLittleEndian(sample.position.y, to: &data)
                    appendLittleEndian(sample.position.z, to: &data)
                    if input.allRecordsHaveObservedColor {
                        guard let color = sample.color else {
                            throw ScanInterchangeExportError.invalidPointCloud
                        }
                        data.append(contentsOf: [color.red, color.green, color.blue])
                    }
                    data.append(sample.confidence)
                }
                try handle.write(contentsOf: data)
            }
            try handle.synchronize()
        } catch let error as ScanInterchangeExportError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw ScanInterchangeExportError.outputWriteFailed(destinationURL.path)
        }
    }

    private func writeCanonicalPointCloudBinary(
        from input: CanonicalSpatialChunkDescriptor,
        to destinationURL: URL
    ) throws -> PointCloudBounds {
        try createParentDirectory(for: destinationURL)
        do {
            try Data().write(to: destinationURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer { try? handle.close() }
            try CanonicalSpatialChunkReader().forEachBatch(in: input) { samples in
                var positions = Data()
                positions.reserveCapacity(samples.count * 12)
                for sample in samples {
                    appendLittleEndian(sample.position.x, to: &positions)
                    appendLittleEndian(sample.position.y, to: &positions)
                    appendLittleEndian(sample.position.z, to: &positions)
                }
                try handle.write(contentsOf: positions)
            }
            let colorByteOffset = try checkedMultiply(input.recordCount, 12)
            if input.allRecordsHaveObservedColor {
                try CanonicalSpatialChunkReader().forEachBatch(in: input) { samples in
                    var colors = Data()
                    colors.reserveCapacity(samples.count * 3)
                    for sample in samples {
                        guard let color = sample.color else {
                            throw ScanInterchangeExportError.invalidPointCloud
                        }
                        colors.append(contentsOf: [color.red, color.green, color.blue])
                    }
                    try handle.write(contentsOf: colors)
                }
            }
            try handle.synchronize()
            return PointCloudBounds(
                bounds: InterchangeBounds.Finalized(input.bounds),
                binaryByteCount: try checkedAdd(
                    colorByteOffset,
                    input.allRecordsHaveObservedColor ? checkedMultiply(input.recordCount, 3) : 0
                ),
                colorByteOffset: input.allRecordsHaveObservedColor ? colorByteOffset : nil
            )
        } catch let error as ScanInterchangeExportError {
            throw error
        } catch {
            throw ScanInterchangeExportError.outputWriteFailed(destinationURL.path)
        }
    }

    private func processedGeometry(
        from surface: ValidatedProcessedSurface
    ) throws -> InterchangeMeshGeometry {
        guard let expectedBounds = surface.validation.bounds,
              surface.validation.isValid,
              surface.manifest.vertexCount > 0,
              surface.manifest.triangleCount > 0
        else { throw ScanInterchangeExportError.invalidProcessedSurface }
        let references = Dictionary(
            uniqueKeysWithValues: surface.manifest.geometryFiles.map { ($0.relativePath, $0) }
        )
        let files = [
            (surface.verticesURL, "geometry/vertices.bin"),
            (surface.normalsURL, "geometry/normals.bin"),
            (surface.colorsURL, "geometry/colors.bin"),
            (surface.indicesURL, "geometry/indices.bin")
        ]
        for (url, path) in files {
            guard let reference = references[path],
                  try fileByteCount(at: url, relativePath: path) == reference.byteCount,
                  try sha256(for: url, relativePath: path) == reference.sha256
            else { throw ScanInterchangeExportError.invalidProcessedSurface }
        }
        let positions = try Data(contentsOf: surface.verticesURL)
        let normals = try Data(contentsOf: surface.normalsURL)
        let sourceColors = try Data(contentsOf: surface.colorsURL)
        let indices = try Data(contentsOf: surface.indicesURL)
        let vertexCount = surface.manifest.vertexCount
        let indexCount = try checkedMultiply(surface.manifest.triangleCount, 3)
        let vectorByteCount = try checkedMultiply(vertexCount, 12)
        let colorByteCount = try checkedMultiply(vertexCount, 4)
        let indexByteCount = try checkedMultiply(indexCount, 4)
        guard positions.count == vectorByteCount,
              normals.count == vectorByteCount,
              sourceColors.count == colorByteCount,
              indices.count == indexByteCount
        else { throw ScanInterchangeExportError.invalidProcessedSurface }

        var actualBounds = InterchangeBounds()
        var observedColorCount = 0
        var exportedColors = Data()
        if surface.allVerticesHaveObservedColors {
            exportedColors.reserveCapacity(vertexCount * 4)
        }
        for index in 0..<vertexCount {
            if index % 8_192 == 0 { try Task.checkCancellation() }
            let offset = index * 12
            let point = Point3D(
                x: float32(in: positions, at: offset),
                y: float32(in: positions, at: offset + 4),
                z: float32(in: positions, at: offset + 8)
            )
            let normal = Point3D(
                x: float32(in: normals, at: offset),
                y: float32(in: normals, at: offset + 4),
                z: float32(in: normals, at: offset + 8)
            )
            let normalLength = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
            let colorOffset = index * 4
            let colorFlag = sourceColors[colorOffset + 3]
            guard areFinite(point), areFinite(normal), normalLength.isFinite,
                  normalLength > 0.5, colorFlag <= 1
            else { throw ScanInterchangeExportError.invalidProcessedSurface }
            actualBounds.include(point)
            if colorFlag == 1 {
                observedColorCount += 1
                if surface.allVerticesHaveObservedColors {
                    exportedColors.append(contentsOf: [
                        sourceColors[colorOffset], sourceColors[colorOffset + 1],
                        sourceColors[colorOffset + 2], 255
                    ])
                }
            }
        }
        for offset in stride(from: 0, to: indices.count, by: 12) {
            let first = int32(in: indices, at: offset)
            let second = int32(in: indices, at: offset + 4)
            let third = int32(in: indices, at: offset + 8)
            guard first < UInt32(vertexCount), second < UInt32(vertexCount), third < UInt32(vertexCount),
                  first != second, second != third, first != third
            else { throw ScanInterchangeExportError.invalidProcessedSurface }
        }
        guard let finalizedBounds = actualBounds.finalized,
              finalizedBounds.minimum == expectedBounds.minimum,
              finalizedBounds.maximum == expectedBounds.maximum,
              surface.hasAnyObservedColors == (observedColorCount > 0),
              surface.allVerticesHaveObservedColors == (observedColorCount == vertexCount)
        else { throw ScanInterchangeExportError.invalidProcessedSurface }
        return InterchangeMeshGeometry(
            positions: positions,
            normals: normals,
            colors: surface.allVerticesHaveObservedColors ? exportedColors : nil,
            indices: indices,
            vertexCount: vertexCount,
            indexCount: indexCount,
            bounds: finalizedBounds
        )
    }

    private func glbData(for geometry: InterchangeMeshGeometry) throws -> Data {
        let positionByteOffset = 0
        let normalByteOffset = geometry.positions.count
        let colorByteOffset = try checkedAdd(normalByteOffset, geometry.normals.count)
        let indexByteOffset = try checkedAdd(colorByteOffset, geometry.colors?.count ?? 0)
        let binaryByteCount = try checkedAdd(indexByteOffset, geometry.indices.count)
        var binary = Data()
        binary.reserveCapacity(binaryByteCount)
        binary.append(geometry.positions)
        binary.append(geometry.normals)
        if let colors = geometry.colors { binary.append(colors) }
        binary.append(geometry.indices)

        var attributes = ["POSITION": 0, "NORMAL": 1]
        var accessors: [[String: Any]] = [
            [
                "bufferView": 0,
                "componentType": 5126,
                "count": geometry.vertexCount,
                "type": "VEC3",
                "min": geometry.bounds.minimum.doubleArray,
                "max": geometry.bounds.maximum.doubleArray
            ],
            [
                "bufferView": 1,
                "componentType": 5126,
                "count": geometry.vertexCount,
                "type": "VEC3"
            ]
        ]
        var bufferViews: [[String: Any]] = [
            ["buffer": 0, "byteOffset": positionByteOffset, "byteLength": geometry.positions.count, "target": 34962],
            ["buffer": 0, "byteOffset": normalByteOffset, "byteLength": geometry.normals.count, "target": 34962]
        ]
        if let colors = geometry.colors {
            attributes["COLOR_0"] = 2
            accessors.append([
                "bufferView": 2,
                "componentType": 5121,
                "normalized": true,
                "count": geometry.vertexCount,
                "type": "VEC4"
            ])
            bufferViews.append([
                "buffer": 0,
                "byteOffset": colorByteOffset,
                "byteLength": colors.count,
                "target": 34962
            ])
        }
        let indexAccessor = accessors.count
        let indexBufferView = bufferViews.count
        accessors.append([
            "bufferView": indexBufferView,
            "componentType": 5125,
            "count": geometry.indexCount,
            "type": "SCALAR"
        ])
        bufferViews.append([
            "buffer": 0,
            "byteOffset": indexByteOffset,
            "byteLength": geometry.indices.count,
            "target": 34963
        ])

        let document: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "materials": [["doubleSided": true]],
            "meshes": [[
                "primitives": [[
                    "attributes": attributes,
                    "indices": indexAccessor,
                    "material": 0,
                    "mode": 4
                ]]
            ]],
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": binaryByteCount]]
        ]
        let json = try jsonData(for: document)
        let paddedJSON = padded(json, byte: 0x20)
        let paddedBinary = padded(binary, byte: 0)
        let jsonChunkLength = try checkedAdd(8, paddedJSON.count)
        let binaryChunkLength = try checkedAdd(8, paddedBinary.count)
        let totalLength = try checkedAdd(12, try checkedAdd(jsonChunkLength, binaryChunkLength))
        guard totalLength <= Int(UInt32.max) else {
            throw ScanInterchangeExportError.geometryTooLarge
        }

        var output = Data()
        output.reserveCapacity(totalLength)
        appendLittleEndian(UInt32(0x4654_6C67), to: &output)
        appendLittleEndian(UInt32(2), to: &output)
        appendLittleEndian(UInt32(totalLength), to: &output)
        appendLittleEndian(UInt32(paddedJSON.count), to: &output)
        appendLittleEndian(UInt32(0x4E4F_534A), to: &output)
        output.append(paddedJSON)
        appendLittleEndian(UInt32(paddedBinary.count), to: &output)
        appendLittleEndian(UInt32(0x004E_4942), to: &output)
        output.append(paddedBinary)
        return output
    }

    private func tilesetData(for bounds: InterchangeBounds.Finalized) throws -> Data {
        // 3D Tiles defines local Cartesian tileset coordinates as Z-up and
        // applies its documented glTF Y-up-to-Z-up transform at runtime. The
        // GLB itself retains the raw ARKit Y-up coordinates; this bounding box
        // is expressed in the matching 3D Tiles coordinate frame so Cesium
        // does not cull valid content. This is a format-mandated transform, not
        // an ARKit coordinate conversion or an asserted georeference.
        let center = bounds.threeDTilesCenter
        let halfAxisX = bounds.threeDTilesHalfAxisX
        let halfAxisY = bounds.threeDTilesHalfAxisY
        let halfAxisZ = bounds.threeDTilesHalfAxisZ
        let box = [
            Double(center.x), Double(center.y), Double(center.z),
            Double(halfAxisX.x), Double(halfAxisX.y), Double(halfAxisX.z),
            Double(halfAxisY.x), Double(halfAxisY.y), Double(halfAxisY.z),
            Double(halfAxisZ.x), Double(halfAxisZ.y), Double(halfAxisZ.z)
        ]
        let document: [String: Any] = [
            "asset": ["version": "1.1"],
            "geometricError": 0,
            "root": [
                "boundingVolume": ["box": box],
                "geometricError": 0,
                "content": ["uri": "content/scan.glb"]
            ]
        ]
        return try jsonData(for: document)
    }

    private func opfGLTFData(
        pointCount: Int,
        binaryByteCount: Int,
        bounds: PointCloudBounds
    ) throws -> Data {
        var attributes = ["POSITION": 0]
        var accessors: [[String: Any]] = [[
            "bufferView": 0,
            "componentType": 5126,
            "count": pointCount,
            "type": "VEC3",
            "min": bounds.bounds.minimum.doubleArray,
            "max": bounds.bounds.maximum.doubleArray
        ]]
        var bufferViews: [[String: Any]] = [[
            "buffer": 0,
            "byteOffset": 0,
            "byteLength": bounds.colorByteOffset ?? binaryByteCount,
            "target": 34962
        ]]
        if let colorByteOffset = bounds.colorByteOffset {
            attributes["COLOR_0"] = 1
            accessors.append([
                "bufferView": 1,
                "componentType": 5121,
                "normalized": true,
                "count": pointCount,
                "type": "VEC3"
            ])
            bufferViews.append([
                "buffer": 0,
                "byteOffset": colorByteOffset,
                "byteLength": try checkedMultiply(pointCount, 3),
                "target": 34962
            ])
        }
        let document: [String: Any] = [
            "asset": [
                "version": "2.0",
                "extensions": ["OPF_asset_version": ["version": "1.0"]]
            ],
            "extensionsUsed": ["KHR_materials_unlit", "OPF_asset_version"],
            "extensionsRequired": ["KHR_materials_unlit", "OPF_asset_version"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "materials": [["extensions": ["KHR_materials_unlit": [String: Any]()]]],
            "meshes": [[
                "primitives": [[
                    "attributes": attributes,
                    "material": 0,
                    "mode": 0
                ]]
            ]],
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [[
                "uri": "point-cloud.bin",
                "byteLength": binaryByteCount
            ]]
        ]
        return try jsonData(for: document)
    }

    private func opfProjectData(projectName: String) throws -> Data {
        // OPF requires UUIDs for its container and item identities. Create
        // export-local IDs rather than expose StrataScan's package or asset IDs.
        let projectID = UUID().uuidString.lowercased()
        let sceneReferenceID = UUID().uuidString.lowercased()
        let pointCloudID = UUID().uuidString.lowercased()
        let document: [String: Any] = [
            "format": "application/opf-project+json",
            "version": "1.0",
            "id": projectID,
            "name": projectName,
            "description": "",
            "items": [
                [
                    "id": sceneReferenceID,
                    "type": "scene_reference_frame",
                    "resources": [],
                    "sources": []
                ],
                [
                    "id": pointCloudID,
                    "type": "point_cloud",
                    "resources": [
                        ["uri": "point-cloud.gltf", "format": "model/gltf+json"],
                        ["uri": "point-cloud.bin", "format": "application/gltf-buffer+bin"]
                    ],
                    "sources": [["id": sceneReferenceID, "type": "scene_reference_frame"]]
                ]
            ]
        ]
        return try jsonData(for: document)
    }

    private func writeNewDirectory(
        to destinationURL: URL,
        body: (URL) throws -> Void
    ) throws {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ScanInterchangeExportError.destinationAlreadyExists(destinationURL.path)
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            throw ScanInterchangeExportError.outputWriteFailed(parentURL.path)
        }
        let stagingURL = parentURL.appending(path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        } catch {
            throw ScanInterchangeExportError.outputWriteFailed(stagingURL.path)
        }
        do {
            try body(stagingURL)
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch let error as ScanInterchangeExportError {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw ScanInterchangeExportError.outputWriteFailed(destinationURL.path)
        }
    }

    private func writeNewFile(_ data: Data, to destinationURL: URL) throws {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ScanInterchangeExportError.destinationAlreadyExists(destinationURL.path)
        }
        try createParentDirectory(for: destinationURL)
        do {
            try data.write(to: destinationURL, options: .withoutOverwriting)
        } catch {
            throw ScanInterchangeExportError.outputWriteFailed(destinationURL.path)
        }
    }

    private func createParentDirectory(for url: URL) throws {
        let parentURL = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            throw ScanInterchangeExportError.outputWriteFailed(parentURL.path)
        }
    }

    private func requireOutputOutsideSourcePackage(_ outputURL: URL, packageURL: URL) throws {
        let resolvedPackageURL = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedOutputParentURL = outputURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let packagePath = resolvedPackageURL.path.hasSuffix("/")
            ? resolvedPackageURL.path
            : resolvedPackageURL.path + "/"
        if resolvedOutputParentURL.path == resolvedPackageURL.path
            || resolvedOutputParentURL.path.hasPrefix(packagePath) {
            throw ScanInterchangeExportError.destinationInsideSourcePackage
        }
    }

    private func fileByteCount(at url: URL, relativePath: String) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let count = values.fileSize, count >= 0 else {
                throw ScanInterchangeExportError.sourceUnreadable(relativePath)
            }
            return Int64(count)
        } catch let error as ScanInterchangeExportError {
            throw error
        } catch {
            throw ScanInterchangeExportError.sourceUnreadable(relativePath)
        }
    }

    private func sha256(for url: URL, relativePath: String) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ScanInterchangeExportError.sourceUnreadable(relativePath)
        }
        defer { try? handle.close() }
        do {
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw ScanInterchangeExportError.sourceUnreadable(relativePath)
        }
    }

    private func validation(
        format: ScanInterchangeFormat,
        bounds: InterchangeBounds.Finalized,
        hasColors: Bool,
        pointCount: Int,
        triangleCount: Int,
        files: [(url: URL, path: String)]
    ) throws -> ScanInterchangeArtifactValidation {
        let validatedFiles = try files.map { file in
            let byteCount = try fileByteCount(at: file.url, relativePath: file.path)
            guard byteCount > 0 else {
                throw ScanInterchangeExportError.outputValidationFailed(file.path)
            }
            return ScanInterchangeFileValidation(
                relativePath: file.path,
                byteCount: byteCount,
                sha256: try sha256(for: file.url, relativePath: file.path)
            )
        }
        return ScanInterchangeArtifactValidation(
            format: format,
            bounds: ScanInterchangeBounds(
                minimum: bounds.minimum,
                maximum: bounds.maximum
            ),
            hasObservedColors: hasColors,
            pointCount: pointCount,
            triangleCount: triangleCount,
            files: validatedFiles
        )
    }

    private func validateGLB(
        at url: URL,
        geometry: InterchangeMeshGeometry
    ) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 28,
              int32(in: data, at: 0) == 0x4654_6C67,
              int32(in: data, at: 4) == 2,
              Int(int32(in: data, at: 8)) == data.count,
              int32(in: data, at: 16) == 0x4E4F_534A
        else { throw ScanInterchangeExportError.outputValidationFailed(url.path) }
        let jsonLength = Int(int32(in: data, at: 12))
        let jsonStart = 20
        let jsonEnd = jsonStart + jsonLength
        guard jsonEnd + 8 <= data.count,
              int32(in: data, at: jsonEnd + 4) == 0x004E_4942,
              let document = try JSONSerialization.jsonObject(
                  with: data[jsonStart..<jsonEnd]
              ) as? [String: Any],
              let accessors = document["accessors"] as? [[String: Any]],
              let meshes = document["meshes"] as? [[String: Any]],
              let primitives = meshes.first?["primitives"] as? [[String: Any]],
              let primitive = primitives.first,
              let attributes = primitive["attributes"] as? [String: Int],
              accessors.first?["count"] as? Int == geometry.vertexCount,
              accessors.first?["min"] as? [Double] == geometry.bounds.minimum.doubleArray,
              accessors.first?["max"] as? [Double] == geometry.bounds.maximum.doubleArray,
              attributes["POSITION"] == 0,
              attributes["NORMAL"] == 1,
              (attributes["COLOR_0"] != nil) == (geometry.colors != nil),
              let indexAccessor = primitive["indices"] as? Int,
              accessors[indexAccessor]["count"] as? Int == geometry.indexCount
        else { throw ScanInterchangeExportError.outputValidationFailed(url.path) }
    }

    private func validateTileset(
        at url: URL,
        bounds: InterchangeBounds.Finalized
    ) throws {
        let document = try jsonObject(at: url)
        let center = bounds.threeDTilesCenter
        let halfAxisX = bounds.threeDTilesHalfAxisX
        let halfAxisY = bounds.threeDTilesHalfAxisY
        let halfAxisZ = bounds.threeDTilesHalfAxisZ
        let expectedBox = [
            Double(center.x), Double(center.y), Double(center.z),
            Double(halfAxisX.x), Double(halfAxisX.y), Double(halfAxisX.z),
            Double(halfAxisY.x), Double(halfAxisY.y), Double(halfAxisY.z),
            Double(halfAxisZ.x), Double(halfAxisZ.y), Double(halfAxisZ.z)
        ]
        guard (document["asset"] as? [String: Any])?["version"] as? String == "1.1",
              let root = document["root"] as? [String: Any],
              (root["content"] as? [String: Any])?["uri"] as? String == "content/scan.glb",
              (root["boundingVolume"] as? [String: Any])?["box"] as? [Double] == expectedBox,
              root["transform"] == nil,
              (root["boundingVolume"] as? [String: Any])?["region"] == nil
        else { throw ScanInterchangeExportError.outputValidationFailed(url.path) }
    }

    private func validateOPFDirectory(
        _ directory: URL,
        input: CanonicalSpatialChunkDescriptor,
        binary: PointCloudBounds
    ) throws {
        let projectURL = directory.appending(path: "project.opf")
        let gltfURL = directory.appending(path: "point-cloud.gltf")
        let binaryURL = directory.appending(path: "point-cloud.bin")
        let project = try jsonObject(at: projectURL)
        let gltf = try jsonObject(at: gltfURL)
        let binaryByteCount = try fileByteCount(at: binaryURL, relativePath: "point-cloud.bin")
        guard project["format"] as? String == "application/opf-project+json",
              project["version"] as? String == "1.0",
              project["generator"] == nil,
              let items = project["items"] as? [[String: Any]],
              items.count == 2,
              items.contains(where: { $0["type"] as? String == "scene_reference_frame" }),
              items.contains(where: { $0["type"] as? String == "point_cloud" }),
              let buffers = gltf["buffers"] as? [[String: Any]],
              buffers.count == 1,
              buffers[0]["uri"] as? String == "point-cloud.bin",
              buffers[0]["byteLength"] as? Int == binary.binaryByteCount,
              binaryByteCount == Int64(binary.binaryByteCount),
              let accessors = gltf["accessors"] as? [[String: Any]],
              accessors.first?["count"] as? Int == input.recordCount,
              accessors.first?["min"] as? [Double] == binary.bounds.minimum.doubleArray,
              accessors.first?["max"] as? [Double] == binary.bounds.maximum.doubleArray,
              let meshes = gltf["meshes"] as? [[String: Any]],
              let primitives = meshes.first?["primitives"] as? [[String: Any]],
              let attributes = primitives.first?["attributes"] as? [String: Int],
              attributes["POSITION"] == 0,
              (attributes["COLOR_0"] != nil) == input.allRecordsHaveObservedColor
        else { throw ScanInterchangeExportError.outputValidationFailed(directory.path) }
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any] else {
                throw ScanInterchangeExportError.outputValidationFailed(url.path)
            }
            return object
        } catch let error as ScanInterchangeExportError {
            throw error
        } catch {
            throw ScanInterchangeExportError.outputValidationFailed(url.path)
        }
    }

    private func areFinite(_ point: Point3D) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private func float32(in data: Data, at offset: Int) -> Float {
        let bits = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }

    private func int32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ScanInterchangeExportError.geometryTooLarge }
        return value
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw ScanInterchangeExportError.geometryTooLarge }
        return value
    }

    private func jsonData(for object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw ScanInterchangeExportError.outputWriteFailed("JSON")
        }
    }

    private func padded(_ data: Data, byte: UInt8) -> Data {
        let remainder = data.count % 4
        guard remainder != 0 else { return data }
        var paddedData = data
        paddedData.append(Data(repeating: byte, count: 4 - remainder))
        return paddedData
    }

    private func appendLittleEndian(_ value: Float, to data: inout Data) {
        appendLittleEndian(value.bitPattern, to: &data)
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private struct InterchangeMeshGeometry {
    var positions: Data
    var normals: Data
    var colors: Data?
    var indices: Data
    var vertexCount: Int
    var indexCount: Int
    var bounds: InterchangeBounds.Finalized
}

private struct PointCloudBounds {
    var bounds: InterchangeBounds.Finalized
    var binaryByteCount: Int
    var colorByteOffset: Int?
}

private struct InterchangeBounds {
    private var minimum: Point3D?
    private var maximum: Point3D?

    mutating func include(_ point: Point3D) {
        guard let currentMinimum = minimum, let currentMaximum = maximum else {
            minimum = point
            maximum = point
            return
        }
        minimum = Point3D(
            x: min(currentMinimum.x, point.x),
            y: min(currentMinimum.y, point.y),
            z: min(currentMinimum.z, point.z)
        )
        maximum = Point3D(
            x: max(currentMaximum.x, point.x),
            y: max(currentMaximum.y, point.y),
            z: max(currentMaximum.z, point.z)
        )
    }

    var finalized: Finalized? {
        guard let minimum, let maximum else { return nil }
        return Finalized(minimum: minimum, maximum: maximum)
    }

    struct Finalized {
        var minimum: Point3D
        var maximum: Point3D

        init(minimum: Point3D, maximum: Point3D) {
            self.minimum = minimum
            self.maximum = maximum
        }

        init(_ bounds: CanonicalSpatialBounds) {
            minimum = bounds.minimum
            maximum = bounds.maximum
        }

        var center: Point3D {
            Point3D(
                x: (minimum.x + maximum.x) / 2,
                y: (minimum.y + maximum.y) / 2,
                z: (minimum.z + maximum.z) / 2
            )
        }

        var halfExtents: Point3D {
            Point3D(
                x: (maximum.x - minimum.x) / 2,
                y: (maximum.y - minimum.y) / 2,
                z: (maximum.z - minimum.z) / 2
            )
        }

        /// The 3D Tiles glTF runtime transform maps `(x, y, z)` to
        /// `(x, -z, y)`. These values keep the tileset bounding volume in the
        /// same coordinate frame as the rendered glTF content.
        var threeDTilesCenter: Point3D {
            let rawCenter = self.center
            return Point3D(x: rawCenter.x, y: -rawCenter.z, z: rawCenter.y)
        }

        var threeDTilesHalfAxisX: Point3D {
            Point3D(x: halfExtents.x, y: 0, z: 0)
        }

        var threeDTilesHalfAxisY: Point3D {
            Point3D(x: 0, y: 0, z: halfExtents.y)
        }

        var threeDTilesHalfAxisZ: Point3D {
            let z = halfExtents.z == 0 ? Float.zero : -halfExtents.z
            return Point3D(x: 0, y: z, z: 0)
        }
    }
}

private extension Point3D {
    var doubleArray: [Double] {
        [Double(x), Double(y), Double(z)]
    }
}
