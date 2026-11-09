import AppKit
import SwiftUI
import Network
import Security

/// Native RFB client. Requests raw pixels to avoid bundling a browser, JavaScript or third-party VNC runtime.
actor XenRFBClient {
    private var socket: XenStreamSocket?
    private var width = 0
    private var height = 0
    private var pixels = Data()
    func close() { socket?.cancel(); socket = nil }
    func run(location: URL, session: String, allowUntrusted: Bool, frame: @escaping @Sendable (Data, Int, Int) async -> Void) async throws {
        guard let host = location.host, ["https", "http"].contains(location.scheme ?? "") else { throw XenError.invalid("控制台地址无效。") }
        let connection = XenStreamSocket(host: host, port: location.port ?? (location.scheme == "https" ? 443 : 80), tls: location.scheme == "https", allowUntrusted: allowUntrusted)
        socket = connection
        defer { connection.cancel(); socket = nil }
        try await connection.start()
        var parts = URLComponents(url: location, resolvingAgainstBaseURL: false)!
        parts.queryItems = parts.queryItems?.filter { $0.name != "session_id" }
        let path = (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath) + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard !session.contains("\r"), !session.contains("\n") else { throw XenError.invalid("控制台会话无效。") }
        let hostHeader = host.contains(":") ? "[\(host)]" : host
        try await connection.write(Data("CONNECT \(path) HTTP/1.1\r\nHost: \(hostHeader):\(location.port ?? (location.scheme == "https" ? 443 : 80))\r\nCookie: session_id=\(session)\r\n\r\n".utf8))
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard header.count < 16_384 else { throw XenError.invalid("控制台 CONNECT 响应过大。") }
            header.append(try await connection.read(1))
        }
        guard String(decoding: header, as: UTF8.self).split(separator: "\n").first?.split(separator: " ").dropFirst().first == "200" else {
            throw XenError.transport("服务器未接受控制台 CONNECT 请求。")
        }
        let version = String(decoding: try await connection.read(12), as: UTF8.self)
        guard version.hasPrefix("RFB 003."), let minor = Int(version.dropFirst(8).prefix(3)) else { throw XenError.invalid("控制台未返回有效 RFB 版本。") }
        let modern = minor >= 7
        try await connection.write(Data((minor >= 8 ? "RFB 003.008\n" : minor == 7 ? "RFB 003.007\n" : "RFB 003.003\n").utf8))
        if modern {
            let count = Int(try await connection.read(1)[0])
            guard count > 0 else { throw XenError.invalid("控制台拒绝了 RFB 会话。") }
            let types = try await connection.read(count)
            guard types.contains(1) else { throw XenError.invalid("控制台要求额外的 VNC 认证，当前尚不支持该认证方式。") }
            try await connection.write(Data([1]))
            if minor >= 8 {
                let security = try await connection.read(4)
                guard security.u32(0) == 0 else { throw XenError.invalid("控制台认证失败。") }
            }
        } else {
            let security = try await connection.read(4)
            guard security.u32(0) == 1 else { throw XenError.invalid("不支持此控制台的 RFB 认证方式。") }
        }
        try await connection.write(Data([1])) // shared session
        let initial = try await connection.read(24)
        try resize(Int(initial.u16(0)), Int(initial.u16(2)))
        let nameLength = Int(initial.u32(20))
        guard nameLength <= 65536 else { throw XenError.invalid("RFB 名称过长。") }
        _ = try await connection.read(nameLength)
        // 32-bit little-endian RGB, shifts R=16/G=8/B=0.
        try await connection.write(Data([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]))
        try await connection.write(Data([2, 0, 0, 2, 0, 0, 0, 0, 255, 255, 255, 33])) // raw + DesktopSize (-223)
        try await requestUpdate(incremental: false)
        while !Task.isCancelled {
            let type = try await connection.read(1)[0]
            switch type {
            case 0:
                let update = try await connection.read(3)
                let count = Int(update.u16(1))
                guard count <= 4096 else { throw XenError.invalid("RFB 矩形数量超出限制。") }
                for _ in 0..<count {
                    let rect = try await connection.read(12)
                    let x = Int(rect.u16(0)), y = Int(rect.u16(2)), w = Int(rect.u16(4)), h = Int(rect.u16(6))
                    let encoding = Int32(bitPattern: rect.u32(8))
                    if encoding == -223 { try resize(w, h); continue }
                    guard encoding == 0, x + w <= width, y + h <= height else { throw XenError.invalid("不支持或无效的 RFB 帧编码。") }
                    let bytes = try await connection.read(w * h * 4)
                    for row in 0..<h {
                        let destination = ((y + row) * width + x) * 4
                        pixels.replaceSubrange(destination..<(destination + w * 4), with: bytes[(row * w * 4)..<((row + 1) * w * 4)])
                    }
                }
                await frame(pixels, width, height)
                try await requestUpdate(incremental: true)
            case 2: break // Bell
            case 3:
                let clipboard = try await connection.read(7)
                let length = Int(clipboard.u32(3))
                guard length <= 1_048_576 else { throw XenError.invalid("控制台剪贴板数据过大。") }
                _ = try await connection.read(length) // Remote clipboard is intentionally not written to the system pasteboard.
            default: throw XenError.invalid("不支持的 RFB 消息。")
            }
        }
    }
    private func resize(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_777_216 else { throw XenError.invalid("控制台分辨率超过限制。") }
        self.width = width; self.height = height
        pixels = Data(repeating: 0, count: width * height * 4)
    }
    private func requestUpdate(incremental: Bool) async throws {
        guard let socket else { return }
        try await socket.write(Data([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)]))
    }
    func pointer(x: Int, y: Int, buttons: UInt8) async {
        guard let socket else { return }
        let x = max(0, min(width - 1, x)), y = max(0, min(height - 1, y))
        try? await socket.write(Data([5, buttons, UInt8(x >> 8), UInt8(x & 255), UInt8(y >> 8), UInt8(y & 255)]))
    }
    func key(_ key: UInt32, down: Bool) async {
        guard let socket else { return }
        try? await socket.write(Data([4, down ? 1 : 0, 0, 0, UInt8((key >> 24) & 255), UInt8((key >> 16) & 255), UInt8((key >> 8) & 255), UInt8(key & 255)]))
    }
}

