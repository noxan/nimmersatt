import AppKit

// ponytail: calibration knobs. Every threshold here is a judgment call; tune against real use.
enum Tuning {
    static let hogCPU = 100.0        // an app is "eating" CPU at one full core, smoothed
    static let tightMemory = 50      // below this memory headroom, name the biggest apps
    static let hogGPU = 50.0         // an app is "eating" the GPU at half of its time, smoothed
    static let gpuIdle = 30.0        // GPU utilisation a resting desktop shows anyway; scored as free
    static let hogDisk = 50e6        // an app is "eating" disk at 50MB/s read + written, smoothed
    static let roomyDiskGB = 40.0    // free space at which the disk scores 100; below, linear to 0
    static let diskSaturation = 4.0  // I/O operations in flight, on average, that count as 100% busy
    static let diskWeight = 0.5      // disk counts half: alone it can pull the score to 50, not lower
    static let good = 70, fair = 40  // score bands: calm, orange, red
    static let idleAppTicks = 5      // while the panel is closed, walk the process list every 5th tick (10s)
    static let diskSpaceTicks = 15   // re-read free disk space every 15th tick (30s)
    static let smoothing = 0.3       // weight of the newest 2s sample (about a 6s time constant)
}

/// One number, 0 to 100, higher is better: how much room the Mac has left.
/// It is the weakest of its contributors, because a bottleneck is not averaged away.
/// Disk counts at reduced weight (see Tuning.diskWeight).
struct Headroom {
    let load: Double        // percent of all cores in use
    let memoryFree: Int     // kernel's free-memory percentage
    let memoryPressure: Int // kernel's pressure level: 1 normal, 2 warning, 4 critical
    let thermalState: ProcessInfo.ThermalState
    var swapUsed: UInt64 = 0 // bytes of swap in use
    var diskFreeGB = 1000.0 // free space on the boot volume, as Finder counts it
    var diskBusy = 0.0      // percent of time the disks spent serving I/O
    var gpuBusy = 0.0       // the GPU's own utilisation percentage

    var cpu: Int { Int(max(0, min(100, 100 - load))) }

    // Half the memory free is a healthy Mac (macOS fills RAM on purpose), so 50% free scores 100.
    // The kernel's own pressure level then caps the score, and so does swap: swap in use
    // means RAM was overcommitted, scored against physical memory (half of RAM swapped = 50).
    var memory: Int {
        let cap = memoryPressure >= 4 ? 15 : memoryPressure >= 2 ? 40 : 100
        let swapShare = Double(swapUsed) / Double(ProcessInfo.processInfo.physicalMemory)
        return max(0, min(cap, memoryFree * 2, Int(100 - swapShare * 100)))
    }

    var thermal: Int {
        switch thermalState {
        case .nominal: 100
        case .fair: 75
        case .serious: 35
        default: 0
        }
    }

    // Disk is the worse of space and activity: a full disk starves swap, a busy one stalls everything.
    var diskSpace: Int { Int(max(0, min(100, diskFreeGB / Tuning.roomyDiskGB * 100))) }
    var diskIdle: Int { Int(max(0, min(100, 100 - diskBusy))) }
    var disk: Int { min(diskSpace, diskIdle) }

    // Compositing an idle desktop already keeps the GPU around 20% busy, so the scale starts above that.
    var gpu: Int { Int(max(0, min(100, 100 - (gpuBusy - Tuning.gpuIdle) / (100 - Tuning.gpuIdle) * 100))) }

    var contributors: [(name: String, score: Int, weight: Double)] {
        [("CPU", cpu, 1), ("GPU", gpu, 1), ("Memory", memory, 1), ("Thermal", thermal, 1),
         ("Disk", disk, Tuning.diskWeight)]
    }
    private static func weighted(_ c: (name: String, score: Int, weight: Double)) -> Int {
        100 - Int((Double(100 - c.score) * c.weight).rounded())
    }
    var score: Int { contributors.map(Self.weighted).min()! }
    var weakest: String { contributors.min { Self.weighted($0) < Self.weighted($1) }!.name }

