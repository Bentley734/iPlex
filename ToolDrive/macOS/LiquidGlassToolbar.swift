import AppKit

private final class GlassMenuButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}

@available(macOS 26.0, *)
final class LiquidGlassToolbar: NSView {
    static let size: CGFloat = 44

    private let glass = NSGlassEffectView()
    private let controls = NSView()
    private let openButton = GlassMenuButton()
    private let onOpen: () -> Void

    init(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        appearance = NSAppearance(named: .darkAqua)
        glass.style = .regular
        glass.cornerRadius = Self.size / 2
        addSubview(glass)
        controls.wantsLayer = true
        controls.layer?.cornerCurve = .continuous
        glass.contentView = controls

        openButton.identifier = NSUserInterfaceItemIdentifier("catalog-menu")
        openButton.title = ""
        let glyph = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)
        openButton.image = glyph?.withSymbolConfiguration(.init(pointSize: 16, weight: .semibold))
        openButton.imagePosition = .imageOnly
        openButton.toolTip = "Menu"
        openButton.bezelStyle = .accessoryBarAction
        openButton.isBordered = false
        openButton.showsBorderOnlyWhileMouseInside = true
        openButton.focusRingType = .exterior
        openButton.setAccessibilityLabel("Menu")
        openButton.target = self
        openButton.action = #selector(openMenu)
        controls.addSubview(openButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(onOpen:)") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    override func layout() {
        super.layout()
        glass.frame = bounds
        controls.frame = glass.bounds
        controls.layer?.cornerRadius = glass.bounds.height / 2
        openButton.frame = controls.bounds
    }

    func focusMenu() { window?.makeFirstResponder(openButton) }
    @objc private func openMenu() { onOpen() }

    func update(theme: String, updatesReady: Bool, glassAccent: String, glassOpacity: Int) {
        let shade: CGFloat
        switch theme {
        case "night-shift":
            glass.tintColor = NSColor.systemOrange.withAlphaComponent(0.055)
            shade = 0.08
        case "laser-grid":
            glass.tintColor = NSColor.systemTeal.withAlphaComponent(0.065)
            shade = 0.48
        case "liquid-glass":
            let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let solid = highContrast || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            let accent = GlassAccent.choices.first { $0.id == glassAccent }
            if !highContrast, let hex = accent?.hex, let rgb = Int(hex.dropFirst(), radix: 16) {
                glass.tintColor = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                                          green: CGFloat((rgb >> 8) & 255) / 255,
                                          blue: CGFloat(rgb & 255) / 255, alpha: 0.20)
            } else {
                glass.tintColor = NSColor.systemIndigo.withAlphaComponent(0.065)
            }
            let step = CGFloat(glassOpacity - 50) / 50
            shade = solid ? 0.96 : 0.40 + step * (step < 0 ? 0.18 : 0.56)
        case "front-row":
            glass.tintColor = nil
            shade = 0.28
        default:
            glass.tintColor = nil
            shade = 0.08
        }
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(shade).cgColor
        openButton.setAccessibilityHelp(updatesReady ? "An update is ready." : nil)
    }
}
