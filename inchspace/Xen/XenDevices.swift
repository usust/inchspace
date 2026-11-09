import Foundation

extension XenClient {
    func createNetwork(name: String, mtu: Int, identity expected: XenSessionIdentity) async throws {
        try requireIdentity(expected)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (576...9000).contains(mtu) else { throw XenError.invalid("请填写网络名称及有效 MTU（576–9000）。") }
        let ref = try await submit("network.create", [.dictionary([
            "name_label": .string(name), "name_description": .string(""), "MTU": .string(String(mtu)), "other_config": .dictionary([:]), "tags": .array([])
        ])]).string
        try requireIdentity(expected)
        let network = try await record(.network, ref: ref)
        guard network.name == name else { throw XenError.unknown("网络已创建，但读回结果尚未确认。") }
    }
    func deleteNetwork(_ network: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(network, identity: expected, operation: "destroy", validate: {
            $0["PIFs"].array.isEmpty && $0["VIFs"].array.isEmpty && $0.permits("destroy")
        }) { before in
            _ = try await self.submit("network.destroy", [.string(before.id)])
            do { _ = try await self.record(.network, ref: before.id); throw XenError.unknown("网络删除结果尚未确认。") }
            catch XenError.api(let code, _) where code == "HANDLE_INVALID" { return }
        }
    }
    func createVIF(_ vm: XenRecord, network: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "vif", validate: { $0.isVM && ["Running", "Halted"].contains($0.state) && $0["current_operations"].dictionary.isEmpty }) { before in
            let currentNetwork = try await self.record(.network, ref: network.id)
            guard currentNetwork.uuid == network.uuid else { throw XenError.invalid("所选网络已变化。") }
            let devices = try await self.call("VM.get_allowed_VIF_devices", [.string(before.id)]).array.map(\.string)
            guard let device = devices.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }).first else { throw XenError.invalid("没有可用网卡设备号。") }
            let ref = try await self.submit("VIF.create", [.dictionary([
                "VM": .string(before.id), "network": .string(network.id), "device": .string(device), "MAC": .string(""),
                "MTU": currentNetwork["MTU"], "other_config": .dictionary([:]), "qos_algorithm_type": .string(""),
                "qos_algorithm_params": .dictionary([:]), "locking_mode": .string("network_default"), "ipv4_allowed": .array([]), "ipv6_allowed": .array([])
            ])]).string
            guard ref.hasPrefix("OpaqueRef:"), ref != "OpaqueRef:NULL" else { throw XenError.unknown("网卡创建结果未知，请刷新设备清单。") }
            if before.state == "Running" {
                do { _ = try await self.submit("VIF.plug", [.string(ref)]) }
                catch { throw XenError.unknown("网卡 \(ref) 已创建，但连接结果未确认：\(error.localizedDescription)") }
            }
            let after = try await self.call("VIF.get_record", [.string(ref)]).dictionary
            guard after["VM"]?.string == vm.id, after["network"]?.string == network.id else { throw XenError.unknown("网卡已创建，但归属尚未确认。") }
        }
    }
    func changeDevice(_ vm: XenRecord, api: String, ref: String, uuid: String, operation: String, identity expected: XenSessionIdentity) async throws {
        guard ["VIF", "VBD"].contains(api), ["plug", "unplug", "destroy", "eject"].contains(operation) else { throw XenError.invalid("不支持的设备操作。") }
        try await mutate(vm, identity: expected, operation: operation, validate: { $0.isVM && $0["current_operations"].dictionary.isEmpty }) { _ in
            let before = try await self.call("\(api).get_record", [.string(ref)]).dictionary
            guard before["uuid"]?.string == uuid, before["VM"]?.string == vm.id,
                  before["allowed_operations"]?.array.contains(.string(operation)) == true else { throw XenError.invalid("设备已变化或当前不允许此操作。") }
            if operation == "destroy", before["currently_attached"]?.boolean == true { throw XenError.invalid("请先断开网卡。") }
            if operation == "eject", before["type"]?.string != "CD" { throw XenError.invalid("仅光驱可以弹出介质。") }
            _ = try await self.submit("\(api).\(operation)", [.string(ref)])
            do {
                let after = try await self.call("\(api).get_record", [.string(ref)]).dictionary
                guard operation != "destroy", after["uuid"]?.string == uuid else { throw XenError.unknown("设备操作结果尚未确认。") }
                if ["plug", "unplug"].contains(operation), after["currently_attached"]?.boolean != (operation == "plug") {
                    throw XenError.unknown("设备连接状态尚未确认。")
                }
                if operation == "eject", after["empty"]?.boolean != true { throw XenError.unknown("光盘弹出结果尚未确认。") }
            } catch XenError.api(let code, _) where code == "HANDLE_INVALID" && operation == "destroy" { return }
        }
    }
    func resizeDisk(_ disk: XenRecord, bytes: Int64, identity expected: XenSessionIdentity) async throws {
        guard bytes > 0 else { throw XenError.invalid("请输入有效容量。") }
        try await mutate(disk, identity: expected, operation: "resize", validate: {
            ($0.permits("resize") || $0.permits("resize_online")) && !$0["read_only"].boolean && !$0["is_a_snapshot"].boolean
        }) { before in
            guard let old = Int64(before["virtual_size"].string), old >= 0, bytes > old else { throw XenError.invalid("只能扩大虚拟磁盘，请刷新容量。") }
            let sr = try await self.record(.storage, ref: before["SR"].string)
            guard let total = Int64(sr["physical_size"].string), let used = Int64(sr["physical_utilisation"].string), total >= 0, used >= 0, total >= used, total - used >= bytes - old else { throw XenError.invalid("存储仓库空间不足。") }
            var online = false
            for ref in before["VBDs"].array {
                let vbd = try await self.call("VBD.get_record", [ref]).dictionary
                let vm = try await self.record(.vm, ref: vbd["VM"]?.string ?? "")
                guard ["Halted", "Running"].contains(vm.state), vm["current_operations"].dictionary.isEmpty else { throw XenError.invalid("关联 VM 当前不允许调整磁盘。") }
                if vm.state == "Running" && vbd["currently_attached"]?.boolean == true { online = true }
            }
            let operation = online ? "resize_online" : before.permits("resize") ? "resize" : "resize_online"
            guard before.permits(operation) else { throw XenError.invalid("服务器当前不支持此磁盘的在线扩容。") }
            _ = try await self.submit("VDI.\(operation)", [.string(before.id), .string(String(bytes))])
            let after = try await self.record(.disk, ref: before.id)
            guard after.uuid == before.uuid, after["virtual_size"].string == String(bytes) else { throw XenError.unknown("磁盘扩容结果尚未确认。") }
        }
    }
    func deleteUnusedDisk(_ disk: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(disk, identity: expected, operation: "destroy", validate: { $0.permits("destroy") && $0["VBDs"].array.isEmpty && !$0["is_a_snapshot"].boolean }) { before in
            _ = try await self.submit("VDI.destroy", [.string(before.id)])
            do { _ = try await self.record(.disk, ref: before.id); throw XenError.unknown("磁盘删除结果尚未确认。") }
            catch XenError.api(let code, _) where code == "HANDLE_INVALID" { return }
        }
    }
    func scanStorage(_ sr: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(sr, identity: expected, operation: "scan", validate: { $0.permits("scan") }) { before in
            let task = try await self.submit("Async.SR.scan", [.string(before.id)])
            _ = try await self.waitForTask(task, identity: expected)
        }
    }
    func cancelTask(_ task: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(task, identity: expected, operation: "cancel", validate: { $0["status"].string == "pending" && $0.permits("cancel") }) { before in
            _ = try await self.submit("task.cancel", [.string(before.id)])
        }
    }
}

