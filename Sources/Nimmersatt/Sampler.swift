import AppKit
import IOKit
import NimmersattShared

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
    var symbol = "gearshape.fill"  // SF Symbol shown when there is no app icon
    var process = ""         // the daemon's own name, when `name` is a friendlier label for it
    /// Second line under the name: the daemon itself, else the busiest child worth mentioning.
    var detail: String? { process.isEmpty ? (busiestCPU >= 1 ? busiest : nil) : process }
}

/// Plain-English names for system daemons that have no app bundle to name them.
/// Naming only: says what the daemon is, never why it is busy.
private let daemonNames: [String: (name: String, symbol: String)] = {
    let groups: [(String, String, [String])] = [
        ("Time Machine", "clock.arrow.circlepath", ["backupd", "backupd-helper", "tmutil"]),
        ("Spotlight", "magnifyingglass", ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "corespotlightd", "spotlightknowledged"]),
        ("Apple Intelligence", "sparkles", ["modelmanagerd", "modelcatalogd", "TGOnDeviceInferenceProviderService", "intelligenceplatformd", "generativeexperiencesd"]),
        ("Visual Intelligence", "eye", ["visualintelligenced"]),
        ("Siri & Shortcuts", "wand.and.stars", ["siriactionsd", "duetexpertd", "coreduetd", "suggestd", "knowledge-agent", "siriknowledged", "assistantd", "assistant_service", "sirittsd", "parsecd", "corespeechd"]),
        ("Neural Engine", "brain", ["ANECompilerService", "ANEStorageProcessor", "aned"]),
        ("Metal Shaders", "cube", ["MTLCompilerService", "MTLAssetUpgraderD"]),
        ("Photos Analysis", "photo.on.rectangle", ["photoanalysisd", "mediaanalysisd", "photolibraryd", "photosanalysisd"]),
        ("iCloud", "icloud", ["cloudd", "bird", "cloudpaird", "cloudphotod", "fileproviderd", "brctl", "CloudTelemetryService"]),
        ("Background Downloads", "arrow.down.circle", ["nsurlsessiond", "nsurlstoraged", "mobileassetd", "MobileAssetUpgradeAgent"]),
        ("Software Update", "arrow.down.app", ["softwareupdated", "suhelperd", "SoftwareUpdateSubscriber", "softwareupdate_notify_agent", "SoftwareUpdateNotificationManager", "mobilesoftwareupdate"]),
        ("Installer", "shippingbox", ["installd", "system_installd", "installcoordinationd", "InstallerProgress", "installer"]),
        ("App Store", "bag", ["appstoreagent", "storedownloadd", "storeassetd", "storeaccountd", "commerce", "AppStore"]),
        ("XProtect", "checkmark.shield", ["xprotectd", "XprotectService", "XProtectPluginService", "XProtectBridgeService", "XProtect"]),
        ("Security", "lock.shield", ["syspolicyd", "amfid", "trustd", "securityd", "secd", "secinitd", "tccd", "sandboxd", "endpointsecurityd", "taskgated"]),
        ("Keychain", "key", ["keybagd", "ctkd", "ctkahp", "CryptoTokenKit", "SecurityAgent"]),
        ("Wi-Fi", "wifi", ["airportd", "wifip2pd", "wifianalyticsd", "WiFiCloudAssetsXPCService", "wifivelocityd", "WiFiAgent", "com.apple.DriverKit-AppleBCMWLAN", "WirelessRadioManagerd"]),
        ("Bluetooth", "wave.3.right", ["bluetoothd", "bluetoothuserd", "IOUserBluetoothSerialDriver", "BTLEServerAgent"]),
        ("Network", "network", ["mDNSResponder", "mDNSResponderHelper", "networkd", "nesessionmanager", "nehelper", "NetworkExtension", "symptomsd", "netbiosd", "configd", "apsd"]),
        ("Audio", "speaker.wave.2", ["coreaudiod", "audioaccessoryd", "audiomxd", "com.apple.audio.Core-Audio-Driver-Service", "com.apple.audio.DriverHelper", "com.apple.audio.SandboxHelper", "systemsoundserverd"]),
        ("Disk Images", "opticaldiscdrive", ["diskimagesiod", "diskimagescontroller", "diskimages-helper", "hdiejectd", "simdiskimaged"]),
        ("Storage", "internaldrive", ["storagekitd", "diskarbitrationd", "fseventsd", "apfsd", "fskitd", "revisiond", "mmaintenanced"]),
        ("Crash Reporting", "ladybug", ["ReportCrash", "spindump", "tailspind", "SubmitDiagInfo", "diagnosticd", "diagnostics_agent", "ReportSystemMemory", "osanalyticshelper"]),
        ("Logging", "doc.text", ["logd", "logd_helper", "syslogd", "systemstats", "powerlogHelperd", "PerfPowerService", "PerfPowerTelemetryClientRegistrationService", "rtcreportingd", "triald", "triald_system", "TrialArchivingService"]),
        ("Power", "bolt", ["powerd", "thermalmonitord", "powerexperienced", "peakpowermanager", "PowerUIAgent", "ioupsd", "watchdogd"]),
        ("Location Services", "location", ["locationd", "geod", "com.apple.geod", "searchpartyd", "findmydeviced", "nearbyd"]),
        ("Messages & Sharing", "message", ["imagent", "identityservicesd", "sharingd", "rapportd", "IMDPersistenceAgent", "AirPlayXPCHelper", "ScreensharingAgent", "screensharingd"]),
        ("Devices", "cable.connector", ["usbmuxd", "hidd", "UVCAssistant", "AppleDeviceQueryService", "AppleDeviceQuery", "ThunderboltAccessoryUpdater", "ThunderboltAccessoryManager", "StandaloneHIDAudio", "nfcd", "bootpd"]),
        ("Launch Services", "square.grid.2x2", ["lsd", "launchservicesd", "iconservicesd", "iconservicesagent", "coreservicesd", "UserEventAgent", "cfprefsd", "distnoted", "notifyd", "usermanagerd", "runningboardd"]),
        ("Accounts", "person.crop.circle", ["akd", "accountsd", "opendirectoryd", "kdc", "GSSCred", "CloudKeychainProxy"]),
        ("Configuration", "gearshape.2", ["mobileactivationd", "ManagedClient", "ManagedConfigurationAgent", "managedappdistributiond", "remotemanagementd", "profiles", "mdmclient", "installcoordinationd", "LegacyProfilesSubscriber", "ManagedAppsSubscriber", "MigrationSubscriber", "ManagementTestSubscriber", "ManagedPreferencesSubscriber"]),
        ("Wallpaper", "photo", ["wallpaperexportd", "WallpaperAgent", "WallpaperAerialsExtension"]),
        ("Kernel", "cpu", ["kernel_task", "kernelmanagerd", "kernelmanager_helper", "KernelEventAgent", "sysextd", "systemextensionsd"]),
        ("Window Server", "macwindow", ["WindowServer", "ViewBridgeAuxiliary", "loginwindow"]),
        ("System Services", "gearshape.fill", ["launchd", "sysmond", "timed", "smd", "seld", "seputil", "systemmigrationd", "systemstatusd"]),
    ]
    var out: [String: (name: String, symbol: String)] = [:]
    for (name, symbol, procs) in groups { for p in procs where out[p] == nil { out[p] = (name, symbol) } }
    return out
}()

