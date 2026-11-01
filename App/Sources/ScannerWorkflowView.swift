import ARKit
import CoreVideo
import SwiftUI
import StrataCore
import UIKit

@MainActor
struct ScannerWorkflowView: View {
    @Bindable var model: ScannerWorkflowModel
    let dismiss: () -> Void
    let reviewSavedScan: (UUID) -> Void
    @State private var showsCancelConfirmation = false

    init(
        model: ScannerWorkflowModel,
        dismiss: @escaping () -> Void,
        reviewSavedScan: @escaping (UUID) -> Void = { _ in }
    ) {
        self.model = model
        self.dismiss = dismiss
        self.reviewSavedScan = reviewSavedScan
    }

    var body: some View {
        Group {
            if presentsCaptureControls {
                captureSurface
            } else {
                scannerSurface
            }
        }
        .task {
            await model.activate()
        }
        .task(id: model.snapshot.lifecycle) {
            while !Task.isCancelled {
                switch model.snapshot.lifecycle {
                case .scanning, .pausing, .trackingLost:
                    break
                default:
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else {
                    return
                }
                await model.refresh()
            }
        }
        .accessibilityIdentifier(AccessibilityID.scannerWorkflow)
    }

    private var presentsCaptureControls: Bool {
        switch model.snapshot.lifecycle {
        case .scanning, .pausing, .trackingLost:
            true
        default:
            false
        }
    }

    private var captureSurface: some View {
        ZStack {
            captureBackground

            VStack(spacing: 0) {
                captureHeader
                Spacer(minLength: 24)

                if model.snapshot.lifecycle == .trackingLost {
                    CaptureTrackingNotice()
                } else if model.snapshot.captureMode == .rawLiDAR {
                    CaptureCoverageNotice(
                        coverage: model.snapshot.rawCoverage,
                        footprint: model.snapshot.rawObservationFootprint,
                        readiness: model.snapshot.rawReadiness,
                        guidance: model.snapshot.rawGuidance
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CaptureControlDock(
                captureMode: model.snapshot.captureMode,
                lifecycle: model.snapshot.lifecycle,
                isDemo: model.snapshot.isDemo,
                canFinishCapture: model.snapshot.canFinishActiveCapture,
                perform: perform,
                requestCancellation: {
                    showsCancelConfirmation = true
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .confirmationDialog(
            "Cancel capture?",
            isPresented: $showsCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("Cancel capture", role: .destructive) {
                perform(.cancel)
            }
            Button("Continue capture", role: .cancel) {}
        } message: {
            Text("Unsaved data will be discarded.")
        }
    }

    private var scannerSurface: some View {
        ZStack {
            ScannerBackdrop()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    captureModeSelector
                    workflowContent
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private var captureBackground: some View {
        if let previewSession = model.previewSession,
           !model.snapshot.isDemo,
           model.snapshot.hasActiveCameraPreview {
            ARCameraPreview(
                session: previewSession,
                showsLiveMesh: model.snapshot.captureMode == .rawLiDAR
            )
                .ignoresSafeArea()
            Color.black.opacity(0.10)
                .ignoresSafeArea()
        } else if let roomCapturePreview = model.roomCapturePreview,
                  !model.snapshot.isDemo,
                  model.snapshot.hasActiveCameraPreview {
            RoomPlanCapturePreview(captureView: roomCapturePreview)
                .ignoresSafeArea()
        } else {
            ScannerBackdrop()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New scan")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)

                Text("On this device")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
            }

            Spacer(minLength: 12)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("Close scanner")
            .accessibilityIdentifier(AccessibilityID.scannerClose)
        }
    }

    private var captureHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                CaptureStatePill(
                    title: captureStateTitle,
                    systemImage: captureStateSymbol,
                    tint: captureStateTint
                )

                Spacer(minLength: 12)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Close scanner")
                .accessibilityIdentifier(AccessibilityID.scannerClose)
            }

        }
        .frame(maxWidth: 430, alignment: .leading)
    }

    @ViewBuilder
    private var captureModeSelector: some View {
        if model.snapshot.canSelectCaptureMode {
            VStack(alignment: .leading, spacing: 10) {
                Text("Capture mode")
                    .font(.headline)
                    .foregroundStyle(.white)

                Picker(
                    "Capture mode",
                    selection: Binding(
                        get: { model.snapshot.captureMode },
                        set: { mode in
                            Task {
                                await model.perform(.selectCaptureMode(mode))
                            }
                        }
                    )
                ) {
                    ForEach(ScanCaptureMode.allCases, id: \.self) { mode in
                        Text(mode.selectionTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(AccessibilityID.scannerCaptureMode)

                Text(model.snapshot.captureMode.selectionDescription)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var workflowContent: some View {
        switch model.snapshot.capability {
        case .checking:
            ScannerPanel(
                title: "Checking",
                message: "Checking this device's capture capabilities.",
                systemImage: "viewfinder.circle",
                tint: .teal,
                identifier: AccessibilityID.scannerChecking
            ) {
                ProgressView("Checking capabilities")
            }
        case let .unavailable(issues):
            unavailableContent(issues: issues)
        case .requiresCameraPermission:
            ScannerPanel(
                title: "Camera access required",
                message: "Allow camera access to start capturing.",
                systemImage: "camera.badge.ellipsis",
                tint: .orange,
                identifier: AccessibilityID.scannerPermission
            ) {
                permissionButton
            }
        case let .available(advisories):
            lifecycleContent(advisories: advisories)
        }
    }

    private func unavailableContent(issues: [ScanCapabilityIssue]) -> some View {
        ScannerPanel(
            title: model.snapshot.isDemo
                ? "Capture adapter unavailable"
                : "\(model.snapshot.captureMode.displayName) unavailable",
            message: unavailableMessage(issues: issues),
            systemImage: "viewfinder.circle.fill",
            tint: .orange,
            identifier: AccessibilityID.scannerUnavailable
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues, id: \.rawValue) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                }
            }

            retryButton
        }
    }

    @ViewBuilder
    private func lifecycleContent(advisories: [ScanCapabilityAdvisory]) -> some View {
        switch model.snapshot.lifecycle {
        case .ready:
            ScannerPanel(
                title: "Ready to capture",
                message: readyMessage(advisories: advisories),
                systemImage: "checkmark.circle",
                tint: .green,
                identifier: AccessibilityID.scannerReady
            ) {
                workflowButton(
                    title: model.snapshot.isDemo
                        ? "Preview capture flow"
                        : "Start \(model.snapshot.captureMode.startActionTitle)",
                    systemImage: "play.fill",
                    command: .startPreview
                )
            }
        case .scanning, .pausing, .trackingLost:
            EmptyView()
        case .processing:
            if let review = model.snapshot.pendingReview, !model.snapshot.isDemo {
                CaptureReviewPanel(review: review) { name in
                    Task {
                        await model.perform(.renameReview(name))
                        await model.perform(.finishProcessing)
                    }
                }
            } else {
                ScannerPanel(
                    title: "Preparing scan",
                    message: "Preparing the scan for review.",
                    systemImage: "gearshape.2",
                    tint: .teal,
                    identifier: AccessibilityID.scannerProcessing
                ) {
                    workflowButton(
                        title: model.snapshot.isDemo ? "Continue" : "Continue to review",
                        systemImage: "arrow.forward",
                        command: .finishProcessing
                    )
                }
            }
        case .saving:
            ScannerPanel(
                title: "Saving",
                message: "Saving the scan to the local library.",
                systemImage: "externaldrive.badge.checkmark",
                tint: .teal,
                identifier: AccessibilityID.scannerSaving
            ) {
                workflowButton(
                    title: "Complete",
                    systemImage: "checkmark",
                    command: .finishSaving
                )
            }
        case .completed:
            ScannerPanel(
                title: "Scan complete",
                message: model.snapshot.isDemo ? "Demo complete." : "Your scan is ready in the local library.",
                systemImage: "checkmark.seal",
                tint: .green,
                identifier: AccessibilityID.scannerCompleted
            ) {
                if let completedScanID = model.snapshot.completedScanID, !model.snapshot.isDemo {
                    Button {
                        reviewSavedScan(completedScanID)
                    } label: {
                        Label("Review scan", systemImage: "square.stack.3d.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier(AccessibilityID.scannerReview)
                }
                Button(action: dismiss) {
                    Label("Back to library", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case let .failed(reason):
            ScannerPanel(
                title: reason.title,
                message: reason.message,
                systemImage: "exclamationmark.triangle",
                tint: .red,
                identifier: AccessibilityID.scannerError
            ) {
                retryButton
            }
        case .insufficientStorage:
            ScannerPanel(
                title: "More storage required",
                message: "Free up space before starting a new capture.",
                systemImage: "externaldrive.badge.exclamationmark",
                tint: .orange,
                identifier: AccessibilityID.scannerError
            ) {
                workflowButton(
                    title: model.snapshot.isDemo ? "Check demo storage again" : "Check storage again",
                    systemImage: "arrow.clockwise",
                    command: .storageAvailable
                )
            }
        case .cancelled:
            ScannerPanel(
                title: "Capture cancelled",
                message: "No new scan was saved.",
                systemImage: "xmark.circle",
                tint: .secondary,
                identifier: AccessibilityID.scannerError
            ) {
                Button(action: dismiss) {
                    Label("Back to library", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        case .idle, .preparing, .capabilityChecking, .requestingPermissions, .recovering:
            ScannerPanel(
                title: "Preparing",
                message: "Please wait.",
                systemImage: "viewfinder.circle",
                tint: .teal,
                identifier: AccessibilityID.scannerChecking
            ) {
                ProgressView("Preparing")
            }
        }
    }

    private func readyMessage(advisories: [ScanCapabilityAdvisory]) -> String {
        let advisoryMessage = advisories.map(\.message).joined(separator: " ")
        guard advisoryMessage.isEmpty else {
            return advisoryMessage
        }
        return model.snapshot.isDemo ? "Ready to show controls." : "Data stays on this device."
    }

    private func unavailableMessage(issues: [ScanCapabilityIssue]) -> String {
        if model.snapshot.isDemo {
            return "Hardware capture is unavailable in the demo."
        }
        if issues.contains(.roomPlanUnavailable) {
            return "This device cannot capture semantic rooms with RoomPlan. Choose raw LiDAR capture if supported."
        }
        if issues.contains(.lidarUnavailable) {
            return "This device does not support raw LiDAR capture."
        }
        if issues.isEmpty {
            return "Capture is not ready."
        }
        return "This device does not meet the capture requirements."
    }

    private var permissionButton: some View {
        workflowButton(
            title: model.snapshot.isDemo ? "Continue demo" : "Allow camera access",
            systemImage: "camera.fill",
            command: .requestCameraPermission
        )
    }

    private var retryButton: some View {
        Button {
            Task {
                await model.activate()
            }
        } label: {
            Label("Check again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier(AccessibilityID.scannerRetry)
    }

    private func workflowButton(
        title: String,
        systemImage: String,
        command: ScannerWorkflowCommand
    ) -> some View {
        Button {
            Task {
                await model.perform(command)
            }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityIdentifier(command.accessibilityIdentifier)
    }

    private var captureStateTitle: String {
        switch model.snapshot.lifecycle {
        case .scanning:
            model.snapshot.isDemo ? "Demo" : "Capturing"
        case .pausing:
            "Capture paused"
        case .trackingLost:
            "Limited tracking"
        default:
            "Ready"
        }
    }

    private var captureStateSymbol: String {
        switch model.snapshot.lifecycle {
        case .scanning:
            "record.circle.fill"
        case .pausing:
            "pause.circle.fill"
        case .trackingLost:
            "exclamationmark.triangle.fill"
        default:
            "checkmark.circle.fill"
        }
    }

    private var captureStateTint: Color {
        switch model.snapshot.lifecycle {
        case .scanning:
            .red
        case .pausing, .trackingLost:
            .orange
        default:
            .green
        }
    }

    private func perform(_ command: ScannerWorkflowCommand) {
        Task {
            await model.perform(command)
        }
    }
}

private struct CaptureReviewPanel: View {
    let review: CaptureReviewSnapshot
    let save: (String) -> Void
    @State private var displayName: String

    init(review: CaptureReviewSnapshot, save: @escaping (String) -> Void) {
        self.review = review
        self.save = save
        _displayName = State(initialValue: review.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Review scan", systemImage: "checkmark.seal")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.teal)

            VStack(alignment: .leading, spacing: 8) {
                Text("Scan name")
                    .font(.subheadline.weight(.semibold))
                TextField("Scan name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier(AccessibilityID.scannerReviewName)
            }

            CaptureReviewSummary(review: review)

            Button {
                save(displayName)
            } label: {
                Label("Save scan", systemImage: "externaldrive.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier(AccessibilityID.scannerReviewSave)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teal.opacity(0.22), lineWidth: 1)
        }
        .accessibilityIdentifier(AccessibilityID.scannerReview)
    }
}

private struct CaptureReviewSummary: View {
    let review: CaptureReviewSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            reviewValue("Capture time", value: EnglishFormat.dateTime(review.capturedAt))
            reviewValue("Duration", value: EnglishFormat.duration(seconds: max(0, Int(review.durationSeconds.rounded()))))
            reviewValue("Captured data size", value: EnglishFormat.byteCount(review.totalByteCount))
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func reviewValue(_ label: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
        } label: {
            Text(label)
        }
    }
}

private struct ScannerBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.03, green: 0.10, blue: 0.12), Color(red: 0.02, green: 0.04, blue: 0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.teal.opacity(0.16))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 100, y: -80)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

private struct CaptureStatePill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.black.opacity(0.58), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.82), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
    }
}

private struct CaptureTrackingNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tracking is limited", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Hold the phone steady, then move slowly toward a well-lit, detailed surface. Capture resumes automatically.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.88))
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.orange.opacity(0.62), lineWidth: 1)
        }
        .accessibilityIdentifier(AccessibilityID.scannerError)
    }
}

/// Shows only categorical evidence received from the active AR session. This
/// avoids turning sparse depth samples into a misleading visual "coverage" map.
private struct CaptureCoverageNotice: View {
    let coverage: RawCaptureCoverage
    let footprint: RawCaptureObservationFootprint
    let readiness: RawCaptureReadiness
    let guidance: RawCaptureGuidance

    var body: some View {
        if let presentation {
            VStack(alignment: .leading, spacing: 8) {
                Label(presentation.title, systemImage: presentation.systemImage)
                    .font(.headline)
                    .foregroundStyle(presentation.tint)

                Text(presentation.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
            }
            .padding(16)
            .frame(maxWidth: 360, alignment: .leading)
            .background(Color.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(presentation.tint.opacity(0.62), lineWidth: 1)
            }
            .accessibilityIdentifier(AccessibilityID.scannerCoverage)
        }
    }

    private var presentation: Presentation? {
        switch guidance {
        case .moveFarther:
            return Presentation(
                title: "Too close",
                message: "Step back slightly to keep depth and mesh tracking stable.",
                systemImage: "arrow.backward.circle",
                tint: .orange
            )
        case .moveCloser:
            return Presentation(
                title: "Too far away",
                message: "Move closer to the surface to capture mesh detail.",
                systemImage: "arrow.forward.circle",
                tint: .orange
            )
        case .moveMoreSlowly:
            return Presentation(
                title: "Slow down",
                message: "Move the phone slowly and steadily to keep the mesh stable.",
                systemImage: "tortoise",
                tint: .orange
            )
        case .seekNewSurface:
            return Presentation(
                title: "Scan a new surface",
                message: "Change your angle slightly or move to another surface to capture more mesh.",
                systemImage: "viewfinder.circle",
                tint: .orange
            )
        case .inactive:
            break
        }

        switch coverage {
        case .inactive, .trackingUnavailable:
            return nil
        case .waitingForSpatialData:
            return Presentation(
                title: "Waiting for a usable surface",
                message: "Point the phone slowly toward a well-lit, matte surface.",
                systemImage: "viewfinder",
                tint: .orange
            )
        case .depthObserved:
            return Presentation(
                title: "LiDAR depth received",
                message: "Move a little more slowly to build a live surface mesh.",
                systemImage: "dot.radiowaves.left.and.right",
                tint: .teal
            )
        case .meshObserved:
            switch footprint {
            case .initialSurface:
                return Presentation(
                    title: "Initial surface captured",
                    message: "This is only the observed area. Continue slowly around this surface.",
                    systemImage: "viewfinder.circle",
                    tint: .teal
                )
            case .expandingSurface:
                return Presentation(
                    title: "Observed surface is expanding",
                    message: "More geometry is visible in the live mesh. Capture unseen edges and angles too.",
                    systemImage: "viewfinder.circle.fill",
                    tint: .teal
                )
            case .broadObservedSurface:
                return Presentation(
                    title: "Broader surface observed",
                    message: "This is observed geometry, not scan completeness. Continue to other surfaces as needed.",
                    systemImage: "cube.transparent",
                    tint: .green
                )
            case .inactive, .awaitingMesh:
                break
            }
            if readiness == .gatheringGeometry {
                return Presentation(
                    title: "Small mesh received",
                    message: "Slowly capture more surfaces or a larger area before finishing.",
                    systemImage: "cube.transparent",
                    tint: .teal
                )
            }
            return Presentation(
                title: "Live mesh capture active",
                message: "More geometry has arrived. You can finish capturing or continue.",
                systemImage: "cube.transparent",
                tint: .green
            )
        }
    }

    private struct Presentation {
        let title: String
        let message: String
        let systemImage: String
        let tint: Color
    }
}

private struct CaptureControlDock: View {
    let captureMode: ScanCaptureMode
    let lifecycle: ScanLifecycleState
    let isDemo: Bool
    let canFinishCapture: Bool
    let perform: (ScannerWorkflowCommand) -> Void
    let requestCancellation: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                leadingControl
                finishControl
                cancelControl
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    leadingControl
                    finishControl
                }
                cancelControl
            }
        }
        .padding(10)
        .background(
            Color.black.opacity(reduceTransparency ? 0.94 : 0.70),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityIdentifier(AccessibilityID.scannerScanning)
    }

    @ViewBuilder
    private var leadingControl: some View {
        if lifecycle == .trackingLost {
            CaptureDockButton(
                title: "Waiting for tracking",
                systemImage: "viewfinder",
                tint: .orange,
                isProminent: false,
                isEnabled: false,
                action: {}
            )
        } else if captureMode == .rawLiDAR, lifecycle == .pausing {
            CaptureDockButton(
                title: isDemo ? "Continue demo" : "Continue",
                systemImage: "play.fill",
                tint: .teal,
                isProminent: false,
                action: {
                    perform(.resumePreview)
                }
            )
            .accessibilityIdentifier("scanner.resumePreview")
        } else if captureMode == .rawLiDAR {
            CaptureDockButton(
                title: isDemo ? "Pause demo" : "Pause",
                systemImage: "pause.fill",
                tint: .white,
                isProminent: false,
                action: {
                    perform(.pausePreview)
                }
            )
            .accessibilityIdentifier("scanner.pausePreview")
        } else {
            CaptureDockButton(
                title: "Pause unavailable",
                systemImage: "pause.fill",
                tint: .secondary,
                isProminent: false,
                isEnabled: false,
                action: {}
            )
            .accessibilityHint("Semantic room capture cannot be paused.")
        }
    }

    private var finishControl: some View {
        CaptureDockButton(
            title: "Finish capture",
            systemImage: "checkmark",
            tint: .blue,
            isProminent: true,
            isEnabled: canFinishCapture,
            action: {
                perform(.finishPreview)
            }
        )
        .accessibilityIdentifier("scanner.finishPreview")
        .accessibilityHint(
            finishHint
        )
    }

    private var finishHint: String {
        if lifecycle == .trackingLost {
            return "Finish is unavailable until tracking is ready."
        }
        if captureMode == .rawLiDAR && !canFinishCapture {
            return "Slowly capture more surfaces or a larger area before finishing."
        }
        return "Ends capture and opens review before saving."
    }

    private var cancelControl: some View {
        CaptureDockButton(
            title: "Cancel",
            systemImage: "xmark",
            tint: .red,
            isProminent: false,
            action: requestCancellation
        )
        .accessibilityIdentifier("scanner.cancel")
        .accessibilityHint("Unsaved data will be discarded.")
    }
}

private struct CaptureDockButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isProminent: Bool
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.bold))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            .foregroundStyle(isProminent ? .white : tint)
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.horizontal, 8)
            .background(
                isProminent ? tint : Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isProminent ? Color.white.opacity(0.42) : tint.opacity(0.42), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.48)
        .accessibilityLabel(title)
    }
}

/// Draws only screen-space samples whose current AR frame contains valid scene depth.
/// It never creates, stores, or represents a persisted point cloud.
@MainActor
private struct LiveDepthPointOverlay: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> LiveDepthPointView {
        LiveDepthPointView(session: session)
    }

    func updateUIView(_ uiView: LiveDepthPointView, context: Context) {
        uiView.session = session
    }

    static func dismantleUIView(_ uiView: LiveDepthPointView, coordinator: ()) {
        uiView.stopSampling()
    }
}

@MainActor
private final class LiveDepthPointView: UIView {
    private struct WorldDepthSample {
        let worldPosition: SIMD3<Float>
        let depthMeters: Float
        let confidence: UInt8
        let capturedAt: TimeInterval
    }

    private static let targetSamplesPerFrame = 72
    private static let maximumCandidateCount = 360
    private static let maximumVisibleSamples = 1_200
    private static let sampleLifetime: TimeInterval = 2.5
    private static let maximumDepthMeters: Float = 8
    private static let minimumDepthMeters: Float = 0.15

    weak var session: ARSession?
    private var displayLink: CADisplayLink?
    private var samples: [WorldDepthSample] = []
    private var lastSampledFrameTimestamp: TimeInterval?
    private let qualityLabel = UILabel()

    init(session: ARSession) {
        self.session = session
        super.init(frame: .zero)

        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw

        qualityLabel.font = .preferredFont(forTextStyle: .subheadline)
        qualityLabel.adjustsFontForContentSizeCategory = true
        qualityLabel.textAlignment = .center
        qualityLabel.textColor = .white
        qualityLabel.numberOfLines = 2
        qualityLabel.layer.cornerRadius = 14
        qualityLabel.layer.masksToBounds = true
        qualityLabel.translatesAutoresizingMaskIntoConstraints = false
        qualityLabel.isAccessibilityElement = true
        addSubview(qualityLabel)
        NSLayoutConstraint.activate([
            qualityLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            qualityLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 76),
            qualityLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78)
        ])

        let displayLink = CADisplayLink(target: self, selector: #selector(sampleDepth))
        displayLink.preferredFramesPerSecond = 12
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    required init?(coder: NSCoder) {
        nil
    }

    func stopSampling() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func sampleDepth() {
        guard let session, let frame = session.currentFrame else {
            update(samples: [], using: nil)
            return
        }

        // A display-link callback can observe the same ARFrame more than once.
        // Keep the visualization tied to newly delivered depth frames rather than
        // making dots move independently of the LiDAR data.
        guard lastSampledFrameTimestamp != frame.timestamp else {
            return
        }
        lastSampledFrameTimestamp = frame.timestamp

        let incomingSamples = samples(from: frame)
        let oldestAllowedTime = frame.timestamp - Self.sampleLifetime
        samples.removeAll { $0.capturedAt < oldestAllowedTime }
        samples.append(contentsOf: incomingSamples)
        if samples.count > Self.maximumVisibleSamples {
            samples.removeFirst(samples.count - Self.maximumVisibleSamples)
        }
        update(samples: samples, using: frame)
    }

    private func update(samples: [WorldDepthSample], using frame: ARFrame?) {
        self.samples = samples
        updateQualityMessage(for: frame, visibleSampleCount: samples.count)
        setNeedsDisplay()
    }

    private func samples(from frame: ARFrame) -> [WorldDepthSample] {
        guard bounds.width > 0,
              bounds.height > 0,
              let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth
        else {
            return []
        }

        let depthMap = depthData.depthMap
        guard let confidenceMap = depthData.confidenceMap,
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8
        else {
            return []
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBaseAddress = CVPixelBufferGetBaseAddress(confidenceMap)
        else {
            return []
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0,
              height > 0,
              CVPixelBufferGetWidth(confidenceMap) == width,
              CVPixelBufferGetHeight(confidenceMap) == height
        else {
            return []
        }

        let depths = depthBaseAddress.assumingMemoryBound(to: Float32.self)
        let depthValuesPerRow = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let confidences = confidenceBaseAddress.assumingMemoryBound(to: UInt8.self)
        let confidenceValuesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        var result: [WorldDepthSample] = []
        result.reserveCapacity(Self.targetSamplesPerFrame)

        // These are actual LiDAR depths transformed into AR world space. Keeping a
        // short history lets the overlay move with the camera, rather than drawing
        // a screen-space grid that can look frozen over the image.
        var generator = DepthSampleGenerator(seed: frame.timestamp.bitPattern)
        var visitedPixels = Set<Int>()
        visitedPixels.reserveCapacity(Self.targetSamplesPerFrame)
        let minimumConfidence = UInt8(ARConfidenceLevel.medium.rawValue)
        let intrinsics = frame.camera.intrinsics
        let imageSize = frame.camera.imageResolution
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let depthScaleX = Float(width) / Float(imageSize.width)
        let depthScaleY = Float(height) / Float(imageSize.height)
        let fx = intrinsics.columns.0.x * depthScaleX
        let fy = intrinsics.columns.1.y * depthScaleY
        let cx = intrinsics.columns.2.x * depthScaleX
        let cy = intrinsics.columns.2.y * depthScaleY
        guard fx != 0, fy != 0 else { return [] }

        for _ in 0..<Self.maximumCandidateCount where result.count < Self.targetSamplesPerFrame {
            let column = generator.nextIndex(upperBound: width)
            let row = generator.nextIndex(upperBound: height)
            let pixelIndex = row * width + column
            guard visitedPixels.insert(pixelIndex).inserted else {
                continue
            }

            let depthMeters = depths[row * depthValuesPerRow + column]
            let confidence = confidences[row * confidenceValuesPerRow + column]
            guard depthMeters.isFinite,
                  depthMeters >= Self.minimumDepthMeters,
                  depthMeters <= Self.maximumDepthMeters,
                  confidence >= minimumConfidence
            else {
                continue
            }

            let cameraPoint = SIMD4<Float>(
                -((Float(column) - cx) / fx) * depthMeters,
                -((Float(row) - cy) / fy) * depthMeters,
                -depthMeters,
                1
            )
            let transformedPoint = frame.camera.transform * cameraPoint
            result.append(
                WorldDepthSample(
                    worldPosition: SIMD3(transformedPoint.x, transformedPoint.y, transformedPoint.z),
                    depthMeters: depthMeters,
                    confidence: confidence,
                    capturedAt: frame.timestamp
                )
            )
        }

        return result
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let frame = session?.currentFrame
        else {
            return
        }

        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        context.setBlendMode(.plusLighter)
        for sample in samples {
            let point = frame.camera.projectPoint(
                sample.worldPosition,
                orientation: orientation,
                viewportSize: bounds.size
            )
            guard bounds.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            let proximity = 1 - min(max(CGFloat(sample.depthMeters) / CGFloat(Self.maximumDepthMeters), 0), 1)
            let isHighConfidence = sample.confidence >= UInt8(ARConfidenceLevel.high.rawValue)
            let age = min(max(CGFloat(frame.timestamp - sample.capturedAt) / CGFloat(Self.sampleLifetime), 0), 1)
            let radius = 1.2 + proximity * 1.25
            let alpha = (0.28 + proximity * 0.34 + (isHighConfidence ? 0.12 : 0)) * (1 - age * 0.55)
            context.setFillColor(UIColor.systemTeal.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(
                in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        }
    }

    private func updateQualityMessage(for frame: ARFrame?, visibleSampleCount: Int) {
        guard let frame else {
            qualityLabel.text = "Waiting for camera"
            qualityLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
            return
        }

        switch frame.camera.trackingState {
        case .normal where visibleSampleCount >= 24:
            qualityLabel.text = "Capturing LiDAR data"
            qualityLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.78)
        case .normal:
            qualityLabel.text = "Keep the surface nearby and in view"
            qualityLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.82)
        case let .limited(reason):
            qualityLabel.text = trackingMessage(for: reason)
            qualityLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.82)
        case .notAvailable:
            qualityLabel.text = "Tracking unavailable; stop moving"
            qualityLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.84)
        }
    }

    private func trackingMessage(for reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:
            "Move slowly until tracking is ready"
        case .excessiveMotion:
            "Move more slowly and steadily"
        case .insufficientFeatures:
            "Keep a well-lit, detailed surface in view"
        case .relocalizing:
            "Return to the previous view to recover tracking"
        @unknown default:
            "Tracking limited; move slowly"
        }
    }
}

/// A deterministic source of bounded sample coordinates for a single AR frame.
/// Its seed comes from that frame's timestamp, so it only changes as live depth
/// frames arrive and never drives visual motion on its own.
private struct DepthSampleGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextIndex(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct ScannerPanel<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let identifier: String
    let actions: Actions

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        identifier: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.identifier = identifier
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)

            Text(message)
                .font(.body)
                .foregroundStyle(.primary)

            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
        .accessibilityIdentifier(identifier)
    }
}

private extension ScanCapabilityIssue {
    var message: String {
        switch self {
        case .lidarUnavailable:
            "Raw LiDAR capture unavailable."
        case .sceneReconstructionUnavailable:
            "Scene reconstruction unavailable."
        case .sceneDepthUnavailable:
            "Scene depth unavailable."
        case .roomPlanUnavailable:
            "RoomPlan semantic capture unavailable."
        case .cameraPermissionDenied:
            "Camera permission denied or restricted."
        case .motionTrackingUnavailable:
            "World tracking unavailable."
        case .insufficientStorage:
            "Available storage is below the capture requirement."
        }
    }
}

private extension ScannerWorkflowCommand {
    var accessibilityIdentifier: String {
        switch self {
        case .requestCameraPermission:
            "scanner.requestCameraPermission"
        case let .selectCaptureMode(mode):
            "scanner.selectCaptureMode.\(mode.rawValue)"
        case .startPreview:
            "scanner.startPreview"
        case .pausePreview:
            "scanner.pausePreview"
        case .resumePreview:
            "scanner.resumePreview"
        case .finishPreview:
            "scanner.finishPreview"
        case .finishProcessing:
            "scanner.finishProcessing"
        case .finishSaving:
            "scanner.finishSaving"
        case .recoverTracking:
            "scanner.recoverTracking"
        case .storageAvailable:
            "scanner.storageAvailable"
        case .renameReview:
            "scanner.renameReview"
        case .cancel:
            "scanner.cancel"
        }
    }
}

private extension ScanCapabilityAdvisory {
    var message: String {
        switch self {
        case .roomPlanUnavailable:
            "Semantic room capture is unavailable, but raw capture can continue."
        }
    }
}

private extension ScanCaptureMode {
    var displayName: String {
        switch self {
        case .rawLiDAR:
            "Raw LiDAR capture"
        case .semanticRoom:
            "Semantic room capture"
        }
    }