extension XenClient {
    func addDisk(_ vm: XenRecord, storage: XenRecord, name: String, bytes: Int64, identity expected: XenSessionIdentity) async throws {
        guard bytes > 0, !name.isEmpty else { throw XenError.invalid("磁盘名称和容量不正确。") }
        try await mutate(vm, identity: expected, operation: "disk", validate: { $0.isVM && ["Halted", "Running"].contains($0.state) && $0["current_operations"].dictionary.isEmpty }) { before in
            let sr = try await self.record(.storage, ref: storage.id)
            guard sr.uuid == storage.uuid, sr["type"].string != "iso", sr["content_type"].string != "iso",
                  let total = Int64(sr["physical_size"].string), let used = Int64(sr["physical_utilisation"].string), total >= 0, used >= 0, total >= used, total - used >= bytes else { throw XenError.invalid("存储仓库不可用或空间不足。") }
            var attached = false
            for ref in sr["PBDs"].array {
                let pbd = try await self.call("PBD.get_record", [ref]).dictionary
                if pbd["currently_attached"]?.boolean == true && (before.state == "Halted" || pbd["host"]?.string == before["resident_on"].string) { attached = true }
            }
            guard attached else { throw XenError.invalid("存储未接入可用主机。") }
            let devices = try await self.call("VM.get_allowed_VBD_devices", [.string(before.id)]).array.map(\.string)
            guard let device = devices.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }).first else { throw XenError.invalid("没有可用磁盘设备号。") }
            let ref = try await self.submit("VDI.create", [.dictionary([
                "name_label": .string(name), "name_description": .string(""), "SR": .string(sr.id), "virtual_size": .string(String(bytes)),
                "type": .string("user"), "sharable": .bool(false), "read_only": .bool(false), "other_config": .dictionary([:]),
                "xenstore_data": .dictionary([:]), "sm_config": .dictionary([:]), "tags": .array([])
            ])]).string
            guard ref.hasPrefix("OpaqueRef:"), ref != "OpaqueRef:NULL" else { throw XenError.unknown("虚拟磁盘创建结果未知，请核对存储清单。") }
            do {
                let vbd = try await self.submit("VBD.create", [.dictionary([
                    "VM": .string(vm.id), "VDI": .string(ref), "userdevice": .string(device), "bootable": .bool(device == "0"),
                    "mode": .string("RW"), "type": .string("Disk"), "unpluggable": .bool(true), "empty": .bool(false),
                    "other_config": .dictionary(["owner": .string("true")]), "qos_algorithm_type": .string(""), "qos_algorithm_params": .dictionary([:])
                ])]).string
                if before.state == "Running" { _ = try await self.submit("VBD.plug", [.string(vbd)]) }
                let after = try await self.call("VBD.get_record", [.string(vbd)]).dictionary
                guard after["VM"]?.string == vm.id, after["VDI"]?.string == ref else { throw XenError.unknown("磁盘挂载结果尚未确认。") }
            } catch { throw XenError.unknown("虚拟磁盘 \(ref) 已创建，后续挂载未完成；磁盘已保留，请核对后处理。\(error.localizedDescription)") }
        }
    }
    func insertISO(_ vm: XenRecord, disk: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "iso", validate: { $0.isVM && $0["current_operations"].dictionary.isEmpty }) { before in
            let iso = try await self.record(.disk, ref: disk.id)
            guard iso.uuid == disk.uuid, iso["type"].string == "iso" || iso["read_only"].boolean else { throw XenError.invalid("请选择有效的只读 ISO 镜像。") }
            var cdRef: String?
            for ref in before["VBDs"].array {
                let vbd = try await self.call("VBD.get_record", [ref]).dictionary
                if vbd["type"]?.string == "CD" {
                    guard vbd["empty"]?.boolean == true else { throw XenError.invalid("请先弹出现有光盘。") }
                    cdRef = ref.string; break
                }
            }
            if cdRef == nil {
                guard before.state == "Halted" else { throw XenError.invalid("需关机后创建光驱。") }
                let devices = try await self.call("VM.get_allowed_VBD_devices", [.string(vm.id)]).array.map(\.string)
                guard let device = devices.contains("3") ? "3" : devices.first else { throw XenError.invalid("没有可用光驱设备号。") }
                cdRef = try await self.submit("VBD.create", [.dictionary([
                    "VM": .string(vm.id), "VDI": .string("OpaqueRef:NULL"), "userdevice": .string(device), "bootable": .bool(true),
                    "mode": .string("RO"), "type": .string("CD"), "unpluggable": .bool(true), "empty": .bool(true),
                    "other_config": .dictionary([:]), "qos_algorithm_type": .string(""), "qos_algorithm_params": .dictionary([:])
                ])]).string
            }
            guard let cdRef else { throw XenError.unknown("光驱创建结果未知。") }
            _ = try await self.submit("VBD.insert", [.string(cdRef), .string(iso.id)])
            let after = try await self.call("VBD.get_record", [.string(cdRef)]).dictionary
            guard after["VDI"]?.string == iso.id, after["VM"]?.string == vm.id else { throw XenError.unknown("光盘挂载结果尚未确认。") }
        }
    }
}

