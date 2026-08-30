import AppKit
import Foundation
import Observation
import SpoonDiagnostics
import SpoonDomain
import SpoonSecurity
import SpoonStorage
import SpoonSVN

struct SVNIgnoreTarget: Identifiable, Sendable {
    var id: String { anchorPath }
    let requestedPath: String
    let anchorPath: String
    let parentURL: URL
    let exactPattern: String
    let nodeKind: NodeKind
    let wasScheduledForAddition: Bool

    var extensionPattern: String? {
        guard nodeKind != .directory else { return nil }
        return SVNIgnoreProperty.extensionPattern(forFileName: exactPattern)
    }
}

struct RevisionImagePreview: Identifiable, Sendable {
    var id: String { repositoryPath }
    let repositoryPath: String
    let beforeData: Data?
    let afterData: Data?
    let beforeRevision: Int?
    let revision: Int

    func matches(diffPath: String) -> Bool {
        let repositoryPath = Self.normalized(repositoryPath)
        let diffPath = Self.normalized(diffPath)
        return repositoryPath == diffPath
            || repositoryPath.hasSuffix("/\(diffPath)")
            || diffPath.hasSuffix("/\(repositoryPath)")
    }

    private static func normalized(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

@MainActor
@Observable
public final class AppModel {
    public var projects: [ProjectRecord] = []
    public var groups: [ProjectGroup] = []
    public var selectedProjectID: UUID?
    public var selectedSection: ProjectSection = .localChanges
    public var statusItems: [StatusItem] = []
    public var selectedPaths = Set<String>()
    public var commitMessage = ""
    public var filterText = ""
    public var showIgnored = false
    public var isBusy = false
    public var diffText = ""
    public var diffBeforeImageData: Data?
    public var diffAfterImageData: Data?
    public var diffBinaryDescription: String?
    var revisionImagePreviews: [RevisionImagePreview] = []
    var diffBeforeImageTitle = "Before"
    var diffAfterImageTitle = "Working Copy"
    var diffContextMode: DiffContextMode = .changes
    var isDiffContextLoading = false
    public var workingCopyInfo: WorkingCopyInfo?
    public var revisions: [RevisionRecord] = []
    public var selectedRevision: Int?
    public var historySearch = ""
    public var repositoryURL: URL?
    public var repositoryRevision = "HEAD"
    public var repositoryEntries: [RepositoryEntry] = []
    public var tasks: [TaskRecord] = []
    public var capabilities: SVNCapabilitySet?
    public var blameLines: [BlameLine] = []
    public var blameTitle = ""
    public var repositoryFileData: Data?
    public var repositoryFileTitle = ""
    public var error: PresentedError?
    public var activityMessage = ""
    public var lastRemoteStatusCheck: Date?

    private let svn: SVNService
    private let storage: SQLiteStore?
    private let diagnostics = DiagnosticExporter()
    private var projectScopes: [UUID: ResolvedSecurityScope] = [:]
    private var taskObserver: Task<Void, Never>?
    private var workingCopyWatcher: WorkingCopyWatcher?
    private var pendingAutomaticRefresh = false
    private var pendingAutomaticRemoteRefresh = false
    private var isAutomaticRefreshInProgress = false
    private var currentDiffRequest: DiffRequest?

    private static let fullFileDiffContextLines = Int(Int32.max)

    private enum DiffRequest {
        case workingCopy(path: String)
        case workingCopyProperties(path: String)
        case revision(Int)
        case revisionPath(path: String, revision: Int)
    }

    public init() {
        svn = SVNService()
        storage = try? SQLiteStore()
        workingCopyWatcher = nil
        SecureTemporaryFile.removeAbandonedFiles()
        workingCopyWatcher = WorkingCopyWatcher { [weak self] checkRemote in
            self?.workingCopyDidChange(checkRemote: checkRemote)
        }
        Task { [svn] in
            await svn.setAuthenticationProvider { challenge in
                try await AppModel.authenticationResponse(for: challenge)
            }
        }
        Task { await bootstrap() }
    }

    public var selectedProject: ProjectRecord? {
        guard let selectedProjectID else { return nil }
        return projects.first(where: { $0.id == selectedProjectID })
    }

    public var filteredStatusItems: [StatusItem] {
        statusItems.filter { item in
            let ignoredVisible = showIgnored || item.workingCopyStatus != .ignored
            let matches = filterText.isEmpty || item.relativePath.localizedCaseInsensitiveContains(filterText)
            return ignoredVisible && matches
        }
    }

    public var conflicts: [StatusItem] {
        statusItems.filter { $0.workingCopyStatus == .conflicted || $0.treeConflicted || $0.propertyStatus == .conflicted }
    }

    public func bootstrap() async {
        if let storage {
            do {
                projects = try await storage.loadProjects()
                groups = try await storage.loadGroups()
                tasks = try await storage.loadTasks()
                selectedProjectID = projects.first?.id
                for project in projects { restoreScope(for: project) }
                if let project = selectedProject { await loadDraft(for: project) }
            } catch {
                present(error)
            }
        }

        taskObserver = Task { [weak self, svn] in
            let stream = await svn.taskUpdates()
            for await records in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self?.tasks = records
                }
                if let storage = self?.storage {
                    for record in records { try? await storage.saveTask(record) }
                }
            }
        }

        do {
            capabilities = try await svn.capabilityProbe()
        } catch {
            present(error)
        }
        if selectedProject != nil { await refreshStatus(remote: true) }
        workingCopyWatcher?.watch(selectedProject?.workingCopyRoot)
    }

