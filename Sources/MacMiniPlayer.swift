#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacMiniPlayer: NSObject, NSWindowDelegate {
    private var panel: MiniPlayerPanel?
    private weak var libraryWindow: NSWindow?
    private var lastFrame: NSRect?

    func show(library: LibraryModel, style: MiniPlayerStyle, hiding window: NSWindow) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let dragHeight: CGFloat = 22
        let size = NSSize(width: 365, height: 478 + dragHeight)
        let screen = lastFrame.flatMap { frame in NSScreen.screens.first { $0.visibleFrame.contains(frame) } }
            ?? window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        let savedOrigin = lastFrame?.intersects(visible) == true ? lastFrame?.origin : nil
        let origin = savedOrigin ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        let frame = NSRect(
            x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
            y: max(visible.minY, min(origin.y, visible.maxY - size.height)),
            width: size.width,
            height: size.height
        )
        let panel = MiniPlayerPanel(contentRect: frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
        panel.title = "Now Playing"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = MiniPlayerHostingView(rootView:
            MiniPlayerContent(library: library, style: style) { [weak panel] in
                // SwiftUI can request a close while updating the hosted view.
                DispatchQueue.main.async { [weak panel] in
                    guard let panel, panel.isVisible else { return }
                    panel.close()
                }
            }
            .preferredColorScheme(style == .classic || style == .desktop98 ? .light : .dark)
        )
        host.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - dragHeight)
        container.addSubview(host)
        let grip = MiniPlayerDragView(frame: NSRect(x: 0, y: host.frame.maxY, width: size.width, height: dragHeight))
        container.addSubview(grip)
        panel.contentView = container
        self.panel = panel
        libraryWindow = window
        panel.makeKeyAndOrderFront(nil)
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? MiniPlayerPanel, closingPanel === panel else { return }
        lastFrame = closingPanel.frame
        let window = libraryWindow
        panel = nil
        libraryWindow = nil
        window?.makeKeyAndOrderFront(nil)
    }
}

private final class MiniPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (event.keyCode == 53 && modifiers.isEmpty) ||
            (event.charactersIgnoringModifiers == "w" && modifiers == .command) {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

private final class MiniPlayerHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class MiniPlayerDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        let grip = NSRect(x: bounds.midX - 21, y: bounds.midY - 3, width: 42, height: 6)
        let outline = NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3)
        NSColor(white: 0.24, alpha: 1).setFill()
        outline.fill()
        NSColor(white: 0.75, alpha: 1).setStroke()
        outline.stroke()
    }
}
#endif
