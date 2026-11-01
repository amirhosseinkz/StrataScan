import Foundation

public enum BenchmarkResidualDomain: String, Codable, CaseIterable, Sendable {
    case admittedSourceDepth = "admitted-source-depth"
    case candidateSurface = "candidate-surface"
    case sourceDepth = "source-depth"
    case missingReference = "missing-reference"
}

public enum BenchmarkResidualAttribution: String, Codable, Sendable {
    // Legacy labels retained for decoding old reports, never emitted by v2.
    case sourceEvidenceAlreadyMisaligned = "source-evidence-already-misaligned"
    case fusionOrExtraction = "fusion-or-extraction"
    case sourceAndCandidateDisagreeWithReference = "source-and-candidate-disagree-with-reference"
    case candidateDisagreesWithReference = "candidate-disagrees-with-reference"
    case candidateWithinThreshold = "candidate-within-threshold"
    case insufficientEvidence = "insufficient-evidence"
}

public enum BenchmarkReferenceDistanceMode: String, Codable, Equatable, Sendable {
    case continuousTriangleSurface = "continuous-triangle-surface"
    case nearestReferenceSample = "nearest-reference-sample"
}

public struct BenchmarkResidualLocalizationConfiguration: Codable, Equatable, Sendable {
    public static let `default` = BenchmarkResidualLocalizationConfiguration(
        uncheckedCellSizeMeters: 0.25,
        surfaceThresholdMeters: BenchmarkEvaluationThresholds.initialCloseRange.surfaceP95Meters,
        depthBandUpperBoundsMeters: [1, 2, 3, 4, 5],
        maximumSourceSamples: 240_000,
        maximumReferenceSamples: 1_000_000,
        maximumReportedCellsPerDomain: 48,
        minimumSamplesPerAggregate: 24
    )

    public let cellSizeMeters: Double
    public let surfaceThresholdMeters: Double
    public let depthBandUpperBoundsMeters: [Double]
    public let maximumSourceSamples: Int
    public let maximumReferenceSamples: Int
    public let maximumReportedCellsPerDomain: Int
    public let minimumSamplesPerAggregate: Int

    public init(
        cellSizeMeters: Double,
        surfaceThresholdMeters: Double,
        depthBandUpperBoundsMeters: [Double],
        maximumSourceSamples: Int = 240_000,
        maximumReferenceSamples: Int = 1_000_000,
        maximumReportedCellsPerDomain: Int = 48,
        minimumSamplesPerAggregate: Int = 24
    ) throws {
        guard cellSizeMeters.isFinite,
              (0.05...2).contains(cellSizeMeters),
              surfaceThresholdMeters.isFinite,
              (0.001...1).contains(surfaceThresholdMeters),
              !depthBandUpperBoundsMeters.isEmpty,
              depthBandUpperBoundsMeters.count <= 16,
              depthBandUpperBoundsMeters.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(depthBandUpperBoundsMeters, depthBandUpperBoundsMeters.dropFirst()).allSatisfy(<),
              (1_000...1_000_000).contains(maximumSourceSamples),
              (1_000...1_000_000).contains(maximumReferenceSamples),
              (1...256).contains(maximumReportedCellsPerDomain),
              (1...10_000).contains(minimumSamplesPerAggregate)
        else {
            throw BenchmarkEvaluationError.geometryInvalid("Invalid residual-localization configuration.")
        }
        self.cellSizeMeters = cellSizeMeters
        self.surfaceThresholdMeters = surfaceThresholdMeters
        self.depthBandUpperBoundsMeters = depthBandUpperBoundsMeters
        self.maximumSourceSamples = maximumSourceSamples
        self.maximumReferenceSamples = maximumReferenceSamples
        self.maximumReportedCellsPerDomain = maximumReportedCellsPerDomain
        self.minimumSamplesPerAggregate = minimumSamplesPerAggregate
    }

