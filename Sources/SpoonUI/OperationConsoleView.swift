import SpoonDomain
import SwiftUI

struct OperationConsoleView: View {
    @Bindable var model: AppModel
    let onOpenTaskCenter: () -> Void
    let onClose: () -> Void
    @State private var selectedTaskID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            consoleHeader
            Divider()

            if visibleTasks.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "terminal",
                    description: Text("SVN commands and their live output will appear here.")
                )
            } else {
                HSplitView {
                    taskList
                        .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
                    taskDetail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: repairSelection)
        .onChange(of: visibleTaskIDs) { _, _ in repairSelection() }
    }

    private var consoleHeader: some View {
        HStack(spacing: 8) {
            Label("Activity", systemImage: "terminal")
                .font(.headline)

            if runningTaskCount > 0 {
                Text("\(runningTaskCount) running")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.isBusy, !model.activityMessage.isEmpty {
                Divider().frame(height: 16)
                Text(model.activityMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let task = selectedTask, task.state == .running {
                Button("Cancel") {
                    Task { await model.cancel(taskID: task.id) }
                }
                .controlSize(.small)
            }

            Button(action: onOpenTaskCenter) {
                Label("Task History", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Open Task History")

            Button(action: onClose) {
                Label("Close Console", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Close Console")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
    }

    private var taskList: some View {
        List(visibleTasks, selection: $selectedTaskID) { task in
            HStack(spacing: 8) {
                TaskStateIndicator(state: task.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.operation.displayTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(task.createdAt, style: .time)
                        if let duration = task.renderedDuration {
                            Text("·")
                            Text(duration)
                        }
                    }
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .tag(task.id)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var taskDetail: some View {
        if let task = selectedTask {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(task.operation.displayTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(task.state.displayTitle)
                        .font(.caption)
                        .foregroundStyle(task.state.tint)
                    Spacer()
                    if let exitCode = task.exitCode {
                        Text("Exit \(exitCode)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)

                Divider()
                TaskTranscriptView(task: task)
            }
        } else {
            ContentUnavailableView("Select an Operation", systemImage: "terminal")
        }
    }

    private var visibleTasks: [TaskRecord] {
        let selectedProjectID = model.selectedProjectID
        return model.tasks
            .filter { task in
                task.projectID == nil || task.projectID == selectedProjectID
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var visibleTaskIDs: [UUID] {
        visibleTasks.map(\.id)
    }

    private var selectedTask: TaskRecord? {
        if let selectedTaskID,
           let selected = visibleTasks.first(where: { $0.id == selectedTaskID }) {
            return selected
        }
        return visibleTasks.first(where: { $0.state == .running }) ?? visibleTasks.first
    }

    private var runningTaskCount: Int {
        visibleTasks.count { $0.state == .running || $0.state == .queued }
    }

    private func repairSelection() {
        guard !visibleTaskIDs.isEmpty else {
            selectedTaskID = nil
            return
        }
        if let selectedTaskID, visibleTaskIDs.contains(selectedTaskID) { return }
        selectedTaskID = visibleTasks.first(where: { $0.state == .running })?.id ?? visibleTaskIDs.first
    }
}

private struct TaskTranscriptView: View {
    let task: TaskRecord

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if transcript.isEmpty {
                        transcriptLine(
                            SVNTaskOutputLine(kind: .command, text: "$ \(task.sanitizedCommand)")
                        )
                        if let summary = task.summary, !summary.isEmpty {
                            transcriptLine(
                                SVNTaskOutputLine(kind: .system, text: summary)
                            )
                        }
                    } else {
                        ForEach(transcript) { line in
                            transcriptLine(line)
                                .id(line.id)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { scrollToBottom(using: proxy) }
            .onChange(of: task.id) { _, _ in scrollToBottom(using: proxy) }
            .onChange(of: lastLineID) { _, _ in scrollToBottom(using: proxy) }
        }
    }

    private var transcript: [SVNTaskOutputLine] {
        task.outputLines ?? []
    }

    private var lastLineID: UUID? {
        transcript.last?.id
    }

    private func transcriptLine(_ line: SVNTaskOutputLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.timestamp, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
            Text(line.kind.prefix)
                .foregroundStyle(line.kind.tint)
                .frame(width: 12, alignment: .center)
            Text(line.text)
                .foregroundStyle(line.kind.textTint)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .textSelection(.enabled)
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        guard let lastLineID else { return }
        Task { @MainActor in
            proxy.scrollTo(lastLineID, anchor: .bottom)
        }
    }
}

private struct TaskStateIndicator: View {
    let state: SVNTaskState

    var body: some View {
        switch state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

private extension TaskRecord {
    var renderedDuration: String? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? .now
        let seconds = max(0, Int(end.timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private extension SVNOperation {
    var displayTitle: String {
        switch self {
        case .capabilityProbe: "Checking SVN"
        case .info: "Reading Working Copy"
        case .status: "Checking Status"
        case .checkout: "Checkout"
        case .update: "Update"
        case .commit: "Commit"
        case .add: "Add"
        case .delete: "Delete"
        case .move: "Move"
        case .revert: "Revert"
        case .cleanup: "Cleanup"
        case .resolve: "Resolve"
        case .log: "Loading History"
        case .diff: "Loading Diff"
        case .list: "Browsing Repository"
        case .cat: "Reading File"
        case .export: "Export"
        case .blame: "Blame"
        case .proplist: "Reading Properties"
        case .propget: "Reading Property"
        case .propset: "Setting Property"
        case .propdel: "Deleting Property"
        case .changelist: "Changelist"
        case .lock: "Lock"
        case .unlock: "Unlock"
        case .copy: "Copy"
        case .mkdir: "Create Directory"
        case .switchWorkingCopy: "Switch Working Copy"
        case .merge: "Merge"
        }
    }
}

private extension SVNTaskState {
    var displayTitle: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var tint: Color {
        switch self {
        case .queued, .cancelled: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }
}

private extension SVNTaskOutputKind {
    var prefix: String {
        switch self {
        case .command: "$"
        case .standardOutput: "›"
        case .standardError: "!"
        case .warning: "⚠"
        case .progress: "·"
        case .authentication: "🔒"
        case .system: "•"
        }
    }

    var tint: Color {
        switch self {
        case .command, .progress: .accentColor
        case .standardOutput, .system: .secondary
        case .standardError: .red
        case .warning, .authentication: .orange
        }
    }

    var textTint: Color {
        switch self {
        case .standardError: .red
        case .warning, .authentication: .orange
        case .system: .secondary
        default: .primary
        }
    }
}
