import AppKit

/// Small Markdown renderer for answers: headings, bullets, numbered lists, and inline bold/italic/code.
/// Re-run on the whole answer for every streamed chunk, so half-written markup fixes itself once closed.
enum Markdown {
    private static let numbered = try! Regex(#"^(\d+)[.)]\s+"#)

    static func render(_ markdown: String, size: CGFloat, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = LaTeX.replaceMath(in: markdown).components(separatedBy: "\n") // math first, so its _ and * aren't read as emphasis

        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { // a blank line between paragraphs: a small gap, not a full empty line
                if i < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size * 0.4)])) }
                continue
            }
            var text = raw
            var font = NSFont.systemFont(ofSize: size)
            var marker = ""
            var indent: CGFloat = 0

            if trimmed.hasPrefix("#") {
                text = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                font = .systemFont(ofSize: size + 1, weight: .semibold)
            } else if ["- ", "* ", "• "].contains(where: { trimmed.hasPrefix($0) }) {
                marker = "•"
                text = String(trimmed.dropFirst(2))
                indent = 14
            } else if let match = trimmed.firstMatch(of: numbered), let number = match.output[1].substring {
                marker = "\(number)."
                text = String(trimmed[match.range.upperBound...])
                indent = 20
            }

            let para = NSMutableParagraphStyle()
            para.lineSpacing = 1.5
            para.paragraphSpacing = trimmed.isEmpty ? 0 : 4
            if indent > 0 {
                para.headIndent = indent // wrapped lines align with the text, not the marker
                para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }

            let line = NSMutableAttributedString()
            if !marker.isEmpty {
                line.append(NSAttributedString(string: marker + "\t", attributes: [.font: font, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.55)]))
            }
            line.append(inline(text, font: font, color: color))
            if i < lines.count - 1 { line.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        return out
    }

    private static func inline(_ s: String, font: NSFont, color: NSColor) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]) }

        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var f = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) : font
            var traits = f.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize) ?? f

            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
            if intent.contains(.code) { attrs[.backgroundColor] = NSColor.quaternaryLabelColor }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}
