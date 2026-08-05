import AppKit
import SpoonDiff
import SwiftUI

struct DiffInspector: View {
    let text: String
    @State private var layout: DiffLayoutChoice = .unified

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Diff").font(.headline)
                Spacer()
                Picker("Layout", selection: $layout) {
                    Text("Unified").tag(DiffLayoutChoice.unified)
                    Text("Side by Side").tag(DiffLayoutChoice.sideBySide)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(10)
            Divider()
            if text.isEmpty {
                ContentUnavailableView("No Diff Selected", systemImage: "doc.text.magnifyingglass", description: Text("Select a changed path or revision."))
            } else if layout == .unified {
                ScrollView([.horizontal, .vertical]) {
                    Text(attributedDiff)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            } else {
                SideBySideDiffView(diff: UnifiedDiffParser.parse(text))
            }
        }
    }

    private var attributedDiff: AttributedString {
        var output = AttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var attributed = AttributedString(String(line) + "\n")
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                attributed.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                attributed.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15)
            } else if line.hasPrefix("@@") {
                attributed.foregroundColor = NSColor.systemBlue
            }
            output.append(attributed)
        }
        return output
    }
}

private enum DiffLayoutChoice { case unified, sideBySide }

private struct SideBySideDiffView: View {
    let diff: UnifiedDiff

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(diff.files) { file in
                    Text(file.newPath).font(.headline.monospaced()).padding(.vertical, 8)
                    ForEach(file.hunks) { hunk in
                        Text(hunk.header).font(.caption.monospaced()).foregroundStyle(.blue)
                        ForEach(SideBySideDiffBuilder.rows(for: hunk)) { row in
                            HStack(spacing: 0) {
                                diffCell(row.left, deletion: true)
                                Divider()
                                diffCell(row.right, deletion: false)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func diffCell(_ line: DiffLine?, deletion: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.flatMap { deletion ? $0.oldLineNumber : $0.newLineNumber }.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing).foregroundStyle(.tertiary)
            Text(line?.content ?? "").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 1)
        .background(line?.kind == .deletion ? Color.red.opacity(0.12) : line?.kind == .addition ? Color.green.opacity(0.12) : Color.clear)
        .frame(width: 500, alignment: .leading)
    }
}
