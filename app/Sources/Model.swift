import Foundation

enum Part {
    case text(String)
    case image(png: Data)
}

struct Turn {
    let role: String // "user" | "model"
    let parts: [Part]
}

/// R10: every model call goes through this. Swapping providers = a new adapter, nothing else changes.
protocol ModelAdapter {
    func stream(system: String, turns: [Turn]) -> AsyncThrowingStream<String, Error>
}

struct ModelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Gemini via the Interactions API (POST /v1beta/interactions), stateless: the full history is resent each turn.
/// Measured 2026-11-02: gemini-3.6-flash with thinking "minimal" → first word ~0.9 s; default thinking → ~3.8 s.
struct GeminiAdapter: ModelAdapter {
    let apiKey: String
    /// Tried in order; the next is used when one is busy (503) or out of quota (429).
    /// Free-tier quotas are per model (gemini-3.6-flash: 20 requests/day, measured 2026-11-02).
    let models: [String]

    /// Seconds to wait for a model's first word before moving to the next (screenshots took up to ~6.5 s).
    static let firstWordDeadline: Double = 8
    static let imageFirstWordDeadline: Double = 15
    /// Seconds an answer that has already started may go silent before giving up.
    static let stallTimeout: Double = 30

    static let defaultModels = ["gemini-3.6-flash", "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.5-flash-lite"]

    /// Key from ~/.config/mist/gemini_key or GEMINI_API_KEY. MIST_MODEL puts a model first in line.
    static func fromEnvironment() -> GeminiAdapter? {
        let env = ProcessInfo.processInfo.environment
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mist/gemini_key")
        let key = env["GEMINI_API_KEY"] ?? (try? String(contentsOf: file, encoding: .utf8))
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        let models = ([env["MIST_MODEL"]].compactMap { $0 } + defaultModels).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return GeminiAdapter(apiKey: key, models: models)
    }

    func stream(system: String, turns: [Turn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lastError = ""
                    // Images take Gemini longer to start: a selection + strip took 6.2 s to the first word (2026-11-04).
                    let hasImage = turns.contains { $0.parts.contains { if case .image = $0 { return true }; return false } }
                    let deadline = hasImage ? Self.imageFirstWordDeadline : Self.firstWordDeadline
                    for model in models {
                        var response: Response
                        do {
                            response = try await withDeadline(deadline) {
                                try await request(model: model, system: system, turns: turns, thinking: "minimal")
                            }
                            // Not every model accepts "minimal" (gemini-3.8-flash doesn't); "low" is the next fastest.
                            // (This retry's timeout used to escape uncaught and showed as a raw FirstWordTimeout.)
                            if case let .failure(400, body) = response, body.contains("Thinking level") {
                                response = try await withDeadline(deadline) {
                                    try await request(model: model, system: system, turns: turns, thinking: "low")
                                }
                            }
                        } catch is FirstWordTimeout { // queued: no response at all
                            lastError = "\(model) didn't respond within \(Int(deadline)) s"
                            continue
                        }
                        switch response {
                        case let .failure(status, body) where status == 503 || status == 429:
                            lastError = "\(model) \(status == 429 ? "out of daily quota" : "busy"): \(body.prefix(160))"
                            continue
                        case let .failure(status, body):
                            throw ModelError(message: "Gemini HTTP \(status) (\(model)): \(body.prefix(300))")
                        case let .success(lines):
                            // Some models accept the request, then sit in Google's queue for minutes.
                            // No first word within the deadline → abandon this model and try the next.
                            let started = Flag()
                            let streamNote = Note()
                            do {
                                try await withThrowingTaskGroup(of: Bool.self) { group in
                                    group.addTask {
                                        for try await line in lines {
                                            if line.contains("error") { streamNote.text = String(line.prefix(200)) }
                                            guard line.hasPrefix("data:"), let text = Self.textDelta(in: line.dropFirst(5)) else { continue }
                                            started.set()
                                            continuation.yield(text)
                                        }
                                        return true // stream finished
                                    }
                                    group.addTask {
                                        try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                                        if !started.isSet { throw FirstWordTimeout() }
                                        return false // deadline passed after the answer had started: keep streaming
                                    }
                                    while let streamDone = try await group.next() {
                                        if streamDone { group.cancelAll(); break }
                                    }
                                }
                            } catch let error where error is FirstWordTimeout || (error as? URLError)?.code == .timedOut {
                                guard !started.isSet else { // stalled mid-answer
                                    throw ModelError(message: "The connection stalled mid-answer (no data for \(Int(Self.stallTimeout)) s). Try again.")
                                }
                                lastError = "\(model) gave no answer within \(Int(deadline)) s"
                                continue
                            }
                            guard started.isSet else { // stream ended without any answer text
                                lastError = "\(model) returned no text \(streamNote.text)"
                                continue
                            }
                            continuation.finish()
                            return
                        }
                    }
                    throw ModelError(message: "Every Gemini model is busy or out of free quota right now. (\(lastError))")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum Response {
        case success(AsyncLineSequence<URLSession.AsyncBytes>)
        case failure(Int, String)
    }

    private func request(model: String, system: String, turns: [Turn], thinking: String) async throws -> Response {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions?alt=sse")!)
        req.httpMethod = "POST"
        // Network idle limit. Kept generous so a slow connection can pause mid-answer; the much shorter
        // first-word deadline is enforced separately (withDeadline + the stream's deadline task).
        req.timeoutInterval = Self.stallTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "store": false,
            "system_instruction": system,
            "generation_config": ["thinking_level": thinking], // thinking costs ~3 s before the first word
            "input": turns.map { turn in
                ["type": turn.role == "model" ? "model_output" : "user_input",
                 "content": turn.parts.map { part -> [String: Any] in
                     switch part {
                     case let .text(s): return ["type": "text", "text": s]
                     case let .image(png): return ["type": "image", "data": png.base64EncodedString(), "mime_type": "image/png"]
                     }
                 }] as [String: Any]
            },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            return .failure(status, text)
        }
        return .success(bytes.lines)
    }

    /// Text arrives as `step.delta` events with `delta.type == "text"`; thought steps and `[DONE]` are skipped.
    private static func textDelta(in json: Substring) -> String? {
        guard let data = json.trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["event_type"] as? String == "step.delta",
              let delta = obj["delta"] as? [String: Any], delta["type"] as? String == "text"
        else { return nil }
        return delta["text"] as? String
    }
}

private struct FirstWordTimeout: LocalizedError {
    var errorDescription: String? { "Gemini didn't start answering in time. Try again in a moment." }
}

/// Thread-safe "has the answer started" flag shared between the stream and its deadline.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Last error-looking line seen in a stream, for the message shown when every model fails.
private final class Note: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Runs `work`, throwing FirstWordTimeout if it takes longer than `seconds`.
private func withDeadline<T>(_ seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next(), let value = first else { throw FirstWordTimeout() }
        return value
    }
}
