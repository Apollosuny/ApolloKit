import Foundation

/// Decides when to warn about low free space: once when space drops below the threshold,
/// and never more than once per `minimumInterval`, so a disk hovering at the limit stays quiet.
public struct LowSpaceAlertPolicy: Sendable {
    public let thresholdBytes: Int64
    public let minimumInterval: TimeInterval

    public init(thresholdBytes: Int64, minimumInterval: TimeInterval = 24 * 60 * 60) {
        self.thresholdBytes = thresholdBytes
        self.minimumInterval = minimumInterval
    }

    public func isLow(availableBytes: Int64) -> Bool {
        availableBytes < thresholdBytes
    }

    /// - Parameters:
    ///   - wasLow: whether the previous check was already below the threshold (`false` on the first check after launch).
    ///   - lastAlertAt: when the last warning was shown, persisted across launches.
    public func shouldAlert(availableBytes: Int64, wasLow: Bool, lastAlertAt: Date?, now: Date = .now) -> Bool {
        guard isLow(availableBytes: availableBytes), !wasLow else { return false }
        guard let lastAlertAt else { return true }
        return now.timeIntervalSince(lastAlertAt) >= minimumInterval
    }
}
