import Foundation

struct ScanDerivedStageEvidence: Sendable {
    var disposition: ScanInspectionDisposition
    var metrics: ScanInspectionMetrics
}

struct ScanDerivedInspection: Sendable {
    var reconstruction: ScanDerivedStageEvidence
    var surface: ScanDerivedStageEvidence
    var consistency: ScanDerivedStageEvidence
    var viewer: ScanDerivedStageEvidence
    var export: ScanDerivedStageEvidence
    var findings: [ScanInspectionFinding]
}

/// Read-only validation of derived reconstruction work. It deliberately uses
/// the same production readers used by the viewer and exporter where possible.
struct ScanPackageDerivedInspector: Sendable {
    private static let maximumJSONBytes = 1_048_576
    private static let maximumArtifactCount = 100_000
    private static let maximumDeltaBytes = 512 * 1_024 * 1_024
    private static let deltaMagic = Data("STRTSDFD".utf8)
    private static let deltaHeaderBytes = 20
    private static let deltaRecordBytes = 24

    func inspect(
        packageURL: URL,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport,
        archiveSource: TSDFReconstructionSource?,
        canonicalDisposition: ScanInspectionDisposition,
        rawMeshDisposition: ScanInspectionDisposition,
        suppliedRoot: URL?
    ) async throws -> ScanDerivedInspection {
        do {
            try Task.checkCancellation()
            guard let suppliedRoot else {
                return unavailableInspection(
                    canonicalDisposition: canonicalDisposition,
                    rawMeshDisposition: rawMeshDisposition
                )
            }
            let roots = try resolvedRoots(from: suppliedRoot)
            let reconstruction = try inspectReconstruction(
                scanID: manifest.localScanID,
                archiveSource: archiveSource,
                processingRoot: roots.processing
            )
            let surfaceResult = try await inspectSurface(
                packageURL: packageURL,
                manifest: manifest,
                integrity: integrity,
                archiveSource: archiveSource,
                derivedRoot: roots.derived,
                processingRoot: roots.processing
            )
            let consistency = inspectConsistency(
                archiveSource: archiveSource,
                reconstructionState: reconstruction.state,
                extractionState: surfaceResult.extractionState,
                surface: surfaceResult.validated
            )
            let viewer = inspectViewer(
                processedSurface: surfaceResult.validated,
                canonicalDisposition: canonicalDisposition,
                rawMeshDisposition: rawMeshDisposition
            )
            let export = inspectExport(
                packageURL: packageURL,
                manifest: manifest,
                integrity: integrity,
                processedSurface: surfaceResult.validated
            )
            return ScanDerivedInspection(
                reconstruction: reconstruction.evidence,
                surface: surfaceResult.evidence,
                consistency: consistency.evidence,
                viewer: viewer.evidence,
                export: export.evidence,
                findings: reconstruction.findings
                    + surfaceResult.findings
                    + consistency.findings
                    + viewer.findings
                    + export.findings
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failedInspection(code: "DERIVED_ROOT_INVALID", conclusion: "The supplied derived-processing root is unsafe or unreadable.")
        }
    }

    private struct Roots {
        var derived: URL
        var processing: URL
    }

    private func resolvedRoots(from supplied: URL) throws -> Roots {
        let root = supplied.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ScanPackageInspectorError.unsafePackageRoot
        }
        switch root.lastPathComponent {
        case "derived":
            return Roots(derived: root, processing: root.deletingLastPathComponent().appending(path: "processing-work", directoryHint: .isDirectory))
        case "processing-work":
            return Roots(derived: root.deletingLastPathComponent().appending(path: "derived", directoryHint: .isDirectory), processing: root)
        default:
            return Roots(derived: root.appending(path: "derived", directoryHint: .isDirectory), processing: root.appending(path: "processing-work", directoryHint: .isDirectory))
        }
    }

    private struct ReconstructionResult {
        var evidence: ScanDerivedStageEvidence
        var state: TSDFReconstructionState?
        var findings: [ScanInspectionFinding]
    }

    private struct CompletedFrame: Codable {
        var schemaVersion: Int
        var frameIndex: Int
        var source: TSDFReconstructionSource
        var configuration: TSDFReconstructionConfiguration
        var submapKeys: [TSDFSubmapKey]
        var statistics: TSDFReconstructionStatistics
    }

