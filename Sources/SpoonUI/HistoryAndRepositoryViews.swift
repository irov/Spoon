import AppKit
import SpoonDomain
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var showBlame = false
    @State private var detailTab: RevisionDetailTab = .commit
    @State private var selectedChangedPath: String?
    @State private var detailPaneHeight: CGFloat = 360
    @State private var detailPaneHeightAtDragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = 10
            let availableHeight = max(0, geometry.size.height - dividerHeight)
            let minimumPaneHeight = min(180, availableHeight / 2)
            let maximumDetailHeight = max(minimumPaneHeight, availableHeight - minimumPaneHeight)
            let resolvedDetailHeight = min(max(detailPaneHeight, minimumPaneHeight), maximumDetailHeight)

            VStack(spacing: 0) {
                historyPane
                    .frame(height: max(minimumPaneHeight, availableHeight - resolvedDetailHeight))

                ZStack {
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.55))
                    Capsule()
                        .fill(.secondary.opacity(0.75))
                        .frame(width: 36, height: 3)
                }
                .frame(height: dividerHeight)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        NSCursor.resizeUpDown.set()
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if detailPaneHeightAtDragStart == nil {
                                detailPaneHeightAtDragStart = resolvedDetailHeight
                            }
                            let start = detailPaneHeightAtDragStart ?? resolvedDetailHeight
                            detailPaneHeight = min(
                                max(start - value.translation.height, minimumPaneHeight),
                                maximumDetailHeight
                            )
                        }
                        .onEnded { _ in detailPaneHeightAtDragStart = nil }
                )
                .accessibilityLabel("Resize revision detail")

                revisionDetail
                    .frame(height: resolvedDetailHeight)
            }
        }
        .navigationTitle("History")
        .sheet(isPresented: $showBlame) { BlameSheet(model: model) }
        .task {
            let selectedBeforeLoad = model.selectedRevision
            if model.revisions.isEmpty { await model.loadHistory() }
            if selectedBeforeLoad == model.selectedRevision,
               let revision = selectedRevisionRecord {
                selectRevision(revision)
            }
        }
        .onChange(of: model.selectedRevision) { _, _ in
            guard let revision = selectedRevisionRecord else { return }
            selectRevision(revision)
        }
    }

    private var historyPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search revision, author, message, or path", text: $model.historySearch)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.loadHistory() } }
                Button { Task { await model.loadHistory() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)

            Divider()

            if model.revisions.isEmpty {
                ContentUnavailableView(
                    "No History Loaded",
                    systemImage: "clock",
                    description: Text("Load repository history to inspect revisions.")
                )
            } else {
                historyColumnHeader
                Divider()
                List(model.revisions, selection: $model.selectedRevision) { revision in
                    revisionRow(revision)
                        .tag(revision.revision)
                }
                .listStyle(.plain)
            }
        }
    }

    private var historyColumnHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 26)
            Text("Commit").frame(maxWidth: .infinity, alignment: .leading)
            Text("Author").frame(width: 150, alignment: .leading)
            Text("Revision").frame(width: 78, alignment: .leading)
            Text("Date").frame(width: 170, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    private func revisionRow(_ revision: RevisionRecord) -> some View {
        HStack(spacing: 10) {
            CommitGraphMarker(isCopy: revision.changedPaths.contains { $0.copyFromPath != nil })
                .frame(width: 26, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(revision.message.isEmpty ? "No commit message" : revision.message)
                    .lineLimit(1)
                if let copiedPath = revision.changedPaths.first(where: { $0.copyFromPath != nil })?.copyFromPath {
                    Label(copiedPath, systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(revision.author ?? "Unknown author")
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text("r\(revision.revision)")
                .font(.body.monospacedDigit())
                .frame(width: 78, alignment: .leading)
            Text(revision.timestampUTC?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var revisionDetail: some View {
        if let revision = selectedRevisionRecord {
            VStack(spacing: 0) {
                HStack {
                    Picker("Revision Detail", selection: $detailTab) {
                        Text("Commit").tag(RevisionDetailTab.commit)
                        Text("Changes").tag(RevisionDetailTab.changes)
                        Text("File Tree").tag(RevisionDetailTab.fileTree)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    Spacer()
                    Button {
                        Task { await model.loadRevisionDiff(revision.revision) }
                    } label: {
                        Label("Revision Diff", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(.bar)

                Divider()
                revisionMetadata(revision)
                Divider()

                switch detailTab {
                case .commit:
                    revisionSplit(revision, treeStyle: false)
                case .changes:
                    changesTable(revision)
                case .fileTree:
                    revisionSplit(revision, treeStyle: true)
                }
            }
        } else {
            ContentUnavailableView(
                "No Revision Selected",
                systemImage: "clock.badge.questionmark",
                description: Text("Select a revision to inspect its changed paths and diff.")
            )
        }
    }

    private func revisionMetadata(_ revision: RevisionRecord) -> some View {
        HStack(spacing: 12) {
            Text(revision.author ?? "Unknown author")
                .font(.headline)
            Text("r\(revision.revision)").font(.body.monospacedDigit())
            if let date = revision.timestampUTC {
                Text(date.formatted(date: .long, time: .shortened))
            }
            Divider().frame(height: 18)
            Text(revision.message.isEmpty ? "No commit message" : revision.message)
                .lineLimit(1)
            Spacer()
            Text("\(revision.changedPaths.count) changes")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func revisionSplit(_ revision: RevisionRecord, treeStyle: Bool) -> some View {
        HSplitView {
            changedPathsPane(revision, treeStyle: treeStyle)
                .frame(minWidth: 300, idealWidth: 390)
            DiffInspector(
                text: model.diffText,
                beforeImageData: model.diffBeforeImageData,
                afterImageData: model.diffAfterImageData,
                binaryDescription: model.diffBinaryDescription,
                contextMode: model.diffContextMode,
                isContextLoading: model.isDiffContextLoading,
                onContextModeChange: { mode in Task { await model.setDiffContextMode(mode) } }
            )
            .frame(minWidth: 500, idealWidth: 760)
        }
    }

    private func changedPathsPane(_ revision: RevisionRecord, treeStyle: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: treeStyle ? "folder" : "doc.on.doc")
                Text(treeStyle ? "File Tree" : "Changed Paths").font(.headline)
                Spacer()
                Text(revision.changedPaths.count, format: .number).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            Divider()

            if revision.changedPaths.isEmpty {
                ContentUnavailableView("No Changed Paths", systemImage: "doc")
            } else {
                List(revision.changedPaths) { path in
                    changedPathRow(path, revision: revision, treeStyle: treeStyle)
                        .listRowBackground(selectedChangedPath == path.id ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .listStyle(.plain)
            }
        }
    }

    private func changedPathRow(_ path: ChangedPath, revision: RevisionRecord, treeStyle: Bool) -> some View {
        Button {
            selectedChangedPath = path.id
            Task { await model.loadRevisionPathDiff(path.path, revision: revision.revision) }
        } label: {
            HStack(spacing: 8) {
                ChangedPathBadge(action: path.action)
                Image(systemName: path.nodeKind == .directory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(treeStyle ? URL(fileURLWithPath: path.path).lastPathComponent : path.path)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if treeStyle {
                        Text(URL(fileURLWithPath: path.path).deletingLastPathComponent().path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .padding(.leading, treeStyle ? CGFloat(max(0, path.path.split(separator: "/").count - 2)) * 5 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if path.nodeKind != .directory && path.action != .deleted {
                Button("Blame") {
                    Task {
                        await model.loadBlame(repositoryPath: path.path, revision: revision.revision)
                        showBlame = true
                    }
                }
            }
        }
    }

    private func changesTable(_ revision: RevisionRecord) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Action").frame(width: 54, alignment: .leading)
                Text("Path").frame(maxWidth: .infinity, alignment: .leading)
                Text("Copy From").frame(width: 300, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.bar)
            Divider()
            List(revision.changedPaths) { path in
                HStack(spacing: 10) {
                    ChangedPathBadge(action: path.action).frame(width: 54, alignment: .leading)
                    Text(path.path).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                    Text(path.copyFromPath.map { "\($0) @ r\(path.copyFromRevision ?? 0)" } ?? "—")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 300, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    detailTab = .commit
                    selectedChangedPath = path.id
                    Task { await model.loadRevisionPathDiff(path.path, revision: revision.revision) }
                }
            }
            .listStyle(.plain)
        }
    }

    private var selectedRevisionRecord: RevisionRecord? {
        guard let selectedRevision = model.selectedRevision else { return nil }
        return model.revisions.first { $0.revision == selectedRevision }
    }

    private func selectRevision(_ revision: RevisionRecord) {
        if let path = revision.changedPaths.first {
            selectedChangedPath = path.id
            Task { await model.loadRevisionPathDiff(path.path, revision: revision.revision) }
        } else {
            selectedChangedPath = nil
            Task { await model.loadRevisionDiff(revision.revision) }
        }
    }
}

private enum RevisionDetailTab: Hashable {
    case commit
    case changes
    case fileTree
}

private struct CommitGraphMarker: View {
    let isCopy: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.yellow.opacity(0.8))
                .frame(width: 2)
            Circle()
                .strokeBorder(isCopy ? Color.orange : Color.yellow, lineWidth: 2)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .frame(width: 11, height: 11)
        }
    }
}

private struct ChangedPathBadge: View {
    let action: ChangedPathAction

    var body: some View {
        Text(action.rawValue)
            .font(.caption2.monospaced().bold())
            .frame(width: 20, height: 20)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
    }

    private var color: Color {
        switch action {
        case .added: .green
        case .deleted: .red
        case .replaced: .orange
        case .modified: .yellow
        case .unknown: .secondary
        }
    }
}

struct RepositoryBrowserView: View {
    @Bindable var model: AppModel
    @State private var mutation: RepositoryMutation?
    @State private var deleteTarget: RepositoryEntry?
    @State private var moveTarget: RepositoryEntry?
    @State private var showFilePreview = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { navigateUp() } label: { Image(systemName: "chevron.up") }
                    .disabled(model.repositoryURL == model.selectedProject?.repositoryRootURL)
                TextField("Repository URL", text: Binding(
                    get: { model.repositoryURL?.absoluteString ?? "" },
                    set: { model.repositoryURL = URL(string: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.loadRepository() } }
                TextField("Revision", text: $model.repositoryRevision)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.loadRepository() } }
                Button("Go") { Task { await model.loadRepository() } }
                Menu {
                    Button("New Directory…") { mutation = .mkdir }
                    Button("Create Branch or Tag…") { mutation = .copy }
                } label: { Image(systemName: "plus") }
            }
            .padding(10)
            Divider()

            if model.repositoryEntries.isEmpty {
                ContentUnavailableView("Repository Folder Is Empty", systemImage: "folder", description: Text("No entries were returned for this URL and revision."))
                    .task { await model.loadRepository() }
            } else {
                Table(model.repositoryEntries) {
                    TableColumn("Name") { entry in
                        Label(entry.name, systemImage: entry.kind == .directory ? "folder" : "doc")
                            .onTapGesture(count: 2) { open(entry) }
                            .contextMenu {
                                Button("Open") { open(entry) }
                                if entry.kind != .directory {
                                    Button("Export…") { export(entry) }
                                }
                                Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.url.absoluteString, forType: .string) }
                                Divider()
                                Button("Move or Rename…") { moveTarget = entry }
                                Button("Delete…", role: .destructive) { deleteTarget = entry }
                            }
                    }
                    TableColumn("Revision") { entry in Text(entry.revision.map(String.init) ?? "—").monospacedDigit() }
                    TableColumn("Author") { entry in Text(entry.author ?? "—") }
                    TableColumn("Size") { entry in Text(entry.size.map(ByteCountFormatter.string) ?? "—") }
                }
            }
        }
        .navigationTitle("Repository Browser")
        .sheet(item: $mutation) { mutation in
            RepositoryMutationSheet(model: model, mutation: mutation)
        }
        .sheet(item: $deleteTarget) { entry in
            DeleteRepositorySheet(model: model, entry: entry)
        }
        .sheet(item: $moveTarget) { entry in
            MoveRepositorySheet(model: model, entry: entry)
        }
        .sheet(isPresented: $showFilePreview) { RepositoryFilePreview(model: model) }
    }

    private func open(_ entry: RepositoryEntry) {
        if entry.kind == .directory {
            Task { await model.loadRepository(url: entry.url) }
        } else {
            Task {
                await model.loadRepositoryFile(url: entry.url, revision: model.repositoryRevision)
                showFilePreview = model.repositoryFileData != nil
            }
        }
    }

    private func export(_ entry: RepositoryEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { await model.exportRepositoryFile(url: entry.url, revision: model.repositoryRevision, destination: destination) }
    }

    private func navigateUp() {
        guard let url = model.repositoryURL else { return }
        Task { await model.loadRepository(url: url.deletingLastPathComponent()) }
    }
}

private struct MoveRepositorySheet: View {
    @Bindable var model: AppModel
    let entry: RepositoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var message = ""

    var body: some View {
        Form {
            LabeledContent("Source", value: entry.url.absoluteString)
            TextField("Destination URL", text: $destination)
            TextField("Commit message", text: $message, axis: .vertical).lineLimit(3...6)
            Text("Preview: \(entry.url.absoluteString) → \(destination)").foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move") {
                    guard let url = URL(string: destination) else { return }
                    Task { await model.moveRepositoryEntry(entry, destination: url, message: message); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(URL(string: destination) == nil || message.isEmpty)
            }
        }
        .padding(20).frame(width: 650)
        .onAppear { destination = entry.url.absoluteString }
    }
}

private struct RepositoryFilePreview: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.repositoryFileTitle).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }.padding(12)
            Divider()
            if let data = model.repositoryFileData, let image = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().scaledToFit().padding()
                }
            } else if let data = model.repositoryFileData, let text = String(data: data, encoding: .utf8) {
                ScrollView([.horizontal, .vertical]) {
                    Text(text).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding()
                }
            } else {
                ContentUnavailableView("Binary File", systemImage: "doc.fill", description: Text("Preview is unavailable for this binary format."))
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

private struct BlameSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(model.blameTitle).font(.headline); Spacer(); Button("Done") { dismiss() } }.padding(12)
            Divider()
            Table(model.blameLines) {
                TableColumn("Line") { Text(String($0.lineNumber)).monospacedDigit() }.width(55)
                TableColumn("Revision") { Text($0.revision.map { "r\($0)" } ?? "—").monospacedDigit() }.width(80)
                TableColumn("Author") { Text($0.author ?? "—") }.width(120)
                TableColumn("Content") { Text($0.content ?? "").font(.body.monospaced()).lineLimit(1) }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private enum RepositoryMutation: String, Identifiable {
    case mkdir
    case copy
    var id: String { rawValue }
}

private struct RepositoryMutationSheet: View {
    @Bindable var model: AppModel
    let mutation: RepositoryMutation
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var source = ""
    @State private var destination = ""
    @State private var message = ""

    var body: some View {
        Form {
            if mutation == .mkdir {
                TextField("Directory name", text: $name)
                LabeledContent("Destination", value: model.repositoryURL?.appendingPathComponent(name).absoluteString ?? "")
            } else {
                TextField("Source URL", text: $source)
                TextField("Destination URL", text: $destination)
            }
            TextField("Commit message", text: $message, axis: .vertical)
                .lineLimit(3...6)
            Text("This operation changes the repository immediately.")
                .foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(mutation == .mkdir ? "Create Directory" : "Create Copy") {
                    Task {
                        if mutation == .mkdir {
                            await model.createRepositoryDirectory(name: name, message: message)
                        } else if let sourceURL = URL(string: source), let destinationURL = URL(string: destination) {
                            await model.createBranch(source: sourceURL, destination: destinationURL, message: message)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(message.isEmpty || (mutation == .mkdir ? name.isEmpty : source.isEmpty || destination.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if mutation == .copy {
                source = model.repositoryURL?.absoluteString ?? ""
                destination = model.repositoryURL?.deletingLastPathComponent().appendingPathComponent("branches/new-branch").absoluteString ?? ""
            }
        }
    }
}

private struct DeleteRepositorySheet: View {
    @Bindable var model: AppModel
    let entry: RepositoryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete Repository Path", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(.red)
            Text(entry.url.absoluteString).textSelection(.enabled)
            TextField("Commit message", text: $message, axis: .vertical).lineLimit(3...6)
            Text("The server-side deletion is committed immediately and cannot be cancelled after completion.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Delete", role: .destructive) {
                    Task { await model.deleteRepositoryEntry(entry, message: message); dismiss() }
                }
                .disabled(message.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

private extension ByteCountFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
