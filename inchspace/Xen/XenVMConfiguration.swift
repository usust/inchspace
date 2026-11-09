import Foundation

nonisolated struct XenMemoryConfiguration: Sendable {
    var staticMin: Int64
    var dynamicMin: Int64
    var dynamicMax: Int64
    var staticMax: Int64
    func validate() throws {
        guard staticMin >= 0, staticMin <= dynamicMin, dynamicMin <= dynamicMax, dynamicMax <= staticMax, staticMax > 0 else {
            throw XenError.invalid("内存必须满足：固定下限 ≤ 动态下限 ≤ 动态上限 ≤ 启动上限。")
        }
    }
}

extension XenClient {
    func updateMemory(_ vm: XenRecord, configuration: XenMemoryConfiguration, identity expected: XenSessionIdentity) async throws {
        try configuration.validate()
        try await mutate(vm, identity: expected, operation: "memory", validate: { $0.isVM && $0["current_operations"].dictionary.isEmpty }) { before in
            guard before["memory_static_min"].string == String(configuration.staticMin) else { throw XenError.invalid("不能修改模板的固定内存下限。") }
            let offline = before.state == "Halted"
            let changesStatic = before["memory_static_max"].string != String(configuration.staticMax)
            if offline && changesStatic {
                guard before.permits("changing_memory_limits") else { throw XenError.invalid("服务器当前不允许修改内存边界。") }
                _ = try await self.submit("VM.set_memory_limits", [.string(vm.id)] + [configuration.staticMin, configuration.staticMax, configuration.dynamicMin, configuration.dynamicMax].map { .string(String($0)) })
            } else {
                guard ["Running", "Halted"].contains(before.state), before.permits("changing_dynamic_range"),
                      before["memory_static_min"].string == String(configuration.staticMin),
                      before["memory_static_max"].string == String(configuration.staticMax) else {
                    throw XenError.invalid("运行中只能调整原固定边界内的动态内存范围。")
                }
                _ = try await self.submit("VM.set_memory_dynamic_range", [.string(vm.id), .string(String(configuration.dynamicMin)), .string(String(configuration.dynamicMax))])
            }
            let after = try await self.record(.vm, ref: vm.id)
            let matches = after.uuid == vm.uuid && after["memory_dynamic_min"].string == String(configuration.dynamicMin)
                && after["memory_dynamic_max"].string == String(configuration.dynamicMax) && after["memory_static_max"].string == String(configuration.staticMax)
            guard matches else { throw XenError.unknown("内存配置尚未确认，请刷新核对。") }
        }
    }
    func updateCPU(_ vm: XenRecord, count: Int, maximum requestedMaximum: Int? = nil, identity expected: XenSessionIdentity) async throws {
        guard (1...4096).contains(count), requestedMaximum.map({ (count...4096).contains($0) }) ?? true else { throw XenError.invalid("vCPU 数量不正确。") }
        try await mutate(vm, identity: expected, operation: "cpu", validate: { $0.isVM && $0["current_operations"].dictionary.isEmpty }) { before in
            if before.state == "Running" {
                guard before.permits("changing_VCPUs_live"), count <= Int(before["VCPUs_max"].string) ?? 0 else { throw XenError.invalid("运行中只能在启动上限内调整 vCPU。") }
                _ = try await self.submit("VM.set_VCPUs_number_live", [.string(vm.id), .string(String(count))])
            } else if before.state == "Halted" {
                let maximum = Int(before["VCPUs_max"].string) ?? 0
                let desiredMaximum = requestedMaximum ?? count
                let setters = desiredMaximum > maximum ? ["set_VCPUs_max", "set_VCPUs_at_startup"] : ["set_VCPUs_at_startup", "set_VCPUs_max"]
                for setter in setters {
                    let value = setter == "set_VCPUs_max" ? desiredMaximum : count
                    _ = try await self.submit("VM.\(setter)", [.string(vm.id), .string(String(value))])
                }
            } else { throw XenError.invalid("请先关闭或恢复 VM，再调整 vCPU。") }
            let after = try await self.record(.vm, ref: vm.id)
            guard after.uuid == vm.uuid, after["VCPUs_at_startup"].string == String(count), before.state != "Halted" || after["VCPUs_max"].string == String(requestedMaximum ?? count) else { throw XenError.unknown("vCPU 可能仅部分保存，请刷新核对。") }
        }
    }
    func setDeletionProtection(_ vm: XenRecord, enabled: Bool, identity expected: XenSessionIdentity) async throws {
        try await mutate(vm, identity: expected, operation: "protection", validate: { $0.isVM }) { before in
            let existing = before["blocked_operations"].dictionary["destroy"]
            if enabled && existing == nil {
                _ = try await self.submit("VM.add_to_blocked_operations", [.string(vm.id), .string("destroy"), .string("inchspace: deletion protection")])
            } else if !enabled && existing != nil {
                _ = try await self.submit("VM.remove_from_blocked_operations", [.string(vm.id), .string("destroy")])
            }
            let after = try await self.record(.vm, ref: vm.id)
            guard after.uuid == vm.uuid, (after["blocked_operations"].dictionary["destroy"] != nil) == enabled else { throw XenError.unknown("删除保护状态尚未确认。") }
        }
    }
    func setBootOrder(_ vm: XenRecord, order: String, identity expected: XenSessionIdentity) async throws {
        guard !order.isEmpty, order.allSatisfy({ "cdn".contains($0) }), Set(order).count == order.count else { throw XenError.invalid("启动顺序仅接受 c（磁盘）、d（光驱）、n（网络），不能重复。") }
        try await mutate(vm, identity: expected, operation: "boot", validate: { $0.isVM && $0.state == "Halted" }) { _ in
            _ = try await self.submit("VM.add_to_HVM_boot_params", [.string(vm.id), .string("order"), .string(order)])
            let after = try await self.record(.vm, ref: vm.id)
            guard after.uuid == vm.uuid, after["HVM_boot_params"].dictionary["order"]?.string == order else { throw XenError.unknown("启动顺序尚未确认。") }
        }
    }
    func restoreSnapshot(_ snapshot: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(snapshot, identity: expected, operation: "revert", validate: { $0["is_a_snapshot"].boolean && $0.permits("revert") }) { before in
            let original = before["snapshot_of"].string
            let vm = try await self.record(.vm, ref: original)
            guard vm.isVM, vm.state == "Halted", vm["current_operations"].dictionary.isEmpty else { throw XenError.invalid("请先关闭原虚拟机，再恢复快照。") }
            let task = try await self.submit("Async.VM.revert", [.string(before.id)])
            _ = try await self.waitForTask(task, identity: expected)
        }
    }
    func deleteSnapshotOrTemplate(_ target: XenRecord, identity expected: XenSessionIdentity) async throws {
        try await mutate(target, identity: expected, operation: "destroy", validate: {
            ($0["is_a_snapshot"].boolean || $0["is_a_template"].boolean) && !$0["is_control_domain"].boolean && $0.permits("destroy")
                && !$0["other_config"].dictionary["default_template", default: .null].boolean
        }) { before in
            _ = try await self.submit("VM.destroy", [.string(before.id)])
            do {
                _ = try await self.record(before.kind, ref: before.id)
                throw XenError.unknown("对象删除结果尚未确认。")
            } catch XenError.api(let code, _) where code == "HANDLE_INVALID" { return }
        }
    }
    /// Only same-pool template cloning; storage-move/copy and cross-pool mutations stay guarded.
    func createFromTemplate(_ template: XenRecord, name: String, identity expected: XenSessionIdentity) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw XenError.invalid("请填写名称。") }
        try await mutate(template, identity: expected, operation: "clone", validate: { $0["is_a_template"].boolean && !$0["is_a_snapshot"].boolean && $0.permits("clone") }) { before in
            let result = try await self.submit("VM.clone", [.string(before.id), .string(name)])
            let ref = result.string
            guard ref.hasPrefix("OpaqueRef:"), ref != "OpaqueRef:NULL" else { throw XenError.unknown("创建响应缺少 VM 引用，请核对资源清单。") }
            do {
                _ = try await self.submit("VM.provision", [.string(ref)])
                let vm = try await self.record(.vm, ref: ref)
                guard vm.isVM, vm.name == name else { throw XenError.unknown("VM 已创建但配置结果尚未确认。") }
            } catch { throw XenError.unknown("已创建对象 \(ref)，但后续配置未完成：\(error.localizedDescription)。对象已保留，请勿重复创建。") }
        }
    }
}

