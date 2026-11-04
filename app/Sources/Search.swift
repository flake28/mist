import Foundation

struct SourceDoc {
    let title: String
    let url: String
    let text: String
}

struct SearchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// General web search via Exa (own index, returns page text). Free tier, from its pricing page 2026-11-03:
/// $10 credit renewed monthly, no card; lite search $4/1k + $1/1k pages of highlights → ~1,400 searches/month.
/// Out of credit is HTTP 402; callers fall back to Wikipedia.
enum Exa {
    static var apiKey: String? {
        let env = ProcessInfo.processInfo.environment["EXA_API_KEY"]
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mist/exa_key")
        let key = env ?? (try? String(contentsOf: file, encoding: .utf8))
        return key.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func search(_ query: String, limit: Int = 3) async throws -> [SourceDoc] {
        guard let key = apiKey else { throw SearchError(message: "no Exa key") }
        var request = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Request shape follows Exa's build-with-exa skill (v0.3.0): /search + highlights, nothing decorative.
        // - type "lite": the skill's choice for latency-sensitive real-time UX (R5); also $4/1k vs $7/1k for auto.
        // - numResults and highlights.maxCharacters are deliberate budgets: every source character delays the
        //   local 4B model's first word, so 3 results × ≤1,500 chars (the skill advises ≥ ~400).
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "type": "lite", "numResults": limit,
            "contents": ["highlights": ["maxCharacters": Wikipedia.maxCharsPerArticle]],
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let reason = status == 402 ? "out of free credit for this month" : "HTTP \(status)"
            throw SearchError(message: "Exa \(reason): \(json["error"] as? String ?? "")")
        }
        return (json["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            let highlights = (r["highlights"] as? [String] ?? []).joined(separator: " … ")
            let text = (highlights.isEmpty ? (r["text"] as? String ?? "") : highlights)
            guard !text.isEmpty else { return nil }
            let title = (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: url)?.host ?? url
            return SourceDoc(title: title, url: url,
                             text: String(text.prefix(Wikipedia.maxCharsPerArticle)))
        }
    }
}

/// Wikipedia retrieval: one API call returns the top articles' intros as plain text.
/// (ProofWiki was the other candidate, but it blocks API clients behind a bot check: HTTP 403, 2026-11-03.)
enum Wikipedia {
    static let maxCharsPerArticle = 1500

    static func search(_ query: String, limit: Int = 3) async throws -> [SourceDoc] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            "action": "query", "generator": "search", "gsrsearch": query, "gsrlimit": "\(limit)",
            "prop": "extracts|info", "exintro": "1", "explaintext": "1", "exlimit": "\(limit)",
            "inprop": "url", "format": "json", "formatversion": "2",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        // Wikimedia asks API clients to identify themselves.
        request.setValue("Mist/0.1 (personal study prototype)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [[String: Any]]
        else { return [] }

        return pages
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) } // search rank
            .compactMap { page in
                guard let title = page["title"] as? String, let extract = page["extract"] as? String else { return nil }
                let text = String(clean(extract).prefix(maxCharsPerArticle))
                guard !text.isEmpty, !text.contains("may refer to:") else { return nil } // skip disambiguation pages
                return SourceDoc(title: title, url: page["fullurl"] as? String ?? "", text: text)
            }
    }

    /// Keeps sources that share at least two meaningful words with what the user is reading, beyond the
    /// search terms. Stops name collisions: a lecturer's name in lecture notes matched unrelated, better-known
    /// people with the same name, and the small model then presented them as the lecturer.
    /// With too little context to check against, sources are kept as-is. Callers pass only the selected text:
    /// in the Exa test (2026-11-03) also counting question words dropped good sources for 5 of 20 plain questions.
    static func relevant(_ docs: [SourceDoc], context: String, query: String) -> [SourceDoc] {
        let queryWords = words(query)
        let clues = words(context).subtracting(queryWords)
        guard clues.count >= 2 else { return docs }
        return docs.filter { words($0.title + " " + $0.text).intersection(clues).count >= 2 }
    }

    private static let stopwords: Set<String> = [
        "this", "that", "these", "those", "with", "from", "into", "onto", "than", "then", "there", "their", "they",
        "what", "which", "when", "where", "while", "whose", "about", "above", "after", "before", "between", "such",
        "some", "each", "other", "also", "only", "very", "more", "most", "much", "many", "have", "does", "doing",
        "been", "being", "were", "will", "would", "could", "should", "explain", "mean", "means", "here", "just",
        "like", "make", "made", "over", "under", "your", "yours", "please", "tell", "give", "show", "text",
    ]

    /// Lowercased content words of 4+ letters, with a crude plural strip.
    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .split { !$0.isLetter }
            .map { $0.count > 4 && $0.hasSuffix("s") ? String($0.dropLast()) : String($0) }
            .filter { $0.count >= 4 && !stopwords.contains($0) })
    }

    /// Plain-text extracts render each formula as a column of 1–3 character lines followed by its LaTeX source,
    /// e.g. "\n J \n s \n , \n k ... {\displaystyle J_{s,k}(X)}". Keep only the LaTeX, converted to Unicode.
    static func clean(_ extract: String) -> String {
        var s = extract
        let marker = "{\\displaystyle"
        while let start = s.range(of: marker) {
            // Find the matching closing brace.
            var depth = 0
            var end = start.lowerBound
            var i = start.lowerBound
            while i < s.endIndex {
                if s[i] == "{" { depth += 1 }
                if s[i] == "}" { depth -= 1; if depth == 0 { end = s.index(after: i); break } }
                i = s.index(after: i)
            }
            guard end > start.lowerBound else { break }
            let latex = String(s[start.upperBound..<s.index(before: end)])

            // Walk back over the exploded rendering: lines that are blank or only a few characters.
            var from = start.lowerBound
            let before = s[..<start.lowerBound]
            var lines = before.split(separator: "\n", omittingEmptySubsequences: false)
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).count <= 3, lines.count > 1 {
                lines.removeLast()
                from = s.index(from, offsetBy: -(last.count + 1))
            }
            s.replaceSubrange(from..<end, with: " " + LaTeX.toUnicode(latex).trimmingCharacters(in: .whitespaces) + " ")
        }
        return s
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ?\n ?"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
