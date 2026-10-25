import ApolloKitCore
import SwiftUI

struct CleanBar: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false
    /// The category this bar cleans; `nil` cleans the selection in every category.
    let scope: RuleGroup?

    var body: some View {
        let selected = model.selectedItems(in: scope)
        let selectedBytes = selected.reduce(0) { $0 + $1.sizeInBytes }

        if isVisible {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedBytes.fileSize)
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: selectedBytes)
                    Text(selectionSummary(count: selected.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    isConfirming = true
                } label: {
                    Label("Clean Up", systemImage: "sparkles")
                        .padding(.horizontal, 6)
                }
                .prominentActionStyle()
                .controlSize(.large)
                .disabled(selected.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .floatingBarBackground()
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .confirmationDialog(
                "Clean \(selected.count) items (\(selectedBytes.fileSize))?",
                isPresented: $isConfirming
            ) {
                Button("Move to Trash") { model.clean(mode: .moveToTrash, in: scope) }
                Button("Delete Permanently", role: .destructive) { model.clean(mode: .deletePermanently, in: scope) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage(for: selected))
            }
        }
    }

    /// Scanning and cleaning have their own full-screen progress, so the bar only appears over results.
    private var isVisible: Bool {
        !model.isBusy && model.report != nil && !model.showsCompletion && !(model.report?.items.isEmpty ?? true)
    }

    /// On a category screen, selections in other categories stay selected but are not cleaned from here.
    private func selectionSummary(count: Int) -> String {
        let elsewhere = scope == nil ? 0 : model.selectedItemIDs.count - count
        let title = scope == .projectArtifacts ? "in projects" : "in this category"
        return elsewhere > 0
            ? "\(count) items \(title) · \(elsewhere) more selected elsewhere"
            : "\(count) items selected"
    }

    private func confirmationMessage(for selected: [CleanupItem]) -> String {
        var lines: [String] = []
        let cautionCount = selected.filter { $0.risk == .caution }.count
        if cautionCount > 0 {
            lines.append("\(cautionCount) items are marked Caution and may be slow to regenerate or contain data worth keeping.")
        }
        let permanentCount = selected.filter(\.isAlwaysPermanent).count
        if permanentCount > 0 {
            lines.append("\(permanentCount) items (Trash contents, simulators, Docker) are always removed permanently through their own tools.")
        }
        lines.append("Moving to Trash lets you restore items; space is freed once the Trash is emptied.")
        return lines.joined(separator: "\n\n")
    }
}