    private func inspectReconstruction(
        scanID: UUID,
        archiveSource: TSDFReconstructionSource?,
        processingRoot: URL
    ) throws -> ReconstructionResult {
        let workspace = processingRoot.appending(path: scanID.uuidString, directoryHint: .isDirectory)
            .appending(path: "tsdf", directoryHint: .isDirectory)
        guard isSafeDirectory(workspace) else {
            return ReconstructionResult(
                evidence: .init(disposition: .unavailable, metrics: .init(values: ["workspace": "not present"])),
                state: nil,
                findings: [finding("RECONSTRUCTION_NOT_ATTEMPTED", .reconstruction, .info, "No TSDF reconstruction workspace is present.", "Reconstruction has not produced inspectable work.", "Absence is not a reconstruction failure.", "Run reconstruction on a qualified retained package.")]
            )
        }
        let stateURL = workspace.appending(path: "reconstruction-state.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            do {
                let recovery = try validatedRecoveryMarkers(
                    in: workspace.appending(path: "frames", directoryHint: .isDirectory),
                    scanID: scanID,
                    archiveSource: archiveSource
                )
                let metrics = ScanInspectionMetrics(
                    counts: [
                        "validatedCompletionMarkers": recovery.validatedCount,
                        "discoveredCompletionMarkers": recovery.discoveredCount
                    ],
                    values: ["workspace": workspace.path]
                )
                return ReconstructionResult(
                    evidence: .init(disposition: .insufficientEvidence, metrics: metrics),
                    state: nil,
                    findings: [finding(
                        "RECONSTRUCTION_CHECKPOINT_PENDING",
                        .reconstruction,
                        .warning,
                        recovery.validatedCount == 0
                            ? "The TSDF workspace exists without a checkpoint or durable completion marker."
                            : "The TSDF checkpoint is absent, but \(recovery.validatedCount) contiguous production completion markers form a resumable prefix.",
                        "Reconstruction is incomplete, not proven corrupt.",
                        "The read-only inspector does not rebuild the checkpoint or validate uncommitted frame work.",
                        "Resume reconstruction; the production reconstructor will rebuild state from the durable marker prefix.",
                        metrics: metrics
                    )]
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return ReconstructionResult(
                    evidence: .init(disposition: .failed, metrics: .init(values: ["workspace": workspace.path])),
                    state: nil,
                    findings: [finding("RECONSTRUCTION_RECOVERY_MARKER_INVALID", .reconstruction, .error, "The checkpoint is absent and the durable completion-marker prefix is unsafe or internally inconsistent.", "The recovery prefix cannot be trusted.", "The inspector does not repair derived state.", "Discard only invalid derived reconstruction work and reconstruct again from the immutable source package.")]
                )
            }
        }
        guard let state: TSDFReconstructionState = try? decodeJSON(at: stateURL),
              state.schemaVersion == TSDFReconstructionState.currentSchemaVersion,
              state.source.scanID == scanID,
              state.nextFrameIndex >= 1,
              state.nextFrameIndex <= state.source.keyframeCount + 1,
              Set(state.submapKeys).count == state.submapKeys.count
        else {
            return ReconstructionResult(
                evidence: .init(disposition: .failed, metrics: .init(values: ["workspace": workspace.path])),
                state: nil,
                findings: [finding("RECONSTRUCTION_CHECKPOINT_INVALID", .reconstruction, .error, "The TSDF state exists but is unsafe, malformed, or internally inconsistent.", "The reconstruction checkpoint cannot be trusted.", "The inspector does not repair derived state.", "Delete only derived work and reconstruct again from the immutable source package.")]
            )
        }
        if let archiveSource, state.source != archiveSource {
            return ReconstructionResult(
                evidence: .init(disposition: .failed, metrics: reconstructionMetrics(state)),
                state: state,
                findings: [finding("RECONSTRUCTION_SOURCE_MISMATCH", .reconstruction, .blocker, "The checkpoint source identity differs from the current calibrated archive.", "The reconstruction is stale or belongs to another source revision.", "No derived geometry can be attributed to this package.", "Reconstruct from the current immutable archive.")]
            )
        }
        let completedCount = state.nextFrameIndex - 1
        let markers = try validatedMarkers(in: workspace.appending(path: "frames", directoryHint: .isDirectory), state: state)
        let deltas = try validatedDeltas(in: workspace.appending(path: "submaps", directoryHint: .isDirectory), state: state)
        var metrics = reconstructionMetrics(state)
        metrics.counts["validatedCompletionMarkers"] = markers
        metrics.counts["validatedDeltaFiles"] = deltas
        let complete = completedCount == state.source.keyframeCount
            && markers == completedCount
            && state.statistics.processedFrameCount == completedCount
        let code = complete ? "RECONSTRUCTION_CHECKPOINT_VALID" : "RECONSTRUCTION_INCOMPLETE"
        let disposition: ScanInspectionDisposition = complete ? .healthy : .insufficientEvidence
        let severity: ScanInspectionSeverity = complete ? .info : .warning
        return ReconstructionResult(
            evidence: .init(disposition: disposition, metrics: metrics),
            state: state,
            findings: [finding(code, .reconstruction, severity, "TSDF state, completion markers, and delta files passed bounded structural validation.", complete ? "The checkpoint is complete for its declared source." : "The checkpoint is valid but incomplete.", "Structural validity does not establish surface accuracy.", complete ? "Validate extraction and promotion against this exact prefix." : "Resume reconstruction from the next declared frame.", metrics: metrics)]
        )
    }

