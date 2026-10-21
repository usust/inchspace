import Foundation

/// Presets only supply connection defaults. Model IDs always come from the service or user.
enum TerminalAIService: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepSeek, openAI, siliconFlow, openRouter, ollama, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .openAI: "OpenAI"
        case .siliconFlow: "硅基流动"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .custom: "自定义（OpenAI 兼容）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com"
        case .openAI: "https://api.openai.com/v1"
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }
}

struct TerminalAIConfiguration: Codable, Equatable, Sendable {
    var service: TerminalAIService = .deepSeek
    var baseURL: String = TerminalAIService.deepSeek.defaultBaseURL
    var model: String = ""

    func validated() throws -> Self {
        let url = try Self.normalizedBaseURL(baseURL)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw TerminalAIError.provider("请选择模型或填写模型 ID。") }
        return Self(service: service, baseURL: url.absoluteString, model: model)
    }

    static func normalizedBaseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw TerminalAIError.provider("请输入有效的 HTTP(S) Base URL，包含 API 路径（如 /v1），不要包含密钥、查询参数或具体接口。")
        }
        components.scheme = scheme
        components.host = host.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard !components.path.hasSuffix("/models"), !components.path.hasSuffix("/chat/completions"),
              let url = components.url else {
            throw TerminalAIError.provider("Base URL 应填写 API 根路径，请移除末尾的 /models 或 /chat/completions。")
        }
        return url
    }

    func endpoint(_ path: String) throws -> URL {
        try Self.normalizedBaseURL(baseURL).appending(path: path)
    }
}

/// Each card has its own identity, so multiple connections can use the same service preset.
struct TerminalAIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var configuration: TerminalAIConfiguration

    static func preset(_ service: TerminalAIService, configuration: TerminalAIConfiguration? = nil) -> Self {
        Self(
            id: "preset-\(service.rawValue)",
            name: service == .custom ? "自定义" : service.title,
            configuration: configuration ?? TerminalAIConfiguration(service: service, baseURL: service.defaultBaseURL)
        )
    }
}

protocol TerminalAIProvider: Sendable {
    func stream(messages: [TerminalAIProviderMessage]) -> AsyncThrowingStream<String, Error>
}

struct TerminalAIProviderMessage: Sendable {
    let role: String
    let content: String
}

struct OpenAICompatibleProvider: TerminalAIProvider {
    let configuration: TerminalAIConfiguration
    let apiKey: String
    var session: URLSession = .shared

    func chatRequest(messages: [TerminalAIProviderMessage]) throws -> URLRequest {
        let configuration = try configuration.validated()
        var request = URLRequest(url: try configuration.endpoint("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ])
        return request
    }

    func stream(messages: [TerminalAIProviderMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try chatRequest(messages: messages)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw TerminalAIError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4_000 { break }
                        }
                        throw TerminalAIError.provider(Self.providerError(from: body) ?? "AI 请求失败（HTTP \(http.statusCode)）。")
                    }

                    var receivedContent = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let content = try Self.streamContent(from: payload), !content.isEmpty else { continue }
                        receivedContent = true
                        continuation.yield(content)
                    }
                    guard receivedContent else { throw TerminalAIError.invalidResponse }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func streamContent(from payload: String) throws -> String? {
        if let message = providerError(from: payload) { throw TerminalAIError.provider(message) }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        let content = delta["content"] as? String ?? ""
        let refusal = delta["refusal"] as? String ?? ""
        return content.isEmpty ? refusal : content
    }

    static func providerError(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        return object["error"] as? String
    }
}

struct TerminalAIModelService: Sendable {
    var session: URLSession = .shared

    func modelsRequest(baseURL: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: try TerminalAIConfiguration.normalizedBaseURL(baseURL).appending(path: "models"))
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let request = try modelsRequest(baseURL: baseURL, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TerminalAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(4_000), encoding: .utf8) ?? ""
            let message = OpenAICompatibleProvider.providerError(from: body)
                ?? "获取模型失败（HTTP \(http.statusCode)），可手动填写模型 ID。"
            throw TerminalAIError.provider(message)
        }
        return try Self.decodeModels(from: data)
    }

    static func decodeModels(from data: Data) throws -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TerminalAIError.invalidResponse
        }
        return Array(Set(response.data.map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}
