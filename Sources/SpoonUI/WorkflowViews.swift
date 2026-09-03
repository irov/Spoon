import AppKit
import SpoonDomain
import SpoonSVN
import SwiftUI

struct BranchAndMergeView: View {
    @Bindable var model: AppModel
    @State private var sourceURL = ""
    @State private var destinationURL = ""
    @State private var revisionRange = ""
    @State private var message = ""
    @State private var reverse = false

    var body: some View {
        Form {
            Section("Create Branch or Tag") {
                TextField("Source URL", text: $sourceURL)
                TextField("Destination URL", text: $destinationURL)
                TextField("Commit message", text: $message, axis: .vertical).lineLimit(2...5)
                LabeledContent("Preview") {
                    VStack(alignment: .trailing) {
                        Text(sourceURL.isEmpty ? "—" : sourceURL)
                        Image(systemName: "arrow.down")
                        Text(destinationURL.isEmpty ? "—" : destinationURL)
                    }
                    .textSelection(.enabled)
                }
                Button("Create Repository Copy") {
                    guard let source = URL(string: sourceURL), let destination = URL(string: destinationURL) else { return }
                    Task { await model.createBranch(source: source, destination: destination, message: message) }
                }
                .disabled(sourceURL.isEmpty || destinationURL.isEmpty || message.isEmpty || model.isBusy)
            }

            Section("Switch Working Copy") {
                TextField("Destination URL", text: $destinationURL)
                Text("Local changes remain in the working copy and may conflict with the destination.")
                    .foregroundStyle(.orange)
                Button("Switch…") {
                    guard let url = URL(string: destinationURL) else { return }
                    Task { await model.switchWorkingCopy(to: url) }
                }
                .disabled(destinationURL.isEmpty || model.isBusy)
            }

            Section("Merge") {
                TextField("Source URL", text: $sourceURL)
                TextField("Revision range (for example 120:135)", text: $revisionRange)
                Toggle("Reverse merge", isOn: $reverse)
                HStack {
                    Button("Dry Run") {
                        guard let url = URL(string: sourceURL) else { return }
                        Task { await model.merge(from: url, range: revisionRange.isEmpty ? nil : revisionRange, dryRun: true, reverse: reverse) }
                    }
                    Button("Merge") {
                        guard let url = URL(string: sourceURL) else { return }
                        Task { await model.merge(from: url, range: revisionRange.isEmpty ? nil : revisionRange, dryRun: false, reverse: reverse) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Merge produces reviewable local changes. Spoon never commits them automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Branches and Tags")
        .onAppear {
            sourceURL = model.selectedProject?.repositoryRootURL?.absoluteString ?? ""
        }
    }
}

struct ChangelistsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let groups = Dictionary(grouping: model.statusItems.filter { $0.changelist != nil }, by: { $0.changelist ?? "" })
        if groups.isEmpty {
            ContentUnavailableView("No Changelists", systemImage: "list.bullet.rectangle", description: Text("Assign changed paths to SVN changelists from Local Changes."))
                .navigationTitle("Changelists")
        } else {
            List {
                ForEach(groups.keys.sorted(), id: \.self) { name in
                    Section(name) {
                        ForEach(groups[name] ?? []) { item in
                            Label(item.relativePath, systemImage: "doc")
                        }
                    }
                }
            }
            .navigationTitle("Changelists")
        }
    }
}

struct ConflictsView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.conflicts.isEmpty {
            ContentUnavailableView("No Conflicts", systemImage: "checkmark.shield", description: Text("The working copy has no unresolved text, property, or tree conflicts."))
                .navigationTitle("Conflicts")
        } else {
            List(model.conflicts) { item in
                HStack {
                    Image(systemName: item.treeConflicted ? "folder.badge.questionmark" : "doc.badge.ellipsis")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text(item.relativePath)
                        Text(conflictKinds(item).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Resolve") {
                        ForEach(ConflictResolution.allCases, id: \.self) { choice in
                            Button(choice.rawValue) { Task { await model.resolve(paths: [item.relativePath], choice: choice) } }
                        }
                    }
                }
            }
            .navigationTitle("Conflicts")
        }
    }

    private func conflictKinds(_ item: StatusItem) -> [String] {
        var kinds: [String] = []
        if item.workingCopyStatus == .conflicted { kinds.append(String(localized: "Text conflict")) }
        if item.propertyStatus == .conflicted { kinds.append(String(localized: "Property conflict")) }
        if item.treeConflicted { kinds.append(String(localized: "Tree conflict")) }
        return kinds
    }
}

struct TaskCenterView: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.tasks.isEmpty {
            ContentUnavailableView("No Tasks", systemImage: "progress.indicator", description: Text("SVN operations will appear here with sanitized diagnostics."))
                .navigationTitle("Tasks")
        } else {
            List(model.tasks) { task in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        stateIcon(task.state)
                        Text(task.operation.rawValue).font(.headline)
                        Text(task.state.rawValue.capitalized).foregroundStyle(.secondary)
                        Spacer()
                        Text(task.createdAt, style: .time).foregroundStyle(.secondary)
                        if task.state == .running {
                            Button("Cancel") { Task { await model.cancel(taskID: task.id) } }
                        }
                    }
                    if let summary = task.summary { Text(summary).lineLimit(2) }
                    Text(task.sanitizedCommand)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if !task.svnErrorCodes.isEmpty {
                        Text(task.svnErrorCodes.map(\.value).joined(separator: ", "))
                            .font(.caption.monospaced()).foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Tasks")
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: SVNTaskState) -> some View {
        switch state {
        case .queued: Image(systemName: "clock")
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

struct CheckoutSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var destinationParent: URL?
    @State private var destinationFolderName = ""
    @State private var revision = "HEAD"
    @State private var depth = "infinity"
    @State private var ignoreExternals = false

    private var repositoryURL: URL? {
        URL(string: repository.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var destination: URL? {
        guard let destinationParent,
              CheckoutDestination.isValidFolderName(destinationFolderName) else { return nil }
        return destinationParent.appendingPathComponent(destinationFolderName, isDirectory: true)
    }

    var body: some View {
        Form {
            TextField("Repository URL", text: $repository)
            TextField("Working copy folder", text: $destinationFolderName)
            HStack {
                LabeledContent("Destination", value: destination?.path ?? "Not selected")
                Button("Choose Parent…", action: chooseDestinationParent)
            }
            TextField("Revision", text: $revision)
            Picker("Depth", selection: $depth) {
                Text("Empty").tag("empty")
                Text("Files").tag("files")
                Text("Immediate children").tag("immediates")
                Text("Infinity").tag("infinity")
            }
            Toggle("Ignore externals", isOn: $ignoreExternals)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Checkout") {
                    guard let repositoryURL, let destinationParent, let destination else { return }
                    Task {
                        if await model.checkout(
                            repositoryURL: repositoryURL,
                            destination: destination,
                            securityScopeRoot: destinationParent,
                            revision: revision,
                            depth: depth,
                            ignoreExternals: ignoreExternals
                        ) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(repositoryURL == nil || destination == nil || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onChange(of: repository) { oldValue, newValue in
            let previousSuggestion = URL(string: oldValue.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap(CheckoutDestination.suggestedFolderName)
            guard destinationFolderName.isEmpty || destinationFolderName == previousSuggestion else { return }
            destinationFolderName = URL(string: newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap(CheckoutDestination.suggestedFolderName) ?? ""
        }
    }

    private func chooseDestinationParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationParent
        panel.message = String(localized: "Choose where Spoon should create the working-copy folder.")
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK { destinationParent = panel.url }
    }

}

struct CommandPaletteView: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var query = ""

    private var commands: [(String, String, () -> Void)] {
        [
            (String(localized: "Refresh Local Status"), "arrow.clockwise", { Task { await model.refreshStatus() } }),
            (String(localized: "Check Remote Status"), "network", { Task { await model.refreshStatus(remote: true) } }),
            (String(localized: "Update Working Copy"), "arrow.down.circle", { Task { await model.updateWorkingCopy() } }),
            (String(localized: "Commit Staged Changes"), "arrow.up.circle", { Task { await model.commitSelected() } }),
            (String(localized: "Reveal in Finder"), "folder", { model.revealSelectedProject() })
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
            Divider()
            List(commands.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }, id: \.0) { command in
                Button {
                    isPresented = false
                    command.2()
                } label: {
                    Label(command.0, systemImage: command.1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 560, height: 380)
    }
}
