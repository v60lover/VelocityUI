// LiveLLMClient.swift

import Foundation

/// Minimal OpenAI-compatible streaming chat client for the "Live LLM" scenario (VelocityUI-25q7).
/// Talks to any provider that speaks the OpenAI `/chat/completions` SSE format — Groq,
/// OpenRouter, Ollama, OpenAI itself — over one code path, since they all share the same wire
/// shape (see `LiveLLMSettings`). Demo-only: lives in BenchmarkHost, never in the VelocityUI
/// library (no network dependency belongs in the core package).
enum LiveLLMClient {
    struct Message: Sendable {
        let role: String
        let content: String
    }

    struct ProviderConfig: Sendable {
        var baseURL: URL
        var apiKey: String
        var model: String
    }

    enum ClientError: Error, LocalizedError, Sendable {
        case httpStatus(Int, body: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case let .httpStatus(code, body):
                return "HTTP \(code): \(body.prefix(200))"
            case .invalidResponse:
                return "Invalid response from server"
            }
        }
    }

    /// Streams assistant text deltas for `messages` against `config`, one non-empty content
    /// delta at a time, in emission order. Finishes when the server sends `data: [DONE]` or the
    /// connection closes; throws `ClientError` on a non-2xx response or a malformed body.
    ///
    /// Runs the network read loop in its own unstructured `Task` (off whatever isolation the
    /// caller is on); cancelling the returned stream's iteration (or the `Task` driving it)
    /// cancels that `Task` via `onTermination`, which cancels the in-flight `URLSession` read.
    static func streamChatCompletion(
        config: ProviderConfig,
        messages: [Message]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !config.apiKey.isEmpty {
                        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    let body: [String: Any] = [
                        "model": config.model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw ClientError.httpStatus(http.statusCode, body: errorBody)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8), let delta = extractDelta(from: data), !delta.isEmpty else {
                            continue
                        }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pure JSON parse, no networking — split out so the SSE loop above stays about control flow
    /// and this stays independently testable against a fixed payload.
    static func extractDelta(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any]
        else { return nil }
        return delta["content"] as? String
    }
}
