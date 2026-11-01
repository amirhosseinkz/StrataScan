import Testing
@testable import StrataCore

@Suite("Scan lifecycle")
struct ScanLifecycleTests {
    @Test("A supported, authorized scan reaches completion through explicit states")
    func completesHappyPath() throws {
        var machine = ScanLifecycleMachine()

        try machine.send(.begin)
        try machine.send(.preparationComplete)
        try machine.send(.capabilitiesAvailable)
        try machine.send(.permissionsGranted)
        try machine.send(.scanStarted)
        try machine.send(.scanFinished)
        try machine.send(.processingFinished)
        try machine.send(.saveSucceeded)

        #expect(machine.state == .completed)
    }

    @Test("Tracking loss pauses capture until tracking recovers")
    func recoversFromTrackingLoss() throws {
        var machine = ScanLifecycleMachine(state: .scanning)

        try machine.send(.trackingDegraded)
        #expect(machine.state == .trackingLost)

        try machine.send(.trackingRecovered)
        #expect(machine.state == .scanning)
    }

    @Test("Invalid transitions leave the state unchanged")
    func rejectsInvalidTransition() {
        var machine = ScanLifecycleMachine()

        #expect(throws: ScanLifecycleError.invalidTransition(from: .idle, event: .scanFinished)) {
            try machine.send(.scanFinished)
        }
        #expect(machine.state == .idle)
    }
}
