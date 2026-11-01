import ARKit
import Darwin
import Foundation
import ImageIO
import Observation
import StrataCore
import UIKit

enum AccessibilityID {
    static let libraryTabContent = "tab.library.content"
    static let settingsTabContent = "tab.settings.content"
    static let libraryLoading = "library.loading"
    static let libraryEmpty = "library.empty"
    static let libraryError = "library.error"
    static let libraryList = "library.list"
    static let libraryNewScan = "library.newScan"
    static let libraryOpenScanner = "library.openScanner"
    static let libraryRetry = "library.retry"
    static let scanDetailLoading = "scanDetail.loading"
    static let scanDetailError = "scanDetail.error"
    static let scanDetailContent = "scanDetail.content"
    static let scanDetailMesh = "scanDetail.mesh"
    static let scanDetailProcessedSurface = "scanDetail.processedSurface"
    static let scanDetailSurfacePicker = "scanDetail.surfacePicker"
    static let scanDetailProcessedStatus = "scanDetail.processedStatus"
    static let scanDetailReconstructionRetry = "scanDetail.reconstruction.retry"
    static let scanDetailResetView = "scanDetail.resetView"
    static let scanDetailMeshError = "scanDetail.mesh.error"
    static let scanDetailNoGeometry = "scanDetail.mesh.empty"
    static let scanDetailShare = "scanDetail.share"
    static let scanDetailDelete = "scanDetail.delete"
    static let scanDetailRetry = "scanDetail.retry"
    static let scannerWorkflow = "scanner.workflow"
    static let scannerClose = "scanner.close"
    static let scannerChecking = "scanner.checking"
    static let scannerUnavailable = "scanner.unavailable"
    static let scannerPermission = "scanner.permission"
    static let scannerReady = "scanner.ready"
    static let scannerScanning = "scanner.scanning"
    static let scannerCoverage = "scanner.coverage"
    static let scannerProcessing = "scanner.processing"
    static let scannerSaving = "scanner.saving"
    static let scannerCompleted = "scanner.completed"
    static let scannerReview = "scanner.review"
    static let scannerReviewSave = "scanner.review.save"
    static let scannerReviewName = "scanner.review.name"
    static let scannerError = "scanner.error"
    static let scannerRetry = "scanner.retry"
    static let scannerCaptureMode = "scanner.captureMode"
    static let settingsRoot = "settings.root"
    static let settingsLocalOnly = "settings.localOnly"

    static func libraryScanRow(_ id: UUID) -> String {
        "library.scan.\(id.uuidString)"
    }

    static func scanDetailAsset(_ id: UUID) -> String {
        "scanDetail.asset.\(id.uuidString)"
    }
}

enum AppTab: Hashable {
    case library
    case settings
}

enum AppRoute: Identifiable {
    case scanner

    var id: String {
        "scanner"
    }
}

@MainActor
@Observable
final class AppShellModel {
    var selectedTab: AppTab = .library
    var presentedRoute: AppRoute?
    var requestedWorkspaceScanID: UUID?

    let library: LibraryViewModel
    let detailService: any ScanDetailServing
    let comparisonDraftService: any ScanComparisonDraftServing
    let scanner: ScannerWorkflowModel
    let settings: SettingsViewState
    let reconstructionCoordinator: (any AppReconstructionCoordinating)?

    init(
        library: LibraryViewModel,
        detailService: any ScanDetailServing,
        comparisonDraftService: any ScanComparisonDraftServing,
        scanner: ScannerWorkflowModel,
        settings: SettingsViewState,
        reconstructionCoordinator: (any AppReconstructionCoordinating)? = nil
    ) {
        self.library = library
        self.detailService = detailService
        self.comparisonDraftService = comparisonDraftService
        self.scanner = scanner
        self.settings = settings
        self.reconstructionCoordinator = reconstructionCoordinator
    }
}

struct AppComposition {
    let libraryService: any ScanLibraryServing
    let detailService: any ScanDetailServing
    let comparisonDraftService: any ScanComparisonDraftServing
    let scannerService: any ScannerWorkflowServing
    let settingsService: any SettingsProviding
    let isDemo: Bool
    let rawPreviewSession: ARSession?
    let semanticPreviewView: UIView?
    let reconstructionCoordinator: (any AppReconstructionCoordinating)?

    @MainActor
    static func make(arguments: [String], dataRootURL: URL? = nil) -> AppComposition {
        guard !isUITesting(arguments: arguments) else {
            return demo(arguments: arguments)
        }

        do {
            return try local(dataRootURL: dataRootURL)
        } catch {
            return AppComposition(
                libraryService: LocalStartupFailureLibraryService(),
                detailService: LocalStartupFailureScanDetailService(),
                comparisonDraftService: LocalStartupFailureScanComparisonDraftService(),
                scannerService: LocalStartupFailureScannerService(),
                settingsService: LocalSettingsService(storageAvailable: false),
                isDemo: false,
                rawPreviewSession: nil,
                semanticPreviewView: nil,
                reconstructionCoordinator: nil
            )
        }
    }

    @MainActor
    static func local(dataRootURL: URL? = nil) throws -> AppComposition {
        let rootURL: URL
        if let dataRootURL {
            rootURL = dataRootURL
        } else {
            let applicationSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            rootURL = applicationSupportURL.appending(path: "StrataScan", directoryHint: .isDirectory)
        }

        let assetStore = try FileAssetStore(
            rootURL: rootURL.appending(path: "scan-packages", directoryHint: .isDirectory)
        )
        let metadataStore = try SQLiteMetadataStore(
            databaseURL: rootURL.appending(path: "scan-metadata.sqlite")
        )
        let repository = LocalScanRepository(metadataStore: metadataStore, assetStore: assetStore)
        let processedSurfaceStore = try ProcessedSurfaceStore(
            rootURL: rootURL.appending(path: "derived", directoryHint: .isDirectory),
            processingRootURL: rootURL.appending(path: "processing-work", directoryHint: .isDirectory)
        )
        let processingRootURL = rootURL.appending(path: "processing-work", directoryHint: .isDirectory)
        let derivedRootURL = rootURL.appending(path: "derived", directoryHint: .isDirectory)
        let reconstructionRunner = LocalScanReconstructionRunner(
            repository: repository,
            assetStore: assetStore,
            processedSurfaceStore: processedSurfaceStore,
            processingRootURL: processingRootURL,
            derivedRootURL: derivedRootURL,
            extractionConfiguration: .productionEvidenceQualified
        )
        let reconstructionCoordinator = try ScanReconstructionCoordinator(
            runner: reconstructionRunner,
            resourceMonitor: SystemScanReconstructionResourceMonitor(volumeURL: rootURL),
            processingRootURL: processingRootURL
        )
        let captureAdapter = ARKitCaptureAdapter(
            assetRootURL: rootURL,
            locationAuthorizationProvider: SystemLocationPermissionProvider()
        )
        let semanticCaptureAdapter = RoomPlanCaptureAdapter()

        return AppComposition(
            libraryService: LocalScanLibraryService(repository: repository, assetStore: assetStore),
            detailService: LocalScanDetailService(
                repository: repository,
                assetStore: assetStore,
                processedSurfaceStore: processedSurfaceStore,
                reconstructionCoordinator: reconstructionCoordinator
            ),
            comparisonDraftService: LocalScanComparisonDraftService(repository: repository, assetStore: assetStore),
            scannerService: LocalScannerWorkflowService(
                repository: repository,
                assetStore: assetStore,
                captureWorkingRootURL: rootURL.appending(path: "capture-work", directoryHint: .isDirectory),
                captureAdapter: captureAdapter,
                semanticCaptureAdapter: semanticCaptureAdapter,
                reconstructionCoordinator: reconstructionCoordinator
            ),
            settingsService: LocalSettingsService(storageAvailable: true),
            isDemo: false,
            rawPreviewSession: captureAdapter.session,
            semanticPreviewView: semanticCaptureAdapter.captureView,
            reconstructionCoordinator: reconstructionCoordinator
        )
    }

    static func demo(arguments: [String]) -> AppComposition {
        let libraryScenario = DemoLibraryScenario(
            rawValue: argumentValue(after: "-uiTestingLibraryState", in: arguments) ?? ""
        ) ?? .content
        let scannerScenario = DemoScannerScenario(
            rawValue: argumentValue(after: "-uiTestingScannerState", in: arguments) ?? ""
        ) ?? .unavailable

        return AppComposition(
            libraryService: DemoScanLibraryService(scenario: libraryScenario),
            detailService: DemoScanDetailService(),
            comparisonDraftService: DemoScanComparisonDraftService(),
            scannerService: DemoScannerWorkflowService(scenario: scannerScenario),
            settingsService: DemoSettingsService(),
            isDemo: true,
            rawPreviewSession: nil,
            semanticPreviewView: nil,
            reconstructionCoordinator: nil
        )
    }

    static func isUITesting(arguments: [String]) -> Bool {
        arguments.contains("-uiTesting")
            || arguments.contains("-uiTestingLibraryState")
            || arguments.contains("-uiTestingScannerState")
    }

    private static func argumentValue(after option: String, in arguments: [String]) -> String? {
        guard let optionIndex = arguments.firstIndex(of: option) else {
            return nil
        }

        let valueIndex = arguments.index(after: optionIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        return arguments[valueIndex]
    }
}

protocol ScanLibraryServing: Sendable {
    func loadLibrary() async -> LibraryLoadResult
}

enum LibraryLoadResult: Equatable, Sendable {
    case success([ScanLibraryItem])
    case failure(LibraryFailureState)
}

struct LibraryFailureState: Equatable, Sendable {
    let title: String
    let message: String
}

protocol ScanComparisonDraftServing: Sendable {
    func saveDraft(baselineScanID: UUID, comparisonScanID: UUID) async -> ScanComparisonDraftSaveResult
    func loadLatestDraft() async -> ScanComparisonDraftLoadResult
    func saveWorkArea(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaSaveResult
    func loadWorkArea(forDraftID draftID: UUID) async -> ScanComparisonWorkAreaLoadResult
    func loadWorkAreaWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaWorkspaceLoadResult
    func saveRefinedWorkArea(
        for draft: ScanComparisonDraft,
        firstCorner: Point3D,
        oppositeCorner: Point3D
    ) async -> ScanComparisonWorkAreaSaveResult
    func loadAlignmentWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonAlignmentWorkspaceLoadResult
    func saveLandmarkAlignment(
        for draft: ScanComparisonDraft,
        baselineLandmarks: [Point3D],
        comparisonLandmarks: [Point3D]
    ) async -> ScanComparisonAlignmentSaveResult
    func evaluateCoverage(for draft: ScanComparisonDraft) async -> ScanComparisonCoverageEvaluationResult
    func loadReadiness(for draft: ScanComparisonDraft) async -> ScanComparisonReadiness
    func loadVisualComparisonWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonVisualWorkspaceLoadResult
    func loadSurfaceDifferencePreview(for draft: ScanComparisonDraft) async -> ScanComparisonSurfaceDifferenceWorkspaceLoadResult
}

enum ScanComparisonDraftSaveResult: Equatable, Sendable {
    case success(ScanComparisonDraft)
    case failure(ScanComparisonDraftFailureState)
}

enum ScanComparisonDraftLoadResult: Equatable, Sendable {
    case success(ScanComparisonDraft?)
    case failure(ScanComparisonDraftFailureState)
}

struct ScanComparisonDraftFailureState: Equatable, Sendable {
    let title: String
    let message: String
}

enum ScanComparisonWorkAreaSaveResult: Equatable, Sendable {
    case success(ScanComparisonWorkArea)
    case failure(ScanComparisonDraftFailureState)
}

enum ScanComparisonWorkAreaLoadResult: Equatable, Sendable {
    case success(ScanComparisonWorkArea?)
    case failure(ScanComparisonDraftFailureState)
}

/// Rendering-ready baseline mesh for defining a finite comparison work area.
/// The view may choose points from it but never mutates the source mesh.
struct ScanComparisonWorkAreaWorkspace: Equatable, Sendable {
    let baselineSnapshots: [MeshSnapshot]
    let savedWorkArea: ScanComparisonWorkArea?
}

enum ScanComparisonWorkAreaWorkspaceLoadResult: Equatable, Sendable {
    case success(ScanComparisonWorkAreaWorkspace)
    case failure(ScanComparisonDraftFailureState)
}

/// Rendering-ready immutable meshes for a deliberate landmark alignment.
/// `baseline` is always the target coordinate system of the saved transform.
struct ScanComparisonAlignmentWorkspace: Equatable, Sendable {
    let baselineSnapshots: [MeshSnapshot]
    let comparisonSnapshots: [MeshSnapshot]
    let savedLandmarks: ScanAlignmentLandmarkSet?
}

enum ScanComparisonAlignmentWorkspaceLoadResult: Equatable, Sendable {
    case success(ScanComparisonAlignmentWorkspace)
    case failure(ScanComparisonDraftFailureState)
}

enum ScanComparisonAlignmentSaveResult: Equatable, Sendable {
    case success(ScanAlignmentLandmarkSet)
    case failure(ScanComparisonDraftFailureState)
}

enum ScanComparisonCoverageEvaluationResult: Equatable, Sendable {
    case checking
    case available(ScanComparisonCoverageReport)
    case needsWorkArea
    case needsAlignment
    case failure(ScanComparisonDraftFailureState)
}

/// An on-demand, non-persistent check that reports whether surface-difference
/// preview can be opened without exposing internal registration metrics.
enum ScanComparisonReadiness: Equatable, Sendable {
    case checking
    case ready
    case needsWorkArea
    case needsAlignment
    case alignmentNeedsImprovement(ScanComparisonAlignmentQualityReport.Status)
    case needsCoverage
    case needsComparableSurfaces
    case failure(ScanComparisonDraftFailureState)
}

/// Read-only geometry prepared in the baseline frame for visual alignment
/// inspection. It contains no surface-difference or quantity result.
struct ScanComparisonVisualWorkspace: Equatable, Sendable {
    let baselineSnapshots: [MeshSnapshot]
    let alignedComparisonSnapshots: [MeshSnapshot]
    let workArea: ScanComparisonWorkArea
}

enum ScanComparisonVisualWorkspaceLoadResult: Equatable, Sendable {
    case success(ScanComparisonVisualWorkspace)
    case failure(ScanComparisonDraftFailureState)
}

/// Read-only, locally supported surface observations for visual inspection.
/// This does not contain a volume, material, or calculated change record.
struct ScanComparisonSurfaceDifferenceWorkspace: Equatable, Sendable {
    let baselineContextSnapshots: [MeshSnapshot]
    let alignedComparisonContextSnapshots: [MeshSnapshot]
    let preview: ScanComparisonSurfaceDifferencePreview
    let workArea: ScanComparisonWorkArea
}

enum ScanComparisonSurfaceDifferenceWorkspaceLoadResult: Equatable, Sendable {
    case success(ScanComparisonSurfaceDifferenceWorkspace)
    case failure(ScanComparisonDraftFailureState)
}

actor LocalScanComparisonDraftService: ScanComparisonDraftServing {
    private let repository: LocalScanRepository
    private let assetStore: FileAssetStore

    init(repository: LocalScanRepository, assetStore: FileAssetStore) {
        self.repository = repository
        self.assetStore = assetStore
    }

    func saveDraft(baselineScanID: UUID, comparisonScanID: UUID) async -> ScanComparisonDraftSaveResult {
        let draft = ScanComparisonDraft(
            baselineScanID: baselineScanID,
            comparisonScanID: comparisonScanID
        )
        do {
            try await repository.save(scanComparisonDraft: draft)
            return .success(draft)
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not save comparison",
                    message: "Both scans must exist in the library to create a comparison."
                )
            )
        }
    }

