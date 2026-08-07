import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable private var model: AppModel
    @Binding private var technicalDataCollectionEnabled: Bool
    private let onTechnicalDataCollectionChanged: (Bool) -> Void
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("diff.fontSize") private var diffFontSize = 12.0
    @AppStorage("diff.ignoreWhitespace") private var ignoreWhitespace = false
    @AppStorage("update.includeExternals") private var includeExternals = true

    public init(
        model: AppModel,
        technicalDataCollectionEnabled: Binding<Bool>,
        onTechnicalDataCollectionChanged: @escaping (Bool) -> Void
    ) {
        self.model = model
        _technicalDataCollectionEnabled = technicalDataCollectionEnabled
        self.onTechnicalDataCollectionChanged = onTechnicalDataCollectionChanged
    }

    public var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("Diff font size", selection: $diffFontSize) {
                    ForEach([10.0, 11.0, 12.0, 13.0, 14.0, 16.0], id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                Toggle("Ignore whitespace in diff view", isOn: $ignoreWhitespace)
                Toggle("Include externals during update", isOn: $includeExternals)

                Section("Privacy") {
                    Toggle("Share technical analytics and crash reports", isOn: $technicalDataCollectionEnabled)
                        .onChange(of: technicalDataCollectionEnabled) { _, enabled in
                            onTechnicalDataCollectionChanged(enabled)
                        }
                    Text("Send technical usage analytics and crash reports to help improve Spoon. Repository contents, file contents, credentials, and commit messages are never included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                LabeledContent("Subversion version", value: model.capabilities?.version ?? "Unavailable")
                LabeledContent("Architecture", value: model.capabilities?.architecture ?? "Unknown")
                LabeledContent("Repository access", value: model.capabilities?.repositoryAccessModules.sorted().joined(separator: ", ") ?? "—")
                LabeledContent("Credential providers", value: model.capabilities?.credentialProviders.sorted().joined(separator: ", ") ?? "—")
                LabeledContent("Bundled toolchain", value: model.capabilities?.isBundled == true ? "Verified" : "Unavailable")
                LabeledContent("Code signature", value: model.capabilities?.signatureValid == true ? "Valid" : "Invalid")
                LabeledContent("Checksums", value: model.capabilities?.checksumsValid == true ? "Valid" : "Invalid")
                LabeledContent("OpenSSH", value: model.capabilities?.openSSHVersion ?? "Unavailable")
                Button("Export Diagnostics…", action: exportDiagnostics)
            }
            .padding(20)
            .tabItem { Label("Diagnostics", systemImage: "stethoscope") }

            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                Text("Spoon").font(.title.bold())
                Text("Native Subversion client for macOS")
                Text("Version 1.0.0 (1)").foregroundStyle(.secondary)
                Link("Source code and licenses", destination: URL(string: "https://github.com/irov/Spoon")!)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 590, height: 390)
    }

    private func exportDiagnostics() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportDiagnostics(to: url) }
    }
}
