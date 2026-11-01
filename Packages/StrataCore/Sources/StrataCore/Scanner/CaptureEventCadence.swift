import Foundation

/// Keeps copied scan values bounded when ARKit produces camera callbacks faster
/// than the package needs them. Timestamps come from one AR session and may
/// restart after a session reset, so an earlier timestamp is admitted.
struct CaptureEventCadence: Sendable {
    let minimumInterval: TimeInterval

    init(maximumFrequency: Double) {
        minimumInterval = maximumFrequency > 0 ? 1 / maximumFrequency : .infinity
    }

    func admits(timestamp: TimeInterval, after previousTimestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite else {
            return false
        }
        guard previousTimestamp.isFinite else {
            return true
        }
        return timestamp < previousTimestamp || timestamp - previousTimestamp >= minimumInterval
    }
}

/// Selects a small, fair set of mesh anchors for one copied-event batch.
/// Anchors not yet represented in the collector are selected first; otherwise
/// the least-recently emitted anchor wins. The deterministic identifier
/// tie-breaker makes the bound testable without ARKit hardware.
struct MeshSnapshotAnchorSelector: Sendable {
    let maximumCount: Int

    init(maximumCount: Int) {
        self.maximumCount = max(0, maximumCount)
    }

    func select(
        from anchorIDs: [UUID],
        lastSnapshotTimestampByAnchorID: [UUID: TimeInterval]
    ) -> [UUID] {
        guard maximumCount > 0 else { return [] }

        var seen = Set<UUID>()
        let uniqueAnchorIDs = anchorIDs.filter { seen.insert($0).inserted }
        return uniqueAnchorIDs
            .sorted { lhs, rhs in
                let lhsTimestamp = timestamp(for: lhs, in: lastSnapshotTimestampByAnchorID)
                let rhsTimestamp = timestamp(for: rhs, in: lastSnapshotTimestampByAnchorID)
                if lhsTimestamp == rhsTimestamp {
                    return lhs.uuidString < rhs.uuidString
                }
                return lhsTimestamp < rhsTimestamp
            }
            .prefix(maximumCount)
            .map { $0 }
    }

    private func timestamp(
        for anchorID: UUID,
        in timestamps: [UUID: TimeInterval]
    ) -> TimeInterval {
        guard let timestamp = timestamps[anchorID], timestamp.isFinite else {
            return -.infinity
        }
        return timestamp
    }
}
