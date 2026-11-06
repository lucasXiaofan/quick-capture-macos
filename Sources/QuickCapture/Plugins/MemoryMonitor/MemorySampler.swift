import AppKit
import Darwin

/// One reading of system memory, in bytes. Same definitions as Activity Monitor's Memory tab:
/// used = app + wired + compressed; "cached files" (file-backed + purgeable) is NOT in used, and is where
/// mmap'd model weights (llama.cpp, LM Studio) live.
struct MemSample: Identifiable {
    let id = UUID()
    let time: Date
    let total: Double
    let app: Double
    let wired: Double
    let compressed: Double
    let cached: Double
    let free: Double
    let swapUsed: Double
    let pressure: Int  // 1 normal, 2 warning, 4 critical

    var used: Double { app + wired + compressed }
    /// What a new model can still get without swapping: total minus used (cached files are given back on demand).
    var available: Double { total - used }
}

struct AppRow: Identifiable {
    let id: pid_t
    let name: String
    let bundleID: String
    let footprint: Double
    let icon: NSImage?
    let app: NSRunningApplication
}

struct ProcRow: Identifiable {
    let id: pid_t
    let name: String
    let footprint: Double
}

/// Reads memory every second while the window is open and keeps the last 10 minutes.
@MainActor
final class MemorySampler: ObservableObject {
    @Published private(set) var history: [MemSample] = []
    @Published private(set) var apps: [AppRow] = []
    @Published private(set) var processes: [ProcRow] = []
    @Published var baseline: MemSample?

    private var timer: Timer?
    private let maxSamples = 600

    var latest: MemSample? { history.last }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func tick() {
        if let s = Self.readSystem() {
            history.append(s)
            if history.count > maxSamples { history.removeFirst(history.count - maxSamples) }
        }
        scanProcesses()
    }

    // MARK: System

    static func readSystem() -> MemSample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(sysconf(_SC_PAGESIZE))
        let purgeable = Double(stats.purgeable_count)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var pressure: Int32 = 1
        var psize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &psize, nil, 0)
        return MemSample(
            time: Date(), total: Double(ProcessInfo.processInfo.physicalMemory),
            app: (Double(stats.internal_page_count) - purgeable) * page,
            wired: Double(stats.wire_count) * page,
            compressed: Double(stats.compressor_page_count) * page,
            cached: (Double(stats.external_page_count) + purgeable) * page,
            free: Double(stats.free_count) * page,
            swapUsed: Double(swap.xsu_used), pressure: Int(pressure))
    }

    // MARK: Processes

    /// Footprint = what Activity Monitor's Memory column shows (dirty + compressed + Metal), per process of this user.
    private static func footprint(_ pid: pid_t) -> Double? {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? Double(info.ri_phys_footprint) : nil
    }

    private static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    private func scanProcesses() {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let list = pids.prefix(Int(got)).filter { $0 > 0 }

        let guiApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleURL != nil
        }
        let prefixes = guiApps.map { ($0, ($0.bundleURL?.path ?? "") + "/") }
        var perApp: [pid_t: Double] = [:]
        var loose: [ProcRow] = []
        let me = ProcessInfo.processInfo.processIdentifier

        for pid in list {
            guard let fp = Self.footprint(pid) else { continue }
            let p = Self.path(pid)
            if let owner = prefixes.first(where: { p.hasPrefix($0.1) })?.0 {
                perApp[owner.processIdentifier, default: 0] += fp
            } else if pid != me, fp > 50_000_000, !p.hasPrefix("/System/"), !p.hasPrefix("/usr/libexec/"), !p.hasPrefix("/usr/sbin/") {
                loose.append(ProcRow(id: pid, name: (p as NSString).lastPathComponent, footprint: fp))
            }
        }
        apps = guiApps.map {
            AppRow(id: $0.processIdentifier, name: $0.localizedName ?? "?", bundleID: $0.bundleIdentifier ?? "",
                   footprint: perApp[$0.processIdentifier] ?? 0, icon: $0.icon, app: $0)
        }.sorted { $0.footprint > $1.footprint }
        processes = Array(loose.sorted { $0.footprint > $1.footprint }.prefix(12))
    }
}
