import AppKit

enum AskContext {
    case none
    case loading
    case text(String)
    case image(Data) // PNG
}

/// Non-activating panel that can still take typing (the Spotlight pattern): the reading app stays active.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() } // Esc

    /// Mist has no menu bar (accessory app), and in AppKit Cmd+C/V/X/A/Z normally come from the Edit menu.
    /// Without this, copying an answer or pasting a question silently does nothing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        let action: Selector?
        switch (key, mods.contains(.shift)) {
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Minimal ask panel: a small header, the captured text as a quote, one question field; grows only as the
/// conversation does.
final class AskPanel: NSObject, NSWindowDelegate {
    /// (question, search): search is true for the 🌐 button or Cmd+Enter.
    var onSubmit: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    private let width: CGFloat = 420
    private let inset: CGFloat = 14
    private let maxContextHeight: CGFloat = 54 // ~3 lines, then scrolls
    private let maxAnswerHeight: CGFloat = 400

    private let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let stack = NSStackView()

    // Header: cloud + where the text came from + close.
    private let header = NSStackView()
    private let sourceLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let closeButton = NSButton()

    // Captured text as a quote (accent bar + text), or the screenshot.
    private let quote = NSView()
    private let quoteBar = NSView()
    private let contextScroll = NSTextView.scrollableTextView()
    private let imageView = NSImageView()

    // Question field in a rounded well.
    private let field = NSView()
    private let question = NSTextField()
    private let searchButton = NSButton()
    private let sendButton = NSButton()
    private let questionRow = NSStackView()

    private let divider = NSBox()
    private let answerScroll = NSTextView.scrollableTextView()
    private let status = NSTextField(labelWithString: "")
    private var contextHeight: NSLayoutConstraint!
    private var answerHeight: NSLayoutConstraint!
    private var waiting = false { didSet { waiting ? spinner.startAnimation(nil) : spinner.stopAnimation(nil); spinner.isHidden = !waiting } }

    /// The conversation shown in the answer area; re-rendered as a whole so Markdown formats correctly while streaming.
    private enum Segment {
        case question(String)
        case answer(String)
        case error(String)
        case sources([SourceDoc], provider: String?)
    }
    private var segments: [Segment] = []

    /// Placed below the selection → keep the top edge fixed and grow down; above → keep the bottom fixed and grow up.
    private var growsDown = true

    private var contextView: NSTextView { contextScroll.documentView as! NSTextView }
    private var answerView: NSTextView { answerScroll.documentView as! NSTextView }

    /// The (possibly user-corrected) captured text.
    var contextText: String { contextView.string }

    /// Screen frame (Cocoa coords) while visible, so gestures inside the panel can be ignored.
    var visibleFrame: NSRect? { panel.isVisible ? panel.frame : nil }

    override init() {
        super.init()
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        build()
    }

    private func build() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        panel.contentView = background

        // Purple wash over the blur: violet at the top-left fading to a deeper indigo-magenta, light enough that
        // text keeps its contrast in both light and dark mode.
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor(srgbRed: 0.55, green: 0.36, blue: 1.00, alpha: 0.42).cgColor,
            NSColor(srgbRed: 0.42, green: 0.25, blue: 0.85, alpha: 0.26).cgColor,
            NSColor(srgbRed: 0.72, green: 0.30, blue: 0.85, alpha: 0.20).cgColor,
        ]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 1) // layer coords: top-left
        gradient.endPoint = CGPoint(x: 1, y: 0)   // bottom-right
        let wash = NSView()
        wash.wantsLayer = true
        wash.layer = gradient
        wash.autoresizingMask = [.width, .height]
        wash.frame = background.bounds
        background.addSubview(wash)
        background.layer?.borderColor = NSColor(srgbRed: 0.65, green: 0.5, blue: 1, alpha: 0.35).cgColor

        // Header
        let cloud = NSImageView(image: NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)!)
        cloud.contentTintColor = Self.lavender
        cloud.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        sourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sourceLabel.textColor = Self.faintColor
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close (Esc)"
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for v in [cloud, sourceLabel, spacer, spinner, closeButton] { header.addArrangedSubview(v) }
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        // Quote
        for (scroll, view) in [(contextScroll, contextView), (answerScroll, answerView)] {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            view.drawsBackground = false
            view.isRichText = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
        }
        contextView.font = .systemFont(ofSize: 12.5)
        contextView.textColor = Self.quoteColor
        contextView.isEditable = true // OCR can be wrong; let the user fix it before asking
        answerView.isEditable = false
        answerView.isSelectable = true
        answerView.isRichText = true
        answerView.linkTextAttributes = [.foregroundColor: Self.lavender, .cursor: NSCursor.pointingHand]

        quoteBar.wantsLayer = true
        quoteBar.layer?.backgroundColor = Self.lavender.withAlphaComponent(0.7).cgColor
        quoteBar.layer?.cornerRadius = 1
        for v in [quoteBar, contextScroll] { v.translatesAutoresizingMaskIntoConstraints = false; quote.addSubview(v) }

        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignLeft
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true

        // Question field
        question.placeholderString = "Ask about this…"
        question.font = .systemFont(ofSize: 13.5)
        question.isBordered = false
        question.drawsBackground = false
        question.focusRingType = .none
        question.target = self
        question.action = #selector(submitQuestion)
        question.cell?.usesSingleLineMode = true
        question.cell?.wraps = false
        question.cell?.isScrollable = true
        question.toolTip = "↩ ask  ·  ⌘↩ search the web first"

        searchButton.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Search the web and answer")
        searchButton.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        searchButton.isBordered = false
        searchButton.contentTintColor = .secondaryLabelColor
        searchButton.toolTip = "Search the web, then answer with sources (⌘↩)"
        searchButton.target = self
        searchButton.action = #selector(searchQuestion)
        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Ask")
        sendButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            .applying(.init(paletteColors: [.white, .controlAccentColor])) // white arrow on an accent circle
        sendButton.isBordered = false
        sendButton.toolTip = "Ask (↩)"
        sendButton.target = self
        sendButton.action = #selector(sendQuestion)
        for v in [question, searchButton, sendButton] { questionRow.addArrangedSubview(v) }
        questionRow.orientation = .horizontal
        questionRow.spacing = 8
        questionRow.alignment = .centerY
        question.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        field.wantsLayer = true
        field.layer?.cornerRadius = 9
        field.layer?.cornerCurve = .continuous
        field.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        field.layer?.borderWidth = 0.5
        field.layer?.borderColor = NSColor.separatorColor.cgColor
        questionRow.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(questionRow)

        divider.boxType = .separator

        status.font = .systemFont(ofSize: 10.5)
        status.textColor = Self.faintColor
        status.lineBreakMode = .byTruncatingTail

        for v in [header, quote, imageView, field, divider, answerScroll, status] { stack.addArrangedSubview(v) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(12, after: field)
        stack.setCustomSpacing(12, after: divider)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        contextHeight = contextScroll.heightAnchor.constraint(equalToConstant: 0)
        answerHeight = answerScroll.heightAnchor.constraint(equalToConstant: 0)
        // Widths are set on each view itself, so they survive the stack detaching hidden views.
        var constraints = [
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            contextHeight!, answerHeight!,
            imageView.heightAnchor.constraint(equalToConstant: 84),
            quoteBar.leadingAnchor.constraint(equalTo: quote.leadingAnchor),
            quoteBar.topAnchor.constraint(equalTo: quote.topAnchor),
            quoteBar.bottomAnchor.constraint(equalTo: quote.bottomAnchor),
            quoteBar.widthAnchor.constraint(equalToConstant: 2.5),
            contextScroll.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 9),
            contextScroll.trailingAnchor.constraint(equalTo: quote.trailingAnchor),
            contextScroll.topAnchor.constraint(equalTo: quote.topAnchor, constant: 1),
            contextScroll.bottomAnchor.constraint(equalTo: quote.bottomAnchor, constant: -1),
            questionRow.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 10),
            questionRow.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -5),
            questionRow.topAnchor.constraint(equalTo: field.topAnchor, constant: 5),
            questionRow.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -5),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ]
        for v in stack.arrangedSubviews { constraints.append(v.widthAnchor.constraint(equalToConstant: width - 2 * inset)) }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Showing

    /// Places the panel next to `cgRect` (global CG coords) without covering it, so it stays out of the OCR capture.
    func show(avoiding cgRect: CGRect) {
        let target = cocoaRect(cgRect)
        let screen = NSScreen.screens.first { $0.frame.intersects(target) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let height = fittedHeight()

        // Below the selection if a full-grown panel would fit there, otherwise above it.
        growsDown = target.minY - 8 - visible.minY >= 200 || target.minY - visible.minY > visible.maxY - target.maxY
        let y = growsDown ? target.minY - 8 - height : target.maxY + 8
        let x = min(max(target.minX, visible.minX + 8), visible.maxX - width - 8)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        relayout()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(question)
    }

    func hide() { panel.orderOut(nil) }

    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func closePanel() { panel.close() }

    // MARK: - Content

    /// Header text: where the question comes from ("Safari · lecture-notes.pdf").
    func setSource(app: String, window: String) {
        sourceLabel.stringValue = [app, window].filter { !$0.isEmpty }.joined(separator: " · ")
        if sourceLabel.stringValue.isEmpty { sourceLabel.stringValue = "Mist" }
    }

    func reset(context: AskContext) {
        question.stringValue = ""
        segments = []
        answerView.string = ""
        status.stringValue = ""
        waiting = false
        setContext(context)
    }

    func setContext(_ context: AskContext) {
        quote.isHidden = true
        imageView.isHidden = true
        switch context {
        case .none:
            question.placeholderString = "Ask Mist anything…"
        case .loading:
            quote.isHidden = false
            contextView.string = "Reading the selection…"
            contextView.textColor = Self.faintColor
            waiting = true
        case let .text(s):
            quote.isHidden = false
            contextView.string = s
            contextView.textColor = Self.quoteColor
            waiting = false
            question.placeholderString = "Ask about this…"
        case let .image(png):
            imageView.isHidden = false
            imageView.image = NSImage(data: png)
            question.placeholderString = "Ask about this…"
        }
        relayout()
    }

    func setStatus(_ s: String) {
        status.stringValue = s
        relayout()
    }

    func beginAnswer(question q: String, followUp: Bool) {
        segments += [.question(q), .answer("")]
        waiting = true
        render()
    }

    func appendAnswer(_ chunk: String) {
        guard case let .answer(text)? = segments.last else { return }
        segments[segments.count - 1] = .answer(text + chunk)
        waiting = false
        render()
    }

    func showSources(_ docs: [SourceDoc], provider: String?) {
        segments.append(.sources(docs, provider: provider))
        render()
    }

    func appendError(_ message: String) {
        if case .answer("")? = segments.last { segments.removeLast() }
        segments.append(.error(message))
        waiting = false
        render()
    }

    private func render() {
        let out = NSMutableAttributedString()
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 2
        body.paragraphSpacing = 0
        for (i, segment) in segments.enumerated() {
            switch segment {
            case let .question(q):
                if i > 0 { out.append(NSAttributedString(string: "\n\n", attributes: [.font: NSFont.systemFont(ofSize: 7)])) }
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 4
                out.append(NSAttributedString(string: q, attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Self.quoteColor,
                    .paragraphStyle: style,
                ]))
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
            case let .answer(a):
                let md = NSMutableAttributedString(attributedString:
                    Markdown.render(a.trimmingCharacters(in: .whitespacesAndNewlines), size: 13.5, color: .labelColor))
                md.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: md.length)) { value, range, _ in
                    let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    style.lineSpacing = body.lineSpacing
                    md.addAttribute(.paragraphStyle, value: style, range: range)
                }
                out.append(md)
            case let .error(e):
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)])) }
                out.append(NSAttributedString(string: e, attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.systemRed, .paragraphStyle: body,
                ]))
            case let .sources(docs, provider):
                let small = NSFont.systemFont(ofSize: 11)
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
                let label = docs.isEmpty
                    ? "Web search found nothing reliable; this answer is from the model's own knowledge."
                    : "Sources · \(provider ?? "web")   "
                out.append(NSAttributedString(string: label,
                                              attributes: [.font: small, .foregroundColor: Self.faintColor]))
                for (n, doc) in docs.enumerated() {
                    var attrs: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: Self.lavender]
                    if let url = URL(string: doc.url) { attrs[.link] = url } // opens in the default browser
                    out.append(NSAttributedString(string: "\(n + 1). \(doc.title)", attributes: attrs))
                    if n < docs.count - 1 { out.append(NSAttributedString(string: "   ", attributes: [.font: small])) }
                }
            }
        }
        answerView.textStorage?.setAttributedString(out)
        relayout()
        answerView.scrollToEndOfDocument(nil)
    }

    @objc private func submitQuestion() {
        // Cmd+Enter searches; plain Enter asks directly.
        send(search: NSApp.currentEvent?.modifierFlags.contains(.command) ?? false)
    }

    @objc private func searchQuestion() { send(search: true) }
    @objc private func sendQuestion() { send(search: false) }

    private func send(search: Bool) {
        let q = question.stringValue
        question.stringValue = ""
        onSubmit?(q, search)
    }

    // MARK: - Sizing

    /// Light violet for accents on the purple wash (the system accent colour disappears against it).
    private static let lavender = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.80, green: 0.72, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.42, green: 0.25, blue: 0.85, alpha: 1)
    }
    private static let quoteColor = NSColor.labelColor.withAlphaComponent(0.72)
    private static let faintColor = NSColor.labelColor.withAlphaComponent(0.45)

    private func textHeight(_ view: NSTextView) -> CGFloat {
        guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    private func fittedHeight() -> CGFloat {
        status.isHidden = status.stringValue.isEmpty
        answerScroll.isHidden = answerView.string.isEmpty
        divider.isHidden = answerScroll.isHidden
        panel.contentView?.layoutSubtreeIfNeeded()
        contextHeight.constant = min(textHeight(contextView), maxContextHeight)
        answerHeight.constant = min(textHeight(answerView), maxAnswerHeight)
        return ceil(stack.fittingSize.height)
    }

    private func relayout() {
        let height = fittedHeight()
        var frame = panel.frame
        guard frame.height != height else { return }
        if growsDown { frame.origin.y = frame.maxY - height }
        frame.size.height = height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.y = min(max(frame.origin.y, visible.minY + 8), visible.maxY - height - 8)
        }
        panel.setFrame(frame, display: true)
    }
}
