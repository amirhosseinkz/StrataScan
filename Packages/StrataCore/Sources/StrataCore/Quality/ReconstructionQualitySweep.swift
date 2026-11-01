import Foundation

public enum ReconstructionQualitySweepFactor: String, Codable, CaseIterable, Sendable {
    case minimumConsistentNeighborCount
    case absoluteNeighborToleranceMillimeters
    case preservesSparseObservations

    fileprivate func accepts(_ value: Int) -> Bool {
        switch self {
        case .minimumConsistentNeighborCount:
            return (2...8).contains(value)
        case .absoluteNeighborToleranceMillimeters:
            return (10...250).contains(value)
        case .preservesSparseObservations:
            return (0...1).contains(value)
        }
    }
}

public struct ReconstructionQualitySweepScene: Codable, Equatable, Sendable {
    public let sceneID: String
    public let scanID: UUID
    public let packageStoreRoot: String
    public let fixtureDirectory: String

    public init(sceneID: String, scanID: UUID, packageStoreRoot: String, fixtureDirectory: String) {
        self.sceneID = sceneID
        self.scanID = scanID
        self.packageStoreRoot = packageStoreRoot
        self.fixtureDirectory = fixtureDirectory
    }
}

public struct ReconstructionQualitySweepPlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumVariantCount = 5
    public static let maximumSceneCount = 10

    public let schemaVersion: Int
    public let campaignID: String
    public let factor: ReconstructionQualitySweepFactor
    public let baselineValue: Int
    public let values: [Int]
    public let buildCommit: String
    public let scenes: [ReconstructionQualitySweepScene]

    public init(
        schemaVersion: Int = ReconstructionQualitySweepPlan.currentSchemaVersion,
        campaignID: String,
        factor: ReconstructionQualitySweepFactor,
        baselineValue: Int,
        values: [Int],
        buildCommit: String,
        scenes: [ReconstructionQualitySweepScene]
    ) {
        self.schemaVersion = schemaVersion
        self.campaignID = campaignID
        self.factor = factor
        self.baselineValue = baselineValue
        self.values = values
        self.buildCommit = buildCommit
        self.scenes = scenes
    }

    public func validated() throws -> Self {
        let safeID = campaignID.range(
            of: #"^[a-z0-9][a-z0-9-]{0,63}$"#,
            options: .regularExpression
        ) != nil
        guard schemaVersion == Self.currentSchemaVersion,
              safeID,
              !buildCommit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (2...Self.maximumVariantCount).contains(values.count),
              Set(values).count == values.count,
              values.contains(baselineValue),
              values.allSatisfy(factor.accepts),
              (3...Self.maximumSceneCount).contains(scenes.count),
              Set(scenes.map(\.sceneID)).count == scenes.count,
              Set(scenes.map(\.scanID)).count == scenes.count,
              scenes.allSatisfy({
                  !$0.sceneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !$0.packageStoreRoot.isEmpty && !$0.fixtureDirectory.isEmpty
              })
        else {
            throw ReconstructionQualitySweepError.invalidPlan
        }
        return self
    }

    public func configuration(for value: Int) throws -> TSDFReconstructionConfiguration {
        guard values.contains(value) else { throw ReconstructionQualitySweepError.invalidPlan }
        var configuration = TSDFReconstructionConfiguration.productionBalanced
        switch factor {
        case .minimumConsistentNeighborCount:
            configuration.minimumConsistentNeighborCount = value
        case .absoluteNeighborToleranceMillimeters:
            configuration.absoluteNeighborToleranceMeters = Float(value) / 1_000
        case .preservesSparseObservations:
            configuration.preservesSparseObservations = value == 1
        }
        return configuration
    }
}

public struct ReconstructionQualitySweepMetrics: Codable, Equatable, Sendable {
    public let surfaceP95Meters: Double
    public let outlierRatio: Double
    public let observedCompleteness: Double
    public let disconnectedComponentRatio: Double
    public let maximumDimensionRelativeError: Double
    public let colorCoverage: Double
    public let outputIntegrityPassed: Bool

    public init(
        surfaceP95Meters: Double,
        outlierRatio: Double,
        observedCompleteness: Double,
        disconnectedComponentRatio: Double,
        maximumDimensionRelativeError: Double,
        colorCoverage: Double,
        outputIntegrityPassed: Bool
    ) {
        self.surfaceP95Meters = surfaceP95Meters
        self.outlierRatio = outlierRatio
        self.observedCompleteness = observedCompleteness
        self.disconnectedComponentRatio = disconnectedComponentRatio
        self.maximumDimensionRelativeError = maximumDimensionRelativeError
        self.colorCoverage = colorCoverage
        self.outputIntegrityPassed = outputIntegrityPassed
    }

