import Foundation

nonisolated struct XenXVAPreview: Sendable {
    let name: String
    let vcpus: String
    let memory: XenValue
    let disks: Int
    let networkNames: [String]
    var interfaces: [(device: String, network: String)] = []
}

nonisolated enum XenXVA {
    /// Reads tar headers with FileHandle; never extracts paths or loads disk chunks into memory.
    static func preview(_ url: URL) throws -> XenXVAPreview {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        var offset: UInt64 = 0
        for _ in 0..<4096 {
            guard offset <= length, length - offset >= 512 else { break }
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 512), header.count == 512, header.contains(where: { $0 != 0 }) else { break }
            func text(_ range: Range<Int>) -> String { String(decoding: header[range].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let size = UInt64(text(124..<136), radix: 8), size <= length - offset - 512,
                  let checksum = UInt64(text(148..<156), radix: 8) else { throw XenError.invalid("XVA tar 文件头无效或文件不完整。") }
            let calculated = header.enumerated().reduce(UInt64(0)) { $0 + UInt64((148..<156).contains($1.offset) ? 32 : $1.element) }
            guard checksum == calculated else { throw XenError.invalid("XVA tar 文件头校验失败。") }
            let name = text(0..<100)
            if name == "ova.xml" || name.hasSuffix("/ova.xml") {
                guard size > 0, size <= 16 * 1024 * 1024, let data = try file.read(upToCount: Int(size)), data.count == Int(size) else { throw XenError.invalid("XVA 元数据过大或不完整。") }
                var xml = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if xml.hasPrefix("<?xml"), let end = xml.range(of: "?>") { xml = String(xml[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
                if xml.hasPrefix("<struct") { xml = "<value>\(xml)</value>" }
                let value = try XenXMLRPC.decode(Data("<methodResponse><params><param>\(xml)</param></params></methodResponse>".utf8))
                let objects = value.dictionary["objects"]?.array.map(\.dictionary) ?? []
                guard let vm = objects.first(where: { $0["class"]?.string == "VM" })?["snapshot"]?.dictionary else { throw XenError.invalid("XVA 中未找到可识别的 VM 元数据。") }
                let networks = objects.filter { $0["class"]?.string == "network" }
                var networkNames: [String: String] = [:]
                for network in networks { networkNames[network["id"]?.string ?? ""] = network["snapshot"]?.dictionary["name_label"]?.string ?? "网络" }
                let interfaces = objects.filter { $0["class"]?.string == "VIF" }.compactMap { object -> (device: String, network: String)? in
                    guard let fields = object["snapshot"]?.dictionary, let device = fields["device"]?.string, !device.isEmpty else { return nil }
                    return (device, networkNames[fields["network"]?.string ?? ""] ?? "源网络")
                }
                guard Set(interfaces.map(\.device)).count == interfaces.count else { throw XenError.invalid("XVA 包含重复网卡设备号。") }
                return XenXVAPreview(name: vm["name_label"]?.string ?? url.deletingPathExtension().lastPathComponent,
                                     vcpus: vm["VCPUs_max"]?.string ?? "—", memory: vm["memory_static_max"] ?? .null,
                                     disks: objects.filter { $0["class"]?.string == "VDI" }.count,
                                     networkNames: networks.compactMap { $0["snapshot"]?.dictionary["name_label"]?.string }, interfaces: interfaces)
            }
            offset += 512 + ((size + 511) / 512) * 512
        }
        throw XenError.invalid("XVA 文件中未找到 ova.xml，或归档格式暂不支持。")
    }
}

extension XenClient {
    func convertToTemplate(_ vm: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "template", validate: {
            $0.isVM && $0.state == "Halted" && $0["current_operations"].dictionary.isEmpty
                && ($0["appliance"].string.isEmpty || $0["appliance"].string == "OpaqueRef:NULL")
        }) { before in
            _ = try await self.submit("VM.set_is_a_template", [.string(before.id), .bool(true)])
            let after = try await self.record(.template, ref: before.id)
            guard after.uuid == before.uuid, after["is_a_template"].boolean else { throw XenError.unknown("模板转换结果尚未确认。") }
        }
    }
}

extension XenClient {
    func remapImportedInterfaces(_ vm: XenRecord, mappings: [String: XenRecord], identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "import-network", validate: { ($0.isVM || $0["is_a_template"].boolean) && $0.state == "Halted" && $0["current_operations"].dictionary.isEmpty }) { before in
            for ref in before["VIFs"].array {
                let vif = try await self.call("VIF.get_record", [ref]).dictionary
                let device = vif["device"]?.string ?? ""
                guard let target = mappings[device] else { continue }
                let network = try await self.record(.network, ref: target.id)
                guard network.uuid == target.uuid, vif["VM"]?.string == vm.id, vif["currently_attached"]?.boolean == false else { throw XenError.invalid("导入网卡或目标网络已变化。") }
                if vif["network"]?.string == target.id { continue }
                _ = try await self.submit("VIF.destroy", [ref])
                let created = try await self.submit("VIF.create", [.dictionary([
                    "VM": .string(vm.id), "network": .string(target.id), "device": .string(device), "MAC": vif["MAC"] ?? .string(""),
                    "MTU": network["MTU"], "other_config": vif["other_config"] ?? .dictionary([:]),
                    "qos_algorithm_type": vif["qos_algorithm_type"] ?? .string(""), "qos_algorithm_params": vif["qos_algorithm_params"] ?? .dictionary([:]),
                    "locking_mode": .string("network_default"), "ipv4_allowed": .array([]), "ipv6_allowed": .array([])
                ])])
                let after = try await self.call("VIF.get_record", [created]).dictionary
                guard after["VM"]?.string == vm.id, after["network"]?.string == target.id, after["device"]?.string == device else { throw XenError.unknown("导入已完成，但网卡映射尚未确认，请检查设备清单。") }
            }
        }
    }
}
