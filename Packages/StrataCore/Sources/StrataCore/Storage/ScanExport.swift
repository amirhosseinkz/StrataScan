import Foundation

/// The only payload this core exporter can describe: the original package
/// assets selected by the user. It neither converts assets nor creates a
/// container around them.
public enum ScanExportPayload: String, Codable, CaseIterable, Sendable {
    case originalAssets
}

/// A capability that can be surfaced by a presentation layer without claiming
/// support for formats or conversions that the installed package does not have.
public struct ScanExportCapability: Codable, Equatable, Sendable {
    public var payload: ScanExportPayload
    public var availableAssetKinds: [AssetKind]
    public var includesMachineReadableManifest: Bool

    public init(
        payload: ScanExportPayload,
        availableAssetKinds: [AssetKind],
        includesMachineReadableManifest: Bool
    ) {
        self.payload = payload
        self.availableAssetKinds = availableAssetKinds
        self.includesMachineReadableManifest = includesMachineReadableManifest
    }
}

/// Identifies the original package assets a user selected for export.
public struct ScanExportSelection: Codable, Equatable, Sendable {
    public var assetIDs: [UUID]

    public init(assetIDs: [UUID]) {
        self.assetIDs = assetIDs
    }
}

/// The machine-readable companion to an original-asset export.
///
/// It intentionally contains only values derived from the saved scan package
/// and the selected `ScanAssetReference` values. Its byte count can therefore
/// be included in a deterministic export-size estimate.
public struct ScanExportManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var scanID: UUID
    public var sourcePackageSchemaVersion: Int
    public var capturedAt: Date
    public var coordinateSystem: String
    public var assets: [ScanAssetReference]
    public var locationIncluded: Bool

    public init(
        schemaVersion: Int = ScanExportManifest.currentSchemaVersion,
        scanID: UUID,
        sourcePackageSchemaVersion: Int,
        capturedAt: Date,
        coordinateSystem: String,
        assets: [ScanAssetReference],
        locationIncluded: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.scanID = scanID
        self.sourcePackageSchemaVersion = sourcePackageSchemaVersion
        self.capturedAt = capturedAt
        self.coordinateSystem = coordinateSystem
        self.assets = assets
        self.locationIncluded = locationIncluded
    }
}

public enum ScanExportPrivacyCategory: String, Codable, CaseIterable, Sendable {
    case geographicLocation
    case visualMedia
    case cameraPoses
    case annotations
    case measurements
}

/// A typed privacy disclosure plus the exact package assets responsible for it.
public struct ScanExportPrivacyWarning: Codable, Equatable, Sendable, Identifiable {
    public var category: ScanExportPrivacyCategory
    public var assetIDs: [UUID]

    public var id: String { category.rawValue }

    public init(category: ScanExportPrivacyCategory, assetIDs: [UUID]) {
        self.category = category
        self.assetIDs = assetIDs
    }
}

public struct ScanExportPrivacyReport: Codable, Equatable, Sendable {
    public var warnings: [ScanExportPrivacyWarning]

    public init(warnings: [ScanExportPrivacyWarning]) {
        self.warnings = warnings
    }

    public func includes(_ category: ScanExportPrivacyCategory) -> Bool {
        warnings.contains { $0.category == category }
    }
}

/// Maps established package asset kinds to future annotation or measurement
/// records when those records acquire a persisted kind. The default makes no
/// unsupported inference about generic attachments.
public struct ScanExportPrivacyPolicy: Equatable, Sendable {
    public var annotationAssetKinds: [AssetKind]
    public var measurementAssetKinds: [AssetKind]

    public init(
        annotationAssetKinds: [AssetKind] = [],
        measurementAssetKinds: [AssetKind] = []
    ) {
        self.annotationAssetKinds = annotationAssetKinds
        self.measurementAssetKinds = measurementAssetKinds
    }

    public static let standard = ScanExportPrivacyPolicy()

    public func categories(for asset: ScanAssetReference) -> [ScanExportPrivacyCategory] {
        var categories: [ScanExportPrivacyCategory] = []

        if asset.spatialReference == .geographicWGS84 {
            categories.append(.geographicLocation)
        }

        switch asset.kind {
        case .video, .textureSource:
            categories.append(.visualMedia)
        case .frameMetadata:
            categories.append(.cameraPoses)
        default:
            break
        }

        if annotationAssetKinds.contains(asset.kind) {
            categories.append(.annotations)
        }
        if measurementAssetKinds.contains(asset.kind) {
            categories.append(.measurements)
        }
        return categories
    }
}

/// A validated export preview. `estimatedByteCount` is the sum of the selected
/// original asset byte counts and the canonical encoded export-manifest bytes;
/// it deliberately excludes filesystem and share-sheet overhead.
public struct ScanExportPreview: Equatable, Sendable {
    public var selection: ScanExportSelection
    public var selectedOriginalAssets: [ScanAssetReference]
    public var manifest: ScanExportManifest
    public var assetByteCount: Int64
    public var manifestByteCount: Int64
    public var estimatedByteCount: Int64
    public var privacy: ScanExportPrivacyReport