private nonisolated extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) << 8 | UInt16(self[offset + 1]) }
    func u32(_ offset: Int) -> UInt32 { UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3]) }
}

nonisolated final class XenStreamSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "vip.lylab.inchspace.xen.rfb")
    private var buffered = Data()
    init(host: String, port: Int, tls: Bool, allowUntrusted: Bool) {
        let parameters: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            if allowUntrusted {
                sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
            }
            parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
        } else { parameters = .tcp }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: parameters)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = XenConsoleStartGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(nil)
                case .failed(let error): gate.finish(error)
                case .cancelled: gate.finish(CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { [connection] in
                if !gate.completed { connection.cancel() }
            }
        }
    }
    func cancel() { connection.cancel() }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    // Called serially by XenRFBClient. Keep NW receive surplus for CONNECT/RFB boundaries.
    func read(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 64 * 1024 * 1024 else { throw XenError.invalid("控制台帧过大。") }
        while buffered.count < count {
            try Task.checkCancellation()
            let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(max(8192, count - buffered.count), 1_048_576)) { data, _, finished, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if finished { continuation.resume(throwing: XenError.transport("控制台连接已关闭。")) }
                    else { continuation.resume(throwing: XenError.transport("控制台未返回数据。")) }
                }
            }
            buffered.append(bytes)
        }
        let result = Data(buffered.prefix(count)); buffered.removeFirst(count); return result
    }
}

@MainActor
final class XenConsoleWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let client = XenRFBClient()
    private var worker: Task<Void, Never>?
    private let canvas = XenConsoleCanvas(frame: .zero)
    private let status = NSTextField(labelWithString: "正在连接控制台…")
    var closed: (() -> Void)?
    init(name: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "\(name) — 控制台"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 640, height: 480)
        let stack = NSStackView(views: [status, canvas])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        canvas.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.contentView = stack
        canvas.client = client
    }
    func open(location: URL, session: String, allowUntrusted: Bool) {
        window.center(); window.makeKeyAndOrderFront(nil)
        worker = Task { [weak self, client] in
            do {
                try await client.run(location: location, session: session, allowUntrusted: allowUntrusted) { [weak self] bytes, width, height in
                    await self?.receivedFrame(bytes, width: width, height: height)
                }
            } catch { self?.status.stringValue = error.localizedDescription }
        }
    }
    private func receivedFrame(_ bytes: Data, width: Int, height: Int) {
        canvas.update(bytes, width: width, height: height)
        status.stringValue = "点击画面输入 · \(width) × \(height)"
    }
    func close() { window.close() }
    func windowWillClose(_ notification: Notification) {
        worker?.cancel()
        Task { await client.close() }
        closed?()
    }
}

