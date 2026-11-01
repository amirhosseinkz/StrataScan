import Testing
@testable import StrataCore

@Suite("Raw capture recording lifecycle")
struct CaptureRecordingLifecycleTests {
    @Test("A capture emits one terminal transition and requires a new configuration")
    func stopIsIdempotentAndCannotRestartStaleWriter() throws {
        var lifecycle = CaptureRecordingLifecycle()

        try lifecycle.configure()
        try lifecycle.start()
        #expect(lifecycle.state == .capturing)

        let firstStop = lifecycle.stop()
        let repeatedStop = lifecycle.stop()
        #expect(firstStop)
        #expect(!repeatedStop)
        #expect(lifecycle.state == .stopped)
        #expect(throws: CaptureRecordingLifecycle.LifecycleError.captureAlreadyActive) {
            try lifecycle.start()
        }
    }

    @Test("Only a stopped capture can finalize and cancellation releases it")
    func finalizationRejectsReentryAndCancelResetsTheState() throws {
        var lifecycle = CaptureRecordingLifecycle()
        try lifecycle.configure()
        try lifecycle.start()

        #expect(throws: CaptureRecordingLifecycle.LifecycleError.captureNotStopped) {
            try lifecycle.beginFinalization()
        }

        let didStop = lifecycle.stop()
        #expect(didStop)
        try lifecycle.beginFinalization()
        #expect(lifecycle.state == .finalizing)
        #expect(throws: CaptureRecordingLifecycle.LifecycleError.finalizationInProgress) {
            try lifecycle.beginFinalization()
        }

        lifecycle.cancel()
        #expect(lifecycle.state == .unconfigured)
        #expect(throws: CaptureRecordingLifecycle.LifecycleError.recordingNotConfigured) {
            try lifecycle.beginFinalization()
        }
    }

    @Test("A completed writer cannot be reused by a later capture")
    func completedFinalizationReturnsToUnconfigured() throws {
        var lifecycle = CaptureRecordingLifecycle()
        try lifecycle.configure()
        try lifecycle.start()
        let didStop = lifecycle.stop()
        #expect(didStop)
        try lifecycle.beginFinalization()

        lifecycle.completeFinalization()

        #expect(lifecycle.state == .unconfigured)
        #expect(throws: CaptureRecordingLifecycle.LifecycleError.recordingNotConfigured) {
            try lifecycle.start()
        }
    }
}