    var selectionTitle: String {
        switch self {
        case .rawLiDAR:
            "Raw LiDAR"
        case .semanticRoom:
            "Room plan"
        }
    }

    var selectionDescription: String {
        switch self {
        case .rawLiDAR:
            "Preserves raw scene depth, mesh, points, frame metadata, and optional local video."
        case .semanticRoom:
            "Creates a separate semantic USDZ with RoomPlan without collecting raw mesh or frame assets."
        }
    }

    var captureNotice: String {
        switch self {
        case .rawLiDAR:
            "Capture stays local on this device. Raw capture is available only when compatible LiDAR support is reported."
        case .semanticRoom:
            "Capture stays local on this device. RoomPlan creates a semantic room plan in a separate, user-selected session."
        }
    }

    var startActionTitle: String {
        switch self {
        case .rawLiDAR:
            "raw capture"
        case .semanticRoom:
            "room capture"
        }
    }

    var finishActionTitle: String {
        switch self {
        case .rawLiDAR:
            "raw capture"
        case .semanticRoom:
            "room capture"
        }
    }

    var readyDescription: String {
        switch self {
        case .rawLiDAR:
            "Starting capture creates local staging files before saving a managed package."
        case .semanticRoom:
            "Room capture uses a separate RoomPlan session and saves a semantic USDZ in the managed package."
        }
    }

