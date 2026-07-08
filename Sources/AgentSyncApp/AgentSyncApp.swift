import SwiftUI

@main
struct AgentSyncApp: App {
    // The status item, popover, splash, and Settings window are all owned by
    // the delegate. The App still needs one scene; SwiftUI's `Settings` scene
    // is unreliable on macOS 26, so this placeholder just satisfies the
    // requirement and is never presented.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
