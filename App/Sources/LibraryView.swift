import AVKit
import QuickLook
import SwiftUI
import StrataCore
import UIKit

@MainActor
struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    let detailService: any ScanDetailServing
    let comparisonDraftService: any ScanComparisonDraftServing
    let beginScanning: () -> Void
    @Binding private var requestedWorkspaceScanID: UUID?
    @State private var showingComparison = false

    init(
        model: LibraryViewModel,
        detailService: any ScanDetailServing,
        comparisonDraftService: any ScanComparisonDraftServing,
        requestedWorkspaceScanID: Binding<UUID?> = .constant(nil),
        beginScanning: @escaping () -> Void
    ) {
        self.model = model
        self.detailService = detailService
        self.comparisonDraftService = comparisonDraftService
        _requestedWorkspaceScanID = requestedWorkspaceScanID
        self.beginScanning = beginScanning
    }

    var body: some View {
        NavigationStack {
            libraryContent
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(item: $requestedWorkspaceScanID) { scanID in
                    ScanWorkspaceView(
                        scanID: scanID,
                        service: detailService,
                        isDemo: model.isDemo,
                        didDelete: reloadLibrary
                    )
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingComparison = true
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .disabled(availableScans.count < 2)
                        .accessibilityLabel("Compare scans")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: beginScanning) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(
                                    Color(uiColor: .secondarySystemBackground),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("New scan")
                        .accessibilityIdentifier(AccessibilityID.libraryNewScan)
                        .accessibilityHint("Opens the full-screen scan workflow.")
                    }
                }
        }
        .sheet(isPresented: $showingComparison) {
            ScanComparisonSheet(
                scans: availableScans,
                service: comparisonDraftService
            )
        }
        .task {
            await model.loadIfNeeded()
        }
    }

    private var availableScans: [ScanLibraryItem] {
        guard case let .content(scans) = model.state else { return [] }
        return scans
    }

    private func reloadLibrary() {
        Task { @MainActor in
            await model.reload()
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch model.state {
        case .loading:
            LibraryLoadingView()
        case .empty:
            LibraryEmptyView(beginScanning: beginScanning)
        case let .content(scans):
            LibraryList(
                scans: scans,
                detailService: detailService,
                isDemo: model.isDemo
            ) {
                Task { @MainActor in
                    await model.reload()
                }
            }
        case let .failure(error):
            LibraryErrorView(error: error) {
                Task {
                    await model.reload()
                }
            }
        }
    }
}