    public init(scorecard: BenchmarkEvaluationScorecard) throws {
        func required(_ id: String) throws -> Double {
            guard let value = scorecard.metric(id)?.value, value.isFinite else {
                throw ReconstructionQualitySweepError.missingRequiredMetric(id)
            }
            return value
        }
        self.init(
            surfaceP95Meters: try required("surface-p95-distance"),
            outlierRatio: try required("outlier-ratio"),
            observedCompleteness: try required("observed-completeness"),
            disconnectedComponentRatio: try required("disconnected-component-ratio"),
            maximumDimensionRelativeError: try required("maximum-dimension-relative-error"),
            colorCoverage: try required("color-coverage"),
            outputIntegrityPassed: scorecard.metric("output-integrity")?.disposition == .passed
        )
    }
}

public struct ReconstructionQualitySweepSceneResult: Codable, Equatable, Sendable {
    public let sceneID: String
    public let scanID: UUID
    public let candidateGeometrySHA256: String
    public let promotedVertexCount: Int
    public let promotedTriangleCount: Int
    public let metrics: ReconstructionQualitySweepMetrics

    public init(
        sceneID: String,
        scanID: UUID,
        candidateGeometrySHA256: String,
        promotedVertexCount: Int,
        promotedTriangleCount: Int,
        metrics: ReconstructionQualitySweepMetrics
    ) {
        self.sceneID = sceneID
        self.scanID = scanID
        self.candidateGeometrySHA256 = candidateGeometrySHA256
        self.promotedVertexCount = promotedVertexCount
        self.promotedTriangleCount = promotedTriangleCount
        self.metrics = metrics
    }
}

public struct ReconstructionQualitySweepVariantResult: Codable, Equatable, Sendable {
    public let value: Int
    public let configurationSHA256: String
    public let scenes: [ReconstructionQualitySweepSceneResult]

    public init(value: Int, configurationSHA256: String, scenes: [ReconstructionQualitySweepSceneResult]) {
        self.value = value
        self.configurationSHA256 = configurationSHA256
        self.scenes = scenes
    }
}

public enum ReconstructionQualitySweepRejection: String, Codable, Equatable, Sendable {
    case baseline
    case sceneSetMismatch
    case integrityFailure
    case primaryMetricRegression
    case completenessRegression
    case topologyRegression
    case dimensionRegression
    case colorRegression
    case noAggregateImprovement
}

public struct ReconstructionQualitySweepDisposition: Codable, Equatable, Sendable {
    public let value: Int
    public let eligible: Bool
    public let normalizedObjective: Double?
    public let rejection: ReconstructionQualitySweepRejection?

    public init(
        value: Int,
        eligible: Bool,
        normalizedObjective: Double?,
        rejection: ReconstructionQualitySweepRejection?
    ) {
        self.value = value
        self.eligible = eligible
        self.normalizedObjective = normalizedObjective
        self.rejection = rejection
    }
}

public struct ReconstructionQualitySweepReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let runnerVersion = "R0.5-one-factor-sweep-v1"

    public let schemaVersion: Int
    public let runnerVersion: String
    public let campaignID: String
    public let factor: ReconstructionQualitySweepFactor
    public let baselineValue: Int
    public let variants: [ReconstructionQualitySweepVariantResult]
    public let dispositions: [ReconstructionQualitySweepDisposition]
    public let recommendedValue: Int?
    public let productionDefaultChanged: Bool
    public let limitations: [String]

    public func stableJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum ReconstructionQualitySweepError: Error, Equatable, Sendable {
    case invalidPlan
    case missingBaseline
    case duplicateVariant
    case missingRequiredMetric(String)
}

public struct ReconstructionQualitySweepAnalyzer: Sendable {
    public static let maximumCompletenessRegression = 0.02
    public static let maximumDimensionRegression = 0.01
    public static let maximumColorRegression = 0.01
    private static let epsilon = 0.000_000_001

    public init() {}

