import SpoonDomain
import SwiftUI

struct LocalChangesView: View {
    @Bindable var model: AppModel
    @AppStorage("localChangesPresentation") private var presentationRawValue = LocalChangesPresentation.tree.rawValue
    @State private var pendingRevert: [String] = []
    @State private var recursiveRevert = false
    @State private var propertyTarget: StatusItem?
    @State private var lockTarget: StatusItem?
    @State private var changelistTarget: StatusItem?
    @State private var deleteTarget: StatusItem?
    @State private var moveTarget: StatusItem?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Filter paths", text: $model.filterText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("changes-filter")
                    Toggle("Ignored", isOn: $model.showIgnored)
                        .toggleStyle(.checkbox)
                    Text("\(model.filteredStatusItems.count) changes")
                        .foregroundStyle(.secondary)
                    Picker("Presentation", selection: $presentationRawValue) {
                        Label("Tree", systemImage: "list.bullet.indent")
                            .labelStyle(.iconOnly)
                            .tag(LocalChangesPresentation.tree.rawValue)
                        Label("List", systemImage: "list.bullet")
                            .labelStyle(.iconOnly)
                            .tag(LocalChangesPresentation.list.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 70)
                    .help(presentation == .tree ? "Tree View" : "List View")
                }
                .padding(10)

                if let info = model.workingCopyInfo {
                    HStack(spacing: 12) {
                        Text(info.url.absoluteString).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("r\(info.revision)").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
                }

                Divider()

                if model.filteredStatusItems.isEmpty {
                    ContentUnavailableView(
                        "Working Copy Clean",
                        systemImage: "checkmark.circle",
                        description: Text("No local changes match the current filter.")
                    )
                } else {
                    changesList
                }

                Divider()
                commitComposer
            }
            .frame(minWidth: 390, idealWidth: 500)
            .frame(maxHeight: .infinity, alignment: .top)

