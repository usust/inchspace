import Foundation

nonisolated struct XenNotificationConfiguration: Codable, Equatable {
    var id = UUID()
    var webhookEnabled = false
    var webhookURL = ""
    var mailEnabled = false
    var smtpHost = ""
    var smtpPort = 465
    var username = ""
    var sender = ""
    var recipient = ""
    func validate() throws {
        if webhookEnabled {
            guard let url = URL(string: webhookURL), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw XenError.invalid("Webhook 需要不含账号密码的 HTTPS 地址。") }
        }
        if mailEnabled {
            guard !smtpHost.isEmpty, !smtpHost.contains(where: { $0.isWhitespace || "/@?#".contains($0) }), (1...65535).contains(smtpPort),
                  Self.validEmail(sender), Self.validEmail(recipient), !username.contains("\r"), !username.contains("\n") else { throw XenError.invalid("请填写 SMTP 主机、TLS 端口及有效的发件人与收件人。") }
        }
    }
    static func validEmail(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }
}

nonisolated enum XenNotifications {
    static func send(_ event: XenAlertEvent, configuration: XenNotificationConfiguration, password: String?) async throws -> String {
        try configuration.validate()
        var outcomes: [String] = []
        if configuration.webhookEnabled {
            do {
            let policy = XenNoRedirectPolicy()
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config, delegate: policy, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: configuration.webhookURL)!)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(event)
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw XenError.transport("Webhook 未确认接收告警。") }
            outcomes.append("Webhook 已确认")
            } catch { outcomes.append("Webhook 未确认送达") }
        }
        if configuration.mailEnabled {
            do {
                guard configuration.username.isEmpty || password != nil else { throw XenError.invalid("无法读取邮件凭据。") }
                try await sendMail(event, configuration: configuration, password: password ?? "")
                outcomes.append("邮件已提交")
            } catch { outcomes.append("邮件未确认送达") }
        }
        return outcomes.joined(separator: " · ")
    }
    private static func sendMail(_ event: XenAlertEvent, configuration: XenNotificationConfiguration, password: String) async throws {
        let socket = XenStreamSocket(host: configuration.smtpHost, port: configuration.smtpPort, tls: true, allowUntrusted: false)
        defer { socket.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await socket.start()
                try await smtpResponse(socket, expected: [220])
                try await smtpCommand(socket, "EHLO inchspace.local", expected: [250])
                if !configuration.username.isEmpty {
                    try await smtpCommand(socket, "AUTH LOGIN", expected: [334])
                    try await smtpCommand(socket, Data(configuration.username.utf8).base64EncodedString(), expected: [334])
                    try await smtpCommand(socket, Data(password.utf8).base64EncodedString(), expected: [235])
                }
                try await smtpCommand(socket, "MAIL FROM:<\(configuration.sender)>", expected: [250])
                try await smtpCommand(socket, "RCPT TO:<\(configuration.recipient)>", expected: [250, 251])
                try await smtpCommand(socket, "DATA", expected: [354])
                let subject = Data(event.title.utf8).base64EncodedString()
                let body = Data("\(event.title)\n资源池：\(event.poolUUID)\n资源：\(event.resourceUUID)\n时间：\(event.createdAt.ISO8601Format())".utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                let message = "From: <\(configuration.sender)>\r\nTo: <\(configuration.recipient)>\r\nSubject: =?UTF-8?B?\(subject)?=\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(body)\r\n.\r\n"
                try await socket.write(Data(message.utf8))
                try await smtpResponse(socket, expected: [250])
                try? await smtpCommand(socket, "QUIT", expected: [221])
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                socket.cancel()
                throw XenError.transport("邮件发送超时，接收结果需核对。")
            }
            do { _ = try await group.next(); group.cancelAll() }
            catch { socket.cancel(); group.cancelAll(); throw error }
        }
    }
    private static func smtpCommand(_ socket: XenStreamSocket, _ command: String, expected: Set<Int>) async throws {
        guard !command.contains("\r"), !command.contains("\n") else { throw XenError.invalid("SMTP 命令包含非法换行。") }
        try await socket.write(Data((command + "\r\n").utf8))
        try await smtpResponse(socket, expected: expected)
    }
    private static func smtpResponse(_ socket: XenStreamSocket, expected: Set<Int>) async throws {
        var total = 0
        while total < 65536 {
            var line = Data()
            while !line.suffix(2).elementsEqual([13, 10]) {
                guard line.count < 4096 else { throw XenError.invalid("SMTP 响应过长。") }
                line.append(try await socket.read(1)); total += 1
            }
            let response = String(decoding: line, as: UTF8.self)
            guard let code = Int(response.prefix(3)), expected.contains(code), line.count >= 5 else { throw XenError.transport("SMTP 服务器未接受邮件请求。") }
            if line[3] == 32 { return }
            guard line[3] == 45 else { throw XenError.invalid("SMTP 响应格式无效。") }
        }
        throw XenError.invalid("SMTP 响应超过限制。")
    }
}

private nonisolated final class XenNoRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
