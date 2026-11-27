import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Einstellungen für die lokale KI.
struct AISettings: Codable, Equatable, Sendable {
    var enabled: Bool = true
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "qwen2.5:3b"
    /// Bildmodell für konkrete Bild-Tags (sieht das Foto selbst an)
    var visionModel: String = "qwen2.5vl:3b"

    static let key = "ai"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AISettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL) ?? d.ollamaURL
        ollamaModel = try c.decodeIfPresent(String.self, forKey: .ollamaModel) ?? d.ollamaModel
        visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel) ?? d.visionModel
    }
}

/// Ein lokales Sprachmodell. Inhalte verlassen den Mac nicht.
enum LocalModel: Sendable {
    case apple
    case ollama(OllamaClient)

    var name: String {
        switch self {
        case .apple: return "Apple (auf dem Gerät)"
        case .ollama(let client): return "Ollama: \(client.model)"
        }
    }

    func complete(system: String, prompt: String) async throws -> String {
        switch self {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession(instructions: system)
                return try await session.respond(to: prompt).content
            }
            #endif
            throw LocalModelError.unavailable
        case .ollama(let client):
            return try await client.generate(system: system, prompt: prompt)
        }
    }

    /// Wählt das beste verfügbare Modell: Apple, sonst Ollama, sonst keins.
    static func find(settings: AISettings) async -> LocalModel? {
        if appleModelAvailable { return .apple }
        guard let url = URL(string: settings.ollamaURL) else { return nil }
        let client = OllamaClient(baseURL: url, model: settings.ollamaModel)
        return await client.isAvailable() ? .ollama(client) : nil
    }

    static var appleModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }
}

enum LocalModelError: LocalizedError {
    case unavailable
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Kein lokales KI-Modell verfügbar. Läuft Ollama und ist das Modell geladen?"
        case .badResponse(let s): return "Unerwartete Antwort des Modells: \(s)"
        }
    }
}

/// Spricht mit Ollama auf diesem Mac (Standard: http://localhost:11434).
struct OllamaClient: Sendable {
    var baseURL: URL
    var model: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Läuft Ollama und ist das Modell geladen?
    func isAvailable() async -> Bool {
        (try? await installedModels().contains { $0 == model || $0 == model + ":latest" }) ?? false
    }

    func installedModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        let (data, _) = try await Self.session.data(for: request)
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        return try JSONDecoder().decode(Tags.self, from: data).models.map(\.name)
    }

    /// `images`: Base64-kodierte Bilder für Bildmodelle (z. B. qwen2.5vl).
    func generate(system: String, prompt: String, images: [String] = []) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.2, "num_ctx": 8192],
        ]
        if !images.isEmpty { body["images"] = images }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await Self.session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalModelError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let error = json["error"] as? String { throw LocalModelError.badResponse(error) }
        guard let text = json["response"] as? String else {
            throw LocalModelError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return text
    }
}