    func loadLatestDraft() async -> ScanComparisonDraftLoadResult {
        do {
            return .success(try await repository.latestScanComparisonDraft())
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not load comparison",
                    message: "The saved comparison draft is unreadable."
                )
            )
        }
    }

    func saveWorkArea(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaSaveResult {
        do {
            guard let storedScan = try await repository.reopen(id: draft.baselineScanID), storedScan.integrity.isValid else {
                throw ScanComparisonWorkAreaError.emptyGeometry
            }
            guard let meshAsset = storedScan.manifest.assets.first(where: { $0.kind == .meshRaw }) else {
                throw ScanComparisonWorkAreaError.emptyGeometry
            }
            let packageURL = try await assetStore.packageURL(for: draft.baselineScanID)
            let snapshots = try Self.validatedSnapshots(
                from: Data(contentsOf: packageURL.appending(path: meshAsset.relativePath))
            )
            let workArea = try ScanComparisonWorkArea.fromBaselineMesh(
                draftID: draft.id,
                referenceScanID: draft.baselineScanID,
                snapshots: snapshots
            )
            try await repository.save(scanComparisonWorkArea: workArea)
            return .success(workArea)
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not set work area",
                    message: "The before scan needs a valid 3D mesh with sufficient extent to define a work area."
                )
            )
        }
    }

    func loadWorkArea(forDraftID draftID: UUID) async -> ScanComparisonWorkAreaLoadResult {
        do {
            return .success(try await repository.scanComparisonWorkArea(forDraftID: draftID))
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not load work area",
                    message: "The saved comparison work area is unreadable."
                )
            )
        }
    }

    func loadWorkAreaWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaWorkspaceLoadResult {
        do {
            async let snapshots = Self.rawMeshSnapshots(
                scanID: draft.baselineScanID,
                repository: repository,
                assetStore: assetStore
            )
            let savedWorkArea = try await repository.scanComparisonWorkArea(forDraftID: draft.id)
            return .success(
                ScanComparisonWorkAreaWorkspace(
                    baselineSnapshots: try await snapshots,
                    savedWorkArea: savedWorkArea
                )
            )
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not open work area",
                    message: "The before scan needs a valid, complete 3D mesh to refine the work area."
                )
            )
        }
    }

    func saveRefinedWorkArea(
        for draft: ScanComparisonDraft,
        firstCorner: Point3D,
        oppositeCorner: Point3D
    ) async -> ScanComparisonWorkAreaSaveResult {
        do {
            let existing = try await repository.scanComparisonWorkArea(forDraftID: draft.id)
            let now = Date.now
            let workArea = try ScanComparisonWorkArea.fromOppositeCorners(
                id: existing?.id ?? UUID(),
                draftID: draft.id,
                referenceScanID: draft.baselineScanID,
                first: firstCorner,
                second: oppositeCorner,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            )
            try await repository.save(scanComparisonWorkArea: workArea)
            return .success(workArea)
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not save work area",
                    message: "Choose two distinct, opposite corners on the before scan mesh."
                )
            )
        }
    }

    func loadAlignmentWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonAlignmentWorkspaceLoadResult {
        do {
            async let baselineSnapshots = Self.rawMeshSnapshots(
                scanID: draft.baselineScanID,
                repository: repository,
                assetStore: assetStore
            )
            async let comparisonSnapshots = Self.rawMeshSnapshots(
                scanID: draft.comparisonScanID,
                repository: repository,
                assetStore: assetStore
            )
            let savedLandmarks = try await repository.scanAlignmentLandmarks(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID
            )
            return .success(
                ScanComparisonAlignmentWorkspace(
                    baselineSnapshots: try await baselineSnapshots,
                    comparisonSnapshots: try await comparisonSnapshots,
                    savedLandmarks: savedLandmarks
                )
            )
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not open alignment",
                    message: "Both scans need valid, complete 3D meshes."
                )
            )
        }
    }

    func saveLandmarkAlignment(
        for draft: ScanComparisonDraft,
        baselineLandmarks: [Point3D],
        comparisonLandmarks: [Point3D]
    ) async -> ScanComparisonAlignmentSaveResult {
        do {
            let estimate = try LandmarkAlignmentEngine().estimate(
                source: comparisonLandmarks,
                target: baselineLandmarks
            )
            let now = Date.now
            let alignment = ScanAlignment(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID,
                targetFromSource: estimate.targetFromSource,
                method: .landmarks,
                createdAt: now,
                updatedAt: now
            )
            let landmarks = ScanAlignmentLandmarkSet(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID,
                targetLandmarks: baselineLandmarks,
                sourceLandmarks: comparisonLandmarks,
                rmsErrorMeters: estimate.rmsError,
                createdAt: now,
                updatedAt: now
            )
            try await repository.save(scanAlignment: alignment, landmarks: landmarks)
            return .success(landmarks)
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not save alignment",
                    message: "Choose three distinct, matching landmarks in both scans."
                )
            )
        }
    }

    func evaluateCoverage(for draft: ScanComparisonDraft) async -> ScanComparisonCoverageEvaluationResult {
        do {
            guard let workArea = try await repository.scanComparisonWorkArea(forDraftID: draft.id) else {
                return .needsWorkArea
            }
            guard let alignment = try await repository.scanAlignment(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID
            ) else {
                return .needsAlignment
            }
            let comparisonSnapshots = try await Self.rawMeshSnapshots(
                scanID: draft.comparisonScanID,
                repository: repository,
                assetStore: assetStore
            )
            let report = try ScanComparisonWorkAreaCoverageEvaluator().evaluate(
                workArea: workArea,
                alignment: alignment,
                comparisonSnapshots: comparisonSnapshots
            )
            return .available(report)
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not check coverage",
                    message: "The after scan mesh must be valid and readable to check coverage."
                )
            )
        }
    }

    func loadReadiness(for draft: ScanComparisonDraft) async -> ScanComparisonReadiness {
        do {
            guard let workArea = try await repository.scanComparisonWorkArea(forDraftID: draft.id) else {
                return .needsWorkArea
            }
            guard let alignment = try await repository.scanAlignment(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID
            ) else {
                return .needsAlignment
            }
            guard let landmarks = try await repository.scanAlignmentLandmarks(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID
            ) else {
                return .needsAlignment
            }
            let alignmentQuality = try ScanComparisonAlignmentQualityEvaluator().evaluate(
                landmarks: landmarks,
                alignment: alignment,
                workArea: workArea
            )
            guard alignmentQuality.status == .supported else {
                return .alignmentNeedsImprovement(alignmentQuality.status)
            }
            async let baselineSnapshots = Self.rawMeshSnapshots(
                scanID: draft.baselineScanID,
                repository: repository,
                assetStore: assetStore
            )
            async let comparisonSnapshots = Self.rawMeshSnapshots(
                scanID: draft.comparisonScanID,
                repository: repository,
                assetStore: assetStore
            )
            let baseline = try await baselineSnapshots
            let comparison = try await comparisonSnapshots
            let coverage = try ScanComparisonWorkAreaCoverageEvaluator().evaluate(
                workArea: workArea,
                alignment: alignment,
                comparisonSnapshots: comparison
            )
            guard coverage.status == .supported else {
                return .needsCoverage
            }
            let preview = try ScanComparisonSurfaceDifferenceEvaluator().evaluate(
                baselineSnapshots: baseline,
                comparisonSnapshots: comparison,
                workArea: workArea,
                targetFromSource: alignment.targetFromSource
            )
            return preview.observations.isEmpty ? .needsComparableSurfaces : .ready
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not check readiness",
                    message: "The alignment and both scan meshes must be valid and readable to check readiness."
                )
            )
        }
    }

    func loadVisualComparisonWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonVisualWorkspaceLoadResult {
        do {
            guard let workArea = try await repository.scanComparisonWorkArea(forDraftID: draft.id) else {
                throw ScanComparisonWorkAreaError.emptyGeometry
            }
            guard let alignment = try await repository.scanAlignment(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID
            ) else {
                throw AlignmentError.invalidTransform
            }
            async let baselineSnapshots = Self.rawMeshSnapshots(
                scanID: draft.baselineScanID,
                repository: repository,
                assetStore: assetStore
            )
            async let comparisonSnapshots = Self.rawMeshSnapshots(
                scanID: draft.comparisonScanID,
                repository: repository,
                assetStore: assetStore
            )
            let clipper = ScanComparisonWorkAreaMeshClipper()
            let baseline = try clipper.clip(snapshots: await baselineSnapshots, to: workArea)
            let comparison = try clipper.clip(
                snapshots: await comparisonSnapshots,
                to: workArea,
                applying: alignment.targetFromSource
            )
            guard !baseline.isEmpty, !comparison.isEmpty else {
                throw ScanComparisonCoverageError.invalidComparisonGeometry
            }
            return .success(
                ScanComparisonVisualWorkspace(
                    baselineSnapshots: baseline,
                    alignedComparisonSnapshots: comparison,
                    workArea: workArea
                )
            )
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not review alignment",
                    message: "The work area, alignment, and both meshes must be valid and share observed geometry."
                )
            )
        }
    }

    func loadSurfaceDifferencePreview(for draft: ScanComparisonDraft) async -> ScanComparisonSurfaceDifferenceWorkspaceLoadResult {
        do {
            guard let workArea = try await repository.scanComparisonWorkArea(forDraftID: draft.id) else {
                throw ScanComparisonWorkAreaError.emptyGeometry
            }
            guard let alignment = try await repository.scanAlignment(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID
            ) else {
                throw AlignmentError.invalidTransform
            }
            guard let landmarks = try await repository.scanAlignmentLandmarks(
                targetScanID: draft.baselineScanID,
                sourceScanID: draft.comparisonScanID
            ) else {
                return .failure(
                    ScanComparisonDraftFailureState(
                        title: "Insufficient alignment for preview",
                        message: "Save alignment with at least three shared, stable landmarks to preview differences."
                    )
                )
            }
            let alignmentQuality = try ScanComparisonAlignmentQualityEvaluator().evaluate(
                landmarks: landmarks,
                alignment: alignment,
                workArea: workArea
            )
            guard alignmentQuality.status == .supported else {
                return .failure(alignmentQualityFailure(for: alignmentQuality.status))
            }
            async let baselineSnapshots = Self.rawMeshSnapshots(
                scanID: draft.baselineScanID,
                repository: repository,
                assetStore: assetStore
            )
            async let comparisonSnapshots = Self.rawMeshSnapshots(
                scanID: draft.comparisonScanID,
                repository: repository,
                assetStore: assetStore
            )
            let baseline = try await baselineSnapshots
            let comparison = try await comparisonSnapshots
            let coverage = try ScanComparisonWorkAreaCoverageEvaluator().evaluate(
                workArea: workArea,
                alignment: alignment,
                comparisonSnapshots: comparison
            )
            guard coverage.status == .supported else {
                throw ScanComparisonCoverageError.invalidComparisonGeometry
            }
            let preview = try ScanComparisonSurfaceDifferenceEvaluator().evaluate(
                baselineSnapshots: baseline,
                comparisonSnapshots: comparison,
                workArea: workArea,
                targetFromSource: alignment.targetFromSource
            )
            guard !preview.observations.isEmpty else {
                throw ScanComparisonCoverageError.invalidComparisonGeometry
            }
            let clipper = ScanComparisonWorkAreaMeshClipper()
            let baselineContext = try clipper.clip(
                snapshots: baseline,
                to: workArea
            )
            let alignedComparisonContext = try clipper.clip(
                snapshots: comparison,
                to: workArea,
                applying: alignment.targetFromSource
            )
            return .success(
                ScanComparisonSurfaceDifferenceWorkspace(
                    baselineContextSnapshots: baselineContext,
                    alignedComparisonContextSnapshots: alignedComparisonContext,
                    preview: preview,
                    workArea: workArea
                )
            )
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not preview differences",
                    message: "The work area needs sufficient coverage and both meshes need nearby, comparable surfaces."
                )
            )
        }
    }

    private func alignmentQualityFailure(
        for status: ScanComparisonAlignmentQualityReport.Status
    ) -> ScanComparisonDraftFailureState {
        switch status {
        case .supported:
            ScanComparisonDraftFailureState(
                title: "Could not preview differences",
                message: "The selected alignment cannot be used for this preview."
            )
        case .landmarkSpreadInsufficient:
            ScanComparisonDraftFailureState(
                title: "Alignment landmarks are too clustered",
                message: "Choose stable landmarks farther apart in both scans, then save alignment again."
            )
        case .landmarkDistributionDegenerate:
            ScanComparisonDraftFailureState(
                title: "Alignment landmarks have a weak arrangement",
                message: "Choose landmarks that do not lie approximately on one line, then save alignment again."
            )
        case .residualTooHigh:
            ScanComparisonDraftFailureState(
                title: "Alignment error is too high for preview",
                message: "Select shared, stable landmarks again to improve alignment."
            )
        }
    }

    private static func rawMeshSnapshots(
        scanID: UUID,
        repository: LocalScanRepository,
        assetStore: FileAssetStore
    ) async throws -> [MeshSnapshot] {
        guard let storedScan = try await repository.reopen(id: scanID), storedScan.integrity.isValid else {
            throw ScanComparisonWorkAreaError.emptyGeometry
        }
        guard let meshAsset = storedScan.manifest.assets.first(where: { $0.kind == .meshRaw }) else {
            throw ScanComparisonWorkAreaError.emptyGeometry
        }
        let packageURL = try await assetStore.packageURL(for: scanID)
        return try validatedSnapshots(from: Data(contentsOf: packageURL.appending(path: meshAsset.relativePath)))
    }

    private static func validatedSnapshots(from data: Data) throws -> [MeshSnapshot] {
        let decoded = try JSONDecoder().decode([MeshSnapshot].self, from: data)
        return try decoded.map { snapshot in
            try MeshSnapshot(
                anchorID: snapshot.anchorID,
                worldFromAnchor: Transform4x4(columns: snapshot.worldFromAnchor.columns),
                vertices: snapshot.vertices,
                normals: snapshot.normals,
                faces: snapshot.faces,
                classifications: snapshot.classifications
            )
        }
    }
}

actor DemoScanComparisonDraftService: ScanComparisonDraftServing {
    private var latestDraft: ScanComparisonDraft?
    private var workAreas: [UUID: ScanComparisonWorkArea] = [:]

    func saveDraft(baselineScanID: UUID, comparisonScanID: UUID) async -> ScanComparisonDraftSaveResult {
        let draft = ScanComparisonDraft(
            baselineScanID: baselineScanID,
            comparisonScanID: comparisonScanID
        )
        latestDraft = draft
        return .success(draft)
    }

    func loadLatestDraft() async -> ScanComparisonDraftLoadResult {
        .success(latestDraft)
    }

    func saveWorkArea(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaSaveResult {
        let area = ScanComparisonWorkArea(
            draftID: draft.id,
            referenceScanID: draft.baselineScanID,
            minimum: Point3D(x: -1, y: -1, z: -1),
            maximum: Point3D(x: 1, y: 1, z: 1)
        )
        workAreas[draft.id] = area
        return .success(area)
    }

    func loadWorkArea(forDraftID draftID: UUID) async -> ScanComparisonWorkAreaLoadResult {
        .success(workAreas[draftID])
    }

    func loadWorkAreaWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Work area editing unavailable in demo",
                message: "Open a real saved scan to select a 3D work area."
            )
        )
    }

    func saveRefinedWorkArea(
        for draft: ScanComparisonDraft,
        firstCorner: Point3D,
        oppositeCorner: Point3D
    ) async -> ScanComparisonWorkAreaSaveResult {
        do {
            let existing = workAreas[draft.id]
            let area = try ScanComparisonWorkArea.fromOppositeCorners(
                id: existing?.id ?? UUID(),
                draftID: draft.id,
                referenceScanID: draft.baselineScanID,
                first: firstCorner,
                second: oppositeCorner,
                createdAt: existing?.createdAt ?? .now
            )
            workAreas[draft.id] = area
            return .success(area)
        } catch {
            return .failure(
                ScanComparisonDraftFailureState(
                    title: "Could not save work area",
                    message: "Choose two distinct, opposite corners."
                )
            )
        }
    }

    func loadAlignmentWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonAlignmentWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Alignment unavailable in demo",
                message: "Open a real saved scan to select landmarks."
            )
        )
    }

    func saveLandmarkAlignment(
        for draft: ScanComparisonDraft,
        baselineLandmarks: [Point3D],
        comparisonLandmarks: [Point3D]
    ) async -> ScanComparisonAlignmentSaveResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Alignment unavailable in demo",
                message: "Open a real saved scan to save alignment."
            )
        )
    }

    func evaluateCoverage(for draft: ScanComparisonDraft) async -> ScanComparisonCoverageEvaluationResult {
        .needsAlignment
    }

    func loadReadiness(for draft: ScanComparisonDraft) async -> ScanComparisonReadiness {
        .needsAlignment
    }

    func loadVisualComparisonWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonVisualWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Alignment review unavailable in demo",
                message: "Open a real saved scan pair to review aligned geometry."
            )
        )
    }

    func loadSurfaceDifferencePreview(for draft: ScanComparisonDraft) async -> ScanComparisonSurfaceDifferenceWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Difference preview unavailable in demo",
                message: "Open a real saved scan pair to review observed differences."
            )
        )
    }
}

enum ScanThumbnailState: Equatable, Sendable {
    case ready
    case pending
    case unavailable
}

struct ScanLibraryItem: Equatable, Identifiable, Sendable {
    let scan: ScanMetadata
    let storageByteCount: Int64
    let thumbnailState: ScanThumbnailState
    let thumbnailURL: URL?
    let assetState: ScanAssetState?
    let summary: ScanSummary?

    init(
        scan: ScanMetadata,
        storageByteCount: Int64,
        thumbnailState: ScanThumbnailState,
        thumbnailURL: URL? = nil,
        assetState: ScanAssetState? = nil,
        summary: ScanSummary? = nil
    ) {
        self.scan = scan
        self.storageByteCount = storageByteCount
        self.thumbnailState = thumbnailState
        self.thumbnailURL = thumbnailURL
        self.assetState = assetState
        self.summary = summary
    }

    var id: UUID {
        scan.id
    }
}

enum LibraryScreenState: Equatable, Sendable {
    case loading
    case empty
    case content([ScanLibraryItem])
    case failure(LibraryFailureState)
}

enum DemoLibraryScenario: String, Sendable {
    case content
    case empty
    case failure
    case loading
}

struct DemoScanLibraryService: ScanLibraryServing {
    let scenario: DemoLibraryScenario

    func loadLibrary() async -> LibraryLoadResult {
        switch scenario {
        case .content:
            return .success(Self.scans)
        case .empty:
            return .success([])
        case .failure:
            return .failure(
                LibraryFailureState(
                    title: "Could not load scans",
                    message: "The local demo service could not provide the library. Try again to repeat the request."
                )
            )
        case .loading:
            try? await Task.sleep(for: .seconds(30))
            return .success([])
        }
    }

