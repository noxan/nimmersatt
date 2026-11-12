import Foundation

// ponytail: calibration knobs. Every threshold here is a judgment call; tune against real use.
enum Tuning {
    static let hogCPU = 100.0        // an app is "eating" CPU at one full core, smoothed
    static let tightMemory = 50      // below this memory headroom, name the biggest apps
    static let good = 70, fair = 40  // score bands: green, yellow, red
    static let smoothing = 0.3       // weight of the newest 2s sample (about a 6s time constant)
}

/// One number, 0 to 100, higher is better: how much room the Mac has left.
/// It is the weakest of three contributors, because a bottleneck is not averaged away.
struct Headroom {
    let load: Double        // percent of all cores in use
    let memoryFree: Int     // kernel's free-memory percentage
    let memoryPressure: Int // kernel's pressure level: 1 normal, 2 warning, 4 critical
    let thermalState: ProcessInfo.ThermalState

    var cpu: Int { Int(max(0, min(100, 100 - load))) }

    // Half the memory free is a healthy Mac (macOS fills RAM on purpose), so 50% free scores 100.
    // The kernel's own pressure level then caps the score.
    var memory: Int {
        let cap = memoryPressure >= 4 ? 15 : memoryPressure >= 2 ? 40 : 100
        return max(0, min(cap, memoryFree * 2))
    }

    var thermal: Int {
        switch thermalState {
        case .nominal: 100
        case .fair: 75
        case .serious: 35
        default: 0
        }
    }

    var contributors: [(name: String, score: Int)] { [("CPU", cpu), ("Memory", memory), ("Thermal", thermal)] }
    var score: Int { contributors.map(\.score).min()! }
    var weakest: String { contributors.min { $0.score < $1.score }!.name }

    static func now(load: Double) -> Headroom {
        Headroom(load: load,
                 memoryFree: sysctlInt("kern.memorystatus_level") ?? 100,
                 memoryPressure: sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1,
                 thermalState: ProcessInfo.processInfo.thermalState)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}

struct Culprit: Identifiable {
    let app: AppUsage
    let value: String
    var id: String { app.id }
}

struct Snapshot {
    var apps: [AppUsage] = []
    var headroom = Headroom(load: 0, memoryFree: 100, memoryPressure: 1, thermalState: .nominal)

    /// Apps worth naming: anything holding a full core, plus the biggest apps when memory is tight.
    var culprits: [Culprit] {
        var out = apps.filter { $0.cpu >= Tuning.hogCPU }
            .sorted { $0.cpu > $1.cpu }
            .map { Culprit(app: $0, value: "\(Int($0.cpu))%") }
        if headroom.memory < Tuning.tightMemory {
            out += apps.sorted { $0.memory > $1.memory }.prefix(3)
                .filter { app in !out.contains { $0.id == app.id } }
                .map { Culprit(app: $0, value: $0.memory.formatted(.byteCount(style: .memory))) }
        }
        return out
    }

    var verdict: String {
        let culprits = culprits
        if culprits.count == 1 { return "\(culprits[0].app.name) is eating resources" }
        if culprits.count > 1 { return "\(culprits.count) apps are eating resources" }
        if headroom.score >= Tuning.good { return "All clear" }
        switch headroom.weakest {
        case "CPU": return "Busy across many apps"
        case "Memory": return "Memory is getting tight"
        default: return "Running hot"
        }
    }
}
