import AppKit
import SpoonDiff
import SwiftUI

struct DiffInspector: View {
    let text: String
    let beforeImageData: Data?
    let afterImageData: Data?
    let binaryDescription: String?
    let contextMode: DiffContextMode
    let isContextLoading: Bool
    let onContextModeChange: (DiffContextMode) -> Void
    @State private var layout: DiffLayoutChoice = .unified

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diff").font(.headline)
                Spacer()
                Picker("Context", selection: contextModeBinding) {
                    Label("Changes Only", systemImage: "eye.slash")
                        .labelStyle(.iconOnly)
                        .tag(DiffContextMode.changes)
                    Label("Full File", systemImage: "eye")
                        .labelStyle(.iconOnly)
                        .tag(DiffContextMode.fullFile)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 70)
                .disabled(!supportsContextModes || isContextLoading)
                .help(contextMode == .fullFile ? "Showing Full File" : "Showing Changes Only")
                .overlay {
                    if isContextLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                Picker("Layout", selection: $layout) {
                    Text("Unified").tag(DiffLayoutChoice.unified)
                    Text("Side by Side").tag(DiffLayoutChoice.sideBySide)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(10)
            Divider()
            if beforeImageData != nil || afterImageData != nil {
                imageComparison
            } else if let binaryDescription {
                ContentUnavailableView("Binary File", systemImage: "doc.fill", description: Text(binaryDescription))
            } else if text.isEmpty {
                ContentUnavailableView("No Diff Selected", systemImage: "doc.text.magnifyingglass", description: Text("Select a changed path or revision."))
            } else {
                let diff = UnifiedDiffParser.parse(text)
                if diff.files.isEmpty {
                    PlainDiffText(text: text)
                } else if layout == .unified {
                    UnifiedDiffView(diff: diff)
                } else {
                    SideBySideDiffView(diff: diff)
                }
            }
        }
    }

    private var contextModeBinding: Binding<DiffContextMode> {
        Binding(get: { contextMode }, set: onContextModeChange)
    }

    private var supportsContextModes: Bool {
        beforeImageData == nil
            && afterImageData == nil
            && binaryDescription == nil
            && text.contains("@@ ")
    }

    private var imageComparison: some View {
        HStack(spacing: 0) {
            imagePane(title: "Before", data: beforeImageData)
            Divider()
            imagePane(title: "Working Copy", data: afterImageData)
        }
    }

    private func imagePane(title: LocalizedStringKey, data: Data?) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary).padding(8)
            Divider()
            if let data, let image = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().scaledToFit().padding(16)
                }
            } else {
                ContentUnavailableView("No Image", systemImage: "photo.badge.exclamationmark")
            }
        }
    }

}

enum DiffContextMode: String, CaseIterable {
    case changes
    case fullFile
}

private enum DiffLayoutChoice { case unified, sideBySide }

private enum DiffMetrics {
    static let codeFontSize: CGFloat = 11
    static let metadataFontSize: CGFloat = 10
    static let lineNumberWidth: CGFloat = 42
    static let markerWidth: CGFloat = 20
    static let lineHeight: CGFloat = 18
}

private struct PlainDiffText: View {
    let text: String

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: text)
                    .font(.system(size: DiffMetrics.codeFontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                    .padding(10)
            }
        }
    }
}

private struct UnifiedDiffView: View {
    let diff: UnifiedDiff

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.files) { file in
                        DiffFileHeader(file: file)
                        ForEach(file.hunks) { hunk in
                            UnifiedHunkHeader(hunk: hunk)
                            ForEach(hunk.lines) { line in
                                UnifiedDiffLineRow(line: line)
                            }
                        }
                        ForEach(Array(file.propertyChanges.enumerated()), id: \.offset) { _, property in
                            PropertyDiffRow(text: property)
                        }
                    }
                }
                .frame(
                    minWidth: max(geometry.size.width, 720),
                    minHeight: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
    }
}