extension XenClient {
    func attachDisk(_ vm: XenRecord, disk: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "attach", validate: { $0.isVM && ["Halted", "Running"].contains($0.state) && $0["current_operations"].dictionary.isEmpty }) { before in
            let current = try await self.record(.disk, ref: disk.id)
            guard current.uuid == disk.uuid, !current["read_only"].boolean, current["type"].string != "iso", !current["is_a_snapshot"].boolean,
                  current["VBDs"].array.isEmpty || current["sharable"].boolean else { throw XenError.invalid("所选磁盘不可用，或已被其他虚拟机使用。") }
            let sr = try await self.record(.storage, ref: current["SR"].string)
            var attached = false
            for ref in sr["PBDs"].array {
                let pbd = try await self.call("PBD.get_record", [ref]).dictionary
                if pbd["currently_attached"]?.boolean == true && (before.state == "Halted" || pbd["host"]?.string == before["resident_on"].string) { attached = true }
            }
            guard attached else { throw XenError.invalid("磁盘所属存储未接入可用主机。") }
            let devices = try await self.call("VM.get_allowed_VBD_devices", [.string(vm.id)]).array.map(\.string)
            guard let device = devices.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }).first else { throw XenError.invalid("没有可用设备号。") }
            let ref = try await self.submit("VBD.create", [.dictionary([
                "VM": .string(vm.id), "VDI": .string(disk.id), "userdevice": .string(device), "bootable": .bool(false), "mode": .string("RW"),
                "type": .string("Disk"), "unpluggable": .bool(true), "empty": .bool(false), "other_config": .dictionary([:]),
                "qos_algorithm_type": .string(""), "qos_algorithm_params": .dictionary([:])
            ])]).string
            guard ref.hasPrefix("OpaqueRef:"), ref != "OpaqueRef:NULL" else { throw XenError.unknown("磁盘设备创建结果未知。") }
            if before.state == "Running" { _ = try await self.submit("VBD.plug", [.string(ref)]) }
            let after = try await self.call("VBD.get_record", [.string(ref)]).dictionary
            guard after["VM"]?.string == vm.id, after["VDI"]?.string == disk.id else { throw XenError.unknown("磁盘连接结果尚未确认，请核对设备清单。") }
        }
    }
}
