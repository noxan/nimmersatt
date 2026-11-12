import AppKit
import IOKit

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
    var disk = 0.0           // bytes per second, read + written
    var gpu = 0.0            // percent of GPU time
    var busiest = ""         // busiest process in the group, if not the app itself
    var busiestCPU = 0.0
}

final class Sampler {
    private var last: [pid_t: (cpu: Double, io: UInt64)] = [:]  // cumulative ns and bytes per pid
    private var lastTime: UInt64 = 0
    private var lastDiskTime: UInt64 = 0
    /// How busy the disks were over the last interval, 0 to 100: summed I/O time per second
    /// of wall time (the average number of operations in flight) against Tuning.diskSaturation.
    private(set) var diskBusy = 0.0
    private var lastGPU: [pid_t: UInt64] = [:]  // cumulative GPU ns per pid
    /// The GPU's own utilisation figure, 0 to 100, from the latest sample.
    private(set) var gpuBusy = 0.0
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

        let diskTime = diskTimeNs()
        if lastDiskTime > 0, diskTime >= lastDiskTime {
            diskBusy = min(100, Double(diskTime - lastDiskTime) / elapsed / Tuning.diskSaturation * 100)
        }
        lastDiskTime = diskTime
        let gpu = sampleGPU(elapsed: elapsed)

        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))

        var current: [pid_t: (cpu: Double, io: UInt64)] = [:]
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
            let io = info.ri_diskio_bytesread + info.ri_diskio_byteswritten
            current[pid] = (ns, io)
            let before = last[pid]
            let cpu = before.map { max(0, ns - $0.cpu) / elapsed * 100 } ?? 0
            let disk = before.map { Double(io >= $0.io ? io - $0.io : 0) / (elapsed / 1e9) } ?? 0

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
            group.disk += disk
            group.gpu += gpu[pid] ?? 0
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
            group.gpu += gpu[p.pid] ?? 0
            groups[key] = group
        }

        last = current
        identity = identity.filter { owners.contains($0.key) }
        return Array(groups.values)
    }

    // Cumulative ns all block devices spent on reads and writes. System-wide, so it also
    // sees root daemons (Spotlight, Time Machine) whose per-process I/O libproc hides from us.
    private func diskTimeNs() -> UInt64 {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        var total: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let stats = property(entry, "Statistics") as? [String: Any]
            for key in ["Total Time (Read)", "Total Time (Write)"] {
                total += (stats?[key] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return total
    }

    // GPU time per pid over the last interval, as percent of that interval; also updates gpuBusy.
    // Read from the IO registry: no privileges needed, and it covers root-owned processes
    // (WindowServer) exactly. ponytail: these registry keys are undocumented. If Apple renames
    // them the GPU ring reads idle instead of failing; upgrade path is IOReport "GPU Stats".
    private func sampleGPU(elapsed: Double) -> [pid_t: Double] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var totals: [pid_t: UInt64] = [:]
        var busy = 0.0
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            let stats = property(accelerator, "PerformanceStatistics") as? [String: Any]
            busy = max(busy, (stats?["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                // The creator reads "pid 643, WindowServer".
                guard let creator = property(client, "IOUserClientCreator") as? String,
                      let pid = pid_t(creator.dropFirst(4).prefix(while: { $0 != "," })),
                      let usage = property(client, "AppUsage") as? [[String: Any]] else { continue }
                totals[pid, default: 0] += usage.reduce(0) {
                    $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
                }
            }
        }
        gpuBusy = busy
        var usage: [pid_t: Double] = [:]
        for (pid, ns) in totals {
            if let before = lastGPU[pid], ns >= before { usage[pid] = Double(ns - before) / elapsed * 100 }
        }
        lastGPU = totals
        return usage
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
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
    private func rootProcesses(_ pids: Set<pid_t>) -> [(pid: pid_t, name: String, cpu: Double, memory: UInt64)] {
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
            return (pid, name, cpu, rssKB * 1024)
        }
    }
}