    static let scans = [
        ScanLibraryItem(
            scan: ScanMetadata(
                id: UUID(uuid: (0x1F, 0x2A, 0xE6, 0x61, 0x2C, 0x41, 0x4D, 0x11, 0xA3, 0xE0, 0xB5, 0xB5, 0xCD, 0x02, 0x42, 0x71)),
                displayName: "North facade",
                status: .completed,
                createdAt: Date(timeIntervalSince1970: 1_735_603_200),
                updatedAt: Date(timeIntervalSince1970: 1_735_603_580),
                durationSeconds: 187
            ),
            storageByteCount: 148_000_000,
            thumbnailState: .ready
        ),
        ScanLibraryItem(
            scan: ScanMetadata(
                id: UUID(uuid: (0x99, 0xD1, 0x43, 0x11, 0x04, 0xC7, 0x4F, 0xF3, 0x9C, 0xB9, 0xC1, 0x88, 0x15, 0x19, 0x77, 0x54)),
                displayName: "Service corridor",
                status: .processing,
                createdAt: Date(timeIntervalSince1970: 1_735_516_800),
                updatedAt: Date(timeIntervalSince1970: 1_735_517_051),
                durationSeconds: 251
            ),
            storageByteCount: 73_000_000,
            thumbnailState: .pending
        )
    ]
}

@MainActor
@Observable
final class LibraryViewModel {
    private let service: any ScanLibraryServing
    private var hasLoaded = false

    let isDemo: Bool
    private(set) var state: LibraryScreenState = .loading

    init(service: any ScanLibraryServing, isDemo: Bool = false) {
        self.service = service
        self.isDemo = isDemo
    }

    func loadIfNeeded() async {
        guard !hasLoaded else {
            return
        }

        hasLoaded = true
        await reload()
    }

    func reload() async {
        state = .loading
        let result = await service.loadLibrary()

        guard !Task.isCancelled else {
            return
        }

        switch result {
        case let .success(scans):
            state = scans.isEmpty ? .empty : .content(scans)
        case let .failure(error):
            state = .failure(error)
        }
    }
}

protocol ScanDetailServing: Sendable {
    func loadDetail(id: UUID) async -> ScanDetailLoadResult
    func loadPointCloud(id: UUID) async -> PointCloudLoadResult
    func renameScan(id: UUID, displayName: String) async -> ScanDetailRenameResult
    func deleteScan(id: UUID) async -> ScanDetailDeleteResult
    func reconstructionUpdates(id: UUID) async -> AsyncStream<ScanReconstructionStatus>
    func retryReconstruction(id: UUID) async -> ScanReconstructionStatus?
}

extension ScanDetailServing {
    func reconstructionUpdates(id: UUID) async -> AsyncStream<ScanReconstructionStatus> {
        AsyncStream { $0.finish() }
    }

    func retryReconstruction(id: UUID) async -> ScanReconstructionStatus? { nil }
}

protocol AppReconstructionCoordinating: Sendable {
    func enqueue(scanID: UUID, automatic: Bool) async -> ScanReconstructionStatus
    func retry(scanID: UUID) async -> ScanReconstructionStatus
    func status(scanID: UUID) async -> ScanReconstructionStatus
    func updates(scanID: UUID) async -> AsyncStream<ScanReconstructionStatus>
    func setApplicationActive(_ isActive: Bool) async
    func resumePendingJobs() async
    func cancelAndWait(scanID: UUID) async
}

extension ScanReconstructionCoordinator: AppReconstructionCoordinating {}

/// Owns the filesystem work required to prepare a truthful original-asset
/// export. It is intentionally separate from `ScanDetailServing` so a demo or
/// startup-failure detail service never has to pretend it can share files.
protocol ScanExportPreparing: Sendable {
    func prepareOriginalAssetExport(
        id: UUID,
        selection: ScanExportSelection
    ) async -> ScanExportPreparationResult
}

/// Prepares a single interoperable deliverable. Unlike the legacy
/// original-asset workflow, this never hands an internal manifest or raw mesh
/// JSON to the share sheet.
protocol ScanInterchangeExportPreparing: Sendable {
    func availableInterchangeFormats(id: UUID) async -> [ScanInterchangeFormat]
    func prepareInterchangeExport(
        id: UUID,
        format: ScanInterchangeFormat
    ) async -> ScanInterchangeExportPreparationResult
}

struct PreparedScanInterchangeExport: Equatable, Sendable, Identifiable {
    let format: ScanInterchangeFormat
    let shareURL: URL

    var id: URL {
        shareURL
    }
}

enum ScanInterchangeExportPreparationResult: Equatable, Sendable {
    case success(PreparedScanInterchangeExport)
    case failure(ScanDetailFailureState)
}

struct PreparedScanExport: Equatable, Sendable, Identifiable {
    let preview: ScanExportPreview
    let assetURLs: [URL]
    let manifestURL: URL

    var id: URL {
        manifestURL
    }

    var shareURLs: [URL] {
        assetURLs + [manifestURL]
    }
}

enum ScanExportPreparationResult: Equatable, Sendable {
    case success(PreparedScanExport)
    case failure(ScanDetailFailureState)
}

struct ScanDetailFailureState: Equatable, Sendable, Identifiable {
    let title: String
    let message: String

    var id: String {
        "\(title)|\(message)"
    }
}

enum RawMeshLoadState: Equatable, Sendable {
    case available([MeshSnapshot])
    case unavailable(message: String)
    case failure(message: String)
}

enum PointCloudLoadResult: Equatable, Sendable {
    case available(SavedPointCloudPresentation)
    case unavailable(message: String)
    case failure(message: String)
}

enum PointCloudScreenState: Equatable, Sendable {
    case idle
    case loading
    case available(SavedPointCloudPresentation)
    case unavailable(message: String)
    case failure(message: String)
}

enum ProcessedSurfaceLoadState: Equatable, Sendable {
    case available(SavedProcessedSurfacePresentation)
    case processing(message: String)
    case unavailable(message: String)

    var hasObservedColors: Bool {
        guard case let .available(presentation) = self else { return false }
        return presentation.hasObservedColors
    }
}

struct SavedProcessedSurfacePresentation: Equatable, Sendable {
    let surface: ProcessedSurfaceLOD
    /// Present only when the presentation was opened from a verified derived
    /// directory. Demo/test surfaces intentionally carry no invented report.
    let validation: TSDFSurfaceValidationReport?

    init(surface: ProcessedSurfaceLOD, validation: TSDFSurfaceValidationReport? = nil) {
        self.surface = surface
        self.validation = validation
    }

    var hasObservedColors: Bool { surface.hasObservedColors }
}

/// A bounded saved point-cloud sample plus only observed display colour. New
/// RGB-D PLY sources provide actual sampled RGB; legacy uncoloured PLY sources
/// may receive an optional display-only projection from verified keyframes.
/// Neither path mutates the immutable source package during viewing.
struct SavedPointCloudPresentation: Equatable, Sendable {
    let source: PointCloudPLYReadResult
    let observedColors: [MeshVertexColor?]

    var points: [PointCloudPLYPoint] {
        source.points
    }

    var hasObservedColors: Bool {
        observedColors.contains(where: { $0 != nil })
    }
}

struct ScanExportAsset: Equatable, Sendable, Identifiable {
    let reference: ScanAssetReference
    let url: URL

    var id: UUID {
        reference.id
    }
}

struct SavedScanKeyframe: Equatable, Sendable, Identifiable {
    let url: URL
    let displayOrientation: CapturedImageOrientation?
    let worldFromCamera: Transform4x4?
    let intrinsics: CameraIntrinsics?
    let imageWidth: Int?
    let imageHeight: Int?

    init(
        url: URL,
        displayOrientation: CapturedImageOrientation?,
        worldFromCamera: Transform4x4? = nil,
        intrinsics: CameraIntrinsics? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) {
        self.url = url
        self.displayOrientation = displayOrientation
        self.worldFromCamera = worldFromCamera
        self.intrinsics = intrinsics
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    var id: URL { url }
}

/// A real retained-image camera pose used only to render an optional saved
/// scan overlay. It is derived directly from capture metadata and never edits
/// the scan's AR-world geometry.
struct SavedCameraFrustum: Equatable, Sendable, Identifiable {
    let id: URL
    let worldFromCamera: Transform4x4
    let intrinsics: CameraIntrinsics
    let imageWidth: Int
    let imageHeight: Int
}

/// A bounded, render-only mesh copy with verified camera-derived colours
/// remapped to its compacted vertex order. Neither the source mesh nor its
/// immutable package is changed.
struct SavedRawMeshPresentation: Equatable, Sendable {
    let snapshots: [MeshSnapshot]
    let vertexColors: [UUID: [MeshVertexColor?]]
}

/// Prepares one bounded saved-mesh presentation as the detail model loads.
///
/// This work deliberately happens outside SwiftUI body evaluation. The
/// sanitizer only removes invalid display primitives and preserves each
/// snapshot's original anchor relation; the index map lets projected source
/// colours stay attached to the correct compacted display vertex.
enum SavedRawMeshPresentationBuilder {
    static func make(
        snapshots: [MeshSnapshot],
        vertexColors: [UUID: [MeshVertexColor?]]
    ) -> SavedRawMeshPresentation {
        let sanitizedSnapshots = MeshPresentationSanitizer().sanitize(snapshots)
        var remappedColors: [UUID: [MeshVertexColor?]] = [:]
        remappedColors.reserveCapacity(sanitizedSnapshots.count)

        for sanitized in sanitizedSnapshots {
            guard let sourceColors = vertexColors[sanitized.snapshot.anchorID] else {
                continue
            }
            let colors = sanitized.sourceVertexIndexByPresentationVertex.map { sourceIndex in
                sourceColors.indices.contains(sourceIndex) ? sourceColors[sourceIndex] : nil
            }
            if colors.contains(where: { $0 != nil }) {
                remappedColors[sanitized.snapshot.anchorID] = colors
            }
        }

        return SavedRawMeshPresentation(
            snapshots: sanitizedSnapshots.map(\.snapshot),
            vertexColors: remappedColors
        )
    }
}

struct SavedScanDetail: Equatable, Sendable {
    let scan: ScanMetadata
    let manifest: ScanPackageManifest
    let integrity: PackageIntegrityReport
    let processedSurface: ProcessedSurfaceLoadState
    let reconstructionStatus: ScanReconstructionStatus?
    /// Derived only from immutable package telemetry and checksum-validated
    /// derived-surface metadata. It is never persisted back into the source
    /// package, so it cannot make an unsupported quality claim stale.
    let reconstructionQualification: ScanReconstructionQualificationReport
    let rawMesh: RawMeshLoadState
    /// Display-only colors projected from verified retained camera keyframes.
    /// They are derived at load time and never mutate the source mesh package.
    let rawMeshVertexColors: [UUID: [MeshVertexColor?]]
    /// The one bounded, render-only mesh preparation shared by all saved views.
    /// It preserves source files and export behavior while avoiding expensive
    /// geometry rebuilding during SwiftUI body updates.
    let rawMeshPresentation: SavedRawMeshPresentation?
    let exportableAssets: [ScanExportAsset]
    let keyframes: [SavedScanKeyframe]

    init(
        scan: ScanMetadata,
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport,
        processedSurface: ProcessedSurfaceLoadState = .unavailable(
            message: "Processed surface is not ready yet."
        ),
        reconstructionStatus: ScanReconstructionStatus? = nil,
        reconstructionQualification: ScanReconstructionQualificationReport? = nil,
        rawMesh: RawMeshLoadState,
        rawMeshVertexColors: [UUID: [MeshVertexColor?]] = [:],
        rawMeshPresentation: SavedRawMeshPresentation? = nil,
        exportableAssets: [ScanExportAsset],
        keyframes: [SavedScanKeyframe] = []
    ) {
        self.scan = scan
        self.manifest = manifest
        self.integrity = integrity
        self.processedSurface = processedSurface
        self.reconstructionStatus = reconstructionStatus
        self.reconstructionQualification = reconstructionQualification
            ?? Self.makeReconstructionQualification(
                manifest: manifest,
                integrity: integrity,
                processedSurface: processedSurface
            )
        self.rawMesh = rawMesh
        self.rawMeshVertexColors = rawMeshVertexColors
        if let rawMeshPresentation {
            self.rawMeshPresentation = rawMeshPresentation
        } else if case let .available(snapshots) = rawMesh {
            self.rawMeshPresentation = SavedRawMeshPresentationBuilder.make(
                snapshots: snapshots,
                vertexColors: rawMeshVertexColors
            )
        } else {
            self.rawMeshPresentation = nil
        }
        self.exportableAssets = exportableAssets
        self.keyframes = keyframes
    }

    private static func makeReconstructionQualification(
        manifest: ScanPackageManifest,
        integrity: PackageIntegrityReport,
        processedSurface: ProcessedSurfaceLoadState
    ) -> ScanReconstructionQualificationReport {
        let validation: TSDFSurfaceValidationReport?
        if case let .available(presentation) = processedSurface {
            validation = presentation.validation
        } else {
            validation = nil
        }
        return ScanReconstructionQualificationReport(
            captureEvidence: manifest.captureTelemetry?.evidenceQualification,
            packageIntegrityIsValid: integrity.isValid,
            canonicalSpatialSourceAvailable: manifest.assets.contains {
                $0.relativePath == CanonicalSpatialChunkStore.relativePath
            },
            processedSurfaceAvailable: {
                if case .available = processedSurface { return true }
                return false
            }(),
            surfaceValidation: validation
        )
    }

    var assetState: ScanAssetState {
        ScanAssetStateResolver().resolve(metadata: scan, manifest: manifest, integrity: integrity)
    }

    var capabilities: ScanCapabilities {
        ScanCapabilities(manifest: manifest)
    }

    /// Verified camera keyframes are user-captured imagery. Keeping their
    /// selection here prevents views from reaching into package paths or
    /// displaying unrelated internal assets.
    var retainedKeyframeURLs: [URL] {
        exportableAssets
            .filter { $0.reference.kind == .textureSource }
            .sorted { $0.reference.relativePath < $1.reference.relativePath }
            .map(\.url)
    }

    /// A verified RoomPlan USDZ belongs to the semantic capture itself. It is
    /// intentionally separate from raw mesh and point-cloud rendering because
    /// it uses RoomPlan's own coordinate/model representation.
    var semanticRoomURL: URL? {
        exportableAssets.first(where: { $0.reference.kind == .semanticRoom })?.url
    }

    /// Limits the workspace gallery to a small, evenly distributed subset of
    /// user-captured images. The full retained set remains an immutable scan
    /// asset and is never loaded by the workspace merely to build a gallery.
    var workspaceKeyframeURLs: [URL] {
        let keyframes = retainedKeyframeURLs
        let maximumCount = 8
        guard keyframes.count > maximumCount else {
            return keyframes
        }
        return (0..<maximumCount).map { index in
            keyframes[index * (keyframes.count - 1) / (maximumCount - 1)]
        }
    }

    var workspaceKeyframes: [SavedScanKeyframe] {
        let source = keyframes.isEmpty
            ? retainedKeyframeURLs.map { SavedScanKeyframe(url: $0, displayOrientation: nil) }
            : keyframes
        let maximumCount = 8
        guard source.count > maximumCount else { return source }
        return (0..<maximumCount).map { source[$0 * (source.count - 1) / (maximumCount - 1)] }
    }

    /// The overlay is available only for retained images with complete,
    /// calibrated capture metadata. This excludes gallery-only images that
    /// cannot truthfully be placed in AR-world coordinates.
    var retainedCameraFrustums: [SavedCameraFrustum] {
        keyframes.compactMap { keyframe in
            guard let worldFromCamera = keyframe.worldFromCamera,
                  let intrinsics = keyframe.intrinsics,
                  let imageWidth = keyframe.imageWidth,
                  let imageHeight = keyframe.imageHeight,
                  imageWidth > 0,
                  imageHeight > 0,
                  intrinsics.fx.isFinite,
                  intrinsics.fy.isFinite,
                  intrinsics.fx > 0,
                  intrinsics.fy > 0
            else {
                return nil
            }
            return SavedCameraFrustum(
                id: keyframe.url,
                worldFromCamera: worldFromCamera,
                intrinsics: intrinsics,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )
        }
    }

    var summary: ScanSummary {
        ScanSummary(manifest: manifest)
    }

    var qualityReport: ScanQualityReport? {
        manifest.qualitySignals.map { ScanQualityEvaluator().evaluate($0) }
    }

    /// A factual summary of the persisted RGB-D admission telemetry. This is
    /// deliberately not a geometric-accuracy or physical-device quality score.
    var captureEvidenceQualification: CaptureEvidenceQualification? {
        manifest.captureTelemetry?.evidenceQualification
    }
}

enum ScanDetailLoadResult: Equatable, Sendable {
    case success(SavedScanDetail)
    case notFound
    case failure(ScanDetailFailureState)
}

enum ScanDetailDeleteResult: Equatable, Sendable {
    case success
    case failure(ScanDetailFailureState)
}

enum ScanDetailRenameResult: Equatable, Sendable {
    case success
    case failure(ScanDetailFailureState)
}

enum ScanDetailScreenState: Equatable, Sendable {
    case loading
    case content(SavedScanDetail)
    case failure(ScanDetailFailureState)
}

@MainActor
@Observable
final class ScanDetailViewModel {
    private let scanID: UUID
    private let service: any ScanDetailServing
    private var hasLoaded = false
    private var hasLoadedPointCloud = false

