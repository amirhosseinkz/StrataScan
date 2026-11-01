import Foundation
import SwiftUI

@main
@MainActor
struct StrataScanApp: App {
    @State private var model: AppShellModel

    init() {
        let composition = AppComposition.make(arguments: ProcessInfo.processInfo.arguments)
        _model = State(
            initialValue: AppShellModel(
                library: LibraryViewModel(
                    service: composition.libraryService,
                    isDemo: composition.isDemo
                ),
                detailService: composition.detailService,
                comparisonDraftService: composition.comparisonDraftService,
                scanner: ScannerWorkflowModel(
                    service: composition.scannerService,
                    isDemo: composition.isDemo,
                    rawPreviewSession: composition.rawPreviewSession,
                    semanticPreviewView: composition.semanticPreviewView
                ),
                settings: composition.settingsService.currentSettings(),
                reconstructionCoordinator: composition.reconstructionCoordinator
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            StrataScanRootView(model: model)
                .environment(\.locale, EnglishFormat.locale)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

@MainActor
private struct StrataScanRootView: View {
    @Bindable var model: AppShellModel
    @State private var isClosingScanner = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $model.selectedTab) {
            Tab("Library", systemImage: "square.stack.3d.up", value: AppTab.library) {
                LibraryView(
                    model: model.library,
                    detailService: model.detailService,
                    comparisonDraftService: model.comparisonDraftService,
                    requestedWorkspaceScanID: $model.requestedWorkspaceScanID
                ) {
                    model.presentedRoute = .scanner
                }
                .accessibilityIdentifier(AccessibilityID.libraryTabContent)
            }

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(state: model.settings)
                    .accessibilityIdentifier(AccessibilityID.settingsTabContent)
            }
        }
        .tint(.teal)
        .fullScreenCover(item: $model.presentedRoute) { _ in
            ScannerWorkflowView(
                model: model.scanner,
                dismiss: {
                    closeScanner()
                },
                reviewSavedScan: { scanID in
                    openCompletedScan(id: scanID)
                }
            )
        }
        .task {
            await updateReconstructionLifecycle(for: scenePhase)
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                await updateReconstructionLifecycle(for: phase)
            }
        }
    }

    private func closeScanner() {
        guard !isClosingScanner else {
            return
        }
        isClosingScanner = true
        Task { @MainActor in
            _ = await model.scanner.perform(.cancel)
            model.presentedRoute = nil
            await model.library.reload()
            isClosingScanner = false
        }
    }

    private func openCompletedScan(id: UUID) {
        model.presentedRoute = nil
        Task {
            await model.library.reload()
            model.requestedWorkspaceScanID = id
        }
    }

    private func updateReconstructionLifecycle(for phase: ScenePhase) async {
        await model.reconstructionCoordinator?.setApplicationActive(phase == .active)
        if phase == .active {
            await model.reconstructionCoordinator?.resumePendingJobs()
        }
    }
}