    static func diskFreeGB() -> Double {
        let volume = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (volume?.volumeAvailableCapacityForImportantUsage).map { Double($0) / 1e9 } ?? 1000
    }

    static func now(_ system: SystemUsage, diskFreeGB: Double) -> Headroom {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return Headroom(load: system.load,
                        memoryFree: sysctlInt("kern.memorystatus_level") ?? 100,
                        memoryPressure: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1,
                        thermalState: ProcessInfo.processInfo.thermalState,
                        swapUsed: swap.xsu_used,
                        diskFreeGB: diskFreeGB,
                        diskBusy: system.diskBusy,
                        gpuBusy: system.gpuBusy)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}

extension Headroom {
    /// nil while there is room (stay quiet, default colour), orange for warning, red for critical.
    static func alarm(_ score: Int) -> NSColor? {
        score >= Tuning.good ? nil : score >= Tuning.fair ? .systemOrange : .systemRed
    }

    /// A ring filled to the score: full means all the room is left. It drains clockwise from
    /// 12 o'clock as headroom runs out, like a countdown; what remains ends at 12. Used as the menu bar icon and in the panel. A template image while calm, so it takes the surrounding default colour.
    static func ring(_ score: Int, size: CGFloat = 16, stroke: CGFloat = 2.5) -> NSImage {
        let color = alarm(score), fill = Double(score) / 100
        let radius = (size - stroke) / 2 - 0.75
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let ink = color ?? .black
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = stroke
            ink.withAlphaComponent(0.3).setStroke()
            track.stroke()
            if fill > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 + 360 * fill, clockwise: false)
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                ink.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

struct Culprit: Identifiable {
    let app: AppUsage
    let value: String
    var detail: String?  // the busiest child process; known for CPU only
    var id: String { app.id }
}

struct Snapshot {
    var apps: [AppUsage] = []
    var headroom = Headroom(load: 0, memoryFree: 100, memoryPressure: 1, thermalState: .nominal)

    /// Apps worth naming: anything holding a full core, half the GPU or hammering the disk, plus the
    /// biggest apps when memory is tight. Each app is listed once, under its first reason.
    var culprits: [Culprit] {
        var out = apps.filter { $0.cpu >= Tuning.hogCPU }
            .sorted { $0.cpu > $1.cpu }
            .map { Culprit(app: $0, value: "\(Int($0.cpu))%", detail: $0.busiestCPU >= 1 ? $0.busiest : nil) }
        out += apps.filter { $0.gpu >= Tuning.hogGPU }
            .sorted { $0.gpu > $1.gpu }
            .map { Culprit(app: $0, value: "\(Int($0.gpu))% GPU") }
        out += apps.filter { $0.disk >= Tuning.hogDisk }
            .sorted { $0.disk > $1.disk }
            .map { Culprit(app: $0, value: Int64($0.disk).formatted(.byteCount(style: .file)) + "/s") }
        if headroom.memory < Tuning.tightMemory {
            out += apps.sorted { $0.memory > $1.memory }.prefix(3)
                .map { Culprit(app: $0, value: $0.memory.formatted(.byteCount(style: .memory))) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    var verdict: String {
        let culprits = culprits
        if culprits.count == 1 { return "\(culprits[0].app.name) is eating resources" }
        if culprits.count > 1 { return "\(culprits.count) apps are eating resources" }
        if headroom.score >= Tuning.good { return "All clear" }
        switch headroom.weakest {
        case "CPU": return "Busy across many apps"
        case "GPU": return "GPU is busy"
        case "Memory": return "Memory is getting tight"
        case "Disk": return headroom.diskSpace < headroom.diskIdle ? "Disk is almost full" : "Disk is busy"
        default: return "Running hot"
        }
    }
}
