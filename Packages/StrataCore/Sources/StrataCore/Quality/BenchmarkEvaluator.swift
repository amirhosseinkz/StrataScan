import CryptoKit
import Foundation

public struct BenchmarkEvaluator: Sendable {
    public static let runManifestFilename = "run.json"
    public static let scorecardFilename = "metrics.json"
    public static let residualLocalizationFilename = "residual-localization.json"

    private static let maximumManifestBytes: Int64 = 1_048_576
    public static let safetyLimits = BenchmarkEvaluationSafetyLimits.default
    private static let maximumRenderPoints = 12_000

    public init() {}

    public func localizeResiduals(
        fixtureDirectory: URL,
        runDirectory: URL,
        packageStoreRoot: URL,
        scanID: UUID,
        outputDirectory: URL,
        configuration: BenchmarkResidualLocalizationConfiguration = .default,
        reconstructionReport: PublicRGBDBenchmarkReconstructionReport? = nil
    ) async throws -> BenchmarkResidualLocalizationReport {
        try Task.checkCancellation()
        let fixtureRoot = try safeDirectory(fixtureDirectory, create: false)
        let runRoot = try safeDirectory(runDirectory, create: false)
        let outputRoot = try safeDirectory(outputDirectory, create: true)
        let validation = try await BenchmarkFixtureValidator().validate(fixtureDirectory: fixtureRoot)
        guard validation.valid, validation.e2Ready else { throw BenchmarkEvaluationError.fixtureNotValid }

        let fixtureManifestURL = fixtureRoot.appending(path: BenchmarkFixtureValidator.manifestFilename)
        let fixture: BenchmarkManifest = try decodeBounded(
            fixtureManifestURL,
            root: fixtureRoot,
            maximumBytes: Self.maximumManifestBytes,
            missing: .manifestMissing,
            unreadable: .manifestUnreadable
        )
        let run: BenchmarkEvaluationRunManifest = try decodeBounded(
            runRoot.appending(path: Self.runManifestFilename),
            root: runRoot,
            maximumBytes: Self.maximumManifestBytes,
            missing: .manifestMissing,
            unreadable: .manifestUnreadable
        )
        try validateIdentity(run: run, fixture: fixture)
        let geometry = try loadCandidate(run.geometry, root: runRoot)
        let candidate = try preparedCandidate(geometry)
        guard let reference = try loadReference(fixture: fixture, root: fixtureRoot, e2Ready: true),
              let referenceAsset = fixture.assets.first(where: { $0.role == .referenceGeometry })
        else {
            throw BenchmarkEvaluationError.referenceUnavailable
        }

        let assetStore = try FileAssetStore(rootURL: try safeDirectory(packageStoreRoot, create: false))
        guard await assetStore.packageExists(id: scanID) else { throw BenchmarkEvaluationError.assetIntegrityFailed }
        let packageURL = try await assetStore.packageURL(for: scanID)
        let packageManifest = try await assetStore.loadManifest(id: scanID)
        let integrity = try await assetStore.validatePackage(id: scanID)
        guard integrity.isValid,
              packageManifest.localScanID == scanID,
              try sha256(packageURL.appending(path: "manifest.json")) == run.sourcePackageSHA256
        else {
            throw BenchmarkEvaluationError.assetIntegrityFailed
        }
        let archive = try CalibratedRGBDKeyframeArchiveReader().open(
            packageURL: packageURL,
            manifest: packageManifest,
            integrity: integrity
        )
        if let reconstructionReport {
            guard reconstructionReport.scanID == scanID,
                  reconstructionReport.evaluatorGeometrySHA256 == run.geometry.sha256,
                  reconstructionReport.source.calibratedArchiveSHA256 == archive.sourceArchiveSHA256
            else { throw BenchmarkEvaluationError.runIdentityMismatch }
        }
        guard !archive.records.isEmpty else { throw BenchmarkEvaluationError.referenceUnavailable }
        guard reference.points.count <= configuration.maximumReferenceSamples else {
            throw BenchmarkEvaluationError.geometryInvalid("Reference exceeds the residual-localization sample limit.")
        }

        let cameraOrigins = archive.records.map { record -> Point3D in
            geometry.fixtureFromGeometry.applying(to: Point3D(
                x: record.metadata.worldFromCamera.columns[12],
                y: record.metadata.worldFromCamera.columns[13],
                z: record.metadata.worldFromCamera.columns[14]
            ))
        }
        let referenceIndex = reference.surfaces.isEmpty ? SpatialKDTree(points: reference.points) : nil
        let candidateIndex = SpatialKDTree(points: candidate.points)
        var observations: [BenchmarkResidualObservation] = []
        observations.reserveCapacity(
            candidate.points.count + reference.points.count + configuration.maximumSourceSamples * 2
        )

        for (index, point) in candidate.points.enumerated() {
            if index % 2_048 == 0 { try Task.checkCancellation() }
            let nearestCameraRange = cameraOrigins.map { euclideanDistance(point, $0) }.min()
            observations.append(BenchmarkResidualObservation(
                domain: .candidateSurface,
                position: benchmarkVector(point),
                residualMeters: referenceIndex?.nearestDistance(to: point) ?? distance(point, to: reference),
                sourceDepthOrCameraRangeMeters: nearestCameraRange
            ))
        }

        var remainingSourceSamples = configuration.maximumSourceSamples
        for frameOffset in archive.records.indices {
            try Task.checkCancellation()
            guard remainingSourceSamples > 0 else { break }
            let keyframe = try archive.readKeyframe(at: frameOffset)
            let sample = keyframe.depth
            let pixelCount = sample.width * sample.height
            let remainingFrames = archive.records.count - frameOffset
            let perFrameBudget = max(remainingSourceSamples / remainingFrames, 1)
            let samplingStride = max(Int(ceil(sqrt(Double(pixelCount) / Double(perFrameBudget)))), 1)
            let intrinsics = sample.calibration.scaled(toWidth: sample.width, height: sample.height)
            sampleRows:
            for y in stride(from: 0, to: sample.height, by: samplingStride) {
                for x in stride(from: 0, to: sample.width, by: samplingStride) {
                    guard remainingSourceSamples > 0 else { break sampleRows }
                    let pixelIndex = y * sample.width + x
                    let depth = sample.depthMeters[pixelIndex]
                    guard depth.isFinite, depth > 0 else { continue }
                    let cameraPoint = Point3D(
                        x: -((Float(x) - intrinsics.cx) / intrinsics.fx) * depth,
                        y: -((Float(y) - intrinsics.cy) / intrinsics.fy) * depth,
                        z: -depth
                    )
                    let worldPoint = sample.worldFromCamera.applying(to: cameraPoint)
                    let fixturePoint = geometry.fixtureFromGeometry.applying(to: worldPoint)
                    observations.append(BenchmarkResidualObservation(
                        domain: .sourceDepth,
                        position: benchmarkVector(fixturePoint),
                        residualMeters: referenceIndex?.nearestDistance(to: fixturePoint) ?? distance(fixturePoint, to: reference),
                        sourceDepthOrCameraRangeMeters: Double(depth),
                        confidence: sample.confidence[pixelIndex]
                    ))
                    remainingSourceSamples -= 1
                }
            }
        }

        if let admission = reconstructionReport?.reconstructionConfiguration {
            var remainingAdmittedSamples = configuration.maximumSourceSamples
            for frameOffset in archive.records.indices {
                try Task.checkCancellation()
                guard remainingAdmittedSamples > 0 else { break }
                let sample = try archive.readKeyframe(at: frameOffset).depth
                let intrinsics = sample.calibration.scaled(toWidth: sample.width, height: sample.height)
                var admittedPixels: [(x: Int, y: Int)] = []
                admittedPixels.reserveCapacity(min(admission.maximumRaysPerFrame, 8_000))
                admittedRows: for y in stride(from: 0, to: sample.height, by: admission.depthPixelStride) {
                    for x in stride(from: 0, to: sample.width, by: admission.depthPixelStride) {
                        let index = y * sample.width + x
                        guard admission.depthSampleRejection(
                            depth: sample.depthMeters[index],
                            confidence: sample.confidence[index],
                            x: x,
                            y: y,
                            sample: sample
                        ) == nil else { continue }
                        guard admittedPixels.count < admission.maximumRaysPerFrame else {
                            break admittedRows
                        }
                        admittedPixels.append((x, y))
                    }
                }
                let remainingFrames = archive.records.count - frameOffset
                let perFrameBudget = max(remainingAdmittedSamples / remainingFrames, 1)
                let diagnosticStride = max(Int(ceil(Double(admittedPixels.count) / Double(perFrameBudget))), 1)
                for pixelOffset in stride(from: 0, to: admittedPixels.count, by: diagnosticStride) {
                    guard remainingAdmittedSamples > 0 else { break }
                    let pixel = admittedPixels[pixelOffset]
                    let index = pixel.y * sample.width + pixel.x
                    let depth = sample.depthMeters[index]
                    let cameraPoint = Point3D(
                        x: -((Float(pixel.x) - intrinsics.cx) / intrinsics.fx) * depth,
                        y: -((Float(pixel.y) - intrinsics.cy) / intrinsics.fy) * depth,
                        z: -depth
                    )
                    let fixturePoint = geometry.fixtureFromGeometry.applying(
                        to: sample.worldFromCamera.applying(to: cameraPoint)
                    )
                    observations.append(BenchmarkResidualObservation(
                        domain: .admittedSourceDepth,
                        position: benchmarkVector(fixturePoint),
                        residualMeters: referenceIndex?.nearestDistance(to: fixturePoint)
                            ?? distance(fixturePoint, to: reference),
                        sourceDepthOrCameraRangeMeters: Double(depth),
                        confidence: sample.confidence[index]
                    ))
                    remainingAdmittedSamples -= 1
                }
            }
        }

        for (index, point) in reference.points.enumerated() {
            if index % 2_048 == 0 { try Task.checkCancellation() }
            observations.append(BenchmarkResidualObservation(
                domain: .missingReference,
                position: benchmarkVector(point),
                residualMeters: candidateIndex.nearestDistance(to: point)
            ))
        }

        let identity = BenchmarkResidualLocalizationIdentity(
            fixtureID: run.fixtureID,
            fixtureVersion: run.fixtureVersion,
            fixtureManifestSHA256: try sha256(fixtureManifestURL),
            referenceGeometrySHA256: referenceAsset.sha256,
            sourcePackageSHA256: run.sourcePackageSHA256,
            sourceArchiveSHA256: archive.sourceArchiveSHA256,
            reconstructionConfigurationSHA256: run.reconstructionConfigurationSHA256,
            candidateGeometrySHA256: run.geometry.sha256,
            buildCommit: run.buildCommit
        )
        let report = try BenchmarkResidualAnalyzer().analyze(
            identity: identity,
            observations: observations,
            configuration: configuration,
            referenceDistanceMode: reference.surfaces.isEmpty
                ? .nearestReferenceSample
                : .continuousTriangleSurface,
            reconstructionAdmissionConfiguration: reconstructionReport?.reconstructionConfiguration
        )
        try writeAtomically(
            report.stableJSON(),
            to: outputRoot.appending(path: Self.residualLocalizationFilename),
            root: outputRoot
        )
        return report
    }

