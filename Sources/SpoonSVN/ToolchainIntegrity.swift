import CryptoKit
import Foundation

public enum ToolchainIntegrity {
    public enum IntegrityError: Error, Equatable {
        case malformedMachO
        case unsupportedArchitecture
    }

    private static let machHeader64Size = 32
    private static let machOMagic64: UInt32 = 0xfeedfacf
    private static let codeSignatureCommand: UInt32 = 0x1d

    /// Hashes the immutable Mach-O payload while excluding load commands and the
    /// code-signature blob. App Store export replaces signatures, but does not
    /// change this payload, so the digest remains pinned across re-signing.
    public static func contentSHA256(of url: URL) throws -> String {
        try contentSHA256(data: Data(contentsOf: url))
    }

    public static func contentSHA256(data: Data) throws -> String {
        guard data.count >= machHeader64Size,
              readUInt32(data, at: 0) == machOMagic64
        else {
            throw IntegrityError.unsupportedArchitecture
        }

        let commandCount = Int(readUInt32(data, at: 16))
        let commandBytes = Int(readUInt32(data, at: 20))
        let payloadStart = machHeader64Size + commandBytes
        guard commandCount > 0, payloadStart <= data.count else {
            throw IntegrityError.malformedMachO
        }

        var commandOffset = machHeader64Size
        var signatureOffset = data.count
        for _ in 0..<commandCount {
            guard commandOffset + 8 <= data.count else {
                throw IntegrityError.malformedMachO
            }
            let command = readUInt32(data, at: commandOffset)
            let commandSize = Int(readUInt32(data, at: commandOffset + 4))
            guard commandSize >= 8, commandOffset + commandSize <= payloadStart else {
                throw IntegrityError.malformedMachO
            }
            if command == codeSignatureCommand {
                guard commandSize >= 16 else { throw IntegrityError.malformedMachO }
                signatureOffset = Int(readUInt32(data, at: commandOffset + 8))
            }
            commandOffset += commandSize
        }

        guard signatureOffset >= payloadStart, signatureOffset <= data.count else {
            throw IntegrityError.malformedMachO
        }
        return SHA256.hash(data: data[payloadStart..<signatureOffset])
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func verifyManifest(_ manifest: URL, relativeTo root: URL) -> Bool {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8), !text.isEmpty else {
            return false
        }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2 else { return false }
            let file = root.appendingPathComponent(String(fields[1]))
            guard let actual = try? contentSHA256(of: file), actual == fields[0] else {
                return false
            }
        }
        return true
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
