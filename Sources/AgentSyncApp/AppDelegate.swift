import AgentSyncCore
import AppKit
import SwiftUI

/// Drives the menu bar with an AppKit `NSStatusItem` rather than SwiftUI's
/// `MenuBarExtra`. A `MenuBarExtra` compiled against an older SDK fails to
/// register its item on macOS 26's redesigned menu bar; a plain status item is
/// SDK-agnostic and appears everywhere.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // SwiftUI wraps this delegate in its own `SwiftUI.AppDelegate`, so
    // `NSApp.delegate` is not castable to this type; keep a direct reference.
    private static weak var instance: AppDelegate?

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let shotsDir = ProcessInfo.processInfo.environment["CONTINUO_SHOTS"] {
            Screenshots.generate(into: URL(fileURLWithPath: shotsDir, isDirectory: true))
            return
        }
        Self.instance = self
        SplashWindow.show()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Continuo")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        let hosting = NSHostingController(rootView: SessionPickerView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.behavior = .transient
        popover.contentViewController = hosting
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else {
            return
        }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Opens Settings in an AppKit-owned window. SwiftUI's `Settings` scene and
    /// its `openSettings`/`showSettingsWindow:` actions don't reliably open from
    /// a status-item popover on macOS 26, so host the settings view directly.
    static func openSettings() {
        instance?.showSettings()
    }

    private func showSettings() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.title = "Continuo Settings"
        window.contentMinSize = NSSize(width: 600, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }
}
