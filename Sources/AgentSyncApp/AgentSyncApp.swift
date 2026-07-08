import SwiftUI

@main
struct AgentSyncApp: App {
    @StateObject private var model = AppModel()

    init() {
        SplashWindow.show()
    }

    var body: some Scene {
        MenuBarExtra("Continuo", systemImage: "arrow.left.arrow.right") {
            SessionPickerView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