    private init(
        uncheckedCellSizeMeters cellSizeMeters: Double,
        surfaceThresholdMeters: Double,
        depthBandUpperBoundsMeters: [Double],
        maximumSourceSamples: Int,
        maximumReferenceSamples: Int,
        maximumReportedCellsPerDomain: Int,
        minimumSamplesPerAggregate: Int
    ) {
        self.cellSizeMeters = cellSizeMeters
        self.surfaceThresholdMeters = surfaceThresholdMeters
        self.depthBandUpperBoundsMeters = depthBandUpperBoundsMeters
        self.maximumSourceSamples = maximumSourceSamples
        self.maximumReferenceSamples = maximumReferenceSamples
        self.maximumReportedCellsPerDomain = maximumReportedCellsPerDomain
        self.minimumSamplesPerAggregate = minimumSamplesPerAggregate
    }
}

public struct BenchmarkResidualObservation: Codable, Equatable, Sendable {
    public let domain: BenchmarkResidualDomain
    public let position: BenchmarkVector3
    public let residualMeters: Double
    /// Exact camera-space depth for source observations; nearest retained-camera
    /// range for candidate observations; unavailable for reference misses.
    public let sourceDepthOrCameraRangeMeters: Double?
    public let confidence: UInt8?

    public init(
        domain: BenchmarkResidualDomain,
        position: BenchmarkVector3,
        residualMeters: Double,
        sourceDepthOrCameraRangeMeters: Double? = nil,
        confidence: UInt8? = nil
    ) {
        self.domain = domain
        self.position = position
        self.residualMeters = residualMeters
        self.sourceDepthOrCameraRangeMeters = sourceDepthOrCameraRangeMeters
        self.confidence = confidence
    }
}

public struct BenchmarkResidualAggregate: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let medianMeters: Double
    public let p95Meters: Double
    public let outlierRatio: Double
}

public struct BenchmarkResidualDomainAggregate: Codable, Equatable, Sendable {
    public let domain: BenchmarkResidualDomain
    public let aggregate: BenchmarkResidualAggregate
}

public struct BenchmarkResidualDepthBand: Codable, Equatable, Sendable {
    public let domain: BenchmarkResidualDomain
    public let lowerBoundMeters: Double
    public let upperBoundMeters: Double?
    public let aggregate: BenchmarkResidualAggregate
}

public struct BenchmarkResidualConfidenceBand: Codable, Equatable, Sendable {
    public let confidence: UInt8
    public let aggregate: BenchmarkResidualAggregate
}

public struct BenchmarkResidualCell: Codable, Equatable, Sendable {
    public let domain: BenchmarkResidualDomain
    public let x: Int
    public let y: Int
    public let z: Int
    public let aggregate: BenchmarkResidualAggregate
}

public struct BenchmarkResidualLocalizationIdentity: Codable, Equatable, Sendable {
    public let fixtureID: String
    public let fixtureVersion: Int
    public let fixtureManifestSHA256: String
    public let referenceGeometrySHA256: String
    public let sourcePackageSHA256: String
    public let sourceArchiveSHA256: String
    public let reconstructionConfigurationSHA256: String
    public let candidateGeometrySHA256: String
    public let buildCommit: String
}

public struct BenchmarkResidualLocalizationReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3
    public static let localizerVersion = "R0-audit-residual-localization-v3"

    public let schemaVersion: Int
    public let localizerVersion: String
    public let identity: BenchmarkResidualLocalizationIdentity
    public let configuration: BenchmarkResidualLocalizationConfiguration
    public let referenceDistanceMode: BenchmarkReferenceDistanceMode
    public let reconstructionAdmissionConfiguration: TSDFReconstructionConfiguration?
    /// Sorted by domain raw value so JSON remains byte-stable across processes.
    public let global: [BenchmarkResidualDomainAggregate]
    public let depthBands: [BenchmarkResidualDepthBand]
    public let confidenceBands: [BenchmarkResidualConfidenceBand]
    public let worstSpatialCells: [BenchmarkResidualCell]
    public let attribution: BenchmarkResidualAttribution
    public let limitations: [String]

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }


    public func aggregate(for domain: BenchmarkResidualDomain) -> BenchmarkResidualAggregate? {
        global.first(where: { $0.domain == domain })?.aggregate
    }
}

