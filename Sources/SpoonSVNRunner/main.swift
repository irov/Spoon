import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("spoon-svn-runner: \(message)\n".utf8))
    exit(126)
}

private func readExactly(_ count: Int) -> Data {
    var result = Data()
    while result.count < count {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: count - result.count),
              !chunk.isEmpty else { fail("invalid security-scope header") }
        result.append(chunk)
    }
    return result
}

let header = readExactly(4)
let bookmarkLength = header.withUnsafeBytes { bytes in
    UInt32(bigEndian: bytes.loadUnaligned(as: UInt32.self))
}
if bookmarkLength > 16 * 1_024 * 1_024 { fail("security-scope bookmark is too large") }

var transferredURL: URL?
if bookmarkLength > 0 {
    let bookmark = readExactly(Int(bookmarkLength))
    do {
        var stale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { fail("transferred bookmark is stale") }
        // A bookmark created without explicit security scope carries an implicit
        // sandbox extension when sent to another process. Resolving it starts that
        // access automatically. Do not stop it: exec preserves the extension for
        // svn-core for the lifetime of the command.
        transferredURL = scopedURL
    } catch {
        fail("unable to resolve transferred bookmark: \(error.localizedDescription)")
    }
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent("svn-core")
let arguments = [executable.path] + CommandLine.arguments.dropFirst()
var cArguments = arguments.map { strdup($0) }
cArguments.append(nil)
defer { for argument in cArguments where argument != nil { free(argument) } }

let status = withExtendedLifetime(transferredURL) {
    executable.path.withCString { path in
        cArguments.withUnsafeMutableBufferPointer { buffer in
            execv(path, buffer.baseAddress)
        }
    }
}
fail("unable to exec svn-core (errno \(errno), status \(status))")
