import CryptoKit
import Foundation

public enum BenchmarkSceneKind: String, Codable, CaseIterable, Sendable {
    case planarCorner = "planar-corner"
    case staircase
    case corridorRevisit = "corridor-revisit"
    case roughRockFace = "rough-rock-face"
    case removableVolume = "known-removable-volume"
    case lowLightControl = "low-light-control"
    case lowTextureControl = "low-texture-control"
}

public enum BenchmarkReferenceStatus: String, Codable, Sendable {
    case requiredBeforeCapture = "required-before-capture"
    case independentlyCheckable = "independently-checkable"
}

public enum BenchmarkReferenceMethod: String, Codable, Sendable {
    case directMeasurement = "direct-measurement"
    case survey = "survey"
    case referenceMesh = "reference-mesh"
    case sampledVisibleReferencePoints = "sampled-visible-reference-points"
    case knownVolume = "known-volume"
}

public enum BenchmarkQuantity: String, Codable, Sendable {
    case length
    case angle
    case volume
}

public enum BenchmarkUnit: String, Codable, Sendable {
    case meter
    case degree
    case cubicMeter = "cubic-meter"
}

public enum BenchmarkPrivacyClass: String, Codable, Sendable {
    case sanitized
    case internalRestricted = "internal-restricted"
}

public enum BenchmarkPermittedUse: String, Codable, Sendable {
    case internalQuality = "internal-quality"
    case regressionTesting = "regression-testing"
    case competitiveEvaluation = "competitive-evaluation"
    case fixtureDistribution = "fixture-distribution"
}

public enum BenchmarkAssetRole: String, Codable, Sendable {
    case referenceGeometry = "reference-geometry"
    case measurementRecord = "measurement-record"
    case captureInput = "capture-input"
    case candidateGeometry = "candidate-geometry"
}

public enum BenchmarkRunArtifact: String, Codable, CaseIterable, Sendable {
    case runManifest = "run.json"
    case metrics = "metrics.json"
    case fixedViews = "fixed-views/"
    case redactedLog = "logs/redacted.ndjson"
    case checksums = "outputs/checksums.json"
}

public struct BenchmarkVector3: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    var values: [Double] { [x, y, z] }
}

public struct BenchmarkBounds: Codable, Equatable, Sendable {
    public let minimum: BenchmarkVector3
    public let maximum: BenchmarkVector3

    public init(minimum: BenchmarkVector3, maximum: BenchmarkVector3) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct BenchmarkMeasurement: Codable, Equatable, Sendable {
    public let id: String
    public let quantity: BenchmarkQuantity
    public let value: Double
    public let unit: BenchmarkUnit
    public let uncertainty: Double
    public let methodNote: String

    public init(
        id: String,
        quantity: BenchmarkQuantity,
        value: Double,
        unit: BenchmarkUnit,
        uncertainty: Double,
        methodNote: String
    ) {
        self.id = id
        self.quantity = quantity
        self.value = value
        self.unit = unit
        self.uncertainty = uncertainty
        self.methodNote = methodNote
    }
}

public struct BenchmarkReference: Codable, Equatable, Sendable {
    public let status: BenchmarkReferenceStatus
    public let method: BenchmarkReferenceMethod
    public let coordinateFrame: String
    public let uncertaintyNote: String
    public let measurements: [BenchmarkMeasurement]

    public init(
        status: BenchmarkReferenceStatus,
        method: BenchmarkReferenceMethod,
        coordinateFrame: String,
        uncertaintyNote: String,
        measurements: [BenchmarkMeasurement]
    ) {
        self.status = status
        self.method = method
        self.coordinateFrame = coordinateFrame
        self.uncertaintyNote = uncertaintyNote
        self.measurements = measurements
    }
}

public struct BenchmarkDeviceEnvironment: Codable, Equatable, Sendable {
    public let deviceModel: String
    public let operatingSystem: String
    public let requiredCapabilities: [String]