    let isDemo: Bool
    private(set) var state: ScanDetailScreenState = .loading
    private(set) var isDeleting = false
    private(set) var isRenaming = false
    private(set) var pointCloudState: PointCloudScreenState = .idle
    private(set) var reconstructionStatus: ScanReconstructionStatus?
    private(set) var isRetryingReconstruction = false
    var isShowingDeleteConfirmation = false
    var deleteFailure: ScanDetailFailureState?
    var renameFailure: ScanDetailFailureState?

    init(scanID: UUID, service: any ScanDetailServing, isDemo: Bool = false) {
        self.scanID = scanID
        self.service = service
        self.isDemo = isDemo
    }

    var navigationTitle: String {
        guard case let .content(detail) = state else {
            return "Scan details"
        }
        return detail.scan.displayName
    }

    func loadIfNeeded() async {
        guard !hasLoaded else {
            return
        }

        hasLoaded = true
        await reload()
    }

    func reload() async {
        state = .loading
        pointCloudState = .idle
        hasLoadedPointCloud = false
        let result = await service.loadDetail(id: scanID)

        guard !Task.isCancelled else {
            return
        }

        switch result {
        case let .success(detail):
            state = .content(detail)
            reconstructionStatus = detail.reconstructionStatus
            if !detail.processedSurface.hasObservedColors,
               detail.capabilities.capability(for: .pointCloud)?.availability == .available {
                await loadPointCloudIfNeeded()
            }
        case .notFound:
            state = .failure(
                ScanDetailFailureState(
                    title: "Scan not found",
                    message: "This saved scan is no longer available in local storage."
                )
            )
        case let .failure(error):
            state = .failure(error)
        }
    }

    func observeReconstruction() async {
        let updates = await service.reconstructionUpdates(id: scanID)
        var lastStage = reconstructionStatus?.stage
        for await status in updates {
            guard !Task.isCancelled else { return }
            reconstructionStatus = status
            if status.stage == .ready, lastStage != .ready {
                await reload()
            }
            lastStage = status.stage
        }
    }

    func retryReconstruction() async {
        guard !isRetryingReconstruction else { return }
        isRetryingReconstruction = true
        reconstructionStatus = await service.retryReconstruction(id: scanID)
        isRetryingReconstruction = false
    }

    func loadPointCloudIfNeeded() async {
        guard !hasLoadedPointCloud else {
            return
        }
        hasLoadedPointCloud = true
        pointCloudState = .loading
        let result = await service.loadPointCloud(id: scanID)
        guard !Task.isCancelled else {
            return
        }
        switch result {
        case let .available(pointCloud):
            pointCloudState = .available(pointCloud)
        case let .unavailable(message):
            pointCloudState = .unavailable(message: message)
        case let .failure(message):
            pointCloudState = .failure(message: message)
        }
    }

    func rename(to displayName: String) async -> Bool {
        guard case .content = state, !isRenaming else {
            return false
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            renameFailure = ScanDetailFailureState(
                title: "Scan name required",
                message: "Enter a nonempty name to save the change."
            )
            return false
        }

        isRenaming = true
        renameFailure = nil
        let result = await service.renameScan(id: scanID, displayName: trimmedName)
        isRenaming = false

        guard !Task.isCancelled else {
            return false
        }

        switch result {
        case .success:
            await reload()
            return true
        case let .failure(error):
            renameFailure = error
            return false
        }
    }

    func requestDeletionConfirmation() {
        guard case .content = state, !isDeleting else {
            return
        }
        isShowingDeleteConfirmation = true
    }

    func delete() async -> Bool {
        guard case .content = state, !isDeleting else {
            return false
        }

        isShowingDeleteConfirmation = false
        deleteFailure = nil
        isDeleting = true
        let result = await service.deleteScan(id: scanID)
        isDeleting = false

        guard !Task.isCancelled else {
            return false
        }

        switch result {
        case .success:
            return true
        case let .failure(error):
            deleteFailure = error
            return false
        }
    }
}

struct DemoScanDetailService: ScanDetailServing {
    func loadDetail(id: UUID) async -> ScanDetailLoadResult {
        guard let item = DemoScanLibraryService.scans.first(where: { $0.id == id }) else {
            return .notFound
        }

        let scan = item.scan
        let manifest = ScanPackageManifest(
            localScanID: scan.id,
            status: scan.status,
            createdAt: scan.createdAt,
            updatedAt: scan.updatedAt,
            durationSeconds: scan.durationSeconds,
            sourceDevice: SourceDeviceInfo(
                modelIdentifier: "Demo device",
                operatingSystemVersion: "Demo iOS version",
                appVersion: "Preview"
            ),
            captureStatistics: CaptureStatistics(
                sampledFrameCount: 264,
                featurePointCount: 38_420,
                depthPointCount: 16_800,
                meshVertexCount: 8,
                meshFaceCount: 12
            )
        )
        return .success(
            SavedScanDetail(
                scan: scan,
                manifest: manifest,
                integrity: PackageIntegrityReport(scanID: scan.id),
                processedSurface: Self.processedSurface.map {
                    .available(SavedProcessedSurfacePresentation(surface: $0))
                } ?? .unavailable(message: "Demo surface unavailable."),
                rawMesh: .available(Self.rawMesh),
                exportableAssets: []
            )
        )
    }

    func deleteScan(id: UUID) async -> ScanDetailDeleteResult {
        .success
    }

    func renameScan(id: UUID, displayName: String) async -> ScanDetailRenameResult {
        .failure(
            ScanDetailFailureState(
                title: "Renaming is not saved in demo",
                message: "Demo data is deterministic and is not written to local storage."
            )
        )
    }

    func loadPointCloud(id: UUID) async -> PointCloudLoadResult {
        .unavailable(message: "Real point clouds are not loaded in the UI test demo.")
    }

    private static let processedSurface: ProcessedSurfaceLOD? = {
        guard let bounds = try? TSDFSurfaceBounds(
            minimum: Point3D(x: -0.8, y: 0, z: -0.35),
            maximum: Point3D(x: 0.8, y: 0.1, z: 0.35)
        ) else { return nil }
        return ProcessedSurfaceLOD(
            prefix: TSDFCompletedPrefixIdentity(
                source: TSDFReconstructionSource(
                    scanID: UUID(uuid: (0x1F, 0x2A, 0xE6, 0x61, 0x2C, 0x41, 0x4D, 0x11, 0xA3, 0xE0, 0xB5, 0xB5, 0xCD, 0x02, 0x42, 0x71)),
                    keyframeIndexSHA256: String(repeating: "0", count: 64),
                    calibratedArchiveSHA256: String(repeating: "1", count: 64),
                    keyframeCount: 1
                ),
                configuration: .default,
                completedFrameCount: 1,
                sha256: String(repeating: "2", count: 64)
            ),
            sourceVertexCount: 4,
            sourceTriangleCount: 2,
            vertices: [
                Point3D(x: -0.8, y: 0, z: -0.35),
                Point3D(x: 0.8, y: 0, z: -0.35),
                Point3D(x: -0.8, y: 0, z: 0.35),
                Point3D(x: 0.8, y: 0, z: 0.35)
            ],
            normals: Array(repeating: Point3D(x: 0, y: 1, z: 0), count: 4),
            colors: [
                PointCloudColor(red: 183, green: 129, blue: 82),
                PointCloudColor(red: 183, green: 129, blue: 82),
                PointCloudColor(red: 202, green: 157, blue: 104),
                PointCloudColor(red: 202, green: 157, blue: 104)
            ],
            indices: [0, 2, 1, 1, 2, 3],
            robustBounds: bounds,
            hasObservedColors: true
        )
    }()