    private func reconstructionMetrics(_ state: TSDFReconstructionState) -> ScanInspectionMetrics {
        .init(
            counts: [
                "sourceKeyframeCount": state.source.keyframeCount,
                "completedFrameCount": state.nextFrameIndex - 1,
                "processedFrameCount": state.statistics.processedFrameCount,
                "submapCount": state.submapKeys.count,
                "integratedRayCount": state.statistics.integratedRayCount,
                "updatedVoxelContributionCount": state.statistics.updatedVoxelContributionCount,
                "rejectedDepthSampleCount": state.statistics.rejectedDepthSampleCount,
                "droppedVoxelUpdateCount": state.statistics.droppedVoxelUpdateCount,
                "rayLimitReachedFrameCount": state.statistics.rayLimitReachedFrameCount
            ],
            values: [
                "qualityProfile": state.configuration.qualityProfile.rawValue,
                "voxelSizeMeters": "\(state.configuration.voxelSizeMeters)",
                "truncationDistanceMeters": "\(state.configuration.truncationDistanceMeters)",
                "minimumConfidence": "\(state.configuration.minimumConfidence)",
                "maximumDepthMeters": "\(state.configuration.maximumDepthMeters)",
                "minimumConsistentNeighborCount": "\(state.configuration.minimumConsistentNeighborCount)"
            ]
        )
    }

    private func validatedMarkers(in frames: URL, state: TSDFReconstructionState) throws -> Int {
        if state.nextFrameIndex == 1 { return 0 }
        guard isSafeDirectory(frames) else { throw ScanPackageInspectorError.ioFailure("frames directory") }
        var count = 0
        for frameIndex in 1..<state.nextFrameIndex {
            try Task.checkCancellation()
            let url = frames.appending(path: "frame-\(String(format: "%06d", frameIndex)).complete.json")
            let marker: CompletedFrame = try decodeJSON(at: url)
            guard marker.schemaVersion == TSDFReconstructionState.currentSchemaVersion,
                  marker.frameIndex == frameIndex,
                  marker.source == state.source,
                  marker.configuration == state.configuration
            else { throw ScanPackageInspectorError.ioFailure("completion marker") }
            count += 1
        }
        return count
    }

    private struct RecoveryMarkerSummary {
        var validatedCount: Int
        var discoveredCount: Int
    }

