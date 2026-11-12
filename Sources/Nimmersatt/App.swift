import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--check") {
            check()
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1], expanded: args.contains("--details"))
        } else {
            NimmersattApp.main()
        }
    }

    // Self-check: `swift run Nimmersatt --check`. Fails if sampling, grouping or scoring breaks.
    static func check() {
        let calm = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal)
        precondition(calm.score == 95 && calm.weakest == "CPU", "calm score")
        let squeezed = Headroom(load: 5, memoryFree: 60, memoryPressure: 4, thermalState: .nominal)
        precondition(squeezed.score == 15 && squeezed.weakest == "Memory", "memory pressure caps the score")
        precondition(Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .critical).score == 0, "thermal")
        let idle = Snapshot(apps: [AppUsage(id: "a", name: "A", cpu: 20)], headroom: calm)
        precondition(idle.culprits.isEmpty && idle.verdict == "All clear", "no culprit when calm")
        let hog = Snapshot(apps: [AppUsage(id: "a", name: "A", cpu: 150)], headroom: calm)
        precondition(hog.culprits.map(\.id) == ["a"], "full core is a culprit")
        let swapping = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal,
                                swapUsed: ProcessInfo.processInfo.physicalMemory / 2)
        precondition(swapping.memory == 50 && swapping.weakest == "Memory", "swap lowers memory")
        let full = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal, diskFreeGB: 0)
        precondition(full.disk == 0 && full.score == 50 && full.weakest == "Disk", "full disk counts half")
        precondition(Snapshot(headroom: full).verdict == "Disk is almost full", "full disk verdict")
        let thrash = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal, diskBusy: 100)
        precondition(thrash.disk == 0 && Snapshot(headroom: thrash).verdict == "Disk is busy", "busy disk")
        let writer = Snapshot(apps: [AppUsage(id: "a", name: "A", disk: 100e6)], headroom: calm)
        precondition(writer.culprits.map(\.value) == ["100 MB/s"], "disk hog is a culprit")
        let tight = Snapshot(apps: [AppUsage(id: "a", name: "A", memory: 1 << 30)], headroom: squeezed)
        precondition(tight.culprits.map(\.id) == ["a"], "tight memory names the biggest app")

        let sampler = Sampler()
        _ = sampler.sample()
        sleep(1)
        let apps = sampler.sample().sorted { $0.cpu > $1.cpu }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let total = apps.reduce(0) { $0 + $1.cpu }
        precondition(apps.count > 5, "no processes sampled")
        precondition(total > 0 && total <= cores * 110, "cpu total out of range: \(total)")
        precondition(apps.contains { $0.memory > 50 << 20 }, "no memory readings")
        precondition(apps.contains { $0.id.hasPrefix("root:") }, "root processes missing")
        for app in apps.prefix(10) {
            let cpu = String(format: "%6.1f%%", app.cpu)
            let mem = app.memory.formatted(.byteCount(style: .memory))
            print(cpu, mem.padding(toLength: 10, withPad: " ", startingAt: 0), app.name, app.busiest)
        }
        let now = Headroom.now(load: total / cores, diskBusy: sampler.diskBusy)
        precondition(now.diskFreeGB > 0 && now.diskFreeGB < 1000, "disk space not read")
        print("ok: \(apps.count) groups, \(Int(total))% of \(Int(cores * 100))%, headroom \(now.score)",
              now.contributors.map { "\($0.name) \($0.score)" },
              "disk \(Int(now.diskFreeGB))GB free, \(Int(now.diskBusy))% busy, swap \(now.swapUsed >> 20)MB")
    }

    // Renders the panel with live data to a PNG, to review layout without clicking the menu bar.
    @MainActor static func snapshot(to path: String, expanded: Bool) {
        let sampler = Sampler()
        _ = sampler.sample()
        sleep(1)
        let apps = sampler.sample()
        let load = apps.reduce(0) { $0 + $1.cpu } / Double(ProcessInfo.processInfo.activeProcessorCount)
        let state = Snapshot(apps: apps, headroom: .now(load: load, diskBusy: sampler.diskBusy))
        let renderer = ImageRenderer(content: Panel(state: state, expanded: expanded).background(.background))
        renderer.scale = 2
        let tiff = renderer.nsImage!.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: path))
    }
}

@Observable
final class Model {
    var state = Snapshot()
    private let sampler = Sampler()
    // Smoothing state, touched only on the timer queue.
    private var smoothed: [String: (cpu: Double, disk: Double)] = [:]
    private var diskBusy = 0.0
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    init() {
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let state = self.tick()
            DispatchQueue.main.async { self.state = state }
        }
        timer.resume()
    }

    // Smooths CPU and disk rates so a 2s spike neither names a culprit nor moves the score.
    private func tick() -> Snapshot {
        var apps = sampler.sample()
        let w = Tuning.smoothing
        for i in apps.indices {
            if let old = smoothed[apps[i].id] {
                apps[i].cpu = old.cpu * (1 - w) + apps[i].cpu * w
                apps[i].disk = old.disk * (1 - w) + apps[i].disk * w
            }
        }
        smoothed = Dictionary(apps.map { ($0.id, ($0.cpu, $0.disk)) }, uniquingKeysWith: { a, _ in a })
        diskBusy = diskBusy * (1 - w) + sampler.diskBusy * w
        let load = apps.reduce(0) { $0 + $1.cpu } / Double(ProcessInfo.processInfo.activeProcessorCount)
        return Snapshot(apps: apps, headroom: .now(load: load, diskBusy: diskBusy))
    }
}