    /// Computes signed-orientation-independent enclosed volume after applying the
    /// declared `fixtureFromGeometry` transform. The mesh must be a closed,
    /// checksum-independent in-memory candidate; callers remain responsible for
    /// deciding whether its topology qualifies the value as evidence.
    public func enclosedVolume(of geometry: BenchmarkEvaluationGeometry) throws -> Double {
        enclosedVolume(try preparedCandidate(geometry))
    }

    public func evaluate(
        fixtureDirectory: URL,
        runDirectory: URL,
        outputDirectory: URL,
        thresholds: BenchmarkEvaluationThresholds = .initialCloseRange
    ) async throws -> BenchmarkEvaluationScorecard {
        try Task.checkCancellation()
        let fixtureRoot = try safeDirectory(fixtureDirectory, create: false)
        let runRoot = try safeDirectory(runDirectory, create: false)
        let outputRoot = try safeDirectory(outputDirectory, create: true)

        let validation = try await BenchmarkFixtureValidator().validate(fixtureDirectory: fixtureRoot)
        guard validation.valid else { throw BenchmarkEvaluationError.fixtureNotValid }

        let fixtureManifestURL = fixtureRoot.appending(path: BenchmarkFixtureValidator.manifestFilename)
        let fixtureManifest: BenchmarkManifest = try decodeBounded(
            fixtureManifestURL,
            root: fixtureRoot,
            maximumBytes: Self.maximumManifestBytes,
            missing: .manifestMissing,
            unreadable: .manifestUnreadable
        )
        let run: BenchmarkEvaluationRunManifest = try decodeBounded(
            runRoot.appending(path: Self.runManifestFilename),
            root: runRoot,
            maximumBytes: Self.maximumManifestBytes,
            missing: .manifestMissing,
            unreadable: .manifestUnreadable
        )
        try validateIdentity(run: run, fixture: fixtureManifest)
        let geometry: BenchmarkEvaluationGeometry = try loadCandidate(run.geometry, root: runRoot)
        let candidate = try preparedCandidate(geometry)
        let reference = try loadReference(fixture: fixtureManifest, root: fixtureRoot, e2Ready: validation.e2Ready)

        var metrics = evaluateGeometry(candidate: candidate, reference: reference, fixture: fixtureManifest, thresholds: thresholds)
        metrics.append(contentsOf: evaluateReprojection(run.reprojectionSamples, thresholds: thresholds))
        metrics.append(contentsOf: evaluateResources(run.resources, thresholds: thresholds))
        metrics.append(BenchmarkMetricResult(
            id: "output-integrity",
            disposition: .passed,
            value: 1,
            unit: "boolean",
            threshold: "checksum-bound candidate geometry must validate",
            detail: "Candidate geometry passed containment, size, checksum, schema, finite-value, and index validation."
        ))
        metrics.append(BenchmarkMetricResult(
            id: "warning-count",
            disposition: .passed,
            value: Double(Set(run.warnings).count),
            unit: "count",
            threshold: "reported-only",
            detail: "Warnings are evidence and do not independently change the scorecard disposition."
        ))
        metrics.sort { $0.id < $1.id }

        let views = try renderFixedViews(
            candidate: candidate,
            reference: reference,
            cameras: fixtureManifest.fixedCameras,
            outputRoot: outputRoot
        )
        let disposition: BenchmarkScorecardDisposition = metrics.contains(where: { $0.disposition == .failed })
            ? .failed
            : (metrics.contains(where: { $0.disposition == .unavailable }) ? .insufficientEvidence : .passed)
        let scorecard = BenchmarkEvaluationScorecard(
            schemaVersion: BenchmarkEvaluationScorecard.currentSchemaVersion,
            evaluatorVersion: BenchmarkEvaluationScorecard.evaluatorVersion,
            fixtureID: run.fixtureID,
            fixtureVersion: run.fixtureVersion,
            fixtureManifestSHA256: try sha256(fixtureManifestURL),
            referenceGeometrySHA256: fixtureManifest.assets.first(where: { $0.role == .referenceGeometry })?.sha256,
            sourcePackageSHA256: run.sourcePackageSHA256,
            reconstructionConfigurationSHA256: run.reconstructionConfigurationSHA256,
            candidateGeometrySHA256: run.geometry.sha256,
            buildCommit: run.buildCommit,
            disposition: disposition,
            thresholds: thresholds,
            metrics: metrics,
            warnings: Array(Set(run.warnings)).sorted(),
            fixedViews: views
        )
        try writeAtomically(scorecard.stableJSON(), to: outputRoot.appending(path: Self.scorecardFilename), root: outputRoot)
        try writeOutputChecksums(scorecard: scorecard, outputRoot: outputRoot)
        return scorecard
    }