    private static let rawMesh: [MeshSnapshot] = {
        let vertices = [
            Point3D(x: -0.5, y: -0.5, z: -0.5),
            Point3D(x: 0.5, y: -0.5, z: -0.5),
            Point3D(x: 0.5, y: 0.5, z: -0.5),
            Point3D(x: -0.5, y: 0.5, z: -0.5),
            Point3D(x: -0.5, y: -0.5, z: 0.5),
            Point3D(x: 0.5, y: -0.5, z: 0.5),
            Point3D(x: 0.5, y: 0.5, z: 0.5),
            Point3D(x: -0.5, y: 0.5, z: 0.5)
        ]
        let faces = [
            MeshFace(indices: (0, 2, 1)), MeshFace(indices: (0, 3, 2)),
            MeshFace(indices: (4, 5, 6)), MeshFace(indices: (4, 6, 7)),
            MeshFace(indices: (0, 1, 5)), MeshFace(indices: (0, 5, 4)),
            MeshFace(indices: (1, 2, 6)), MeshFace(indices: (1, 6, 5)),
            MeshFace(indices: (2, 3, 7)), MeshFace(indices: (2, 7, 6)),
            MeshFace(indices: (3, 0, 4)), MeshFace(indices: (3, 4, 7))
        ]

        do {
            return [
                try MeshSnapshot(
                    anchorID: UUID(uuid: (0xA4, 0x9A, 0x32, 0xCE, 0x42, 0x10, 0x4A, 0x42, 0x92, 0x4E, 0x2A, 0xD7, 0xA1, 0xE9, 0xB4, 0x0D)),
                    worldFromAnchor: .identity,
                    vertices: vertices,
                    normals: [],
                    faces: faces
                )
            ]
        } catch {
            return []
        }
    }()
}

actor LocalScanDetailService: ScanDetailServing, ScanExportPreparing, ScanInterchangeExportPreparing {
    private let repository: LocalScanRepository
    private let assetStore: FileAssetStore
    private let processedSurfaceStore: ProcessedSurfaceStore?
    private let reconstructionCoordinator: (any AppReconstructionCoordinating)?

    init(
        repository: LocalScanRepository,
        assetStore: FileAssetStore,
        processedSurfaceStore: ProcessedSurfaceStore? = nil,
        reconstructionCoordinator: (any AppReconstructionCoordinating)? = nil
    ) {
        self.repository = repository
        self.assetStore = assetStore
        self.processedSurfaceStore = processedSurfaceStore
        self.reconstructionCoordinator = reconstructionCoordinator
    }

    func loadDetail(id: UUID) async -> ScanDetailLoadResult {
        do {
            guard let storedScan = try await repository.reopen(id: id) else {
                return .notFound
            }

            guard storedScan.integrity.isValid else {
                return .success(
                    SavedScanDetail(
                        scan: storedScan.scan,
                        manifest: storedScan.manifest,
                        integrity: storedScan.integrity,
                        processedSurface: .unavailable(
                            message: "Processed surface unavailable until scan integrity is verified."
                        ),
                        rawMesh: .unavailable(
                            message: "Raw mesh viewing and export are unavailable until this package passes integrity checks."
                        ),
                        exportableAssets: []
                    )
                )
            }

            let packageURL = try await assetStore.packageURL(for: id)
            let exportableAssets = storedScan.manifest.assets.map {
                ScanExportAsset(reference: $0, url: packageURL.appending(path: $0.relativePath))
            }
            let processedSurface = try await loadProcessedSurface(
                id: id,
                packageURL: packageURL,
                storedScan: storedScan
            )
            let reconstructionStatus = await reconstructionStatus(
                id: id,
                processedSurface: processedSurface
            )
            let rawMesh: RawMeshLoadState
            if let rawMeshAsset = storedScan.manifest.assets.first(where: { $0.kind == .meshRaw }) {
                rawMesh = loadRawMesh(from: rawMeshAsset, packageURL: packageURL)
            } else {
                rawMesh = .unavailable(message: "This scan package has no raw mesh snapshot.")
            }
            let rawMeshVertexColors = loadProjectedVertexColors(
                for: rawMesh,
                manifest: storedScan.manifest,
                packageURL: packageURL
            )
            let keyframes = loadKeyframes(
                manifest: storedScan.manifest,
                packageURL: packageURL,
                exportableAssets: exportableAssets
            )

            return .success(
                SavedScanDetail(
                    scan: storedScan.scan,
                    manifest: storedScan.manifest,
                    integrity: storedScan.integrity,
                    processedSurface: processedSurface,
                    reconstructionStatus: reconstructionStatus,
                    rawMesh: rawMesh,
                    rawMeshVertexColors: rawMeshVertexColors,
                    exportableAssets: exportableAssets,
                    keyframes: keyframes
                )
            )
        } catch {
            return .failure(
                ScanDetailFailureState(
                    title: "Could not open scan",
                    message: "Local scan metadata or package assets could not be opened. Check available storage and try again."
                )
            )
        }
    }

    func reconstructionUpdates(id: UUID) async -> AsyncStream<ScanReconstructionStatus> {
        guard let reconstructionCoordinator else {
            return AsyncStream { $0.finish() }
        }
        return await reconstructionCoordinator.updates(scanID: id)
    }

    func retryReconstruction(id: UUID) async -> ScanReconstructionStatus? {
        await reconstructionCoordinator?.retry(scanID: id)
    }

    private func reconstructionStatus(
        id: UUID,
        processedSurface: ProcessedSurfaceLoadState
    ) async -> ScanReconstructionStatus? {
        guard let reconstructionCoordinator else { return nil }
        if case .available = processedSurface { return nil }

        let current = await reconstructionCoordinator.status(scanID: id)
        return await reconstructionCoordinator.enqueue(
            scanID: id,
            automatic: current.stage != .ready
        )
    }

    private func loadProcessedSurface(
        id: UUID,
        packageURL: URL,
        storedScan: StoredScan
    ) async throws -> ProcessedSurfaceLoadState {
        guard let processedSurfaceStore else {
            return .unavailable(message: "Processed surface is not ready yet.")
        }
        do {
            let surface = try await processedSurfaceStore.loadProcessedSurface(
                scanID: id,
                packageURL: packageURL,
                manifest: storedScan.manifest,
                integrity: storedScan.integrity
            )
            let validated = try await processedSurfaceStore.validatedProcessedSurface(
                scanID: id,
                packageURL: packageURL,
                manifest: storedScan.manifest,
                integrity: storedScan.integrity
            )
            return .available(SavedProcessedSurfacePresentation(
                surface: surface,
                validation: validated.validation
            ))
        } catch ProcessedSurfaceReadError.notFound {
            return await processedSurfaceStore.hasProcessingWork(for: id)
                ? .processing(message: "3D surface processing is not complete yet.")
                : .unavailable(message: "Processed surface is not ready yet.")
        } catch let error as CancellationError {
            throw error
        } catch {
            return .unavailable(
                message: "Processed surface is invalid; showing a fallback view."
            )
        }
    }

    func deleteScan(id: UUID) async -> ScanDetailDeleteResult {
        do {
            await reconstructionCoordinator?.cancelAndWait(scanID: id)
            try await processedSurfaceStore?.removeDerivedData(for: id)
            try await repository.delete(id: id)
            return .success
        } catch {
            return .failure(
                ScanDetailFailureState(
                    title: "Could not delete scan",
                    message: "The local scan could not be deleted. Check available storage and try again."
                )
            )
        }
    }

    func renameScan(id: UUID, displayName: String) async -> ScanDetailRenameResult {
        do {
            try await repository.rename(id: id, displayName: displayName, updatedAt: .now)
            return .success
        } catch ScanRepositoryError.emptyDisplayName {
            return .failure(
                ScanDetailFailureState(
                    title: "Scan name required",
                    message: "Enter a nonempty name to save the change."
                )
            )
        } catch ScanRepositoryError.scanNotFound {
            return .failure(
                ScanDetailFailureState(
                    title: "Scan not found",
                    message: "This saved scan is no longer available locally."
                )
            )
        } catch {
            return .failure(
                ScanDetailFailureState(
                    title: "Could not rename scan",
                    message: "Local scan metadata could not be updated. Package files were not changed."
                )
            )
        }
    }

    func loadPointCloud(id: UUID) async -> PointCloudLoadResult {
        do {
            guard let storedScan = try await repository.reopen(id: id) else {
                return .unavailable(message: "This saved scan is no longer available.")
            }
            guard storedScan.integrity.isValid else {
                return .unavailable(message: "Point cloud unavailable until package integrity is verified.")
            }
            guard let asset = storedScan.manifest.assets.first(where: { $0.kind == .pointCloud }) else {
                return .unavailable(message: "This scan package has no saved point cloud.")
            }
            let packageURL = try await assetStore.packageURL(for: id)
            let result = try PointCloudPLYReader().read(
                from: packageURL.appending(path: asset.relativePath)
            )
            let persistedColors = result.points.map { point in
                point.color.map {
                    MeshVertexColor(
                        red: $0.red,
                        green: $0.green,
                        blue: $0.blue,
                        alpha: 255
                    )
                }
            }
            let observedColors: [MeshVertexColor?]
            if persistedColors.contains(where: { $0 != nil }) {
                observedColors = persistedColors
            } else {
                let frames = loadProjectionFrames(
                    manifest: storedScan.manifest,
                    packageURL: packageURL,
                    maximumCount: 8
                )
                observedColors = frames.isEmpty
                    ? []
                    : PointCloudColorProjector().project(
                        points: result.points.map(\.position),
                        frames: frames
                    ).colors
            }
            return .available(
                SavedPointCloudPresentation(
                    source: result,
                    observedColors: observedColors
                )
            )
        } catch let error as PointCloudPLYReaderError {
            return .failure(message: "The saved point cloud is unreadable: \(String(describing: error))")
        } catch {
            return .failure(message: "Could not open the saved point cloud.")
        }
    }

    func prepareOriginalAssetExport(
        id: UUID,
        selection: ScanExportSelection
    ) async -> ScanExportPreparationResult {
        do {
            guard let storedScan = try await repository.reopen(id: id) else {
                return .failure(
                    ScanDetailFailureState(
                        title: "Could not export",
                        message: "This saved scan is no longer available."
                    )
                )
            }
            guard storedScan.integrity.isValid else {
                return .failure(
                    ScanDetailFailureState(
                        title: "Export disabled until integrity is verified",
                        message: "The scan package must pass size and checksum checks before preparing source files."
                    )
                )
            }

            let exporter = OriginalAssetScanExporter()
            let preview = try exporter.preview(selection: selection, from: storedScan.manifest)
            let packageURL = try await assetStore.packageURL(for: id)
            let assetURLs = try preview.selectedOriginalAssets.map { asset -> URL in
                let url = packageURL.appending(path: asset.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ExportPreparationError.assetMissing
                }
                return url
            }

            let manifestData = try exporter.encodeManifest(preview.manifest)
            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("StrataScanExports", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )
            let manifestURL = exportDirectory.appendingPathComponent("export-manifest.json")
            try manifestData.write(to: manifestURL, options: .atomic)

            return .success(
                PreparedScanExport(
                    preview: preview,
                    assetURLs: assetURLs,
                    manifestURL: manifestURL
                )
            )
        } catch {
            return .failure(
                ScanDetailFailureState(
                    title: "Could not prepare export",
                    message: "The selected source files or accompanying manifest could not be prepared. No new conversion or packaging was performed."
                )
            )
        }
    }

    func availableInterchangeFormats(id: UUID) async -> [ScanInterchangeFormat] {
        do {
            guard let storedScan = try await repository.reopen(id: id),
                  storedScan.integrity.isValid
            else {
                return []
            }
            let packageURL = try await assetStore.packageURL(for: id)
            let processedSurface = try? await processedSurfaceStore?.validatedProcessedSurface(
                scanID: id,
                packageURL: packageURL,
                manifest: storedScan.manifest,
                integrity: storedScan.integrity
            )
            return ScanInterchangeExporter().availableFormats(
                for: storedScan.manifest,
                packageURL: packageURL,
                integrity: storedScan.integrity,
                processedSurface: processedSurface
            )
        } catch {
            return []
        }
    }

    func prepareInterchangeExport(
        id: UUID,
        format: ScanInterchangeFormat
    ) async -> ScanInterchangeExportPreparationResult {
        do {
            guard let storedScan = try await repository.reopen(id: id) else {
                return .failure(
                    ScanDetailFailureState(
                        title: "Could not export",
                        message: "This saved scan is no longer available."
                    )
                )
            }
            guard storedScan.integrity.isValid else {
                return .failure(
                    ScanDetailFailureState(
                        title: "Export unavailable",
                        message: "This scan must be checked before exporting."
                    )
                )
            }

            let packageURL = try await assetStore.packageURL(for: id)
            let exporter = ScanInterchangeExporter()
            let processedSurface = try? await processedSurfaceStore?.validatedProcessedSurface(
                scanID: id,
                packageURL: packageURL,
                manifest: storedScan.manifest,
                integrity: storedScan.integrity
            )
            guard exporter.availableFormats(
                for: storedScan.manifest,
                packageURL: packageURL,
                integrity: storedScan.integrity,
                processedSurface: processedSurface
            ).contains(format) else {
                return .failure(
                    ScanDetailFailureState(
                        title: "Export unavailable",
                        message: "This scan has no exportable data in this format."
                    )
                )
            }

            let exportDirectory = FileManager.default.temporaryDirectory
                .appending(path: "StrataScan-Interchange-Exports", directoryHint: .isDirectory)
                .appending(path: id.uuidString, directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)

            switch format {
            case .ply:
                let output = try exporter.writePLY(
                    from: storedScan.manifest,
                    packageURL: packageURL,
                    integrity: storedScan.integrity,
                    to: exportDirectory.appending(path: "scan.ply")
                )
                return .success(
                    PreparedScanInterchangeExport(
                        format: format,
                        shareURL: output.fileURL
                    )
                )
            case .glb:
                guard let processedSurface else {
                    throw ScanInterchangeExportError.missingProcessedSurface
                }
                let outputURL = exportDirectory.appending(path: "scan.glb")
                _ = try exporter.writeGLB(
                    from: processedSurface,
                    packageURL: packageURL,
                    to: outputURL
                )
                return .success(PreparedScanInterchangeExport(format: format, shareURL: outputURL))
            case .cesium3DTiles:
                guard let processedSurface else {
                    throw ScanInterchangeExportError.missingProcessedSurface
                }
                let directoryURL = exportDirectory.appending(
                    path: "scan-3d-tiles",
                    directoryHint: .isDirectory
                )
                let output = try exporter.writeCesium3DTiles(
                    from: processedSurface,
                    packageURL: packageURL,
                    to: directoryURL
                )
                let archiveURL = exportDirectory.appending(path: "scan-3d-tiles.zip")
                let shareURL = try ScanInterchangeArchiveWriter().writeDirectory(
                    at: output.directoryURL,
                    to: archiveURL
                )
                return .success(PreparedScanInterchangeExport(format: format, shareURL: shareURL))
            case .opf:
                let directoryURL = exportDirectory.appending(
                    path: "scan-opf",
                    directoryHint: .isDirectory
                )
                let output = try exporter.writeOPFPointCloud(
                    from: storedScan.manifest,
                    packageURL: packageURL,
                    integrity: storedScan.integrity,
                    to: directoryURL,
                    projectName: storedScan.scan.displayName
                )
                let archiveURL = exportDirectory.appending(path: "scan-opf.zip")
                let shareURL = try ScanInterchangeArchiveWriter().writeDirectory(
                    at: output.directoryURL,
                    to: archiveURL
                )
                return .success(PreparedScanInterchangeExport(format: format, shareURL: shareURL))
            }
        } catch {
            return .failure(
                ScanDetailFailureState(
                    title: "Could not prepare export",
                    message: "The selected file could not be prepared. The source scan is unchanged."
                )
            )
        }
    }

    private func loadRawMesh(from asset: ScanAssetReference, packageURL: URL) -> RawMeshLoadState {
        do {
            let data = try Data(contentsOf: packageURL.appending(path: asset.relativePath))
            return .available(try validatedRawMeshSnapshots(from: data))
        } catch {
            return .failure(message: "The saved raw mesh could not be decoded.")
        }
    }

    private func validatedRawMeshSnapshots(from data: Data) throws -> [MeshSnapshot] {
        let decodedSnapshots = try JSONDecoder().decode([MeshSnapshot].self, from: data)
        return try decodedSnapshots.map { snapshot in
            let transform = try Transform4x4(columns: snapshot.worldFromAnchor.columns)
            return try MeshSnapshot(
                anchorID: snapshot.anchorID,
                worldFromAnchor: transform,
                vertices: snapshot.vertices,
                normals: snapshot.normals,
                faces: snapshot.faces,
                classifications: snapshot.classifications
            )
        }
    }

    /// Uses a bounded, evenly distributed subset so opening a detailed scan
    /// does not decode every retained JPEG at once. Candidate metadata and
    /// source-image assets share capture order by collector contract.
    private func loadProjectedVertexColors(
        for rawMesh: RawMeshLoadState,
        manifest: ScanPackageManifest,
        packageURL: URL
    ) -> [UUID: [MeshVertexColor?]] {
        guard case let .available(snapshots) = rawMesh,
              !snapshots.isEmpty
        else {
            return [:]
        }

        let frames = loadProjectionFrames(
            manifest: manifest,
            packageURL: packageURL,
            maximumCount: 12
        )
        guard !frames.isEmpty else {
            return [:]
        }
        return MeshVertexColorProjector().project(snapshots: snapshots, frames: frames).colorsByAnchorID
    }

    /// Loads a small, evenly distributed set of only verified retained images
    /// with their original capture-time calibration. Callers may use the
    /// returned frames for a display-only derived preview; source assets remain
    /// immutable and malformed optional imagery simply contributes no colour.
    private func loadProjectionFrames(
        manifest: ScanPackageManifest,
        packageURL: URL,
        maximumCount: Int
    ) -> [TextureProjectionFrame] {
        guard maximumCount > 0,
              let metadataAsset = manifest.assets.first(where: { $0.kind == .frameMetadata })
        else {
            return []
        }

        do {
            let metadata = try frameMetadata(
                from: Data(contentsOf: packageURL.appending(path: metadataAsset.relativePath))
            )
            .filter(\.isTextureSourceCandidate)
            let imageAssets = manifest.assets
                .filter { $0.kind == .textureSource }
                .sorted { $0.relativePath < $1.relativePath }
            let pairs = boundedEvenlyDistributed(
                Array(zip(metadata, imageAssets)),
                maximumCount: maximumCount
            )
            return pairs.compactMap { metadata, asset -> TextureProjectionFrame? in
                guard let image = TextureProjectionImageDecoder.decode(
                    data: try? Data(contentsOf: packageURL.appending(path: asset.relativePath))
                ) else {
                    return nil
                }
                return TextureProjectionFrame(metadata: metadata, image: image)
            }
        } catch {
            return []
        }
    }

    private func frameMetadata(from data: Data) throws -> [FrameMetadata] {
        let decoder = JSONDecoder()
        return try data
            .split(separator: 0x0A)
            .map { try decoder.decode(FrameMetadata.self, from: Data($0)) }
    }

    private func loadKeyframes(
        manifest: ScanPackageManifest,
        packageURL: URL,
        exportableAssets: [ScanExportAsset]
    ) -> [SavedScanKeyframe] {
        let images = exportableAssets
            .filter { $0.reference.kind == .textureSource }
            .sorted { $0.reference.relativePath < $1.reference.relativePath }
        guard let metadataAsset = manifest.assets.first(where: { $0.kind == .frameMetadata }), !images.isEmpty,
              let metadata = try? frameMetadata(from: Data(contentsOf: packageURL.appending(path: metadataAsset.relativePath)))
        else { return images.map { SavedScanKeyframe(url: $0.url, displayOrientation: nil) } }
        return zip(metadata.filter(\.isTextureSourceCandidate), images).map {
            SavedScanKeyframe(
                url: $0.1.url,
                displayOrientation: $0.0.displayOrientation,
                worldFromCamera: $0.0.worldFromCamera,
                intrinsics: $0.0.intrinsics,
                imageWidth: $0.0.imageWidth,
                imageHeight: $0.0.imageHeight
            )
        }
    }

    private func boundedEvenlyDistributed<Element>(_ values: [Element], maximumCount: Int) -> [Element] {
        guard maximumCount > 0, values.count > maximumCount else {
            return values
        }
        return (0..<maximumCount).map { index in
            values[index * (values.count - 1) / (maximumCount - 1)]
        }
    }
}

private enum TextureProjectionImageDecoder {
    static func decode(data: Data?) -> TextureProjectionImage? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else {
            return nil
        }
        let count = width * height * 4
        let rgba = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: count))
        return try? TextureProjectionImage(width: width, height: height, rgbaBytes: rgba)
    }
}

private enum ExportPreparationError: Error {
    case assetMissing
}

enum ScannerCapabilityState: Equatable, Sendable {
    case checking
    case available([ScanCapabilityAdvisory])
    case requiresCameraPermission
    case unavailable([ScanCapabilityIssue])
}

/// A compact, value-only description of a finalized capture staging area.
/// It is deliberately separate from a persisted package: the user is still
/// reviewing the capture and can discard it without creating scan metadata.
struct CaptureReviewArtifact: Equatable, Sendable, Identifiable {
    let kind: AssetKind
    let relativePath: String
    let byteCount: Int64

    var id: String {
        relativePath
    }
}

struct CaptureReviewSnapshot: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let capturedAt: Date
    let durationSeconds: TimeInterval
    let captureMode: ScanCaptureMode
    let statistics: CaptureStatistics
    let artifacts: [CaptureReviewArtifact]

    var totalByteCount: Int64 {
        artifacts.reduce(0) { $0 + $1.byteCount }
    }
}

/// A truthful, presentation-only summary of what the current raw AR session
/// has actually supplied. It deliberately has no percentage: observed mesh and
/// depth cannot prove completeness of an unknown room or object.
enum RawCaptureCoverage: Equatable, Sendable {
    case inactive
    case waitingForSpatialData
    case depthObserved
    case meshObserved(meshAnchorCount: Int)
    case trackingUnavailable

    var hasObservedMesh: Bool {
        if case .meshObserved = self {
            return true
        }
        return false
    }
}

/// A live-only decision for the Finish control. It has no percentage or
/// completeness claim: it only distinguishes a small accepted fragment from
/// enough observed mesh evidence to let the operator choose to finish.
enum RawCaptureReadiness: Equatable, Sendable {
    case inactive
    case gatheringGeometry
    case readyToFinish

    var canFinish: Bool {
        self == .readyToFinish
    }
}

/// A short, factual prompt based on the most recent copied ARKit samples. This
/// is deliberately not a quality score: it only reports a range, motion, or
/// mesh-update condition the active session has actually observed.
enum RawCaptureGuidance: Equatable, Sendable {
    case inactive
    case moveFarther
    case moveCloser
    case moveMoreSlowly
    case seekNewSurface
}

/// A transient, mesh-only description of the area actually observed during a
/// raw capture. It deliberately does not measure completion: an AR session has
/// no knowledge of the intended object, room, or boundary. Its only purpose is
/// to distinguish a first small surface from an expanding observed footprint.
enum RawCaptureObservationFootprint: Equatable, Sendable {
    case inactive
    case awaitingMesh
    case initialSurface
    case expandingSurface
    case broadObservedSurface
}

/// Keeps a bounded, live-only footprint of AR-world mesh vertices. The grid
/// cells are evidence that geometry was observed there, not a surface area or
/// a completeness percentage. This evaluator intentionally never enters the
/// collector or a saved scan package.
private struct RawCaptureObservationFootprintEvaluator: Sendable {
    private static let cellSizeMeters: Float = 0.25
    private static let maximumObservedCells = 4_096
    private static let maximumVertexSamplesPerMesh = 512
    private static let expandingExtentMeters = 0.45
    private static let broadExtentMeters = 1.20

    private var observedAnchorIDs: Set<UUID> = []
    private var observedCells: Set<WorldCell> = []
    private var bounds: WorldBounds?

    var footprint: RawCaptureObservationFootprint {
        guard !observedAnchorIDs.isEmpty else {
            return .awaitingMesh
        }

        let extent = bounds?.diagonalMeters ?? 0
        if extent >= Self.broadExtentMeters || observedCells.count >= 24 || observedAnchorIDs.count >= 4 {
            return .broadObservedSurface
        }
        if extent >= Self.expandingExtentMeters || observedCells.count >= 6 || observedAnchorIDs.count >= 2 {
            return .expandingSurface
        }
        return .initialSurface
    }

    mutating func observe(_ mesh: MeshSnapshot) {
        let vertices = mesh.worldVertices
        guard !vertices.isEmpty else { return }

        observedAnchorIDs.insert(mesh.anchorID)
        let step = max(1, vertices.count / Self.maximumVertexSamplesPerMesh)
        for index in stride(from: 0, to: vertices.count, by: step) {
            let point = vertices[index]
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { continue }
            bounds = bounds.map { $0.including(point) } ?? WorldBounds(point: point)
            guard observedCells.count < Self.maximumObservedCells else { continue }
            observedCells.insert(WorldCell(point: point))
        }
    }

    mutating func reset() {
        observedAnchorIDs.removeAll(keepingCapacity: false)
        observedCells.removeAll(keepingCapacity: false)
        bounds = nil
    }

    private struct WorldCell: Hashable, Sendable {
        let x: Int
        let y: Int
        let z: Int

        init(point: Point3D) {
            x = Int((point.x / RawCaptureObservationFootprintEvaluator.cellSizeMeters).rounded(.down))
            y = Int((point.y / RawCaptureObservationFootprintEvaluator.cellSizeMeters).rounded(.down))
            z = Int((point.z / RawCaptureObservationFootprintEvaluator.cellSizeMeters).rounded(.down))
        }
    }

    private struct WorldBounds: Sendable {
        var minimumX: Double
        var minimumY: Double
        var minimumZ: Double
        var maximumX: Double
        var maximumY: Double
        var maximumZ: Double

        init(point: Point3D) {
            minimumX = Double(point.x)
            minimumY = Double(point.y)
            minimumZ = Double(point.z)
            maximumX = Double(point.x)
            maximumY = Double(point.y)
            maximumZ = Double(point.z)
        }