    public func selectProject(_ project: ProjectRecord) {
        guard selectedProjectID != project.id else { return }
        selectedProjectID = project.id
        statusItems = []
        revisions = []
        repositoryEntries = []
        diffText = ""
        diffBeforeImageData = nil
        diffAfterImageData = nil
        diffBinaryDescription = nil
        revisionImagePreviews = []
        diffBeforeImageTitle = "Before"
        diffAfterImageTitle = "Working Copy"
        currentDiffRequest = nil
        selectedPaths = []
        repositoryURL = project.repositoryRootURL
        lastRemoteStatusCheck = nil
        workingCopyWatcher?.watch(project.workingCopyRoot)
        Task {
            await loadDraft(for: project)
            await refreshStatus(remote: true)
        }
    }

    public func addWorkingCopy(url: URL) async {
        await withActivity("Opening working copy…") {
            try await registerWorkingCopy(url: url, requireSelectedRoot: true)
            if let project = selectedProject { try await reloadStatus(project: project) }
        }
    }

    @discardableResult
    public func checkout(
        repositoryURL: URL,
        destination: URL,
        revision: String,
        depth: String,
        ignoreExternals: Bool
    ) async -> Bool {
        var succeeded = false
        await withActivity("Checking out repository…") {
            let scope = ResolvedSecurityScope(url: destination)
            _ = scope
            activityMessage = try await svn.checkout(
                url: repositoryURL,
                destination: destination,
                revision: revision,
                depth: depth,
                ignoreExternals: ignoreExternals,
                securityScopedBookmark: try SecurityScopedBookmark(url: destination).data
            )
            try await registerWorkingCopy(url: destination, requireSelectedRoot: false)
            if let project = selectedProject { try await reloadStatus(project: project) }
            succeeded = true
        }
        return succeeded
    }

    public func removeSelectedProject() async {
        guard let project = selectedProject else { return }
        projects.removeAll { $0.id == project.id }
        projectScopes[project.id] = nil
        selectedProjectID = projects.first?.id
        lastRemoteStatusCheck = nil
        workingCopyWatcher?.watch(selectedProject?.workingCopyRoot)
        try? await storage?.removeProject(id: project.id)
        statusItems = []
        diffText = ""
        currentDiffRequest = nil
        if selectedProject != nil { await refreshStatus() }
    }

