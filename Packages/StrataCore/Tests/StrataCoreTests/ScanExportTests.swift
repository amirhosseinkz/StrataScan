import Foundation
import Testing
@testable import StrataCore

@Suite("Scan export domain")
struct ScanExportTests {
    @Test("Original-asset export preserves the selected references and includes its encoded manifest in the estimate")
    func previewsExactOriginalAssetsAndBytes() throws {
        let first = asset(kind: .pointCloud, path: "pointcloud/cloud.ply", byteCount: 128)
        let second = asset(kind: .meshRaw, path: "mesh/raw-mesh.json", byteCount: 256)
        let package = manifest(assets: [first, second])
        let exporter = OriginalAssetScanExporter()

        let capabilities = exporter.capabilities(for: package)
        #expect(capabilities == [
            ScanExportCapability(
                payload: .originalAssets,
                availableAssetKinds: [.meshRaw, .pointCloud],
                includesMachineReadableManifest: true
            )
        ])

        let preview = try exporter.preview(
            selection: ScanExportSelection(assetIDs: [second.id, first.id]),
            from: package
        )

        #expect(preview.selectedOriginalAssets == [second, first])
        #expect(preview.manifest.assets == [second, first])
        #expect(preview.assetByteCount == 384)
        #expect(preview.manifestByteCount == Int64(try exporter.encodeManifest(preview.manifest).count))
        #expect(preview.estimatedByteCount == preview.assetByteCount + preview.manifestByteCount)
        #expect(preview.privacy.warnings.isEmpty)
    }

    @Test("Selections reject duplicate and unavailable assets")
    func rejectsDuplicateAndMissingSelections() throws {
        let stored = asset(kind: .meshRaw, path: "mesh/raw-mesh.json", byteCount: 64)
        let package = manifest(assets: [stored])
        let exporter = OriginalAssetScanExporter()
        let missingID = UUID()

        #expect(throws: ScanExportError.duplicateSelection(stored.id)) {
            try exporter.preview(
                selection: ScanExportSelection(assetIDs: [stored.id, stored.id]),
                from: package
            )
        }
        #expect(throws: ScanExportError.missingAsset(missingID)) {
            try exporter.preview(
                selection: ScanExportSelection(assetIDs: [missingID]),
                from: package
            )
        }
    }

    @Test("Privacy disclosures are derived from selected spatial references and typed asset kinds")
    func reportsPrivacyWarningsForSensitiveSelectedAssets() throws {
        let geographic = asset(
            kind: .gisLayer,
            path: "gis/site.geojson",
            byteCount: 20,
            spatialReference: .geographicWGS84
        )
        let video = asset(kind: .video, path: "video/capture.mov", byteCount: 30)
        let texture = asset(kind: .textureSource, path: "texture/frame.jpg", byteCount: 40)
        let frameMetadata = asset(kind: .frameMetadata, path: "frames/frame-metadata.ndjson", byteCount: 50)
        let annotations = asset(kind: .manifestAttachment, path: "notes/annotations.json", byteCount: 60)
        let measurements = asset(kind: .alignment, path: "tools/measurements.json", byteCount: 70)
        let selected = [geographic, video, texture, frameMetadata, annotations, measurements]
        let exporter = OriginalAssetScanExporter(
            privacyPolicy: ScanExportPrivacyPolicy(
                annotationAssetKinds: [.manifestAttachment],
                measurementAssetKinds: [.alignment]
            )
        )

        let preview = try exporter.preview(
            selection: ScanExportSelection(assetIDs: selected.map(\.id)),
            from: manifest(assets: selected)
        )

        #expect(preview.manifest.locationIncluded)
        #expect(preview.privacy.warnings == [
            ScanExportPrivacyWarning(category: .geographicLocation, assetIDs: [geographic.id]),
            ScanExportPrivacyWarning(category: .visualMedia, assetIDs: [video.id, texture.id]),
            ScanExportPrivacyWarning(category: .cameraPoses, assetIDs: [frameMetadata.id]),
            ScanExportPrivacyWarning(category: .annotations, assetIDs: [annotations.id]),
            ScanExportPrivacyWarning(category: .measurements, assetIDs: [measurements.id])
        ])
    }

    private func manifest(assets: [ScanAssetReference]) -> ScanPackageManifest {
        ScanPackageManifest(
            localScanID: UUID(uuidString: "B85C223E-53B5-430A-AE4A-9590A4F778DA") ?? UUID(),
            status: .completed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            assets: assets
        )
    }

    private func asset(
        kind: AssetKind,
        path: String,
        byteCount: Int64,
        spatialReference: SpatialReferenceKind = .scanLocal
    ) -> ScanAssetReference {
        ScanAssetReference(
            kind: kind,
            relativePath: path,
            byteCount: byteCount,
            sha256: "fixture-\(path)",
            spatialReference: spatialReference,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
