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

if bookmarkLength > 0 {
    let bookmark = readExactly(Int(bookmarkLength))
    do {
        var stale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { fail("security-scope bookmark is stale") }
        guard scopedURL.startAccessingSecurityScopedResource() else { fail("security-scope access was denied") }
        // Do not stop access: exec replaces this process and preserves the consumed
        // sandbox extension for svn-core for the lifetime of the command.
    } catch {
        fail("unable to resolve security-scope bookmark: \(error.localizedDescription)")
    }
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .appendingPathComponent("svn-core")
let arguments = [executable.path] + CommandLine.arguments.dropFirst()
var cArguments = arguments.map { strdup($0) }
cArguments.append(nil)
defer { for argument in cArguments where argument != nil { free(argument) } }

let status = executable.path.withCString { path in
    cArguments.withUnsafeMutableBufferPointer { buffer in
        execv(path, buffer.baseAddress)
    }
}
fail("unable to exec svn-core (errno \(errno), status \(status))")
