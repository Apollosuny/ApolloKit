import ApolloKitCore
import SwiftUI

struct CleanBar: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 12) {
            status
            Spacer()
            Button("Clean Up…") { isConfirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog(confirmationTitle, isPresented: $isConfirming) {
            Button("Move to Trash") { model.clean(mode: .moveToTrash) }
            Button("Delete Permanently", role: .destructive) { model.clean(mode: .deletePermanently) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .scanning(let status):
            ProgressView().controlSize(.small)
            Text(status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .cleaning(let completed, let total):
            ProgressView(value: Double(completed), total: Double(max(total, 1)))
                .frame(width: 160)
            Text("Cleaning \(completed)/\(total)…").foregroundStyle(.secondary)
        case .idle:
            Text("\(model.selectedItemIDs.count) selected · \(model.selectedBytes.formatted(.byteCount(style: .file)))")
                .monospacedDigit()
        }
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
