#if os(macOS)
import AppKit
import AVKit
import SwiftUI

@MainActor
final class MacVideoPresentation: NSObject, NSWindowDelegate {
    enum Mode { case fullscreen, floating }

    private weak var inline: NSView?
    private var video: NSView?
    private var window: VideoPresentationWindow?
    private var mode: Mode?
    private var floatingFrame: NSRect?
    private var keepOnTop = true
    private var togglePlayback: (() -> Void)?

    func attach(_ video: NSView, to inline: NSView, togglePlayback: @escaping () -> Void) {
        self.video?.removeFromSuperview()
        self.video = video
        self.inline = inline
        self.togglePlayback = togglePlayback
        if let surface = window?.contentView?.subviews.first { mount(in: surface) }
        else { mount(in: inline) }
    }

    func detach(from inline: NSView) {
        guard self.inline === inline else { return }
        video?.removeFromSuperview()
        video = nil
        self.inline = nil
        togglePlayback = nil
    }

    func show(_ requested: Mode, title: String) {
        guard let inline, video != nil else { return }
        if mode == requested, let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let screen = window?.screen ?? inline.window?.screen ?? NSScreen.main
        guard let screen else { return }
        window?.close()
        let workArea = screen.visibleFrame
        let size = NSSize(width: min(540, workArea.width), height: min(330, workArea.height))
        let initial = NSRect(x: workArea.maxX - size.width - 24, y: workArea.maxY - size.height - 24,
                             width: size.width, height: size.height)
        let frame = requested == .fullscreen ? screen.frame :
            floatingFrame.flatMap { workArea.contains($0) ? $0 : nil } ?? initial
        let style: NSWindow.StyleMask = requested == .fullscreen ? .borderless : [.titled, .closable, .resizable]
        let window = VideoPresentationWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.title = title
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isMovable = requested == .floating
        window.collectionBehavior = requested == .floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = requested == .fullscreen ? .init(rawValue: NSWindow.Level.mainMenu.rawValue + 1) :
            keepOnTop ? .floating : .normal
        window.minSize = NSSize(width: 260, height: 165)
        window.togglePlayback = { [weak self] in self?.togglePlayback?() }

        let root = NSView()
        let surface = NSView()
        root.addSubview(surface)
        surface.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            surface.topAnchor.constraint(equalTo: root.topAnchor),
            surface.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        window.contentView = root
        if requested == .fullscreen {
            let exit = NSButton(title: "Exit Fullscreen", target: self, action: #selector(restoreVideo))
            exit.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(exit)
            window.configureFullscreenExit(exit)
            NSLayoutConstraint.activate([
                exit.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
                exit.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18)
            ])
        } else {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            let pin = NSButton(checkboxWithTitle: "Keep on Top", target: self, action: #selector(changePin(_:)))
            pin.state = keepOnTop ? .on : .off
            pin.frame = NSRect(x: 0, y: 0, width: pin.fittingSize.width + 12, height: 24)
            accessory.view = pin
            window.addTitlebarAccessoryViewController(accessory)
        }
        self.window = window
        mode = requested
        mount(in: surface)
        window.makeKeyAndOrderFront(nil)
    }

    func end() {
        window?.close()
        video?.removeFromSuperview()
        video = nil
        inline = nil
        togglePlayback = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? VideoPresentationWindow, closing === window else { return }
        if mode == .floating { floatingFrame = closing.frame }
        closing.stopTrackingFullscreenExit()
        mode = nil
        window = nil
        if let inline { mount(in: inline) }
    }

    private func mount(in destination: NSView) {
        guard let video else { return }
        if let av = video as? AVPlayerView { av.controlsStyle = mode == .floating ? .none : .inline }
        video.removeFromSuperview()
        video.frame = destination.bounds
        video.autoresizingMask = [.width, .height]
        destination.addSubview(video)
    }

    @objc private func restoreVideo() { window?.close() }

    @objc private func changePin(_ sender: NSButton) {
        keepOnTop = sender.state == .on
        window?.level = keepOnTop ? .floating : .normal
    }
}

private final class VideoPresentationWindow: NSWindow {
    var togglePlayback: (() -> Void)?
    private weak var fullscreenExit: NSButton?
    private var hideExit: Task<Void, Never>?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func configureFullscreenExit(_ button: NSButton) {
        fullscreenExit = button
        acceptsMouseMovedEvents = true
        revealFullscreenExit()
    }

    func stopTrackingFullscreenExit() {
        hideExit?.cancel()
        hideExit = nil
        fullscreenExit = nil
    }

    private func revealFullscreenExit() {
        guard let button = fullscreenExit else { return }
        button.isHidden = false
        hideExit?.cancel()
        hideExit = Task { [weak button] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            button?.isHidden = true
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved || event.type == .leftMouseDragged ||
            event.type == .rightMouseDragged || event.type == .otherMouseDragged {
            revealFullscreenExit()
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close()
        case 49: if !event.isARepeat { togglePlayback?() }
        default: super.keyDown(with: event)
        }
    }
}

struct MacVideoSurface<Drawable: NSView>: NSViewRepresentable {
    let presentation: MacVideoPresentation
    let make: () -> Drawable
    let release: (Drawable) -> Void
    let togglePlayback: () -> Void

    final class Coordinator {
        let presentation: MacVideoPresentation
        let release: (Drawable) -> Void
        var drawable: Drawable?

        init(presentation: MacVideoPresentation, release: @escaping (Drawable) -> Void) {
            self.presentation = presentation
            self.release = release
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(presentation: presentation, release: release) }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        let drawable = make()
        context.coordinator.drawable = drawable
        presentation.attach(drawable, to: host, togglePlayback: togglePlayback)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {}

    static func dismantleNSView(_ host: NSView, coordinator: Coordinator) {
        coordinator.presentation.detach(from: host)
        if let drawable = coordinator.drawable { coordinator.release(drawable) }
        coordinator.drawable = nil
    }
}
#endif