    public func toggleFavorite(_ project: ProjectRecord) async {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].isFavorite.toggle()
        try? await storage?.saveProject(projects[index])
    }

    public func createGroup(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let group = ProjectGroup(name: trimmed, sortIndex: groups.count)
        groups.append(group)
        try? await storage?.saveGroup(group)
    }

    public func assign(_ project: ProjectRecord, to group: ProjectGroup?) async {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].groupID = group?.id
        try? await storage?.saveProject(projects[index])
    }

    public func refreshStatus(remote: Bool = false) async {
        guard let project = selectedProject else { return }
        await withActivity(remote ? "Checking remote changes…" : "Refreshing changes…") {
            try await reloadStatus(project: project, remote: remote)
            if remote, selectedSection == .history {
                try await reloadHistory(project: project)
            }
        }
    }

    public func refreshAutomatically(remote: Bool = false) async {
        guard let project = selectedProject else { return }
        guard !isBusy, !isAutomaticRefreshInProgress else {
            pendingAutomaticRefresh = true
            pendingAutomaticRemoteRefresh = pendingAutomaticRemoteRefresh || remote
            return
        }

        isAutomaticRefreshInProgress = true
        do {
            try await reloadStatus(project: project, remote: remote)
            if remote, selectedSection == .history {
                try await reloadHistory(project: project)
            }
        } catch {
            // Background checks keep the last known state. A manual refresh still
            // presents authentication, connectivity, and working-copy errors.
        }
        isAutomaticRefreshInProgress = false

        if pendingAutomaticRefresh {
            let checkRemote = pendingAutomaticRemoteRefresh
            pendingAutomaticRefresh = false
            pendingAutomaticRemoteRefresh = false
            await refreshAutomatically(remote: checkRemote)
        }
    }

    public func loadDiff(path: String) async {
        currentDiffRequest = .workingCopy(path: path)
        guard let project = selectedProject else { return }
        do {
            let file = project.workingCopyRoot.appendingPathComponent(path)
            let item = statusItems.first(where: { $0.relativePath == path })
            diffBeforeImageData = nil
            diffAfterImageData = nil
            diffBinaryDescription = nil
            revisionImagePreviews = []
            diffBeforeImageTitle = "Before"
            diffAfterImageTitle = "Working Copy"
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic"]
            if imageExtensions.contains(file.pathExtension.lowercased()), item?.nodeKind != .directory {
                if item?.workingCopyStatus != .added {
                    diffBeforeImageData = try? await svn.contents(project: project, target: file.path, revision: "BASE")
                }
                if item?.workingCopyStatus != .deleted && item?.workingCopyStatus != .missing {
                    diffAfterImageData = try? Data(contentsOf: file)
                }
                diffText = ""
                return
            }

            switch item?.workingCopyStatus {
            case .unversioned, .ignored:
                guard item?.nodeKind != .directory else {
                    diffText = "No textual diff is available for an unversioned directory."
                    return
                }
                guard let data = try? Data(contentsOf: file) else {
                    diffText = "The local file is no longer present. Refresh Local Changes to update its status."
                    return
                }
                guard let contents = String(data: data, encoding: .utf8), !data.contains(0) else {
                    diffText = ""
                    diffBinaryDescription = "Unversioned file · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
                    return
                }
                diffText = Self.localFileDiff(path: path, contents: contents, added: true)
                return

            case .missing:
                guard item?.nodeKind != .directory else {
                    diffText = "The versioned directory is missing from the working copy."
                    return
                }
                guard let data = try? await svn.contents(project: project, target: file.path, revision: "BASE") else {
                    diffText = "The versioned file is missing from the working copy. Its BASE contents are unavailable."
                    return
                }
                guard let contents = String(data: data, encoding: .utf8), !data.contains(0) else {
                    diffText = ""
                    diffBinaryDescription = "Missing versioned file · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
                    return
                }
                diffText = Self.localFileDiff(path: path, contents: contents, added: false)
                return

            case .external, .incomplete, .obstructed, .unknown:
                diffText = "A textual diff is not available for the \(item?.workingCopyStatus.rawValue ?? "unknown") working-copy state."
                return

            default:
                break
            }

            if item?.nodeKind != .directory,
               item?.workingCopyStatus != .deleted,
               !FileManager.default.fileExists(atPath: file.path) {
                diffText = "The local file is no longer present. Refresh Local Changes to update its status."
                return
            }

            diffText = try await svn.diff(
                project: project,
                paths: [file.path],
                contextLines: requestedDiffContextLines,
                content: .textOnly
            )
            let hasWorkingCopyChange = item.map {
                $0.workingCopyStatus != .none && $0.workingCopyStatus != .normal
            } ?? false
            if diffText.isEmpty, item?.nodeKind != .directory, hasWorkingCopyChange {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                diffBinaryDescription = size.map { "Binary file · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "Binary file"
            }
        } catch {
            diffText = ""
            present(error)
        }
    }

    public func loadPropertyDiff(path: String) async {
        currentDiffRequest = .workingCopyProperties(path: path)
        guard let project = selectedProject else { return }
        do {
            diffBeforeImageData = nil
            diffAfterImageData = nil
            diffBinaryDescription = nil
            revisionImagePreviews = []
            let target = project.workingCopyRoot.appendingPathComponent(path).path
            let rawDiff = try await svn.diff(
                project: project,
                paths: [target],
                content: .propertiesOnly,
                depth: "empty"
            )
            diffText = Self.propertyDiffForDisplay(rawDiff, relativePath: path)
        } catch {
            diffText = ""
            present(error)
        }
    }

    private static func propertyDiffForDisplay(_ diff: String, relativePath: String) -> String {
        let displayPath = relativePath == "." ? String(localized: "Working Copy") : relativePath
        let propertyPath = "\(displayPath) · \(String(localized: "Properties"))"
        var replacedIndex = false
        return diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                if !replacedIndex, line.hasPrefix("Index: ") {
                    replacedIndex = true
                    return "Index: \(propertyPath)"
                }
                if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                    let prefix = String(line.prefix(4))
                    let suffix = line.firstIndex(of: "\t").map { String(line[$0...]) } ?? ""
                    return "\(prefix)\(propertyPath)\(suffix)"
                }
                if line.hasPrefix("Property changes on: ") {
                    return "Property changes on: \(displayPath)"
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    private static func localFileDiff(path: String, contents: String, added: Bool) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if contents.hasSuffix("\n"), lines.last?.isEmpty == true { lines.removeLast() }
        let oldCount = added ? 0 : lines.count
        let newCount = added ? lines.count : 0
        let oldStart = added ? 0 : 1
        let newStart = added ? 1 : 0
        let oldLabel = added ? "(nonexistent)" : "(BASE)"
        let newLabel = added ? "(working copy)" : "(nonexistent)"
        let prefix = added ? "+" : "-"
        let body = lines.map { prefix + $0 }.joined(separator: "\n")
        return """
        Index: \(path)
        ===================================================================
        --- \(path)\t\(oldLabel)
        +++ \(path)\t\(newLabel)
        @@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@
        \(body)
        """
    }

    public func updateWorkingCopy() async {
        guard let project = selectedProject else { return }
        await withActivity("Updating working copy…") {
            activityMessage = try await svn.update(
                project: project,
                includeExternals: project.settingsOverride?.includeExternalsOnUpdate ?? true
            )
            try await reloadStatus(project: project, remote: true)
        }
    }

    public func cleanupWorkingCopy() async {
        guard let project = selectedProject else { return }
        await withActivity("Cleaning working copy…") {
            activityMessage = try await svn.cleanup(project: project)
            try await reloadStatus(project: project)
        }
    }

    public func commitSelected() async {
        guard let project = selectedProject else { return }
        let selectedItems = statusItems.filter { selectedPaths.contains($0.relativePath) }
        guard !selectedItems.isEmpty else {
            present(SpoonError(title: "Nothing staged", explanation: "Stage at least one changed path to commit."))
            return
        }
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            present(SpoonError(title: "Commit message is empty", explanation: "Enter a message before committing."))
            return
        }
        guard !selectedItems.contains(where: { $0.workingCopyStatus == .conflicted || $0.treeConflicted || $0.propertyStatus == .conflicted }) else {
            present(SpoonError(title: "Unresolved conflict staged", explanation: "Resolve conflicts before committing."))
            return
        }
        let ineligibleItems = selectedItems.filter { !$0.isCommitEligible }
        guard ineligibleItems.isEmpty else {
            let paths = ineligibleItems.prefix(5).map(\.relativePath).joined(separator: "\n")
            present(SpoonError(
                title: String(localized: "Staged paths cannot be committed"),
                explanation: String(localized: "Add unversioned paths to SVN, schedule missing paths for deletion, or unstage them before committing.") + "\n\n" + paths
            ))
            return
        }

        let targets = selectedItems.map(\.absolutePath.path)
        await withActivity("Committing \(targets.count) path(s)…") {
            let revision = try await svn.commit(project: project, targets: targets, message: commitMessage)
            activityMessage = revision.map { "Committed revision r\($0)." } ?? "Commit completed."
            commitMessage = ""
            selectedPaths = []
            try await storage?.saveDraft(CommitDraft(projectID: project.id))
            try await reloadStatus(project: project, remote: true)
            revisions = try await svn.history(project: project, limit: 200, search: historySearch.isEmpty ? nil : historySearch)
        }
    }

    public func saveDraft() async {
        guard let project = selectedProject else { return }
        try? await storage?.saveDraft(CommitDraft(projectID: project.id, message: commitMessage, selectedRelativePaths: selectedPaths))
    }

    public func stage(paths: [String]) async {
        guard let project = selectedProject else { return }
        let requestedPaths = Set(paths)
        let requestedItems = statusItems.filter { requestedPaths.contains($0.relativePath) && $0.isStageable }
        let stageableItems = StatusItem.expandingSelection(requestedPaths, in: statusItems)
            .filter(\.isStageable)
        guard !stageableItems.isEmpty else { return }

        let unversionedItems = requestedItems
            .filter { $0.workingCopyStatus == .unversioned }
        let unversionedDirectoryPaths = unversionedItems
            .filter { $0.nodeKind == .directory }
            .map(\.relativePath)
        let unversionedPaths = unversionedItems
            .filter { item in
                !unversionedDirectoryPaths.contains {
                    $0 != item.relativePath && item.relativePath.hasPrefix($0 + "/")
                }
            }
            .map(\.relativePath)

        guard !unversionedPaths.isEmpty else {
            selectedPaths.formUnion(stageableItems.map(\.relativePath))
            return
        }

        await withActivity("Adding and staging paths…") {
            activityMessage = try await svn.add(
                project: project,
                targets: absolute(unversionedPaths, project: project)
            )
            try await reloadStatus(project: project)
            let stagedPaths = StatusItem.expandingSelection(requestedPaths, in: statusItems)
                .filter(\.isCommitEligible)
                .map(\.relativePath)
            selectedPaths.formUnion(stagedPaths)
            activityMessage = "Staged \(stagedPaths.count) path(s)."
        }
    }

    public func unstage(paths: [String]) {
        let requestedPaths = Set(paths)
        let pathsToUnstage = StatusItem.expandingSelection(requestedPaths, in: statusItems)
            .map(\.relativePath)
        selectedPaths.subtract(pathsToUnstage)
    }

    public func add(paths: [String]) async {
        guard let project = selectedProject else { return }
        await withActivity("Adding paths…") {
            activityMessage = try await svn.add(project: project, targets: absolute(paths, project: project))
            try await reloadStatus(project: project)
        }
    }

    func ignoreTarget(for path: String) -> SVNIgnoreTarget? {
        guard let requestedItem = statusItems.first(where: {
            $0.relativePath == path && $0.canAddToIgnore
        }) else { return nil }

        let anchorItem: StatusItem
        if requestedItem.workingCopyStatus == .unversioned {
            let unversionedAncestors = statusItems.filter {
                $0.workingCopyStatus == .unversioned
                    && (path == $0.relativePath || path.hasPrefix($0.relativePath + "/"))
            }
            guard let outermostUnversionedItem = unversionedAncestors.min(by: { lhs, rhs in
                lhs.relativePath.split(separator: "/").count < rhs.relativePath.split(separator: "/").count
            }) else { return nil }
            anchorItem = outermostUnversionedItem
        } else {
            anchorItem = requestedItem
        }

        let anchorURL = anchorItem.absolutePath
        return SVNIgnoreTarget(
            requestedPath: path,
            anchorPath: anchorItem.relativePath,
            parentURL: anchorURL.deletingLastPathComponent(),
            exactPattern: anchorURL.lastPathComponent,
            nodeKind: anchorItem.nodeKind,
            wasScheduledForAddition: anchorItem.workingCopyStatus == .added
        )
    }

    func addToIgnore(target: SVNIgnoreTarget, pattern: String) async {
        guard let project = selectedProject,
              let currentTarget = ignoreTarget(for: target.requestedPath),
              currentTarget.anchorPath == target.anchorPath else { return }

        let parentURL = currentTarget.parentURL
        let anchorPath = currentTarget.anchorPath
        guard !pattern.isEmpty,
              !pattern.contains(where: \.isNewline),
              !pattern.contains("/") else {
            present(SpoonError(title: "Path cannot be ignored", explanation: "SVN ignore patterns cannot contain line breaks or path separators."))
            return
        }

        await withActivity("Adding path to SVN ignore…") {
            let properties = try await svn.properties(project: project, target: parentURL.path)
            let existingValue = properties.first(where: { $0.name == "svn:ignore" })?.value ?? ""
            let updatedValue = SVNIgnoreProperty.adding(pattern: pattern, to: existingValue)

            if updatedValue != existingValue {
                activityMessage = try await svn.setProperty(
                    project: project,
                    name: "svn:ignore",
                    value: Data(updatedValue.utf8),
                    targets: [parentURL.path]
                )
            }

            if currentTarget.wasScheduledForAddition {
                activityMessage = try await svn.revert(
                    project: project,
                    targets: [currentTarget.parentURL.appendingPathComponent(currentTarget.exactPattern).path],
                    depth: currentTarget.nodeKind == .directory ? "infinity" : "empty"
                )
            } else if updatedValue == existingValue {
                activityMessage = "Path is already ignored."
                return
            }

            try await reloadStatus(project: project)
            if let propertyItem = statusItems.first(where: {
                $0.absolutePath.standardizedFileURL == parentURL.standardizedFileURL
                    && $0.propertyStatus != .none
                    && $0.propertyStatus != .normal
            }) {
                await loadPropertyDiff(path: propertyItem.relativePath)
            }
            activityMessage = "Added \(anchorPath) to svn:ignore."
        }
    }

    public func revert(paths: [String], recursive: Bool = false) async {
        guard let project = selectedProject else { return }
        await withActivity("Reverting paths…") {
            activityMessage = try await svn.revert(project: project, targets: absolute(paths, project: project), depth: recursive ? "infinity" : "empty")
            try await reloadStatus(project: project)
        }
    }

    public func delete(paths: [String], keepLocal: Bool = false) async {
        guard let project = selectedProject else { return }
        await withActivity("Scheduling deletion…") {
            activityMessage = try await svn.delete(project: project, targets: absolute(paths, project: project), keepLocal: keepLocal)
            try await reloadStatus(project: project)
        }
    }

    public func move(path: String, to destination: URL) async {
        guard let project = selectedProject else { return }
        await withActivity("Moving path…") {
            let source = project.workingCopyRoot.appendingPathComponent(path).path
            activityMessage = try await svn.move(project: project, source: source, destination: destination.path)
            try await reloadStatus(project: project)
        }
    }

    public func resolve(paths: [String], choice: ConflictResolution) async {
        guard let project = selectedProject else { return }
        await withActivity("Resolving conflicts…") {
            activityMessage = try await svn.resolve(project: project, targets: absolute(paths, project: project), choice: choice)
            try await reloadStatus(project: project)
        }
    }

    public func lock(paths: [String], message: String?) async {
        guard let project = selectedProject else { return }
        await withActivity("Locking paths…") {
            activityMessage = try await svn.lock(project: project, targets: absolute(paths, project: project), message: message)
            try await reloadStatus(project: project)
        }
    }

    public func unlock(paths: [String]) async {
        guard let project = selectedProject else { return }
        await withActivity("Unlocking paths…") {
            activityMessage = try await svn.unlock(project: project, targets: absolute(paths, project: project))
            try await reloadStatus(project: project)
        }
    }

    public func setChangelist(_ name: String?, paths: [String]) async {
        guard let project = selectedProject else { return }
        await withActivity(name == nil ? "Removing changelist…" : "Assigning changelist…") {
            activityMessage = try await svn.setChangelist(project: project, name: name, targets: absolute(paths, project: project))
            try await reloadStatus(project: project)
        }
    }

    func open(path: String, with preset: ExternalToolPreset? = nil, compareWithBase: Bool = false) async {
        guard let project = selectedProject else { return }
        let current = project.workingCopyRoot.appendingPathComponent(path)
        do {
            if compareWithBase {
                let contents = try await svn.contents(project: project, target: current.path, revision: "BASE")
                let baseDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Spoon-ExternalDiff", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let base = baseDirectory.appendingPathComponent(current.deletingPathExtension().lastPathComponent + "-BASE" + (current.pathExtension.isEmpty ? "" : ".\(current.pathExtension)"))
                try contents.write(to: base, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: base.path)
                try await ExternalToolLauncher.open([base, current], with: preset)
            } else {
                try await ExternalToolLauncher.open([current], with: preset)
            }
        } catch { present(error) }
    }

    public func loadHistory() async {
        guard let project = selectedProject else { return }
        await withActivity("Loading history…") {
            try await reloadHistory(project: project)
        }
    }

    public func loadRevisionDiff(_ revision: Int) async {
        currentDiffRequest = .revision(revision)
        guard let project = selectedProject else { return }
        do {
            diffBeforeImageData = nil
            diffAfterImageData = nil
            diffBinaryDescription = nil
            revisionImagePreviews = []
            diffBeforeImageTitle = "Before"
            diffAfterImageTitle = "Working Copy"
            let target = project.repositoryRootURL?.absoluteString ?? project.workingCopyRoot.path
            diffText = try await svn.diff(
                project: project,
                paths: [target],
                change: revision,
                contextLines: requestedDiffContextLines
            )

            guard case let .revision(requestedRevision) = currentDiffRequest,
                  requestedRevision == revision,
                  let record = revisions.first(where: { $0.revision == revision }) else { return }
            for path in record.changedPaths where Self.isImagePath(path) {
                if let preview = await revisionImagePreview(for: path, revision: revision, project: project) {
                    guard case let .revision(requestedRevision) = currentDiffRequest,
                          requestedRevision == revision else { return }
                    revisionImagePreviews.append(preview)
                }
            }
        } catch { present(error) }
    }

    public func loadRevisionPathDiff(_ changedPath: ChangedPath, revision: Int) async {
        currentDiffRequest = .revisionPath(path: changedPath.path, revision: revision)
        guard let project = selectedProject else { return }
        do {
            diffBeforeImageData = nil
            diffAfterImageData = nil
            diffBinaryDescription = nil
            revisionImagePreviews = []
            diffBeforeImageTitle = "Before"
            diffAfterImageTitle = "Working Copy"

            if Self.isImagePath(changedPath),
               let preview = await revisionImagePreview(for: changedPath, revision: revision, project: project) {
                diffBeforeImageData = preview.beforeData
                diffAfterImageData = preview.afterData
                diffBeforeImageTitle = preview.beforeRevision.map { "Before · r\($0)" } ?? "Before"
                diffAfterImageTitle = "Revision · r\(revision)"
                diffText = ""
                return
            }

            let target = repositoryTarget(for: changedPath.path, project: project)
            diffText = try await svn.diff(
                project: project,
                paths: [target],
                change: revision,
                contextLines: requestedDiffContextLines
            )
        } catch {
            diffText = ""
            present(error)
        }
    }

    func setDiffContextMode(_ mode: DiffContextMode) async {
        guard mode != diffContextMode else { return }
        diffContextMode = mode
        guard let currentDiffRequest else { return }

        isDiffContextLoading = true
        defer { isDiffContextLoading = false }
        switch currentDiffRequest {
        case let .workingCopy(path):
            await loadDiff(path: path)
        case let .workingCopyProperties(path):
            await loadPropertyDiff(path: path)
        case let .revision(revision):
            await loadRevisionDiff(revision)
        case let .revisionPath(path, revision):
            let changedPath = revisions
                .first(where: { $0.revision == revision })?
                .changedPaths
                .first(where: { $0.path == path })
                ?? ChangedPath(path: path, action: .unknown)
            await loadRevisionPathDiff(changedPath, revision: revision)
        }
    }

    private static func isImagePath(_ path: ChangedPath) -> Bool {
        guard path.nodeKind != .directory else { return false }
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "heic"]
        return extensions.contains(URL(fileURLWithPath: path.path).pathExtension.lowercased())
    }

    private func revisionImagePreview(
        for path: ChangedPath,
        revision: Int,
        project: ProjectRecord
    ) async -> RevisionImagePreview? {
        var beforeData: Data?
        var beforeRevision: Int?
        var afterData: Data?

        if path.action == .added,
           let copyFromPath = path.copyFromPath,
           let copyFromRevision = path.copyFromRevision {
            beforeRevision = copyFromRevision
            let target = repositoryTarget(for: copyFromPath, project: project, pegRevision: copyFromRevision)
            beforeData = try? await svn.contents(
                project: project,
                target: target,
                revision: String(copyFromRevision)
            )
        } else if path.action != .added {
            let previousRevision = max(0, revision - 1)
            beforeRevision = previousRevision
            let target = repositoryTarget(for: path.path, project: project, pegRevision: previousRevision)
            beforeData = try? await svn.contents(
                project: project,
                target: target,
                revision: String(previousRevision)
            )
        }

        if path.action != .deleted {
            let target = repositoryTarget(for: path.path, project: project, pegRevision: revision)
            afterData = try? await svn.contents(project: project, target: target, revision: String(revision))
        }

        guard beforeData != nil || afterData != nil else { return nil }
        return RevisionImagePreview(
            repositoryPath: path.path,
            beforeData: beforeData,
            afterData: afterData,
            beforeRevision: beforeRevision,
            revision: revision
        )
    }

    private func repositoryTarget(
        for repositoryPath: String,
        project: ProjectRecord,
        pegRevision: Int? = nil
    ) -> String {
        let relativePath = repositoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let target = project.repositoryRootURL?
            .appendingPathComponent(relativePath)
            .absoluteString ?? project.workingCopyRoot.appendingPathComponent(relativePath).path
        return pegRevision.map { "\(target)@\($0)" } ?? target
    }

    private var requestedDiffContextLines: Int? {
        diffContextMode == .fullFile ? Self.fullFileDiffContextLines : nil
    }

    public func loadRepository(url: URL? = nil) async {
        guard let project = selectedProject,
              let url = url ?? repositoryURL ?? project.repositoryRootURL else { return }
        repositoryURL = url
        await withActivity("Loading repository…") {
            repositoryEntries = try await svn.repositoryList(project: project, url: url, revision: repositoryRevision)
        }
    }

    public func createRepositoryDirectory(name: String, message: String) async {
        guard let project = selectedProject, let parent = repositoryURL else { return }
        await withActivity("Creating repository directory…") {
            _ = try await svn.createRepositoryDirectory(project: project, url: parent.appendingPathComponent(name), message: message)
            repositoryEntries = try await svn.repositoryList(project: project, url: parent, revision: repositoryRevision)
        }
    }

    public func deleteRepositoryEntry(_ entry: RepositoryEntry, message: String) async {
        guard let project = selectedProject else { return }
        await withActivity("Deleting repository path…") {
            _ = try await svn.repositoryDelete(project: project, url: entry.url, message: message)
            if let repositoryURL { repositoryEntries = try await svn.repositoryList(project: project, url: repositoryURL, revision: repositoryRevision) }
        }
    }

    public func createBranch(source: URL, destination: URL, message: String) async {
        guard let project = selectedProject else { return }
        await withActivity("Creating repository copy…") {
            _ = try await svn.repositoryCopy(project: project, source: source, destination: destination, message: message)
            if let repositoryURL { repositoryEntries = try await svn.repositoryList(project: project, url: repositoryURL, revision: repositoryRevision) }
        }
    }

    public func moveRepositoryEntry(_ entry: RepositoryEntry, destination: URL, message: String) async {
        guard let project = selectedProject else { return }
        await withActivity("Moving repository path…") {
            _ = try await svn.repositoryMove(project: project, source: entry.url, destination: destination, message: message)
            if let repositoryURL { repositoryEntries = try await svn.repositoryList(project: project, url: repositoryURL, revision: repositoryRevision) }
        }
    }

    public func loadRepositoryFile(url: URL, revision: String) async {
        guard let project = selectedProject else { return }
        await withActivity("Loading historical file…") {
            repositoryFileData = try await svn.contents(project: project, target: url.absoluteString, revision: revision)
            repositoryFileTitle = url.lastPathComponent + " @ " + revision
        }
    }

    public func exportRepositoryFile(url: URL, revision: String, destination: URL) async {
        guard let project = selectedProject else { return }
        await withActivity("Exporting historical file…") {
            let data = try await svn.contents(project: project, target: url.absoluteString, revision: revision)
            let scope = ResolvedSecurityScope(url: destination.deletingLastPathComponent())
            _ = scope
            try data.write(to: destination, options: .atomic)
        }
    }

    public func loadBlame(repositoryPath: String, revision: Int) async {
        guard let project = selectedProject, let root = project.repositoryRootURL else { return }
        let target = root.appendingPathComponent(repositoryPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        await withActivity("Loading blame…") {
            blameLines = try await svn.blame(project: project, target: target.absoluteString, revision: String(revision))
            blameTitle = "\(repositoryPath) @ r\(revision)"
        }
    }

    public func switchWorkingCopy(to url: URL, revision: String = "HEAD") async {
        guard let project = selectedProject else { return }
        await withActivity("Switching working copy…") {
            activityMessage = try await svn.switchWorkingCopy(project: project, url: url, revision: revision)
            try await reloadStatus(project: project)
        }
    }

    public func merge(from url: URL, range: String?, dryRun: Bool, reverse: Bool) async {
        guard let project = selectedProject else { return }
        await withActivity(dryRun ? "Previewing merge…" : "Merging…") {
            activityMessage = try await svn.merge(project: project, source: url, revisionRange: range, dryRun: dryRun, reverse: reverse)
            if !dryRun { try await reloadStatus(project: project) }
        }
    }

    public func cancel(taskID: UUID) async { await svn.cancel(taskID: taskID) }

    public func exportDiagnostics(to destination: URL) async {
        do {
            let folder = try await diagnostics.export(
                to: destination,
                tasks: tasks,
                capabilities: capabilities,
                settings: ["language": Locale.current.identifier, "showIgnored": String(showIgnored)]
            )
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { present(error) }
    }

    public func revealSelectedProject() {
        guard let project = selectedProject else { return }
        NSWorkspace.shared.activateFileViewerSelecting([project.workingCopyRoot])
    }

    private func restoreScope(for project: ProjectRecord) {
        guard let data = project.workingCopyBookmark,
              let scope = try? SecurityScopedBookmark(data: data).resolve() else { return }
        projectScopes[project.id] = scope
    }

    private func loadDraft(for project: ProjectRecord) async {
        guard let draft = try? await storage?.loadDraft(projectID: project.id) else {
            commitMessage = ""
            selectedPaths = []
            return
        }
        commitMessage = draft.message
        selectedPaths = draft.selectedRelativePaths
    }

    private func absolute(_ paths: [String], project: ProjectRecord) -> [String] {
        paths.map { project.workingCopyRoot.appendingPathComponent($0).path }
    }

    private func registerWorkingCopy(url: URL, requireSelectedRoot: Bool) async throws {
        let temporaryScope = ResolvedSecurityScope(url: url)
        _ = temporaryScope
        let selectedBookmark = try SecurityScopedBookmark(url: url)
        let info = try await svn.info(path: url, securityScopedBookmark: selectedBookmark.data)
        let selected = url.standardizedFileURL
        let root = info.workingCopyRoot.standardizedFileURL
        if requireSelectedRoot && selected != root {
            throw SpoonError(
                title: "Select the working-copy root",
                explanation: "The selected folder is inside a working copy. Open \(root.path) so Spoon can retain sandbox access to the complete working copy."
            )
        }
        if projects.contains(where: { $0.workingCopyRoot.standardizedFileURL == root }) {
            throw SpoonError(title: "Working copy already added", explanation: root.path)
        }
        let bookmark = try SecurityScopedBookmark(url: root)
        let project = ProjectRecord(
            displayName: root.lastPathComponent,
            workingCopyRoot: root,
            workingCopyBookmark: bookmark.data,
            repositoryRootURL: info.repositoryRootURL,
            repositoryUUID: info.repositoryUUID,
            relativeURL: info.relativeURL
        )
        projects.append(project)
        projects.sort { ($0.isFavorite ? 0 : 1, $0.displayName.lowercased()) < ($1.isFavorite ? 0 : 1, $1.displayName.lowercased()) }
        selectedProjectID = project.id
        projectScopes[project.id] = try bookmark.resolve()
        repositoryURL = project.repositoryRootURL
        try await storage?.saveProject(project)
        workingCopyInfo = info
        workingCopyWatcher?.watch(root)
    }

    private func reloadStatus(project: ProjectRecord, remote: Bool = false) async throws {
        let refreshedInfo = try? await svn.info(
            path: project.workingCopyRoot,
            projectID: project.id,
            securityScopedBookmark: project.workingCopyBookmark
        )
        let refreshedItems = try await svn.status(project: project, remote: remote, showIgnored: showIgnored)
        guard selectedProjectID == project.id else { return }

        workingCopyInfo = refreshedInfo
        if remote {
            statusItems = refreshedItems
            lastRemoteStatusCheck = .now
        } else {
            statusItems = Self.preservingRemoteStatuses(from: statusItems, in: refreshedItems)
        }
        selectedPaths.formIntersection(Set(statusItems.filter(\.isCommitEligible).map(\.relativePath)))
        if let first = selectedPaths.first,
           let selectedItem = statusItems.first(where: { $0.relativePath == first }) {
            let propertyOnly = selectedItem.propertyStatus != .none
                && selectedItem.propertyStatus != .normal
                && (selectedItem.workingCopyStatus == .none || selectedItem.workingCopyStatus == .normal)
            if propertyOnly {
                await loadPropertyDiff(path: first)
            } else {
                await loadDiff(path: first)
            }
        }
    }

    private func reloadHistory(project: ProjectRecord) async throws {
        let refreshedRevisions = try await svn.history(
            project: project,
            limit: 200,
            search: historySearch.isEmpty ? nil : historySearch
        )
        guard selectedProjectID == project.id else { return }
        revisions = refreshedRevisions
        if selectedRevision == nil || !revisions.contains(where: { $0.revision == selectedRevision }) {
            selectedRevision = revisions.first?.revision
        }
    }

    private static func preservingRemoteStatuses(
        from previousItems: [StatusItem],
        in refreshedItems: [StatusItem]
    ) -> [StatusItem] {
        let previousRemoteItems = Dictionary(
            previousItems
                .filter { $0.remoteStatus != .none && $0.remoteStatus != .normal }
                .map { ($0.relativePath, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var mergedItems = refreshedItems.map { refreshedItem in
            var item = refreshedItem
            if let previous = previousRemoteItems[item.relativePath] {
                item.remoteStatus = previous.remoteStatus
            }
            return item
        }
        let refreshedPaths = Set(refreshedItems.map(\.relativePath))
        mergedItems.append(contentsOf: previousRemoteItems.values.filter {
            !refreshedPaths.contains($0.relativePath)
        })
        return mergedItems.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func workingCopyDidChange(checkRemote: Bool) {
        guard selectedProject != nil else { return }
        if isBusy || isAutomaticRefreshInProgress {
            pendingAutomaticRefresh = true
            pendingAutomaticRemoteRefresh = pendingAutomaticRemoteRefresh || checkRemote
        } else {
            Task { await refreshAutomatically(remote: checkRemote) }
        }
    }

    private func withActivity(_ message: String, operation: () async throws -> Void) async {
        isBusy = true
        activityMessage = message
        do { try await operation() } catch is CancellationError {
            activityMessage = "Cancelled"
            if selectedProject != nil { await refreshStatus() }
        } catch {
            present(error)
        }
        isBusy = false
        if pendingAutomaticRefresh {
            let checkRemote = pendingAutomaticRemoteRefresh
            pendingAutomaticRefresh = false
            pendingAutomaticRemoteRefresh = false
            Task { await refreshAutomatically(remote: checkRemote) }
        }
    }

    private func present(_ error: Error) {
        if let spoon = error as? SpoonError {
            self.error = PresentedError(title: spoon.title, message: spoon.explanation, details: spoon.diagnosticDetails)
        } else {
            self.error = PresentedError(title: "Operation failed", message: error.localizedDescription, details: nil)
        }
    }

    private static func authenticationResponse(
        for challenge: SVNAuthenticationChallenge
    ) async throws -> SVNAuthenticationResponse {
        switch challenge.kind {
        case .credentials:
            let account = "svn:\(challenge.host)"
            if !challenge.previousAttemptFailed,
               let stored = try await storedCredential(for: challenge.host) {
                return SVNAuthenticationResponse(username: stored.username, password: stored.password, saveInKeychain: true)
            }

            let result = await MainActor.run { () -> (String, String, Bool)? in
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = challenge.previousAttemptFailed ? "Authentication failed" : "Authentication Required"
                alert.informativeText = [challenge.host, challenge.realm].compactMap { $0 }.joined(separator: "\n")
                alert.addButton(withTitle: "Continue")
                alert.addButton(withTitle: "Cancel")

                let username = NSTextField(string: "")
                username.placeholderString = "Username"
                let password = NSSecureTextField(string: "")
                password.placeholderString = "Password"
                let remember = NSButton(checkboxWithTitle: "Save in Keychain", target: nil, action: nil)
                remember.state = .on
                let stack = NSStackView(views: [username, password, remember])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 8
                stack.setFrameSize(NSSize(width: 360, height: 86))
                username.widthAnchor.constraint(equalToConstant: 360).isActive = true
                password.widthAnchor.constraint(equalToConstant: 360).isActive = true
                alert.accessoryView = stack
                alert.window.initialFirstResponder = username
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                return (username.stringValue, password.stringValue, remember.state == .on)
            }
            guard let result else { throw CancellationError() }
            if result.2 {
                let encoded = try JSONEncoder().encode(StoredSVNCredential(username: result.0, password: result.1))
                try await KeychainStore.shared.save(encoded, account: account, label: "SVN credentials for \(challenge.host)")
            }
            return SVNAuthenticationResponse(username: result.0, password: result.1, saveInKeychain: result.2)

        case .serverTrust(let failures):
            let account = "svn-trust:\(challenge.host)"
            if !challenge.previousAttemptFailed,
               let data = try await KeychainStore.shared.load(account: account),
               let stored = try? JSONDecoder().decode(StoredSVNServerTrust.self, from: data),
               stored.acceptedServerFailures.isSuperset(of: failures) {
                return try await authenticationResponse(
                    trusting: stored.acceptedServerFailures,
                    host: challenge.host
                )
            }
            if challenge.previousAttemptFailed {
                try? await KeychainStore.shared.remove(account: account)
            }

            let decision = await MainActor.run { () -> ServerTrustDecision? in
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Server Certificate Is Not Trusted"
                alert.informativeText = "\(challenge.host)\n\n\(challenge.message)"
                alert.addButton(withTitle: "Trust Once")
                alert.addButton(withTitle: "Always Trust This Server")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn: return .once
                case .alertSecondButtonReturn: return .always
                default: return nil
                }
            }
            guard let decision else { throw CancellationError() }
            if decision == .always {
                let stored = StoredSVNServerTrust(acceptedServerFailures: failures)
                try await KeychainStore.shared.save(
                    try JSONEncoder().encode(stored),
                    account: account,
                    label: "SVN server trust for \(challenge.host)"
                )
            }
            return try await authenticationResponse(trusting: failures, host: challenge.host)
        }
    }

    private static func storedCredential(for host: String) async throws -> StoredSVNCredential? {
        guard let data = try await KeychainStore.shared.load(account: "svn:\(host)") else { return nil }
        return try? JSONDecoder().decode(StoredSVNCredential.self, from: data)
    }

    private static func authenticationResponse(
        trusting failures: Set<String>,
        host: String
    ) async throws -> SVNAuthenticationResponse {
        guard let credential = try await storedCredential(for: host) else {
            return SVNAuthenticationResponse(acceptedServerFailures: failures)
        }
        return SVNAuthenticationResponse(
            username: credential.username,
            password: credential.password,
            saveInKeychain: true,
            acceptedServerFailures: failures
        )
    }
}

private enum ServerTrustDecision {
    case once
    case always
}

private struct StoredSVNCredential: Codable, Sendable {
    var username: String
    var password: String
}

private struct StoredSVNServerTrust: Codable, Sendable {
    var acceptedServerFailures: Set<String>
}

public struct PresentedError: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var details: String?

    public init(title: String, message: String, details: String?) {
        self.title = title
        self.message = message
        self.details = details
    }
}
