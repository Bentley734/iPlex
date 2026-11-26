#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacMiniPlayer: NSObject, NSWindowDelegate {
    private var panel: MiniPlayerPanel?
    private weak var libraryWindow: NSWindow?
    private var lastFrame: NSRect?

    func show(library: LibraryModel, style: MiniPlayerStyle, hiding window: NSWindow) {
        guard panel == nil else { panel?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 365, height: 478)
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window.frame
        let savedOrigin = lastFrame?.intersects(visible) == true ? lastFrame?.origin : nil
        let origin = savedOrigin ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        let frame = NSRect(
            x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
            y: max(visible.minY, min(origin.y, visible.maxY - size.height)),
            width: size.width,
            height: size.height
        )
        let panel = MiniPlayerPanel(contentRect: frame, styleMask: [.borderless, .utilityWindow],
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
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = NSHostingView(rootView:
            MiniPlayerContent(library: library, style: style) { [weak self] in self?.panel?.close() }
                .preferredColorScheme(style == .classic ? .light : .dark)
                .overlay(alignment: .top) {
                    MiniPlayerDragArea().frame(height: 16).accessibilityHidden(true)
                }
        )
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)
        self.panel = panel
        libraryWindow = window
        panel.makeKeyAndOrderFront(nil)
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? MiniPlayerPanel, closingPanel === panel else { return }
        lastFrame = closingPanel.frame
        panel = nil
        libraryWindow?.makeKeyAndOrderFront(nil)
        libraryWindow = nil
    }
}

private final class MiniPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }

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

private struct MiniPlayerDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
#endif