private struct ScanComparisonSheet: View {
    let scans: [ScanLibraryItem]
    let service: any ScanComparisonDraftServing
    @Environment(\.dismiss) private var dismiss
    @State private var beforeID: UUID?
    @State private var afterID: UUID?
    @State private var latestDraft: ScanComparisonDraft?
    @State private var workArea: ScanComparisonWorkArea?
    @State private var workAreaDraft: ScanComparisonDraft?
    @State private var visualComparisonDraft: ScanComparisonDraft?
    @State private var surfaceDifferenceDraft: ScanComparisonDraft?
    @State private var alignmentDraft: ScanComparisonDraft?
    @State private var coverageResult: ScanComparisonCoverageEvaluationResult?
    @State private var readiness: ScanComparisonReadiness?
    @State private var failure: ScanComparisonDraftFailureState?
    @State private var isSaving = false
    @State private var isSavingWorkArea = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Scans") {
                    Picker("Before", selection: $beforeID) {
                        Text("Choose a scan").tag(UUID?.none)
                        ForEach(scans, id: \.id) { scan in
                            Text(scan.scan.displayName).tag(Optional(scan.id))
                        }
                    }
                    Picker("After", selection: $afterID) {
                        Text("Choose a scan").tag(UUID?.none)
                        ForEach(scans, id: \.id) { scan in
                            Text(scan.scan.displayName).tag(Optional(scan.id))
                        }
                    }
                }

                Section("Status") {
                    if workArea != nil {
                        Label("Work area saved", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("Check alignment and coverage for both scans before calculating.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if beforeID == nil || afterID == nil {
                        Label("Choose two scans", systemImage: "circle.dashed")
                    } else if beforeID == afterID {
                        Label("Choose two different scans", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Label("Ready to save draft", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("Choose a work area after saving the draft.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let latestDraft, let baseline = name(for: latestDraft.baselineScanID), let comparison = name(for: latestDraft.comparisonScanID) {
                    Section("Latest draft") {
                        Label("Selected comparison saved", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("\(baseline) ← \(comparison)")
                            .foregroundStyle(.secondary)
                        if workArea == nil {
                            Button("Use before scan mesh bounds") {
                                Task { await saveWorkArea(for: latestDraft) }
                            }
                            .disabled(isSavingWorkArea)
                        } else {
                            Label("Work area set from before scan mesh bounds", systemImage: "viewfinder")
                                .foregroundStyle(.secondary)
                            Button("Refine 3D work area") {
                                workAreaDraft = latestDraft
                            }
                        }
                        Button("Align with landmarks") {
                            alignmentDraft = latestDraft
                        }
                        Button("Review alignment") {
                            visualComparisonDraft = latestDraft
                        }
                        .disabled(workArea == nil)
                        Button("Surface difference preview") {
                            surfaceDifferenceDraft = latestDraft
                        }
                        .disabled(!canOpenSurfacePreview)
                        Button("Refresh preview readiness") {
                            Task { await loadReadiness(for: latestDraft) }
                        }
                        .disabled(isCheckingReadiness)
                        readinessStatus
                        Button("Check coverage") {
                            Task { await evaluateCoverage(for: latestDraft) }
                        }
                        .disabled(isEvaluatingCoverage)
                        coverageStatus
                    }
                }

                if let failure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } header: {
                        Text(failure.title)
                    }
                }
            }
            .navigationTitle("Compare scans")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Save draft") {
                        Task { await saveDraft() }
                    }
                    .disabled(!canSave || isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await loadLatestDraft()
        }
        .sheet(item: $alignmentDraft, onDismiss: {
            guard let latestDraft else { return }
            Task { await loadReadiness(for: latestDraft) }
        }) { draft in
            ScanLandmarkAlignmentSheet(
                draft: draft,
                baselineName: name(for: draft.baselineScanID) ?? "Before scan",
                comparisonName: name(for: draft.comparisonScanID) ?? "After scan",
                service: service
            )
        }
        .sheet(item: $workAreaDraft) { draft in
            ScanWorkAreaEditorSheet(
                draft: draft,
                baselineName: name(for: draft.baselineScanID) ?? "Before scan",
                service: service,
                didSave: { area in
                    workArea = area
                    coverageResult = nil
                    Task { await loadReadiness(for: draft) }
                }
            )
        }
        .sheet(item: $visualComparisonDraft) { draft in
            ScanComparisonVisualInspectionSheet(
                draft: draft,
                baselineName: name(for: draft.baselineScanID) ?? "Before scan",
                comparisonName: name(for: draft.comparisonScanID) ?? "After scan",
                service: service
            )
        }
        .sheet(item: $surfaceDifferenceDraft) { draft in
            ScanSurfaceDifferencePreviewSheet(
                draft: draft,
                service: service
            )
        }
    }

    private var canSave: Bool {
        guard let beforeID, let afterID else { return false }
        return beforeID != afterID
    }

    private var isEvaluatingCoverage: Bool {
        if case .checking = coverageResult {
            return true
        }
        return false
    }

    private var isCheckingReadiness: Bool {
        if case .checking = readiness {
            return true
        }
        return false
    }

    private var canOpenSurfacePreview: Bool {
        if case .ready = readiness {
            return true
        }
        return false
    }

    @ViewBuilder
    private var readinessStatus: some View {
        switch readiness {
        case .ready:
            Label("Difference preview ready", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            Text("Alignment, coverage, and comparable surfaces checked.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .needsWorkArea:
            Label("Set a work area first", systemImage: "viewfinder")
                .foregroundStyle(.secondary)
        case .needsAlignment:
            Label("Align the scans with landmarks first", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.secondary)
        case let .alignmentNeedsImprovement(status):
            alignmentReadinessStatus(for: status)
        case .needsCoverage:
            Label("After scan geometry has insufficient coverage", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Capture the selected area from more viewpoints in the after scan.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .needsComparableSurfaces:
            Label("No comparable surfaces found", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Review alignment and capture the area from more viewpoints.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .failure(error):
            Label(error.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .checking:
            Label("Checking preview readiness", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func alignmentReadinessStatus(
        for status: ScanComparisonAlignmentQualityReport.Status
    ) -> some View {
        switch status {
        case .supported:
            EmptyView()
        case .landmarkSpreadInsufficient:
            Label("Alignment landmarks are too clustered", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Choose stable landmarks farther apart in both scans.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .landmarkDistributionDegenerate:
            Label("Alignment landmarks have a weak arrangement", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Choose landmarks that do not lie approximately on one line.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .residualTooHigh:
            Label("Alignment error is too high for preview", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Select the shared, stable landmarks again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var coverageStatus: some View {
        switch coverageResult {
        case let .available(report):
            switch report.status {
            case .supported:
                Label("After scan mesh supports the work area", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("This checks mesh extent only. No change result or quantity has been calculated.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .insufficient:
                Label("After scan geometry has insufficient coverage", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Capture the selected area from more viewpoints in the after scan, then check again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .needsWorkArea:
            Label("Set a work area first", systemImage: "viewfinder")
                .foregroundStyle(.secondary)
        case .needsAlignment:
            Label("Align the scans with landmarks first", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.secondary)
        case let .failure(error):
            Label(error.message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .checking:
            Label("Checking mesh coverage", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func name(for scanID: UUID) -> String? {
        scans.first(where: { $0.id == scanID })?.scan.displayName
    }

    private func loadLatestDraft() async {
        switch await service.loadLatestDraft() {
        case let .success(draft):
            latestDraft = draft
            if let draft {
                await loadWorkArea(for: draft.id)
                await loadReadiness(for: draft)
            }
        case let .failure(error):
            failure = error
        }
    }

    private func saveDraft() async {
        guard let beforeID, let afterID, beforeID != afterID else { return }
        isSaving = true
        failure = nil
        defer { isSaving = false }

        switch await service.saveDraft(baselineScanID: beforeID, comparisonScanID: afterID) {
        case let .success(draft):
            latestDraft = draft
            workArea = nil
            coverageResult = nil
            readiness = nil
        case let .failure(error):
            failure = error
        }
    }

    private func loadWorkArea(for draftID: UUID) async {
        switch await service.loadWorkArea(forDraftID: draftID) {
        case let .success(area):
            workArea = area
            coverageResult = nil
        case let .failure(error):
            failure = error
        }
    }

    private func saveWorkArea(for draft: ScanComparisonDraft) async {
        isSavingWorkArea = true
        failure = nil
        defer { isSavingWorkArea = false }

        switch await service.saveWorkArea(for: draft) {
        case let .success(area):
            workArea = area
            coverageResult = nil
            await loadReadiness(for: draft)
        case let .failure(error):
            failure = error
        }
    }

    private func evaluateCoverage(for draft: ScanComparisonDraft) async {
        coverageResult = .checking
        coverageResult = await service.evaluateCoverage(for: draft)
    }

    private func loadReadiness(for draft: ScanComparisonDraft) async {
        readiness = .checking
        readiness = await service.loadReadiness(for: draft)
    }
}

private struct ScanWorkAreaEditorSheet: View {
    let draft: ScanComparisonDraft
    let baselineName: String
    let service: any ScanComparisonDraftServing
    let didSave: (ScanComparisonWorkArea) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: WorkAreaEditorScreenState = .loading
    @State private var firstCorner: Point3D?
    @State private var oppositeCorner: Point3D?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Opening scan mesh")
                case let .failure(failure):
                    ContentUnavailableView(
                        failure.title,
                        systemImage: "exclamationmark.triangle",
                        description: Text(failure.message)
                    )
                case let .ready(workspace):
                    editorContent(workspace: workspace)
                }
            }
            .navigationTitle("Refine 3D work area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveWorkArea() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
        .task {
            await loadWorkspace()
        }
    }

    private func editorContent(workspace: ScanComparisonWorkAreaWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose two opposite corners on the before scan mesh. The teal box shows the new work area.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack(spacing: 8) {
                Label(selectionStatus, systemImage: selectionIcon)
                    .foregroundStyle(canSave ? .green : .secondary)
                Spacer()
                Button("Start over") {
                    firstCorner = nil
                    oppositeCorner = nil
                }
                .disabled(firstCorner == nil && oppositeCorner == nil)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal)

            Text(baselineName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            RawMeshWorkAreaSceneView(
                snapshots: workspace.baselineSnapshots,
                firstCorner: firstCorner,
                oppositeCorner: oppositeCorner,
                onWorldPointSelected: selectCorner
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)

            Text("This changes only the comparison work area. The source mesh and saved alignment stay unchanged.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    private var selectionStatus: String {
        if firstCorner == nil {
            return "Choose the first corner"
        }
        if oppositeCorner == nil {
            return "Choose the opposite corner"
        }
        return "New work area ready to save"
    }

    private var selectionIcon: String {
        canSave ? "checkmark.circle.fill" : "viewfinder"
    }

    private var canSave: Bool {
        firstCorner != nil && oppositeCorner != nil
    }

    private func selectCorner(_ point: Point3D) {
        if firstCorner == nil {
            firstCorner = point
        } else if oppositeCorner == nil {
            oppositeCorner = point
        } else {
            firstCorner = point
            oppositeCorner = nil
        }
    }

    private func loadWorkspace() async {
        switch await service.loadWorkAreaWorkspace(for: draft) {
        case let .success(workspace):
            if let savedWorkArea = workspace.savedWorkArea {
                firstCorner = savedWorkArea.minimum
                oppositeCorner = savedWorkArea.maximum
            }
            state = .ready(workspace)
        case let .failure(failure):
            state = .failure(failure)
        }
    }

    private func saveWorkArea() async {
        guard let firstCorner, let oppositeCorner else { return }
        isSaving = true
        defer { isSaving = false }
        switch await service.saveRefinedWorkArea(
            for: draft,
            firstCorner: firstCorner,
            oppositeCorner: oppositeCorner
        ) {
        case let .success(area):
            didSave(area)
            dismiss()
        case let .failure(failure):
            state = .failure(failure)
        }
    }

    private enum WorkAreaEditorScreenState: Equatable {
        case loading
        case ready(ScanComparisonWorkAreaWorkspace)
        case failure(ScanComparisonDraftFailureState)
    }
}

private struct ScanComparisonVisualInspectionSheet: View {
    let draft: ScanComparisonDraft
    let baselineName: String
    let comparisonName: String
    let service: any ScanComparisonDraftServing

    @Environment(\.dismiss) private var dismiss
    @State private var state: VisualInspectionScreenState = .loading
    @State private var mode: RawMeshComparisonSceneView.DisplayMode = .overlay

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Preparing review")
                case let .failure(failure):
                    ContentUnavailableView(
                        failure.title,
                        systemImage: "exclamationmark.triangle",
                        description: Text(failure.message)
                    )
                case let .ready(workspace):
                    inspectionContent(workspace: workspace)
                }
            }
            .navigationTitle("Review alignment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await loadWorkspace()
        }
    }

    private func inspectionContent(workspace: ScanComparisonVisualWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Show", selection: $mode) {
                Text("Before scan").tag(RawMeshComparisonSceneView.DisplayMode.baseline)
                Text("After scan").tag(RawMeshComparisonSceneView.DisplayMode.comparison)
                Text("Overlay").tag(RawMeshComparisonSceneView.DisplayMode.overlay)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            HStack(spacing: 12) {
                Label(baselineName, systemImage: "circle.fill")
                    .foregroundStyle(.teal)
                Label(comparisonName, systemImage: "circle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.footnote)
            .padding(.horizontal)

            RawMeshComparisonSceneView(
                baselineSnapshots: workspace.baselineSnapshots,
                alignedComparisonSnapshots: workspace.alignedComparisonSnapshots,
                workArea: workspace.workArea,
                mode: mode
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)

            Text("Only captured geometry inside the work area is shown. This view supports alignment review and does not calculate a change result or quantity.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    private func loadWorkspace() async {
        switch await service.loadVisualComparisonWorkspace(for: draft) {
        case let .success(workspace):
            state = .ready(workspace)
        case let .failure(failure):
            state = .failure(failure)
        }
    }

    private enum VisualInspectionScreenState: Equatable {
        case loading
        case ready(ScanComparisonVisualWorkspace)
        case failure(ScanComparisonDraftFailureState)
    }
}

private struct ScanSurfaceDifferencePreviewSheet: View {
    let draft: ScanComparisonDraft
    let service: any ScanComparisonDraftServing

    @Environment(\.dismiss) private var dismiss
    @State private var state: SurfaceDifferencePreviewScreenState = .loading
    @State private var mode: RawMeshSurfaceDifferenceSceneView.DisplayMode = .observedDifferences

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Preparing preview")
                case let .failure(failure):
                    ContentUnavailableView(
                        failure.title,
                        systemImage: "exclamationmark.triangle",
                        description: Text(failure.message)
                    )
                case let .ready(workspace):
                    previewContent(workspace: workspace)
                }
            }
            .navigationTitle("Surface difference preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await loadPreview()
        }
    }

    private func previewContent(workspace: ScanComparisonSurfaceDifferenceWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Show", selection: $mode) {
                Text("Before scan").tag(RawMeshSurfaceDifferenceSceneView.DisplayMode.baselineContext)
                Text("After scan").tag(RawMeshSurfaceDifferenceSceneView.DisplayMode.alignedComparison)
                Text("Observed differences").tag(RawMeshSurfaceDifferenceSceneView.DisplayMode.observedDifferences)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            legend(for: mode)

            RawMeshSurfaceDifferenceSceneView(
                baselineContextSnapshots: workspace.baselineContextSnapshots,
                alignedComparisonContextSnapshots: workspace.alignedComparisonContextSnapshots,
                preview: workspace.preview,
                workArea: workspace.workArea,
                mode: mode
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)

            Text(description(for: mode))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    @ViewBuilder
    private func legend(for mode: RawMeshSurfaceDifferenceSceneView.DisplayMode) -> some View {
        switch mode {
        case .baselineContext:
            Label("Captured before scan surface", systemImage: "circle.fill")
                .foregroundStyle(.secondary)
                .font(.footnote)
                .padding(.horizontal)
        case .alignedComparison:
            Label("Aligned after scan surface", systemImage: "circle.fill")
                .foregroundStyle(.blue)
                .font(.footnote)
                .padding(.horizontal)
        case .observedDifferences:
            HStack(spacing: 12) {
                Label("Coincident with before surface", systemImage: "circle.fill")
                    .foregroundStyle(.teal)
                Label("Along the before surface normal", systemImage: "circle.fill")
                    .foregroundStyle(.orange)
                Label("Against the before surface normal", systemImage: "circle.fill")
                    .foregroundStyle(.purple)
            }
            .font(.footnote)
            .padding(.horizontal)
        }
    }

    private func description(for mode: RawMeshSurfaceDifferenceSceneView.DisplayMode) -> String {
        switch mode {
        case .baselineContext:
            "Only captured before scan geometry inside the work area is shown."
        case .alignedComparison:
            "Only aligned, captured after scan geometry inside the work area is shown."
        case .observedDifferences:
            "Only points with nearby, aligned surfaces are colored. Unmatched areas remain uncolored; this preview is not a quantity or change result."
        }
    }

    private func loadPreview() async {
        switch await service.loadSurfaceDifferencePreview(for: draft) {
        case let .success(workspace):
            state = .ready(workspace)
        case let .failure(failure):
            state = .failure(failure)
        }
    }

    private enum SurfaceDifferencePreviewScreenState: Equatable {
        case loading
        case ready(ScanComparisonSurfaceDifferenceWorkspace)
        case failure(ScanComparisonDraftFailureState)
    }
}

private struct ScanLandmarkAlignmentSheet: View {
    let draft: ScanComparisonDraft
    let baselineName: String
    let comparisonName: String
    let service: any ScanComparisonDraftServing

    @Environment(\.dismiss) private var dismiss
    @State private var state: AlignmentScreenState = .loading
    @State private var baselineLandmarks: [Point3D] = []
    @State private var comparisonLandmarks: [Point3D] = []
    @State private var savedLandmarks: ScanAlignmentLandmarkSet?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Opening scan meshes")
                case let .failure(failure):
                    ContentUnavailableView(
                        failure.title,
                        systemImage: "exclamationmark.triangle",
                        description: Text(failure.message)
                    )
                case let .ready(workspace):
                    alignmentContent(workspace: workspace)
                }
            }
            .navigationTitle("Align scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveAlignment() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
        .task {
            await loadWorkspace()
        }
    }

    @ViewBuilder
    private func alignmentContent(workspace: ScanComparisonAlignmentWorkspace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("For each landmark, tap the same stable, recognizable point in both scans.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack(spacing: 8) {
                Label(
                    "\(EnglishFormat.number(completedPairCount)) of at least 3 landmark pairs",
                    systemImage: completedPairCount >= 3 ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(completedPairCount >= 3 ? .green : .secondary)
                Spacer()
                Button("Undo") { undoLastSelection() }
                    .disabled(baselineLandmarks.isEmpty)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal)

            if choosingBaseline {
                landmarkPicker(
                    title: "1. Choose landmark \(EnglishFormat.number(nextLandmarkNumber)) in the before scan",
                    scanName: baselineName,
                    snapshots: workspace.baselineSnapshots,
                    points: baselineLandmarks,
                    select: { point in baselineLandmarks.append(point) }
                )
            } else {
                landmarkPicker(
                    title: "2. Choose the same landmark \(EnglishFormat.number(nextLandmarkNumber)) in the after scan",
                    scanName: comparisonName,
                    snapshots: workspace.comparisonSnapshots,
                    points: comparisonLandmarks,
                    select: { point in comparisonLandmarks.append(point) }
                )
            }

            if let savedLandmarks {
                Label(
                    "\(EnglishFormat.number(savedLandmarks.targetLandmarks.count)) landmark pairs saved",
                    systemImage: "checkmark.seal"
                )
                .font(.footnote)
                .foregroundStyle(.green)
                .padding(.horizontal)
            }

            Text("This saves a separate transform and does not change either source scan.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    private func landmarkPicker(
        title: String,
        scanName: String,
        snapshots: [MeshSnapshot],
        points: [Point3D],
        select: @escaping (Point3D) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal)
            Text(scanName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            RawMeshLandmarkSceneView(
                snapshots: snapshots,
                selectedPoints: points,
                onWorldPointSelected: select
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
        }
        .frame(maxHeight: .infinity)
    }

    private var choosingBaseline: Bool {
        baselineLandmarks.count == comparisonLandmarks.count
    }

    private var completedPairCount: Int {
        min(baselineLandmarks.count, comparisonLandmarks.count)
    }

    private var nextLandmarkNumber: Int {
        completedPairCount + 1
    }

    private var canSave: Bool {
        completedPairCount >= 3 && baselineLandmarks.count == comparisonLandmarks.count
    }

    private func loadWorkspace() async {
        switch await service.loadAlignmentWorkspace(for: draft) {
        case let .success(workspace):
            if let saved = workspace.savedLandmarks {
                baselineLandmarks = saved.targetLandmarks
                comparisonLandmarks = saved.sourceLandmarks
                savedLandmarks = saved
            }
            state = .ready(workspace)
        case let .failure(failure):
            state = .failure(failure)
        }
    }

    private func undoLastSelection() {
        if baselineLandmarks.count > comparisonLandmarks.count {
            baselineLandmarks.removeLast()
        } else if !comparisonLandmarks.isEmpty {
            baselineLandmarks.removeLast()
            comparisonLandmarks.removeLast()
        }
    }

    private func saveAlignment() async {
        guard canSave else { return }
        isSaving = true
        defer { isSaving = false }
        switch await service.saveLandmarkAlignment(
            for: draft,
            baselineLandmarks: baselineLandmarks,
            comparisonLandmarks: comparisonLandmarks
        ) {
        case let .success(landmarks):
            savedLandmarks = landmarks
        case let .failure(failure):
            state = .failure(failure)
        }
    }

    private enum AlignmentScreenState: Equatable {
        case loading
        case ready(ScanComparisonAlignmentWorkspace)
        case failure(ScanComparisonDraftFailureState)
    }
}

private struct LibraryLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading scans")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier(AccessibilityID.libraryLoading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading scans")
    }
}

private struct LibraryEmptyView: View {
    let beginScanning: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("No scans yet")
                    .font(.title2.weight(.semibold))

                Text("Capture a new scan to get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: beginScanning) {
                    Label("Open scanner", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.libraryOpenScanner)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(AccessibilityID.libraryEmpty)
    }
}

private struct LibraryErrorView: View {
    let error: LibraryFailureState
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text(error.title)
                    .font(.title2.weight(.semibold))

                Text("Please try again.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.libraryRetry)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(AccessibilityID.libraryError)
    }
}

private struct LibraryList: View {
    let scans: [ScanLibraryItem]
    let detailService: any ScanDetailServing
    let isDemo: Bool
    let scanDeleted: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(scans) { scan in
                    NavigationLink {
                        ScanWorkspaceView(
                            scanID: scan.id,
                            service: detailService,
                            isDemo: isDemo,
                            didDelete: scanDeleted
                        )
                    } label: {
                        ScanRow(item: scan)
                    }
                    .accessibilityIdentifier(AccessibilityID.libraryScanRow(scan.id))
                    .accessibilityLabel(accessibilityDescription(for: scan))
                    .accessibilityHint("Opens the saved scan details.")
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            } header: {
                Text("\(EnglishFormat.number(scans.count)) scans")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier(AccessibilityID.libraryList)
    }

    private func accessibilityDescription(for item: ScanLibraryItem) -> String {
        let scan = item.scan
        let created = EnglishFormat.dateTime(scan.createdAt)
        let state = item.assetState?.workspaceDisplayName ?? scan.status.title
        return "\(scan.displayName), status \(state), created \(created), \(EnglishFormat.byteCount(item.storageByteCount))"
    }
}

private struct ScanRow: View {
    let item: ScanLibraryItem

    private var scan: ScanMetadata {
        item.scan
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ScanLibraryPreviewGlyph(item: item)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(scan.displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Spacer(minLength: 4)

                    if let assetState = item.assetState {
                        ScanAssetStateBadge(state: assetState)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        ScanStatusBadge(status: scan.status)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Text("\(EnglishFormat.dateTime(scan.createdAt))  ·  \(EnglishFormat.byteCount(item.storageByteCount))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ScanLibraryPreviewGlyph: View {
    let item: ScanLibraryItem

    private var presentation: (symbol: String, tint: Color, title: String) {
        if item.summary?.meshTriangleCount != nil {
            return ("cube.transparent", .teal, "Saved raw mesh")
        }
        if item.summary?.pointCount != nil {
            return ("circle.grid.3x3", .teal, "Saved point cloud")
        }
        if item.summary?.hasVideo == true {
            return ("video", .purple, "Captured video")
        }
        return ("square.stack.3d.up", .secondary, "Saved scan")
    }

    var body: some View {
        Group {
            if let thumbnailURL,
               let image = UIImage(contentsOfFile: thumbnailURL.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 72, height: 52)
                    .clipped()
            } else {
                Image(systemName: presentation.symbol)
                    .font(.title2)
                    .foregroundStyle(presentation.tint)
                    .frame(width: 72, height: 52)
                    .background(presentation.tint.opacity(0.14))
            }
        }
        .background(presentation.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel(presentation.title)
    }

    private var thumbnailURL: URL? {
        item.thumbnailState == .ready ? item.thumbnailURL : nil
    }
}

@MainActor
struct ScanDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScanDetailViewModel
    @State private var sharedAsset: ScanExportAsset?

    private let didDelete: () -> Void

    init(
        scanID: UUID,
        service: any ScanDetailServing,
        isDemo: Bool,
        didDelete: @escaping () -> Void
    ) {
        _model = State(initialValue: ScanDetailViewModel(scanID: scanID, service: service, isDemo: isDemo))
        self.didDelete = didDelete
    }

    var body: some View {
        @Bindable var model = model

        detailContent
            .navigationTitle(model.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case let .content(detail) = model.state {
                    if !detail.exportableAssets.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                ForEach(detail.exportableAssets) { asset in
                                    Button {
                                        sharedAsset = asset
                                    } label: {
                                        Label(
                                            "Share \(asset.reference.kind.detailDisplayName)",
                                            systemImage: "square.and.arrow.up"
                                        )
                                    }
                                }
                            } label: {
                                Label("Share asset", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityIdentifier(AccessibilityID.scanDetailShare)
                            .accessibilityLabel("Share a verified local asset")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            model.requestDeletionConfirmation()
                        } label: {
                            if model.isDeleting {
                                ProgressView()
                            } else {
                                Label("Delete scan", systemImage: "trash")
                            }
                        }
                        .disabled(model.isDeleting)
                        .accessibilityIdentifier(AccessibilityID.scanDetailDelete)
                    }
                }
            }
            .confirmationDialog(
                "Delete \(model.navigationTitle)?",
                isPresented: $model.isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete scan", role: .destructive) {
                    deleteScan()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This scan will be removed from the device.")
            }
            .sheet(item: $sharedAsset) { asset in
                ScanShareSheet(urls: [asset.url])
            }
            .alert(item: $model.deleteFailure) { failure in
                Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .task {
                await model.loadIfNeeded()
            }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.state {
        case .loading:
            ScanDetailLoadingView()
        case let .failure(error):
            ScanDetailErrorView(error: error) {
                Task { @MainActor in
                    await model.reload()
                }
            }
        case let .content(detail):
            ScanDetailContentView(detail: detail, isDemo: model.isDemo)
        }
    }

    private func deleteScan() {
        Task { @MainActor in
            guard await model.delete() else {
                return
            }
            dismiss()
            didDelete()
        }
    }
}

private struct ScanDetailLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Opening saved scan")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityIdentifier(AccessibilityID.scanDetailLoading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening saved scan")
    }
}

private struct ScanDetailErrorView: View {
    let error: ScanDetailFailureState
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text(error.title)
                    .font(.title2.weight(.semibold))

                Text(error.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier(AccessibilityID.scanDetailRetry)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(AccessibilityID.scanDetailError)
    }
}

private struct ScanDetailContentView: View {
    let detail: SavedScanDetail
    let isDemo: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if isDemo {
                    Label(
                        "Demo geometry and metadata are deterministic previews and do not use local package files.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                DetailSection("Raw mesh", systemImage: "cube.transparent") {
                    RawMeshDetailView(
                        rawMesh: detail.rawMesh,
                        presentation: detail.rawMeshPresentation
                    )
                }

                DetailSection("Capture", systemImage: "viewfinder") {
                    DetailValueRow("Status", value: detail.scan.status.detailDisplayName)
                    DetailValueRow("Created", value: EnglishFormat.dateTime(detail.scan.createdAt))
                    DetailValueRow("Last updated", value: EnglishFormat.dateTime(detail.scan.updatedAt))
                    DetailValueRow("Duration", value: durationDescription(detail.scan.durationSeconds))
                    DetailCopyableValueRow("Local scan ID", value: detail.scan.id.uuidString)
                }

                DetailSection("Capture statistics", systemImage: "chart.bar") {
                    let statistics = detail.manifest.captureStatistics
                    DetailValueRow("Sampled frames", value: EnglishFormat.number(statistics.sampledFrameCount))
                    DetailValueRow("Feature points", value: EnglishFormat.number(statistics.featurePointCount))
                    DetailValueRow("Depth points", value: EnglishFormat.number(statistics.depthPointCount))
                    DetailValueRow("Mesh vertices", value: EnglishFormat.number(statistics.meshVertexCount))
                    DetailValueRow("Mesh faces", value: EnglishFormat.number(statistics.meshFaceCount))
                }

                DetailSection("Package", systemImage: "shippingbox") {
                    DetailValueRow("Schema", value: "Version \(EnglishFormat.number(detail.manifest.schemaVersion))")
                    DetailValueRow("Processing pipeline", value: detail.manifest.processing.pipelineVersion)
                    DetailValueRow("Texture status", value: textureStatusDescription(detail.manifest.processing.textureProjectionStatus))
                    DetailValueRow("Sync status", value: detail.manifest.sync.status.detailDisplayName)
                    DetailValueRow("Source device", value: detail.manifest.sourceDevice.modelIdentifier)
                    DetailValueRow("Operating system", value: detail.manifest.sourceDevice.operatingSystemVersion)
                    DetailValueRow("App version", value: detail.manifest.sourceDevice.appVersion)
                    DetailTextRow("Coordinate system", value: coordinateSystemDescription(detail.manifest.coordinateSystem))
                    DetailTextRow("Camera metadata", value: cameraMetadataDescription(detail.manifest.cameraMetadataDescription))
                }

                DetailSection("Assets", systemImage: "externaldrive") {
                    if detail.manifest.assets.isEmpty {
                        Text(isDemo ? "The demo does not provide local asset files." : "No external assets are listed in this package.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detail.manifest.assets) { asset in
                            ScanAssetMetadataView(asset: asset)
                        }
                    }
                }

                DetailSection("Integrity", systemImage: detail.integrity.isValid ? "checkmark.seal" : "exclamationmark.shield") {
                    IntegrityDetailView(report: detail.integrity)
                }

                DetailSection("Export", systemImage: "square.and.arrow.up") {
                    if detail.exportableAssets.isEmpty {
                        Text(
                            detail.integrity.isValid
                                ? "No local package assets are available to share."
                                : "Export is disabled until the package passes integrity checks."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Use Share in the toolbar to export a verified local asset through the system share sheet.")
                            .foregroundStyle(.secondary)
                        DetailValueRow("Shareable assets", value: EnglishFormat.number(detail.exportableAssets.count))
                    }
                }
            }
            .padding()
        }
            .background(Color(uiColor: .systemGroupedBackground))
            .accessibilityIdentifier(AccessibilityID.scanDetailContent)
    }

    private func textureStatusDescription(_ status: String) -> String {
        switch status {
        case "sourceOnly":
            "Source only"
        case "notStarted":
            "Not started"
        case "projected":
            "Projected"
        case "baked":
            "Baked"
        default:
            status
        }
    }

    private func coordinateSystemDescription(_ description: String) -> String {
        switch description {
        case "RoomPlan semantic room coordinates; no ARKit world transform is inferred.":
            "RoomPlan semantic room coordinates; no ARKit world transform is inferred."
        case "ARKit right-handed meters; column-major worldFromLocal":
            "ARKit right-handed meters; column-major worldFromLocal."
        default:
            description
        }
    }

    private func cameraMetadataDescription(_ description: String) -> String {
        switch description {
        case "No raw ARKit frame metadata is retained for this semantic room capture.":
            "No raw ARKit frame metadata is retained for this semantic room capture."
        case "Selected frame metadata records intrinsics and worldFromCamera.":
            "Selected frame metadata records intrinsics and worldFromCamera."
        default:
            description
        }
    }
}

private struct RawMeshDetailView: View {
    let rawMesh: RawMeshLoadState
    let presentation: SavedRawMeshPresentation?

    var body: some View {
        switch rawMesh {
        case .available:
            if let presentation,
               presentation.snapshots.contains(where: isRenderable) {
                RawMeshSceneView(
                    snapshots: presentation.snapshots,
                    vertexColors: presentation.vertexColors
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier(AccessibilityID.scanDetailMesh)

                let anchorCount = presentation.snapshots.filter(isRenderable).count
                let faceCount = presentation.snapshots.reduce(0) { $0 + $1.faces.count }
                Text("\(EnglishFormat.number(anchorCount)) mesh anchors, \(EnglishFormat.number(faceCount)) faces")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !presentation.vertexColors.isEmpty {
                    Text("Display color comes from captured scan images.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                MeshNoGeometryView(message: "The saved raw mesh has no displayable vertices.")
            }
        case let .unavailable(message):
            MeshNoGeometryView(message: message)
        case let .failure(message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Raw mesh unavailable", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier(AccessibilityID.scanDetailMeshError)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Raw mesh unavailable. \(message)")
        }
    }

    private func isRenderable(_ snapshot: MeshSnapshot) -> Bool {
        !snapshot.vertices.isEmpty
    }
}

private struct MeshNoGeometryView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No saved mesh geometry", systemImage: "cube.transparent")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(AccessibilityID.scanDetailNoGeometry)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No saved mesh geometry. \(message)")
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DetailValueRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        } label: {
            Text(label)
        }
    }
}

private struct DetailCopyableValueRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

private struct DetailTextRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ScanAssetMetadataView: View {
    let asset: ScanAssetReference

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(asset.kind.detailDisplayName, systemImage: asset.kind.detailSystemImage)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(EnglishFormat.byteCount(asset.byteCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: asset.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
            DetailValueRow("Spatial reference", value: asset.spatialReference.detailDisplayName)
            DetailCopyableValueRow("SHA-256", value: asset.sha256)
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(AccessibilityID.scanDetailAsset(asset.id))
    }
}

private struct IntegrityDetailView: View {
    let report: PackageIntegrityReport

    var body: some View {
        if report.isValid {
            Label("All manifest assets passed size and checksum checks.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Package integrity verified")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Package integrity needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                    Text(failure.detailDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Package integrity needs attention")
        }
    }
}

private func durationDescription(_ duration: TimeInterval?) -> String {
    guard let duration else {
        return "Not captured"
    }

    return EnglishFormat.duration(seconds: max(0, Int(duration.rounded())))
}

private extension ScanStatus {
    var detailDisplayName: String {
        switch self {
        case .draft:
            "Draft"
        case .capturing:
            "Capturing"
        case .processing:
            "Processing"
        case .completed:
            "Complete"
        case .failed:
            "Failed"
        case .corrupted:
            "Needs attention"
        case .deleted:
            "Deleted"
        }
    }
}

private extension SynchronizationStatus {
    var detailDisplayName: String {
        switch self {
        case .localOnly:
            "Local only"
        case .pendingUpload:
            "Pending upload"
        case .uploading:
            "Uploading"
        case .synced:
            "Synced"
        case .modified:
            "Modified"
        case .conflict:
            "Conflict"
        case .failed:
            "Failed"
        case .pendingDeletion:
            "Pending deletion"
        }
    }
}

private extension AssetKind {
    var detailDisplayName: String {
        switch self {
        case .video:
            "Video"
        case .frameMetadata:
            "Frame metadata"
        case .pointCloud:
            "Point cloud"
        case .meshRaw:
            "Raw mesh"
        case .meshProcessed:
            "Processed mesh"
        case .semanticRoom:
            "Semantic room"
        case .textureSource:
            "Texture source"
        case .gisLayer:
            "GIS layer"
        case .alignment:
            "Alignment"
        case .thumbnail:
            "Thumbnail"
        case .manifestAttachment:
            "Manifest attachment"
        }
    }

    var detailSystemImage: String {
        switch self {
        case .video:
            "video"
        case .frameMetadata, .manifestAttachment:
            "doc.text"
        case .pointCloud:
            "circle.grid.3x3"
        case .meshRaw, .meshProcessed:
            "cube"
        case .semanticRoom:
            "house"
        case .textureSource, .thumbnail:
            "photo"
        case .gisLayer:
            "map"
        case .alignment:
            "arrow.triangle.merge"
        }
    }
}

private extension SpatialReferenceKind {
    var detailDisplayName: String {
        switch self {
        case .scanLocal:
            "Scan local"
        case .arWorld:
            "AR world"
        case .geographicWGS84:
            "WGS 84"
        }
    }
}

private extension PackageIntegrityFailure {
    var detailDescription: String {
        switch self {
        case .manifestMissing:
            "Package manifest is missing."
        case .manifestUnreadable:
            "Package manifest is unreadable."
        case .manifestIDMismatch:
            "The manifest scan ID does not match this scan."
        case let .unsafePath(path):
            "The manifest contains an unsafe asset path: \(path)."
        case let .duplicatePath(path):
            "The manifest references an asset path more than once: \(path)."
        case let .assetMissing(path):
            "A listed asset is missing: \(path)."
        case let .byteCountMismatch(path):
            "An asset size does not match the manifest: \(path)."
        case let .checksumMismatch(path):
            "An asset checksum does not match the manifest: \(path)."
        }
    }
}

private struct ThumbnailStateView: View {
    let state: ScanThumbnailState

    var body: some View {
        Image(systemName: state.systemImage)
            .font(.title3)
            .foregroundStyle(state.tint)
            .frame(width: 44, height: 44)
            .background(state.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(state.title)
    }
}

private struct ScanStatusBadge: View {
    let status: ScanStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status: \(status.title)")
    }
}

private struct ScanAssetStateBadge: View {
    let state: ScanAssetState

    private var tint: Color {
        switch state {
        case .ready, .synced:
            .green
        case .capturing, .processing, .pendingSync, .syncing, .pendingDeletion:
            .orange
        case .processingFailed, .syncFailed, .syncConflict, .incomplete, .corrupted:
            .red
        case .modified:
            .teal
        case .deleted:
            .secondary
        }
    }

    var body: some View {
        Text(state.workspaceDisplayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status: \(state.workspaceDisplayName)")
    }
}

private extension ScanStatus {
    var title: String {
        switch self {
        case .draft:
            "Draft"
        case .capturing:
            "Capturing"
        case .processing:
            "Processing"
        case .completed:
            "Complete"
        case .failed:
            "Failed"
        case .corrupted:
            "Needs attention"
        case .deleted:
            "Deleted"
        }
    }

    var tint: Color {
        switch self {
        case .completed:
            .green
        case .processing, .capturing:
            .orange
        case .failed, .corrupted:
            .red
        case .draft, .deleted:
            .secondary
        }
    }
}

private extension ScanThumbnailState {
    var title: String {
        switch self {
        case .ready:
            "Thumbnail ready"
        case .pending:
            "Thumbnail pending"
        case .unavailable:
            "Thumbnail unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            "photo"
        case .pending:
            "clock"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            .teal
        case .pending:
            .orange
        case .unavailable:
            .red
        }
    }
}

#Preview("Library - Content") {
    LibraryView(
        model: LibraryViewModel(service: DemoScanLibraryService(scenario: .content), isDemo: true),
        detailService: DemoScanDetailService(),
        comparisonDraftService: DemoScanComparisonDraftService(),
        beginScanning: {}
    )
}

#Preview("Library - Loading") {
    LibraryView(
        model: LibraryViewModel(service: DemoScanLibraryService(scenario: .loading), isDemo: true),
        detailService: DemoScanDetailService(),
        comparisonDraftService: DemoScanComparisonDraftService(),
        beginScanning: {}
    )
}

#Preview("Library - Empty") {
    LibraryView(
        model: LibraryViewModel(service: DemoScanLibraryService(scenario: .empty), isDemo: true),
        detailService: DemoScanDetailService(),
        comparisonDraftService: DemoScanComparisonDraftService(),
        beginScanning: {}
    )
}

#Preview("Library - Error") {
    LibraryView(
        model: LibraryViewModel(service: DemoScanLibraryService(scenario: .failure), isDemo: true),
        detailService: DemoScanDetailService(),
        comparisonDraftService: DemoScanComparisonDraftService(),
        beginScanning: {}
    )
}

// MARK: - Scan workspace

/// The workspace is deliberately restricted to renderers that are installed in
/// this build. Manifest availability is not mistaken for viewer support.
enum WorkspaceSurface: String, CaseIterable, Hashable, Identifiable {
    case processedSurface
    case rawMesh
    case pointCloud
    case semanticRoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processedSurface:
            "Processed surface"
        case .rawMesh:
            "Diagnostic raw mesh"
        case .pointCloud:
            "Point cloud"
        case .semanticRoom:
            "Room model"
        }
    }

    var systemImage: String {
        switch self {
        case .processedSurface:
            "square.3.layers.3d"
        case .rawMesh:
            "cube.transparent"
        case .pointCloud:
            "circle.grid.3x3"
        case .semanticRoom:
            "house"
        }
    }
}

/// Keeps saved-scan presentation honest: the quality-first point-cloud view is
/// the initial surface, and pose overlays only receive complete calibrated
/// camera data. This filters presentation input only; it does not alter any
/// saved package or exported asset.
enum SavedScanWorkspacePresentation {
    static let defaultSurface: WorkspaceSurface = .processedSurface

    static func preferredSurface(
        processedSurface: ProcessedSurfaceLoadState,
        pointCloudState: PointCloudScreenState,
        hasPointCloud: Bool,
        hasRawMesh: Bool,
        hasSemanticRoom: Bool
    ) -> WorkspaceSurface? {
        if case let .available(surface) = processedSurface, surface.hasObservedColors {
            return .processedSurface
        }
        if hasPointCloud {
            switch pointCloudState {
            case .idle, .loading:
                return .pointCloud
            case let .available(pointCloud) where pointCloud.hasObservedColors:
                return .pointCloud
            default:
                break
            }
        }
        if case .available = processedSurface { return .processedSurface }
        if case let .available(pointCloud) = pointCloudState, !pointCloud.points.isEmpty {
            return .pointCloud
        }
        if hasSemanticRoom { return .semanticRoom }
        if hasRawMesh { return .rawMesh }
        return nil
    }

    static func calibratedCameraFrustums(
        from candidates: [SavedCameraFrustum]
    ) -> [SavedCameraFrustum] {
        candidates.filter { frustum in
            let transform = frustum.worldFromCamera.columns
            let intrinsics = frustum.intrinsics
            return transform.count == 16
                && transform.allSatisfy(\.isFinite)
                && frustum.imageWidth > 0
                && frustum.imageHeight > 0
                && intrinsics.imageWidth > 0
                && intrinsics.imageHeight > 0
                && intrinsics.fx.isFinite
                && intrinsics.fy.isFinite
                && intrinsics.cx.isFinite
                && intrinsics.cy.isFinite
                && intrinsics.fx > 0
                && intrinsics.fy > 0
        }
    }
}

@MainActor
struct ScanWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScanDetailViewModel
    @State private var selectedSurface: WorkspaceSurface?
    @State private var viewportRevision = UUID()
    @State private var isShowingExportComposer = false
    @State private var isShowingRename = false
    @State private var renameDraft = ""
    @AppStorage("scanWorkspace.layer.rawMesh.visible") private var isRawMeshVisible = true
    @AppStorage("scanWorkspace.layer.processedSurface.visible") private var isProcessedSurfaceVisible = true
    @AppStorage("scanWorkspace.layer.pointCloud.visible") private var isPointCloudVisible = true
    @AppStorage("scanWorkspace.layer.semanticRoom.visible") private var isSemanticRoomVisible = true
    @AppStorage("scanWorkspace.rawMesh.cameraColor.visible") private var showsCameraColor = true
    @State private var showsCameraFrustums = false

    private let didDelete: () -> Void
    private let exportService: (any ScanInterchangeExportPreparing)?

    init(
        scanID: UUID,
        service: any ScanDetailServing,
        isDemo: Bool,
        didDelete: @escaping () -> Void
    ) {
        _model = State(initialValue: ScanDetailViewModel(scanID: scanID, service: service, isDemo: isDemo))
        self.didDelete = didDelete
        exportService = service as? any ScanInterchangeExportPreparing
    }

    var body: some View {
        @Bindable var model = model

        workspaceBody
            .navigationTitle(model.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                workspaceToolbar
            }
            .confirmationDialog(
                "Delete \(model.navigationTitle)?",
                isPresented: $model.isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete scan", role: .destructive) {
                    deleteScan()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the scan metadata and its managed local assets.")
            }
            .sheet(isPresented: $isShowingExportComposer) {
                if let detail = currentDetail, let exportService {
                    ScanInterchangeExportComposer(detail: detail, exportService: exportService)
                }
            }
            .alert("Rename scan", isPresented: $isShowingRename) {
                TextField("Scan name", text: $renameDraft)
                Button("Save") {
                    renameScan()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a new name.")
            }
            .alert(item: $model.deleteFailure) { failure in
                Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(item: $model.renameFailure) { failure in
                Alert(
                    title: Text(failure.title),
                    message: Text(failure.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .task {
                await model.loadIfNeeded()
                await model.observeReconstruction()
            }
    }

    @ViewBuilder
    private var workspaceBody: some View {
        switch model.state {
        case .loading:
            ScanDetailLoadingView()
        case let .failure(error):
            ScanDetailErrorView(error: error) {
                Task { @MainActor in
                    await model.reload()
                }
            }
        case let .content(detail):
            workspaceContent(detail)
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if let detail = currentDetail {
            if !supportedSurfaces(for: detail).isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            resetViewport()
                        } label: {
                            Label("Reset view", systemImage: "view.3d")
                        }

                        Divider()

                        Menu("Visible layers", systemImage: "square.3.layers.3d") {
                            ForEach(supportedSurfaces(for: detail)) { surface in
                                Toggle(
                                    surface.title,
                                    isOn: visibilityBinding(for: surface)
                                )
                            }
                        }
                    } label: {
                        Label("View tools", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityLabel("3D view tools")
                }
            }

            if detail.integrity.isValid,
               hasInterchangeSource(in: detail),
               exportService != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingExportComposer = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export")
                    .accessibilityIdentifier(AccessibilityID.scanDetailShare)
                }
            }

            if !model.isDemo {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        renameDraft = detail.scan.displayName
                        isShowingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .disabled(model.isRenaming)
                    .accessibilityLabel("Rename scan")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    model.requestDeletionConfirmation()
                } label: {
                    if model.isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .disabled(model.isDeleting)
                .accessibilityIdentifier(AccessibilityID.scanDetailDelete)
            }
        }
    }

    private var currentDetail: SavedScanDetail? {
        guard case let .content(detail) = model.state else {
            return nil
        }
        return detail
    }

    private func workspaceContent(_ detail: SavedScanDetail) -> some View {
        let rawMeshPresentation = detail.rawMeshPresentation
        let surfaces = supportedSurfaces(
            for: detail,
            rawMeshPresentation: rawMeshPresentation
        )
        let activeSurface = activeSurface(for: surfaces, detail: detail)
        let calibratedCameraFrustums = SavedScanWorkspacePresentation.calibratedCameraFrustums(
            from: detail.retainedCameraFrustums
        )

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                WorkspaceHero(detail: detail)
                reconstructionStatus(model.reconstructionStatus, fallback: detail.processedSurface)
                captureEvidenceStatus(detail.captureEvidenceQualification)
                reconstructionQualificationStatus(detail.reconstructionQualification)

                if !surfaces.isEmpty {
                    DetailSection(activeSurface.title, systemImage: activeSurface.systemImage) {
                        if surfaces.count > 1 {
                            Picker(
                                "3D view",
                                selection: Binding(
                                    get: { activeSurface },
                                    set: { selectedSurface = $0 }
                                )
                            ) {
                                ForEach(surfaces) { surface in
                                    Label(surface.title, systemImage: surface.systemImage)
                                        .tag(surface)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier(AccessibilityID.scanDetailSurfacePicker)
                        }

                        if activeSurface == .rawMesh,
                           hasProjectedMeshColors(in: rawMeshPresentation) {
                            Picker("Mesh view", selection: $showsCameraColor) {
                                Text("Geometry").tag(false)
                                Text("Image color").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("Mesh view")
                        }

                        if !calibratedCameraFrustums.isEmpty {
                            Toggle("Image positions", isOn: $showsCameraFrustums)
                                .accessibilityLabel("Show captured image positions")
                        }

                        WorkspaceCanvas(
                            detail: detail,
                            rawMeshPresentation: rawMeshPresentation,
                            surface: activeSurface,
                            isVisible: isSurfaceVisible(activeSurface),
                            showsCameraColor: showsCameraColor,
                            cameraFrustums: showsCameraFrustums ? calibratedCameraFrustums : [],
                            pointCloudState: model.pointCloudState,
                            viewportRevision: viewportRevision,
                            resetView: resetViewport
                        )
                        .task(id: activeSurface) {
                            guard activeSurface == .pointCloud else {
                                return
                            }
                            await model.loadPointCloudIfNeeded()
                        }
                    }
                }

                if !detail.workspaceKeyframes.isEmpty {
                    DetailSection("Captured images", systemImage: "photo.on.rectangle") {
                        ScanKeyframeGallery(keyframes: detail.workspaceKeyframes)
                    }
                }

                if let video = detail.exportableAssets.first(where: { $0.reference.kind == .video }) {
                    DetailSection("Captured media", systemImage: "video") {
                        ScanVideoPreview(url: video.url)
                    }
                }

                if surfaces.isEmpty, detail.exportableAssets.first(where: { $0.reference.kind == .video }) == nil {
                    ContentUnavailableView(
                        "View unavailable",
                        systemImage: "cube.transparent",
                        description: Text("This scan has no displayable content."))
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier(AccessibilityID.scanDetailContent)
    }

    private func supportedSurfaces(for detail: SavedScanDetail) -> [WorkspaceSurface] {
        supportedSurfaces(
            for: detail,
            rawMeshPresentation: detail.rawMeshPresentation
        )
    }

    private func supportedSurfaces(
        for detail: SavedScanDetail,
        rawMeshPresentation: SavedRawMeshPresentation?
    ) -> [WorkspaceSurface] {
        var surfaces: [WorkspaceSurface] = []
        if case .available = detail.processedSurface {
            surfaces.append(.processedSurface)
        }
        if detail.capabilities.capability(for: .pointCloud)?.availability == .available {
            surfaces.append(.pointCloud)
        }
        if detail.semanticRoomURL != nil {
            surfaces.append(.semanticRoom)
        }
        if rawMeshPresentation?.snapshots.contains(where: { !$0.vertices.isEmpty }) == true {
            surfaces.append(.rawMesh)
        }
        return surfaces
    }

    private func activeSurface(
        for surfaces: [WorkspaceSurface],
        detail: SavedScanDetail
    ) -> WorkspaceSurface {
        if let selectedSurface, surfaces.contains(selectedSurface) {
            return selectedSurface
        }
        let preferred = SavedScanWorkspacePresentation.preferredSurface(
            processedSurface: detail.processedSurface,
            pointCloudState: model.pointCloudState,
            hasPointCloud: detail.capabilities.capability(for: .pointCloud)?.availability == .available,
            hasRawMesh: detail.rawMeshPresentation?.snapshots.contains(where: { !$0.vertices.isEmpty }) == true,
            hasSemanticRoom: detail.semanticRoomURL != nil
        )
        return preferred.flatMap { surfaces.contains($0) ? $0 : nil }
            ?? surfaces.first
            ?? SavedScanWorkspacePresentation.defaultSurface
    }

    private func visibilityBinding(for surface: WorkspaceSurface) -> Binding<Bool> {
        switch surface {
        case .processedSurface:
            $isProcessedSurfaceVisible
        case .rawMesh:
            $isRawMeshVisible
        case .pointCloud:
            $isPointCloudVisible
        case .semanticRoom:
            $isSemanticRoomVisible
        }
    }

    private func isSurfaceVisible(_ surface: WorkspaceSurface) -> Bool {
        switch surface {
        case .processedSurface:
            isProcessedSurfaceVisible
        case .rawMesh:
            isRawMeshVisible
        case .pointCloud:
            isPointCloudVisible
        case .semanticRoom:
            isSemanticRoomVisible
        }
    }

    private func hasProjectedMeshColors(in presentation: SavedRawMeshPresentation?) -> Bool {
        presentation?.vertexColors.values.contains { colors in
            colors.contains(where: { $0 != nil })
        } == true
    }

    @ViewBuilder
    private func reconstructionStatus(
        _ status: ScanReconstructionStatus?,
        fallback: ProcessedSurfaceLoadState
    ) -> some View {
        if let status {
            switch status.stage {
            case .queued, .verifyingSource:
                reconstructionStatusLabel("Preparing 3D surface…", systemImage: "hourglass")
            case .reconstructing:
                reconstructionProgress(
                    message: "Reconstructing 3D surface…",
                    completed: status.completedFrameCount,
                    total: status.totalFrameCount
                )
            case .extractingSurface, .validatingSurface, .promotingSurface:
                reconstructionProgress(
                    message: "Processing 3D surface…",
                    completed: status.completedSubmapCount,
                    total: status.totalSubmapCount
                )
            case .paused:
                reconstructionRetryStatus("3D surface processing is paused.")
            case .failedRetryable:
                reconstructionRetryStatus("3D surface processing did not complete.")
            case .unavailable:
                reconstructionStatusLabel(
                    "Reconstruction input is missing; showing a fallback view.",
                    systemImage: "info.circle"
                )
            case .failedTerminal:
                reconstructionStatusLabel(
                    "No valid 3D surface was produced; showing a fallback view.",
                    systemImage: "exclamationmark.triangle"
                )
            case .ready:
                EmptyView()
            }
        } else {
            processedSurfaceStatus(fallback)
        }
    }

    @ViewBuilder
    private func processedSurfaceStatus(_ state: ProcessedSurfaceLoadState) -> some View {
        switch state {
        case .available:
            EmptyView()
        case let .processing(message):
            Label(message, systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.scanDetailProcessedStatus)
        case let .unavailable(message):
            Label(message, systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.scanDetailProcessedStatus)
        }
    }

    private func reconstructionStatusLabel(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.scanDetailProcessedStatus)
    }

    @ViewBuilder
    private func captureEvidenceStatus(_ qualification: CaptureEvidenceQualification?) -> some View {
        if let qualification {
            Label(
                captureEvidenceMessage(qualification),
                systemImage: qualification.isEvidenceSufficientForProcessing
                    ? "checkmark.circle"
                    : "info.circle"
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("scan-detail.capture-evidence-status")
        }
    }

    private func captureEvidenceMessage(_ qualification: CaptureEvidenceQualification) -> String {
        if qualification.isEvidenceSufficientForProcessing {
            return "Retained RGB-D evidence: \(qualification.acceptedCount) of \(qualification.candidateCount)"
        }
        return "Insufficient RGB-D reconstruction evidence: \(qualification.acceptedCount) of \(qualification.candidateCount)"
    }

    private func reconstructionQualificationStatus(
        _ report: ScanReconstructionQualificationReport
    ) -> some View {
        Label(
            reconstructionQualificationMessage(report),
            systemImage: report.isProcessedSurfaceEligible
                ? "checkmark.seal"
                : "exclamationmark.triangle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("scan-detail.reconstruction-qualification-status")
    }

    private func reconstructionQualificationMessage(
        _ report: ScanReconstructionQualificationReport
    ) -> String {
        if report.isProcessedSurfaceEligible {
            return "Processed surface and geometry export are ready."
        }
        let codes = report.issues.filter { $0.severity == .blocking }.map(\.code)
        if codes.contains(.packageIntegrityUnavailable) {
            return "Reconstruction eligibility: package integrity is unverified."
        }
        if codes.contains(.captureEvidenceUnavailable) {
            return "Reconstruction eligibility: no RGB-D evidence captured."
        }
        if codes.contains(.captureEvidenceInsufficient) {
            return "Reconstruction eligibility: insufficient RGB-D evidence for a processed surface."
        }
        if codes.contains(.processedSurfaceInvalid) {
            return "Reconstruction eligibility: processed surface validation failed."
        }
        if codes.contains(.processedSurfaceUnavailable) {
            return "Reconstruction eligibility: processed surface is not yet available."
        }
        return "Reconstruction eligibility: complete spatial source unavailable."
    }

    private func reconstructionProgress(message: String, completed: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            reconstructionStatusLabel(message, systemImage: "hourglass")
            if total > 0 {
                ProgressView(value: Double(completed), total: Double(total))
            } else {
                ProgressView()
            }
        }
    }

    private func reconstructionRetryStatus(_ message: String) -> some View {
        HStack(spacing: 12) {
            reconstructionStatusLabel(message, systemImage: "pause.circle")
            Spacer()
            Button("Try again") {
                Task { await model.retryReconstruction() }
            }
            .disabled(model.isRetryingReconstruction)
            .accessibilityIdentifier(AccessibilityID.scanDetailReconstructionRetry)
        }
    }

    private func hasInterchangeSource(in detail: SavedScanDetail) -> Bool {
        detail.manifest.assets.contains {
            $0.kind == .manifestAttachment
                && $0.relativePath == CanonicalSpatialChunkStore.relativePath
        } || {
            if case .available = detail.processedSurface { return true }
            return false
        }()
    }

    private func deleteScan() {
        Task { @MainActor in
            guard await model.delete() else {
                return
            }
            dismiss()
            didDelete()
        }
    }

    private func renameScan() {
        Task { @MainActor in
            guard await model.rename(to: renameDraft) else {
                return
            }
            isShowingRename = false
            didDelete()
        }
    }

    private func resetViewport() {
        viewportRevision = UUID()
    }
}

private struct WorkspaceHero: View {
    let detail: SavedScanDetail

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: heroSymbol)
                .font(.title2)
                .foregroundStyle(detail.integrity.isValid ? Color.teal : Color.orange)
                .frame(width: 46, height: 46)
                .background((detail.integrity.isValid ? Color.teal : Color.orange).opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.scan.displayName)
                    .font(.title3.weight(.semibold))
                Text(EnglishFormat.dateTime(detail.scan.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var heroSymbol: String {
        if detail.capabilities.capability(for: .pointCloud)?.availability == .available {
            return "circle.grid.3x3"
        }
        if detail.capabilities.capability(for: .meshRaw)?.availability == .available {
            return "cube.transparent"
        }
        if detail.capabilities.capability(for: .semanticRoom)?.availability == .available {
            return "house"
        }
        return "externaldrive"
    }
}

private struct WorkspaceCanvas: View {
    let detail: SavedScanDetail
    let rawMeshPresentation: SavedRawMeshPresentation?
    let surface: WorkspaceSurface
    let isVisible: Bool
    let showsCameraColor: Bool
    let cameraFrustums: [SavedCameraFrustum]
    let pointCloudState: PointCloudScreenState
    let viewportRevision: UUID
    let resetView: () -> Void

    var body: some View {
        Group {
            if !isVisible {
                ContentUnavailableView(
                    "This layer is hidden",
                    systemImage: "eye.slash",
                    description: Text("Enable the \(surface.title) layer in View tools.")
                )
            } else {
                switch surface {
                case .processedSurface:
                    processedSurfaceCanvas
                case .rawMesh:
                    rawMeshCanvas
                case .pointCloud:
                    pointCloudCanvas
                case .semanticRoom:
                    semanticRoomCanvas
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var processedSurfaceCanvas: some View {
        switch detail.processedSurface {
        case let .available(presentation):
            ZStack(alignment: .topTrailing) {
                ProcessedSurfaceSceneView(
                    surface: presentation.surface,
                    resetToken: viewportRevision
                )
                .accessibilityIdentifier(AccessibilityID.scanDetailProcessedSurface)

                Button(action: resetView) {
                    Label("Reset view", systemImage: "view.3d")
                }
                .buttonStyle(.bordered)
                .padding(12)
                .accessibilityIdentifier(AccessibilityID.scanDetailResetView)
            }
        case let .processing(message):
            ProgressView(message)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .unavailable(message):
            ContentUnavailableView(
                "Processed surface unavailable",
                systemImage: "square.3.layers.3d.slash",
                description: Text(message)
            )
        }
    }

    @ViewBuilder
    private var rawMeshCanvas: some View {
        switch detail.rawMesh {
        case .available:
            if let rawMeshPresentation,
               rawMeshPresentation.snapshots.contains(where: { !$0.vertices.isEmpty }) {
                ZStack(alignment: .topTrailing) {
                    RawMeshSceneView(
                        snapshots: rawMeshPresentation.snapshots,
                        vertexColors: showsCameraColor ? rawMeshPresentation.vertexColors : [:],
                        cameraFrustums: cameraFrustums,
                        resetToken: viewportRevision
                    )

                    Button(action: resetView) {
                        Label("Reset view", systemImage: "view.3d")
                    }
                    .buttonStyle(.bordered)
                    .padding(12)
                    .accessibilityLabel("Reset 3D view")
                }
            } else {
                ContentUnavailableView(
                    "3D view unavailable",
                    systemImage: "cube.transparent",
                    description: Text("This capture has no displayable points or surfaces."))
            }
        case let .unavailable(message), let .failure(message):
            ContentUnavailableView(
                "3D view unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    @ViewBuilder
    private var pointCloudCanvas: some View {
        switch pointCloudState {
        case .idle, .loading:
            ProgressView("Loading bounded point cloud sample")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .available(presentation) where !presentation.points.isEmpty:
            PointCloudSceneView(
                result: presentation.source,
                vertexColors: presentation.observedColors,
                cameraFrustums: cameraFrustums
            )
                .id(viewportRevision)
        case .available:
            ContentUnavailableView(
                "No 3D model captured",
                systemImage: "cube.transparent",
                description: Text("Capture a new scan to view a 3D model."))
        case let .unavailable(message), let .failure(message):
            ContentUnavailableView(
                "Point cloud unavailable",
                systemImage: "circle.grid.3x3",
                description: Text(message)
            )
        }
    }

    @ViewBuilder
    private var semanticRoomCanvas: some View {
        if let url = detail.semanticRoomURL {
            SemanticRoomQuickLookView(url: url)
                .id(viewportRevision)
                .accessibilityLabel("Saved room model")
        } else {
            ContentUnavailableView(
                "Room model unavailable",
                systemImage: "house",
                description: Text("This scan has no room model file."))
        }
    }
}

/// Presents a verified RoomPlan USDZ with the system viewer. The workspace
/// does not attempt to reinterpret RoomPlan coordinates as a raw ARKit mesh.
private struct SemanticRoomQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else {
            return
        }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> (any QLPreviewItem) {
            url as NSURL
        }
    }
}

private struct ScanVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView("Preparing captured video")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            guard player == nil else {
                return
            }
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
        .accessibilityLabel("Captured video preview")
    }
}

private struct ScanKeyframeGallery: View {
    let keyframes: [SavedScanKeyframe]
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 12) {
            if let selectedKeyframe {
                ScanKeyframePreview(keyframe: selectedKeyframe)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(keyframes.indices, id: \.self) { index in
                        Button {
                            selectedIndex = index
                        } label: {
                            Text("Image \(EnglishFormat.number(index + 1))")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    index == selectedIndex ? Color.teal : Color(uiColor: .tertiarySystemFill),
                                    in: Capsule()
                                )
                                .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Captured image \(EnglishFormat.number(index + 1))")
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 1)
            }
        }
        .onChange(of: keyframes) { _, newKeyframes in
            selectedIndex = min(selectedIndex, max(0, newKeyframes.count - 1))
        }
    }

    private var selectedKeyframe: SavedScanKeyframe? {
        guard keyframes.indices.contains(selectedIndex) else {
            return nil
        }
        return keyframes[selectedIndex]
    }
}

private struct ScanKeyframePreview: View {
    let keyframe: SavedScanKeyframe
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView("Opening captured image")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: keyframe) {
            image = nil
            guard let decoded = UIImage(contentsOfFile: keyframe.url.path),
                  let cgImage = decoded.cgImage
            else { return }
            image = UIImage(
                cgImage: cgImage,
                scale: decoded.scale,
                orientation: keyframe.displayOrientation?.uiImageOrientation ?? decoded.imageOrientation
            )
        }
        .accessibilityLabel("Captured image")
    }
}

private extension CapturedImageOrientation {
    var uiImageOrientation: UIImage.Orientation {
        switch self {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }
}

@MainActor
private struct ScanInterchangeExportComposer: View {
    @Environment(\.dismiss) private var dismiss

    let detail: SavedScanDetail
    let exportService: any ScanInterchangeExportPreparing
    @State private var formats: [ScanInterchangeFormat] = []
    @State private var isLoading = true
    @State private var isPreparing = false
    @State private var preparedExport: PreparedScanInterchangeExport?
    @State private var failure: ScanDetailFailureState?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    Section {
                        ProgressView("Preparing formats")
                    }
                } else if formats.isEmpty {
                    ContentUnavailableView(
                        "Export unavailable",
                        systemImage: "square.and.arrow.up",
                        description: Text("This scan has no exportable file."))
                } else {
                    Section("Format") {
                        ForEach(formats, id: \.rawValue) { format in
                            Button {
                                prepareExport(format)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: format.systemImage)
                                        .frame(width: 24)
                                        .foregroundStyle(Color.accentColor)
                                    Text(format.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                    if isPreparing {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(isPreparing)
                            .accessibilityLabel("Export \(format.displayName)")
                        }
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheet(item: $preparedExport) { export in
            ScanShareSheet(urls: [export.shareURL])
        }
        .alert(item: $failure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            formats = await exportService.availableInterchangeFormats(id: detail.scan.id)
            isLoading = false
        }
    }

    private func prepareExport(_ format: ScanInterchangeFormat) {
        isPreparing = true
        failure = nil
        Task { @MainActor in
            let result = await exportService.prepareInterchangeExport(
                id: detail.scan.id,
                format: format
            )
            isPreparing = false
            switch result {
            case let .success(export):
                preparedExport = export
            case let .failure(error):
                failure = error
            }
        }
    }
}

private extension ScanInterchangeFormat {
    var displayName: String {
        switch self {
        case .ply:
            "PLY"
        case .glb:
            "glTF (.glb)"
        case .cesium3DTiles:
            "Cesium 3D Tiles"
        case .opf:
            "OPF"
        }
    }

    var systemImage: String {
        switch self {
        case .ply:
            "circle.grid.3x3"
        case .glb:
            "cube.transparent"
        case .cesium3DTiles:
            "square.3.layers.3d"
        case .opf:
            "point.3.connected.trianglepath.dotted"
        }
    }
}

private extension ScanAssetState {
    var workspaceDisplayName: String {
        switch self {
        case .capturing:
            "Capturing"
        case .processing:
            "Processing"
        case .ready:
            "Ready locally"
        case .modified:
            "Modified"
        case .pendingSync:
            "Pending sync"
        case .syncing:
            "Syncing"
        case .synced:
            "Synced"
        case .incomplete:
            "Incomplete"
        case .processingFailed:
            "Processing failed"
        case .syncFailed:
            "Sync failed"
        case .syncConflict:
            "Sync conflict"
        case .pendingDeletion:
            "Pending deletion"
        case .corrupted:
            "Needs attention"
        case .deleted:
            "Deleted"
        }
    }
}
