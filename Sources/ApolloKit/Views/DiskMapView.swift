import ApolloKitCore
import AppKit
import SwiftUI

struct DiskMapView: View {
    @Environment(AppModel.self) private var model

    private var diskMap: DiskMapModel { model.diskMap }

    var body: some View {
        Group {
            if let focused = diskMap.focusedNode, let root = diskMap.root {
                DiskMapContent(root: root, focused: focused)
            } else if diskMap.isScanning {
                DiskMapScanningView()
            } else {
                DiskMapStartView()
            }
        }
        .navigationTitle("Disk Map")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                if diskMap.isScanning {
                    Button("Stop", systemImage: "stop.circle") { diskMap.cancelScan() }
                } else if diskMap.root != nil {
                    Button("Rescan", systemImage: "arrow.clockwise") { diskMap.scan() }
                        .help("Measure the home folder again")
                }
            }
        }
    }

    private var subtitle: String {
        if diskMap.isScanning, diskMap.root != nil { return "Rescanning… \(diskMap.scannedBytes.fileSize)" }
        guard let scannedAt = diskMap.scannedAt else { return "" }
        return "Scanned \(scannedAt.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Start and progress

private struct DiskMapStartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 56))
                .foregroundStyle(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 6) {
                Text("See where your space went").font(.title2.weight(.semibold))
                Text("Measures every folder in your home folder, including what Smart Scan has no rule for, so you can find and remove what is taking up space.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            Button("Map Home Folder") { model.diskMap.scan() }
                .prominentActionStyle()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("Usually takes under a minute. Nothing is removed until you collect items and confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiskMapScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let diskMap = model.diskMap
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("\(diskMap.scannedBytes.fileSize) measured")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: diskMap.scannedBytes)
            Text("\(diskMap.scannedItemCount.formatted()) files")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(diskMap.currentPath.replacingOccurrences(of: diskMap.homeDirectory.path, with: "~"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
            Button("Stop") { diskMap.cancelScan() }
                .secondaryActionStyle()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Map

private struct DiskMapContent: View {
    @Environment(AppModel.self) private var model
    let root: DiskNode
    let focused: DiskNode

    @State private var hoveredNode: DiskNode?
    @State private var isConfirming = false

    private var diskMap: DiskMapModel { model.diskMap }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DiskOverview(home: root)
                if root.unreadableCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield").foregroundStyle(.orange)
                        Text("\(root.unreadableCount) folders could not be read. Grant Full Disk Access for complete sizes.")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 12)
                        Button("Open Settings") { model.openFullDiskAccessSettings() }
                            .controlSize(.small)
                    }
                    .font(.callout)
                }
                Breadcrumbs()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                Sunburst(focused: focused, isRoot: focused.id == root.id, hoveredNode: $hoveredNode)
                    .padding(20)
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: 520, maxHeight: .infinity, alignment: .top)
                Divider()
                ChildList(focused: focused, hoveredNode: $hoveredNode)
                    .frame(minWidth: 360)
            }

            if !diskMap.collected.isEmpty || diskMap.lastResult != nil {
                Divider()
                CollectTray(isConfirming: $isConfirming)
            }
        }
        .confirmationDialog("Remove \(diskMap.collected.count) items?", isPresented: $isConfirming) {
            Button("Move to Trash") { diskMap.clean(mode: .moveToTrash) }
            Button("Delete Permanently", role: .destructive) { diskMap.clean(mode: .deletePermanently) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(diskMap.collectedBytes.fileSize) in \(diskMap.collected.count) items you picked. These are your own files and folders, not caches: check that nothing important is among them. Moving to Trash lets you restore them.")
        }
    }
}

/// Home, everything else on the disk (system, apps, other users), and free space.
private struct DiskOverview: View {
    @Environment(AppModel.self) private var model
    let home: DiskNode

    var body: some View {
        if let disk = model.diskSpace {
            StorageBar(
                segments: [
                    .init(id: "home", title: "Home folder", bytes: home.bytes, color: .blue),
                    .init(id: "other", title: "System, apps & other", bytes: max(0, disk.usedBytes - home.bytes), color: .gray),
                    .init(id: "free", title: "Free", bytes: disk.availableBytes, color: .green.opacity(0.35)),
                ],
                totalBytes: disk.totalBytes,
                height: 10
            )
        }
    }
}

private struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let diskMap = model.diskMap
        let crumbs = diskMap.breadcrumbs
        HStack(spacing: 4) {
            Button { diskMap.goUp() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(crumbs.count <= 1)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .help("Enclosing folder (⌘↑)")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button(index == 0 ? "Home" : node.name) { diskMap.focus(node) }
                            .buttonStyle(.borderless)
                            .fontWeight(index == crumbs.count - 1 ? .semibold : .regular)
                            .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            if let current = crumbs.last {
                Text(current.bytes.fileSize)
                    .font(.headline)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Sunburst

private struct SunburstSegment: Identifiable {
    let node: DiskNode
    let ring: Int
    let start: Double
    let end: Double
    let color: Color

    var id: String { node.id }
}

/// Three rings: the focused folder's children, then grandchildren and great-grandchildren in their parent's arc.
private struct Sunburst: View {
    @Environment(AppModel.self) private var model
    let focused: DiskNode
    let isRoot: Bool
    @Binding var hoveredNode: DiskNode?

    private static let ringCount = 3
    /// Arcs thinner than this are left out; they would be unreadable and only add views.
    private static let minimumSpan = 0.004

    var body: some View {
        let segments = Self.segments(for: focused)
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            let hole = radius * 0.34
            let ringWidth = (radius - hole) / Double(Self.ringCount)

            ZStack {
                ForEach(segments) { segment in
                    let shape = SectorShape(
                        start: segment.start, end: segment.end,
                        innerRadius: hole + ringWidth * Double(segment.ring), outerRadius: hole + ringWidth * Double(segment.ring + 1) - 1
                    )
                    shape
                        .fill(segment.color.opacity(hoveredNode?.id == segment.id ? 1 : (hoveredNode == nil ? 0.9 : 0.55)))
                        .contentShape(shape)
                        .onHover { inside in
                            if inside { hoveredNode = segment.node } else if hoveredNode?.id == segment.id { hoveredNode = nil }
                        }
                        .onTapGesture { model.diskMap.focus(segment.node) }
                        .help("\(segment.node.name) — \(segment.node.bytes.fileSize)")
                }

                Circle()
                    .fill(.background.opacity(0.001))
                    .frame(width: hole * 2, height: hole * 2)
                    .onTapGesture { model.diskMap.goUp() }
                    .overlay { center }
                    .help("Enclosing folder")
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.smooth(duration: 0.25), value: focused.id)
    }

    private var center: some View {
        let node = hoveredNode ?? focused
        return VStack(spacing: 2) {
            Text(node.bytes.fileSize)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(node.id == focused.id && isRoot ? "Home" : node.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if node.id != focused.id, focused.bytes > 0 {
                Text((Double(node.bytes) / Double(focused.bytes)).formatted(.percent.precision(.fractionLength(0...1))))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 120)
        .allowsHitTesting(false)
    }

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .indigo, .mint, .cyan]

    static func segments(for focused: DiskNode) -> [SunburstSegment] {
        guard focused.bytes > 0 else { return [] }
        var result: [SunburstSegment] = []

        func add(_ node: DiskNode, ring: Int, start: Double, span: Double, color: Color) {
            var offset = start
            for child in node.children {
                let childSpan = span * Double(child.bytes) / Double(max(node.bytes, 1))
                defer { offset += childSpan }
                guard childSpan >= minimumSpan else { continue }
                let childColor: Color = switch child.kind {
                case .smallerItems: .gray.opacity(0.45)
                case .file: color.opacity(0.6)
                default: color
                }
                result.append(SunburstSegment(node: child, ring: ring, start: offset, end: offset + childSpan, color: childColor))
                if child.isDirectory, ring + 1 < ringCount {
                    add(child, ring: ring + 1, start: offset, span: childSpan, color: color.opacity(0.75))
                }
            }
        }

        var offset = 0.0
        var colorIndex = 0
        for child in focused.children {
            let span = Double(child.bytes) / Double(focused.bytes)
            defer { offset += span }
            guard span >= minimumSpan else { continue }
            let color: Color
            if case .smallerItems = child.kind {
                color = .gray.opacity(0.45)
            } else {
                color = palette[colorIndex % palette.count]
                colorIndex += 1
            }
            result.append(SunburstSegment(node: child, ring: 0, start: offset, end: offset + span, color: child.kind == .file ? color.opacity(0.6) : color))
            if child.isDirectory {
                add(child, ring: 1, start: offset, span: span, color: color.opacity(0.75))
            }
        }
        return result
    }
}

/// An annular sector; `start` and `end` are fractions of a full turn, clockwise from 12 o'clock.
private struct SectorShape: Shape {
    var start: Double
    var end: Double
    var innerRadius: Double
    var outerRadius: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(start, end), AnimatablePair(innerRadius, outerRadius)) }
        set {
            (start, end) = (newValue.first.first, newValue.first.second)
            (innerRadius, outerRadius) = (newValue.second.first, newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // A hairline gap between neighbours, without eating thin arcs entirely.
        let gap = min(0.0015, (end - start) / 4)
        let startAngle = Angle.degrees((start + gap) * 360 - 90)
        let endAngle = Angle.degrees((end - gap) * 360 - 90)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - List

private struct ChildList: View {
    @Environment(AppModel.self) private var model
    let focused: DiskNode
    @Binding var hoveredNode: DiskNode?

    private var diskMap: DiskMapModel { model.diskMap }

    var body: some View {
        let reclaimable = smartScanBytes(in: focused.children)

        List {
            ForEach(focused.children) { node in
                ChildRow(
                    node: node,
                    parentBytes: focused.bytes,
                    smartScanBytes: reclaimable[node.id] ?? 0,
                    isHighlighted: hoveredNode?.id == node.id
                )
                .onHover { inside in
                    if inside { hoveredNode = node } else if hoveredNode?.id == node.id { hoveredNode = nil }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if focused.children.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            }
        }
    }

    /// What the latest Smart Scan found inside each child, to point at space that is cheaper to reclaim there.
    private func smartScanBytes(in nodes: [DiskNode]) -> [DiskNode.ID: Int64] {
        guard let items = model.report?.items else { return [:] }
        var result: [DiskNode.ID: Int64] = [:]
        for node in nodes where node.isRemovable {
            let path = node.url.path
            let bytes = items.reduce(Int64(0)) { total, item in
                guard let itemPath = item.url?.path, itemPath == path || itemPath.hasPrefix(path + "/") else { return total }
                return total + item.sizeInBytes
            }
            if bytes > 0 { result[node.id] = bytes }
        }
        return result
    }
}

private struct ChildRow: View {
    @Environment(AppModel.self) private var model
    let node: DiskNode
    let parentBytes: Int64
    let smartScanBytes: Int64
    let isHighlighted: Bool

    private var diskMap: DiskMapModel { model.diskMap }

    var body: some View {
        let isCollected = diskMap.isCollected(node)
        let isIncluded = diskMap.isIncludedByAncestor(node)

        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if smartScanBytes > 0 {
                        Text("Smart Scan \(smartScanBytes.fileSize)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .foregroundStyle(.green)
                            .background(.green.opacity(0.14), in: Capsule())
                            .help("Smart Scan can safely reclaim this much here. Prefer cleaning it there.")
                    }
                }
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(2, proxy.size.width * fraction))
                }
                .frame(height: 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Text(node.bytes.fileSize)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)

            if diskMap.canCollect(node) || isCollected {
                Button {
                    diskMap.toggleCollected(node)
                } label: {
                    Image(systemName: isCollected || isIncluded ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(isCollected || isIncluded ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(isIncluded)
                .help(isIncluded ? "Included with its enclosing folder" : isCollected ? "Remove from collection" : "Collect for removal")
            } else {
                Image(systemName: "lock")
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .help(node.isRemovable ? "Protected location" : "Small items are listed together and can't be collected")
            }

            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .opacity(node.isDirectory ? 1 : 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .listRowBackground(isHighlighted ? Color.accentColor.opacity(0.1) : Color.clear)
        .onTapGesture { diskMap.focus(node) }
        .contextMenu {
            if node.isRemovable {
                Button("Reveal in Finder") { diskMap.reveal(node) }
                Button("Open") { diskMap.open(node) }
                if diskMap.canCollect(node) {
                    Divider()
                    Button(isCollected ? "Remove from Collection" : "Collect for Removal") { diskMap.toggleCollected(node) }
                        .disabled(isIncluded)
                }
            }
        }
    }

    private var fraction: Double {
        parentBytes > 0 ? min(1, Double(node.bytes) / Double(parentBytes)) : 0
    }

    @ViewBuilder
    private var icon: some View {
        switch node.kind {
        case .smallerItems:
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        default:
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable()
                .frame(width: 24, height: 24)
        }
    }
}

// MARK: - Collect tray

private struct CollectTray: View {
    @Environment(AppModel.self) private var model
    @Binding var isConfirming: Bool

    var body: some View {
        let diskMap = model.diskMap
        HStack(spacing: 12) {
            if let result = diskMap.lastResult, diskMap.collected.isEmpty {
                Label(
                    "Removed \(result.removedCount) items, \(result.reclaimedBytes.fileSize)" + (result.failures.isEmpty ? "" : " · \(result.failures.count) failed"),
                    systemImage: result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(result.failures.isEmpty ? Color.green : .orange)
                .help(result.failures.joined(separator: "\n"))
                Spacer()
            } else {
                Image(systemName: "tray.full")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(diskMap.collectedBytes.fileSize).font(.headline).monospacedDigit()
                    Text(diskMap.collected.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button("Clear") { diskMap.clearCollected() }
                    .disabled(diskMap.isRemoving)
                if diskMap.isRemoving {
                    ProgressView().controlSize(.small)
                }
                Button("Remove \(diskMap.collected.count) Items…") { isConfirming = true }
                    .prominentActionStyle()
                    .disabled(diskMap.isRemoving)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
