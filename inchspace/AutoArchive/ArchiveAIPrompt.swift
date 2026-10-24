import Foundation

nonisolated enum ArchiveAIPrompt {
    // The rules every stage works under live in `ArchiveConvention`, and each stage's own instructions in
    // `ArchiveStagePrompt`; this type only reads what comes back.

    /// Local chat models often wrap the answer in `<think>` blocks or code fences; only the JSON object counts.
    static func extractJSONObject(_ text: String) -> String {
        var body = text
        while let open = body.range(of: "<think>"), let close = body.range(of: "</think>", range: open.upperBound..<body.endIndex) {
            body.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let close = body.range(of: "</think>") { body = String(body[close.upperBound...]) }
        guard let first = body.firstIndex(of: "{"), let last = body.lastIndex(of: "}"), first < last else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(body[first...last])
    }

    static func decode(_ text: String) throws -> ArchiveAIResponse {
        let data = Data(extractJSONObject(text).utf8)
        guard data.count <= 100_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["summary", "directories", "files"],
              let directories = object["directories"] as? [[String: Any]], directories.count <= 20,
              let files = object["files"] as? [[String: Any]], files.count <= 30,
              directories.allSatisfy({ Set($0.keys) == ["action", "rootID", "relativePath", "reason"] }),
              files.allSatisfy({ Set($0.keys) == ["fileID", "rootID", "relativeDirectory", "proposedName", "reason"] && $0["proposedName"] is String }) else {
            throw ArchiveError("AI 返回的计划格式无效，未执行任何操作。")
        }
        let result = try JSONDecoder().decode(ArchiveAIResponse.self, from: data)
        guard !result.summary.isEmpty, result.summary.count <= 4_000,
              result.directories.allSatisfy({ !$0.reason.isEmpty && $0.reason.count <= 1_000 }),
              result.files.allSatisfy({ !$0.reason.isEmpty && $0.reason.count <= 1_000 }) else {
            throw ArchiveError("AI 计划缺少说明或超过长度限制。")
        }
        return result
    }
}

/// The model service could not be reached or did not finish in time. Unlike an invalid plan, this is not
/// the files' fault, so autopilot retries once with a smaller batch and otherwise reports it instead of
/// giving up on those files.
nonisolated struct ArchiveAIUnavailable: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Connection limits chosen for where the model runs. A model on this Mac needs small batches and patience:
/// it has to read the whole prompt before the first token arrives, and it writes the plan slowly.
nonisolated struct ArchiveAITuning: Equatable, Sendable {
    /// Files taken from one scan.
    var batchSize: Int
    /// Files reviewed in one model request.
    var reviewBatch: Int
    /// Keywords sent per file.
    var keywordLimit: Int
    /// Existing folders listed in a review question.
    var folderLimit: Int
    /// Other files of the same folder shown per file.
    var siblingLimit: Int
    /// Longest silence tolerated between two chunks of the response.
    var idleTimeout: TimeInterval
    /// Longest time for one planning request as a whole.
    var totalTimeout: TimeInterval
    /// Ask thinking models (Qwen3, DeepSeek-R1 style) to answer directly instead of reasoning first.
    var disablesThinking: Bool
    /// Pause between two model requests, so a local GPU is not pinned at full load for minutes on end.
    var cooldown: TimeInterval
    /// Similar folders sent per file, and example files shown for each.
    var candidateLimit = 8
    var candidateSamples = 5
    /// Extra output tokens on top of the answer's own budget. Some local servers (LM Studio with Qwen3.5) ignore
    /// the request not to think; the reasoning then counts against `max_tokens` and, with a budget sized for the
    /// answer alone, the answer is cut off and the files are left without a result.
    var reasoningAllowance = 0

    static let remote = ArchiveAITuning(batchSize: 30, reviewBatch: 10, keywordLimit: 80, folderLimit: 300, siblingLimit: 20,
                                        idleTimeout: 90, totalTimeout: 300, disablesThinking: false, cooldown: 0)
    static let local = ArchiveAITuning(batchSize: 15, reviewBatch: 5, keywordLimit: 24, folderLimit: 160, siblingLimit: 8,
                                       idleTimeout: 240, totalTimeout: 1_200, disablesThinking: true, cooldown: 0.5,
                                       candidateLimit: 6, candidateSamples: 4, reasoningAllowance: 3_000)

    static func isLocal(_ configuration: TerminalAIConfiguration) -> Bool {
        if configuration.service == .ollama { return true }
        guard let host = (try? TerminalAIConfiguration.normalizedBaseURL(configuration.baseURL))?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host) || host.hasSuffix(".local")
            || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }

    static func tuning(for configuration: TerminalAIConfiguration) -> ArchiveAITuning {
        isLocal(configuration) ? .local : .remote
    }
}

/// Uses the existing OpenAI-compatible connection settings for a bounded, streamed planning request.
/// Streaming matters even though the plan is only usable once complete: every chunk resets the idle
/// timeout, so a slow local model is not cut off while it is still writing, and the UI can show it working.
@MainActor
struct ArchiveAIClient {
    var tuning: ArchiveAITuning?

