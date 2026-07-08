import AgentSyncCore
import AppKit
import SwiftUI

/// Launch splash: one of the two bundled posters, chosen at
/// random, fading in and out in a floating borderless window.
@MainActor
enum SplashWindow {
    private static var window: NSWindow?

    static func show() {
        let bundle = continuoResourceBundle("agent-sync_AgentSyncApp", fallback: .module)
        let candidates = ["splash-1", "splash-2"].compactMap {
            bundle.url(forResource: $0, withExtension: "png")
        }
        guard let url = candidates.randomElement(), let image = NSImage(contentsOf: url) else {
            return
        }

        let height: CGFloat = 560
        let width = height * (image.size.width / max(image.size.height, 1))
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let splash = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        splash.isOpaque = false
        splash.backgroundColor = .clear
        splash.level = .floating
        splash.hasShadow = true
        splash.contentView = imageView
        splash.contentView?.wantsLayer = true
        splash.contentView?.layer?.cornerRadius = 18
        splash.contentView?.layer?.masksToBounds = true
        splash.center()
        splash.alphaValue = 0
        splash.orderFrontRegardless()
        window = splash

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            splash.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                splash.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    window?.orderOut(nil)
                    window = nil
                }
            })
        }
    }
}