    private func validateIdentity(run: BenchmarkEvaluationRunManifest, fixture: BenchmarkManifest) throws {
        guard run.schemaVersion == BenchmarkEvaluationRunManifest.currentSchemaVersion,
              run.fixtureID == fixture.fixtureID,
              run.fixtureVersion == fixture.fixtureVersion,
              isSHA256(run.sourcePackageSHA256),
              isSHA256(run.reconstructionConfigurationSHA256),
              !run.buildCommit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              run.geometry.role == .candidateGeometry else {
            throw BenchmarkEvaluationError.runIdentityMismatch
        }
    }

    private func loadCandidate(_ asset: BenchmarkAssetReference, root: URL) throws -> BenchmarkEvaluationGeometry {
        guard asset.byteCount > 0,
              asset.byteCount <= Self.safetyLimits.maximumGeometryBytes,
              isSHA256(asset.sha256) else {
            throw BenchmarkEvaluationError.assetIntegrityFailed
        }
        let url = try containedFile(asset.relativePath, root: root)
        guard try fileSize(url) == asset.byteCount, try sha256(url) == asset.sha256 else {
            throw BenchmarkEvaluationError.assetIntegrityFailed
        }
        let value: BenchmarkEvaluationGeometry
        do {
            value = try JSONDecoder().decode(BenchmarkEvaluationGeometry.self, from: Data(contentsOf: url))
        } catch {
            throw BenchmarkEvaluationError.geometryUnreadable
        }
        return value
    }