struct NimmersattApp: App {
    @State private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }  // no Dock icon under `swift run`

    var body: some Scene {
        MenuBarExtra {
            Panel(state: model.state)
                .background(GeometryReader { geo in WindowFit(height: geo.size.height) })
                .frame(maxHeight: .infinity, alignment: .top)  // never re-center while the window catches up
        } label: {
            // Headroom ring: full and default colour while calm; empties, orange then red, as room runs out.
            Image(nsImage: Headroom.ring(model.state.headroom.score))
                .accessibilityLabel("Headroom \(model.state.headroom.score) of 100")
        }
        .menuBarExtraStyle(.window)  // the system supplies the panel's glass; content adds no material
    }
}

// MenuBarExtra's window grows with its content but never shrinks back, leaving the
// panel floating in an oversized window. Pin the window height to the content height
// ourselves, top edge fixed. Idempotent, so it agrees with the system when that resizes.
private struct WindowFit: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Synchronous on purpose: deferring a runloop turn draws one frame at the old size.
        guard let window = view.window, let content = window.contentView,
              abs(content.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        frame.size.height += height - content.frame.height
        frame.origin.y = window.frame.maxY - frame.size.height
        window.setFrame(frame, display: true)
    }
}

// Laid out like the system's Wi-Fi panel: bold title, inset dividers, bold section
// headers, rows of round icon + name + trailing value, plain footer actions.
// Default view is the score, a verdict, one ring per contributor and any culprits;
// Details holds the app lists.
struct Panel: View {
    let state: Snapshot
    @State var expanded = false

    var body: some View {
        let headroom = state.headroom
        let culprits = state.culprits

        VStack(alignment: .leading, spacing: 0) {
            // Hierarchy: the score is the hero (large ring, number inside), named and explained
            // beside it; the three contributors follow as smaller rings of the same shape.
            HStack(spacing: 12) {
                Image(nsImage: Headroom.ring(headroom.score, size: 56, stroke: 5))
                    .overlay { Text("\(headroom.score)").font(.system(size: 20, weight: .semibold)) }
                    .accessibilityElement()
                    .accessibilityLabel("Headroom \(headroom.score) of 100")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headroom").fontWeight(.bold)
                    Text(state.verdict).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)

            // One ring per contributor, its glyph inside. Facts are in the tooltip.
            HStack(spacing: 0) {
                contributor("cpu", headroom.cpu, "CPU: \(Int(headroom.load))% of all cores busy")
                contributor("memorychip", headroom.memory,
                            "Memory: \(headroom.memoryFree)% free, \(headroom.swapUsed.formatted(.byteCount(style: .memory))) swap")
                contributor("thermometer.medium", headroom.thermal,
                            "Thermal: " + ["nominal", "fair", "serious", "critical"][headroom.thermalState.rawValue])
                contributor("internaldrive", headroom.disk,
                            "Disk: \(Int(headroom.diskFreeGB)) GB free, \(Int(headroom.diskBusy))% busy")
            }
            .padding(.vertical, 12)

            if !culprits.isEmpty {
                Divider().padding(.bottom, 4)
                ForEach(culprits) { culprit in
                    Row(icon: culprit.app.icon, name: culprit.app.name, value: culprit.value,
                        detail: culprit.app.busiestCPU >= 1 ? culprit.app.busiest : nil)
                }
                Spacer().frame(height: 4)
            }

            Divider().padding(.bottom, 4)
            Action(title: "Details", expanded: expanded) { expanded.toggle() }
            if expanded {
                section("CPU") {
                    ForEach(state.apps.sorted { $0.cpu > $1.cpu }.prefix(5)) { app in
                        Row(icon: app.icon, name: app.name, value: "\(Int(app.cpu))%",
                            detail: app.busiestCPU >= 1 ? app.busiest : nil)
                    }
                }
                section("Memory") {
                    ForEach(state.apps.sorted { $0.memory > $1.memory }.prefix(5)) { app in
                        Row(icon: app.icon, name: app.name, value: app.memory.formatted(.byteCount(style: .memory)))
                    }
                }
            }

            Divider().padding(.vertical, 4)
            Action(title: "Activity Monitor…") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Action(title: "Quit Nimmersatt") { NSApp.terminate(nil) }
        }
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300)
    }

    private func contributor(_ symbol: String, _ score: Int, _ fact: String) -> some View {
        Image(nsImage: Headroom.ring(score, size: 28, stroke: 2.5))
            .overlay { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
            .help(fact)
            .accessibilityElement()
            .accessibilityLabel(fact)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        Divider().padding(.top, 4)
        Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
        rows()
    }
}

struct Row: View {
    var icon: NSImage?
    var symbol = "gearshape.fill"
    let name: String
    let value: String
    var detail: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: Circle())
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary)
        }
        .frame(height: 34)
    }
}

struct Action: View {
    let title: String
    var expanded: Bool?  // non-nil draws a disclosure chevron
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let expanded {
                    Image(systemName: "chevron.right")
                        .fontWeight(.semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)  // highlight bleeds past the text column, like system menu rows
        .onHover { hovered = $0 }
    }
}
