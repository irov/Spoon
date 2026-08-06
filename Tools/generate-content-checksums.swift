#!/usr/bin/env swift

import CryptoKit
import Foundation

enum ChecksumError: Error {
    case usage
    case malformedMachO(URL)
}

func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data.withUnsafeBytes { bytes in
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}

func contentSHA256(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    guard data.count >= 32, readUInt32(data, at: 0) == 0xfeedfacf else {
        throw ChecksumError.malformedMachO(url)
    }

    let commandCount = Int(readUInt32(data, at: 16))
    let commandBytes = Int(readUInt32(data, at: 20))
    let payloadStart = 32 + commandBytes
    guard commandCount > 0, payloadStart <= data.count else {
        throw ChecksumError.malformedMachO(url)
    }

    var commandOffset = 32
    var signatureOffset = data.count
    for _ in 0..<commandCount {
        guard commandOffset + 8 <= data.count else { throw ChecksumError.malformedMachO(url) }
        let command = readUInt32(data, at: commandOffset)
        let commandSize = Int(readUInt32(data, at: commandOffset + 4))
        guard commandSize >= 8, commandOffset + commandSize <= payloadStart else {
            throw ChecksumError.malformedMachO(url)
        }
        if command == 0x1d {
            guard commandSize >= 16 else { throw ChecksumError.malformedMachO(url) }
            signatureOffset = Int(readUInt32(data, at: commandOffset + 8))
        }
        commandOffset += commandSize
    }

    guard signatureOffset >= payloadStart, signatureOffset <= data.count else {
        throw ChecksumError.malformedMachO(url)
    }
    return SHA256.hash(data: data[payloadStart..<signatureOffset])
        .map { String(format: "%02x", $0) }
        .joined()
}

guard CommandLine.arguments.count == 3 else { throw ChecksumError.usage }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
var paths: [String] = []
for directory in ["Helpers", "Libraries"] {
    let directoryURL = root.appendingPathComponent(directory, isDirectory: true)
    let children = try FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    paths += children.map { "\(directory)/\($0.lastPathComponent)" }
}

let manifest = try paths.sorted().map { path in
    "\(try contentSHA256(of: root.appendingPathComponent(path)))  \(path)"
}.joined(separator: "\n") + "\n"
try manifest.write(to: output, atomically: true, encoding: .utf8)
