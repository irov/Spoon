import AppKit
import SpoonDiff
import SwiftUI

struct DiffInspector: View {
    let text: String
    let beforeImageData: Data?
    let afterImageData: Data?
    let binaryDescription: String?
    let pathBase: String?
    let contextMode: DiffContextMode
    let isContextLoading: Bool
    let onContextModeChange: (DiffContextMode) -> Void
    @State private var layout: DiffLayoutChoice = .unified

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Diff")
                    .font(.system(size: 12, weight: .semibold))
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
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 180)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
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
                    UnifiedDiffView(diff: diff, pathBase: pathBase)
                } else {
                    SideBySideDiffView(diff: diff, pathBase: pathBase)
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
    static let codeFontSize: CGFloat = 10
    static let metadataFontSize: CGFloat = 9.5
    static let lineNumberWidth: CGFloat = 34
    static let lineHeight: CGFloat = 16
    static let codeLeadingPadding: CGFloat = 7
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
    let pathBase: String?

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.files) { file in
                        DiffFileHeader(file: file, pathBase: pathBase)
                        ForEach(file.hunks) { hunk in
                            UnifiedHunkHeader(hunk: hunk)
                            ForEach(hunk.lines) { line in
                                UnifiedDiffLineRow(
                                    line: line,
                                    minimumWidth: max(geometry.size.width, 720)
                                )
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
    let pathBase: String?

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 8)
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(displayPath)
                .font(.system(size: DiffMetrics.metadataFontSize, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(Color.primary.opacity(0.055))
        .overlay(alignment: .bottom) { Divider() }
        .help(fullPath)
    }

    private var fullPath: String {
        file.newPath.isEmpty ? file.oldPath : file.newPath
    }

    private var displayPath: String {
        guard let pathBase, !pathBase.isEmpty else { return fullPath }
        let prefix = pathBase.hasSuffix("/") ? pathBase : pathBase + "/"
        if fullPath == pathBase { return URL(fileURLWithPath: fullPath).lastPathComponent }
        if fullPath.hasPrefix(prefix) { return String(fullPath.dropFirst(prefix.count)) }
        return fullPath
    }
}

private struct UnifiedHunkHeader: View {
    let hunk: DiffHunk

    var body: some View {
        HStack(spacing: 0) {
            DiffLineNumber(number: hunk.oldStart)
            DiffLineNumber(number: hunk.newStart)
            Divider()
            HStack(spacing: 0) {
                Text(verbatim: hunk.header)
                    .padding(.leading, DiffMetrics.codeLeadingPadding)
                Spacer(minLength: 12)
            }
            .frame(height: 20)
            .background(Color.primary.opacity(0.04))
        }
        .font(.system(size: DiffMetrics.metadataFontSize, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }
}

private struct UnifiedDiffLineRow: View {
    let line: DiffLine
    let minimumWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            DiffLineNumber(number: line.oldLineNumber)
            DiffLineNumber(number: line.newLineNumber)
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
            Text(verbatim: line.content.isEmpty ? " " : line.content)
                .padding(.leading, DiffMetrics.codeLeadingPadding)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
        }
        .font(.system(size: DiffMetrics.codeFontSize, weight: .regular, design: .monospaced))
        .frame(minHeight: DiffMetrics.lineHeight)
        .frame(minWidth: minimumWidth, alignment: .leading)
        .background {
            Rectangle().fill(DiffPalette.lineBackground(for: line.kind, colorScheme: colorScheme))
        }
    }
}

private struct PropertyDiffRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            DiffLineNumber(number: nil)
            DiffLineNumber(number: nil)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "tag").foregroundStyle(.orange)
                Text(verbatim: text).textSelection(.enabled)
                Spacer(minLength: 12)
            }
            .padding(.leading, DiffMetrics.codeLeadingPadding)
            .frame(height: DiffMetrics.lineHeight)
            .background(Color.orange.opacity(0.12))
        }
        .font(.system(size: DiffMetrics.metadataFontSize, design: .monospaced))
        .frame(height: DiffMetrics.lineHeight)
    }
}

private struct SideBySideDiffView: View {
    let diff: UnifiedDiff
    let pathBase: String?

    var body: some View {
        GeometryReader { geometry in
            let columnWidth = max(380, (geometry.size.width - 1) / 2)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.files) { file in
                        DiffFileHeader(file: file, pathBase: pathBase)
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
        HStack(spacing: 0) {
            DiffLineNumber(number: old ? hunk.oldStart : hunk.newStart)
            Divider()
            HStack {
                Text(verbatim: hunk.header)
                Spacer(minLength: 8)
            }
            .padding(.leading, DiffMetrics.codeLeadingPadding)
            .background(Color.primary.opacity(0.04))
        }
        .font(.system(size: DiffMetrics.metadataFontSize, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: width, height: 20)
    }

    private func diffCell(_ line: DiffLine?, side: DiffSide, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            DiffLineNumber(number: side.lineNumber(for: line))
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
            Text(verbatim: line?.content.isEmpty == false ? line?.content ?? "" : " ")
                .padding(.leading, DiffMetrics.codeLeadingPadding)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
        }
        .font(.system(size: DiffMetrics.codeFontSize, weight: .regular, design: .monospaced))
        .frame(width: width, alignment: .leading)
        .frame(minHeight: DiffMetrics.lineHeight)
        .clipped()
        .background {
            Rectangle().fill(side.backgroundColor(for: line, colorScheme: colorScheme))
        }
    }

    @Environment(\.colorScheme) private var colorScheme
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

    func backgroundColor(for line: DiffLine?, colorScheme: ColorScheme) -> Color {
        guard let line else { return Color.primary.opacity(0.018) }
        return switch (self, line.kind) {
        case (.old, .deletion): DiffPalette.deletionBackground(colorScheme)
        case (.new, .addition): DiffPalette.additionBackground(colorScheme)
        default: Color.clear
        }
    }

}

private struct DiffLineNumber: View {
    let number: Int?

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: DiffMetrics.metadataFontSize, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .padding(.trailing, 5)
            .frame(width: DiffMetrics.lineNumberWidth, height: DiffMetrics.lineHeight, alignment: .trailing)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

private enum DiffPalette {
    static func lineBackground(for kind: DiffLineKind, colorScheme: ColorScheme) -> Color {
        switch kind {
        case .addition: additionBackground(colorScheme)
        case .deletion: deletionBackground(colorScheme)
        case .metadata: Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)
        case .context: .clear
        }
    }

    static func additionBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.29, blue: 0.17)
            : Color(red: 0.84, green: 0.96, blue: 0.86)
    }

    static func deletionBackground(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.34, green: 0.16, blue: 0.17)
            : Color(red: 1.00, green: 0.87, blue: 0.87)
    }

}
