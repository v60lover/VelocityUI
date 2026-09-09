// LiveLLMSettings.swift

import Foundation

/// User-editable connection settings for the "Live LLM" scenario (VelocityUI-25q7), persisted in
/// `UserDefaults` so the API key only needs typing once per device. Defaults to Groq's
/// OpenAI-compatible endpoint (fast free-tier streaming, good for a live demo); any other
/// OpenAI-compatible provider — OpenRouter, Ollama, OpenAI itself — works by editing base URL +
/// model, since `LiveLLMClient` speaks one wire format for all of them.
struct LiveLLMSettings: Sendable, Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    static let `default` = LiveLLMSettings(
        baseURL: "https://api.groq.com/openai/v1",
        apiKey: "",
        model: "openai/gpt-oss-120b"
    )

    var resolvedBaseURL: URL? { URL(string: baseURL) }

    private enum Keys {
        static let baseURL = "liveLLM.baseURL"
        static let apiKey = "liveLLM.apiKey"
        static let model = "liveLLM.model"
    }

    static func load(from defaults: UserDefaults = .standard) -> LiveLLMSettings {
        LiveLLMSettings(
            baseURL: defaults.string(forKey: Keys.baseURL) ?? Self.default.baseURL,
            apiKey: defaults.string(forKey: Keys.apiKey) ?? Self.default.apiKey,
            model: defaults.string(forKey: Keys.model) ?? Self.default.model
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(baseURL, forKey: Keys.baseURL)
        defaults.set(apiKey, forKey: Keys.apiKey)
        defaults.set(model, forKey: Keys.model)
    }
}
