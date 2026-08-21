import Foundation

protocol TerminalAIProvider: Sendable {
    func stream(messages: [TerminalAIProviderMessage]) -> AsyncThrowingStream<String, Error>
}

struct TerminalAIProviderMessage: Sendable {
    let role: String
    let content: String
}

struct DeepSeekProvider: TerminalAIProvider {
    static let baseURL = URL(string: "https://api.deepseek.com")!

    let apiKey: String
    let model: String
    let session: URLSession

    init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func stream(messages: [TerminalAIProviderMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = Self.baseURL.appending(path: "chat/completions")
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "stream": true,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                    ])

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw TerminalAIError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4_000 { break }
                        }
                        let message = Self.providerError(from: body) ?? "DeepSeek 请求失败（HTTP \(http.statusCode)）。"
                        throw TerminalAIError.provider(message)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func providerError(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

struct DeepSeekModelService: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: DeepSeekProvider.baseURL.appending(path: "models"))
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TerminalAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(4_000), encoding: .utf8) ?? ""
            let message = DeepSeekProvider.providerError(from: body)
                ?? "获取 DeepSeek 模型失败（HTTP \(http.statusCode)）。"
            throw TerminalAIError.provider(message)
        }
        return try Self.decodeModels(from: data)
    }

    static func decodeModels(from data: Data) throws -> [String] {
        struct Response: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        return Array(Set(response.data.map(\.id).filter { !$0.isEmpty })).sorted()
    }
}