            DiffInspector(
                text: model.diffText,
                beforeImageData: model.diffBeforeImageData,
                afterImageData: model.diffAfterImageData,
                binaryDescription: model.diffBinaryDescription,
                contextMode: model.diffContextMode,
                isContextLoading: model.isDiffContextLoading,
                onContextModeChange: { mode in Task { await model.setDiffContextMode(mode) } }
            )
            .frame(minWidth: 460, idealWidth: 760)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.selectedProject?.displayName ?? "Local Changes")
        .confirmationDialog(
            "Revert selected paths?",
            isPresented: Binding(get: { !pendingRevert.isEmpty }, set: { if !$0 { pendingRevert = [] } }),
            titleVisibility: .visible
        ) {
            Button("Revert \(pendingRevert.count) Path(s)", role: .destructive) {
                let paths = pendingRevert
                pendingRevert = []
                Task { await model.revert(paths: paths, recursive: recursiveRevert) }
            }
            Button("Cancel", role: .cancel) { pendingRevert = [] }
        } message: {
            Text(pendingRevert.joined(separator: "\n"))
        }
        .onChange(of: model.commitMessage) { _, _ in Task { await model.saveDraft() } }
        .onChange(of: model.selectedPaths) { _, _ in Task { await model.saveDraft() } }
        .sheet(item: $propertyTarget) { PropertiesSheet(model: model, item: $0) }
        .sheet(item: $lockTarget) { LockSheet(model: model, item: $0) }
        .sheet(item: $changelistTarget) { ChangelistSheet(model: model, item: $0) }
        .sheet(item: $moveTarget) { MoveWorkingCopyItemSheet(model: model, item: $0) }
        .confirmationDialog(
            "Schedule path for deletion?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let item = deleteTarget else { return }
                deleteTarget = nil
                Task { await model.delete(paths: [item.relativePath]) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { Text(deleteTarget?.absolutePath.path ?? "") }
    }

    private var presentation: LocalChangesPresentation {
        LocalChangesPresentation(rawValue: presentationRawValue) ?? .tree
    }

    @ViewBuilder
    private var changesList: some View {
        if presentation == .tree {
            List {
                ForEach(ChangeTreeNode.build(from: model.filteredStatusItems)) { node in
                    ExpandedChangeTreeBranch(node: node) { node in
                        if let item = node.item {
                            return AnyView(changeRow(item, title: node.name, showSeparator: false))
                        } else {
                            return AnyView(folderRow(node))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
        } else {
            List(model.filteredStatusItems) { item in
                changeRow(item, title: item.relativePath, showSeparator: true)
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func changeRow(_ item: StatusItem, title: String, showSeparator: Bool) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { model.selectedPaths.contains(item.relativePath) },
                set: { selected in
                    if selected { model.selectedPaths.insert(item.relativePath) }
                    else { model.selectedPaths.remove(item.relativePath) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(item.workingCopyStatus == .conflicted || item.treeConflicted)

            StatusBadge(status: item.workingCopyStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if item.propertyStatus != .none && item.propertyStatus != .normal {
                        Label("Properties", systemImage: "tag").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    if item.switched { Text("Switched").font(.system(size: 9.5)).foregroundStyle(.orange) }
                    if item.copied { Text("Copied").font(.system(size: 9.5)).foregroundStyle(.secondary) }
                    if let changelist = item.changelist { Text(changelist).font(.system(size: 9.5)).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if item.locked { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary) }
            if item.remoteStatus != .none && item.remoteStatus != .normal {
                Image(systemName: "arrow.down.circle").font(.system(size: 10)).foregroundStyle(.blue).help("Remote change")
            }
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(showSeparator ? .visible : .hidden)
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.loadDiff(path: item.relativePath) } }
        .contextMenu {
            Button("Open") { Task { await model.open(path: item.relativePath) } }
            Menu("Open Diff With") {
                ForEach(ExternalToolPreset.allCases) { preset in
                    Button(preset.rawValue) { Task { await model.open(path: item.relativePath, with: preset, compareWithBase: true) } }
                        .disabled(ExternalToolLauncher.application(for: preset) == nil || item.nodeKind == .directory || item.workingCopyStatus == .added)
                }
            }
            Button("Properties…") { propertyTarget = item }
            if item.workingCopyStatus == .unversioned {
                Button("Add") { Task { await model.add(paths: [item.relativePath]) } }
            } else {
                Button("Move or Rename…") { moveTarget = item }
                Button("Delete…", role: .destructive) { deleteTarget = item }
            }
            if item.workingCopyStatus == .conflicted || item.treeConflicted || item.propertyStatus == .conflicted {
                Menu("Resolve") {
                    ForEach(ConflictResolution.allCases, id: \.self) { choice in
                        Button(choice.rawValue) { Task { await model.resolve(paths: [item.relativePath], choice: choice) } }
                    }
                }
            }
            if item.locked {
                Button("Unlock") { Task { await model.unlock(paths: [item.relativePath]) } }
            } else if item.nodeKind != .directory && item.workingCopyStatus != .unversioned {
                Button("Lock…") { lockTarget = item }
            }
            Button("Assign Changelist…") { changelistTarget = item }
            if item.changelist != nil {
                Button("Remove from Changelist") { Task { await model.setChangelist(nil, paths: [item.relativePath]) } }
            }
            Divider()
            Button("Revert…", role: .destructive) {
                recursiveRevert = item.nodeKind == .directory
                pendingRevert = [item.relativePath]
            }
        }
    }

    private func folderRow(_ node: ChangeTreeNode) -> some View {
        let items = node.selectableItems
        let selectedCount = items.lazy.filter { model.selectedPaths.contains($0.relativePath) }.count
        return HStack(spacing: 6) {
            Button {
                if selectedCount == items.count {
                    model.selectedPaths.subtract(items.map(\.relativePath))
                } else {
                    model.selectedPaths.formUnion(items.map(\.relativePath))
                }
            } label: {
                Image(systemName: selectionSymbol(selectedCount: selectedCount, totalCount: items.count))
                    .font(.system(size: 13))
                    .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(items.isEmpty)
            .accessibilityLabel("Select changes in \(node.name)")

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
            Text(node.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer()
            Text(items.count, format: .number)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
    }

    private func selectionSymbol(selectedCount: Int, totalCount: Int) -> String {
        if selectedCount == 0 { return "square" }
        if selectedCount == totalCount { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit Message").font(.headline)
                Spacer()
                Text("\(model.selectedPaths.count) selected").foregroundStyle(.secondary)
            }
            TextEditor(text: $model.commitMessage)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Commit Message")
            HStack {
                if !model.activityMessage.isEmpty {
                    Text(model.activityMessage).lineLimit(1).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Commit Selected") { Task { await model.commitSelected() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedPaths.isEmpty || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            }
        }
        .padding(12)
    }
}

private struct MoveWorkingCopyItemSheet: View {
    @Bindable var model: AppModel
    let item: StatusItem
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""

    var body: some View {
        Form {
            LabeledContent("Source", value: item.absolutePath.path)
            TextField("Destination path", text: $destination)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move") {
                    Task { await model.move(path: item.relativePath, to: URL(fileURLWithPath: destination)); dismiss() }
                }
                .buttonStyle(.borderedProminent).disabled(destination.isEmpty || destination == item.absolutePath.path)
            }
        }
        .padding(20).frame(width: 650)
        .onAppear { destination = item.absolutePath.path }
    }
}

private struct PropertiesSheet: View {
    @Bindable var model: AppModel
    let item: StatusItem
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Properties — \(item.relativePath)").font(.title3.bold())
            List(model.inspectedProperties) { property in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(property.name).font(.headline.monospaced())
                        Spacer()
                        Button("Delete", role: .destructive) { Task { await model.deleteProperty(path: item.relativePath, name: property.name) } }
                    }
                    Text(property.value).font(.body.monospaced()).textSelection(.enabled)
                }
            }
            Divider()
            TextField("Property name", text: $name)
            TextEditor(text: $value).font(.body.monospaced()).frame(height: 90)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Set Property") { Task { await model.setProperty(path: item.relativePath, name: name, value: value) } }
                    .buttonStyle(.borderedProminent).disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 500)
        .task { await model.loadProperties(path: item.relativePath) }
    }
}

private struct LockSheet: View {
    @Bindable var model: AppModel
    let item: StatusItem
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        Form {
            Text(item.relativePath).textSelection(.enabled)
            TextField("Lock message", text: $message, axis: .vertical).lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Lock") { Task { await model.lock(paths: [item.relativePath], message: message.isEmpty ? nil : message); dismiss() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 520)
    }
}

private struct ChangelistSheet: View {
    @Bindable var model: AppModel
    let item: StatusItem
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        Form {
            Text(item.relativePath).textSelection(.enabled)
            TextField("Changelist name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Assign") { Task { await model.setChangelist(name, paths: [item.relativePath]); dismiss() } }
                    .buttonStyle(.borderedProminent).disabled(name.isEmpty)
            }
        }
        .padding(20).frame(width: 500)
        .onAppear { name = item.changelist ?? "" }
    }
}

struct StatusBadge: View {
    let status: WorkingCopyStatus

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .frame(width: 18, height: 18)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityText)
    }

    private var label: String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .missing: "!"
        case .replaced: "R"
        case .conflicted: "C"
        case .obstructed: "~"
        case .unversioned: "?"
        case .ignored: "I"
        case .external: "X"
        default: "•"
        }
    }

    private var color: Color {
        switch status {
        case .added: .green
        case .deleted, .missing: .red
        case .conflicted, .obstructed: .orange
        case .unversioned, .ignored: .secondary
        default: .blue
        }
    }

    private var accessibilityText: String { status.rawValue.capitalized }
}

