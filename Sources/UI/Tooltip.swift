import AppKit
import SwiftUI

extension View {
    /// An immediate, native tooltip: shows `text` in a small floating window
    /// above the view the moment the pointer enters it (no `.help` hover delay)
    /// and hides on exit. Backed by an `NSTrackingArea` and a non-activating
    /// window, so it never steals focus or flickers like a SwiftUI `.popover`.
    func hoverTooltip(_ text: String) -> some View {
        background(TooltipTrackingView(text: text))
    }
}

/// A transparent background view that reports hover to the shared tooltip window.
/// Tracking areas are region-based, so the view still receives enter/exit even
/// though it sits behind the (clickable) content.
private struct TooltipTrackingView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.text = text
    }

    final class TrackingNSView: NSView {
        var text: String = ""
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            TooltipWindow.shared.show(text, near: bounds, in: self)
        }

        override func mouseExited(with event: NSEvent) {
            TooltipWindow.shared.hide()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { TooltipWindow.shared.hide() }
        }
    }
}

/// A single shared floating tooltip window. Positioning is done in screen
/// coordinates, anchored to the *top* edge of the hovered element.
private final class TooltipWindow {
    static let shared = TooltipWindow()

    private let window: NSWindow
    private let label: NSTextField

    private init() {
        label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .labelColor
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.alignment = .left

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(label)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.animationBehavior = .none
        window.contentView = container
    }

    func show(_ text: String, near rect: NSRect, in view: NSView) {
        guard let anchorWindow = view.window else { return }

        label.stringValue = text
        let maxTextWidth: CGFloat = 268
        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 4

        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: 40),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let w = ceil(textSize.width) + paddingX * 2
        let h = ceil(textSize.height) + paddingY * 2
        label.frame = NSRect(x: paddingX, y: paddingY,
                             width: w - paddingX * 2, height: h - paddingY * 2)

        let rectInWindow = view.convert(rect, to: nil)
        let rectInScreen = anchorWindow.convertToScreen(rectInWindow)

        let gap: CGFloat = 5
        var x = rectInScreen.midX - w / 2
        let y = rectInScreen.maxY + gap

        // Keep the tooltip on screen horizontally.
        if let screen = anchorWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 4), visible.maxX - w - 4)
        }

        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        window.orderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }
}