        func including(_ point: Point3D) -> WorldBounds {
            WorldBounds(
                minimumX: min(minimumX, Double(point.x)),
                minimumY: min(minimumY, Double(point.y)),
                minimumZ: min(minimumZ, Double(point.z)),
                maximumX: max(maximumX, Double(point.x)),
                maximumY: max(maximumY, Double(point.y)),
                maximumZ: max(maximumZ, Double(point.z))
            )
        }

        var diagonalMeters: Double {
            let x = maximumX - minimumX
            let y = maximumY - minimumY
            let z = maximumZ - minimumZ
            return (x * x + y * y + z * z).squareRoot()
        }

        private init(
            minimumX: Double,
            minimumY: Double,
            minimumZ: Double,
            maximumX: Double,
            maximumY: Double,
            maximumZ: Double
        ) {
            self.minimumX = minimumX
            self.minimumY = minimumY
            self.minimumZ = minimumZ
            self.maximumX = maximumX
            self.maximumY = maximumY
            self.maximumZ = maximumZ
        }
    }
}

/// Reduces the latest accepted mesh per anchor into a small, transient Finish
/// decision. The thresholds deliberately use only real geometry facts: a
/// single small fragment cannot unlock Finish, while a compact object may do
/// so once its own mesh has enough faces and physical extent.
private struct RawMeshReadinessEvaluator: Sendable {
    private static let minimumSingleMeshFaces = 24
    private static let minimumSingleMeshExtentMeters = 0.30
    private static let minimumMultiAnchorFaces = 12
    private static let minimumMultiAnchorExtentMeters = 0.18

    private var observationsByAnchorID: [UUID: MeshObservation] = [:]

    var readiness: RawCaptureReadiness {
        guard !observationsByAnchorID.isEmpty else {
            return .inactive
        }

        let totalFaces = observationsByAnchorID.values.reduce(0) { $0 + $1.faceCount }
        let extent = combinedExtentMeters
        let hasSubstantialSingleMesh = observationsByAnchorID.values.contains {
            $0.faceCount >= Self.minimumSingleMeshFaces &&
                $0.extentMeters >= Self.minimumSingleMeshExtentMeters
        }
        let hasMultipleObservedSurfaces = observationsByAnchorID.count >= 2 &&
            totalFaces >= Self.minimumMultiAnchorFaces &&
            extent >= Self.minimumMultiAnchorExtentMeters

        return hasSubstantialSingleMesh || hasMultipleObservedSurfaces
            ? .readyToFinish
            : .gatheringGeometry
    }

    mutating func observe(_ mesh: MeshSnapshot) {
        observationsByAnchorID[mesh.anchorID] = MeshObservation(mesh: mesh)
    }

    mutating func reset() {
        observationsByAnchorID.removeAll(keepingCapacity: false)
    }

    private var combinedExtentMeters: Double {
        var combinedBounds: WorldBounds?
        for observation in observationsByAnchorID.values {
            guard let bounds = observation.bounds else { continue }
            combinedBounds = combinedBounds.map { $0.including(bounds) } ?? bounds
        }
        return combinedBounds?.diagonalMeters ?? 0
    }

    private struct MeshObservation: Sendable {
        let faceCount: Int
        let extentMeters: Double
        let bounds: WorldBounds?

        init(mesh: MeshSnapshot) {
            faceCount = mesh.faces.count
            let bounds = WorldBounds(vertices: mesh.worldVertices)
            self.bounds = bounds
            extentMeters = bounds?.diagonalMeters ?? 0
        }
    }

    private struct WorldBounds: Sendable {
        var minimumX: Double
        var minimumY: Double
        var minimumZ: Double
        var maximumX: Double
        var maximumY: Double
        var maximumZ: Double

        init?(vertices: [Point3D]) {
            guard let first = vertices.first else { return nil }
            minimumX = Double(first.x)
            minimumY = Double(first.y)
            minimumZ = Double(first.z)
            maximumX = Double(first.x)
            maximumY = Double(first.y)
            maximumZ = Double(first.z)

            for point in vertices.dropFirst() {
                minimumX = min(minimumX, Double(point.x))
                minimumY = min(minimumY, Double(point.y))
                minimumZ = min(minimumZ, Double(point.z))
                maximumX = max(maximumX, Double(point.x))
                maximumY = max(maximumY, Double(point.y))
                maximumZ = max(maximumZ, Double(point.z))
            }
        }

        func including(_ other: WorldBounds) -> WorldBounds {
            WorldBounds(
                minimumX: min(minimumX, other.minimumX),
                minimumY: min(minimumY, other.minimumY),
                minimumZ: min(minimumZ, other.minimumZ),
                maximumX: max(maximumX, other.maximumX),
                maximumY: max(maximumY, other.maximumY),
                maximumZ: max(maximumZ, other.maximumZ)
            )
        }

        var diagonalMeters: Double {
            let x = maximumX - minimumX
            let y = maximumY - minimumY
            let z = maximumZ - minimumZ
            return (x * x + y * y + z * z).squareRoot()
        }

        private init(
            minimumX: Double,
            minimumY: Double,
            minimumZ: Double,
            maximumX: Double,
            maximumY: Double,
            maximumZ: Double
        ) {
            self.minimumX = minimumX
            self.minimumY = minimumY
            self.minimumZ = minimumZ
            self.maximumX = maximumX
            self.maximumY = maximumY
            self.maximumZ = maximumZ
        }
    }
}

/// Evaluates live raw-capture conditions without retaining ARKit objects.
/// `worldFromCamera` is column-major, so its final column is the camera's
/// world-space position in meters.
private struct RawCaptureGuidanceEvaluator: Sendable {
    private static let minimumWorkingDistance: Float = 0.25
    private static let maximumWorkingDistance: Float = 4.5
    private static let maximumMotionMetersPerSecond: Float = 0.8
    private static let freshnessInterval: TimeInterval = 1.5
    private static let meshStallInterval: TimeInterval = 2.5

    private var previousCameraPosition: Point3D?
    private var previousFrameTimestamp: TimeInterval?
    private var latestRangeGuidance: RawCaptureGuidance = .inactive
    private var isMovingTooFast = false
    private var lastFrameReceivedAt: Date?
    private var lastMeshReceivedAt: Date?

    mutating func reset() {
        previousCameraPosition = nil
        previousFrameTimestamp = nil
        latestRangeGuidance = .inactive
        isMovingTooFast = false
        lastFrameReceivedAt = nil
        lastMeshReceivedAt = nil
    }

    mutating func observe(frame packet: CaptureFramePacket, receivedAt: Date) {
        lastFrameReceivedAt = receivedAt
        latestRangeGuidance = representativeDepth(in: packet.depth).map { depth in
            if depth < Self.minimumWorkingDistance { return .moveFarther }
            if depth > Self.maximumWorkingDistance { return .moveCloser }
            return .inactive
        } ?? .inactive

        let position = cameraPosition(from: packet.metadata.worldFromCamera)
        if let previousCameraPosition,
           let previousFrameTimestamp,
           packet.metadata.timestamp > previousFrameTimestamp {
            let elapsed = Float(packet.metadata.timestamp - previousFrameTimestamp)
            let dx = position.x - previousCameraPosition.x
            let dy = position.y - previousCameraPosition.y
            let dz = position.z - previousCameraPosition.z
            let speed = sqrt(dx * dx + dy * dy + dz * dz) / elapsed
            isMovingTooFast = speed > Self.maximumMotionMetersPerSecond
        } else {
            isMovingTooFast = false
        }
        self.previousCameraPosition = position
        previousFrameTimestamp = packet.metadata.timestamp
    }

    mutating func observe(mesh: MeshSnapshot, receivedAt: Date) {
        guard !mesh.vertices.isEmpty else { return }
        lastMeshReceivedAt = receivedAt
    }

    func guidance(
        coverage: RawCaptureCoverage,
        captureMode: ScanCaptureMode,
        lifecycle: ScanLifecycleState,
        now: Date = .now
    ) -> RawCaptureGuidance {
        guard captureMode == .rawLiDAR, lifecycle == .scanning,
              coverage != .trackingUnavailable
        else {
            return .inactive
        }

        if let lastFrameReceivedAt,
           now.timeIntervalSince(lastFrameReceivedAt) <= Self.freshnessInterval {
            if latestRangeGuidance != .inactive { return latestRangeGuidance }
            if isMovingTooFast { return .moveMoreSlowly }
        }

        if coverage.hasObservedMesh,
           let lastMeshReceivedAt,
           now.timeIntervalSince(lastMeshReceivedAt) > Self.meshStallInterval {
            return .seekNewSurface
        }
        return .inactive
    }

    private func cameraPosition(from transform: Transform4x4) -> Point3D {
        Point3D(
            x: transform.columns[12],
            y: transform.columns[13],
            z: transform.columns[14]
        )
    }

