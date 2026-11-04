import AppKit
import Carbon.HIToolbox

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

/// Where the user was reading (R6: app name and doc title when useful).
struct Source {
    var app = ""
    var window = ""

    static func current(_ front: NSRunningApplication?) -> Source {
        guard let front else { return Source() }
        let ax = AXUIElementCreateApplication(front.processIdentifier)
        var win: CFTypeRef?, title: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success {
            AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title)
        }
        return Source(app: front.localizedName ?? "", window: title as? String ?? "")
    }
}

/// Coordinates the shell: gestures → icon → capture → panel → model.
final class Mist {
    private struct Session {
        var mode = ""
        var context: AskContext = .none
        var source = Source()
        var turns: [Turn] = []
        var strip: Data? // PNG of the area around a selection, sent with the OCR text
        var captureMs: Double?
        var ocrMs: Double?
    }

    private let watcher = SelectionWatcher()
    private let icon = IconPanel()
    private let ask = AskPanel()
    private let model: ModelAdapter?
    private let local = LMStudioAdapter.fromEnvironment()
    private var lastProvider: String? // which search answered, shown with the sources
    private var lastGesture: Gesture?
    private var session = Session()
    private var streamTask: Task<Void, Never>?
    private var streaming = false

    init(model: ModelAdapter?) { self.model = model }

    func start() {
        watcher.onGesture = { [weak self] g in
            guard let self, !self.isOnMist(g) else { return }
            self.lastGesture = g
            self.icon.show(at: g.start)
        }
        watcher.onDismiss = { [weak self] in self?.icon.hide() }
        icon.onClick = { [weak self] in self?.askAboutSelection() }
        ask.onSubmit = { [weak self] q, search in self?.submit(q, search: search) }
        ask.onClose = { [weak self] in // drop the conversation and its images from memory once the panel closes
            self?.streamTask?.cancel()
            self?.session = Session()
        }

        Hotkeys.install()
        Hotkeys.register(key: kVK_Space, modifiers: controlKey | optionKey, id: 1) { [weak self] in self?.askGeneral() }
        Hotkeys.register(key: kVK_ANSI_X, modifiers: controlKey | optionKey, id: 2) { [weak self] in self?.askAboutRegion() }
        watcher.start()
    }

    // MARK: - Entry points

