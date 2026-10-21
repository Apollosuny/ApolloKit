import ApolloKitCore
import SwiftUI

struct CleanBar: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        if isVisible {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.selectedBytes.fileSize)
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.selectedBytes)
                    Text("\(model.selectedItemIDs.count) items selected")
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
                .disabled(model.selectedItemIDs.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .floatingBarBackground()
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .confirmationDialog(confirmationTitle, isPresented: $isConfirming) {
                Button("Move to Trash") { model.clean(mode: .moveToTrash) }
                Button("Delete Permanently", role: .destructive) { model.clean(mode: .deletePermanently) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    /// Scanning and cleaning have their own full-screen progress, so the bar only appears over results.
    private var isVisible: Bool {
        !model.isBusy && model.report != nil && !model.showsCompletion && !(model.report?.items.isEmpty ?? true)
    }

    private var confirmationTitle: String {
        "Clean \(model.selectedItemIDs.count) items (\(model.selectedBytes.formatted(.byteCount(style: .file))))?"
    }

    private var confirmationMessage: String {
        let selected = model.selectedItems
        var lines: [String] = []
        let cautionCount = selected.filter { $0.rule.risk == .caution }.count
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
