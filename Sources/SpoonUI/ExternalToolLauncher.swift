import AppKit
import Foundation

enum ExternalToolPreset: String, CaseIterable, Identifiable {
    case fileMerge = "FileMerge"
    case kaleidoscope = "Kaleidoscope"
    case beyondCompare = "Beyond Compare"

    var id: String { rawValue }

    var bundleIdentifiers: [String] {
        switch self {
        case .fileMerge: ["com.apple.FileMerge"]
        case .kaleidoscope: ["com.kaleidoscopeapp.Kaleidoscope", "com.blackpixel.kaleidoscope"]
        case .beyondCompare: ["com.scootersoftware.BeyondCompare"]
        }
    }
}

enum ExternalToolLauncher {
    static func application(for preset: ExternalToolPreset) -> URL? {
        for identifier in preset.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        if preset == .fileMerge {
            let bundled = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Applications/FileMerge.app")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return nil
    }

    @MainActor
    static func open(_ urls: [URL], with preset: ExternalToolPreset?) async throws {
        guard let preset else {
            guard let first = urls.first else { return }
            NSWorkspace.shared.open(first)
            return
        }
        guard let application = application(for: preset) else {
            throw NSError(domain: "Spoon.ExternalTool", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(preset.rawValue) is not installed."])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}
