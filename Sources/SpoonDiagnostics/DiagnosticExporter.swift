import Foundation
import SpoonDomain
import SpoonSecurity

public struct DiagnosticManifest: Codable, Sendable {
    public var spoonVersion: String
    public var build: String
    public var macOSVersion: String
    public var architecture: String
    public var svnCapabilities: SVNCapabilitySet?
    public var exportedAt: Date
    public var taskCount: Int

    public init(
        spoonVersion: String,
        build: String,
        macOSVersion: String,
        architecture: String,
        svnCapabilities: SVNCapabilitySet?,
        exportedAt: Date = .now,
        taskCount: Int
    ) {
        self.spoonVersion = spoonVersion
        self.build = build
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.svnCapabilities = svnCapabilities
        self.exportedAt = exportedAt
        self.taskCount = taskCount
    }
}

public actor DiagnosticExporter {
    public init() {}

    public func export(
        to destination: URL,
        tasks: [TaskRecord],
        capabilities: SVNCapabilitySet?,
        settings: [String: String] = [:]
    ) throws -> URL {
        let folder = destination.appendingPathComponent("Spoon-Diagnostics-\(Self.timestamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let info = ProcessInfo.processInfo
        let manifest = DiagnosticManifest(
            spoonVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            macOSVersion: info.operatingSystemVersionString,
            architecture: Self.architecture(),
            svnCapabilities: capabilities,
            taskCount: tasks.count
        )

        try Self.writeJSON(manifest, to: folder.appendingPathComponent("manifest.json"))
        let safeTasks = tasks.map { task -> TaskRecord in
            var task = task
            task.targets = task.targets.map(Self.redactPath)
            task.sanitizedCommand = Redactor.text(task.sanitizedCommand)
            task.summary = task.summary.map(Redactor.text)
            task.logReference = nil
            return task
        }
        try Self.writeJSON(safeTasks, to: folder.appendingPathComponent("tasks.json"))
        try Self.writeJSON(settings.mapValues(Redactor.text), to: folder.appendingPathComponent("settings.json"))

        let privacy = """
        Spoon diagnostics are created locally and are never uploaded automatically.
        Review every file before sharing this directory. Repository paths are reduced
        to their final component and known credential patterns are redacted.
        """
        try Data(privacy.utf8).write(to: folder.appendingPathComponent("PRIVACY.txt"), options: .atomic)
        return folder
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private static func redactPath(_ input: String) -> String {
        if input.contains("://") { return Redactor.text(input) }
        let component = URL(fileURLWithPath: input).lastPathComponent
        return component.isEmpty ? "<path>" : "…/\(component)"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