    /// Uses up to 256 medium/high-confidence samples so a single bad depth
    /// pixel cannot tell the operator to move. Depth samples are current-frame
    /// only and are never persisted by this evaluator.
    private func representativeDepth(in depth: DepthFrameSample?) -> Float? {
        guard let depth, !depth.depthMeters.isEmpty else { return nil }
        let samplingStep = max(1, depth.depthMeters.count / 256)
        var samples: [Float] = []
        samples.reserveCapacity(min(256, depth.depthMeters.count))
        for index in stride(from: 0, to: depth.depthMeters.count, by: samplingStep) {
            let value = depth.depthMeters[index]
            let confidenceIsAcceptable = index >= depth.confidence.count || depth.confidence[index] >= 1
            if value.isFinite, value > 0, confidenceIsAcceptable {
                samples.append(value)
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}

struct ScannerWorkflowSnapshot: Equatable, Sendable {
    let lifecycle: ScanLifecycleState
    let capability: ScannerCapabilityState
    let captureMode: ScanCaptureMode
    let isDemo: Bool
    let pendingReview: CaptureReviewSnapshot?
    let completedScanID: UUID?
    let rawCoverage: RawCaptureCoverage
    let rawObservationFootprint: RawCaptureObservationFootprint
    let rawReadiness: RawCaptureReadiness
    let rawGuidance: RawCaptureGuidance

    var canSelectCaptureMode: Bool {
        switch lifecycle {
        case .requestingPermissions, .ready, .insufficientStorage,
             .failed(.unsupportedDevice), .failed(.permissionDenied):
            true
        default:
            false
        }
    }

    var hasActiveCameraPreview: Bool {
        switch lifecycle {
        case .scanning, .pausing, .trackingLost:
            true
        default:
            false
        }
    }

    /// A raw capture may finish only after the collector has accepted enough
    /// real mesh evidence to avoid treating one small fragment as a usable
    /// scan. This is a categorical gate, not a coverage or quality score.
    var canFinishActiveCapture: Bool {
        guard lifecycle == .scanning else {
            return false
        }
        if isDemo || captureMode == .semanticRoom {
            return true
        }
        return rawReadiness.canFinish
    }
}

enum ScannerWorkflowCommand: Sendable {
    case selectCaptureMode(ScanCaptureMode)
    case requestCameraPermission
    case startPreview
    case pausePreview
    case resumePreview
    case finishPreview
    case finishProcessing
    case finishSaving
    case recoverTracking
    case storageAvailable
    case renameReview(String)
    case cancel
}

protocol ScannerWorkflowServing: Sendable {
    func begin() async -> ScannerWorkflowSnapshot
    func resolveCapabilities() async -> ScannerWorkflowSnapshot
    func perform(_ command: ScannerWorkflowCommand) async -> ScannerWorkflowSnapshot
    func currentSnapshot() async -> ScannerWorkflowSnapshot
}

enum DemoScannerScenario: String, Sendable {
    case unavailable
    case ready
    case permissionRequired
    case failure
}

actor DemoScannerWorkflowService: ScannerWorkflowServing {
    private let scenario: DemoScannerScenario
    private var machine = ScanLifecycleMachine()
    private var capabilityState: ScannerCapabilityState = .checking
    private var captureMode: ScanCaptureMode = .rawLiDAR

    init(scenario: DemoScannerScenario) {
        self.scenario = scenario
    }

    func begin() async -> ScannerWorkflowSnapshot {
        machine = ScanLifecycleMachine()
        capabilityState = .checking
        captureMode = .rawLiDAR
        transition(.begin)
        transition(.preparationComplete)
        return snapshot
    }

    func resolveCapabilities() async -> ScannerWorkflowSnapshot {
        applyCapabilities(demoCapabilities)
        return snapshot
    }

    func perform(_ command: ScannerWorkflowCommand) async -> ScannerWorkflowSnapshot {
        switch command {
        case let .selectCaptureMode(mode):
            selectCaptureMode(mode)
        case .requestCameraPermission:
            guard scenario == .permissionRequired, machine.state == .requestingPermissions else {
                break
            }
            capabilityState = .available(demoCapabilities.advisories(for: captureMode))
            transition(.permissionsGranted)
        case .startPreview:
            transition(.scanStarted)
        case .pausePreview:
            transition(.pauseRequested)
        case .resumePreview:
            transition(.resumeRequested)
        case .finishPreview:
            transition(.scanFinished)
        case .finishProcessing:
            transition(.processingFinished)
        case .finishSaving:
            transition(.saveSucceeded)
        case .recoverTracking:
            transition(.trackingRecovered)
        case .storageAvailable:
            transition(.storageAvailable)
        case .renameReview:
            break
        case .cancel:
            guard !machine.state.isTerminal else {
                break
            }
            transition(.cancel)
        }

        return snapshot
    }

    func currentSnapshot() async -> ScannerWorkflowSnapshot {
        snapshot
    }

    private func applyCapabilities(_ capabilities: DeviceCapabilities) {
        switch capabilities.availability(for: captureMode) {
        case .available:
            capabilityState = .available(capabilities.advisories(for: captureMode))
            transition(.capabilitiesAvailable)
            transition(.permissionsGranted)

            if scenario == .failure {
                transition(.fail(.interrupted))
            }
        case .requiresCameraPermission:
            capabilityState = .requiresCameraPermission
            transition(.capabilitiesAvailable)
        case let .unavailable(issues):
            capabilityState = .unavailable(issues)
            transition(.capabilitiesUnavailable)
        }
    }

    private func selectCaptureMode(_ mode: ScanCaptureMode) {
        guard mode != captureMode, snapshot.canSelectCaptureMode else {
            return
        }

        captureMode = mode
        machine = ScanLifecycleMachine()
        capabilityState = .checking
        transition(.begin)
        transition(.preparationComplete)
        applyCapabilities(demoCapabilities)
    }

    private var demoCapabilities: DeviceCapabilities {
        switch scenario {
        case .unavailable:
            DeviceCapabilities(
                lidarAvailable: false,
                sceneReconstructionAvailable: true,
                sceneDepthAvailable: true,
                roomPlanAvailable: true,
                cameraAuthorization: .notDetermined,
                motionTrackingAvailable: true,
                locationAuthorization: .notDetermined,
                availableStorageBytes: 1_000_000_000,
                minimumRequiredStorageBytes: 250_000_000
            )
        case .ready, .failure:
            DeviceCapabilities.supported(cameraAuthorization: .authorized)
        case .permissionRequired:
            DeviceCapabilities.supported(cameraAuthorization: .notDetermined)
        }
    }

    private var snapshot: ScannerWorkflowSnapshot {
        ScannerWorkflowSnapshot(
            lifecycle: machine.state,
            capability: capabilityState,
            captureMode: captureMode,
            isDemo: true,
            pendingReview: nil,
            completedScanID: nil,
            rawCoverage: .inactive,
            rawObservationFootprint: .inactive,
            rawReadiness: .inactive,
            rawGuidance: .inactive
        )
    }

    private func transition(_ event: ScanLifecycleEvent) {
        do {
            try machine.send(event)
        } catch {
            machine = ScanLifecycleMachine(state: .failed(.unknown))
        }
    }
}

@MainActor
@Observable
final class ScannerWorkflowModel {
    private let service: any ScannerWorkflowServing
    private let rawPreviewSession: ARSession?
    private let semanticPreviewView: UIView?

    private(set) var snapshot: ScannerWorkflowSnapshot

    init(
        service: any ScannerWorkflowServing,
        isDemo: Bool = false,
        rawPreviewSession: ARSession? = nil,
        semanticPreviewView: UIView? = nil
    ) {
        self.service = service
        self.rawPreviewSession = rawPreviewSession
        self.semanticPreviewView = semanticPreviewView
        snapshot = ScannerWorkflowSnapshot(
            lifecycle: .idle,
            capability: .checking,
            captureMode: .rawLiDAR,
            isDemo: isDemo,
            pendingReview: nil,
            completedScanID: nil,
            rawCoverage: .inactive,
            rawObservationFootprint: .inactive,
            rawReadiness: .inactive,
            rawGuidance: .inactive
        )
    }

    var previewSession: ARSession? {
        snapshot.captureMode == .rawLiDAR ? rawPreviewSession : nil
    }

    var roomCapturePreview: UIView? {
        snapshot.captureMode == .semanticRoom ? semanticPreviewView : nil
    }

    func activate() async {
        snapshot = await service.begin()
        guard !Task.isCancelled else {
            return
        }

        snapshot = await service.resolveCapabilities()
    }

    func perform(_ command: ScannerWorkflowCommand) async {
        let nextSnapshot = await service.perform(command)
        guard !Task.isCancelled else {
            return
        }

        snapshot = nextSnapshot
    }

    func refresh() async {
        let nextSnapshot = await service.currentSnapshot()
        guard !Task.isCancelled else {
            return
        }
        snapshot = nextSnapshot
    }
}

struct SettingsViewState: Equatable, Sendable {
    let captureAdapterSummary: String
    let storageSummary: String
    let privacySummary: String
    let buildSummary: String
}

protocol SettingsProviding: Sendable {
    func currentSettings() -> SettingsViewState
}

struct DemoSettingsService: SettingsProviding {
    func currentSettings() -> SettingsViewState {
        SettingsViewState(
            captureAdapterSummary: "Preview mode",
            storageSummary: "Sample scans stay in memory",
            privacySummary: "Local demo data stays in memory and is never sent over the network.",
            buildSummary: "Preview"
        )
    }
}

@MainActor
protocol ScanCaptureSessionServing: AnyObject {
    var essentialEvents: AsyncStream<ScanCaptureEvent> { get }
    var events: AsyncStream<ScanCaptureEvent> { get }

    func currentCapabilities() async -> DeviceCapabilities
    func requestCameraAuthorization() async -> PermissionAuthorization
    func configureVideoRecording(outputURL: URL) throws
    func start() throws
    func pause()
    func resume() throws
    func finishKeyframeCapture() async
    func stop()
    func finishVideoRecording() async throws -> URL
    func cancelVideoRecording()
}

extension ARKitCaptureAdapter: ScanCaptureSessionServing {}

@MainActor
protocol SemanticRoomCaptureSessionServing: AnyObject {
    func start() throws
    func finishAndExport(to outputURL: URL) async throws
    func cancel() async
}

extension RoomPlanCaptureAdapter: SemanticRoomCaptureSessionServing {}

actor LocalScanLibraryService: ScanLibraryServing {
    private let repository: LocalScanRepository
    private let assetStore: FileAssetStore

    init(repository: LocalScanRepository, assetStore: FileAssetStore) {
        self.repository = repository
        self.assetStore = assetStore
    }

    func loadLibrary() async -> LibraryLoadResult {
        do {
            let metadata = try await repository.list()
            var items: [ScanLibraryItem] = []
            items.reserveCapacity(metadata.count)

            for scan in metadata {
                guard let storedScan = try await repository.reopen(id: scan.id) else {
                    return .failure(
                        LibraryFailureState(
                            title: "Could not load scans",
                            message: "An indexed local scan package is no longer available."
                        )
                    )
                }

                var displayedScan = storedScan.scan
                if !storedScan.integrity.isValid {
                    displayedScan.status = .corrupted
                }
                let packageBytes = try await assetStore.packageByteCount(id: scan.id)
                let thumbnailAsset = storedScan.integrity.isValid
                    ? storedScan.manifest.assets.first(where: { $0.kind == .thumbnail })
                    : nil
                let thumbnailState: ScanThumbnailState = thumbnailAsset == nil ? .unavailable : .ready
                let thumbnailURL: URL?
                if let thumbnailAsset {
                    let packageURL = try await assetStore.packageURL(for: scan.id)
                    thumbnailURL = packageURL.appending(path: thumbnailAsset.relativePath)
                } else {
                    thumbnailURL = nil
                }
                items.append(
                    ScanLibraryItem(
                        scan: displayedScan,
                        storageByteCount: packageBytes,
                        thumbnailState: thumbnailState,
                        thumbnailURL: thumbnailURL,
                        assetState: ScanAssetStateResolver().resolve(
                            metadata: displayedScan,
                            manifest: storedScan.manifest,
                            integrity: storedScan.integrity
                        ),
                        summary: ScanSummary(manifest: storedScan.manifest)
                    )
                )
            }
            return .success(items)
        } catch {
            return .failure(
                LibraryFailureState(
                    title: "Could not load scans",
                    message: "Local scan metadata or packages could not be opened. Check available storage and try again."
                )
            )
        }
    }
}

/// Keeps user-initiated scanner commands in FIFO order. A finish operation can
/// await AVFoundation or RoomPlan; a subsequent cancel must not remove its
/// working directory until that operation has relinquished it.
private actor ScannerWorkflowCommandGate {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isOccupied else {
            isOccupied = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isOccupied = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

/// Captures immutable runtime provenance at workflow construction so every
/// persisted scan can be attributed to the build and device that produced it.
private enum RuntimeSourceDeviceInfo {
    @MainActor
    static func current(
        bundle: Bundle = .main,
        device: UIDevice = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SourceDeviceInfo {
        let modelIdentifier = environment["SIMULATOR_MODEL_IDENTIFIER"]
            ?? hardwareModelIdentifier()
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let buildCommit = bundle.object(forInfoDictionaryKey: "StrataScanBuildCommit") as? String
        let appVersion: String
        switch (shortVersion?.nonEmpty, buildVersion?.nonEmpty) {
        case let (.some(short), .some(build)):
            appVersion = "\(short) (\(build))"
        case let (.some(short), .none):
            appVersion = short
        case let (.none, .some(build)):
            appVersion = "build \(build)"
        case (.none, .none):
            appVersion = "unknown"
        }
        return SourceDeviceInfo(
            modelIdentifier: modelIdentifier.nonEmpty ?? "unknown",
            operatingSystemVersion: "\(device.systemName) \(device.systemVersion)",
            appVersion: appVersion,
            operatingSystemBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            appBuildCommit: buildCommit?.nonEmpty
        )
    }

    private static func hardwareModelIdentifier() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Owns one selected capture adapter, its staging handoff, and local persistence.
/// SwiftUI only sends commands and renders lifecycle snapshots.
@MainActor
final class LocalScannerWorkflowService: ScannerWorkflowServing {
    private let repository: LocalScanRepository
    private let assetStore: FileAssetStore?
    private let captureWorkingRootURL: URL
    private let captureAdapter: any ScanCaptureSessionServing
    private let semanticCaptureAdapter: (any SemanticRoomCaptureSessionServing)?
    private let fileManager: FileManager
    private let reconstructionCoordinator: (any AppReconstructionCoordinating)?
    private let sourceDeviceInfo: SourceDeviceInfo
    private let commandGate = ScannerWorkflowCommandGate()

    private var machine = ScanLifecycleMachine()
    private var capabilityState: ScannerCapabilityState = .checking
    private var captureMode: ScanCaptureMode = .rawLiDAR
    private var collector: ScanCaptureAssetCollector?
    private var stagedArtifacts: CaptureArtifactBundle?
    private var captureID: UUID?
    private var captureStartedAt: Date?
    private var captureWorkingDirectory: URL?
    private var hasSavedLocalPackage = false
    private var packageSaveID: UUID?
    private var pendingReview: CaptureReviewSnapshot?
    private var completedScanID: UUID?
    private var rawCoverage: RawCaptureCoverage = .inactive
    private var observedMeshAnchorIDs: Set<UUID> = []
    private var rawObservationFootprintEvaluator = RawCaptureObservationFootprintEvaluator()
    private var rawMeshReadiness = RawMeshReadinessEvaluator()
    private var rawGuidanceEvaluator = RawCaptureGuidanceEvaluator()

    /// The essential task is the sole persistence consumer. The presentation
    /// task may receive coalesced values and never writes package data.
    private var captureEssentialEventTask: Task<Void, Never>?
    private var captureEventTask: Task<Void, Never>?

    /// Owned while FileAssetStore copies the finalized staging files. Cancellation
    /// waits for it before removing staging so package finalization remains atomic.
    private var packageSaveTask: Task<Bool, Never>?

    init(
        repository: LocalScanRepository,
        assetStore: FileAssetStore? = nil,
        captureWorkingRootURL: URL,
        captureAdapter: any ScanCaptureSessionServing,
        semanticCaptureAdapter: (any SemanticRoomCaptureSessionServing)? = nil,
        reconstructionCoordinator: (any AppReconstructionCoordinating)? = nil,
        fileManager: FileManager = .default,
        sourceDeviceInfo: SourceDeviceInfo? = nil
    ) {
        self.repository = repository
        self.assetStore = assetStore
        self.captureWorkingRootURL = captureWorkingRootURL
        self.captureAdapter = captureAdapter
        self.semanticCaptureAdapter = semanticCaptureAdapter
        self.reconstructionCoordinator = reconstructionCoordinator
        self.fileManager = fileManager
        self.sourceDeviceInfo = sourceDeviceInfo ?? RuntimeSourceDeviceInfo.current()
    }

    deinit {
        captureEssentialEventTask?.cancel()
        captureEventTask?.cancel()
    }

    func begin() async -> ScannerWorkflowSnapshot {
        await commandGate.acquire()
        await discardActiveCapture()
        machine = ScanLifecycleMachine()
        capabilityState = .checking
        captureMode = .rawLiDAR
        resetRawCoverage()
        pendingReview = nil
        completedScanID = nil
        transition(.begin)
        transition(.preparationComplete)
        let currentSnapshot = snapshot
        await commandGate.release()
        return currentSnapshot
    }

    func resolveCapabilities() async -> ScannerWorkflowSnapshot {
        await commandGate.acquire()
        let capabilities = await currentCapabilities()
        applyInitialCapabilities(capabilities)
        let currentSnapshot = snapshot
        await commandGate.release()
        return currentSnapshot
    }

    func perform(_ command: ScannerWorkflowCommand) async -> ScannerWorkflowSnapshot {
        await commandGate.acquire()
        switch command {
        case let .selectCaptureMode(mode):
            await selectCaptureMode(mode)
        case .requestCameraPermission:
            await requestCameraPermission()
        case .startPreview:
            await startCapture()
        case .pausePreview:
            pauseCapture()
        case .resumePreview:
            resumeCapture()
        case .finishPreview:
            await finishCapture()
        case .finishProcessing:
            await saveCapture()
        case .finishSaving:
            completeSave()
        case .recoverTracking:
            recoverTracking()
        case .storageAvailable:
            await recheckStorage()
        case let .renameReview(name):
            renameReview(to: name)
        case .cancel:
            await cancelCapture()
        }
        let currentSnapshot = snapshot
        await commandGate.release()
        return currentSnapshot
    }

    func currentSnapshot() async -> ScannerWorkflowSnapshot {
        snapshot
    }

    private var snapshot: ScannerWorkflowSnapshot {
        ScannerWorkflowSnapshot(
            lifecycle: machine.state,
            capability: capabilityState,
            captureMode: captureMode,
            isDemo: false,
            pendingReview: pendingReview,
            completedScanID: completedScanID,
            rawCoverage: rawCoverage,
            rawObservationFootprint: captureMode == .rawLiDAR
                ? rawObservationFootprintEvaluator.footprint
                : .inactive,
            rawReadiness: rawMeshReadiness.readiness,
            rawGuidance: rawGuidanceEvaluator.guidance(
                coverage: rawCoverage,
                captureMode: captureMode,
                lifecycle: machine.state
            )
        )
    }

    /// Coverage is intentionally a small, live-only state machine. It informs
    /// the operator which ARKit spatial inputs have arrived without presenting
    /// a fabricated completion or accuracy score.
    private func resetRawCoverage() {
        rawCoverage = .inactive
        observedMeshAnchorIDs.removeAll(keepingCapacity: false)
        rawObservationFootprintEvaluator.reset()
        rawMeshReadiness.reset()
        rawGuidanceEvaluator.reset()
    }

    private func updateRawCoverage(for tracking: FrameTrackingState) {
        guard captureMode == .rawLiDAR else {
            return
        }

        switch tracking {
        case .normal where rawCoverage == .trackingUnavailable:
            rawCoverage = observedMeshAnchorIDs.isEmpty
                ? .waitingForSpatialData
                : .meshObserved(meshAnchorCount: observedMeshAnchorIDs.count)
        case .limited, .notAvailable:
            rawCoverage = .trackingUnavailable
        case .normal:
            break
        }
    }

    private func updateRawCoverage(for packet: CaptureFramePacket) {
        guard captureMode == .rawLiDAR else {
            return
        }
        rawGuidanceEvaluator.observe(frame: packet, receivedAt: .now)
        guard rawCoverage == .waitingForSpatialData,
              let depth = packet.depth,
              depth.depthMeters.contains(where: { $0.isFinite && $0 > 0 })
        else { return }
        rawCoverage = .depthObserved
    }

    private func updateRawCoverage(for mesh: MeshSnapshot) {
        guard captureMode == .rawLiDAR, !mesh.vertices.isEmpty else {
            return
        }

        observedMeshAnchorIDs.insert(mesh.anchorID)
        rawObservationFootprintEvaluator.observe(mesh)
        rawMeshReadiness.observe(mesh)
        rawCoverage = .meshObserved(meshAnchorCount: observedMeshAnchorIDs.count)
        rawGuidanceEvaluator.observe(mesh: mesh, receivedAt: .now)
    }

    private func currentCapabilities() async -> DeviceCapabilities {
        await captureAdapter.currentCapabilities()
    }

    private func captureAvailability(for capabilities: DeviceCapabilities) -> ScanAvailability {
        guard captureMode == .semanticRoom, semanticCaptureAdapter == nil else {
            return capabilities.availability(for: captureMode)
        }

        var unavailableSemanticCapabilities = capabilities
        unavailableSemanticCapabilities.roomPlanAvailable = false
        return unavailableSemanticCapabilities.availability(for: captureMode)
    }

    private func applyInitialCapabilities(_ capabilities: DeviceCapabilities) {
        guard machine.state == .capabilityChecking else {
            return
        }

        switch captureAvailability(for: capabilities) {
        case .available:
            capabilityState = .available(capabilities.advisories(for: captureMode))
            transition(.capabilitiesAvailable)
            transition(.permissionsGranted)
        case .requiresCameraPermission:
            capabilityState = .requiresCameraPermission
            transition(.capabilitiesAvailable)
        case let .unavailable(issues):
            capabilityState = .unavailable(issues)
            transition(.capabilitiesUnavailable)
        }
    }

    private func requestCameraPermission() async {
        guard machine.state == .requestingPermissions,
              capabilityState == .requiresCameraPermission
        else {
            return
        }

        let authorization = await captureAdapter.requestCameraAuthorization()
        let capabilities = await currentCapabilities()
        switch captureAvailability(for: capabilities) {
        case .available:
            capabilityState = .available(capabilities.advisories(for: captureMode))
            transition(.permissionsGranted)
        case .requiresCameraPermission:
            capabilityState = .requiresCameraPermission
        case let .unavailable(issues):
            capabilityState = .unavailable(issues)
            if authorization == .denied || authorization == .restricted
                || capabilities.cameraAuthorization == .denied || capabilities.cameraAuthorization == .restricted {
                transition(.permissionsDenied)
            } else {
                fail(.unsupportedDevice)
            }
        }
    }

    private func selectCaptureMode(_ mode: ScanCaptureMode) async {
        guard mode != captureMode, snapshot.canSelectCaptureMode else {
            return
        }

        await discardActiveCapture()
        captureMode = mode
        resetRawCoverage()
        machine = ScanLifecycleMachine()
        capabilityState = .checking
        transition(.begin)
        transition(.preparationComplete)
        applyInitialCapabilities(await currentCapabilities())
    }

    private func startCapture() async {
        guard machine.state == .ready else {
            return
        }

        switch captureMode {
        case .rawLiDAR:
            await startRawCapture()
        case .semanticRoom:
            await startSemanticRoomCapture()
        }
    }

    private func startRawCapture() async {
        let id = UUID()
        let workingDirectory = captureWorkingRootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
        do {
            let collector = try ScanCaptureAssetCollector(workingDirectory: workingDirectory)
            captureID = id
            captureStartedAt = .now
            captureWorkingDirectory = workingDirectory
            self.collector = collector
            stagedArtifacts = nil
            hasSavedLocalPackage = false
            pendingReview = nil
            completedScanID = nil
            rawCoverage = .waitingForSpatialData
            observedMeshAnchorIDs.removeAll(keepingCapacity: true)
            rawObservationFootprintEvaluator.reset()
            rawMeshReadiness.reset()
            startEventConsumer(captureID: id, collector: collector)
            // The adapter may synchronously yield its initial tracking or sensor
            // event from `start()`. Enter scanning first so that event is not
            // silently ignored by the lifecycle reducer.
            transition(.scanStarted)
            try captureAdapter.start()
        } catch {
            await cancelEventConsumer()
            await discardActiveCapture()
            fail(.unsupportedDevice)
        }
    }

    private func startSemanticRoomCapture() async {
        guard let semanticCaptureAdapter else {
            fail(.unsupportedDevice)
            return
        }

        let id = UUID()
        let workingDirectory = captureWorkingRootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            captureID = id
            captureStartedAt = .now
            captureWorkingDirectory = workingDirectory
            collector = nil
            stagedArtifacts = nil
            hasSavedLocalPackage = false
            pendingReview = nil
            completedScanID = nil
            resetRawCoverage()
            try semanticCaptureAdapter.start()
            transition(.scanStarted)
        } catch {
            await discardActiveCapture()
            fail(.unsupportedDevice)
        }
    }

    private func pauseCapture() {
        guard captureMode == .rawLiDAR, machine.state == .scanning else {
            return
        }
        captureAdapter.pause()
        transition(.pauseRequested)
    }

    private func resumeCapture() {
        guard captureMode == .rawLiDAR, machine.state == .pausing else {
            return
        }
        do {
            try captureAdapter.resume()
            transition(.resumeRequested)
        } catch {
            fail(.interrupted)
        }
    }

    private func finishCapture() async {
        guard snapshot.canFinishActiveCapture else {
            return
        }

        switch captureMode {
        case .rawLiDAR:
            await finishRawCapture()
        case .semanticRoom:
            await finishSemanticRoomCapture()
        }
    }

    private func finishRawCapture() async {
        guard let collector else {
            fail(.processingFailed)
            return
        }

        // Stop new AR delivery first, then let the bounded image encoder drain
        // its already-owned copies while the collector is still consuming.
        captureAdapter.pause()
        await captureAdapter.finishKeyframeCapture()
        captureAdapter.stop()
        await stopEventConsumer()

        do {
            stagedArtifacts = try await collector.finalize(videoFileURL: nil)
            prepareReview()
            transition(.scanFinished)
        } catch ScanCaptureAssetCollectorError.noSpatialData {
            await discardActiveCapture()
            fail(.noSpatialData)
        } catch {
            fail(.processingFailed)
        }
    }

    private func finishSemanticRoomCapture() async {
        guard let semanticCaptureAdapter,
              let workingDirectory = captureWorkingDirectory,
              let captureID
        else {
            fail(.processingFailed)
            return
        }

        let outputURL = workingDirectory.appending(path: "room/semantic-room.usdz")
        do {
            try await semanticCaptureAdapter.finishAndExport(to: outputURL)
            guard self.captureID == captureID,
                  machine.state == .scanning,
                  !Task.isCancelled
            else {
                try? fileManager.removeItem(at: workingDirectory)
                return
            }
            let values = try outputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                fail(.processingFailed)
                return
            }
            stagedArtifacts = CaptureArtifactBundle(
                assets: [
                    CapturedAssetFile(
                        kind: .semanticRoom,
                        relativePath: "room/semantic-room.usdz",
                        fileURL: outputURL,
                        spatialReference: .scanLocal
                    )
                ],
                statistics: CaptureStatistics()
            )
            prepareReview()
            transition(.scanFinished)
        } catch {
            fail(.processingFailed)
        }
    }

    private func saveCapture() async {
        guard machine.state == .processing,
              let artifacts = stagedArtifacts,
              let id = captureID,
              let review = pendingReview
        else {
            return
        }

        transition(.processingFinished)
        let savedAt = Date.now
        let isSemanticRoom = captureMode == .semanticRoom
        let metadata = ScanMetadata(
            id: id,
            displayName: review.displayName,
            status: .completed,
            createdAt: review.capturedAt,
            updatedAt: savedAt,
            durationSeconds: review.durationSeconds
        )
        let manifest = ScanPackageManifest(
            localScanID: id,
            status: .completed,
            createdAt: review.capturedAt,
            updatedAt: savedAt,
            durationSeconds: metadata.durationSeconds,
            sourceDevice: sourceDeviceInfo,
            coordinateSystem: isSemanticRoom
                ? "RoomPlan semantic room coordinates; no ARKit world transform is inferred."
                : "ARKit right-handed meters; column-major worldFromLocal",
            cameraMetadataDescription: isSemanticRoom
                ? "No raw ARKit frame metadata is retained for this semantic room capture."
                : "Sampled frame metadata and calibrated RGB-D keyframes record intrinsics and worldFromCamera.",
            captureStatistics: artifacts.statistics,
            qualitySignals: artifacts.qualitySignals,
            captureTelemetry: artifacts.captureTelemetry
        )
        let assets = artifacts.assets.map {
            AssetInput(
                kind: $0.kind,
                relativePath: $0.relativePath,
                fileURL: $0.fileURL,
                spatialReference: $0.spatialReference
            )
        }

        let saveID = UUID()
        packageSaveID = saveID
        let saveTask = Task {
            do {
                try await repository.save(scan: metadata, manifest: manifest, assets: assets)
                await enqueueReconstructionIfEligible(scanID: id)
                return true
            } catch {
                return false
            }
        }
        packageSaveTask = saveTask
        let didSave = await saveTask.value
        guard packageSaveID == saveID else {
            return
        }
        packageSaveTask = nil
        packageSaveID = nil

        if didSave {
            hasSavedLocalPackage = true
        } else {
            fail(.saveFailed)
        }
    }

    private func enqueueReconstructionIfEligible(scanID: UUID) async {
        guard let assetStore, let reconstructionCoordinator else { return }
        do {
            guard let stored = try await repository.reopen(id: scanID),
                  stored.integrity.isValid
            else { return }
            let packageURL = try await assetStore.packageURL(for: scanID)
            let archive = try CalibratedRGBDKeyframeArchiveReader().open(
                packageURL: packageURL,
                manifest: stored.manifest,
                integrity: stored.integrity
            )
            guard archive.reconstructionSource.keyframeCount > 0 else { return }
            _ = await reconstructionCoordinator.enqueue(scanID: scanID, automatic: true)
        } catch {
            // A valid saved package remains usable through its point-cloud fallback.
        }
    }

    private func completeSave() {
        guard machine.state == .saving, hasSavedLocalPackage else {
            fail(.saveFailed)
            return
        }
        completedScanID = captureID
        transition(.saveSucceeded)
        releaseSavedCaptureResources()
    }

    private func renameReview(to name: String) {
        guard machine.state == .processing,
              var review = pendingReview
        else {
            return
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        review = CaptureReviewSnapshot(
            id: review.id,
            displayName: trimmedName,
            capturedAt: review.capturedAt,
            durationSeconds: review.durationSeconds,
            captureMode: review.captureMode,
            statistics: review.statistics,
            artifacts: review.artifacts
        )
        pendingReview = review
    }

    private func prepareReview() {
        guard let id = captureID,
              let startedAt = captureStartedAt,
              let artifacts = stagedArtifacts
        else {
            fail(.processingFailed)
            return
        }

        let completedAt = Date.now
        let captureLabel = captureMode == .semanticRoom ? "Room" : "Scan"
        let reviewArtifacts = artifacts.assets.compactMap { asset -> CaptureReviewArtifact? in
            guard asset.kind != .manifestAttachment else { return nil }
            guard let byteCount = try? asset.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return nil
            }
            return CaptureReviewArtifact(
                kind: asset.kind,
                relativePath: asset.relativePath,
                byteCount: Int64(byteCount)
            )
        }
        pendingReview = CaptureReviewSnapshot(
            id: id,
            displayName: "\(captureLabel) \(id.uuidString.prefix(8))",
            capturedAt: startedAt,
            durationSeconds: max(0, completedAt.timeIntervalSince(startedAt)),
            captureMode: captureMode,
            statistics: artifacts.statistics,
            artifacts: reviewArtifacts.sorted { $0.relativePath < $1.relativePath }
        )
    }

    private func recoverTracking() {
        guard captureMode == .rawLiDAR, machine.state == .trackingLost else {
            return
        }
        // ARKit continues running while tracking is limited. Calling `run` here
        // restarts an already active session and can prolong initialization.
        // A transition back to scanning happens only when ARKit reports normal
        // tracking through the capture-event stream.
    }

    private func recheckStorage() async {
        guard machine.state == .insufficientStorage else {
            return
        }

        let capabilities = await currentCapabilities()
        switch captureAvailability(for: capabilities) {
        case .available:
            capabilityState = .available(capabilities.advisories(for: captureMode))
            transition(.storageAvailable)
        case .requiresCameraPermission:
            capabilityState = .requiresCameraPermission
        case let .unavailable(issues):
            capabilityState = .unavailable(issues)
        }
    }

    private func cancelCapture() async {
        await discardActiveCapture()
        guard !machine.state.isTerminal else {
            return
        }
        transition(.cancel)
    }

    private func startEventConsumer(captureID: UUID, collector: ScanCaptureAssetCollector) {
        let essentialEvents = captureAdapter.essentialEvents
        captureEssentialEventTask = Task { [weak self] in
            for await event in essentialEvents {
                guard !Task.isCancelled else { return }
                do {
                    try await collector.consume(event)
                } catch {
                    self?.essentialCaptureFailed(captureID: captureID)
                    return
                }
                if case .captureEnded = event {
                    return
                }
            }
        }

        let events = captureAdapter.events
        captureEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else {
                    return
                }
                let shouldStop = await self?.consume(event, captureID: captureID) ?? true
                if shouldStop {
                    return
                }
            }
        }
    }

    private func consume(
        _ event: ScanCaptureEvent,
        captureID: UUID
    ) async -> Bool {
        guard self.captureID == captureID, !Task.isCancelled else {
            return true
        }

        switch event {
        case let .tracking(tracking):
            updateRawCoverage(for: tracking)
            switch tracking {
            case .normal where machine.state == .trackingLost:
                transition(.trackingRecovered)
            case .limited where machine.state == .scanning,
                 .notAvailable where machine.state == .scanning:
                transition(.trackingDegraded)
            default:
                break
            }
        case .interruptionBegan:
            captureAdapter.stop()
            fail(.interrupted)
        case let .failed(message):
            captureAdapter.stop()
            fail(message == "sensorUnavailable" ? .sensorUnavailable : .unknown)
        case .captureEnded:
            return true
        case let .frame(packet):
            updateRawCoverage(for: packet)
        case let .mesh(mesh):
            updateRawCoverage(for: mesh)
        case .meshRemoved, .meshRegistrySnapshot, .telemetry, .interruptionEnded:
            break
        }
        return false
    }

    private func essentialCaptureFailed(captureID: UUID) {
        guard self.captureID == captureID else { return }
        captureAdapter.stop()
        fail(.processingFailed)
    }

    private func stopEventConsumer() async {
        let essentialTask = captureEssentialEventTask
        let task = captureEventTask
        captureEssentialEventTask = nil
        captureEventTask = nil
        if let essentialTask {
            await essentialTask.value
        }
        if let task {
            await task.value
        }
    }

    private func cancelEventConsumer() async {
        let essentialTask = captureEssentialEventTask
        let task = captureEventTask
        captureEssentialEventTask = nil
        captureEventTask = nil
        essentialTask?.cancel()
        task?.cancel()
        if let essentialTask {
            await essentialTask.value
        }
        if let task {
            await task.value
        }
    }

    private func discardActiveCapture() async {
        switch captureMode {
        case .rawLiDAR:
            captureAdapter.stop()
            await stopEventConsumer()
            captureAdapter.cancelVideoRecording()
            await collector?.cancel()
        case .semanticRoom:
            if let semanticCaptureAdapter {
                await semanticCaptureAdapter.cancel()
            }
            await cancelEventConsumer()
        }
        await waitForPackageSave()
        removeCaptureWorkingDirectory()
        collector = nil
        stagedArtifacts = nil
        captureID = nil
        captureStartedAt = nil
        captureWorkingDirectory = nil
        hasSavedLocalPackage = false
        pendingReview = nil
        completedScanID = nil
        resetRawCoverage()
    }

    private func releaseSavedCaptureResources() {
        removeCaptureWorkingDirectory()
        collector = nil
        stagedArtifacts = nil
        captureID = nil
        captureStartedAt = nil
        captureWorkingDirectory = nil
        hasSavedLocalPackage = false
        pendingReview = nil
        packageSaveTask = nil
        packageSaveID = nil
    }

    private func removeCaptureWorkingDirectory() {
        guard let captureWorkingDirectory,
              fileManager.fileExists(atPath: captureWorkingDirectory.path)
        else {
            return
        }
        try? fileManager.removeItem(at: captureWorkingDirectory)
    }

    private func waitForPackageSave() async {
        let saveTask = packageSaveTask
        let saveID = packageSaveID
        if let saveTask {
            _ = await saveTask.value
        }
        guard packageSaveID == saveID else {
            return
        }
        packageSaveTask = nil
        packageSaveID = nil
    }

    private func transition(_ event: ScanLifecycleEvent) {
        do {
            try machine.send(event)
        } catch {
            machine = ScanLifecycleMachine(state: .failed(.unknown))
        }
    }

    private func fail(_ reason: ScanFailureReason) {
        guard !machine.state.isTerminal else {
            return
        }
        transition(.fail(reason))
    }
}

struct LocalSettingsService: SettingsProviding {
    let storageAvailable: Bool

    func currentSettings() -> SettingsViewState {
        SettingsViewState(
            captureAdapterSummary: "Raw ARKit capture is checked when the scanner opens.",
            storageSummary: storageAvailable
                ? "SQLite metadata and managed scan packages stay on this device."
                : "Local scan storage could not be initialized.",
            privacySummary: "Capture data stays local unless a future user-initiated sync workflow is configured.",
            buildSummary: "Local-first runtime"
        )
    }
}

struct LocalStartupFailureLibraryService: ScanLibraryServing {
    func loadLibrary() async -> LibraryLoadResult {
        .failure(
            LibraryFailureState(
                title: "Could not open local storage",
                message: "StrataScan could not initialize local metadata or package storage."
            )
        )
    }
}

struct LocalStartupFailureScanComparisonDraftService: ScanComparisonDraftServing {
    func saveDraft(baselineScanID: UUID, comparisonScanID: UUID) async -> ScanComparisonDraftSaveResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not save comparison",
                message: "Local storage is not ready to save a comparison draft."
            )
        )
    }