/// `ps` shows other users' processes as "(name)", cut to 16 characters.
private func daemon(_ raw: String) -> (name: String, symbol: String, process: String)? {
    let bare = raw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    let hit = daemonNames[bare] ?? (bare.count >= 15 ? daemonNames.first { $0.key.hasPrefix(bare) }?.value : nil)
    guard let hit else { return nil }
    let same = hit.name.replacingOccurrences(of: " ", with: "") == bare
    return (hit.name, hit.symbol, same ? "" : bare)
}

struct SystemUsage {
    var load = 0.0      // percent of all cores busy
    /// How busy the disks were, 0 to 100: summed I/O time per second of wall time (the
    /// average number of operations in flight) against Tuning.diskSaturation.
    var diskBusy = 0.0
    var gpuBusy = 0.0   // the GPU's own utilisation figure, 0 to 100
}

/// Two samplers with separate costs. `system()` is a handful of kernel reads and is all the
/// score needs. `apps()` walks every process and spawns `ps`; it is only needed to name apps.
final class Sampler {
    private var last: [pid_t: (cpu: Double, io: UInt64)] = [:]  // cumulative ns and bytes per pid
    private var lastTime: UInt64 = 0
    private var lastRootIO: [pid_t: UInt64] = [:]  // helper bytes per root pid
    private var lastSystemTime: UInt64 = 0
    private var lastDiskTime: UInt64 = 0
    private var lastTicks: (busy: UInt64, total: UInt64) = (0, 0)
    private var lastGPU: [pid_t: UInt64] = [:]  // cumulative GPU ns per pid
    /// For the self-check: the registry still reports GPU time per process. Cumulative, so it
    /// holds on a quiet screen too, where no app uses the GPU during the sample.
    var hasGPUCounters: Bool { lastGPU.values.contains { $0 > 0 } }
    private var identity: [pid_t: (name: String, icon: NSImage?, symbol: String, process: String)] = [:]

