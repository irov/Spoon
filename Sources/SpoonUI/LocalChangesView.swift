import SpoonDomain
import SwiftUI

struct LocalChangesView: View {
    @Bindable var model: AppModel
    @State private var pendingRevert: [String] = []
    @State private var recursiveRevert = false
    @State private var propertyTarget: StatusItem?
    @State private var lockTarget: StatusItem?
    @State private var changelistTarget: StatusItem?
    @State private var deleteTarget: StatusItem?
    @State private var moveTarget: StatusItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter paths", text: $model.filterText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("changes-filter")
                Toggle("Ignored", isOn: $model.showIgnored)
                    .toggleStyle(.checkbox)
                Text("\(model.filteredStatusItems.count) changes")
                    .foregroundStyle(.secondary)
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
                List(model.filteredStatusItems) { item in
                    changeRow(item)
                }
                .listStyle(.inset)
            }

            Divider()
            commitComposer
        }
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

    private func changeRow(_ item: StatusItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { model.selectedPaths.contains(item.relativePath) },
                set: { selected in
                    if selected { model.selectedPaths.insert(item.relativePath) }
                    else { model.selectedPaths.remove(item.relativePath) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(item.workingCopyStatus == .conflicted || item.treeConflicted)

            StatusBadge(status: item.workingCopyStatus)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.relativePath).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if item.propertyStatus != .none && item.propertyStatus != .normal {
                        Label("Properties", systemImage: "tag").font(.caption).foregroundStyle(.secondary)
                    }
                    if item.switched { Text("Switched").font(.caption).foregroundStyle(.orange) }
                    if item.copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                    if let changelist = item.changelist { Text(changelist).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            if item.locked { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
            if item.remoteStatus != .none && item.remoteStatus != .normal {
                Image(systemName: "arrow.down.circle").foregroundStyle(.blue).help("Remote change")
            }
        }
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
            .font(.caption2.monospaced().bold())
            .frame(width: 22, height: 22)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
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