private enum LocalChangesPresentation: String {
    case tree
    case list
}

private struct ExpandedChangeTreeBranch: View {
    let node: ChangeTreeNode
    let row: (ChangeTreeNode) -> AnyView
    @State private var isExpanded = true

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    ExpandedChangeTreeBranch(node: child, row: row)
                }
            } label: {
                row(node)
            }
        } else {
            row(node)
        }
    }
}

private struct ChangeTreeNode: Identifiable {
    let name: String
    let relativePath: String
    let item: StatusItem?
    let children: [ChangeTreeNode]?

    var id: String { relativePath }

    var selectableItems: [StatusItem] {
        let own = item.map { Self.selectable($0) ? [$0] : [] } ?? []
        return own + (children ?? []).flatMap(\.selectableItems)
    }

    static func build(from items: [StatusItem]) -> [ChangeTreeNode] {
        build(entries: items.map(TreeEntry.init), depth: 0)
    }

    private static func build(entries: [TreeEntry], depth: Int) -> [ChangeTreeNode] {
        let groups = Dictionary(grouping: entries.filter { $0.components.count > depth }) {
            $0.components[depth]
        }

        return groups.map { name, entries in
            let exactItem = entries.first { $0.components.count == depth + 1 }?.item
            let descendants = entries.filter { $0.components.count > depth + 1 }
            let children = build(entries: descendants, depth: depth + 1)
            let relativePath = exactItem?.relativePath
                ?? entries.first.map { $0.components.prefix(depth + 1).joined(separator: "/") }
                ?? name
            return ChangeTreeNode(
                name: name,
                relativePath: relativePath,
                item: exactItem,
                children: children.isEmpty ? nil : children
            )
        }
        .sorted { lhs, rhs in
            if (lhs.children != nil) != (rhs.children != nil) { return lhs.children != nil }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func selectable(_ item: StatusItem) -> Bool {
        item.workingCopyStatus != .conflicted && !item.treeConflicted
    }

    private struct TreeEntry {
        let item: StatusItem
        let components: [String]

        init(_ item: StatusItem) {
            self.item = item
            components = item.relativePath.split(separator: "/").map(String.init)
        }
    }
}