    private func preparedCandidate(_ geometry: BenchmarkEvaluationGeometry) throws -> PreparedGeometry {
        guard geometry.schemaVersion == BenchmarkEvaluationGeometry.currentSchemaVersion,
              geometry.coordinateFrame == "geometry-local",
              !geometry.vertices.isEmpty,
              geometry.vertices.count <= Self.safetyLimits.maximumVertices,
              geometry.triangles.count <= Self.safetyLimits.maximumTriangles else {
            throw BenchmarkEvaluationError.geometryInvalid("Unsupported schema, coordinate frame, or bounded geometry count.")
        }
        let points = geometry.vertices.map {
            geometry.fixtureFromGeometry.applying(to: Point3D(x: Float($0.position.x), y: Float($0.position.y), z: Float($0.position.z)))
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw BenchmarkEvaluationError.geometryInvalid("Geometry contains non-finite positions.")
        }
        let inverseColumns = try geometry.fixtureFromGeometry.inverted().columns
        let normals = geometry.vertices.map { vertex -> Vector? in
            guard let normal = vertex.normal else { return nil }
            // Normals transform by the inverse transpose of the geometry transform.
            // This remains correct for rigid, scaled, and sheared synthetic oracles.
            let x = Double(inverseColumns[0]) * normal.x + Double(inverseColumns[1]) * normal.y + Double(inverseColumns[2]) * normal.z
            let y = Double(inverseColumns[4]) * normal.x + Double(inverseColumns[5]) * normal.y + Double(inverseColumns[6]) * normal.z
            let z = Double(inverseColumns[8]) * normal.x + Double(inverseColumns[9]) * normal.y + Double(inverseColumns[10]) * normal.z
            return Vector(x, y, z).normalized
        }
        for triangle in geometry.triangles {
            guard triangle.a >= 0, triangle.b >= 0, triangle.c >= 0,
                  triangle.a < points.count, triangle.b < points.count, triangle.c < points.count,
                  triangle.a != triangle.b, triangle.b != triangle.c, triangle.c != triangle.a else {
                throw BenchmarkEvaluationError.geometryInvalid("Geometry contains an invalid triangle index.")
            }
            guard triangleArea(points[triangle.a], points[triangle.b], points[triangle.c]) > 0.000_000_000_1 else {
                throw BenchmarkEvaluationError.geometryInvalid("Geometry contains a degenerate triangle.")
            }
        }
        return PreparedGeometry(points: points, normals: normals, colors: geometry.vertices.map(\.color), triangles: geometry.triangles)
    }

    private func loadReference(fixture: BenchmarkManifest, root: URL, e2Ready: Bool) throws -> ReferenceGeometry? {
        guard e2Ready, let asset = fixture.assets.first(where: { $0.role == .referenceGeometry }) else { return nil }
        let url = try containedFile(asset.relativePath, root: root)
        guard try fileSize(url) == asset.byteCount, try sha256(url) == asset.sha256 else {
            throw BenchmarkEvaluationError.assetIntegrityFailed
        }
        let document: ReferenceDocument
        do { document = try JSONDecoder().decode(ReferenceDocument.self, from: Data(contentsOf: url)) }
        catch { throw BenchmarkEvaluationError.referenceUnavailable }
        guard document.coordinateFrame == fixture.reference.coordinateFrame else {
            throw BenchmarkEvaluationError.referenceUnavailable
        }
        if let vertices = document.vertices, !vertices.isEmpty {
            let points = vertices.map { Point3D(x: Float($0.x), y: Float($0.y), z: Float($0.z)) }
            return ReferenceGeometry(points: points, surfaces: [], expectedBounds: document.referenceBounds ?? fixture.expectedVisibleRegion.bounds)
        }
        guard let surfaces = document.surfaces, !surfaces.isEmpty else { throw BenchmarkEvaluationError.referenceUnavailable }
        let required = Set(fixture.expectedVisibleRegion.requiredSurfaceIDs)
        let retained = surfaces.filter { required.isEmpty || required.contains($0.id) }
        guard !retained.isEmpty else { throw BenchmarkEvaluationError.referenceUnavailable }
        let bounds = document.referenceBounds ?? fixture.expectedVisibleRegion.bounds
        let points = sample(surfaces: retained, bounds: bounds, step: 0.04)
        return ReferenceGeometry(points: points, surfaces: retained, expectedBounds: bounds)
    }