    public init(
        selection: ScanExportSelection,
        selectedOriginalAssets: [ScanAssetReference],
        manifest: ScanExportManifest,
        assetByteCount: Int64,
        manifestByteCount: Int64,
        estimatedByteCount: Int64,
        privacy: ScanExportPrivacyReport
    ) {
        self.selection = selection
        self.selectedOriginalAssets = selectedOriginalAssets
        self.manifest = manifest
        self.assetByteCount = assetByteCount
        self.manifestByteCount = manifestByteCount
        self.estimatedByteCount = estimatedByteCount
        self.privacy = privacy
    }
}

public enum ScanExportError: Error, Equatable, Sendable {
    case emptySelection
    case duplicateSelection(UUID)
    case missingAsset(UUID)
    case duplicateManifestAssetID(UUID)
    case invalidAssetByteCount(UUID)
    case byteCountOverflow
    case manifestEncodingFailed
}

/// Defines the pure domain work required before a caller writes or shares an
/// export. Implementations must expose only capabilities they can truthfully
/// prepare from a saved package.
public protocol ScanExporter: Sendable {
    func capabilities(for package: ScanPackageManifest) -> [ScanExportCapability]
    func preview(selection: ScanExportSelection, from package: ScanPackageManifest) throws -> ScanExportPreview
    func encodeManifest(_ manifest: ScanExportManifest) throws -> Data
}

/// Prepares selections of existing package files. It does not mutate the
/// source package and does not transform any selected artifact.
public struct OriginalAssetScanExporter: ScanExporter, Sendable {
    public var privacyPolicy: ScanExportPrivacyPolicy

    public init(privacyPolicy: ScanExportPrivacyPolicy = .standard) {
        self.privacyPolicy = privacyPolicy
    }

    public func capabilities(for package: ScanPackageManifest) -> [ScanExportCapability] {
        let kinds = uniqueKinds(in: package.assets)
        guard !kinds.isEmpty else { return [] }
        return [
            ScanExportCapability(
                payload: .originalAssets,
                availableAssetKinds: kinds,
                includesMachineReadableManifest: true
            )
        ]
    }

    public func preview(selection: ScanExportSelection, from package: ScanPackageManifest) throws -> ScanExportPreview {
        let selectedAssets = try validatedSelectedAssets(selection: selection, package: package)
        let assetByteCount = try totalByteCount(for: selectedAssets)
        let privacy = privacyReport(for: selectedAssets)
        let manifest = ScanExportManifest(
            scanID: package.localScanID,
            sourcePackageSchemaVersion: package.schemaVersion,
            capturedAt: package.createdAt,
            coordinateSystem: package.coordinateSystem,
            assets: selectedAssets,
            locationIncluded: privacy.includes(.geographicLocation)
        )
        let manifestByteCount = Int64(try encodeManifest(manifest).count)
        guard assetByteCount <= Int64.max - manifestByteCount else {
            throw ScanExportError.byteCountOverflow
        }

        return ScanExportPreview(
            selection: selection,
            selectedOriginalAssets: selectedAssets,
            manifest: manifest,
            assetByteCount: assetByteCount,
            manifestByteCount: manifestByteCount,
            estimatedByteCount: assetByteCount + manifestByteCount,
            privacy: privacy
        )
    }

    public func encodeManifest(_ manifest: ScanExportManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(manifest)
        } catch {
            throw ScanExportError.manifestEncodingFailed
        }
    }

    private func validatedSelectedAssets(
        selection: ScanExportSelection,
        package: ScanPackageManifest
    ) throws -> [ScanAssetReference] {
        guard !selection.assetIDs.isEmpty else {
            throw ScanExportError.emptySelection
        }

        var selectedIDs = Set<UUID>()
        for id in selection.assetIDs {
            guard selectedIDs.insert(id).inserted else {
                throw ScanExportError.duplicateSelection(id)
            }
        }

        var assetsByID: [UUID: ScanAssetReference] = [:]
        for asset in package.assets {
            guard assetsByID[asset.id] == nil else {
                throw ScanExportError.duplicateManifestAssetID(asset.id)
            }
            assetsByID[asset.id] = asset
        }

        return try selection.assetIDs.map { id in
            guard let asset = assetsByID[id] else {
                throw ScanExportError.missingAsset(id)
            }
            guard asset.byteCount >= 0 else {
                throw ScanExportError.invalidAssetByteCount(id)
            }
            return asset
        }
    }

    private func totalByteCount(for assets: [ScanAssetReference]) throws -> Int64 {
        var total = Int64.zero
        for asset in assets {
            guard asset.byteCount >= 0 else {
                throw ScanExportError.invalidAssetByteCount(asset.id)
            }
            guard total <= Int64.max - asset.byteCount else {
                throw ScanExportError.byteCountOverflow
            }
            total += asset.byteCount
        }
        return total
    }

    private func uniqueKinds(in assets: [ScanAssetReference]) -> [AssetKind] {
        var kinds: [AssetKind] = []
        for asset in assets where !kinds.contains(asset.kind) {
            kinds.append(asset.kind)
        }
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    private func privacyReport(for assets: [ScanAssetReference]) -> ScanExportPrivacyReport {
        let warnings = ScanExportPrivacyCategory.allCases.compactMap { category -> ScanExportPrivacyWarning? in
            let assetIDs = assets.compactMap { asset in
                privacyPolicy.categories(for: asset).contains(category) ? asset.id : nil
            }
            guard !assetIDs.isEmpty else { return nil }
            return ScanExportPrivacyWarning(category: category, assetIDs: assetIDs)
        }
        return ScanExportPrivacyReport(warnings: warnings)
    }
}