    private func validatedRecoveryMarkers(
        in frames: URL,
        scanID: UUID,
        archiveSource: TSDFReconstructionSource?
    ) throws -> RecoveryMarkerSummary {
        guard FileManager.default.fileExists(atPath: frames.path) else {
            return RecoveryMarkerSummary(validatedCount: 0, discoveredCount: 0)
        }
        guard isSafeDirectory(frames) else { throw ScanPackageInspectorError.unsafePackageRoot }
        let files = try regularFilesRecursively(under: frames, suffix: ".complete.json")
        guard files.count <= Self.maximumArtifactCount else {
            throw ScanPackageInspectorError.ioFailure("too many completion markers")
        }
        var expectedIndex = 1
        var expectedSource: TSDFReconstructionSource?
        var expectedConfiguration: TSDFReconstructionConfiguration?
        for url in files {
            try Task.checkCancellation()
            guard url.deletingLastPathComponent().standardizedFileURL == frames.standardizedFileURL,
                  url.lastPathComponent == "frame-\(String(format: "%06d", expectedIndex)).complete.json"
            else { throw ScanPackageInspectorError.ioFailure("non-contiguous completion markers") }
            let marker: CompletedFrame = try decodeJSON(at: url)
            guard marker.schemaVersion == TSDFReconstructionState.currentSchemaVersion,
                  marker.frameIndex == expectedIndex,
                  marker.source.scanID == scanID,
                  marker.source.keyframeCount >= expectedIndex,
                  Set(marker.submapKeys).count == marker.submapKeys.count,
                  marker.submapKeys == marker.submapKeys.sorted()
            else { throw ScanPackageInspectorError.ioFailure("invalid completion marker") }
            if let archiveSource, marker.source != archiveSource {
                throw ScanPackageInspectorError.ioFailure("completion marker source mismatch")
            }
            if let expectedSource, marker.source != expectedSource {
                throw ScanPackageInspectorError.ioFailure("completion marker source changed")
            }
            if let expectedConfiguration, marker.configuration != expectedConfiguration {
                throw ScanPackageInspectorError.ioFailure("completion marker configuration changed")
            }
            expectedSource = marker.source
            expectedConfiguration = marker.configuration
            expectedIndex += 1
        }
        return RecoveryMarkerSummary(validatedCount: expectedIndex - 1, discoveredCount: files.count)
    }

