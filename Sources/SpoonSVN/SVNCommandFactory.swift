import Foundation
import Darwin
import Security
import SpoonDomain
import SpoonSecurity

public struct SVNCommandFactory: Sendable {
    public var executable: URL
    public var configDirectory: URL

    public init(executable: URL = SVNExecutableLocator.bundledSVN(), configDirectory: URL? = nil) {
        self.executable = executable
        if let configDirectory {
            self.configDirectory = configDirectory
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.configDirectory = support.appendingPathComponent("Spoon/SVNConfig", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        configureSSH()
    }

    public func capabilityProbe() -> SVNCommandDescriptor<SVNCapabilitySet> {
        descriptor(arguments: ["--version"], operation: .capabilityProbe, operationClass: .repositoryRead) { stdout, _ in
            let text = String(decoding: stdout, as: UTF8.self)
            let version = text.firstMatch(#"svn, version ([0-9.]+)"#) ?? "unknown"
            var modules = Set<String>()
            for module in ["ra_svn", "ra_local", "ra_serf"] where text.contains(module) { modules.insert(module) }
            var providers = Set<String>()
            if text.localizedCaseInsensitiveContains("Keychain") { providers.insert("Keychain") }
            let inspection = Self.inspectToolchain(executable: executable)
            return SVNCapabilitySet(
                version: version,
                architecture: inspection.architecture,
                repositoryAccessModules: modules,
                credentialProviders: providers,
                supportsSearch: true,
                supportsShowItem: true,
                isBundled: inspection.isBundled,
                signatureValid: inspection.signatureValid,
                checksumsValid: inspection.checksumsValid,
                openSSHVersion: inspection.openSSHVersion
            )
        }
    }

    private static func inspectToolchain(executable: URL) -> (
        architecture: String,
        isBundled: Bool,
        signatureValid: Bool,
        checksumsValid: Bool,
        openSSHVersion: String?
    ) {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let isBundled = executable.deletingLastPathComponent().lastPathComponent == "Helpers"
            && FileManager.default.fileExists(atPath: contents.appendingPathComponent("Libraries").path)
        let architecture: String = {
            guard let data = try? Data(contentsOf: executable), data.count >= 8 else { return "unknown" }
            let cpuType = data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            }
            return cpuType == 0x0100000C ? "arm64" : "unsupported"
        }()
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(executable as CFURL, [], &code)
        let signatureValid = createStatus == errSecSuccess
            && code.map { SecStaticCodeCheckValidity($0, [], nil) == errSecSuccess } == true
        let manifest = contents.appendingPathComponent("Resources/ThirdPartyLicenses/Toolchain-Content-SHA256SUMS.txt")
        let checksumsValid = ToolchainIntegrity.verifyManifest(manifest, relativeTo: contents)
        let versions = contents.appendingPathComponent("Resources/ThirdPartyLicenses/Toolchain-VERSIONS.txt")
        let openSSHVersion = (try? String(contentsOf: versions, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains("OpenSSH_") })
        return (architecture, isBundled, signatureValid, checksumsValid, openSSHVersion)
    }

    public func info(path: URL) -> SVNCommandDescriptor<WorkingCopyInfo> {
        descriptor(
            arguments: ["info", "--xml", "--", path.path],
            workingDirectory: path,
            operation: .info,
            operationClass: .workingCopyRead,
            targets: [path.path]
        ) { stdout, _ in try SVNXMLParsers.info(stdout) }
    }

    public func status(root: URL, remote: Bool = false, showIgnored: Bool = false) -> SVNCommandDescriptor<[StatusItem]> {
        var arguments = ["status", "--xml", "--verbose"]
        if remote { arguments.append("--show-updates") }
        if showIgnored { arguments.append("--no-ignore") }
        arguments += ["--", root.path]
        return descriptor(
            arguments: arguments,
            workingDirectory: root,
            operation: .status,
            operationClass: .workingCopyRead,
            targets: [root.path]
        ) { stdout, _ in try SVNXMLParsers.status(stdout, workingCopyRoot: root) }
    }

    public func log(target: String, limit: Int = 100, search: String? = nil) -> SVNCommandDescriptor<[RevisionRecord]> {
        var arguments = ["log", "--xml", "--verbose", "--limit", String(max(1, limit))]
        if let search, !search.isEmpty { arguments += ["--search", search] }
        arguments += ["--", target]
        return descriptor(arguments: arguments, operation: .log, operationClass: .repositoryRead, targets: [target]) { stdout, _ in
            try SVNXMLParsers.log(stdout)
        }
    }

    public func list(url: URL, revision: String = "HEAD") -> SVNCommandDescriptor<[RepositoryEntry]> {
        descriptor(
            arguments: ["list", "--xml", "-r", revision, "--", url.absoluteString],
            operation: .list,
            operationClass: .repositoryRead,
            targets: [url.absoluteString]
        ) { stdout, _ in try SVNXMLParsers.list(stdout, baseURL: url) }
    }

    public func blame(target: String, revision: String? = nil) -> SVNCommandDescriptor<[BlameLine]> {
        var arguments = ["blame", "--xml"]
        if let revision { arguments += ["-r", revision] }
        arguments += ["--", target]
        return descriptor(arguments: arguments, operation: .blame, operationClass: .repositoryRead, targets: [target]) { stdout, _ in
            try SVNXMLParsers.blame(stdout)
        }
    }

    public func diff(
        targets: [String],
        revision: String? = nil,
        change: Int? = nil,
        contextLines: Int? = nil
    ) -> SVNCommandDescriptor<String> {
        var arguments = ["diff"]
        if let revision { arguments += ["-r", revision] }
        if let change { arguments += ["--change", String(change)] }
        if let contextLines { arguments += ["-x", "-U \(max(0, contextLines))"] }
        arguments.append("--")
        arguments += targets
        return descriptor(arguments: arguments, operation: .diff, operationClass: .workingCopyRead, targets: targets) { stdout, _ in
            String(decoding: stdout, as: UTF8.self)
        }
    }

    public func cat(target: String, revision: String = "HEAD") -> SVNCommandDescriptor<Data> {
        descriptor(
            arguments: ["cat", "-r", revision, "--", target],
            operation: .cat,
            operationClass: .repositoryRead,
            targets: [target]
        ) { stdout, _ in stdout }
    }

    public func properties(target: String, revision: String? = nil) -> SVNCommandDescriptor<[SVNPropertyRecord]> {
        var arguments = ["proplist", "--xml", "--verbose"]
        if let revision { arguments += ["-r", revision] }
        arguments += ["--", target]
        return descriptor(arguments: arguments, operation: .proplist, operationClass: .workingCopyRead, targets: [target]) { stdout, _ in
            try SVNXMLParsers.properties(stdout)
        }
    }

    public func checkout(url: URL, destination: URL, revision: String = "HEAD", depth: String = "infinity", ignoreExternals: Bool = false) -> SVNCommandDescriptor<String> {
        var arguments = ["checkout", "-r", revision, "--depth", depth]
        if ignoreExternals { arguments.append("--ignore-externals") }
        arguments += ["--", url.absoluteString, destination.path]
        return textDescriptor(arguments: arguments, operation: .checkout, operationClass: .workingCopyWrite, targets: [url.absoluteString, destination.path])
    }

    public func update(targets: [String], revision: String = "HEAD", includeExternals: Bool = true) -> SVNCommandDescriptor<String> {
        var arguments = ["update", "-r", revision, "--accept", "postpone"]
        if !includeExternals { arguments.append("--ignore-externals") }
        arguments.append("--")
        arguments += targets
        return textDescriptor(arguments: arguments, operation: .update, operationClass: .workingCopyWrite, targets: targets)
    }

    public func commit(targets: [String], message: String) throws -> SVNCommandDescriptor<Int?> {
        let messageFile = try SecureTemporaryFile(text: message, prefix: "commit-message")
        let targetsFile = try SecureTemporaryFile(text: targets.joined(separator: "\n") + "\n", prefix: "commit-targets")
        return descriptor(
            arguments: ["commit", "--depth", "empty", "--file", messageFile.url.path, "--targets", targetsFile.url.path],
            operation: .commit,
            operationClass: .workingCopyWrite,
            targets: targets,
            retainedResources: [messageFile, targetsFile]
        ) { stdout, _ in
            let text = String(decoding: stdout, as: UTF8.self)
            return text.firstMatch(#"Committed revision (\d+)\."#).flatMap(Int.init)
        }
    }

    public func add(targets: [String], depth: String = "infinity") -> SVNCommandDescriptor<String> {
        pathCommand(.add, arguments: ["add", "--depth", depth], targets: targets)
    }

    public func delete(targets: [String], keepLocal: Bool = false) -> SVNCommandDescriptor<String> {
        var arguments = ["delete"]
        if keepLocal { arguments.append("--keep-local") }
        return pathCommand(.delete, arguments: arguments, targets: targets)
    }

    public func move(source: String, destination: String) -> SVNCommandDescriptor<String> {
        textDescriptor(arguments: ["move", "--", source, destination], operation: .move, operationClass: .workingCopyWrite, targets: [source, destination])
    }

    public func revert(targets: [String], depth: String = "empty") -> SVNCommandDescriptor<String> {
        pathCommand(.revert, arguments: ["revert", "--depth", depth], targets: targets)
    }

    public func cleanup(root: URL, removeUnversioned: Bool = false, removeIgnored: Bool = false) -> SVNCommandDescriptor<String> {
        var arguments = ["cleanup"]
        if removeUnversioned { arguments.append("--remove-unversioned") }
        if removeIgnored { arguments.append("--remove-ignored") }
        arguments += ["--", root.path]
        return textDescriptor(arguments: arguments, operation: .cleanup, operationClass: .workingCopyWrite, targets: [root.path])
    }

    public func resolve(targets: [String], choice: ConflictResolution) -> SVNCommandDescriptor<String> {
        pathCommand(.resolve, arguments: ["resolve", "--accept", choice.rawValue], targets: targets)
    }

    public func lock(targets: [String], message: String? = nil, force: Bool = false) throws -> SVNCommandDescriptor<String> {
        var arguments = ["lock"]
        var resources: [SecureTemporaryFile] = []
        if let message {
            let file = try SecureTemporaryFile(text: message, prefix: "lock-message")
            arguments += ["--file", file.url.path]
            resources.append(file)
        }
        if force { arguments.append("--force") }
        arguments.append("--")
        arguments += targets
        return textDescriptor(arguments: arguments, operation: .lock, operationClass: .workingCopyWrite, targets: targets, resources: resources)
    }

    public func unlock(targets: [String], force: Bool = false) -> SVNCommandDescriptor<String> {
        var arguments = ["unlock"]
        if force { arguments.append("--force") }
        return pathCommand(.unlock, arguments: arguments, targets: targets)
    }

    public func changelist(name: String?, targets: [String]) -> SVNCommandDescriptor<String> {
        var arguments = ["changelist"]
        if let name { arguments.append(name) } else { arguments.append("--remove") }
        return pathCommand(.changelist, arguments: arguments, targets: targets)
    }

    public func propertySet(name: String, value: Data, targets: [String]) throws -> SVNCommandDescriptor<String> {
        let valueFile = try SecureTemporaryFile(data: value, prefix: "property-value")
        var arguments = ["propset", name, "--file", valueFile.url.path, "--"]
        arguments += targets
        return textDescriptor(arguments: arguments, operation: .propset, operationClass: .workingCopyWrite, targets: targets, resources: [valueFile])
    }

    public func propertyDelete(name: String, targets: [String]) -> SVNCommandDescriptor<String> {
        pathCommand(.propdel, arguments: ["propdel", name], targets: targets)
    }

    public func repositoryCopy(source: URL, destination: URL, message: String, revision: String? = nil) throws -> SVNCommandDescriptor<Int?> {
        let messageFile = try SecureTemporaryFile(text: message, prefix: "copy-message")
        var arguments = ["copy"]
        if let revision { arguments += ["-r", revision] }
        arguments += [source.absoluteString, destination.absoluteString, "--file", messageFile.url.path]
        return revisionCreatingDescriptor(arguments: arguments, operation: .copy, targets: [source.absoluteString, destination.absoluteString], resource: messageFile)
    }

    public func repositoryMkdir(url: URL, message: String) throws -> SVNCommandDescriptor<Int?> {
        let messageFile = try SecureTemporaryFile(text: message, prefix: "mkdir-message")
        return revisionCreatingDescriptor(arguments: ["mkdir", url.absoluteString, "--file", messageFile.url.path], operation: .mkdir, targets: [url.absoluteString], resource: messageFile)
    }

    public func repositoryDelete(url: URL, message: String) throws -> SVNCommandDescriptor<Int?> {
        let messageFile = try SecureTemporaryFile(text: message, prefix: "delete-message")
        return revisionCreatingDescriptor(arguments: ["delete", url.absoluteString, "--file", messageFile.url.path], operation: .delete, targets: [url.absoluteString], resource: messageFile)
    }

    public func repositoryMove(source: URL, destination: URL, message: String) throws -> SVNCommandDescriptor<Int?> {
        let messageFile = try SecureTemporaryFile(text: message, prefix: "move-message")
        return revisionCreatingDescriptor(arguments: ["move", source.absoluteString, destination.absoluteString, "--file", messageFile.url.path], operation: .move, targets: [source.absoluteString, destination.absoluteString], resource: messageFile)
    }

    public func switchWorkingCopy(url: URL, path: URL, revision: String = "HEAD") -> SVNCommandDescriptor<String> {
        textDescriptor(arguments: ["switch", "-r", revision, "--accept", "postpone", "--", url.absoluteString, path.path], operation: .switchWorkingCopy, operationClass: .workingCopyWrite, targets: [url.absoluteString, path.path])
    }

    public func merge(source: URL, target: URL, revisionRange: String? = nil, dryRun: Bool = false, reverse: Bool = false) -> SVNCommandDescriptor<String> {
        var arguments = ["merge"]
        if dryRun { arguments.append("--dry-run") }
        if let revisionRange {
            let range = reverse ? Self.reversedRange(revisionRange) : revisionRange
            arguments += ["-r", range]
        }
        arguments += ["--accept", "postpone", source.absoluteString, target.path]
        return textDescriptor(arguments: arguments, operation: .merge, operationClass: .workingCopyWrite, targets: [source.absoluteString, target.path])
    }

    private func pathCommand(_ operation: SVNOperation, arguments: [String], targets: [String]) -> SVNCommandDescriptor<String> {
        var arguments = arguments
        arguments.append("--")
        arguments += targets
        return textDescriptor(arguments: arguments, operation: operation, operationClass: .workingCopyWrite, targets: targets)
    }

    private func textDescriptor(
        arguments: [String],
        operation: SVNOperation,
        operationClass: SVNOperationClass,
        targets: [String],
        resources: [SecureTemporaryFile] = []
    ) -> SVNCommandDescriptor<String> {
        descriptor(arguments: arguments, operation: operation, operationClass: operationClass, targets: targets, retainedResources: resources) { stdout, _ in
            String(decoding: stdout, as: UTF8.self)
        }
    }

    private func revisionCreatingDescriptor(
        arguments: [String],
        operation: SVNOperation,
        targets: [String],
        resource: SecureTemporaryFile
    ) -> SVNCommandDescriptor<Int?> {
        descriptor(arguments: arguments, operation: operation, operationClass: .repositoryWrite, targets: targets, retainedResources: [resource]) { stdout, _ in
            String(decoding: stdout, as: UTF8.self).firstMatch(#"Committed revision (\d+)\."#).flatMap(Int.init)
        }
    }

    private func descriptor<Output: Sendable>(
        arguments: [String],
        workingDirectory: URL? = nil,
        operation: SVNOperation,
        operationClass: SVNOperationClass,
        targets: [String] = [],
        retainedResources: [SecureTemporaryFile] = [],
        parser: @escaping @Sendable (Data, Data) throws -> Output
    ) -> SVNCommandDescriptor<Output> {
        var completeArguments = arguments
        if operation != .capabilityProbe {
            completeArguments.insert(contentsOf: ["--config-dir", configDirectory.path, "--non-interactive"], at: min(1, completeArguments.count))
        }
        var environment = SVNCommandDescriptor<Output>.stableEnvironment
        let bundledSSH = executable.deletingLastPathComponent().appendingPathComponent("ssh")
        if FileManager.default.isExecutableFile(atPath: bundledSSH.path) {
            let sshConfig = configDirectory.appendingPathComponent("ssh/config").path
            environment["SVN_SSH"] = "\"\(bundledSSH.path)\" -F \"\(sshConfig)\""
        }
        return SVNCommandDescriptor(
            executable: executable,
            arguments: completeArguments,
            workingDirectory: workingDirectory,
            environment: environment,
            operation: operation,
            operationClass: operationClass,
            targets: targets,
            retainedResources: retainedResources,
            parser: parser
        )
    }

    private func configureSSH() {
        let sshDirectory = configDirectory.appendingPathComponent("ssh", isDirectory: true)
        let knownHosts = sshDirectory.appendingPathComponent("known_hosts")
        let config = sshDirectory.appendingPathComponent("config")
        try? FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: knownHosts.path) {
            FileManager.default.createFile(atPath: knownHosts.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        if !FileManager.default.fileExists(atPath: config.path) {
            let contents = """
            Host *
                UserKnownHostsFile \(knownHosts.path)
                GlobalKnownHostsFile /dev/null
                StrictHostKeyChecking yes
                HashKnownHosts yes
                IdentitiesOnly yes
            """
            FileManager.default.createFile(atPath: config.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600])
        }
    }

    private static func reversedRange(_ range: String) -> String {
        let components = range.split(separator: ":", maxSplits: 1).map(String.init)
        return components.count == 2 ? "\(components[1]):\(components[0])" : range
    }
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..<endIndex, in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}

private extension ProcessInfo {
    var machineArchitecture: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
