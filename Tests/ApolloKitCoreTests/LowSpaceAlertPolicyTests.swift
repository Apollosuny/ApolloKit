import Foundation
import Testing
@testable import ApolloKitCore

@Suite struct LowSpaceAlertPolicyTests {
    private let policy = LowSpaceAlertPolicy(thresholdBytes: 20_000_000_000)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func alertsWhenSpaceDropsBelowTheThreshold() {
        #expect(policy.shouldAlert(availableBytes: 15_000_000_000, wasLow: false, lastAlertAt: nil, now: now))
        #expect(!policy.shouldAlert(availableBytes: 25_000_000_000, wasLow: false, lastAlertAt: nil, now: now))
    }

    @Test func staysQuietWhileSpaceRemainsLow() {
        #expect(!policy.shouldAlert(availableBytes: 15_000_000_000, wasLow: true, lastAlertAt: nil, now: now))
    }

    @Test func alertsAtMostOncePerInterval() {
        let recent = now.addingTimeInterval(-3_600)
        let old = now.addingTimeInterval(-25 * 3_600)
        #expect(!policy.shouldAlert(availableBytes: 15_000_000_000, wasLow: false, lastAlertAt: recent, now: now))
        #expect(policy.shouldAlert(availableBytes: 15_000_000_000, wasLow: false, lastAlertAt: old, now: now))
    }
}