    func request(system: String, user: String, configuration: TerminalAIConfiguration, apiKey: String,
                 maxTokens: Int = 6_000) throws -> URLRequest {
        let configuration = try configuration.validated()
        let tuning = tuning ?? ArchiveAITuning.tuning(for: configuration)
        let url = try configuration.endpoint("chat/completions")
        guard url.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") else {
            throw ArchiveError("归档 AI 仅允许 HTTPS 服务或本机 HTTP 模型。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = tuning.idleTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        // Deterministic sampling keeps the JSON tight; the system prompt is byte-identical across requests so
        // local servers can reuse their prompt cache for it.
        var body: [String: Any] = [
            "model": configuration.model, "stream": true, "max_tokens": max(256, maxTokens) + tuning.reasoningAllowance,
            "temperature": 0,
            // Qwen's soft switch, at the very end so the cached prefix stays the same; it is ignored where the
            // template flag below already turned thinking off, and helps where a server drops that flag.
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": tuning.disablesThinking ? user + "\n/no_think" : user]],
        ]
        if tuning.disablesThinking {
            // llama.cpp, vLLM and LM Studio read chat_template_kwargs; Ollama reads think. Both ignore the other.
            body["chat_template_kwargs"] = ["enable_thinking": false]
            body["think"] = false
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// One streamed request with the given instructions; returns the answer text without reasoning.
    func complete(system: String, user: String, configuration: TerminalAIConfiguration, apiKey: String,
                  maxTokens: Int = 6_000, onProgress: @MainActor (Int) -> Void = { _ in }) async throws -> String {
        let request = try request(system: system, user: user, configuration: configuration, apiKey: apiKey, maxTokens: maxTokens)
        return try await send(request, configuration: configuration, onProgress: onProgress)
    }

    private func send(_ request: URLRequest, configuration: TerminalAIConfiguration,
                      onProgress: @MainActor (Int) -> Void) async throws -> String {
        let tuning = tuning ?? ArchiveAITuning.tuning(for: (try? configuration.validated()) ?? configuration)
        let configurationForSession = URLSessionConfiguration.ephemeral
        configurationForSession.timeoutIntervalForRequest = tuning.idleTimeout
        configurationForSession.timeoutIntervalForResource = tuning.totalTimeout
        let session = URLSession(configuration: configurationForSession, delegate: ArchiveAINoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        // Stopping the run cancels the request; URLSession reports that as `URLError.cancelled`, which must stop the
        // run quietly instead of showing up as a failure named "cancelled".
        do { (bytes, response) = try await session.bytes(for: request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut {
            throw ArchiveAIUnavailable("模型在 \(Int(tuning.idleTimeout)) 秒内没有响应。本机模型请确认服务已启动且模型已加载；提示词较长时首个字可能需要更久。")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines where body.count < 4_000 { body += line }
            let detail = OpenAICompatibleProvider.providerError(from: body).map { "：\($0)" } ?? ""
            throw ArchiveAIUnavailable("归档 AI 请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）\(detail)")
        }
        var parser = ArchiveAIStreamParser()
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let previous = parser.content.count
                try parser.consume(line)
                if parser.content.count != previous { onProgress(parser.content.count) }
                if parser.finished { break }
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw ArchiveAIUnavailable("模型输出中途停顿超过 \(Int(tuning.idleTimeout)) 秒，已放弃本轮。可减少待整理文件数量或换用更快的模型。")
        }
        return try parser.text()
    }
}

/// Parses an OpenAI-compatible chat completion, streamed as server-sent events or returned as one document.
/// Reasoning text (`reasoning_content`) is counted but never treated as the answer.
nonisolated struct ArchiveAIStreamParser {
    private(set) var content = ""
    private(set) var finished = false
    private(set) var sawReasoning = false
    private var raw = ""
    private var sawEvents = false
    private var finishReason: String?

    private struct Event {
        var content: String
        var reasoning: Bool
        var finishReason: String?
    }

    mutating func consume(_ line: String) throws {
        if line.hasPrefix("data:") {
            sawEvents = true
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { finished = true; return }
            guard let event = try Self.event(from: payload) else { return }
            if let reason = event.finishReason { finishReason = reason }
            if event.reasoning { sawReasoning = true } else { content += event.content }
        } else if !sawEvents {
            // A server that ignores `stream` answers with one JSON document instead.
            raw += line + "\n"
        }
        guard content.utf8.count + raw.utf8.count < 150_000 else { throw ArchiveError("AI 响应过大，已停止读取。") }
    }

    func result() throws -> ArchiveAIResponse {
        try ArchiveAIPrompt.decode(try text())
    }

    /// The answer text, once it is known to be complete and not just reasoning.
    func text() throws -> String {
        var answer = content
        var reason = finishReason
        if !sawEvents {
            let completion = try Self.completion(from: raw)
            answer = completion.content
            reason = completion.finishReason
        }
        guard reason != "length" else { throw ArchiveError("AI 的回答超过长度上限而被截断；本轮文件较多，将用更小的批次重试。") }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if sawReasoning {
                throw ArchiveError("模型只输出了思考过程，没有给出方案。请确认本机模型支持关闭思考，或换用非推理模型。")
            }
            throw ArchiveError("AI 未返回归档计划。")
        }
        return answer
    }

    private static func event(from payload: String) throws -> Event? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            throw ArchiveAIUnavailable("归档 AI 请求失败：\(message)")
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
        let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
        let content = delta["content"] as? String ?? ""
        let reasoning = content.isEmpty && (delta["reasoning_content"] as? String)?.isEmpty == false
        return Event(content: content, reasoning: reasoning, finishReason: choice["finish_reason"] as? String)
    }

    /// The terminal provider reads this too, but it is main-actor isolated; the parser must stay off the main actor.
    private static func providerMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        return object["error"] as? String
    }

    private static func completion(from body: String) throws -> Event {
        if let message = providerMessage(from: body) { throw ArchiveAIUnavailable("归档 AI 请求失败：\(message)") }
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw ArchiveError("AI 未返回完整的归档计划。") }
        let content = message["content"] as? String ?? ""
        return Event(content: content, reasoning: content.isEmpty && (message["reasoning_content"] as? String)?.isEmpty == false,
                     finishReason: choice["finish_reason"] as? String)
    }
}

nonisolated private final class ArchiveAINoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