    public init(deviceModel: String, operatingSystem: String, requiredCapabilities: [String]) {
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.requiredCapabilities = requiredCapabilities
    }
}

public struct BenchmarkLighting: Codable, Equatable, Sendable {
    public let description: String
    public let minimumLux: Double?
    public let maximumLux: Double?

    public init(description: String, minimumLux: Double?, maximumLux: Double?) {
        self.description = description
        self.minimumLux = minimumLux
        self.maximumLux = maximumLux
    }
}

public struct BenchmarkCaptureProtocol: Codable, Equatable, Sendable {
    public let orderedInstructions: [String]
    public let minimumDurationSeconds: Double
    public let maximumDurationSeconds: Double
    public let minimumRangeMeters: Double
    public let maximumRangeMeters: Double
    public let requiresRevisit: Bool

    public init(
        orderedInstructions: [String],
        minimumDurationSeconds: Double,
        maximumDurationSeconds: Double,
        minimumRangeMeters: Double,
        maximumRangeMeters: Double,
        requiresRevisit: Bool
    ) {
        self.orderedInstructions = orderedInstructions
        self.minimumDurationSeconds = minimumDurationSeconds
        self.maximumDurationSeconds = maximumDurationSeconds
        self.minimumRangeMeters = minimumRangeMeters
        self.maximumRangeMeters = maximumRangeMeters
        self.requiresRevisit = requiresRevisit
    }
}

public struct BenchmarkExpectedVisibleRegion: Codable, Equatable, Sendable {
    public let coordinateFrame: String
    public let bounds: BenchmarkBounds
    public let requiredSurfaceIDs: [String]

    public init(coordinateFrame: String, bounds: BenchmarkBounds, requiredSurfaceIDs: [String]) {
        self.coordinateFrame = coordinateFrame
        self.bounds = bounds
        self.requiredSurfaceIDs = requiredSurfaceIDs
    }
}

public struct BenchmarkAssetReference: Codable, Equatable, Sendable {
    public let role: BenchmarkAssetRole
    public let relativePath: String
    public let mediaType: String
    public let byteCount: Int64
    public let sha256: String

