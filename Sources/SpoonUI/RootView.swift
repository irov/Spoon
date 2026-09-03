import AppKit
import SpoonDomain
import SwiftUI

public struct RootView: View {
    @Bindable private var model: AppModel
    @State private var showCheckout = false
    @State private var showCommandPalette = false
    @State private var showOperationConsole = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model, openWorkingCopy: openWorkingCopy)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                if model.selectedProject != nil {
                    ProjectTabStrip(model: model, openWorkingCopy: openWorkingCopy)
                    Divider()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showOperationConsole {
                    Divider()
                    OperationConsoleView(
                        model: model,
                        onOpenTaskCenter: {
                            model.selectedSection = .tasks
                            showOperationConsole = false
                        },
                        onClose: { showOperationConsole = false }
                    )
                    .frame(minHeight: 180, idealHeight: 240, maxHeight: 340)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_180, minHeight: 720)
        .toolbar { toolbar }
        .alert(item: $model.error) { error in
            let message = Text([error.message, error.details].compactMap { $0 }.joined(separator: "\n\n"))
            if let recovery = error.recoveryAction {
                return Alert(
                    title: Text(error.title),
                    message: message,
                    primaryButton: .default(Text(recovery.actionTitle)) {
                        model.error = nil
                        Task { await model.performRecovery(recovery) }
                    },
                    secondaryButton: .cancel(Text("Not Now"))
                )
            }
            return Alert(
                title: Text(error.title),
                message: message,
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
        .onReceive(NotificationCenter.default.publisher(for: .spoonToggleConsole)) { _ in
            withAnimation(.easeInOut(duration: 0.16)) { showOperationConsole.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshAutomatically(remote: true) }
        }
        .task {
            var activeTicks = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard NSApp.isActive else { continue }
                activeTicks += 1
                await model.refreshAutomatically(remote: activeTicks.isMultiple(of: 4))
            }
        }
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
            Button(action: openWorkingCopy) { Label("Open", systemImage: "plus") }
                .help("Open Working Copy")
            Button { Task { await model.refreshStatus() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedProject == nil || model.isBusy)
            Button { Task { await model.updateWorkingCopy() } } label: { Label("Update", systemImage: "arrow.down.circle") }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(model.selectedProject == nil || model.isBusy)
            Menu {
                Button { Task { await model.refreshStatus(remote: true) } } label: {
                    Label("Check Remote", systemImage: "network")
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.selectedProject == nil || model.isBusy)
                Divider()
                Button { showCheckout = true } label: {
                    Label("Checkout", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More Working Copy Actions")
        }
        ToolbarItem(placement: .principal) {
            if let project = model.selectedProject {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showOperationConsole.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        VStack(spacing: 1) {
                            Text(project.displayName).font(.headline)
                            Text(model.workingCopyInfo.map { "r\($0.revision)" } ?? "SVN")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "terminal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(showOperationConsole ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(model.isBusy ? "\(model.activityMessage) — Click to show activity" : "Show Activity Console")
                .accessibilityLabel(model.isBusy ? "\(model.activityMessage). Show Activity Console" : "Show Activity Console")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await model.commitSelected() } } label: {
                Label("Commit", systemImage: "arrow.up.circle.fill")
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(
                model.selectedPaths.isEmpty
                    || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isBusy
            )
            .help(model.selectedPaths.isEmpty ? "Stage paths to commit" : "Commit \(model.selectedPaths.count) staged path(s)")
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

private extension SpoonRecoveryAction {
    var actionTitle: LocalizedStringKey {
        switch self {
        case .cleanupWorkingCopy: "Run Cleanup"
        case .cleanupAndRetryUpdate: "Cleanup and Retry"
        }
    }
}

private struct SidebarView: View {
    @Bindable var model: AppModel
    let openWorkingCopy: () -> Void
    @State private var showNewGroup = false
    @State private var newGroupName = ""

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
            Divider()
            List {
                if model.selectedProject != nil {
                    Section {
                        sectionRow(.localChanges, title: "Local Changes", count: model.statusItems.count)
                        sectionRow(.history, title: "All Commits")
                    }

                    Section("Working Copy") {
                        sectionRow(.repository, title: "Repository Browser")
                        sectionRow(.branchesAndTags, title: "Branches and Tags")
                        sectionRow(.changelists, title: "Changelists")
                        sectionRow(.conflicts, title: "Conflicts", count: model.conflicts.count)
                        sectionRow(.tasks, title: "Tasks", count: model.tasks.filter { $0.state == .running }.count)
                    }
                }

                Section("Projects") {
                    ForEach(model.projects) { project in
                        projectRow(project)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Spoon")
        .toolbar {
            Button { showNewGroup = true } label: { Label("New Group", systemImage: "folder.badge.plus") }
        }
        .alert("New Project Group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { newGroupName = "" }
            Button("Create") {
                let name = newGroupName
                newGroupName = ""
                Task { await model.createGroup(named: name) }
            }
        }
    }

    @ViewBuilder
    private var projectHeader: some View {
        if let project = model.selectedProject {
            Menu {
                ForEach(model.projects) { candidate in
                    Button {
                        model.selectProject(candidate)
                    } label: {
                        if candidate.id == project.id {
                            Label(candidate.displayName, systemImage: "checkmark")
                        } else {
                            Text(candidate.displayName)
                        }
                    }
                }
                Divider()
                Button("Open Working Copy…", action: openWorkingCopy)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.displayName).font(.headline).lineLimit(1)
                        Text(project.relativeURL ?? project.workingCopyRoot.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .padding(12)
        } else {
            Button(action: openWorkingCopy) {
                Label("Open Working Copy…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    private func sectionRow(_ section: ProjectSection, title: LocalizedStringKey, count: Int? = nil) -> some View {
        Button {
            model.selectedSection = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).frame(width: 17)
                Text(title)
                Spacer()
                if let count, count > 0 {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selectedSection == section ? Color.accentColor.opacity(0.2) : Color.clear)
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        Button {
            model.selectProject(project)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: project.id == model.selectedProjectID ? "externaldrive.fill" : "externaldrive")
                    .foregroundStyle(project.id == model.selectedProjectID ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.displayName).lineLimit(1)
                    if let group = model.groups.first(where: { $0.id == project.groupID }) {
                        Text(group.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if project.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(project.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { await model.toggleFavorite(project) }
            }
            Menu("Move to Group") {
                Button("No Group") { Task { await model.assign(project, to: nil) } }
                ForEach(model.groups) { group in
                    Button(group.name) { Task { await model.assign(project, to: group) } }
                }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.workingCopyRoot]) }
            Divider()
            Button("Remove Project", role: .destructive) {
                if model.selectedProjectID != project.id { model.selectProject(project) }
                Task { await model.removeSelectedProject() }
            }
        }
    }
}

private struct ProjectTabStrip: View {
    @Bindable var model: AppModel
    let openWorkingCopy: () -> Void
    @State private var hoveredProjectID: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.projects) { project in
                            projectTab(project)
                                .id(project.id)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.never, axes: .horizontal)
                .onChange(of: model.selectedProjectID) { _, selectedProjectID in
                    guard let selectedProjectID else { return }
                    withAnimation(.easeInOut(duration: 0.16)) {
                        proxy.scrollTo(selectedProjectID, anchor: .center)
                    }
                }
            }

            Divider().frame(height: 22)

            Menu {
                ForEach(model.projects) { project in
                    Button {
                        model.selectProject(project)
                    } label: {
                        if project.id == model.selectedProjectID {
                            Label(project.displayName, systemImage: "checkmark")
                        } else {
                            Text(project.displayName)
                        }
                    }
                }
            } label: {
                Label("All Projects", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("All Projects")

            Button(action: openWorkingCopy) {
                Label("Open Working Copy", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Working Copy")
            .padding(.trailing, 8)
        }
        .frame(height: 42)
        .background(.bar)
    }

    private func projectTab(_ project: ProjectRecord) -> some View {
        let isSelected = project.id == model.selectedProjectID
        let isHovered = project.id == hoveredProjectID

        return Button {
            model.selectProject(project)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "externaldrive.fill" : "externaldrive")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(project.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if project.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 11)
            .frame(minWidth: 110, maxWidth: 190, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : isHovered ? Color.primary.opacity(0.07) : Color.clear
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.42) : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(project.workingCopyRoot.path)
        .onHover { hovering in hoveredProjectID = hovering ? project.id : nil }
        .contextMenu {
            Button(project.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { await model.toggleFavorite(project) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.workingCopyRoot])
            }
            Divider()
            Button("Remove Project", role: .destructive) {
                if model.selectedProjectID != project.id { model.selectProject(project) }
                Task { await model.removeSelectedProject() }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension ProjectSection {
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
    static let spoonToggleConsole = Notification.Name("Spoon.ToggleConsole")
}
