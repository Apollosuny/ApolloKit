import AppKit
import SwiftUI

@main
struct ApolloKitApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("ApolloKit", id: Self.mainWindowID) {
            ContentView()
                .environment(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.preferences.showsMenuBarExtra },
            set: { model.preferences.showsMenuBarExtra = $0 }
        )) {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum AppActivation {
    /// Shows the Dock icon again and brings the app forward before a window opens.
    static func bringToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Titled, normal-level windows (main and Settings); excludes the menu bar panel and open/save panels.
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && window.level == .normal && !(window is NSPanel)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run`) rather than an .app bundle.
        AppActivation.bringToFront()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closingWindowID = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { Self.hideDockIconIfNoWindows(excluding: closingWindowID) }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let isAppWindow = (note.object as? NSWindow).map { window in
                MainActor.assumeIsolated { AppActivation.isAppWindow(window) }
            } ?? false
            MainActor.assumeIsolated {
                if isAppWindow, NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                }
            }
        })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Preferences.storedShowsMenuBarExtra()
    }

    /// With the menu bar item enabled, the app lives on in the menu bar once its last window closes.
    private static func hideDockIconIfNoWindows(excluding closingWindowID: ObjectIdentifier?) {
        guard Preferences.storedShowsMenuBarExtra() else { return }
        let hasOpenWindow = NSApp.windows.contains { window in
            ObjectIdentifier(window) != closingWindowID && window.isVisible && AppActivation.isAppWindow(window)
        }
        if !hasOpenWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
