import ApolloKitCore
import SwiftUI

/// Floating bar over Smart Scan, a category or Projects: what is selected there and the Clean Up action.
struct CleanBar: View {
    @Environment(AppModel.self) private var model
    @State private var pendingMode: DeletionMode?
    @State private var isReviewing = false
    /// The screen the bar sits on; it decides what is cleaned and which shortcut sits next to Clean Up.
    let screen: SidebarSelection

    private var scope: RuleGroup? { screen.cleanScope }

    var body: some View {
        let selected = model.selectedItems(in: scope)
        let selectedBytes = selected.reduce(0) { $0 + $1.sizeInBytes }

        if isVisible {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(selectedBytes: selectedBytes))
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(subtitle(selected: selected))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.snappy, value: selectedBytes)

                secondaryAction(selected: selected)
                    .capsuleButtonStyle()
                    .controlSize(.large)

                Menu {
                    Button("Move to Trash") { clean(.moveToTrash, selected) }
                    Button("Delete Permanently…") { pendingMode = .deletePermanently }
                    Divider()
                    Button("Review Selection…") { isReviewing = true }
                } label: {
                    Text("Clean Up")
                        .fontWeight(.semibold)
                } primaryAction: {
                    clean(.moveToTrash, selected)
                }
                .menuStyle(.button)
                .prominentActionStyle()
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .fixedSize()
                .disabled(selected.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(height: 58)
            .floatingPanelBackground()
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .confirmationDialog(
                pendingMode == .deletePermanently
                    ? "Delete \(selected.count) items (\(selectedBytes.fileSize)) permanently?"
                    : "Clean \(selected.count) items (\(selectedBytes.fileSize))?",
                isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } })
            ) {
                if pendingMode == .deletePermanently {
                    Button("Delete Permanently", role: .destructive) { model.clean(mode: .deletePermanently, in: scope) }
                } else {
                    Button("Move to Trash") { model.clean(mode: .moveToTrash, in: scope) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage(for: selected, mode: pendingMode ?? .moveToTrash))
            }
            .sheet(isPresented: $isReviewing) {
                SelectionReview(items: selected) { isReviewing = false }
            }
        }
    }

    /// Scanning and cleaning have their own full-screen progress, so the bar only appears over results.
    private var isVisible: Bool {
        !model.isBusy && model.report != nil && !model.showsCompletion && !(model.report?.items.isEmpty ?? true)
    }

    /// Moving safe items to the Trash is undoable, so it needs no question; anything that needs a decision or skips the Trash does.
    private func clean(_ mode: DeletionMode, _ selected: [CleanupItem]) {
        if selected.contains(where: { $0.risk == .caution || $0.isAlwaysPermanent }) {
            pendingMode = mode
        } else {
            model.clean(mode: mode, in: scope)
        }
    }

    private func title(selectedBytes: Int64) -> String {
        switch screen {
        case .group(let group):
            "\(selectedBytes.fileSize) of \(model.totalBytes(in: group).fileSize) selected"
        default:
            "\(selectedBytes.fileSize) selected"
        }
    }

    private func subtitle(selected: [CleanupItem]) -> String {
        let count = selected.count == 1 ? "1 item" : "\(selected.count) items"
        // On a category screen, selections in other categories stay selected but are not cleaned from here.
        let elsewhere = scope == nil ? 0 : model.selectedItemIDs.count - selected.count
        let elsewhereNote = elsewhere > 0 ? " · \(elsewhere) more selected elsewhere" : ""
        switch screen {
        case .group(let group):
            let leftForUser = model.items(in: group).filter { $0.risk == .caution && !model.selectedItemIDs.contains($0.id) }.count
            let cautionNote = leftForUser > 0 ? " · \(leftForUser) caution items are left for you to decide" : ""
            return count + cautionNote + elsewhereNote
        case .projects:
            let stale = model.projects.filter(\.isStale).count
            return "\(stale) stale projects · active projects are never selected" + elsewhereNote
        default:
            let groups = Set(selected.map(\.rule.group)).count
            return "\(count) in \(groups == 1 ? "1 category" : "\(groups) categories") · moves to the Trash, restorable until you empty it"
        }
    }

    @ViewBuilder
    private func secondaryAction(selected: [CleanupItem]) -> some View {
        switch screen {
        case .group(let group):
            Button("Select All Safe") { model.select(model.items(in: group).filter { $0.risk == .safe }, true) }
        case .projects:
            Button("Deselect All") { model.select(model.items(in: .projectArtifacts), false) }
                .disabled(selected.isEmpty)
        default:
            Button("Review…") { isReviewing = true }
                .disabled(selected.isEmpty)
        }
    }

    private func confirmationMessage(for selected: [CleanupItem], mode: DeletionMode) -> String {
        var lines: [String] = []
        let cautionCount = selected.filter { $0.risk == .caution }.count
        if cautionCount > 0 {
            lines.append("\(cautionCount) items are marked Caution and may be slow to regenerate or contain data worth keeping.")
        }
        let permanentCount = selected.filter(\.isAlwaysPermanent).count
        if mode == .moveToTrash, permanentCount > 0 {
            lines.append("\(permanentCount) items (Trash contents, simulators, Docker) are always removed permanently through their own tools.")
        }
        lines.append(mode == .moveToTrash
            ? "Everything else goes to the Trash, so you can put it back until you empty it."
            : "Nothing goes to the Trash. This cannot be undone.")
        return lines.joined(separator: "\n\n")
    }
}

/// Everything a Clean Up would remove, by category, before committing to it.
private struct SelectionReview: View {
    let items: [CleanupItem]
    let dismiss: () -> Void

    var body: some View {
        let total = items.reduce(0) { $0 + $1.sizeInBytes }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Selection").font(.title3.weight(.semibold))
                Text("\(total.fileSize) in \(items.count) items")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(20)

            List {
                ForEach(RuleGroup.allCases.filter { group in items.contains { $0.rule.group == group } }) { group in
                    Section {
                        ForEach(items.filter { $0.rule.group == group }.sorted { $0.sizeInBytes > $1.sizeInBytes }) { item in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.displayName).lineLimit(1)
                                    Text(item.locationDescription)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if item.risk == .caution || item.isAlwaysPermanent {
                                    SafetyLabel(risk: item.risk, isPermanent: item.isAlwaysPermanent)
                                        .font(.caption)
                                }
                                Text(item.sizeInBytes.fileSize)
                                    .monospacedDigit()
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            GroupIcon(group: group, size: 18)
                            Text(group.title)
                        }
                    }
                }
            }
            .frame(minHeight: 320)

            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 520)
    }
}
