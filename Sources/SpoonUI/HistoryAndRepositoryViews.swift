import AppKit
import SpoonDomain
import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var showBlame = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search revision, author, message, or path", text: $model.historySearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.loadHistory() } }
                Button("Search") { Task { await model.loadHistory() } }
                Button { Task { await model.loadHistory() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(10)
            Divider()

            if model.revisions.isEmpty {
                ContentUnavailableView("No History Loaded", systemImage: "clock", description: Text("Load repository history to inspect revisions."))
                    .task { await model.loadHistory() }
            } else {
                List(model.revisions, selection: $model.selectedRevision) { revision in
                    revisionRow(revision)
                        .tag(revision.revision)
                        .onTapGesture {
                            model.selectedRevision = revision.revision
                            Task { await model.loadRevisionDiff(revision.revision) }
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .sheet(isPresented: $showBlame) { BlameSheet(model: model) }
    }

    private func revisionRow(_ revision: RevisionRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("r\(revision.revision)").font(.headline.monospacedDigit())
                Text(revision.author ?? "Unknown author").foregroundStyle(.secondary)
                Spacer()
                if let date = revision.timestampUTC { Text(date, style: .relative).foregroundStyle(.secondary) }
            }
            Text(revision.message.isEmpty ? "No commit message" : revision.message)
                .lineLimit(2)
            if !revision.changedPaths.isEmpty {
                DisclosureGroup("\(revision.changedPaths.count) changed paths") {
                    ForEach(revision.changedPaths) { path in
                        HStack {
                            Text(path.action.rawValue).font(.caption.monospaced().bold())
                            Text(path.path).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            if path.nodeKind != .directory && path.action != .deleted {
                                Button("Blame") {
                                    Task { await model.loadBlame(repositoryPath: path.path, revision: revision.revision); showBlame = true }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
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
