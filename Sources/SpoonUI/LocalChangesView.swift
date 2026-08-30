import SpoonDomain
import SwiftUI

struct LocalChangesView: View {
    @Bindable var model: AppModel
    @AppStorage("localChangesPresentation") private var presentationRawValue = LocalChangesPresentation.tree.rawValue
    @State private var pendingRevert: [String] = []
    @State private var recursiveRevert = false
    @State private var lockTarget: StatusItem?
    @State private var changelistTarget: StatusItem?
    @State private var deleteTarget: StatusItem?
    @State private var moveTarget: StatusItem?
    @State private var ignoreTarget: SVNIgnoreTarget?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Filter paths", text: $model.filterText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("changes-filter")
                    Toggle("Ignored", isOn: $model.showIgnored)
                        .toggleStyle(.checkbox)
                    if localChangeCount > 0 || incompleteItems.isEmpty && incomingItems.isEmpty {
                        Text("\(localChangeCount) changes")
                            .foregroundStyle(.secondary)
                    }
                    if !incomingItems.isEmpty {
                        Label {
                            Text(incomingItems.count, format: .number)
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                            .foregroundStyle(.blue)
                            .help("Incoming Changes")
                    }
                    if !incompleteItems.isEmpty {
                        Label("\(incompleteItems.count) issues", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
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
                revisionImagePreviews: [],
                beforeImageTitle: "Before",
                afterImageTitle: "Working Copy",
                pathBase: model.selectedProject?.workingCopyRoot.path,
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
        .sheet(item: $lockTarget) { LockSheet(model: model, item: $0) }
        .sheet(item: $changelistTarget) { ChangelistSheet(model: model, item: $0) }
        .sheet(item: $moveTarget) { MoveWorkingCopyItemSheet(model: model, item: $0) }
        .sheet(item: $ignoreTarget) { IgnoreSheet(model: model, target: $0) }
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

    private var incompleteItems: [StatusItem] {
        model.filteredStatusItems.filter { $0.workingCopyStatus == .incomplete }
    }

    private var incomingItems: [StatusItem] {
        model.filteredStatusItems.filter(\.hasRemoteChange)
    }

    private var localChangeItems: [StatusItem] {
        model.filteredStatusItems.filter {
            $0.workingCopyStatus != .incomplete && $0.hasLocalChange
        }
    }

    private var localChangeCount: Int {
        localChangeItems.count
    }

    private var unstagedItems: [StatusItem] {
        localChangeItems.filter {
            !model.selectedPaths.contains($0.relativePath)
        }
    }

    private var stagedItems: [StatusItem] {
        model.filteredStatusItems.filter { model.selectedPaths.contains($0.relativePath) }
    }

    @ViewBuilder
    private var changesList: some View {
        VSplitView {
            if !incomingItems.isEmpty {
                incomingChangesSection
                    .frame(minHeight: 130)
            }

            if !incompleteItems.isEmpty {
                workingCopyIssuesSection
                    .frame(minHeight: 140)
            }

            changesSection(
                title: "Unstaged",
                emptyMessage: incompleteItems.isEmpty ? "All eligible paths are staged." : "No unstaged changes.",
                items: unstagedItems,
                isStaged: false
            )
            .frame(minHeight: 110)

            changesSection(
                title: "Staged",
                emptyMessage: "Stage whole paths to include them in the commit.",
                items: stagedItems,
                isStaged: true
            )
            .frame(minHeight: 110)
        }
    }

    private var incomingChangesSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Incoming Changes", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
                Text(incomingItems.count, format: .number)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastRemoteStatusCheck = model.lastRemoteStatusCheck {
                    Text(lastRemoteStatusCheck, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Last remote check")
                }
                Button("Update") {
                    Task { await model.updateWorkingCopy() }
                }
                .disabled(model.isBusy)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.bar)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("These paths were committed to the repository and are not in this working copy yet.")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            List(incomingItems) { item in
                incomingRow(item)
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func incomingRow(_ item: StatusItem) -> some View {
        HStack(spacing: 6) {
            RemoteStatusBadge(status: item.remoteStatus)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle(item.relativePath))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(remoteStatusTitle(item.remoteStatus))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.hasLocalChange {
                Label("Also changed locally", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .contentShape(Rectangle())
    }

    private func remoteStatusTitle(_ status: RemoteStatus) -> LocalizedStringKey {
        switch status {
        case .modified: "Modified on server"
        case .added: "Added on server"
        case .deleted: "Deleted on server"
        case .replaced: "Replaced on server"
        case .unknown: "Changed on server"
        case .none, .normal: "Incoming change"
        }
    }

    private var workingCopyIssuesSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Working Copy Issues", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(incompleteItems.count, format: .number)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Complete Update") {
                    Task { await model.updateWorkingCopy() }
                }
                .disabled(model.isBusy)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.bar)

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("SVN did not finish updating these paths. Complete the update before committing.")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            issueRows
        }
    }

    @ViewBuilder
    private var issueRows: some View {
        if presentation == .tree {
            List {
                ForEach(ChangeTreeNode.build(from: incompleteItems)) { node in
                    ExpandedChangeTreeBranch(node: node) { node in
                        AnyView(issueRow(node))
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
        } else {
            List(incompleteItems) { item in
                issueRow(ChangeTreeNode(item: item))
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func issueRow(_ node: ChangeTreeNode) -> some View {
        HStack(spacing: 6) {
            if let item = node.item {
                StatusBadge(status: item.workingCopyStatus)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                    .frame(width: 18, height: 18)
            }

            Text(displayTitle(node.name))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            if node.item != nil {
                Text("Incomplete")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Spacer()
        }
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let item = node.item else { return }
            Task { await model.loadDiff(path: item.relativePath) }
        }
    }

    private func changesSection(
        title: LocalizedStringKey,
        emptyMessage: LocalizedStringKey,
        items: [StatusItem],
        isStaged: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(items.count, format: .number)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if isStaged {
                    Button("Unstage All") { setStaged(items, staged: false) }
                        .disabled(items.isEmpty)
                } else {
                    Button("Stage All") { setStaged(items, staged: true) }
                        .disabled(model.isBusy || !items.contains(where: \.isStageable))
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.bar)

            Divider()

            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: isStaged ? "tray" : "checkmark.circle")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                changeRows(items: items, isStaged: isStaged)
            }
        }
    }

    @ViewBuilder
    private func changeRows(items: [StatusItem], isStaged: Bool) -> some View {
        if presentation == .tree {
            List {
                ForEach(ChangeTreeNode.build(from: items)) { node in
                    ExpandedChangeTreeBranch(node: node) { node in
                        if let item = node.item {
                            return AnyView(changeItemRows(item, title: node.name, showSeparator: false, isStaged: isStaged))
                        } else {
                            return AnyView(folderRow(node, isStaged: isStaged))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
        } else {
            List(items) { item in
                changeItemRows(item, title: item.relativePath, showSeparator: true, isStaged: isStaged)
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 22)
        }
    }

    private func changeItemRows(_ item: StatusItem, title: String, showSeparator: Bool, isStaged: Bool) -> some View {
        changeRow(item, title: title, showSeparator: showSeparator, isStaged: isStaged)
    }

    private func changeRow(_ item: StatusItem, title: String, showSeparator: Bool, isStaged: Bool) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { model.selectedPaths.contains(item.relativePath) },
                set: { setStaged([item], staged: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(model.isBusy || (!isStaged && !item.isStageable))
            .help(stageHelp(for: item, isStaged: isStaged))
            .accessibilityLabel(isStaged ? "Unstage Path" : "Stage Path")

            if item.hasWorkingCopyChange {
                StatusBadge(status: item.workingCopyStatus)
            } else if item.hasPropertyChange {
                PropertyStatusBadge(status: item.propertyStatus)
            } else {
                Color.clear.frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayTitle(title))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.hasPropertyChange {
                        propertyIndicator(item)
                    }
                }
                HStack(spacing: 6) {
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
        .onTapGesture {
            Task {
                if item.isPropertyOnlyChange {
                    await model.loadPropertyDiff(path: item.relativePath)
                } else {
                    await model.loadDiff(path: item.relativePath)
                }
            }
        }
        .contextMenu {
            if isStaged || item.isStageable {
                Button(isStaged ? "Unstage" : "Stage") {
                    setStaged([item], staged: !isStaged)
                }
                .disabled(model.isBusy)
                Divider()
            }
            Button("Open") { Task { await model.open(path: item.relativePath) } }
            Menu("Open Diff With") {
                ForEach(ExternalToolPreset.allCases) { preset in
                    Button(preset.rawValue) { Task { await model.open(path: item.relativePath, with: preset, compareWithBase: true) } }
                        .disabled(ExternalToolLauncher.application(for: preset) == nil || item.nodeKind == .directory || item.workingCopyStatus == .added)
                }
            }
            if item.workingCopyStatus == .unversioned {
                Button("Add") { Task { await model.add(paths: [item.relativePath]) } }
            }
            if item.canAddToIgnore {
                Button("Add to Ignore") { ignoreTarget = model.ignoreTarget(for: item.relativePath) }
            }
            if item.workingCopyStatus != .unversioned {
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

    private func propertyIndicator(_ item: StatusItem) -> some View {
        Button {
            Task { await model.loadPropertyDiff(path: item.relativePath) }
        } label: {
            Label("Properties", systemImage: "tag.fill")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Select to show the SVN property diff. Properties are staged with their path.")
        .accessibilityLabel("Properties — \(item.relativePath)")
    }

    private func folderRow(_ node: ChangeTreeNode, isStaged: Bool) -> some View {
        let items = node.selectableItems
        return HStack(spacing: 6) {
            Button {
                setStaged(items, staged: !isStaged)
            } label: {
                Image(systemName: isStaged ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isStaged ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || items.isEmpty)
            .help(isStaged ? "Unstage Folder Paths" : "Stage Folder Paths")
            .accessibilityLabel(isStaged ? "Unstage paths in \(node.name)" : "Stage paths in \(node.name)")

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

    private func setStaged(_ items: [StatusItem], staged: Bool) {
        if staged {
            let paths = items.filter(\.isStageable).map(\.relativePath)
            Task { await model.stage(paths: paths) }
        } else {
            model.unstage(paths: items.map(\.relativePath))
        }
    }

    private func displayTitle(_ title: String) -> String {
        title == "." ? String(localized: "Working Copy Root") : title
    }

    private func stageHelp(for item: StatusItem, isStaged: Bool) -> LocalizedStringKey {
        if isStaged { return "Unstage Path" }
        if item.workingCopyStatus == .unversioned { return "Add to SVN and Stage" }
        if item.isStageable { return "Stage Path" }
        return "Add or schedule this path in SVN before committing"
    }

    private var commitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Commit Message").font(.headline)
                Spacer()
                Text("\(model.selectedPaths.count) staged").foregroundStyle(.secondary)
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
                Button("Commit Staged") { Task { await model.commitSelected() } }
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

private struct IgnoreSheet: View {
    @Bindable var model: AppModel
    let target: SVNIgnoreTarget
    @Environment(\.dismiss) private var dismiss
    @State private var ignoreExtension = false

    private var selectedPattern: String {
        if ignoreExtension, let extensionPattern = target.extensionPattern {
            return extensionPattern
        }
        return target.exactPattern
    }

    private var parentDisplayPath: String {
        let components = target.anchorPath.split(separator: "/")
        guard components.count > 1 else { return String(localized: "Working Copy Root") }
        return components.dropLast().joined(separator: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ignore this path?").font(.title3.bold())

            Label(target.anchorPath, systemImage: target.nodeKind == .directory ? "folder.fill" : "doc.fill")
                .lineLimit(2)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 8) {
                Text("What will happen")
                    .font(.callout.weight(.semibold))
                Label("Keep files on disk", systemImage: "internaldrive")
                if target.wasScheduledForAddition {
                    Label("Remove this path from SVN", systemImage: "minus.circle")
                }
                Label("Ignore it from now on", systemImage: "eye.slash")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if let extensionPattern = target.extensionPattern {
                Toggle(
                    String(format: String(localized: "Ignore all files with this extension (%@)"), extensionPattern),
                    isOn: $ignoreExtension
                )
                .toggleStyle(.checkbox)
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Ignore rule").foregroundStyle(.secondary)
                        Text(selectedPattern).font(.body.monospaced()).textSelection(.enabled)
                    }
                    GridRow {
                        Text("In folder").foregroundStyle(.secondary)
                        Text(parentDisplayPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Ignore") {
                    Task {
                        await model.addToIgnore(target: target, pattern: selectedPattern)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 520)
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
        case .none, .normal: ""
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
        case .incomplete: "!"
        case .merged: "G"
        case .unknown: "?"
        }
    }

    private var color: Color {
        switch status {
        case .added: .green
        case .deleted, .missing: .red
        case .conflicted, .obstructed, .incomplete, .unknown: .orange
        case .unversioned, .ignored: .secondary
        default: .blue
        }
    }

    private var accessibilityText: String {
        status == .incomplete ? String(localized: "Incomplete working copy") : status.rawValue.capitalized
    }
}

private struct PropertyStatusBadge: View {
    let status: WorkingCopyStatus

    var body: some View {
        Text("P")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .frame(width: 18, height: 18)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
            .accessibilityLabel("Property \(status.rawValue)")
    }

    private var color: Color {
        switch status {
        case .added: .green
        case .deleted, .missing: .red
        case .conflicted, .obstructed: .orange
        default: .purple
        }
    }
}

private struct RemoteStatusBadge: View {
    let status: RemoteStatus

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .frame(width: 18, height: 18)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
            .accessibilityLabel("Remote \(status.rawValue)")
    }

    private var label: String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .replaced: "R"
        case .unknown: "?"
        case .none, .normal: "↓"
        }
    }

    private var color: Color {
        switch status {
        case .added: .green
        case .deleted: .red
        case .unknown: .orange
        default: .blue
        }
    }
}

private enum LocalChangesPresentation: String {
    case tree
    case list
}

private extension StatusItem {
    var hasWorkingCopyChange: Bool {
        workingCopyStatus != .none && workingCopyStatus != .normal
    }

    var hasPropertyChange: Bool {
        propertyStatus != .none && propertyStatus != .normal
    }

    var hasLocalChange: Bool {
        hasWorkingCopyChange || hasPropertyChange
    }

    var hasRemoteChange: Bool {
        remoteStatus != .none && remoteStatus != .normal
    }

    var isPropertyOnlyChange: Bool {
        hasPropertyChange
            && !hasWorkingCopyChange
            && (remoteStatus == .none || remoteStatus == .normal)
            && !locked
    }
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

    init(item: StatusItem) {
        name = item.relativePath
        relativePath = item.relativePath
        self.item = item
        children = nil
    }

    private init(name: String, relativePath: String, item: StatusItem?, children: [ChangeTreeNode]?) {
        self.name = name
        self.relativePath = relativePath
        self.item = item
        self.children = children
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
        item.isStageable
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
