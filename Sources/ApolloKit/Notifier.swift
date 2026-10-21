import AppKit
import UserNotifications

/// Posts the low-space notification and routes a click on it back to the app.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Authorization {
        case notDetermined, allowed, denied
    }

    private static let lowSpaceIdentifier = "lowDiskSpace"

    var onOpen: (() -> Void)?

    /// `UNUserNotificationCenter` requires a bundle; a bare `swift run` executable has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func authorization() async -> Authorization {
        guard let center else { return .denied }
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func postLowSpace(availableBytes: Int64, reclaimableBytes: Int64?) async {
        guard let center, await requestAuthorization() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Only \(availableBytes.fileSize) free on your Mac"
        if let reclaimableBytes, reclaimableBytes > 0 {
            content.body = "ApolloKit found about \(reclaimableBytes.fileSize) of caches and build data you can clean. Click to review."
        } else {
            content.body = "Click to scan for caches and build data you can clean."
        }
        content.sound = .default
        // A fixed identifier replaces an older, still-visible warning instead of stacking.
        let request = UNNotificationRequest(identifier: Self.lowSpaceIdentifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    func openNotificationSettings() {
        let identifier = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { onOpen?() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
