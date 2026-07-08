import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global hotkey (⌥⌘S) via Carbon — no accessibility permission required.
/// All use is from the main thread (Carbon dispatches there too).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onHotKey: (() -> Void)?

    func register() {
        unregister()
        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData -> OSStatus in
                    guard let userData else {
                        return noErr
                    }
                    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async {
                        center.onHotKey?()
                    }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &handlerRef
            )
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5345_5353), id: 1) // 'SESS'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(optionKey | cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

/// Spotlight-style floating panel hosting the same picker. Exists because a
/// MenuBarExtra popover cannot be opened programmatically.
@MainActor
enum QuickPicker {
    private static var panel: KeyablePanel?

    static func toggle(model: AppModel) {
        if let existing = panel, existing.isVisible {
            existing.close()
            panel = nil
            return
        }
        let hosting = NSHostingController(rootView: SessionPickerView(model: model))
        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = hosting
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.standardWindowButton(.closeButton)?.isHidden = true
        newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newPanel.standardWindowButton(.zoomButton)?.isHidden = true
        newPanel.isMovableByWindowBackground = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        newPanel.onDismiss = {
            panel = nil
        }

        // Spotlight placement: horizontally centered, upper third.
        if let screen = NSScreen.main {
            let frame = newPanel.frame
            newPanel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.minY + screen.visibleFrame.height * 0.68 - frame.height
            ))
        }
        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }
}

final class KeyablePanel: NSPanel, NSWindowDelegate {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        delegate = self
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    override func close() {
        onDismiss?()
        super.close()
    }
}
