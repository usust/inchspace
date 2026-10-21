import Compression
import Foundation

/// Reads only Word's document XML from an OOXML ZIP. No embedded resources or links are loaded.
nonisolated enum ArchiveWordExtractor {
    static func text(from data: Data) throws -> String {
        // ZIP64, encrypted entries and XML larger than 5 MB are deliberately unsupported.
        guard data.count >= 22 else { throw ArchiveError("Word 文档不是有效的 ZIP 文件。") }
        let searchStart = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: searchStart, by: -1).first(where: {
            uint32(data, $0) == 0x06054b50 && $0 + 22 + Int(uint16(data, $0 + 20)) == data.count
        }) else { throw ArchiveError("Word 文档目录损坏。") }
        let count = Int(uint16(data, end + 10))
        let directorySize = Int(uint32(data, end + 12))
        let directoryStart = Int(uint32(data, end + 16))
        guard uint16(data, end + 4) == 0, uint16(data, end + 6) == 0,
              uint16(data, end + 8) == uint16(data, end + 10), count <= 10_000,
              directoryStart <= end, directorySize <= end - directoryStart else {
            throw ArchiveError("不支持分卷、ZIP64 或过大的 Word 文档。")
        }
        var offset = directoryStart
        for _ in 0..<count {
            guard offset <= end - 46, uint32(data, offset) == 0x02014b50 else { throw ArchiveError("Word 文档目录损坏。") }
            let flags = uint16(data, offset + 8)
            let method = uint16(data, offset + 10)
            let compressed = Int(uint32(data, offset + 20))
            let expanded = Int(uint32(data, offset + 24))
            let nameLength = Int(uint16(data, offset + 28))
            let extraLength = Int(uint16(data, offset + 30))
            let commentLength = Int(uint16(data, offset + 32))
            let localOffset = Int(uint32(data, offset + 42))
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard next <= directoryStart + directorySize, next <= end else { throw ArchiveError("Word 文档目录越界。") }
            let name = String(data: data.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8)
            if name == "word/document.xml" {
                guard flags & 1 == 0, expanded > 0, expanded <= 5_000_000, compressed > 0, compressed <= data.count,
                      localOffset <= directoryStart - 30, uint32(data, localOffset) == 0x04034b50,
                      uint16(data, localOffset + 8) == method else {
                    throw ArchiveError("Word 正文已加密、损坏或超过 5 MB。")
                }
                let start = localOffset + 30 + Int(uint16(data, localOffset + 26)) + Int(uint16(data, localOffset + 28))
                guard start <= directoryStart, compressed <= directoryStart - start else { throw ArchiveError("Word 正文越界。") }
                let input = data.subdata(in: start..<start + compressed)
                let xml: Data
                if method == 0 {
                    guard compressed == expanded else { throw ArchiveError("Word 正文大小不匹配。") }
                    xml = input
                } else if method == 8 {
                    var output = [UInt8](repeating: 0, count: expanded + 1)
                    let decoded = output.withUnsafeMutableBufferPointer { destination in
                        input.withUnsafeBytes { source in
                            compression_decode_buffer(destination.baseAddress!, destination.count,
                                                      source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                                      nil, COMPRESSION_ZLIB)
                        }
                    }
                    guard decoded == expanded else { throw ArchiveError("Word 正文无法解压或大小不匹配。") }
                    xml = Data(output.prefix(decoded))
                } else { throw ArchiveError("Word 文档使用了不支持的压缩方式。") }
                let collector = WordTextCollector()
                let parser = XMLParser(data: xml)
                parser.shouldProcessNamespaces = true
                parser.shouldResolveExternalEntities = false
                parser.delegate = collector
                guard parser.parse() || collector.reachedLimit, !collector.rejectedDTD else {
                    throw ArchiveError("Word 正文 XML 无效或包含不支持的实体。")
                }
                return collector.text
            }
            offset = next
        }
        throw ArchiveError("Word 文档没有找到正文。")
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

nonisolated private final class WordTextCollector: NSObject, XMLParserDelegate {
    var text = ""
    var reachedLimit = false
    var rejectedDTD = false
    private var insideText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "t" { insideText = true }
        if ["tab", "br", "cr"].contains(elementName) { append(" ", parser: parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideText else { return }
        append(string, parser: parser)
    }

    private func append(_ string: String, parser: XMLParser) {
        text += String(string.prefix(max(0, 12_000 - text.count)))
        if text.count >= 12_000 { reachedLimit = true; parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            self.parser(parser, foundCharacters: string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { insideText = false }
        if elementName == "p" { append("\n", parser: parser) }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        rejectedDTD = true
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        rejectedDTD = true
        parser.abortParsing()
    }
}