    private func validatedDeltas(in submaps: URL, state: TSDFReconstructionState) throws -> Int {
        guard isSafeDirectory(submaps) || state.submapKeys.isEmpty else {
            throw ScanPackageInspectorError.ioFailure("submaps directory")
        }
        guard isSafeDirectory(submaps) else { return 0 }
        let files = try regularFilesRecursively(under: submaps, suffix: ".delta")
        guard files.count <= Self.maximumArtifactCount else { throw ScanPackageInspectorError.ioFailure("too many delta files") }
        for (offset, url) in files.enumerated() {
            if offset % 64 == 0 { try Task.checkCancellation() }
            guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize >= Self.deltaHeaderBytes,
                  fileSize <= Self.maximumDeltaBytes
            else { throw ScanPackageInspectorError.ioFailure("invalid delta size") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let recordByteCount: Int
            if let declaredRecordCount = data.uint32LE(at: 16).flatMap(Int.init(exactly:)) {
                let (bytes, overflow) = declaredRecordCount.multipliedReportingOverflow(by: Self.deltaRecordBytes)
                guard !overflow else { throw ScanPackageInspectorError.ioFailure("invalid delta count") }
                recordByteCount = bytes
            } else {
                throw ScanPackageInspectorError.ioFailure("invalid delta count")
            }
            guard data.count >= Self.deltaHeaderBytes,
                  data.prefix(Self.deltaMagic.count) == Self.deltaMagic,
                  data.uint32LE(at: 8) == 1,
                  data.uint32LE(at: 12) == UInt32(state.configuration.submapVoxelDimension),
                  let recordCount = data.uint32LE(at: 16).flatMap(Int.init(exactly:)),
                  data.count == Self.deltaHeaderBytes + recordByteCount
            else { throw ScanPackageInspectorError.ioFailure("invalid delta") }
            var previous: UInt32?
            let limit = state.configuration.submapVoxelDimension * state.configuration.submapVoxelDimension * state.configuration.submapVoxelDimension
            for index in 0..<recordCount {
                let recordOffset = Self.deltaHeaderBytes + index * Self.deltaRecordBytes
                guard let localIndex = data.uint32LE(at: recordOffset),
                      Int(localIndex) < limit,
                      previous.map({ localIndex > $0 }) ?? true,
                      let distanceBits = data.uint32LE(at: recordOffset + 4),
                      let weightBits = data.uint32LE(at: recordOffset + 8),
                      Float(bitPattern: distanceBits).isFinite,
                      Float(bitPattern: weightBits).isFinite,
                      Float(bitPattern: weightBits) > 0
                else { throw ScanPackageInspectorError.ioFailure("invalid delta record") }
                previous = localIndex
            }
        }
        return files.count
    }

    private struct ExtractionState: Codable {
        var schemaVersion: Int
        var snapshot: TSDFExtractionSnapshot
        var configuration: TSDFSurfaceExtractionConfiguration
        var canonicalBounds: TSDFSurfaceBounds
        var submapKeys: [TSDFSubmapKey]
        var nextSubmapOffset: Int
        var statistics: TSDFSurfaceExtractionStatistics
    }

    private struct SurfaceResult {
        var evidence: ScanDerivedStageEvidence
        var extractionState: ExtractionState?
        var validated: ValidatedProcessedSurface?
        var findings: [ScanInspectionFinding]
    }

    private func inspectSurface(
        packageURL: URL,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport,
        archiveSource: TSDFReconstructionSource?,
        derivedRoot: URL,
        processingRoot: URL
    ) async throws -> SurfaceResult {
        let extractionURL = processingRoot.appending(path: manifest.localScanID.uuidString, directoryHint: .isDirectory)
            .appending(path: "surface-extraction", directoryHint: .isDirectory)
            .appending(path: "surface-extraction-state.json")
        let extractionStateExists = FileManager.default.fileExists(atPath: extractionURL.path)
        let extractionState: ExtractionState? = try? decodeJSON(at: extractionURL)
        if extractionStateExists, extractionState == nil {
            return SurfaceResult(evidence: .init(disposition: .failed, metrics: .init()), extractionState: nil, validated: nil, findings: [finding("SURFACE_EXTRACTION_STATE_INVALID", .surfaceExtraction, .error, "Surface extraction state exists but is unsafe or cannot be decoded.", "Surface extraction cannot be resumed safely.", "The inspector does not mutate staging work.", "Discard only derived staging work and restart extraction.")])
        }
        if let extractionState,
           extractionState.schemaVersion != 1
            || extractionState.nextSubmapOffset < 0
            || extractionState.nextSubmapOffset > extractionState.submapKeys.count
            || Set(extractionState.submapKeys).count != extractionState.submapKeys.count {
            return SurfaceResult(evidence: .init(disposition: .failed, metrics: .init()), extractionState: extractionState, validated: nil, findings: [finding("SURFACE_EXTRACTION_STATE_INVALID", .surfaceExtraction, .error, "Surface extraction state is malformed or internally inconsistent.", "Surface extraction cannot be resumed safely.", "The inspector does not mutate staging work.", "Discard only derived staging work and restart extraction.")])
        }
        if let extractionState, let archiveSource, extractionState.snapshot.prefix.source != archiveSource {
            return SurfaceResult(evidence: .init(disposition: .failed, metrics: extractionMetrics(extractionState)), extractionState: extractionState, validated: nil, findings: [finding("SURFACE_EXTRACTION_SOURCE_MISMATCH", .surfaceExtraction, .blocker, "Extraction staging references a different calibrated source.", "The staged surface is stale.", "No staged chunks were promoted or repaired.", "Restart extraction from the current completed TSDF prefix.")])
        }
        guard isSafeDirectory(derivedRoot) else {
            let disposition: ScanInspectionDisposition = extractionState == nil ? .unavailable : .insufficientEvidence
            return SurfaceResult(evidence: .init(disposition: disposition, metrics: extractionState.map(extractionMetrics) ?? .init()), extractionState: extractionState, validated: nil, findings: [finding("SURFACE_NOT_PROMOTED", .surfaceExtraction, .info, extractionState == nil ? "No extraction or promoted surface is present." : "Extraction staging exists but no promoted surface root is present.", "A processed surface is not available to the viewer or mesh exports.", "Absence does not prove extraction failure.", "Complete reconstruction and extraction for the exact source prefix.")])
        }
        do {
            let store = try ProcessedSurfaceStore(rootURL: derivedRoot, processingRootURL: processingRoot)
            let validated = try await store.validatedProcessedSurface(scanID: manifest.localScanID, packageURL: packageURL, manifest: manifest, integrity: integrity)
            var metrics = ScanInspectionMetrics(counts: ["vertexCount": validated.manifest.vertexCount, "triangleCount": validated.manifest.triangleCount, "completedFrameCount": validated.manifest.prefix.completedFrameCount], values: ["prefixSHA256": validated.manifest.prefix.sha256, "hasObservedColors": "\(validated.hasAnyObservedColors)", "allVerticesHaveObservedColors": "\(validated.allVerticesHaveObservedColors)"])
            if let extractionState { metrics.counts.merge(extractionMetrics(extractionState).counts, uniquingKeysWith: { current, _ in current }) }
            return SurfaceResult(evidence: .init(disposition: .healthy, metrics: metrics), extractionState: extractionState, validated: validated, findings: [finding("SURFACE_PROMOTION_VALID", .surfaceExtraction, .info, "The production processed-surface reader accepted source identity, checksums, geometry, bounds, and validation evidence.", "The promoted surface is structurally eligible for viewing and mesh export.", "This is not a spatial-accuracy claim.", "Compare it against benchmark reference geometry.", metrics: metrics)])
        } catch is CancellationError {
            throw CancellationError()
        } catch ProcessedSurfaceReadError.notFound {
            return SurfaceResult(evidence: .init(disposition: extractionState == nil ? .unavailable : .insufficientEvidence, metrics: extractionState.map(extractionMetrics) ?? .init()), extractionState: extractionState, validated: nil, findings: [finding("SURFACE_NOT_PROMOTED", .surfaceExtraction, .info, "No promoted processed surface is present.", "Processed geometry is unavailable.", "Staging work may still be resumable.", "Complete extraction and atomic promotion.")])
        } catch ProcessedSurfaceReadError.staleSource {
            return SurfaceResult(evidence: .init(disposition: .failed, metrics: .init()), extractionState: extractionState, validated: nil, findings: [finding("SURFACE_PROMOTION_STALE", .surfaceExtraction, .blocker, "The promoted surface source differs from the current package archive.", "The processed surface is ineligible.", "The viewer/exporter correctly reject stale geometry.", "Reconstruct and promote from the current source.")])
        } catch {
            return SurfaceResult(evidence: .init(disposition: .failed, metrics: .init()), extractionState: extractionState, validated: nil, findings: [finding("SURFACE_PROMOTION_INVALID", .surfaceExtraction, .error, "The production processed-surface reader rejected the promoted artifact.", "Processed geometry is invalid or incomplete.", "The inspector does not repair geometry.", "Inspect the processed-surface manifest, validation report, and checksums.")])
        }
    }

    private func extractionMetrics(_ state: ExtractionState) -> ScanInspectionMetrics {
        .init(counts: ["sourceCompletedFrameCount": state.snapshot.prefix.completedFrameCount, "submapCount": state.submapKeys.count, "processedSubmapCount": state.statistics.processedSubmapCount, "nextSubmapOffset": state.nextSubmapOffset, "emittedTriangleCount": state.statistics.emittedTriangleCount, "droppedSubmapCount": state.statistics.droppedSubmapCount, "droppedVertexCount": state.statistics.droppedVertexCount, "droppedTriangleCount": state.statistics.droppedTriangleCount], values: ["prefixSHA256": state.snapshot.prefix.sha256, "minimumDistinctFrameCount": "\(state.configuration.minimumDistinctFrameCount)"])
    }

    private struct EvidenceResult { var evidence: ScanDerivedStageEvidence; var findings: [ScanInspectionFinding] }

    private func inspectConsistency(archiveSource: TSDFReconstructionSource?, reconstructionState: TSDFReconstructionState?, extractionState: ExtractionState?, surface: ValidatedProcessedSurface?) -> EvidenceResult {
        var checked = 0
        var mismatches = 0
        if let archiveSource, let reconstructionState { checked += 1; if archiveSource != reconstructionState.source { mismatches += 1 } }
        if let reconstructionState, let extractionState { checked += 1; if reconstructionState.source != extractionState.snapshot.prefix.source || reconstructionState.configuration != extractionState.snapshot.prefix.configuration || reconstructionState.nextFrameIndex - 1 != extractionState.snapshot.prefix.completedFrameCount { mismatches += 1 } }
        if let extractionState, let surface { checked += 1; if extractionState.snapshot.prefix != surface.manifest.prefix { mismatches += 1 } }
        if let archiveSource, let surface { checked += 1; if archiveSource != surface.manifest.prefix.source || archiveSource.keyframeCount != surface.manifest.prefix.completedFrameCount { mismatches += 1 } }
        let metrics = ScanInspectionMetrics(counts: ["checkedIdentityEdges": checked, "identityMismatchCount": mismatches])
        if mismatches > 0 { return EvidenceResult(evidence: .init(disposition: .failed, metrics: metrics), findings: [finding("CROSS_STAGE_SOURCE_MISMATCH", .crossStageConsistency, .blocker, "At least one downstream artifact does not identify the exact upstream source/prefix.", "The pipeline chain is not attributable end to end.", "No best-effort association is accepted.", "Regenerate downstream work from the first mismatched stage.", metrics: metrics)]) }
        if checked < 3 { return EvidenceResult(evidence: .init(disposition: .unqualified, metrics: metrics), findings: [finding("CROSS_STAGE_CHAIN_INCOMPLETE", .crossStageConsistency, .info, "Too few adjacent stages exist to prove end-to-end identity.", "Cross-stage consistency is unqualified.", "Missing work is not evidence of mismatch.", "Complete the derived pipeline and inspect again.", metrics: metrics)]) }
        return EvidenceResult(evidence: .init(disposition: .healthy, metrics: metrics), findings: [finding("CROSS_STAGE_CHAIN_VALID", .crossStageConsistency, .info, "Archive, TSDF, extraction, and promotion identities agree.", "The derived chain is attributable to the retained source.", "Identity agreement does not prove spatial accuracy.", "Proceed to benchmark validation.", metrics: metrics)])
    }

    private func inspectViewer(processedSurface: ValidatedProcessedSurface?, canonicalDisposition: ScanInspectionDisposition, rawMeshDisposition: ScanInspectionDisposition) -> EvidenceResult {
        let selection: String
        let disposition: ScanInspectionDisposition
        if let processedSurface { selection = processedSurface.hasAnyObservedColors ? "coloredProcessedSurface" : "geometryOnlyProcessedSurface"; disposition = .healthy }
        else if canonicalDisposition != .failed && canonicalDisposition != .unavailable { selection = "canonicalPointCloudFallback"; disposition = .unqualified }
        else if rawMeshDisposition != .failed && rawMeshDisposition != .unavailable { selection = "diagnosticRawMeshFallback"; disposition = .unqualified }
        else { selection = "none"; disposition = .unavailable }
        let metrics = ScanInspectionMetrics(values: ["selectedSource": selection])
        return EvidenceResult(evidence: .init(disposition: disposition, metrics: metrics), findings: [finding(processedSurface == nil ? "VIEWER_FALLBACK_ACTIVE" : "VIEWER_PROCESSED_SURFACE_ELIGIBLE", .viewer, processedSurface == nil ? .warning : .info, "Saved-viewer source selection resolves to \(selection).", processedSurface == nil ? "The viewer cannot use a validated processed surface." : "The viewer can load the exact validated processed surface.", "Eligibility does not measure rendering quality.", "Open the same package in the saved viewer and compare framing and recognizability.", metrics: metrics)])
    }

    private func inspectExport(packageURL: URL, manifest: ScanPackageManifest, integrity: PackageIntegrityReport, processedSurface: ValidatedProcessedSurface?) -> EvidenceResult {
        let formats = ScanInterchangeExporter().availableFormats(for: manifest, packageURL: packageURL, integrity: integrity, processedSurface: processedSurface).map(\.rawValue).sorted()
        let metrics = ScanInspectionMetrics(counts: ["eligibleFormatCount": formats.count], values: ["eligibleFormats": formats.joined(separator: ",")])
        let all = Set(formats) == Set(ScanInterchangeFormat.allCases.map(\.rawValue))
        return EvidenceResult(evidence: .init(disposition: formats.isEmpty ? .unavailable : .unqualified, metrics: metrics), findings: [finding(all ? "EXPORT_ALL_FORMATS_SYNTACTICALLY_ELIGIBLE" : "EXPORT_FORMATS_LIMITED", .export, all ? .info : .warning, "Production export preflight reports: \(formats.isEmpty ? "none" : formats.joined(separator: ", ")).", all ? "All interchange formats have structurally valid source inputs." : "Only a subset of interchange formats has valid source inputs.", "Preflight is not survey accuracy, georeferencing, or Cesium field validation.", "Run format validators and benchmark geometry before product qualification.", metrics: metrics)])
    }

    private func unavailableInspection(canonicalDisposition: ScanInspectionDisposition, rawMeshDisposition: ScanInspectionDisposition) -> ScanDerivedInspection {
        let viewer = inspectViewer(processedSurface: nil, canonicalDisposition: canonicalDisposition, rawMeshDisposition: rawMeshDisposition)
        return ScanDerivedInspection(reconstruction: .init(disposition: .unavailable, metrics: .init()), surface: .init(disposition: .unavailable, metrics: .init()), consistency: .init(disposition: .unqualified, metrics: .init()), viewer: viewer.evidence, export: .init(disposition: .unqualified, metrics: .init()), findings: [finding("DERIVED_ROOT_UNAVAILABLE", .reconstruction, .info, "No derived-processing root was supplied.", "Downstream work cannot be inspected.", "This is not evidence that derived work is absent.", "Supply the application-support root, derived root, or processing-work root.")] + viewer.findings + [finding("EXPORT_UNVALIDATED", .export, .info, "Export eligibility was not evaluated without downstream roots.", "Export state is unqualified.", "Source package integrity alone is insufficient for mesh exports.", "Supply derived-processing work and inspect again.")])
    }

    private func failedInspection(code: String, conclusion: String) -> ScanDerivedInspection {
        let evidence = ScanDerivedStageEvidence(disposition: .failed, metrics: .init())
        return ScanDerivedInspection(reconstruction: evidence, surface: evidence, consistency: evidence, viewer: evidence, export: evidence, findings: [finding(code, .reconstruction, .error, conclusion, conclusion, "The inspector stopped at this safety boundary.", "Correct the supplied root and rerun inspection.")])
    }

    private func decodeJSON<T: Decodable>(at url: URL) throws -> T {
        try Task.checkCancellation()
        guard isSafeRegularFile(url), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= Self.maximumJSONBytes else { throw ScanPackageInspectorError.ioFailure("unsafe JSON") }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func regularFilesRecursively(under root: URL, suffix: String) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for (offset, element) in enumerator.enumerated() {
            if offset % 64 == 0 { try Task.checkCancellation() }
            guard let url = element as? URL else { continue }
            if result.count > Self.maximumArtifactCount { throw ScanPackageInspectorError.ioFailure("too many artifacts") }
            if url.lastPathComponent.hasSuffix(suffix) {
                guard isSafeRegularFile(url), url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw ScanPackageInspectorError.unsafePackageRoot }
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func isSafeDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func finding(_ code: String, _ stage: ScanInspectionStage, _ severity: ScanInspectionSeverity, _ evidence: String, _ conclusion: String, _ limitation: String, _ next: String, metrics: ScanInspectionMetrics = .init()) -> ScanInspectionFinding {
        ScanInspectionFinding(code: code, stage: stage, severity: severity, evidence: evidence, conclusion: conclusion, limitation: limitation, recommendedNextMeasurement: next, metrics: metrics)
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { raw in
            let byte0 = UInt32(raw[offset])
            let byte1 = UInt32(raw[offset + 1]) << 8
            let byte2 = UInt32(raw[offset + 2]) << 16
            let byte3 = UInt32(raw[offset + 3]) << 24
            return byte0 | byte1 | byte2 | byte3
        }
    }
}