private struct DiffFileHeader: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(file.newPath.isEmpty ? file.oldPath : file.newPath)
                .font(.system(size: DiffMetrics.metadataFontSize, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            if !file.oldPath.isEmpty, !file.newPath.isEmpty, file.oldPath != file.newPath {
                Text("← \(file.oldPath)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(Color.primary.opacity(0.075))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct UnifiedHunkHeader: View {
    let hunk: DiffHunk

    var body: some View {
        HStack(spacing: 0) {
            Text(hunk.oldStart, format: .number)
                .frame(width: DiffMetrics.lineNumberWidth, alignment: .trailing)
            Text(hunk.newStart, format: .number)
                .frame(width: DiffMetrics.lineNumberWidth, alignment: .trailing)
            Rectangle()
                .fill(Color.blue.opacity(0.8))
                .frame(width: 3)
            Text(verbatim: hunk.header)
                .padding(.leading, 9)
            Spacer(minLength: 12)
        }
        .font(.system(size: DiffMetrics.metadataFontSize, design: .monospaced))
        .foregroundStyle(Color.blue)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(Color.blue.opacity(0.12))
    }
}

private struct UnifiedDiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)
            Rectangle()
                .fill(line.accentColor)
                .frame(width: 3)
            Text(line.marker)
                .foregroundStyle(line.accentColor)
                .frame(width: DiffMetrics.markerWidth, alignment: .center)
            Text(verbatim: line.content.isEmpty ? " " : line.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
        }
        .font(.system(size: DiffMetrics.codeFontSize, weight: .regular, design: .monospaced))
        .frame(minHeight: DiffMetrics.lineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Rectangle().fill(line.backgroundColor) }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: DiffMetrics.lineNumberWidth, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

private struct PropertyDiffRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: DiffMetrics.lineNumberWidth * 2)
            Rectangle().fill(Color.orange.opacity(0.8)).frame(width: 3)
            Image(systemName: "tag").frame(width: DiffMetrics.markerWidth).foregroundStyle(.orange)
            Text(verbatim: text)
                .textSelection(.enabled)
            Spacer(minLength: 12)
        }
        .font(.system(size: DiffMetrics.metadataFontSize, design: .monospaced))
        .frame(minHeight: DiffMetrics.lineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Rectangle().fill(Color.orange.opacity(0.10)) }
    }
}

private struct SideBySideDiffView: View {
    let diff: UnifiedDiff

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = max(380, (geometry.size.width - 1) / 2)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.files) { file in
                        DiffFileHeader(file: file)
                        ForEach(file.hunks) { hunk in
                            HStack(spacing: 0) {
                                sideHunkHeader(hunk, old: true, width: columnWidth)
                                Divider()
                                sideHunkHeader(hunk, old: false, width: columnWidth)
                            }
                            ForEach(SideBySideDiffBuilder.rows(for: hunk)) { row in
                                HStack(spacing: 0) {
                                    diffCell(row.left, side: .old, width: columnWidth)
                                    Divider()
                                    diffCell(row.right, side: .new, width: columnWidth)
                                }
                            }
                        }
                    }
                }
                .frame(
                    minWidth: max(geometry.size.width, columnWidth * 2 + 1),
                    minHeight: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
    }

    private func sideHunkHeader(_ hunk: DiffHunk, old: Bool, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(old ? hunk.oldStart : hunk.newStart, format: .number)
                .frame(width: DiffMetrics.lineNumberWidth, alignment: .trailing)
            Text(verbatim: hunk.header)
            Spacer(minLength: 8)
        }
        .font(.system(size: DiffMetrics.metadataFontSize, design: .monospaced))
        .foregroundStyle(Color.blue)
        .frame(width: width, height: 22)
        .background(Color.blue.opacity(0.12))
    }

    private func diffCell(_ line: DiffLine?, side: DiffSide, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(side.lineNumber(for: line).map(String.init) ?? "")
                .frame(width: DiffMetrics.lineNumberWidth, alignment: .trailing)
                .padding(.trailing, 6)
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(side.accentColor(for: line))
                .frame(width: 3)
            Text(side.marker(for: line))
                .frame(width: DiffMetrics.markerWidth)
                .foregroundStyle(side.accentColor(for: line))
            Text(verbatim: line?.content.isEmpty == false ? line?.content ?? "" : " ")
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
        }
        .font(.system(size: DiffMetrics.codeFontSize, weight: .regular, design: .monospaced))
        .frame(width: width, alignment: .leading)
        .frame(minHeight: DiffMetrics.lineHeight)
        .background(side.backgroundColor(for: line))
    }
}

private enum DiffSide {
    case old
    case new

    func lineNumber(for line: DiffLine?) -> Int? {
        switch self {
        case .old: line?.oldLineNumber
        case .new: line?.newLineNumber
        }
    }

    func marker(for line: DiffLine?) -> String {
        guard let line else { return "" }
        return switch (self, line.kind) {
        case (.old, .deletion): "−"
        case (.new, .addition): "+"
        default: ""
        }
    }

    func accentColor(for line: DiffLine?) -> Color {
        guard let line else { return .clear }
        return switch (self, line.kind) {
        case (.old, .deletion): Color.red
        case (.new, .addition): Color.green
        default: Color.clear
        }
    }

    func backgroundColor(for line: DiffLine?) -> Color {
        guard let line else { return Color.primary.opacity(0.018) }
        return switch (self, line.kind) {
        case (.old, .deletion): Color.red.opacity(0.28)
        case (.new, .addition): Color.green.opacity(0.24)
        default: Color.clear
        }
    }
}

private extension DiffLine {
    var marker: String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context, .metadata: ""
        }
    }

    var accentColor: Color {
        switch kind {
        case .addition: .green
        case .deletion: .red
        case .metadata: .orange
        case .context: .clear
        }
    }

    var backgroundColor: Color {
        switch kind {
        case .addition: Color.green.opacity(0.24)
        case .deletion: Color.red.opacity(0.28)
        case .metadata: Color.orange.opacity(0.10)
        case .context: .clear
        }
    }
}