nonisolated enum XenTaskResult {
    static func reference(_ value: XenValue) throws -> String {
        var result = value
        if case .string(let xml) = value, xml.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            result = try XenXMLRPC.decode(Data("<methodResponse><params><param>\(xml)</param></params></methodResponse>".utf8))
        }
        if case .array(let values) = result, values.count == 1 { result = values[0] }
        let ref = result.string
        guard ref.hasPrefix("OpaqueRef:"), ref != "OpaqueRef:NULL" else { throw XenError.unknown("任务结果缺少有效对象引用。") }
        return ref
    }
}

extension XenClient {
    func exportSnapshot(_ vm: XenRecord, identity expected: XenSessionIdentity) async throws -> XenRecord {
        var target: XenRecord?
        try await mutate(vm, identity: expected, operation: "checkpoint", validate: { $0.isVM && $0.state == "Running" && $0.permits("checkpoint") }) { before in
            let task = try await self.submit("Async.VM.checkpoint", [.string(before.id), .string("\(before.name) — XVA 导出快照")])
            let result = try await self.waitForTask(task, identity: expected)
            let ref = try XenTaskResult.reference(result)
            let snapshot = try await self.record(.snapshot, ref: ref)
            guard snapshot["is_a_snapshot"].boolean, snapshot["snapshot_of"].string == vm.id else { throw XenError.unknown("导出快照归属尚未确认。") }
            target = snapshot
        }
        guard let target else { throw XenError.unknown("导出快照未确认。") }
        return target
    }
}
