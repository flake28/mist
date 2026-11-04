import AppKit

/// Converts a global CG rect (top-left origin) to Cocoa screen coordinates (bottom-left origin).
func cocoaRect(_ r: CGRect) -> NSRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

/// A bare cloud just above-left of the selection's first letter. Never takes focus; fades if ignored.
final class IconPanel: NSPanel {
    var onClick: (() -> Void)?

    private let size: CGFloat = 22
    private let idleSeconds = 2.5
    private var fadeTimer: Timer?
    private var generation = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true // follows the cloud's shape, keeps it visible on any background
        ignoresMouseEvents = false // clicks on the cloud's transparent edges still count
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = IconView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.onClick = { [weak self] in self?.onClick?() }
        view.onHover = { [weak self] inside in inside ? self?.fadeTimer?.invalidate() : self?.scheduleFade() }
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(at cgPoint: CGPoint) {
        generation += 1
        // cgPoint is where the selection starts (mid-height of the first letter's line). Put the cloud's
        // bottom-right corner at that letter's top-left: left of it by the icon width, above by ~half a line.
        let halfLine: CGFloat = 9
        let p = cocoaRect(CGRect(origin: cgPoint, size: .zero)).origin
        var origin = NSPoint(x: p.x - size + 2, y: p.y + halfLine)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) { // keep it on screen
            origin.x = min(max(origin.x, screen.frame.minX + 2), screen.frame.maxX - size - 2)
            origin.y = min(max(origin.y, screen.frame.minY + 2), screen.frame.maxY - size - 2)
        }
        setFrameOrigin(origin)
        alphaValue = 1
        orderFrontRegardless()
        scheduleFade()
    }

    func hide() {
        generation += 1
        fadeTimer?.invalidate()
        orderOut(nil)
    }

    private func scheduleFade() {
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: idleSeconds, repeats: false) { [weak self] _ in self?.fadeOut() }
    }

    private func fadeOut() {
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == gen else { return } // re-shown mid-fade
            self.orderOut(nil)
        })
    }
}

private final class IconView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let image = NSImageView(frame: bounds)
        image.image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "Ask Mist")
        image.contentTintColor = .controlAccentColor
        image.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        addSubview(image)

        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