    private func evaluateGeometry(
        candidate: PreparedGeometry,
        reference: ReferenceGeometry?,
        fixture: BenchmarkManifest,
        thresholds: BenchmarkEvaluationThresholds
    ) -> [BenchmarkMetricResult] {
        guard let reference else {
            return unavailableGeometryMetrics(detail: "The fixture has no independently checkable, integrity-qualified reference geometry.")
        }
        let candidateIndex = SpatialKDTree(points: candidate.points)
        let referenceIndex = reference.surfaces.isEmpty ? SpatialKDTree(points: reference.points) : nil
        let candidateDistances = candidate.points.map {
            referenceIndex?.nearestDistance(to: $0) ?? distance($0, to: reference)
        }.sorted()
        let referenceDistances = reference.points.map { candidateIndex.nearestDistance(to: $0) }
        let median = percentile(candidateDistances, 0.50)
        let p95 = percentile(candidateDistances, 0.95)
        let completeness = Double(referenceDistances.filter { $0 <= thresholds.surfaceP95Meters }.count) / Double(referenceDistances.count)
        let outliers = Double(candidateDistances.filter { $0 > thresholds.surfaceP95Meters }.count) / Double(candidateDistances.count)
        let dimensionError = maximumDimensionError(points: candidate.points, bounds: reference.expectedBounds)
        let topology = topologyMetrics(candidate)
        let normalConsistency: Double? = {
            let values = candidate.normals.compactMap { $0 }
            guard !values.isEmpty, !reference.surfaces.isEmpty else { return nil }
            return Double(values.filter { normal in reference.surfaces.contains { abs(normal.dot($0.vector.normalized)) >= 0.90 } }.count) / Double(values.count)
        }()
        let colorCoverage = Double(candidate.colors.compactMap { $0 }.count) / Double(candidate.colors.count)
        let volumeMeasurement = fixture.reference.measurements.first(where: { $0.quantity == .volume && $0.unit == .cubicMeter })
        let volumeError: Double? = {
            guard let volumeMeasurement, topology.boundaryEdgeRatio == 0, !candidate.triangles.isEmpty else { return nil }
            let volume = enclosedVolume(candidate)
            return abs(volume - volumeMeasurement.value) / max(abs(volumeMeasurement.value), 0.000_001)
        }()
        return [
            maximumMetric("surface-median-distance", median, "meter", thresholds.surfaceMedianMeters, "<=", "Candidate-to-reference median surface distance."),
            maximumMetric("surface-p95-distance", p95, "meter", thresholds.surfaceP95Meters, "<=", "Candidate-to-reference p95 surface distance."),
            maximumMetric("maximum-dimension-relative-error", dimensionError, "ratio", thresholds.maximumDimensionRelativeError, "<=", "Maximum robust X/Y/Z extent error."),
            minimumMetric("observed-completeness", completeness, "ratio", thresholds.minimumObservedCompleteness, ">=", "Fraction of deliberately sampled reference surface observed within the p95 distance tolerance."),
            maximumMetric("outlier-ratio", outliers, "ratio", thresholds.maximumOutlierRatio, "<=", "Fraction of candidate vertices beyond the p95 distance tolerance."),
            maximumMetric("disconnected-component-ratio", topology.disconnectedComponentRatio, "ratio", thresholds.maximumDisconnectedComponentRatio, "<=", "Surface-area ratio outside the largest welded component."),
            maximumMetric("boundary-edge-ratio", topology.boundaryEdgeRatio, "ratio", thresholds.maximumBoundaryEdgeRatio, "<=", "Boundary edges divided by unique welded mesh edges."),
            optionalMinimumMetric("normal-consistency", normalConsistency, "ratio", thresholds.minimumNormalConsistency, "Normals or reference surface normals are unavailable."),
            minimumMetric("color-coverage", colorCoverage, "ratio", thresholds.minimumColorCoverage, ">=", "Fraction of candidate vertices carrying RGB color."),
            optionalMaximumMetric("volume-relative-error", volumeError, "ratio", thresholds.maximumVolumeRelativeError, "A closed candidate mesh and reference volume are both required.")
        ]
    }

    private func evaluateReprojection(_ samples: [BenchmarkReprojectionSample], thresholds: BenchmarkEvaluationThresholds) -> [BenchmarkMetricResult] {
        guard !samples.isEmpty, samples.allSatisfy({ $0.projectedX.isFinite && $0.projectedY.isFinite && $0.observedX.isFinite && $0.observedY.isFinite }) else {
            return [
                unavailable("reprojection-rmse", unit: "pixel", threshold: "<= \(thresholds.maximumReprojectionRMSEPixels)", detail: "No qualified reprojection samples were declared."),
                unavailable("reprojection-occlusion-failure-ratio", unit: "ratio", threshold: "<= \(thresholds.maximumReprojectionOcclusionFailureRatio)", detail: "No qualified occlusion samples were declared.")
            ]
        }
        let squared = samples.map { pow($0.projectedX - $0.observedX, 2) + pow($0.projectedY - $0.observedY, 2) }
        let rmse = sqrt(squared.reduce(0, +) / Double(squared.count))
        let failures = Double(samples.filter { !$0.passedOcclusionTest }.count) / Double(samples.count)
        return [
            maximumMetric("reprojection-rmse", rmse, "pixel", thresholds.maximumReprojectionRMSEPixels, "<=", "Root-mean-square declared image reprojection error."),
            maximumMetric("reprojection-occlusion-failure-ratio", failures, "ratio", thresholds.maximumReprojectionOcclusionFailureRatio, "<=", "Fraction of declared reprojections failing the occlusion test.")
        ]
    }

    private func evaluateResources(_ resources: BenchmarkResourceObservation?, thresholds: BenchmarkEvaluationThresholds) -> [BenchmarkMetricResult] {
        [
            optionalMaximumMetric("processing-time", resources?.processingSeconds, "second", thresholds.maximumProcessingSeconds, "No processing-time observation was declared."),
            optionalMaximumMetric("peak-memory", resources?.peakMemoryBytes.map(Double.init), "byte", Double(thresholds.maximumPeakMemoryBytes), "No peak-memory observation was declared."),
            optionalMaximumMetric("storage", resources?.storageBytes.map(Double.init), "byte", Double(thresholds.maximumStorageBytes), "No storage observation was declared.")
        ]
    }

    private func unavailableGeometryMetrics(detail: String) -> [BenchmarkMetricResult] {
        ["surface-median-distance", "surface-p95-distance", "maximum-dimension-relative-error", "observed-completeness", "outlier-ratio", "disconnected-component-ratio", "boundary-edge-ratio", "normal-consistency", "color-coverage", "volume-relative-error"].map {
            unavailable($0, unit: nil, threshold: "reference-required", detail: detail)
        }
    }

    private func maximumMetric(_ id: String, _ value: Double, _ unit: String, _ threshold: Double, _ symbol: String, _ detail: String) -> BenchmarkMetricResult {
        BenchmarkMetricResult(id: id, disposition: value <= threshold ? .passed : .failed, value: value, unit: unit, threshold: "\(symbol) \(threshold)", detail: detail)
    }

    private func minimumMetric(_ id: String, _ value: Double, _ unit: String, _ threshold: Double, _ symbol: String, _ detail: String) -> BenchmarkMetricResult {
        BenchmarkMetricResult(id: id, disposition: value >= threshold ? .passed : .failed, value: value, unit: unit, threshold: "\(symbol) \(threshold)", detail: detail)
    }