    var scanningDescription: String {
        switch self {
        case .rawLiDAR:
            "Copied frame metadata, depth-derived points, and mesh snapshots are written to local staging files."
        case .semanticRoom:
            "RoomPlan is mapping a semantic room locally. Finish when the plan is complete; semantic capture cannot be paused."
        }
    }

    var processingDescription: String {
        switch self {
        case .rawLiDAR:
            "Finalizing capture files in local staging. Saving creates a managed package and SQLite metadata record."
        case .semanticRoom:
            "RoomPlan is finalizing a semantic USDZ in local staging. Saving creates a managed package and SQLite metadata record."
        }
    }

    var packageDescription: String {
        switch self {
        case .rawLiDAR:
            "Raw scan"
        case .semanticRoom:
            "Semantic room"
        }
    }
}

private extension ScanFailureReason {
    var title: String {
        switch self {
        case .unsupportedDevice:
            "Capture unavailable"
        case .permissionDenied:
            "Camera access denied"
        case .sensorUnavailable:
            "Camera unavailable"
        case .interrupted:
            "Capture interrupted"
        case .noSpatialData:
            "Scan not captured"
        case .processingFailed:
            "Processing incomplete"
        case .saveFailed:
            "Save incomplete"
        case .corruptedAsset:
            "Invalid capture asset"
        case .unknown:
            "Scanner workflow needs attention"
        }
    }