public struct BenchmarkResidualAnalyzer: Sendable {
    public init() {}

    public func analyze(
        identity: BenchmarkResidualLocalizationIdentity,
        observations: [BenchmarkResidualObservation],
        configuration: BenchmarkResidualLocalizationConfiguration = .default,
        referenceDistanceMode: BenchmarkReferenceDistanceMode = .nearestReferenceSample,
        reconstructionAdmissionConfiguration: TSDFReconstructionConfiguration? = nil
    ) throws -> BenchmarkResidualLocalizationReport {
        guard !observations.isEmpty,
              observations.count <= 2_000_000,
              observations.allSatisfy({ observation in
                  [observation.position.x, observation.position.y, observation.position.z].allSatisfy {
                      $0.isFinite && abs($0) <= 1_000_000
                  } &&
                      observation.residualMeters.isFinite && observation.residualMeters >= 0 &&
                      (observation.sourceDepthOrCameraRangeMeters.map { $0.isFinite && $0 >= 0 } ?? true)
              })
        else {
            throw BenchmarkEvaluationError.geometryInvalid("Residual observations are empty, invalid, or unbounded.")
        }

        var aggregatesByDomain: [BenchmarkResidualDomain: BenchmarkResidualAggregate] = [:]
        for domain in BenchmarkResidualDomain.allCases {
            let values = observations.lazy.filter { $0.domain == domain }.map(\.residualMeters)
            if let aggregate = aggregate(Array(values), configuration: configuration) {
                aggregatesByDomain[domain] = aggregate
            }
        }

        var depthBands: [BenchmarkResidualDepthBand] = []
        for domain in [BenchmarkResidualDomain.sourceDepth, .admittedSourceDepth, .candidateSurface] {
            var lower = 0.0
            for upper in configuration.depthBandUpperBoundsMeters.map(Optional.some) + [nil] {
                let values = observations.compactMap { observation -> Double? in
                    guard observation.domain == domain,
                          let depth = observation.sourceDepthOrCameraRangeMeters,
                          depth >= lower,
                          upper.map({ depth < $0 }) ?? true else { return nil }
                    return observation.residualMeters
                }
                if let value = aggregate(values, configuration: configuration) {
                    depthBands.append(BenchmarkResidualDepthBand(
                        domain: domain,
                        lowerBoundMeters: lower,
                        upperBoundMeters: upper,
                        aggregate: value
                    ))
                }
                if let upper { lower = upper }
            }
        }

        let confidenceBands = (UInt8(0)...UInt8(2)).compactMap { confidence -> BenchmarkResidualConfidenceBand? in
            let values = observations.compactMap { observation -> Double? in
                guard observation.domain == .sourceDepth,
                      observation.confidence == confidence else { return nil }
                return observation.residualMeters
            }
            return aggregate(values, configuration: configuration).map {
                BenchmarkResidualConfidenceBand(confidence: confidence, aggregate: $0)
            }
        }

        struct CellKey: Hashable { let domain: BenchmarkResidualDomain; let x: Int; let y: Int; let z: Int }
        var residualsByCell: [CellKey: [Double]] = [:]
        for observation in observations {
            let key = CellKey(
                domain: observation.domain,
                x: Int(floor(observation.position.x / configuration.cellSizeMeters)),
                y: Int(floor(observation.position.y / configuration.cellSizeMeters)),
                z: Int(floor(observation.position.z / configuration.cellSizeMeters))
            )
            residualsByCell[key, default: []].append(observation.residualMeters)
        }
        let cells = residualsByCell.compactMap { key, values -> BenchmarkResidualCell? in
            aggregate(values, configuration: configuration).map {
                BenchmarkResidualCell(domain: key.domain, x: key.x, y: key.y, z: key.z, aggregate: $0)
            }
        }
        let worstCells = BenchmarkResidualDomain.allCases.flatMap { domain in
            cells.filter { $0.domain == domain }
                .sorted {
                    ($0.aggregate.p95Meters, $0.aggregate.outlierRatio, $0.aggregate.sampleCount, -$0.x, -$0.y, -$0.z) >
                        ($1.aggregate.p95Meters, $1.aggregate.outlierRatio, $1.aggregate.sampleCount, -$1.x, -$1.y, -$1.z)
                }
                .prefix(configuration.maximumReportedCellsPerDomain)
        }

        let attribution: BenchmarkResidualAttribution = {
            guard let candidate = aggregatesByDomain[.candidateSurface],
                  let source = aggregatesByDomain[.admittedSourceDepth] ?? aggregatesByDomain[.sourceDepth] else {
                return .insufficientEvidence
            }
            if candidate.p95Meters <= configuration.surfaceThresholdMeters { return .candidateWithinThreshold }
            if source.p95Meters > configuration.surfaceThresholdMeters { return .sourceAndCandidateDisagreeWithReference }
            return .candidateDisagreesWithReference
        }()

        return BenchmarkResidualLocalizationReport(
            schemaVersion: BenchmarkResidualLocalizationReport.currentSchemaVersion,
            localizerVersion: BenchmarkResidualLocalizationReport.localizerVersion,
            identity: identity,
            configuration: configuration,
            referenceDistanceMode: referenceDistanceMode,
            reconstructionAdmissionConfiguration: reconstructionAdmissionConfiguration,
            global: aggregatesByDomain.map {
                BenchmarkResidualDomainAggregate(domain: $0.key, aggregate: $0.value)
            }.sorted { $0.domain.rawValue < $1.domain.rawValue },
            depthBands: depthBands.sorted {
                ($0.domain.rawValue, $0.lowerBoundMeters) < ($1.domain.rawValue, $1.lowerBoundMeters)
            },
            confidenceBands: confidenceBands,
            worstSpatialCells: worstCells,
            attribution: attribution,
            limitations: [
                "Threshold disagreements do not identify an earliest causal stage or prove fusion/extraction failure.",
                reconstructionAdmissionConfiguration == nil
                    ? "Admitted-source residuals are unavailable because no exact reconstruction report was supplied."
                    : "Admitted-source residuals apply the exact supplied reconstruction depth policy, pixel stride, and per-frame ray cap before bounded diagnostic sampling.",
                referenceDistanceMode == .nearestReferenceSample
                    ? "Residuals are nearest-sample distances, not continuous surface distances; reference density and common visible support are not qualified."
                    : "Candidate and source residuals use continuous declared triangle surfaces; common visible support remains unqualified.",
                "Source-depth residuals compare calibrated archived samples with the declared benchmark reference; they do not independently separate depth bias from trajectory or reference-frame error.",
                "Candidate depth bands use distance to the nearest retained camera, not exact per-vertex fusion lineage.",
                "Spatial cells localize error but do not prove causation. The next experiment must still change one factor only.",
                "Public replay does not qualify physical-device capture, thermal behavior, exports, competitors, or mining conclusions."
            ]
        )
    }

    private func aggregate(
        _ values: [Double],
        configuration: BenchmarkResidualLocalizationConfiguration
    ) -> BenchmarkResidualAggregate? {
        guard values.count >= configuration.minimumSamplesPerAggregate else { return nil }
        let sorted = values.sorted()
        return BenchmarkResidualAggregate(
            sampleCount: sorted.count,
            medianMeters: percentile(sorted, fraction: 0.50),
            p95Meters: percentile(sorted, fraction: 0.95),
            outlierRatio: Double(sorted.filter { $0 > configuration.surfaceThresholdMeters }.count) / Double(sorted.count)
        )
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        sorted[min(Int((Double(sorted.count - 1) * fraction).rounded()), sorted.count - 1)]
    }
}