    private func optionalMaximumMetric(_ id: String, _ value: Double?, _ unit: String, _ threshold: Double, _ unavailableDetail: String) -> BenchmarkMetricResult {
        guard let value, value.isFinite, value >= 0 else { return unavailable(id, unit: unit, threshold: "<= \(threshold)", detail: unavailableDetail) }
        return maximumMetric(id, value, unit, threshold, "<=", "Measured value compared with the declared R0.3 threshold.")
    }

    private func optionalMinimumMetric(_ id: String, _ value: Double?, _ unit: String, _ threshold: Double, _ unavailableDetail: String) -> BenchmarkMetricResult {
        guard let value, value.isFinite else { return unavailable(id, unit: unit, threshold: ">= \(threshold)", detail: unavailableDetail) }
        return minimumMetric(id, value, unit, threshold, ">=", "Measured value compared with the declared R0.3 threshold.")
    }

    private func unavailable(_ id: String, unit: String?, threshold: String, detail: String) -> BenchmarkMetricResult {
        BenchmarkMetricResult(id: id, disposition: .unavailable, value: nil, unit: unit, threshold: threshold, detail: detail)
    }

    private func renderFixedViews(candidate: PreparedGeometry, reference: ReferenceGeometry?, cameras: [BenchmarkFixedCamera], outputRoot: URL) throws -> [BenchmarkFixedViewArtifact] {
        let viewsRoot = outputRoot.appending(path: "fixed-views", directoryHint: .isDirectory)
        _ = try safeDirectory(viewsRoot, create: true)
        var artifacts: [BenchmarkFixedViewArtifact] = []
        for camera in cameras.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            guard camera.widthPixels <= 4_096, camera.heightPixels <= 4_096 else {
                throw BenchmarkEvaluationError.outputFailure("Fixed-view dimensions exceed the evaluator bound.")
            }
            let data = try svg(candidate: candidate, reference: reference, camera: camera)
            let relativePath = "fixed-views/\(camera.id).svg"
            let url = outputRoot.appending(path: relativePath)
            try writeAtomically(data, to: url, root: outputRoot)
            artifacts.append(BenchmarkFixedViewArtifact(cameraID: camera.id, relativePath: relativePath, byteCount: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
        }
        return artifacts
    }

    private func svg(candidate: PreparedGeometry, reference: ReferenceGeometry?, camera: BenchmarkFixedCamera) throws -> Data {
        let cameraFromFixture = try camera.fixtureFromCamera.inverted()
        let width = Double(camera.widthPixels), height = Double(camera.heightPixels)
        let focal = height * 0.5 / tan(camera.verticalFieldOfViewDegrees * .pi / 360)
        func projected(_ point: Point3D) -> (Double, Double, Double)? {
            let p = cameraFromFixture.applying(to: point)
            let depth = -Double(p.z)
            guard depth > 0.01 else { return nil }
            return (width * 0.5 + focal * Double(p.x) / depth, height * 0.5 - focal * Double(p.y) / depth, depth)
        }
        var dots: [(Double, Double, Double, String, Double)] = []
        let referencePoints = boundedSamples(reference?.points ?? [], maximum: Self.maximumRenderPoints)
        dots.append(contentsOf: referencePoints.compactMap { point in projected(point).map { ($0.0, $0.1, $0.2, "#7c8791", 0.42) } })
        let indices = boundedIndices(count: candidate.points.count, maximum: Self.maximumRenderPoints)
        for index in indices {
            guard let p = projected(candidate.points[index]) else { continue }
            let color = candidate.colors[index].map { String(format: "#%02x%02x%02x", $0.red, $0.green, $0.blue) } ?? "#20d5df"
            dots.append((p.0, p.1, p.2, color, 0.86))
        }
        dots.sort { ($0.2, $0.0, $0.1, $0.3) > ($1.2, $1.0, $1.1, $1.3) }
        var text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(camera.widthPixels)\" height=\"\(camera.heightPixels)\" viewBox=\"0 0 \(camera.widthPixels) \(camera.heightPixels)\"><rect width=\"100%\" height=\"100%\" fill=\"#050608\"/>"
        for dot in dots where dot.0 >= 0 && dot.0 <= width && dot.1 >= 0 && dot.1 <= height {
            text += String(format: "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"1.35\" fill=\"%@\" fill-opacity=\"%.2f\"/>", dot.0, dot.1, dot.3, dot.4)
        }
        text += "</svg>"
        guard let data = text.data(using: .utf8) else { throw BenchmarkEvaluationError.outputFailure("Unable to encode SVG.") }
        return data
    }

    private func maximumDimensionError(points: [Point3D], bounds: BenchmarkBounds) -> Double {
        let xs = points.map { Double($0.x) }.sorted(), ys = points.map { Double($0.y) }.sorted(), zs = points.map { Double($0.z) }.sorted()
        let observed = [percentile(xs, 0.99) - percentile(xs, 0.01), percentile(ys, 0.99) - percentile(ys, 0.01), percentile(zs, 0.99) - percentile(zs, 0.01)]
        let expected = [bounds.maximum.x - bounds.minimum.x, bounds.maximum.y - bounds.minimum.y, bounds.maximum.z - bounds.minimum.z]
        return zip(observed, expected).map { abs($0 - $1) / max(abs($1), 0.000_001) }.max() ?? .infinity
    }

    private func distance(_ point: Point3D, to reference: ReferenceGeometry) -> Double {
        if reference.surfaces.isEmpty { return .infinity }
        return reference.surfaces.map { surfaceDistance(point, surface: $0, bounds: reference.expectedBounds) }.min() ?? .infinity
    }

    private func euclideanDistance(_ lhs: Point3D, _ rhs: Point3D) -> Double {
        let x = Double(lhs.x - rhs.x)
        let y = Double(lhs.y - rhs.y)
        let z = Double(lhs.z - rhs.z)
        return sqrt(x * x + y * y + z * z)
    }

    private func benchmarkVector(_ point: Point3D) -> BenchmarkVector3 {
        BenchmarkVector3(x: Double(point.x), y: Double(point.y), z: Double(point.z))
    }

    private func surfaceDistance(_ point: Point3D, surface: ReferenceSurface, bounds: BenchmarkBounds) -> Double {
        let p = Vector(Double(point.x), Double(point.y), Double(point.z))
        let normal = surface.vector.normalized
        let signed = normal.dot(p) - surface.offset
        let projection = p - normal * signed
        let clamped = Vector(
            min(max(projection.x, bounds.minimum.x), bounds.maximum.x),
            min(max(projection.y, bounds.minimum.y), bounds.maximum.y),
            min(max(projection.z, bounds.minimum.z), bounds.maximum.z)
        )
        return (p - clamped).length
    }

    private func topologyMetrics(_ geometry: PreparedGeometry) -> (disconnectedComponentRatio: Double, boundaryEdgeRatio: Double) {
        guard !geometry.triangles.isEmpty else { return (1, 1) }
        var parent = Array(geometry.triangles.indices)
        func root(_ value: Int) -> Int { var p = value; while parent[p] != p { p = parent[p] }; return p }
        func key(_ index: Int) -> QuantizedPoint { QuantizedPoint(geometry.points[index]) }
        var edges: [WeldedEdge: [Int]] = [:]
        for (triangleIndex, t) in geometry.triangles.enumerated() {
            for edge in [WeldedEdge(key(t.a), key(t.b)), WeldedEdge(key(t.b), key(t.c)), WeldedEdge(key(t.c), key(t.a))] { edges[edge, default: []].append(triangleIndex) }
        }
        for owners in edges.values where owners.count > 1 {
            let first = root(owners[0]); for owner in owners.dropFirst() { let other = root(owner); if first != other { parent[other] = first } }
        }
        var areaByRoot: [Int: Double] = [:]
        for (index, t) in geometry.triangles.enumerated() { areaByRoot[root(index), default: 0] += triangleArea(geometry.points[t.a], geometry.points[t.b], geometry.points[t.c]) }
        let total = areaByRoot.values.reduce(0, +)
        let largest = areaByRoot.values.max() ?? 0
        let boundary = edges.values.filter { $0.count == 1 }.count
        return (total > 0 ? (total - largest) / total : 1, Double(boundary) / Double(max(edges.count, 1)))
    }

    private func enclosedVolume(_ geometry: PreparedGeometry) -> Double {
        abs(geometry.triangles.reduce(0) { total, triangle in
            let a = Vector(geometry.points[triangle.a]), b = Vector(geometry.points[triangle.b]), c = Vector(geometry.points[triangle.c])
            return total + a.dot(b.cross(c)) / 6
        })
    }

    private func triangleArea(_ a: Point3D, _ b: Point3D, _ c: Point3D) -> Double { 0.5 * (Vector(b) - Vector(a)).cross(Vector(c) - Vector(a)).length }

    private func sample(surfaces: [ReferenceSurface], bounds: BenchmarkBounds, step: Double) -> [Point3D] {
        var result: [Point3D] = []
        let xs = strideValues(bounds.minimum.x, bounds.maximum.x, step), ys = strideValues(bounds.minimum.y, bounds.maximum.y, step), zs = strideValues(bounds.minimum.z, bounds.maximum.z, step)
        for surface in surfaces {
            let n = surface.vector.normalized
            if abs(n.x) > 0.999 { for y in ys { for z in zs { result.append(Point3D(x: Float(surface.offset / n.x), y: Float(y), z: Float(z))) } } }
            else if abs(n.y) > 0.999 { for x in xs { for z in zs { result.append(Point3D(x: Float(x), y: Float(surface.offset / n.y), z: Float(z))) } } }
            else if abs(n.z) > 0.999 { for x in xs { for y in ys { result.append(Point3D(x: Float(x), y: Float(y), z: Float(surface.offset / n.z))) } } }
        }
        return result
    }

    private func strideValues(_ minimum: Double, _ maximum: Double, _ step: Double) -> [Double] {
        let count = max(Int(ceil((maximum - minimum) / step)), 1)
        return (0...count).map { minimum + (maximum - minimum) * Double($0) / Double(count) }
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return .infinity }
        return sorted[min(Int((Double(sorted.count - 1) * fraction).rounded()), sorted.count - 1)]
    }