    private func askAboutSelection() {
        guard let g = lastGesture else { return }
        let front = NSWorkspace.shared.frontmostApplication
        icon.hide()
        let rect = Capture.band(for: g, window: front.flatMap { Capture.frontWindowFrame(pid: $0.processIdentifier) })
        begin(mode: "selection", context: .loading, source: .current(front))
        ask.show(avoiding: rect) // opens immediately; text fills in when OCR finishes

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000) // let the icon leave the screen before capturing
            do {
                let t0 = nowMs()
                let image = try await Capture.screenshot(rect)
                let t1 = nowMs()
                let lines = try await Task.detached { try Capture.recognize(image, in: rect) }.value
                let text = Capture.select(lines, for: g)
                let t2 = nowMs()
                self.session.captureMs = t1 - t0
                self.session.ocrMs = t2 - t1
                self.session.context = .text(text)
                self.session.strip = Capture.png(image)
                self.ask.setContext(.text(text))
                self.ask.setStatus(self.timingLine())
                if text.isEmpty { self.ask.setStatus("No text found there. Type or paste it above, or use Ctrl+Option+X.") }
            } catch {
                self.session.context = .text("")
                self.ask.setContext(.text(""))
                self.ask.setStatus("Capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func askGeneral() {
        icon.hide()
        begin(mode: "general", context: .none, source: .current(NSWorkspace.shared.frontmostApplication))
        ask.show(avoiding: mouseRect())
    }

    private func askAboutRegion() {
        icon.hide()
        ask.hide()
        let source = Source.current(NSWorkspace.shared.frontmostApplication)
        Task { @MainActor in
            guard let png = await Capture.interactiveScreenshot() else { return } // Esc cancels
            self.begin(mode: "region", context: .image(png), source: source)
            self.ask.show(avoiding: self.mouseRect())
        }
    }

    // MARK: - Asking

    private func begin(mode: String, context: AskContext, source: Source) {
        streamTask?.cancel()
        streaming = false
        session = Session(mode: mode, context: context, source: source)
        ask.reset(context: context)
        ask.setSource(app: source.app, window: source.window)
    }

    /// Enter → Gemini. Search (🌐 / Cmd+Enter) → Wikipedia + local model, citing sources.
    private func submit(_ raw: String, search: Bool) {
        if case .loading = session.context { return }
        guard !streaming else { return }
        let adapter: ModelAdapter
        if search {
            adapter = local
        } else if let model {
            adapter = model
        } else {
            ask.appendError("No Gemini API key. Put it in ~/.config/mist/gemini_key or set GEMINI_API_KEY.")
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = trimmed.isEmpty ? "Explain this." : trimmed
        if case .text = session.context { session.context = .text(ask.contextText) } // keep the user's OCR corrections

        let isFirst = session.turns.isEmpty
        ask.beginAnswer(question: question, followUp: !isFirst)
        streaming = true
        streamTask = Task { @MainActor in
            var searchMs: Double?
            var docs: [SourceDoc] = []
            if search {
                self.ask.setStatus("Searching the web…")
                let t = nowMs()
                docs = await self.findSources(question: question)
                searchMs = nowMs() - t
            }

            var parts = isFirst
                ? PromptBuilder.firstTurn(context: self.session.context, source: self.session.source, question: question,
                                          strip: self.session.strip)
                : [.text(question)]
            if search { parts = PromptBuilder.withSources(parts, docs) }
            self.session.turns.append(Turn(role: "user", parts: parts))
            let turns = self.session.turns
            if ProcessInfo.processInfo.environment["MIST_DEBUG"] != nil { self.debugPrint(turns) }

            let start = nowMs()
            var firstToken: Double?
            var full = ""
            do {
                let system = search ? PromptBuilder.searchSystem : PromptBuilder.system
                for try await chunk in adapter.stream(system: system, turns: turns) {
                    if firstToken == nil {
                        firstToken = nowMs() - start
                        self.ask.setStatus(self.timingLine(searchMs: searchMs, firstToken: firstToken))
                    }
                    full += chunk
                    self.ask.appendAnswer(chunk)
                }
                if search { self.ask.showSources(docs, provider: self.lastProvider) }
                self.session.turns.append(Turn(role: "model", parts: [.text(full)]))
                Timings.log(mode: self.session.mode + (search ? "+wiki" : ""), app: self.session.source.app,
                            captureMs: self.session.captureMs, ocrMs: self.session.ocrMs, searchMs: searchMs,
                            firstTokenMs: firstToken, totalMs: nowMs() - start, chars: full.count)
            } catch {
                if !Task.isCancelled {
                    self.ask.appendError(error.localizedDescription)
                    Timings.logError(mode: self.session.mode + (search ? "+search" : ""), app: self.session.source.app,
                                     hadImage: self.session.strip != nil, message: error.localizedDescription)
                }
                self.session.turns.removeLast() // drop the unanswered question so turns stay paired
            }
            self.streaming = false
        }
    }

    /// Local model turns selection + question into a short query; falls back to a plain one if that fails.
    private func findSources(question: String) async -> [SourceDoc] {
        var selected = ""
        if case let .text(s) = session.context { selected = String(s.prefix(600)) }
        let fallback = question == "Explain this." && !selected.isEmpty
            ? selected.split(separator: " ").prefix(8).joined(separator: " ")
            : question
        let query = (try? await local.complete(system: PromptBuilder.queryWriter,
                                               user: PromptBuilder.queryRequest(selection: selected, question: question),
                                               maxTokens: 20))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n.")) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        // Exa first; Wikipedia if Exa is missing, failing or out of credit.
        let context = selected // the filter checks sources against what you're reading; a bare question has too few clues
        var provider = "Exa"
        var found: [SourceDoc] = []
        do {
            found = try await Exa.search(query)
        } catch {
            print("Exa unavailable (\(error.localizedDescription)); falling back to Wikipedia")
        }
        var kept = Wikipedia.relevant(found, context: context, query: query)
        if kept.isEmpty {
            provider = "Wikipedia"
            found = (try? await Wikipedia.search(query)) ?? []
            kept = Wikipedia.relevant(found, context: context, query: query)
        }
        print("search query: \(query) [\(provider)] → \(found.map(\.title)) kept \(kept.map(\.title))")
        lastProvider = kept.isEmpty ? nil : provider
        return kept
    }

    // MARK: - Helpers

    /// MIST_DEBUG=1 prints exactly what is sent to the model (terminal only, nothing stored).
    private func debugPrint(_ turns: [Turn]) {
        print("\n----- prompt sent to model -----")
        for t in turns {
            for p in t.parts {
                switch p {
                case let .text(s): print("[\(t.role)] \(s)")
                case let .image(png): print("[\(t.role)] <image \(png.count / 1024) KB>")
                }
            }
        }
        print("--------------------------------")
    }

    /// Timings go to timings.csv; the panel only shows them with MIST_DEBUG set.
    private func timingLine(searchMs: Double? = nil, firstToken: Double? = nil) -> String {
        guard ProcessInfo.processInfo.environment["MIST_DEBUG"] != nil else { return "" }
        var parts: [String] = []
        if let c = session.captureMs { parts.append(String(format: "capture %.0f ms", c)) }
        if let o = session.ocrMs { parts.append(String(format: "OCR %.0f ms", o)) }
        if let s = searchMs { parts.append(String(format: "search %.0f ms", s)) }
        if let f = firstToken { parts.append(String(format: "first word %.0f ms", f)) }
        return parts.joined(separator: " · ")
    }

    /// Selecting text inside the ask panel (e.g. the answer) shouldn't summon the icon.
    private func isOnMist(_ g: Gesture) -> Bool {
        guard let frame = ask.visibleFrame else { return false }
        let points: [CGPoint]
        switch g {
        case let .drag(a, b): points = [a, b]
        case let .word(p), let .line(p): points = [p]
        }
        return points.contains { frame.contains(cocoaRect(CGRect(origin: $0, size: .zero)).origin) }
    }

    private func mouseRect() -> CGRect {
        let p = CGEvent(source: nil)?.location ?? .zero
        return CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)
    }
}

/// Appends one row per answered question to timings.csv (feeds Phase 0 tests 2 and 4).
enum Timings {
    static let path = "timings.csv"

