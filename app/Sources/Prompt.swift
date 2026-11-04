import Foundation

/// R8: default is one easy paragraph. Becomes user-configurable in Phase 1/2.
enum PromptBuilder {
    static let answerStyle = """
    Keep it short and easy to scan: usually 2–4 sentences. Bold the one or two key terms. \
    Use a short bulleted list only for steps or a few distinct points. No headings, no preamble, \
    and go longer only if the user asks. Write maths and chemistry with Unicode (x², √x, ½, ≈, →, α, H₂O), \
    not LaTeX.
    """

    static let system = """
    You are Mist, a study buddy built into the user's Mac. The user is reading and wants to understand \
    something quickly without leaving their document. \(answerStyle) Use plain language and define jargon. \
    Captured text comes from OCR and may contain small errors; work with the most likely reading. \
    Don't invent specifics about people, institutions, dates or numbers that aren't in the text: if the text \
    doesn't say and you aren't sure, say so briefly instead of guessing.
    """

    static var searchSystem: String { system + """
     Today is \(today). Web excerpts are provided as numbered sources, found by an automatic search, so some may be about \
    something else. Use a source only if it clearly matches what the user is reading: for people, a shared name \
    is not enough, the source must match the context (field, institution, details in the text). Never claim the \
    text refers to a source's subject unless the text itself confirms it. Put [n] right after each sentence that \
    uses source n. If no source clearly matches, say the search didn't find a confident match and answer from \
    the selected text alone. If several sources disagree on a current fact, prefer the most recent one.
    """ }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: Date())
    }

    /// Today's date is included because the model only knows its training-time date: asked for a current interest
    /// rate, it added a stale year to the query and pulled two-year-old articles.
    static var queryWriter: String { """
    You write web search queries. Today is \(today). Reply with only the query: 3–8 words naming exactly what \
    the user wants to know (the concept, theorem, product, problem or topic). Don't add a year unless the user \
    gave one; for current facts use words like "current" or "latest". No quotes, no explanation.
    """ }

    static func queryRequest(selection: String, question: String) -> String {
        selection.isEmpty ? "Question: \(question)" : "Selected text: \(selection)\nQuestion: \(question)"
    }

    /// Appends numbered sources to a user turn.
    static func withSources(_ parts: [Part], _ docs: [SourceDoc]) -> [Part] {
        guard !docs.isEmpty else {
            return parts + [.text("(Web search found nothing relevant. Answer from your own knowledge, say so in one short clause, and don't use [n] citations.)")]
        }
        let listed = docs.enumerated().map { i, d in "[\(i + 1)] \(d.title)\n\(d.text)" }.joined(separator: "\n\n")
        return parts + [.text("Sources:\n\(listed)")]
    }

    /// `strip` is the screenshot of the screen area around a selection. Sent with the OCR text because Vision OCR
    /// garbles maths: on an exam paper "d²y/dx² + 9y = sin(3x)" came out as "2v + 9y = sin(3z),)".
    static func firstTurn(context: AskContext, source: Source, question: String, strip: Data? = nil) -> [Part] {
        var where_ = source.app.isEmpty ? "" : "App: \(source.app)"
        if !source.window.isEmpty { where_ += " — window: \"\(source.window)\"" }

        switch context {
        case let .text(s) where !s.isEmpty && strip != nil:
            return [.text("""
            \(where_)
            Selected text (read by OCR, which often garbles formulas and symbols):
            \"\"\"
            \(s)
            \"\"\"
            Attached: an image of the screen area around the selection. The image is authoritative: read the \
            selected passage (the part matching the OCR text) and every formula from the image, not from the OCR.

            Question: \(question)
            """), .image(png: strip!)]
        case let .text(s) where !s.isEmpty:
            return [.text("""
            \(where_)
            Selected text:
            \"\"\"
            \(s)
            \"\"\"

            Question: \(question)
            """)]
        case let .image(png):
            return [.text("""
            \(where_)
            The user took a screenshot of part of their screen (attached).

            Question: \(question)
            """), .image(png: png)]
        default:
            return [.text(question)]
        }
    }
}
