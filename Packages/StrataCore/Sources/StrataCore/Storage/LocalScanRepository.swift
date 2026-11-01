import Foundation

public enum ScanRepositoryError: Error, Equatable, Sendable {
    case emptyDisplayName
    case scanNotFound(UUID)
}

public protocol ScanRepository: Sendable {
    func save(scan: ScanMetadata, manifest: ScanPackageManifest, assets: [AssetInput]) async throws
    func reopen(id: UUID) async throws -> StoredScan?
    func list() async throws -> [ScanMetadata]
    func rename(id: UUID, displayName: String, updatedAt: Date) async throws
    func save(spatialLayer: SpatialLayer, forScanID scanID: UUID) async throws
    func spatialLayers(forScanID scanID: UUID) async throws -> [SpatialLayer]
    func deleteSpatialLayer(id: UUID, forScanID scanID: UUID) async throws -> Bool
    func save(scanComparisonDraft: ScanComparisonDraft) async throws
    func latestScanComparisonDraft() async throws -> ScanComparisonDraft?
    func save(scanComparisonWorkArea: ScanComparisonWorkArea) async throws
    func scanComparisonWorkArea(forDraftID draftID: UUID) async throws -> ScanComparisonWorkArea?
    func save(scanAlignment: ScanAlignment, landmarks: ScanAlignmentLandmarkSet) async throws
    func scanAlignment(targetScanID: UUID, sourceScanID: UUID) async throws -> ScanAlignment?
    func scanAlignmentLandmarks(targetScanID: UUID, sourceScanID: UUID) async throws -> ScanAlignmentLandmarkSet?
    func delete(id: UUID) async throws
}

/// Coordinates metadata and files without exposing transaction or path details
/// to features. If database registration fails, the newly finalized package is
/// removed so it cannot masquerade as a complete saved scan.
public actor LocalScanRepository: ScanRepository {
    private let metadataStore: SQLiteMetadataStore
    private let assetStore: FileAssetStore

    public init(metadataStore: SQLiteMetadataStore, assetStore: FileAssetStore) {
        self.metadataStore = metadataStore
        self.assetStore = assetStore
    }

    public func save(scan: ScanMetadata, manifest: ScanPackageManifest, assets: [AssetInput]) async throws {
        guard scan.id == manifest.localScanID else {
            throw AssetStoreError.manifestScanIDMismatch
        }
        var packageManifest = manifest
        packageManifest.status = scan.status
        packageManifest.updatedAt = scan.updatedAt
        packageManifest.durationSeconds = scan.durationSeconds
        packageManifest.remoteScanID = scan.remoteID

        let finalized = try await assetStore.finalize(manifest: packageManifest, assets: assets)
        do {
            try await metadataStore.save(scan: scan, assets: finalized.assets)
        } catch {
            try? await assetStore.removePackage(id: scan.id)
            throw error
        }
    }

    public func reopen(id: UUID) async throws -> StoredScan? {
        guard let scan = try await metadataStore.scan(id: id) else { return nil }
        let manifest = try await assetStore.loadManifest(id: id)
        let integrity = try await assetStore.validatePackage(id: id)
        return StoredScan(scan: scan, manifest: manifest, integrity: integrity)
    }

    public func list() async throws -> [ScanMetadata] {
        try await metadataStore.allScans()
    }

    public func rename(id: UUID, displayName: String, updatedAt: Date) async throws {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty else {
            throw ScanRepositoryError.emptyDisplayName
        }
        guard try await metadataStore.rename(
            scanID: id,
            displayName: trimmedDisplayName,
            updatedAt: updatedAt
        ) else {
            throw ScanRepositoryError.scanNotFound(id)
        }
    }

    /// Persists user-authored spatial metadata only. Finalized scan assets are
    /// intentionally not read, rewritten, or otherwise mutated here.
    public func save(spatialLayer: SpatialLayer, forScanID scanID: UUID) async throws {
        try await metadataStore.save(spatialLayer: spatialLayer, forScanID: scanID)
    }

    public func spatialLayers(forScanID scanID: UUID) async throws -> [SpatialLayer] {
        try await metadataStore.spatialLayers(forScanID: scanID)
    }

    @discardableResult
    public func deleteSpatialLayer(id: UUID, forScanID scanID: UUID) async throws -> Bool {
        try await metadataStore.deleteSpatialLayer(id: id, forScanID: scanID)
    }

    /// Persists only the selected scan pair. It never alters either source scan
    /// or claims that they are aligned or ready for a calculated result.
    public func save(scanComparisonDraft: ScanComparisonDraft) async throws {
        try await metadataStore.save(scanComparisonDraft: scanComparisonDraft)
    }

    public func latestScanComparisonDraft() async throws -> ScanComparisonDraft? {
        try await metadataStore.latestScanComparisonDraft()
    }

    public func save(scanComparisonWorkArea: ScanComparisonWorkArea) async throws {
        try await metadataStore.save(scanComparisonWorkArea: scanComparisonWorkArea)
    }

    public func scanComparisonWorkArea(forDraftID draftID: UUID) async throws -> ScanComparisonWorkArea? {
        try await metadataStore.scanComparisonWorkArea(forDraftID: draftID)
    }

    /// Saves a derived rigid transform and the matched landmarks that justify
    /// it. Neither operation edits the scan packages or their source geometry.
    public func save(scanAlignment: ScanAlignment, landmarks: ScanAlignmentLandmarkSet) async throws {
        guard
            scanAlignment.targetScanID == landmarks.targetScanID,
            scanAlignment.sourceScanID == landmarks.sourceScanID
        else {
            throw AlignmentError.invalidTransform
        }
        try landmarks.validate()
        try await metadataStore.save(alignment: scanAlignment, landmarks: landmarks)
    }

    public func scanAlignment(targetScanID: UUID, sourceScanID: UUID) async throws -> ScanAlignment? {
        try await metadataStore.alignment(targetScanID: targetScanID, sourceScanID: sourceScanID)
    }

    public func scanAlignmentLandmarks(
        targetScanID: UUID,
        sourceScanID: UUID
    ) async throws -> ScanAlignmentLandmarkSet? {
        try await metadataStore.scanAlignmentLandmarks(targetScanID: targetScanID, sourceScanID: sourceScanID)
    }

    public func delete(id: UUID) async throws {
        try await metadataStore.delete(scanID: id)
        try await assetStore.removePackage(id: id)
    }
}