    static let header = "time,mode,app,capture_ms,ocr_ms,first_token_ms,total_ms,answer_chars,search_ms"

    /// errors.log: time, mode, app, whether an image was sent, and the error text. Never the question or selection.
    static func logError(mode: String, app: String, hadImage: Bool, message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(mode) \(app) image=\(hadImage) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        print("ERROR: " + line, terminator: "")
        if !FileManager.default.fileExists(atPath: "errors.log") { FileManager.default.createFile(atPath: "errors.log", contents: nil) }
        guard let h = FileHandle(forWritingAtPath: "errors.log") else { return }
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    }

    static func log(mode: String, app: String, captureMs: Double?, ocrMs: Double?, searchMs: Double?,
                    firstTokenMs: Double?, totalMs: Double, chars: Int) {
        let f = { (v: Double?) in v.map { String(format: "%.0f", $0) } ?? "" }
        let row = [ISO8601DateFormatter().string(from: Date()), mode, app.replacingOccurrences(of: ",", with: " "),
                   f(captureMs), f(ocrMs), f(firstTokenMs), f(totalMs), "\(chars)", f(searchMs)].joined(separator: ",") + "\n"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: (header + "\n").data(using: .utf8))
        } else if let existing = try? String(contentsOfFile: path, encoding: .utf8), !existing.hasPrefix(header) {
            // Older files lack search_ms; upgrade the header (old rows just leave it empty).
            let body = existing.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
            try? (header + "\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(row.data(using: .utf8)!)
        h.closeFile()
        print(row, terminator: "")
    }
}
