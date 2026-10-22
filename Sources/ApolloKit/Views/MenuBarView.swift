import ApolloKitCore
import AppKit
import SwiftUI

/// Status item: the app glyph plus free space, or progress while a scan or cleanup runs.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
            } else {
                Image(nsImage: MenuBarGlyph.image)
            }
            if let text {
                Text(text).monospacedDigit()
            }
        }
    }

    /// `nil` shows the app's own glyph; progress and warnings use system symbols.
    private var symbolName: String? {
        switch model.phase {
        case .scanning: "sparkle.magnifyingglass"
        case .cleaning: "sparkles"
        case .idle: model.isDiskSpaceLow ? "exclamationmark.triangle.fill" : nil
        }
    }

    private var text: String? {
        switch model.phase {
        case .scanning:
            return model.scanFraction.map { "\(Int($0 * 100))%" } ?? "Scanning"
        case .cleaning(let completed, let total):
            return "\(completed)/\(total)"
        case .idle:
            guard model.preferences.showsFreeSpaceInMenuBar, let disk = model.diskSpace else { return nil }
            return disk.availableBytes.fileSize
        }
    }
}

/// The app icon's platter, drawn as a template image so it follows the menu bar's appearance.
enum MenuBarGlyph {
    static let image: NSImage = {
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="18" height="18"><path d="M4.9 9a4.1 4.1 0 1 0 8.2 0a4.1 4.1 0 1 0 -8.2 0ZM7.2 9a1.8 1.8 0 1 1 3.6 0a1.8 1.8 0 1 1 -3.6 0ZM16.19 7.73A7.3 7.3 0 1 1 11.5 2.14L10.66 4.44A4.85 4.85 0 1 0 13.78 8.16Z" fill="#000" fill-rule="evenodd"/><path d="M12.49 1.3A7.3 7.3 0 0 1 17.18 6.9L14.77 7.32A4.85 4.85 0 0 0 11.65 3.61Z" fill="#000"/></svg>"##
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)!
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        image.accessibilityDescription = "ApolloKit"
        return image
    }()
}

/// Compact popover: disk, latest findings, two actions. Deletion always goes through the main window's review.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private let topGroupCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let disk = model.diskSpace {
                diskSection(disk)
            }
            Divider()
            findingsSection
            actions
            if !model.ports.developerPorts.isEmpty {
                Divider()
                portsSection
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 290)
        .onAppear {
            model.refreshDiskSpace()
            model.ports.reload()
            model.openMainWindow = { [openWindow] in openWindow(id: ApolloKitApp.mainWindowID) }
        }
    }

    private func diskSection(_ disk: DiskSpace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(disk.availableBytes.fileSize) free")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(model.isDiskSpaceLow ? Color.orange : .primary)
                Spacer()
                Text("of \(disk.totalBytes.fileSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: disk.usedFraction)
                .tint(model.isDiskSpaceLow ? .orange : .accentColor)
        }
    }

    @ViewBuilder
    private var findingsSection: some View {
        switch model.phase {
        case .scanning(let status):
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.liveTotalBytes.fileSize) found so far")
                    .font(.headline)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.liveTotalBytes)
                if let fraction = model.scanFraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .cleaning(let completed, let total):
            VStack(alignment: .leading, spacing: 6) {
                Text("Cleaning \(completed) of \(total)…").font(.headline)
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                if let name = model.cleaningItemName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case .idle:
            if let report = model.report {
                reportSummary(report)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not scanned yet").font(.headline)
                    Text("Scan to find caches and build artifacts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reportSummary(_ report: ScanReport) -> some View {
        let groups = model.groupsWithFindings
        let otherBytes = groups.dropFirst(topGroupCount).reduce(0) { $0 + model.totalBytes(in: $1) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(report.totalBytes.fileSize)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("reclaimable")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 5) {
                ForEach(groups.prefix(topGroupCount)) { group in
                    summaryRow(title: group.title, bytes: model.totalBytes(in: group)) {
                        GroupIcon(group: group, size: 16)
                    }
                }
                if otherBytes > 0 {
                    summaryRow(title: "Other", bytes: otherBytes) {
                        Image(systemName: "ellipsis.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                }
            }

            TimelineView(.everyMinute) { _ in
                Group {
                    if model.showsCompletion, let outcome = model.lastOutcome {
                        Text("Freed \(outcome.reclaimedBytes.fileSize) · scanned \(report.finishedAt, format: .relative(presentation: .named))")
                    } else {
                        Text("Scanned \(report.finishedAt, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow<Icon: View>(title: String, bytes: Int64, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(title).lineLimit(1)
            Spacer()
            Text(bytes.fileSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                Button { model.cancel() } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()
            } else if model.report == nil {
                // Before the first scan there is nothing to review, so Scan is the only action.
                Button { model.startScan() } label: {
                    Text("Scan").frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
            } else {
                Button { model.startScan() } label: {
                    Text("Scan Again").frame(maxWidth: .infinity)
                }
                .secondaryActionStyle()

                Button { showMainWindow() } label: {
                    Text("Review & Clean").frame(maxWidth: .infinity)
                }
                .prominentActionStyle()
                .disabled(model.report?.items.isEmpty ?? true)
            }
        }
        .controlSize(.large)
    }

    private var portsSection: some View {
        let ports = model.ports.developerPorts
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ports in Use").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(ports.count > maxPortRows ? "All \(ports.count)" : "Manage") {
                    model.requestedSidebarSelection = .ports
                    showMainWindow()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            ForEach(ports.prefix(maxPortRows)) { port in
                MenuBarPortRow(port: port)
            }
        }
    }

    private let maxPortRows = 4

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open ApolloKit") { showMainWindow() }
            Spacer()
            Button {
                AppActivation.bringToFront()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit ApolloKit")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .font(.callout)
    }

    private func showMainWindow() {
        model.openMainWindow = { [openWindow] in openWindow(id: ApolloKitApp.mainWindowID) }
        model.showMainWindow()
    }
}


/// One port in the popover. Stop needs a second click instead of a dialog, which popovers handle poorly.
private struct MenuBarPortRow: View {
    @Environment(AppModel.self) private var model
    let port: ListeningPort
    @State private var isConfirmingStop = false

    var body: some View {
        let ports = model.ports
        HStack(spacing: 8) {
            Button { ports.open(port) } label: {
                HStack(spacing: 8) {
                    Text(String(port.port))
                        .monospacedDigit()
                        .fontWeight(.medium)
                        .frame(minWidth: 40, alignment: .leading)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open http://localhost:\(String(port.port))")

            Spacer(minLength: 4)

            if ports.stoppingPortIDs.contains(port.id) {
                ProgressView().controlSize(.mini)
            } else if ports.unresponsivePortIDs.contains(port.id) {
                Button("Force Stop") { ports.stop(port, force: true) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            } else if ports.canStop(port) {
                if isConfirmingStop {
                    Button("Stop?") { ports.stop(port) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                } else {
                    Button { isConfirmingStop = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop \(port.processName)")
                }
            }
        }
        .font(.callout)
        .task(id: isConfirmingStop) {
            // An unanswered confirmation reverts, so a later stray click can't stop the process.
            guard isConfirmingStop else { return }
            try? await Task.sleep(for: .seconds(3))
            isConfirmingStop = false
        }
    }

    private var subtitle: String {
        let project = port.projectURL(homeDirectory: model.ports.homeDirectory)?.lastPathComponent
        return [port.processName, project].compactMap { $0 }.joined(separator: " · ")
    }
}
