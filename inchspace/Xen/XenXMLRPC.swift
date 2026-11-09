import Foundation

/// Strict, bounded XML-RPC codec implemented with Foundation. External entities are never resolved.
nonisolated enum XenXMLRPC {
    static func request(method: String, parameters: [XenValue]) -> Data {
        let params = parameters.map { "<param>\(encode($0))</param>" }.joined()
        return Data("<?xml version=\"1.0\"?><methodCall><methodName>\(escape(method))</methodName><params>\(params)</params></methodCall>".utf8)
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    static func encode(_ value: XenValue) -> String {
        let content: String
        switch value {
        case .string(let string): content = "<string>\(escape(string))</string>"
        case .integer(let number): content = "<i8>\(number)</i8>"
        case .double(let number): content = "<double>\(number)</double>"
        case .bool(let flag): content = "<boolean>\(flag ? 1 : 0)</boolean>"
        case .array(let values): content = "<array><data>\(values.map(encode).joined())</data></array>"
        case .dictionary(let values): content = "<struct>" + values.keys.sorted().map { "<member><name>\(escape($0))</name>\(encode(values[$0]!))</member>" }.joined() + "</struct>"
        case .null: content = "<nil/>"
        }
        return "<value>\(content)</value>"
    }
    static func decode(_ data: Data) throws -> XenValue {
        guard data.count <= 32 * 1024 * 1024 else { throw XenError.invalid("XML-RPC 响应超过大小限制。") }
        let delegate = XenXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root, root.name == "methodResponse" else {
            throw XenError.invalid("服务器返回了无效的 XML-RPC 响应。")
        }
        if let fault = root.children.first(where: { $0.name == "fault" }) {
            let fields = try decodeValue(fault.child("value")).dictionary
            throw XenError.api("XMLRPC_FAULT", [fields["faultCode"]?.string ?? "", fields["faultString"]?.string ?? ""])
        }
        let params = try root.child("params")
        guard params.children.count == 1 else { throw XenError.invalid("XML-RPC 响应参数数量不正确。") }
        return try decodeValue(params.child("param").child("value"))
    }
    static func result(_ data: Data) throws -> XenValue {
        let envelope = try decode(data).dictionary
        switch envelope["Status"]?.string {
        case "Success":
            guard let value = envelope["Value"] else { throw XenError.invalid("XAPI 响应缺少 Value。") }
            return value
        case "Failure":
            let errors = envelope["ErrorDescription"]?.array.map(\.string) ?? []
            guard let code = errors.first else { throw XenError.invalid("XAPI 错误响应无效。") }
            throw XenError.api(code, Array(errors.dropFirst()))
        default: throw XenError.invalid("服务器未返回 XAPI 状态。")
        }
    }
    private static func decodeValue(_ node: XenXMLNode) throws -> XenValue {
        guard node.name == "value", node.children.count <= 1 else { throw XenError.invalid("XML-RPC value 无效。") }
        guard let typed = node.children.first else { return .string(node.text) }
        switch typed.name {
        case "string", "dateTime.iso8601", "base64": return .string(typed.text)
        case "int", "i4", "i8":
            guard let value = Int64(typed.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw XenError.invalid("XML-RPC 整数无效。") }
            return .integer(value)
        case "double":
            guard let value = Double(typed.text), value.isFinite else { throw XenError.invalid("XML-RPC 数值无效。") }
            return .double(value)
        case "boolean":
            guard ["0", "1"].contains(typed.text) else { throw XenError.invalid("XML-RPC 布尔值无效。") }
            return .bool(typed.text == "1")
        case "nil": return .null
        case "array": return .array(try typed.child("data").children.map { try decodeValue($0) })
        case "struct":
            var fields: [String: XenValue] = [:]
            for member in typed.children {
                guard member.name == "member", member.children.count == 2 else { throw XenError.invalid("XML-RPC 字段无效。") }
                let name = try member.child("name").text
                guard fields[name] == nil else { throw XenError.invalid("XML-RPC 包含重复字段。") }
                fields[name] = try decodeValue(member.child("value"))
            }
            return .dictionary(fields)
        default: throw XenError.invalid("不支持的 XML-RPC 类型：\(typed.name)")
        }
    }
}

private nonisolated final class XenXMLNode {
    let name: String
    var text = ""
    var children: [XenXMLNode] = []
    init(_ name: String) { self.name = name }
    func child(_ name: String) throws -> XenXMLNode {
        let matches = children.filter { $0.name == name }
        guard matches.count == 1, let node = matches.first else { throw XenError.invalid("XML-RPC 缺少或重复 \(name)。") }
        return node
    }
}

private nonisolated final class XenXMLParser: NSObject, XMLParserDelegate {
    var root: XenXMLNode?
    var invalid = false
    private var stack: [XenXMLNode] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 64 else { invalid = true; parser.abortParsing(); return }
        let node = XenXMLNode(elementName)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { invalid = true; parser.abortParsing(); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}
