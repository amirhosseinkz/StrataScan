import CoreGraphics
import Foundation
import Testing
@testable import StrataCore

@Suite("Capture event cadence")
struct CaptureEventCadenceTests {
    @Test("Spatial copying is admitted at a bounded cadence and after a reset")
    func admitsBoundedSamples() {
        let cadence = CaptureEventCadence(maximumFrequency: 10)

        #expect(cadence.admits(timestamp: 0, after: -Double.infinity))
        #expect(!cadence.admits(timestamp: 0.09, after: 0))
        #expect(cadence.admits(timestamp: 0.11, after: 0))
        #expect(cadence.admits(timestamp: 0.01, after: 1))
        #expect(!cadence.admits(timestamp: .nan, after: 0))
    }

    @Test("Final mesh sweeps are fair, deterministic, and bounded")
    func selectsBoundedFinalMeshAnchors() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let third = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let fourth = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let selector = MeshSnapshotAnchorSelector(maximumCount: 2)

        let selected = selector.select(
            from: [fourth, second, first, third, first],
            lastSnapshotTimestampByAnchorID: [
                second: 20,
                third: 10,
                fourth: 30
            ]
        )

        #expect(selected == [first, third])
    }

    @Test("Final mesh sweeps tolerate invalid timestamps and an empty budget")
    func handlesInvalidFinalMeshSweepInputs() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        let invalidTimestampSelection = MeshSnapshotAnchorSelector(maximumCount: 1).select(
            from: [second, first],
            lastSnapshotTimestampByAnchorID: [second: .nan]
        )
        let emptyBudgetSelection = MeshSnapshotAnchorSelector(maximumCount: 0).select(
            from: [first, second],
            lastSnapshotTimestampByAnchorID: [:]
        )

        #expect(invalidTimestampSelection == [first])
        #expect(emptyBudgetSelection.isEmpty)
    }

    @Test("QuickTime orientation metadata uses ARKit's landscape-right buffer basis")
    func mapsInterfaceOrientationToTrackTransform() {
        let width = 1920
        let height = 1440

        expect(
            CaptureVideoOrientation.landscapeRight.trackTransform(frameWidth: width, frameHeight: height),
            equals: .identity
        )
        expect(
            CaptureVideoOrientation.portrait.trackTransform(frameWidth: width, frameHeight: height),
            equals: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1440, ty: 0)
        )
        expect(
            CaptureVideoOrientation.landscapeLeft.trackTransform(frameWidth: width, frameHeight: height),
            equals: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1440)
        )
        expect(
            CaptureVideoOrientation.portraitUpsideDown.trackTransform(frameWidth: width, frameHeight: height),
            equals: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)
        )
    }

    private func expect(_ actual: CGAffineTransform, equals expected: CGAffineTransform) {
        #expect(actual.a == expected.a)
        #expect(actual.b == expected.b)
        #expect(actual.c == expected.c)
        #expect(actual.d == expected.d)
        #expect(actual.tx == expected.tx)
        #expect(actual.ty == expected.ty)
    }
}
