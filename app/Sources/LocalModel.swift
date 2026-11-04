import Foundation

/// A local model served by LM Studio (OpenAI-compatible API on localhost:1234).
/// Thinking is switched off with `reasoning_effort: "none"`: measured 2026-11-02, without it Qwen 3.5 thinks for
/// up to ~2 min before the first word; chat_template_kwargs, reasoning.effort and "/no_think" were ignored.
struct LMStudioAdapter: ModelAdapter {
    let model: String
    let baseURL = URL(string: "http://localhost:1234/v1/chat/completions")!

    /// MIST_LOCAL_MODEL overrides the model (an `lms ls` key). Default: Qwen 3.5 4B, the best balance in Test 3.
    static func fromEnvironment() -> LMStudioAdapter {
        LMStudioAdapter(model: ProcessInfo.processInfo.environment["MIST_LOCAL_MODEL"] ?? "qwen/qwen3.5-4b")
    }

    func stream(system: String, turns: [Turn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await send(system: system, turns: turns, stream: true, maxTokens: nil)
                    try await check(response, bytes)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"), let text = Self.contentDelta(in: line.dropFirst(5)) else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.friendly(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One short, non-streamed reply (used to write search queries).
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var text = ""
        for try await chunk in stream(system: system, turns: [Turn(role: "user", parts: [.text(user)])]) {
            text += chunk
            if text.count > maxTokens * 6 { break } // safety cap; queries are a few words
        }
        return text
    }

    private func send(system: String, turns: [Turn], stream: Bool, maxTokens: Int?) async throws
        -> (URLSession.AsyncBytes, URLResponse) {
        var req = URLRequest(url: baseURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 60 // first request may load the model (~6 s), or wait for LM Studio to start
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in turns {
            let role = turn.role == "model" ? "assistant" : "user"
            let hasImage = turn.parts.contains { if case .image = $0 { return true }; return false }
            if hasImage { // OpenAI-style multimodal content; the Qwen 3.5 and Gemma 4 builds report vision support
                let content: [[String: Any]] = turn.parts.map { part in
                    switch part {
                    case let .text(s): return ["type": "text", "text": s]
                    case let .image(png):
                        return ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]]
                    }
                }
                messages.append(["role": role, "content": content])
            } else {
                let text = turn.parts.compactMap { part -> String? in
                    if case let .text(s) = part { return s }
                    return nil
                }.joined(separator: "\n\n")
                messages.append(["role": role, "content": text])
            }
        }
        var body: [String: Any] = ["model": model, "stream": stream, "messages": messages,
                                   "reasoning_effort": "none", "temperature": 0.4]
        if let maxTokens { body["max_tokens"] = maxTokens }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await URLSession.shared.bytes(for: req)
    }

    private func check(_ response: URLResponse, _ bytes: URLSession.AsyncBytes) async throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw ModelError(message: "LM Studio HTTP \(status) (\(model)): \(text.prefix(300))")
        }
    }

    private static func friendly(_ error: Error) -> Error {
        if let url = error as? URLError, url.code == .cannotConnectToHost || url.code == .networkConnectionLost {
            return ModelError(message: "Local model isn't running. Start LM Studio's server: ~/.lmstudio/bin/lms server start")
        }
        return error
    }

    private static func contentDelta(in json: Substring) -> String? {
        guard let data = json.trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let text = delta["content"] as? String, !text.isEmpty
        else { return nil }
        return text
    }
}
