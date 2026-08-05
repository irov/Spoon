import AppKit
import SpoonDomain
import SwiftUI

public struct RootView: View {
    @Bindable private var model: AppModel
    @State private var showCheckout = false
    @State private var showCommandPalette = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 340)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
        } detail: {
            DiffInspector(
                text: model.diffText,
                beforeImageData: model.diffBeforeImageData,
                afterImageData: model.diffAfterImageData,
                binaryDescription: model.diffBinaryDescription
            )
                .navigationSplitViewColumnWidth(min: 380, ideal: 620)
        }
        .frame(minWidth: 1_080, minHeight: 680)
        .toolbar { toolbar }
        .alert(item: $model.error) { error in
            Alert(
                title: Text(error.title),
                message: Text([error.message, error.details].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showCheckout) { CheckoutSheet(model: model) }
        .sheet(isPresented: $showCommandPalette) { CommandPaletteView(model: model, isPresented: $showCommandPalette) }
        .onReceive(NotificationCenter.default.publisher(for: .spoonOpenWorkingCopy)) { _ in openWorkingCopy() }
        .onReceive(NotificationCenter.default.publisher(for: .spoonCheckout)) { _ in showCheckout = true }
        .onReceive(NotificationCenter.default.publisher(for: .spoonRefresh)) { _ in Task { await model.refreshStatus() } }
        .onReceive(NotificationCenter.default.publisher(for: .spoonRemoteRefresh)) { _ in Task { await model.refreshStatus(remote: true) } }
        .onReceive(NotificationCenter.default.publisher(for: .spoonCommit)) { _ in Task { await model.commitSelected() } }
        .onReceive(NotificationCenter.default.publisher(for: .spoonUpdate)) { _ in Task { await model.updateWorkingCopy() } }
        .onReceive(NotificationCenter.default.publisher(for: .spoonCommandPalette)) { _ in showCommandPalette = true }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedProject == nil {
            ContentUnavailableView {
                Label("Open a Working Copy", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("Add an existing SVN working copy or check out a repository.")
            } actions: {
                HStack {
                    Button("Open Working Copy…", action: openWorkingCopy)
                    Button("Checkout…") { showCheckout = true }
                }
            }
        } else {
            switch model.selectedSection {
            case .localChanges:
                LocalChangesView(model: model)
            case .history:
                HistoryView(model: model)
            case .repository:
                RepositoryBrowserView(model: model)
            case .branchesAndTags:
                BranchAndMergeView(model: model)
            case .changelists:
                ChangelistsView(model: model)
            case .conflicts:
                ConflictsView(model: model)
            case .tasks:
                TaskCenterView(model: model)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: openWorkingCopy) { Label("Open Working Copy", systemImage: "plus") }
                .help("Open Working Copy")
            Button { showCheckout = true } label: { Label("Checkout", systemImage: "square.and.arrow.down") }
                .help("Checkout")
        }
        ToolbarItemGroup {
            Button { Task { await model.refreshStatus() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedProject == nil || model.isBusy)
            Button { Task { await model.refreshStatus(remote: true) } } label: { Label("Check Remote", systemImage: "network") }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.selectedProject == nil || model.isBusy)
            Button { Task { await model.updateWorkingCopy() } } label: { Label("Update", systemImage: "arrow.down.circle") }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.selectedProject == nil || model.isBusy)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.commitSelected() } } label: { Label("Commit", systemImage: "arrow.up.circle.fill") }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.selectedPaths.isEmpty || model.isBusy)
        }
        ToolbarItem(placement: .status) {
            if model.isBusy { ProgressView().controlSize(.small).help(model.activityMessage) }
        }
    }

    private func openWorkingCopy() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open SVN Working Copy")
        panel.prompt = String(localized: "Open")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addWorkingCopy(url: url) }
    }
}

private struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var showNewGroup = false
    @State private var newGroupName = ""

    var body: some View {
        List(selection: Binding(
            get: { model.selectedProjectID.map { SidebarSelection.project($0) } },
            set: { selection in
                if case .project(let id) = selection,
                   let project = model.projects.first(where: { $0.id == id }) { model.selectProject(project) }
            }
        )) {
            if model.projects.contains(where: \.isFavorite) {
                Section("Favorites") {
                    ForEach(model.projects.filter(\.isFavorite)) { project in projectRow(project) }
                }
            }
            ForEach(model.groups) { group in
                Section(group.name) {
                    ForEach(model.projects.filter { $0.groupID == group.id }) { project in projectRow(project) }
                }
            }
            Section("Projects") {
                ForEach(model.projects.filter { $0.groupID == nil && !$0.isFavorite }) { project in
                    projectRow(project)
                }
            }

            if model.selectedProject != nil {
                Section("Workspace") {
                    ForEach(ProjectSection.allCases) { section in
                        Button {
                            model.selectedSection = section
                            if section == .history { Task { await model.loadHistory() } }
                            if section == .repository { Task { await model.loadRepository() } }
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(model.selectedSection == section ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Spoon")
        .toolbar {
            Button { showNewGroup = true } label: { Label("New Group", systemImage: "folder.badge.plus") }
        }
        .alert("New Project Group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { newGroupName = "" }
            Button("Create") { let name = newGroupName; newGroupName = ""; Task { await model.createGroup(named: name) } }
        }
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        Label {
            HStack {
                Text(project.displayName)
                Spacer()
                if project.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
        } icon: {
            Image(systemName: "externaldrive.connected.to.line.below")
        }
        .tag(SidebarSelection.project(project.id))
        .contextMenu {
            Button(project.isFavorite ? "Remove from Favorites" : "Add to Favorites") { Task { await model.toggleFavorite(project) } }
            Menu("Move to Group") {
                Button("No Group") { Task { await model.assign(project, to: nil) } }
                ForEach(model.groups) { group in Button(group.name) { Task { await model.assign(project, to: group) } } }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.workingCopyRoot]) }
            Divider()
            Button("Remove Project", role: .destructive) { Task { await model.removeSelectedProject() } }
        }
    }
}

private enum SidebarSelection: Hashable {
    case project(UUID)
}

private extension ProjectSection {
    var title: LocalizedStringKey {
        switch self {
        case .localChanges: "Local Changes"
        case .history: "History"
        case .repository: "Repository Browser"
        case .branchesAndTags: "Branches and Tags"
        case .changelists: "Changelists"
        case .conflicts: "Conflicts"
        case .tasks: "Tasks"
        }
    }

    var symbol: String {
        switch self {
        case .localChanges: "doc.badge.ellipsis"
        case .history: "clock.arrow.circlepath"
        case .repository: "folder.badge.gearshape"
        case .branchesAndTags: "arrow.triangle.branch"
        case .changelists: "list.bullet.rectangle"
        case .conflicts: "exclamationmark.triangle"
        case .tasks: "progress.indicator"
        }
    }
}

public extension Notification.Name {
    static let spoonOpenWorkingCopy = Notification.Name("Spoon.OpenWorkingCopy")
    static let spoonCheckout = Notification.Name("Spoon.Checkout")
    static let spoonRefresh = Notification.Name("Spoon.Refresh")
    static let spoonRemoteRefresh = Notification.Name("Spoon.RemoteRefresh")
    static let spoonCommit = Notification.Name("Spoon.Commit")
    static let spoonUpdate = Notification.Name("Spoon.Update")
    static let spoonCommandPalette = Notification.Name("Spoon.CommandPalette")
}
