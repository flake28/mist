import AppKit
import ScreenCaptureKit
import Vision

struct Word {
    let text: String
    let box: CGRect // global CG coords
}

struct Line {
    let words: [Word]
    let box: CGRect
}

/// Screen capture + Apple Vision OCR. All rects are global CG coordinates (top-left origin).
enum Capture {
    /// Vertical padding around the gesture, enough for large headings.
    static let pad: CGFloat = 40

    static func frontWindowFrame(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary) {
                return r // list is front-to-back, so the first match is the frontmost window
            }
        }
        return nil
    }

    /// The strip of screen to OCR for a gesture. Kept small: less area means faster OCR.
    static func band(for g: Gesture, window: CGRect?) -> CGRect {
        let bounds = window ?? CGDisplayBounds(CGMainDisplayID())
        let r: CGRect
        switch g {
        case let .drag(a, b):
            let top = min(a.y, b.y) - pad, height = abs(a.y - b.y) + 2 * pad
            if abs(a.y - b.y) < 12 { // single line
                r = CGRect(x: min(a.x, b.x) - 120, y: top, width: abs(a.x - b.x) + 240, height: height)
            } else {
                r = CGRect(x: bounds.minX, y: top, width: bounds.width, height: height)
            }
        case let .word(p):
            r = CGRect(x: p.x - 200, y: p.y - pad, width: 400, height: 2 * pad)
        case let .line(p):
            r = CGRect(x: bounds.minX, y: p.y - pad, width: bounds.width, height: 2 * pad)
        }
        let clipped = r.intersection(bounds)
        return (clipped.isNull || clipped.isEmpty ? r : clipped).integral
    }

    /// PNG for the model, at most `maxWidth` px wide: a Retina strip is ~2400 px, and the local model's time to
    /// first word grows with image size (measured on an exam-paper strip).
    static func png(_ image: CGImage, maxWidth: Int = 1280) -> Data? {
        var img = image
        if image.width > maxWidth {
            let h = Int(Double(image.height) * Double(maxWidth) / Double(image.width))
            if let ctx = CGContext(data: nil, width: maxWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
                img = ctx.makeImage() ?? image
            }
        }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func screenshot(_ rect: CGRect) async throws -> CGImage {
        try await SCScreenshotManager.captureImage(in: rect)
    }

    /// Uses the system's own region picker. Returns PNG data, or nil if the user pressed Esc.
    static func interactiveScreenshot() async -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mist-\(UUID().uuidString).png")
        let ran: Bool = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", url.path]
            p.terminationHandler = { _ in cont.resume(returning: true) }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        return ran ? try? Data(contentsOf: url) : nil
    }

    /// OCR into lines of words with screen-space boxes, sorted top to bottom.
    static func recognize(_ image: CGImage, in rect: CGRect) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])

        // Vision boxes are normalized with a bottom-left origin.
        func toScreen(_ n: CGRect) -> CGRect {
            CGRect(x: rect.minX + n.minX * rect.width, y: rect.minY + (1 - n.maxY) * rect.height,
                   width: n.width * rect.width, height: n.height * rect.height)
        }

        return (request.results ?? []).compactMap { obs -> Line? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let s = candidate.string
            var words: [Word] = []
            var i = s.startIndex
            while i < s.endIndex {
                if s[i].isWhitespace { i = s.index(after: i); continue }
                var j = i
                while j < s.endIndex && !s[j].isWhitespace { j = s.index(after: j) }
                if let box = try? candidate.boundingBox(for: i..<j)?.boundingBox {
                    words.append(Word(text: String(s[i..<j]), box: toScreen(box)))
                }
                i = j
            }
            return words.isEmpty ? nil : Line(words: words, box: toScreen(obs.boundingBox))
        }
        .sorted { $0.box.midY < $1.box.midY }
    }

    /// Picks the words the gesture most likely selected.
    static func select(_ lines: [Line], for g: Gesture) -> String {
        guard !lines.isEmpty else { return "" }

        func distance(_ box: CGRect, _ p: CGPoint) -> CGFloat {
            hypot(max(box.minX - p.x, 0, p.x - box.maxX), max(box.minY - p.y, 0, p.y - box.maxY))
        }
        // Prefer lines that horizontally contain the point (multi-column pages), then the vertically closest.
        func nearestLine(_ p: CGPoint) -> Int {
            func score(_ l: Line) -> CGFloat {
                abs(l.box.midY - p.y) + (l.box.minX - 20 <= p.x && p.x <= l.box.maxX + 20 ? 0 : 1000)
            }
            return lines.indices.min { score(lines[$0]) < score(lines[$1]) }!
        }
        func text(_ words: [Word]) -> String { words.map(\.text).joined(separator: " ") }

        switch g {
        case let .word(p):
            return lines[nearestLine(p)].words.min { distance($0.box, p) < distance($1.box, p) }?.text ?? ""

        case let .line(p):
            return text(lines[nearestLine(p)].words)

        case let .drag(a, b):
            var (start, end) = a.y <= b.y ? (a, b) : (b, a)
            var s = nearestLine(start), e = nearestLine(end)
            if s == e {
                let lo = min(a.x, b.x), hi = max(a.x, b.x)
                return text(lines[s].words.filter { $0.box.maxX > lo && $0.box.minX < hi })
            }
            if s > e { swap(&s, &e); swap(&start, &end) }

            let column = lines[s].box.union(lines[e].box)
            var out: [String] = []
            for i in s...e {
                let line = lines[i]
                let isEdge = i == s || i == e
                if !isEdge && (line.box.maxX < column.minX || line.box.minX > column.maxX) { continue } // other column
                var words = line.words
                if i == s { words = words.filter { $0.box.maxX > start.x } }
                if i == e { words = words.filter { $0.box.minX < end.x } }
                if !words.isEmpty { out.append(text(words)) }
            }
            return joinLines(out)
        }
    }

    /// Joins visual lines into flowing text, undoing end-of-line hyphenation.
    private static func joinLines(_ lines: [String]) -> String {
        lines.reduce("") { acc, line in
            if acc.isEmpty { return line }
            if acc.hasSuffix("-") && acc.count > 1 { return String(acc.dropLast()) + line }
            return acc + " " + line
        }
    }
}
