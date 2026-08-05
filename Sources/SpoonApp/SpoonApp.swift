import SpoonUI
import SwiftUI

@main
struct SpoonApp: App {
    var body: some Scene {
        WindowGroup("Spoon") {
            SpoonWindow()
        }
        .defaultSize(width: 1_380, height: 820)
        .commands { SpoonCommands() }

        Settings {
            SettingsContainer()
        }
    }
}

private struct SpoonWindow: View {
    @State private var model = AppModel()
    var body: some View { RootView(model: model) }
}

private struct SettingsContainer: View {
    @State private var model = AppModel()
    var body: some View { SettingsView(model: model) }
}

private struct SpoonCommands: Commands {
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
            Button("Commit Selected Changes") { NotificationCenter.default.post(name: .spoonCommit, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Command Palette") { NotificationCenter.default.post(name: .spoonCommandPalette, object: nil) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
