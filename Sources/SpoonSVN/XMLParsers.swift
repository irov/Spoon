import Foundation
import SpoonDomain

public enum SVNXMLParsers {
    public static func info(_ data: Data) throws -> WorkingCopyInfo {
        let delegate = InfoParserDelegate()
        try parse(data, delegate: delegate)
        guard let info = delegate.info else { throw SVNParseError("svn info XML did not contain a complete entry") }
        return info
    }

    public static func status(_ data: Data, workingCopyRoot: URL) throws -> [StatusItem] {
        let delegate = StatusParserDelegate(root: workingCopyRoot)
        try parse(data, delegate: delegate)
        return delegate.items
    }

    public static func log(_ data: Data) throws -> [RevisionRecord] {
        let delegate = LogParserDelegate()
        try parse(data, delegate: delegate)
        return delegate.revisions
    }

    public static func list(_ data: Data, baseURL: URL) throws -> [RepositoryEntry] {
        let delegate = ListParserDelegate(baseURL: baseURL)
        try parse(data, delegate: delegate)
        return delegate.entries
    }

    public static func blame(_ data: Data) throws -> [BlameLine] {
        let delegate = BlameParserDelegate()
        try parse(data, delegate: delegate)
        return delegate.lines
    }

    public static func properties(_ data: Data) throws -> [SVNPropertyRecord] {
        let delegate = PropertyParserDelegate()
        try parse(data, delegate: delegate)
        return delegate.properties
    }

    private static func parse(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw SVNParseError(parser.parserError?.localizedDescription ?? "Malformed SVN XML")
        }
    }
}

private final class PropertyParserDelegate: NSObject, XMLParserDelegate {
    var properties: [SVNPropertyRecord] = []
    private var propertyName: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "property" {
            propertyName = attributeDict["name"]
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if propertyName != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "property", let propertyName {
            properties.append(SVNPropertyRecord(name: propertyName, value: text))
            self.propertyName = nil
            text = ""
        }
    }
}

private final class InfoParserDelegate: NSObject, XMLParserDelegate {
    var info: WorkingCopyInfo?
    private var entryAttributes: [String: String] = [:]
    private var values: [String: String] = [:]
    private var stack: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(elementName)
        text = ""
        if elementName == "entry" { entryAttributes = attributeDict }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let path = stack.joined(separator: "/")
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { values[path] = value }
        if elementName == "entry" { buildInfo() }
        _ = stack.popLast()
        text = ""
    }

    private func buildInfo() {
        guard let rawPath = entryAttributes["path"],
              let revision = Int(entryAttributes["revision"] ?? ""),
              let urlString = values["info/entry/url"],
              let url = URL(string: urlString),
              let rootString = values["info/entry/repository/root"],
              let repositoryRoot = URL(string: rootString),
              let uuid = values["info/entry/repository/uuid"],
              let wcRoot = values["info/entry/wc-info/wcroot-abspath"] else { return }
        info = WorkingCopyInfo(
            path: URL(fileURLWithPath: rawPath),
            workingCopyRoot: URL(fileURLWithPath: wcRoot),
            url: url,
            repositoryRootURL: repositoryRoot,
            repositoryUUID: uuid,
            relativeURL: values["info/entry/relative-url"],
            revision: revision,
            nodeKind: NodeKind(rawValue: entryAttributes["kind"] ?? "") ?? .unknown
        )
    }
}

private final class StatusParserDelegate: NSObject, XMLParserDelegate {
    let root: URL
    var items: [StatusItem] = []
    private var entryPath: String?
    private var wcAttributes: [String: String] = [:]
    private var remoteAttributes: [String: String] = [:]
    private var targetPath: String?
    private var changelist: String?
    private var inEntry = false
    private var inLock = false
    private var lockValues: [String: String] = [:]
    private var text = ""

