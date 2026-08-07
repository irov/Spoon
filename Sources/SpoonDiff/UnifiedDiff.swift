import Foundation

public struct UnifiedDiff: Hashable, Sendable {
    public var files: [DiffFile]
    public init(files: [DiffFile]) { self.files = files }
}

public struct DiffFile: Hashable, Identifiable, Sendable {
    public var id: String { "\(oldPath)->\(newPath)" }
    public var oldPath: String
    public var newPath: String
    public var hunks: [DiffHunk]
    public var propertyChanges: [String]

    public init(oldPath: String, newPath: String, hunks: [DiffHunk] = [], propertyChanges: [String] = []) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
        self.propertyChanges = propertyChanges
    }
}

public struct DiffHunk: Hashable, Identifiable, Sendable {
    public var id: String { header }
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine] = []) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct DiffLine: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: DiffLineKind
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    public var content: String

    public init(id: UUID = UUID(), kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, content: String) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.content = content
    }
}

public enum DiffLineKind: String, Hashable, Sendable {
    case context
    case addition
    case deletion
    case metadata
}

public enum UnifiedDiffParser {
    public static func parse(_ text: String) -> UnifiedDiff {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var files: [DiffFile] = []
        var currentFile: DiffFile?
        var currentHunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            guard let hunk = currentHunk else { return }
            if currentFile == nil { currentFile = DiffFile(oldPath: "", newPath: "") }
            currentFile?.hunks.append(hunk)
            currentHunk = nil
        }

        func flushFile() {
            flushHunk()
            if let file = currentFile { files.append(file) }
            currentFile = nil
        }

        for line in lines {
            if line.hasPrefix("Index: ") {
                flushFile()
                let path = String(line.dropFirst("Index: ".count))
                currentFile = DiffFile(oldPath: path, newPath: path)
            } else if !line.isEmpty, line.allSatisfy({ $0 == "=" }) {
                continue
            } else if line.hasPrefix("--- ") {
                if currentFile == nil { currentFile = DiffFile(oldPath: "", newPath: "") }
                currentFile?.oldPath = Self.path(from: line)
            } else if line.hasPrefix("+++ ") {
                currentFile?.newPath = Self.path(from: line)
            } else if line.hasPrefix("@@"), let range = Self.hunkRange(line) {
                flushHunk()
                oldLine = range.oldStart
                newLine = range.newStart
                currentHunk = DiffHunk(
                    header: line,
                    oldStart: range.oldStart,
                    oldCount: range.oldCount,
                    newStart: range.newStart,
                    newCount: range.newCount
                )
            } else if line.hasPrefix("Property changes on: ") {
                flushHunk()
                if currentFile == nil { currentFile = DiffFile(oldPath: "", newPath: "") }
                currentFile?.propertyChanges.append(line)
            } else if currentHunk != nil {
                if line.isEmpty {
                    continue
                } else if line.hasPrefix("+") {
                    currentHunk?.lines.append(DiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: newLine, content: String(line.dropFirst())))
                    newLine += 1
                } else if line.hasPrefix("-") {
                    currentHunk?.lines.append(DiffLine(kind: .deletion, oldLineNumber: oldLine, newLineNumber: nil, content: String(line.dropFirst())))
                    oldLine += 1
                } else if line.hasPrefix(" ") {
                    currentHunk?.lines.append(DiffLine(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, content: String(line.dropFirst())))
                    oldLine += 1
                    newLine += 1
                } else {
                    currentHunk?.lines.append(DiffLine(kind: .metadata, oldLineNumber: nil, newLineNumber: nil, content: line))
                }
            } else if currentFile != nil, !line.isEmpty {
                currentFile?.propertyChanges.append(line)
            }
        }

        flushFile()
        return UnifiedDiff(files: files)
    }

    private static func path(from header: String) -> String {
        let body = String(header.dropFirst(4))
        return body.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? body
    }

    private static func hunkRange(_ header: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard let expression = try? NSRegularExpression(pattern: #"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#),
              let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..<header.endIndex, in: header)) else { return nil }
        func number(_ index: Int, default fallback: Int) -> Int {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: header) else { return fallback }
            return Int(header[range]) ?? fallback
        }
        return (number(1, default: 0), number(2, default: 1), number(3, default: 0), number(4, default: 1))
    }
}

public enum SideBySideDiffBuilder {
    public struct Row: Identifiable, Hashable, Sendable {
        public let id = UUID()
        public var left: DiffLine?
        public var right: DiffLine?
    }

    public static func rows(for hunk: DiffHunk) -> [Row] {
        var rows: [Row] = []
        var pendingDeletes: [DiffLine] = []
        var pendingAdds: [DiffLine] = []

        func flushChanges() {
            let count = max(pendingDeletes.count, pendingAdds.count)
            for index in 0..<count {
                rows.append(Row(
                    left: index < pendingDeletes.count ? pendingDeletes[index] : nil,
                    right: index < pendingAdds.count ? pendingAdds[index] : nil
                ))
            }
            pendingDeletes.removeAll(keepingCapacity: true)
            pendingAdds.removeAll(keepingCapacity: true)
        }

        for line in hunk.lines {
            switch line.kind {
            case .deletion: pendingDeletes.append(line)
            case .addition: pendingAdds.append(line)
            case .context, .metadata:
                flushChanges()
                rows.append(Row(left: line, right: line))
            }
        }
        flushChanges()
        return rows
    }
}