    func loadLatestDraft() async -> ScanComparisonDraftLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not load comparison",
                message: "Local storage is not ready to read a comparison draft."
            )
        )
    }

    func saveWorkArea(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaSaveResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not set work area",
                message: "Local storage is not ready to define a work area."
            )
        )
    }

    func loadWorkArea(forDraftID draftID: UUID) async -> ScanComparisonWorkAreaLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not load work area",
                message: "Local storage is not ready to read a work area."
            )
        )
    }

    func loadWorkAreaWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonWorkAreaWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not open work area",
                message: "Local storage is not ready to open the scan mesh."
            )
        )
    }

    func saveRefinedWorkArea(
        for draft: ScanComparisonDraft,
        firstCorner: Point3D,
        oppositeCorner: Point3D
    ) async -> ScanComparisonWorkAreaSaveResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not save work area",
                message: "Local storage is not ready to save a work area."
            )
        )
    }

    func loadAlignmentWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonAlignmentWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not open alignment",
                message: "Local storage is not ready to open scan meshes."
            )
        )
    }

    func saveLandmarkAlignment(
        for draft: ScanComparisonDraft,
        baselineLandmarks: [Point3D],
        comparisonLandmarks: [Point3D]
    ) async -> ScanComparisonAlignmentSaveResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not save alignment",
                message: "Local storage is not ready to save alignment."
            )
        )
    }

    func evaluateCoverage(for draft: ScanComparisonDraft) async -> ScanComparisonCoverageEvaluationResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not check coverage",
                message: "Local storage is not ready to check the mesh."
            )
        )
    }

    func loadReadiness(for draft: ScanComparisonDraft) async -> ScanComparisonReadiness {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not check readiness",
                message: "Local storage is not ready to check the meshes."
            )
        )
    }

    func loadVisualComparisonWorkspace(for draft: ScanComparisonDraft) async -> ScanComparisonVisualWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not review alignment",
                message: "Local storage is not ready to open the meshes."
            )
        )
    }

    func loadSurfaceDifferencePreview(for draft: ScanComparisonDraft) async -> ScanComparisonSurfaceDifferenceWorkspaceLoadResult {
        .failure(
            ScanComparisonDraftFailureState(
                title: "Could not preview differences",
                message: "Local storage is not ready to open the meshes."
            )
        )
    }
}

struct LocalStartupFailureScanDetailService: ScanDetailServing {
    func loadDetail(id: UUID) async -> ScanDetailLoadResult {
        .failure(
            ScanDetailFailureState(
                title: "Could not open local storage",
                message: "StrataScan could not initialize local metadata or package storage."
            )
        )
    }

    func deleteScan(id: UUID) async -> ScanDetailDeleteResult {
        .failure(
            ScanDetailFailureState(
                title: "Could not delete scan",
                message: "StrataScan could not initialize local storage to delete this scan."
            )
        )
    }

    func renameScan(id: UUID, displayName: String) async -> ScanDetailRenameResult {
        .failure(
            ScanDetailFailureState(
                title: "Could not rename scan",
                message: "StrataScan could not initialize local storage to update the scan name."
            )
        )
    }

    func loadPointCloud(id: UUID) async -> PointCloudLoadResult {
        .unavailable(message: "Local storage could not be initialized to open the point cloud.")
    }
}

struct LocalStartupFailureScannerService: ScannerWorkflowServing {
    func begin() async -> ScannerWorkflowSnapshot {
        snapshot
    }

    func resolveCapabilities() async -> ScannerWorkflowSnapshot {
        snapshot
    }

    func perform(_ command: ScannerWorkflowCommand) async -> ScannerWorkflowSnapshot {
        snapshot
    }

    func currentSnapshot() async -> ScannerWorkflowSnapshot {
        snapshot
    }

    private var snapshot: ScannerWorkflowSnapshot {
        ScannerWorkflowSnapshot(
            lifecycle: .failed(.saveFailed),
            capability: .unavailable([]),
            captureMode: .rawLiDAR,
            isDemo: false,
            pendingReview: nil,
            completedScanID: nil,
            rawCoverage: .inactive,
            rawObservationFootprint: .inactive,
            rawReadiness: .inactive,
            rawGuidance: .inactive
        )
    }
}
