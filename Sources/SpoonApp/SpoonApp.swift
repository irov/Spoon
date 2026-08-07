import SpoonUI
import SwiftUI

@main
struct SpoonApp: App {
    @NSApplicationDelegateAdaptor(SpoonApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup("Spoon") {
            SpoonWindow()
        }
        .defaultSize(width: 1_500, height: 900)
        .commands { SpoonCommands() }

        Settings {
            SettingsContainer()
        }

        Window("Spoon Help", id: "spoon-help") {
            SupportView()
        }
        .windowResizability(.contentSize)

        Window("Feedback", id: "spoon-feedback") {
            FeedbackView()
        }
        .windowResizability(.contentSize)
    }
}

private struct SpoonWindow: View {
    @State private var model = AppModel()
    var body: some View { RootView(model: model) }
}

private struct SettingsContainer: View {
    @State private var model = AppModel()
    @AppStorage(TelemetryPreferences.collectionEnabledKey) private var technicalDataCollectionEnabled = false

    var body: some View {
        SettingsView(
            model: model,
            technicalDataCollectionEnabled: $technicalDataCollectionEnabled,
            onTechnicalDataCollectionChanged: { enabled in
                FirebaseTelemetry.shared.updateConsent(enabled: enabled)
            }
        )
    }
}

private struct SpoonCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Working Copy…") { NotificationCenter.default.post(name: .spoonOpenWorkingCopy, object: nil) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Checkout…") { NotificationCenter.default.post(name: .spoonCheckout, object: nil) }
        }
        CommandMenu("Working Copy") {
            Button("Refresh Local Status") { NotificationCenter.default.post(name: .spoonRefresh, object: nil) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Check Remote Status") { NotificationCenter.default.post(name: .spoonRemoteRefresh, object: nil) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Update Working Copy") { NotificationCenter.default.post(name: .spoonUpdate, object: nil) }
                .keyboardShortcut("u", modifiers: .command)
            Button("Commit Staged Changes") { NotificationCenter.default.post(name: .spoonCommit, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Command Palette") { NotificationCenter.default.post(name: .spoonCommandPalette, object: nil) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Spoon Help") { openWindow(id: "spoon-help") }
            Button("Send Feedback…") { openWindow(id: "spoon-feedback") }
        }
    }
}
