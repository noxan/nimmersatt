import AppKit

// Private API, the one Activity Monitor groups by: maps helpers (browser tabs,
// WebKit content, shell children) to the app the user actually launched.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePid(_ pid: pid_t) -> pid_t

struct AppUsage: Identifiable {
    let id: String
    var name: String
    var icon: NSImage?
    var cpu = 0.0            // percent of one core
    var memory: UInt64 = 0   // bytes
    var busiest = ""         // busiest process in the group, if not the app itself
    var busiestCPU = 0.0
}

final class Sampler {
    private var lastCPU: [pid_t: Double] = [:]  // cumulative ns per pid
    private var lastTime: UInt64 = 0
    private var identity: [pid_t: (name: String, icon: NSImage?)] = [:]

    // rusage times are mach ticks, not ns: 125/3 on Apple Silicon, 1/1 on Intel.
    private let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func sample() -> [AppUsage] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = Double(now - lastTime)
        lastTime = now

        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))

        var cpuNow: [pid_t: Double] = [:]
        var groups: [String: AppUsage] = [:]
        var owners: Set<pid_t> = []
        var unreadable: Set<pid_t> = [0]  // kernel_task

        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0
            guard ok else { unreadable.insert(pid); continue }  // other users' processes

            let ns = Double(info.ri_user_time + info.ri_system_time) * nsPerTick
            cpuNow[pid] = ns
            let cpu = lastCPU[pid].map { max(0, ns - $0) / elapsed * 100 } ?? 0

            let responsible = responsiblePid(pid)
            let owner = responsible > 0 ? responsible : pid
            owners.insert(owner)

            let key = "app:\(owner)"
            var group = groups[key] ?? {
                let who = identify(owner)
                return AppUsage(id: key, name: who.name, icon: who.icon)
            }()
            group.cpu += cpu
            group.memory += info.ri_phys_footprint
            if pid != owner, cpu > group.busiestCPU {
                group.busiest = processName(pid)
                group.busiestCPU = cpu
            }
            groups[key] = group
        }

        for p in rootProcesses(unreadable) {
            let key = "root:\(p.name)"
            var group = groups[key] ?? AppUsage(id: key, name: p.name)
            group.cpu += p.cpu
            group.memory += p.memory
            groups[key] = group
        }

        lastCPU = cpuNow
        identity = identity.filter { owners.contains($0.key) }
        return Array(groups.values)
    }

    private func identify(_ pid: pid_t) -> (name: String, icon: NSImage?) {
        if let hit = identity[pid] { return hit }
        let app = NSRunningApplication(processIdentifier: pid)
        let value = (name: app?.localizedName ?? processName(pid), icon: app?.icon)
        identity[pid] = value
        return value
    }

    private func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        proc_pidpath(pid, &buf, UInt32(buf.count))
        let name = String(cString: buf).split(separator: "/").last.map(String.init)
        return name ?? "pid \(pid)"
    }

    // ponytail: root-owned processes (WindowServer, kernel_task, mds) are unreadable
    // via libproc without privileges, so ask setuid `ps`. Its %cpu is a decaying
    // average and rss is not footprint, so these rows are approximate. Upgrade path:
    // a privileged helper, if exact numbers for system daemons ever matter.
    private func rootProcesses(_ pids: Set<pid_t>) -> [(name: String, cpu: Double, memory: UInt64)] {
        let ps = Process()
        let pipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "pid=,pcpu=,rss=,comm="]
        ps.environment = ["LC_ALL": "C"]  // decimal point, whatever the user's locale
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return [] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = pid_t(f[0]), pids.contains(pid),
                  let cpu = Double(f[1]), let rssKB = UInt64(f[2]) else { return nil }
            let name = f[3].split(separator: "/").last.map(String.init) ?? String(f[3])
            return (name, cpu, rssKB * 1024)
        }
    }
}