@MainActor
private final class XenConsoleCanvas: NSView {
    var client: XenRFBClient?
    private var image: CGImage?
    private var remoteSize = CGSize.zero
    private var buttons: UInt8 = 0
    private var heldKeys: [UInt16: UInt32] = [:]
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 1024, height: 720) }
    func update(_ bytes: Data, width: Int, height: Int) {
        guard let provider = CGDataProvider(data: bytes as CFData) else { return }
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        remoteSize = CGSize(width: width, height: height); needsDisplay = true
    }
    private var imageRect: CGRect {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return bounds }
        let scale = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        return CGRect(x: (bounds.width - remoteSize.width * scale) / 2, y: (bounds.height - remoteSize.height * scale) / 2, width: remoteSize.width * scale, height: remoteSize.height * scale)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    }
    private func pointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return }
        let x = Int((point.x - rect.minX) / rect.width * remoteSize.width), y = Int((point.y - rect.minY) / rect.height * remoteSize.height)
        let mask = buttons
        Task { await client?.pointer(x: x, y: y, buttons: mask) }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(event) }
    override func mouseUp(with event: NSEvent) { buttons &= ~1; pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func rightMouseDown(with event: NSEvent) { buttons |= 4; pointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~4; pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func scrollWheel(with event: NSEvent) {
        let original = buttons
        buttons |= event.scrollingDeltaY > 0 ? 8 : 16
        pointer(event)
        buttons = original
        pointer(event)
    }
    override func keyDown(with event: NSEvent) {
        let special: [UInt16: UInt32] = [36: 0xff0d, 48: 0xff09, 51: 0xff08, 53: 0xff1b, 123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52, 117: 0xffff]
        let key = special[event.keyCode] ?? event.characters?.unicodeScalars.first.map { $0.value < 256 ? $0.value : 0x01000000 | $0.value }
        guard let key else { return }
        heldKeys[event.keyCode] = key
        Task { await client?.key(key, down: true) }
    }
    override func keyUp(with event: NSEvent) {
        guard let key = heldKeys.removeValue(forKey: event.keyCode) else { return }
        Task { await client?.key(key, down: false) }
    }
    override func flagsChanged(with event: NSEvent) {
        let modifiers: [(NSEvent.ModifierFlags, UInt32)] = [(.shift, 0xffe1), (.control, 0xffe3), (.option, 0xffe9), (.command, 0xffeb)]
        Task { for (flag, symbol) in modifiers { await client?.key(symbol, down: event.modifierFlags.contains(flag)) } }
    }
    override func resignFirstResponder() -> Bool {
        let keys = Array(heldKeys.values); heldKeys = [:]; buttons = 0
        Task {
            for key in keys + [0xffe1, 0xffe3, 0xffe9, 0xffeb] { await client?.key(key, down: false) }
            await client?.pointer(x: 0, y: 0, buttons: 0)
        }
        return super.resignFirstResponder()
    }
}

extension XenClient {
    func consoleLocation(_ vm: XenRecord, identity expected: XenSessionIdentity) async throws -> (URL, String) {
        try requireIdentity(expected)
        let before = try await record(.vm, ref: vm.id)
        guard before.uuid == vm.uuid, before.isVM, before.state == "Running" else { throw XenError.invalid("仅运行中的虚拟机可打开控制台。") }
        let refs = try await call("VM.get_consoles", [.string(vm.id)]).array
        let hosts = try await records(.host)
        let context = try authenticatedEndpoint()
        for ref in refs {
            let console = try await call("console.get_record", [ref]).dictionary
            guard console["protocol"]?.string == "rfb", let url = URL(string: console["location"]?.string ?? ""),
                  let host = url.host, url.user == nil, url.password == nil,
                  ["https", "http"].contains(url.scheme ?? ""),
                  context.0.scheme != "https" || url.scheme == "https",
                  host == context.0.host || hosts.contains(where: { $0["address"].string == host }) else { continue }
            try requireIdentity(expected)
            return (url, context.1)
        }
        throw XenError.invalid("未找到可信的 RFB 控制台地址。")
    }
}

private nonisolated final class XenConsoleStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return continuation == nil }
    func finish(_ error: Error?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
