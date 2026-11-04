import AppKit

/// A selection-like gesture, in global CG coordinates (top-left origin).
enum Gesture {
    case drag(from: CGPoint, to: CGPoint)
    case word(CGPoint)  // double-click
    case line(CGPoint)  // triple-click

    /// Where the selection starts: the first letter in reading order. For a drag that's whichever end is higher
    /// on screen (or further left on the same line); you can drag backwards. For double/triple-click it's the
    /// click point: finding the word's first letter would mean reading the screen before you click the icon,
    /// which we deliberately don't do (CONTEXT.md §6).
    var start: CGPoint {
        switch self {
        case let .drag(a, b):
            let sameLine = abs(a.y - b.y) < 8
            return sameLine ? (a.x <= b.x ? a : b) : (a.y < b.y ? a : b)
        case let .word(p), let .line(p): return p
        }
    }
}

/// Infers selections from mouse gestures only. No text is read here (see CONTEXT.md §6 Selection Flow).
final class SelectionWatcher {
    var onGesture: ((Gesture) -> Void)?
    var onDismiss: (() -> Void)?

    private var downPoint: CGPoint = .zero
    private var monitors: [Any] = []
    private let minDragDistance: CGFloat = 6

    func start() {
        // Global monitors never see events aimed at Mist's own panels, so clicking the icon doesn't dismiss it.
        add(.leftMouseDown) { [weak self] e in
            self?.downPoint = e.cgEvent?.location ?? .zero
            self?.onDismiss?()
        }
        add(.leftMouseUp) { [weak self] e in
            guard let self, let up = e.cgEvent?.location else { return }
            if hypot(up.x - downPoint.x, up.y - downPoint.y) > minDragDistance {
                guard !Self.isWindowChrome(downPoint) else { return } // moving a window or a scrollbar, not selecting
                onGesture?(.drag(from: downPoint, to: up))
            } else if e.clickCount == 2 {
                onGesture?(.word(up))
            } else if e.clickCount >= 3 {
                onGesture?(.line(up))
            }
        }
        add([.keyDown, .scrollWheel]) { [weak self] _ in self?.onDismiss?() }
    }

    /// True if a drag started on a title bar / tab strip (top 30 pt) or a scrollbar (right 16 pt) of the window
    /// under the cursor. Uses window frames only; no pixels or text are read.
    static func isWindowChrome(_ p: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 { // front to back; normal windows only
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.contains(p) else { continue }
            return p.y - r.minY < 30 || r.maxX - p.x < 16
        }
        return false
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
    }
}