    init(root: URL) { self.root = root.standardizedFileURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "target": targetPath = attributeDict["path"]
        case "changelist": changelist = attributeDict["name"]
        case "entry":
            inEntry = true
            entryPath = attributeDict["path"]
            wcAttributes = [:]
            remoteAttributes = [:]
            lockValues = [:]
        case "wc-status" where inEntry: wcAttributes = attributeDict
        case "repos-status" where inEntry: remoteAttributes = attributeDict
        case "lock" where inEntry:
            inLock = true
            lockValues = [:]
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLock { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "entry" {
            appendEntry()
            inEntry = false
        } else if elementName == "changelist" {
            changelist = nil
        } else if elementName == "lock" {
            inLock = false
        } else if inLock {
            lockValues[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ""
    }

    private func appendEntry() {
        guard let entryPath else { return }
        let absolute: URL
        if entryPath.hasPrefix("/") {
            absolute = URL(fileURLWithPath: entryPath).standardizedFileURL
        } else if let targetPath, targetPath.hasPrefix("/") {
            let target = URL(fileURLWithPath: targetPath)
            absolute = (target.hasDirectoryPath ? target : target.deletingLastPathComponent())
                .appendingPathComponent(entryPath).standardizedFileURL
        } else {
            absolute = root.appendingPathComponent(entryPath).standardizedFileURL
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let relative = absolute.path == root.path ? "." : absolute.path.replacingOccurrences(of: rootPath, with: "", options: [.anchored])
        let itemStatus = WorkingCopyStatus(svnValue: wcAttributes["item"] ?? "unknown")
        let propertyStatus = WorkingCopyStatus(svnValue: wcAttributes["props"] ?? "none")
        let remoteItemStatus = RemoteStatus(svnValue: remoteAttributes["item"])
        let remotePropertyStatus = RemoteStatus(svnValue: remoteAttributes["props"])
        let remoteStatus = if remoteItemStatus == .none || remoteItemStatus == .normal {
            remotePropertyStatus
        } else {
            remoteItemStatus
        }
        let resourceValues = try? absolute.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let nodeKind: NodeKind = if resourceValues?.isSymbolicLink == true {
            .symbolicLink
        } else if resourceValues?.isDirectory == true {
            .directory
        } else {
            .file
        }
        let lock = lockValues.isEmpty ? nil : LockRecord(
            token: lockValues["token"],
            owner: lockValues["owner"],
            comment: lockValues["comment"],
            createdAt: lockValues["created"].flatMap(SVNDateParser.date)
        )
        guard itemStatus != .normal && itemStatus != .none
            || propertyStatus != .normal && propertyStatus != .none
            || remoteStatus != .normal && remoteStatus != .none
            || lock != nil else { return }
        items.append(StatusItem(
            relativePath: relative,
            absolutePath: absolute,
            nodeKind: nodeKind,
            workingCopyStatus: itemStatus,
            propertyStatus: propertyStatus,
            remoteStatus: remoteStatus,
            revision: Int(wcAttributes["revision"] ?? ""),
            copied: Self.bool(wcAttributes["copied"]),
            switched: Self.bool(wcAttributes["switched"]),
            locked: Self.bool(wcAttributes["wc-locked"]) || lock != nil,
            treeConflicted: Self.bool(wcAttributes["tree-conflicted"]),
            changelist: changelist,
            lock: lock
        ))
    }

    private static func bool(_ value: String?) -> Bool { value == "true" || value == "yes" }
}

private final class LogParserDelegate: NSObject, XMLParserDelegate {
    var revisions: [RevisionRecord] = []
    private var currentRevision: Int?
    private var author: String?
    private var date: Date?
    private var message = ""
    private var changedPaths: [ChangedPath] = []
    private var currentPathAttributes: [String: String]?
    private var currentElement = ""
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        text = ""
        if elementName == "logentry" {
            currentRevision = Int(attributeDict["revision"] ?? "")
            author = nil
            date = nil
            message = ""
            changedPaths = []
        } else if elementName == "path" {
            currentPathAttributes = attributeDict
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: elementName == "msg" ? .newlines : .whitespacesAndNewlines)
        switch elementName {
        case "author": author = value
        case "date": date = SVNDateParser.date(value)
        case "msg": message = value
        case "path":
            let attributes = currentPathAttributes ?? [:]
            changedPaths.append(ChangedPath(
                path: value,
                action: ChangedPathAction(rawValue: attributes["action"] ?? "?") ?? .unknown,
                nodeKind: NodeKind(rawValue: attributes["kind"] ?? "") ?? .unknown,
                copyFromPath: attributes["copyfrom-path"],
                copyFromRevision: Int(attributes["copyfrom-rev"] ?? "")
            ))
            currentPathAttributes = nil
        case "logentry":
            if let currentRevision {
                revisions.append(RevisionRecord(revision: currentRevision, author: author, timestampUTC: date, message: message, changedPaths: changedPaths))
            }
        default: break
        }
        currentElement = ""
        text = ""
    }
}

private final class ListParserDelegate: NSObject, XMLParserDelegate {
    let baseURL: URL
    var entries: [RepositoryEntry] = []
    private var attributes: [String: String] = [:]
    private var values: [String: String] = [:]
    private var stack: [String] = []
    private var text = ""

    init(baseURL: URL) { self.baseURL = baseURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        stack.append(elementName)
        text = ""
        if elementName == "entry" { attributes = attributeDict; values = [:] }
        if elementName == "commit", let revision = attributeDict["revision"] { values["revision"] = revision }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { values[elementName] = value }
        if elementName == "entry", let name = values["name"] {
            entries.append(RepositoryEntry(
                name: name,
                url: baseURL.appendingPathComponent(name),
                kind: NodeKind(rawValue: attributes["kind"] ?? "") ?? .unknown,
                size: Int64(values["size"] ?? ""),
                revision: Int(values["revision"] ?? ""),
                author: values["author"],
                committedAt: values["date"].flatMap(SVNDateParser.date)
            ))
        }
        _ = stack.popLast()
        text = ""
    }
}

private final class BlameParserDelegate: NSObject, XMLParserDelegate {
    var lines: [BlameLine] = []
    private var lineNumber: Int?
    private var revision: Int?
    private var author: String?
    private var date: Date?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "entry" { lineNumber = Int(attributeDict["line-number"] ?? "") }
        if elementName == "commit" { revision = Int(attributeDict["revision"] ?? "") }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "author" { author = value }
        if elementName == "date" { date = SVNDateParser.date(value) }
        if elementName == "entry", let lineNumber {
            lines.append(BlameLine(lineNumber: lineNumber, revision: revision, author: author, timestampUTC: date))
            revision = nil
            author = nil
            date = nil
        }
        text = ""
    }
}

private enum SVNDateParser {
    static func date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: string) { return value }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

public struct SVNParseError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