    private func boundedSamples(_ points: [Point3D], maximum: Int) -> [Point3D] { boundedIndices(count: points.count, maximum: maximum).map { points[$0] } }
    private func boundedIndices(count: Int, maximum: Int) -> [Int] {
        guard count > maximum else { return Array(0..<count) }
        return (0..<maximum).map { $0 * count / maximum }
    }

    private func safeDirectory(_ url: URL, create: Bool) throws -> URL {
        let root = url.standardizedFileURL
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw BenchmarkEvaluationError.unsafeDirectory }
        return root
    }

    private func containedFile(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw BenchmarkEvaluationError.unsafeAsset }
        let url = root.appending(path: path).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedCandidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resolvedCandidate.hasPrefix(prefix), values.isRegularFile == true, values.isSymbolicLink != true else { throw BenchmarkEvaluationError.unsafeAsset }
        return url
    }

    private func decodeBounded<T: Decodable>(_ url: URL, root: URL, maximumBytes: Int64, missing: BenchmarkEvaluationError, unreadable: BenchmarkEvaluationError) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { throw missing }
        guard (try? containedFile(String(url.path.dropFirst(root.path.count + 1)), root: root)) != nil, (try? fileSize(url)) ?? .max <= maximumBytes else { throw unreadable }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) } catch { throw unreadable }
    }

    private func fileSize(_ url: URL) throws -> Int64 { Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func isSHA256(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    private func writeAtomically(_ data: Data, to url: URL, root: URL) throws {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw BenchmarkEvaluationError.outputFailure("Output escaped its root.") }
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw BenchmarkEvaluationError.outputFailure("An existing output is not a safe regular file.")
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private func writeOutputChecksums(scorecard: BenchmarkEvaluationScorecard, outputRoot: URL) throws {
        var assets = scorecard.fixedViews.map { OutputChecksum(relativePath: $0.relativePath, byteCount: $0.byteCount, sha256: $0.sha256) }
        let metricsURL = outputRoot.appending(path: Self.scorecardFilename)
        assets.append(OutputChecksum(relativePath: Self.scorecardFilename, byteCount: try fileSize(metricsURL), sha256: try sha256(metricsURL)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        _ = try safeDirectory(outputRoot.appending(path: "outputs", directoryHint: .isDirectory), create: true)
        try writeAtomically(try encoder.encode(OutputChecksums(schemaVersion: 1, assets: assets.sorted { $0.relativePath < $1.relativePath })), to: outputRoot.appending(path: "outputs/checksums.json"), root: outputRoot)
    }
}

private struct PreparedGeometry { let points: [Point3D]; let normals: [Vector?]; let colors: [BenchmarkEvaluationColor?]; let triangles: [BenchmarkEvaluationTriangle] }
private struct ReferenceGeometry { let points: [Point3D]; let surfaces: [ReferenceSurface]; let expectedBounds: BenchmarkBounds }
private struct ReferenceDocument: Decodable {
    let coordinateFrame: String
    let surfaces: [ReferenceSurface]?
    let vertices: [BenchmarkVector3]?
    let dimensions: [String: Double]?

    var referenceBounds: BenchmarkBounds? {
        guard let dimensions,
              let width = dimensions["width"], let height = dimensions["height"], let depth = dimensions["depth"],
              width > 0, height > 0, depth > 0 else { return nil }
        return BenchmarkBounds(
            minimum: BenchmarkVector3(x: 0, y: 0, z: 0),
            maximum: BenchmarkVector3(x: width, y: height, z: depth)
        )
    }
}
private struct ReferenceSurface: Decodable { let id: String; let normal: [Double]; let offset: Double; var vector: Vector { Vector(normal.count > 0 ? normal[0] : 0, normal.count > 1 ? normal[1] : 0, normal.count > 2 ? normal[2] : 0) } }
private struct OutputChecksum: Codable { let relativePath: String; let byteCount: Int64; let sha256: String }
private struct OutputChecksums: Codable { let schemaVersion: Int; let assets: [OutputChecksum] }

private struct Vector {
    let x: Double, y: Double, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    init(_ point: Point3D) { self.init(Double(point.x), Double(point.y), Double(point.z)) }
    var length: Double { sqrt(x * x + y * y + z * z) }
    var normalized: Vector { let divisor = max(length, 0.000_000_001); return self * (1 / divisor) }
    func dot(_ rhs: Vector) -> Double { x * rhs.x + y * rhs.y + z * rhs.z }
    func cross(_ rhs: Vector) -> Vector { Vector(y * rhs.z - z * rhs.y, z * rhs.x - x * rhs.z, x * rhs.y - y * rhs.x) }
    static func - (lhs: Vector, rhs: Vector) -> Vector { Vector(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z) }
    static func * (lhs: Vector, rhs: Double) -> Vector { Vector(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs) }
}

private struct QuantizedPoint: Hashable, Comparable {
    let x: Int, y: Int, z: Int
    init(_ point: Point3D) { x = Int((Double(point.x) * 10_000).rounded()); y = Int((Double(point.y) * 10_000).rounded()); z = Int((Double(point.z) * 10_000).rounded()) }
    static func < (lhs: QuantizedPoint, rhs: QuantizedPoint) -> Bool { (lhs.x, lhs.y, lhs.z) < (rhs.x, rhs.y, rhs.z) }
}
private struct WeldedEdge: Hashable { let a: QuantizedPoint, b: QuantizedPoint; init(_ lhs: QuantizedPoint, _ rhs: QuantizedPoint) { if lhs < rhs { a = lhs; b = rhs } else { a = rhs; b = lhs } } }

private struct SpatialKDTree {
    private final class Node {
        let point: Point3D
        let axis: Int
        let left: Node?
        let right: Node?
        init(point: Point3D, axis: Int, left: Node?, right: Node?) { self.point = point; self.axis = axis; self.left = left; self.right = right }
    }

    private let root: Node?

    init(points: [Point3D]) { root = Self.build(points, depth: 0) }

    func nearestDistance(to point: Point3D) -> Double {
        var squaredBest = Double.infinity
        Self.search(root, query: point, squaredBest: &squaredBest)
        return sqrt(squaredBest)
    }

    private static func build(_ points: [Point3D], depth: Int) -> Node? {
        guard !points.isEmpty else { return nil }
        let axis = depth % 3
        let sorted = points.sorted { coordinate($0, axis) < coordinate($1, axis) }
        let middle = sorted.count / 2
        let rightPoints = middle + 1 < sorted.count ? Array(sorted[(middle + 1)...]) : []
        return Node(
            point: sorted[middle],
            axis: axis,
            left: build(Array(sorted[..<middle]), depth: depth + 1),
            right: build(rightPoints, depth: depth + 1)
        )
    }

    private static func search(_ node: Node?, query: Point3D, squaredBest: inout Double) {
        guard let node else { return }
        let dx = Double(query.x - node.point.x), dy = Double(query.y - node.point.y), dz = Double(query.z - node.point.z)
        squaredBest = min(squaredBest, dx * dx + dy * dy + dz * dz)
        let delta = coordinate(query, node.axis) - coordinate(node.point, node.axis)
        let near = delta < 0 ? node.left : node.right
        let far = delta < 0 ? node.right : node.left
        search(near, query: query, squaredBest: &squaredBest)
        if delta * delta < squaredBest { search(far, query: query, squaredBest: &squaredBest) }
    }

    private static func coordinate(_ point: Point3D, _ axis: Int) -> Double {
        switch axis {
        case 0: return Double(point.x)
        case 1: return Double(point.y)
        default: return Double(point.z)
        }
    }
}