    public func analyze(
        plan: ReconstructionQualitySweepPlan,
        variants: [ReconstructionQualitySweepVariantResult]
    ) throws -> ReconstructionQualitySweepReport {
        let plan = try plan.validated()
        guard Set(variants.map(\.value)).count == variants.count else {
            throw ReconstructionQualitySweepError.duplicateVariant
        }
        guard variants.count == plan.values.count,
              Set(variants.map(\.value)) == Set(plan.values)
        else {
            throw ReconstructionQualitySweepError.invalidPlan
        }
        guard let baseline = variants.first(where: { $0.value == plan.baselineValue }) else {
            throw ReconstructionQualitySweepError.missingBaseline
        }
        guard Set(baseline.scenes.map(\.sceneID)).count == baseline.scenes.count else {
            throw ReconstructionQualitySweepError.invalidPlan
        }
        let baselineScenes = Dictionary(uniqueKeysWithValues: baseline.scenes.map { ($0.sceneID, $0) })
        let plannedScenes = Dictionary(uniqueKeysWithValues: plan.scenes.map { ($0.sceneID, $0) })
        guard baselineScenes.count == plan.scenes.count,
              Set(baselineScenes.keys) == Set(plannedScenes.keys),
              baselineScenes.allSatisfy({ plannedScenes[$0.key]?.scanID == $0.value.scanID })
        else {
            throw ReconstructionQualitySweepError.invalidPlan
        }

        var dispositions: [ReconstructionQualitySweepDisposition] = []
        for variant in variants.sorted(by: { $0.value < $1.value }) {
            if variant.value == plan.baselineValue {
                dispositions.append(.init(value: variant.value, eligible: false, normalizedObjective: nil, rejection: .baseline))
                continue
            }
            guard Set(variant.scenes.map(\.sceneID)).count == variant.scenes.count else {
                dispositions.append(.init(value: variant.value, eligible: false, normalizedObjective: nil, rejection: .sceneSetMismatch))
                continue
            }
            let candidateScenes = Dictionary(uniqueKeysWithValues: variant.scenes.map { ($0.sceneID, $0) })
            guard candidateScenes.count == baselineScenes.count,
                  Set(candidateScenes.keys) == Set(baselineScenes.keys),
                  candidateScenes.allSatisfy({ plannedScenes[$0.key]?.scanID == $0.value.scanID })
            else {
                dispositions.append(.init(value: variant.value, eligible: false, normalizedObjective: nil, rejection: .sceneSetMismatch))
                continue
            }
            let pairs = baselineScenes.keys.sorted().compactMap { id -> (ReconstructionQualitySweepMetrics, ReconstructionQualitySweepMetrics)? in
                guard let before = baselineScenes[id]?.metrics, let after = candidateScenes[id]?.metrics else { return nil }
                return (before, after)
            }
            let rejection: ReconstructionQualitySweepRejection?
            if pairs.contains(where: { !$0.1.outputIntegrityPassed }) {
                rejection = .integrityFailure
            } else if pairs.contains(where: {
                $0.1.surfaceP95Meters > $0.0.surfaceP95Meters + Self.epsilon ||
                    $0.1.outlierRatio > $0.0.outlierRatio + Self.epsilon
            }) {
                rejection = .primaryMetricRegression
            } else if pairs.contains(where: { $0.1.observedCompleteness < $0.0.observedCompleteness - Self.maximumCompletenessRegression }) {
                rejection = .completenessRegression
            } else if pairs.contains(where: { $0.1.disconnectedComponentRatio > $0.0.disconnectedComponentRatio + Self.epsilon }) {
                rejection = .topologyRegression
            } else if pairs.contains(where: { $0.1.maximumDimensionRelativeError > $0.0.maximumDimensionRelativeError + Self.maximumDimensionRegression }) {
                rejection = .dimensionRegression
            } else if pairs.contains(where: { $0.1.colorCoverage < $0.0.colorCoverage - Self.maximumColorRegression }) {
                rejection = .colorRegression
            } else {
                let p95Ratio = pairs.reduce(0.0) { $0 + $1.1.surfaceP95Meters / $1.0.surfaceP95Meters } / Double(pairs.count)
                let outlierRatio = pairs.reduce(0.0) { $0 + $1.1.outlierRatio / $1.0.outlierRatio } / Double(pairs.count)
                let objective = (p95Ratio + outlierRatio) / 2
                rejection = objective < 1 - Self.epsilon ? nil : .noAggregateImprovement
                dispositions.append(.init(
                    value: variant.value,
                    eligible: rejection == nil,
                    normalizedObjective: objective,
                    rejection: rejection
                ))
                continue
            }
            dispositions.append(.init(value: variant.value, eligible: false, normalizedObjective: nil, rejection: rejection))
        }
        let recommended = dispositions
            .filter(\.eligible)
            .sorted {
                let lhs = $0.normalizedObjective ?? .infinity
                let rhs = $1.normalizedObjective ?? .infinity
                return lhs == rhs ? $0.value < $1.value : lhs < rhs
            }
            .first?.value
        return ReconstructionQualitySweepReport(
            schemaVersion: ReconstructionQualitySweepReport.currentSchemaVersion,
            runnerVersion: ReconstructionQualitySweepReport.runnerVersion,
            campaignID: plan.campaignID,
            factor: plan.factor,
            baselineValue: plan.baselineValue,
            variants: variants.sorted(by: { $0.value < $1.value }),
            dispositions: dispositions,
            recommendedValue: recommended,
            productionDefaultChanged: false,
            limitations: [
                "A recommendation is evidence for this frozen public campaign only and does not change the production default.",
                "Only the declared factor may vary; references, thresholds, inputs, extraction, viewer, and exports remain frozen.",
                "Public replay does not qualify physical-device capture, trajectory drift, thermal behavior, or competitors."
            ]
        )
    }
}