    var message: String {
        switch self {
        case .unsupportedDevice:
            "This device does not meet raw LiDAR capture requirements. Simulator results do not validate sensors."
        case .permissionDenied:
            "Camera access was denied or restricted. You can change this in Settings before trying again."
        case .sensorUnavailable:
            "The camera or required sensors did not respond. Close the app and other camera apps, then try again."
        case .interrupted:
            "Capture was interrupted before a complete local package was saved."
        case .noSpatialData:
            "Not enough spatial data was captured. Move around slightly and try again."
        case .processingFailed:
            "Capture files could not be finalized. No incomplete package was added to the library."
        case .saveFailed:
            "The local package or SQLite metadata record could not be saved."
        case .corruptedAsset:
            "The source package must stay immutable while its integrity issue is investigated."
        case .unknown:
            "The workflow could not advance from its current state. Check the injected service result and try again."
        }
    }
}

#Preview("Scanner - Capability Unavailable") {
    ScannerWorkflowView(
        model: ScannerWorkflowModel(service: DemoScannerWorkflowService(scenario: .unavailable), isDemo: true),
        dismiss: {}
    )
}

#Preview("Scanner - Ready") {
    ScannerWorkflowView(
        model: ScannerWorkflowModel(service: DemoScannerWorkflowService(scenario: .ready), isDemo: true),
        dismiss: {}
    )
}