    public init(role: BenchmarkAssetRole, relativePath: String, mediaType: String, byteCount: Int64, sha256: String) {
        self.role = role
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct BenchmarkFixedCamera: Codable, Equatable, Sendable {
    public let id: String
    /// Column-major `fixtureFromCamera`, in meters, matching the project transform convention.
    public let fixtureFromCamera: Transform4x4
    public let verticalFieldOfViewDegrees: Double
    public let widthPixels: Int
    public let heightPixels: Int

    public init(
        id: String,
        fixtureFromCamera: Transform4x4,
        verticalFieldOfViewDegrees: Double,
        widthPixels: Int,
        heightPixels: Int
    ) {
        self.id = id
        self.fixtureFromCamera = fixtureFromCamera
        self.verticalFieldOfViewDegrees = verticalFieldOfViewDegrees
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

public struct BenchmarkManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let fixtureID: String
    public let fixtureVersion: Int
    public let scene: BenchmarkSceneKind
    public let title: String
    public let purpose: String
    public let privacyClass: BenchmarkPrivacyClass
    public let permittedUses: [BenchmarkPermittedUse]
    public let deviceEnvironment: BenchmarkDeviceEnvironment
    public let lighting: BenchmarkLighting
    public let captureProtocol: BenchmarkCaptureProtocol
    public let reference: BenchmarkReference
    public let expectedVisibleRegion: BenchmarkExpectedVisibleRegion
    public let assets: [BenchmarkAssetReference]
    public let fixedCameras: [BenchmarkFixedCamera]
    public let requiredRunArtifacts: [BenchmarkRunArtifact]

    public init(
        schemaVersion: Int = BenchmarkManifest.currentSchemaVersion,
        fixtureID: String,
        fixtureVersion: Int,
        scene: BenchmarkSceneKind,
        title: String,
        purpose: String,
        privacyClass: BenchmarkPrivacyClass,
        permittedUses: [BenchmarkPermittedUse],
        deviceEnvironment: BenchmarkDeviceEnvironment,
        lighting: BenchmarkLighting,
        captureProtocol: BenchmarkCaptureProtocol,
        reference: BenchmarkReference,
        expectedVisibleRegion: BenchmarkExpectedVisibleRegion,
        assets: [BenchmarkAssetReference],
        fixedCameras: [BenchmarkFixedCamera],
        requiredRunArtifacts: [BenchmarkRunArtifact]
    ) {
        self.schemaVersion = schemaVersion
        self.fixtureID = fixtureID
        self.fixtureVersion = fixtureVersion
        self.scene = scene
        self.title = title
        self.purpose = purpose
        self.privacyClass = privacyClass
        self.permittedUses = permittedUses
        self.deviceEnvironment = deviceEnvironment
        self.lighting = lighting
        self.captureProtocol = captureProtocol
        self.reference = reference
        self.expectedVisibleRegion = expectedVisibleRegion
        self.assets = assets
        self.fixedCameras = fixedCameras
        self.requiredRunArtifacts = requiredRunArtifacts
    }
}

public struct BenchmarkValidationIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }

    public let code: String
    public let severity: Severity
    public let path: String
    public let message: String

    public init(code: String, severity: Severity, path: String, message: String) {
        self.code = code
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public struct BenchmarkValidationReport: Codable, Equatable, Sendable {
    public let fixtureID: String?
    public let scene: BenchmarkSceneKind?
    public let valid: Bool
    /// Ready to enter an E2 device run; this does not itself constitute E2 evidence.
    public let e2Ready: Bool
    public let issues: [BenchmarkValidationIssue]
    public let verifiedAssetCount: Int

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum BenchmarkContractError: Error, Equatable, Sendable {
    case unsafeFixtureRoot
    case manifestMissing
    case manifestTooLarge
    case manifestUnreadable
    case ioFailure(String)
}

public struct BenchmarkFixtureValidator: Sendable {
    public static let manifestFilename = "benchmark.json"
    public static let maximumManifestByteCount = 1_048_576
    public static let maximumAssetByteCount: Int64 = 512 * 1_048_576
    public static let maximumAssetCount = 128

    public init() {}

    public func validate(fixtureDirectory: URL) async throws -> BenchmarkValidationReport {
        try Task.checkCancellation()
        let root = fixtureDirectory.standardizedFileURL
        let rootValues = try values(for: root)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw BenchmarkContractError.unsafeFixtureRoot
        }
        let manifestURL = root.appending(path: Self.manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BenchmarkContractError.manifestMissing
        }
        guard try isContainedRegularFile(manifestURL, under: root) else {
            throw BenchmarkContractError.unsafeFixtureRoot
        }
        let manifestSize = try fileSize(manifestURL)
        guard manifestSize <= Self.maximumManifestByteCount else {
            throw BenchmarkContractError.manifestTooLarge
        }

        let manifest: BenchmarkManifest
        do {
            manifest = try JSONDecoder().decode(BenchmarkManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw BenchmarkContractError.manifestUnreadable
        }

        var issues = semanticIssues(for: manifest)
        var verifiedAssets = 0
        var declaredPaths = Set([Self.manifestFilename])
        for asset in manifest.assets.sorted(by: { $0.relativePath < $1.relativePath }) {
            try Task.checkCancellation()
            if !declaredPaths.insert(asset.relativePath).inserted { continue }
            guard isSafeRelativePath(asset.relativePath) else { continue }
            let url = root.appending(path: asset.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                issues.append(issue("ASSET_MISSING", asset.relativePath, "Declared asset is missing."))
                continue
            }
            guard try isContainedRegularFile(url, under: root) else {
                issues.append(issue("ASSET_UNSAFE", asset.relativePath, "Asset is not a contained regular file."))
                continue
            }
            let size = try fileSize(url)
            guard size == asset.byteCount else {
                issues.append(issue("ASSET_SIZE", asset.relativePath, "Declared byte count does not match the file."))
                continue
            }
            guard try sha256(url) == asset.sha256 else {
                issues.append(issue("ASSET_CHECKSUM", asset.relativePath, "Declared SHA-256 does not match the file."))
                continue
            }
            verifiedAssets += 1
        }

        let presentPaths = try regularRelativePaths(root: root)
        for path in presentPaths.subtracting(declaredPaths).sorted() {
            issues.append(issue("ASSET_UNDECLARED", path, "Sanitized fixture contains an undeclared file."))
        }

        issues.sort { ($0.code, $0.path, $0.message) < ($1.code, $1.path, $1.message) }
        let valid = !issues.contains(where: { $0.severity == .error })
        let e2Ready = valid
            && manifest.privacyClass == .sanitized
            && manifest.reference.status == .independentlyCheckable
            && !manifest.reference.measurements.isEmpty
            && !manifest.assets.isEmpty
            && verifiedAssets == manifest.assets.count
            && !manifest.fixedCameras.isEmpty

        return BenchmarkValidationReport(
            fixtureID: manifest.fixtureID,
            scene: manifest.scene,
            valid: valid,
            e2Ready: e2Ready,
            issues: issues,
            verifiedAssetCount: verifiedAssets
        )
    }

    private func semanticIssues(for manifest: BenchmarkManifest) -> [BenchmarkValidationIssue] {
        var issues: [BenchmarkValidationIssue] = []
        if manifest.schemaVersion != BenchmarkManifest.currentSchemaVersion {
            issues.append(issue("SCHEMA_VERSION", "schemaVersion", "Unsupported benchmark schema version."))
        }
        if manifest.fixtureVersion < 1 {
            issues.append(issue("FIXTURE_VERSION", "fixtureVersion", "Fixture version must be positive."))
        }
        if !isIdentifier(manifest.fixtureID) {
            issues.append(issue("FIXTURE_ID", "fixtureID", "Fixture ID must use lowercase letters, digits, and hyphens."))
        }
        requireText(manifest.title, path: "title", code: "TITLE_EMPTY", into: &issues)
        requireText(manifest.purpose, path: "purpose", code: "PURPOSE_EMPTY", into: &issues)
        requireText(manifest.deviceEnvironment.deviceModel, path: "deviceEnvironment.deviceModel", code: "DEVICE_EMPTY", into: &issues)
        requireText(manifest.deviceEnvironment.operatingSystem, path: "deviceEnvironment.operatingSystem", code: "OS_EMPTY", into: &issues)
        requireText(manifest.lighting.description, path: "lighting.description", code: "LIGHTING_EMPTY", into: &issues)
        requireText(manifest.reference.coordinateFrame, path: "reference.coordinateFrame", code: "REFERENCE_FRAME_EMPTY", into: &issues)
        requireText(manifest.reference.uncertaintyNote, path: "reference.uncertaintyNote", code: "UNCERTAINTY_NOTE_EMPTY", into: &issues)
        requireText(manifest.expectedVisibleRegion.coordinateFrame, path: "expectedVisibleRegion.coordinateFrame", code: "VISIBLE_FRAME_EMPTY", into: &issues)

        if manifest.permittedUses.isEmpty || Set(manifest.permittedUses).count != manifest.permittedUses.count {
            issues.append(issue("PERMITTED_USE", "permittedUses", "Permitted uses must be non-empty and unique."))
        }
        if manifest.deviceEnvironment.requiredCapabilities.isEmpty
            || Set(manifest.deviceEnvironment.requiredCapabilities).count != manifest.deviceEnvironment.requiredCapabilities.count {
            issues.append(issue("DEVICE_CAPABILITIES", "deviceEnvironment.requiredCapabilities", "Capabilities must be non-empty and unique."))
        }

        let protocolValue = manifest.captureProtocol
        if protocolValue.orderedInstructions.isEmpty || protocolValue.orderedInstructions.contains(where: isBlank) {
            issues.append(issue("CAPTURE_PATH", "captureProtocol.orderedInstructions", "Capture path requires ordered, non-empty instructions."))
        }
        if !validPositiveRange(protocolValue.minimumDurationSeconds, protocolValue.maximumDurationSeconds) {
            issues.append(issue("CAPTURE_DURATION", "captureProtocol", "Capture duration range must be finite, positive, and ordered."))
        }
        if !validPositiveRange(protocolValue.minimumRangeMeters, protocolValue.maximumRangeMeters) {
            issues.append(issue("CAPTURE_RANGE", "captureProtocol", "Capture distance range must be finite, positive, and ordered."))
        }
        if let minimumLux = manifest.lighting.minimumLux, !minimumLux.isFinite || minimumLux < 0 {
            issues.append(issue("LIGHTING_RANGE", "lighting.minimumLux", "Lux values must be finite and non-negative."))
        }
        if let maximumLux = manifest.lighting.maximumLux, !maximumLux.isFinite || maximumLux < 0 {
            issues.append(issue("LIGHTING_RANGE", "lighting.maximumLux", "Lux values must be finite and non-negative."))
        }
        if let minimumLux = manifest.lighting.minimumLux,
           let maximumLux = manifest.lighting.maximumLux,
           minimumLux > maximumLux {
            issues.append(issue("LIGHTING_RANGE", "lighting", "Lighting range must be ordered."))
        }

        let bounds = manifest.expectedVisibleRegion.bounds
        if !bounds.minimum.values.allSatisfy(\.isFinite)
            || !bounds.maximum.values.allSatisfy(\.isFinite)
            || zip(bounds.minimum.values, bounds.maximum.values).contains(where: { $0 >= $1 }) {
            issues.append(issue("VISIBLE_BOUNDS", "expectedVisibleRegion.bounds", "Visible bounds must be finite and strictly ordered."))
        }
        if manifest.expectedVisibleRegion.requiredSurfaceIDs.isEmpty
            || Set(manifest.expectedVisibleRegion.requiredSurfaceIDs).count != manifest.expectedVisibleRegion.requiredSurfaceIDs.count {
            issues.append(issue("VISIBLE_SURFACES", "expectedVisibleRegion.requiredSurfaceIDs", "Required surfaces must be non-empty and unique."))
        }

        let measurementIDs = manifest.reference.measurements.map(\.id)
        if Set(measurementIDs).count != measurementIDs.count {
            issues.append(issue("MEASUREMENT_DUPLICATE", "reference.measurements", "Measurement IDs must be unique."))
        }
        for (index, measurement) in manifest.reference.measurements.enumerated() {
            let path = "reference.measurements[\(index)]"
            if !isIdentifier(measurement.id) {
                issues.append(issue("MEASUREMENT_ID", path, "Measurement ID is invalid."))
            }
            if !measurement.value.isFinite || measurement.value <= 0
                || !measurement.uncertainty.isFinite || measurement.uncertainty < 0 {
                issues.append(issue("MEASUREMENT_VALUE", path, "Measurement and uncertainty must be finite and physically valid."))
            }
            if !unit(measurement.unit, matches: measurement.quantity) {
                issues.append(issue("MEASUREMENT_UNIT", path, "Measurement unit does not match its quantity."))
            }
            requireText(measurement.methodNote, path: path + ".methodNote", code: "MEASUREMENT_METHOD_EMPTY", into: &issues)
        }
        if manifest.reference.status == .independentlyCheckable && manifest.reference.measurements.isEmpty {
            issues.append(issue("REFERENCE_EMPTY", "reference.measurements", "An independently checkable reference needs measurements."))
        }

        if manifest.assets.count > Self.maximumAssetCount {
            issues.append(issue("ASSET_LIMIT", "assets", "Fixture declares too many assets."))
        }
        let assetPaths = manifest.assets.map(\.relativePath)
        if Set(assetPaths).count != assetPaths.count {
            issues.append(issue("ASSET_DUPLICATE", "assets", "Asset paths must be unique."))
        }
        for (index, asset) in manifest.assets.enumerated() {
            let path = "assets[\(index)]"
            if !isSafeRelativePath(asset.relativePath) {
                issues.append(issue("ASSET_PATH", path, "Asset path must be a safe relative path."))
            }
            if asset.byteCount <= 0 || asset.byteCount > Self.maximumAssetByteCount {
                issues.append(issue("ASSET_SIZE_LIMIT", path, "Asset byte count is outside the bounded fixture contract."))
            }
            if !isSHA256(asset.sha256) {
                issues.append(issue("ASSET_SHA256", path, "Asset SHA-256 must be 64 lowercase hexadecimal characters."))
            }
            requireText(asset.mediaType, path: path + ".mediaType", code: "ASSET_MEDIA_TYPE", into: &issues)
        }

        let cameraIDs = manifest.fixedCameras.map(\.id)
        if manifest.fixedCameras.isEmpty || Set(cameraIDs).count != cameraIDs.count {
            issues.append(issue("FIXED_CAMERAS", "fixedCameras", "Fixed render cameras must be non-empty and uniquely named."))
        }
        for (index, camera) in manifest.fixedCameras.enumerated() {
            let path = "fixedCameras[\(index)]"
            if !isIdentifier(camera.id)
                || !camera.fixtureFromCamera.columns.allSatisfy(\.isFinite)
                || !camera.verticalFieldOfViewDegrees.isFinite
                || !(1..<179).contains(camera.verticalFieldOfViewDegrees)
                || camera.widthPixels < 64 || camera.heightPixels < 64 {
                issues.append(issue("FIXED_CAMERA_INVALID", path, "Fixed camera pose, field of view, and dimensions must be valid."))
            }
        }

        let required = Set(BenchmarkRunArtifact.allCases)
        if Set(manifest.requiredRunArtifacts) != required
            || manifest.requiredRunArtifacts.count != required.count {
            issues.append(issue("RUN_ARTIFACTS", "requiredRunArtifacts", "All version-one run artifacts must be required exactly once."))
        }
        return issues
    }

    private func values(for url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw BenchmarkContractError.ioFailure(error.localizedDescription)
        }
    }

    private func isContainedRegularFile(_ url: URL, under root: URL) throws -> Bool {
        let resourceValues = try values(for: url)
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resourceValues.isRegularFile == true
            && resourceValues.isSymbolicLink != true
            && candidate.hasPrefix(base)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        Int64(try values(for: url).fileSize ?? 0)
    }

    private func sha256(_ url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BenchmarkContractError.ioFailure(error.localizedDescription)
        }
    }

    private func regularRelativePaths(root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw BenchmarkContractError.ioFailure("Unable to enumerate fixture.") }
        var paths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let resourceValues = try values(for: url)
            guard resourceValues.isSymbolicLink != true else {
                throw BenchmarkContractError.unsafeFixtureRoot
            }
            if resourceValues.isRegularFile == true {
                let relative = url.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                paths.insert(relative)
                if paths.count > Self.maximumAssetCount + 1 {
                    throw BenchmarkContractError.ioFailure("Fixture contains too many files.")
                }
            }
        }
        return paths
    }

    private func issue(_ code: String, _ path: String, _ message: String) -> BenchmarkValidationIssue {
        BenchmarkValidationIssue(code: code, severity: .error, path: path, message: message)
    }

    private func requireText(
        _ value: String,
        path: String,
        code: String,
        into issues: inout [BenchmarkValidationIssue]
    ) {
        if isBlank(value) { issues.append(issue(code, path, "Value must not be empty.")) }
    }

    private func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80, value.first?.isLetter == true else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    private func validPositiveRange(_ minimum: Double, _ maximum: Double) -> Bool {
        minimum.isFinite && maximum.isFinite && minimum > 0 && minimum <= maximum
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    private func unit(_ unit: BenchmarkUnit, matches quantity: BenchmarkQuantity) -> Bool {
        switch (quantity, unit) {
        case (.length, .meter), (.angle, .degree), (.volume, .cubicMeter): true
        default: false
        }
    }
}