    // rusage times are mach ticks, not ns: 125/3 on Apple Silicon, 1/1 on Intel.
    private let nsPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func system() -> SystemUsage {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = Double(now - lastSystemTime)
        lastSystemTime = now
        var usage = SystemUsage()

        let ticks = cpuTicks()
        if lastTicks.total > 0, ticks.total > lastTicks.total, ticks.busy >= lastTicks.busy {
            usage.load = Double(ticks.busy - lastTicks.busy) / Double(ticks.total - lastTicks.total) * 100
        }
        lastTicks = ticks

        let diskTime = diskTimeNs()
        if lastDiskTime > 0, diskTime >= lastDiskTime {
            usage.diskBusy = min(100, Double(diskTime - lastDiskTime) / elapsed / Tuning.diskSaturation * 100)
        }
        lastDiskTime = diskTime

        forEachAccelerator { accelerator in
            let stats = property(accelerator, "PerformanceStatistics") as? [String: Any]
            usage.gpuBusy = max(usage.gpuBusy, (stats?["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
        }
        return usage
    }

    /// `roots: false` skips the root-owned processes: they cost a `ps` spawn (24ms of CPU, five
    /// times the rest of the walk), and nobody reads them while the panel is closed.
    func apps(roots: Bool = true) -> [AppUsage] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = Double(now - lastTime)
        lastTime = now
        let gpu = gpuTime(elapsed: elapsed)

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
                return AppUsage(id: key, name: who.name, icon: who.icon, symbol: who.symbol, process: who.process)
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

        // With the root helper on, the processes libproc hides get their disk use from it.
        let helperIO = roots ? RootHelper.diskBytes() : nil
        var rootIO: [pid_t: UInt64] = [:]
        for p in roots ? rootProcesses(unreadable) : [] {
            let key = "root:\(p.name)"
            var group = groups[key] ?? {
                guard let d = daemon(p.name) else { return AppUsage(id: key, name: p.name) }
                return AppUsage(id: key, name: d.name, symbol: d.symbol, process: d.process)
            }()
            group.cpu += p.cpu
            group.memory += p.memory
            group.gpu += gpu[p.pid] ?? 0
            if let io = helperIO?[p.pid] {
                rootIO[p.pid] = io
                if let before = lastRootIO[p.pid], io >= before { group.disk += Double(io - before) / (elapsed / 1e9) }
            }
            groups[key] = group
        }

        last = current
        lastRootIO = rootIO
        identity = identity.filter { owners.contains($0.key) }
        return Array(groups.values)
    }

    // Cumulative CPU ticks over all cores, from the kernel: exact, and includes root processes.
    private func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        } == KERN_SUCCESS
        guard ok else { return (0, 0) }
        let (user, system, idle, nice) = info.cpu_ticks
        let busy = UInt64(user) + UInt64(system) + UInt64(nice)
        return (busy, busy + UInt64(idle))
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

    // GPU readings come from the IO registry: no privileges needed, and they cover root-owned
    // processes (WindowServer) exactly. ponytail: the registry keys are undocumented. If Apple
    // renames them the GPU ring reads idle instead of failing; upgrade path is IOReport "GPU Stats".
    private func forEachAccelerator(_ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            body(accelerator)
            IOObjectRelease(accelerator)
        }
    }

    // GPU time per pid over the last interval, as percent of that interval.
    private func gpuTime(elapsed: Double) -> [pid_t: Double] {
        var totals: [pid_t: UInt64] = [:]
        forEachAccelerator { accelerator in
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { return }
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

    private func identify(_ pid: pid_t) -> (name: String, icon: NSImage?, symbol: String, process: String) {
        if let hit = identity[pid] { return hit }
        let app = NSRunningApplication(processIdentifier: pid)
        let raw = processName(pid)
        let d = app == nil ? daemon(raw) : nil
        let value = (name: app?.localizedName ?? d?.name ?? raw, icon: app?.icon,
                     symbol: d?.symbol ?? "gearshape.fill", process: d?.process ?? "")
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
