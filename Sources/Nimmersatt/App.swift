import OSLog
import SwiftUI

private let log = Logger(subsystem: "local.nimmersatt", category: "panel")

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
        let both = Headroom(load: 55, memoryFree: 60, memoryPressure: 2, thermalState: .nominal)
        precondition(both.cpu == 45 && both.memory == 40 && both.score == 36, "two strained contributors compound")
        precondition(Snapshot(headroom: both).verdict == "Memory and CPU under pressure", "compound verdict")
        let resting = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal, gpuBusy: 30)
        precondition(resting.gpu == 100, "resting gpu is free")
        let rendering = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal, gpuBusy: 100)
        precondition(rendering.score == 0 && Snapshot(headroom: rendering).verdict == "GPU is busy", "busy gpu, full weight")
        let renderer = Snapshot(apps: [AppUsage(id: "a", name: "A", gpu: 80)], headroom: calm)
        precondition(renderer.culprits.map(\.value) == ["80% GPU"], "gpu hog is a culprit")
        let swapping = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal,
                                swapUsed: ProcessInfo.processInfo.physicalMemory / 2)
        precondition(swapping.memory == 50 && swapping.weakest == "Memory", "swap lowers memory")
        let full = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal, diskFreeGB: 0)
        precondition(full.disk == 0 && full.score == 40 && full.weakest == "Disk", "full disk counts less")
        precondition(Snapshot(headroom: full).verdict == "Disk is almost full", "full disk verdict")
        let thrash = Headroom(load: 5, memoryFree: 60, memoryPressure: 1, thermalState: .nominal, diskBusy: 100)
        precondition(thrash.disk == 0 && Snapshot(headroom: thrash).verdict == "Disk is busy", "busy disk")
        let writer = Snapshot(apps: [AppUsage(id: "a", name: "A", disk: 100e6)], headroom: calm)
        precondition(writer.culprits.map(\.value) == ["100 MB/s"], "disk hog is a culprit")
        let tight = Snapshot(apps: [AppUsage(id: "a", name: "A", memory: 1 << 30)], headroom: squeezed)
        precondition(tight.culprits.map(\.id) == ["a"], "tight memory names the biggest app")

        let sampler = Sampler()
        _ = sampler.apps()
        _ = sampler.system()
        sleep(1)
        let apps = sampler.apps().sorted { $0.cpu > $1.cpu }
        let system = sampler.system()
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let total = apps.reduce(0) { $0 + $1.cpu }
        precondition(apps.count > 5, "no processes sampled")
        precondition(total > 0 && total <= cores * 110, "cpu total out of range: \(total)")
        precondition(system.load > 0 && system.load <= 100, "system load out of range: \(system.load)")
        precondition(abs(system.load - total / cores) < 25, "kernel load \(system.load) disagrees with per-app sum \(total / cores)")
        precondition(apps.contains { $0.memory > 50 << 20 }, "no memory readings")
        precondition(apps.contains { $0.id.hasPrefix("root:") }, "root processes missing")
        for app in apps.prefix(10) {
            let cpu = String(format: "%6.1f%%", app.cpu)
            let mem = app.memory.formatted(.byteCount(style: .memory))
            print(cpu, mem.padding(toLength: 10, withPad: " ", startingAt: 0), app.name, app.busiest)
        }
        let now = Headroom.now(system, diskFreeGB: Headroom.diskFreeGB())
        precondition(apps.contains { $0.gpu > 0 }, "no per-app gpu readings")
        precondition(now.diskFreeGB > 0 && now.diskFreeGB < 1000, "disk space not read")
        print("ok: \(apps.count) groups, load \(Int(system.load))% (per-app sum \(Int(total / cores))%), headroom \(now.score)",
              now.contributors.map { "\($0.name) \($0.score)" },
              "disk \(Int(now.diskFreeGB))GB free, \(Int(now.diskBusy))% busy, swap \(now.swapUsed >> 20)MB, gpu \(Int(now.gpuBusy))%",
              "top gpu: " + (apps.max { $0.gpu < $1.gpu }.map { "\($0.name) \(Int($0.gpu))%" } ?? "none"))
    }

    // Renders the panel with live data to a PNG, to review layout without clicking the menu bar.
    @MainActor static func snapshot(to path: String, expanded: Bool) {
        let sampler = Sampler()
        _ = sampler.apps()
        _ = sampler.system()
        sleep(1)
        var state = Snapshot(apps: sampler.apps(), headroom: .now(sampler.system(), diskFreeGB: Headroom.diskFreeGB()))
        // `--load N` fakes the CPU load, to review the rings at any pressure.
        if let i = CommandLine.arguments.firstIndex(of: "--load"), let load = Double(CommandLine.arguments[i + 1]) {
            state.headroom = Headroom(load: load, memoryFree: 60, memoryPressure: 1, thermalState: .nominal)
        }
        var content = AnyView(Panel(state: state, expanded: expanded).background(.background))
        if CommandLine.arguments.contains("--demo") { content = AnyView(demo()) }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        // Redrawn into 8-bit sRGB: on an HDR display the render comes back as 16-bit PQ, which
        // browsers and image viewers show washed out.
        let cg = renderer.cgImage!
        let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: path))
    }
}

extension Main {
    // `--snapshot path --demo`: the README screenshot. Mocked data, a calm Mac beside an
    // overloaded one, on a transparent canvas so it sits on light and dark pages alike.
    @MainActor static func demo() -> some View {
        func app(_ path: String, cpu: Double, gb: Double, busiest: String = "") -> AppUsage {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return AppUsage(id: name, name: name, icon: NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: path).resolvingSymlinksInPath().path), cpu: cpu,
                            memory: UInt64(gb * 1_073_741_824), busiest: busiest, busiestCPU: busiest.isEmpty ? 0 : cpu)
        }
        let apps = [app("/Applications/Xcode.app", cpu: 412, gb: 6.2, busiest: "swift-frontend"),
                    app("/Applications/Safari.app", cpu: 38, gb: 3.4, busiest: "Web Content"),
                    app("/System/Applications/Photos.app", cpu: 21, gb: 1.9),
                    app("/System/Applications/Music.app", cpu: 6, gb: 0.6),
                    app("/System/Applications/Mail.app", cpu: 3, gb: 0.4)]
        let calm = Snapshot(headroom: Headroom(load: 12, memoryFree: 62, memoryPressure: 1, thermalState: .nominal,
                                               diskFreeGB: 200, diskBusy: 4, gpuBusy: 34))
        let busy = Snapshot(apps: apps, headroom: Headroom(load: 68, memoryFree: 35, memoryPressure: 1, thermalState: .fair,
                                                           diskFreeGB: 200, diskBusy: 22, gpuBusy: 55))
        let hot = Snapshot(headroom: Headroom(load: 82, memoryFree: 30, memoryPressure: 2, thermalState: .fair,
                                              diskFreeGB: 200, diskBusy: 30, gpuBusy: 40))
        func card(_ state: Snapshot) -> some View {
            Panel(state: state, expanded: !state.apps.isEmpty)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        }
        return HStack(spacing: 28) {
            VStack(spacing: 28) { card(calm); card(hot) }
            card(busy)
        }
        .padding(36)
        .environment(\.colorScheme, .dark)
    }
}

@Observable
final class Model {
    /// For the panel. Refreshed every tick while it is open and not at all while it is closed:
    /// the system keeps a closed panel's views alive, and they would render every update.
    var state = Snapshot()
    /// For the menu bar ring. Redrawing the status item is the app's main idle cost, so it
    /// follows the score only on a colour change or a move of 5 or more: an 18pt ring cannot
    /// show less, and a score hovering around one value never redraws.
    var ringScore = 100

    // Everything below is touched only on `queue`.
    @ObservationIgnored private let queue = DispatchQueue(label: "local.nimmersatt.sampler", qos: .utility)
    @ObservationIgnored private let timer: DispatchSourceTimer
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private var system = SystemUsage()  // smoothed
    @ObservationIgnored private var apps: [AppUsage] = []   // smoothed, from the latest process walk
    @ObservationIgnored private var diskFreeGB = 1000.0
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lastAppsTick = 0
    @ObservationIgnored private var panelOpen = false

    init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))  // lets the system batch wakeups
        timer.setEventHandler { [weak self] in self?.publish() }
        timer.resume()
    }

    /// The panel names apps, so the process list must be fresh while it is open. Closed, only
    /// the ring is visible, and the score needs no per-process work.
    func panel(open: Bool) {
        queue.async {
            guard open != self.panelOpen else { return }
            self.panelOpen = open
            if open { self.publish() }  // refresh now, not at the next tick
        }
    }

    private func publish() {
        let state = tick()
        let showState = panelOpen
        let score = state.headroom.score
        DispatchQueue.main.async {
            if Headroom.alarm(score) != Headroom.alarm(self.ringScore) || abs(score - self.ringScore) >= 5 {
                self.ringScore = score
            }
            if showState { self.state = state }
        }
    }

    // Smooths rates so a 2s spike neither names a culprit nor moves the score.
    private func tick() -> Snapshot {
        let w = Tuning.smoothing
        ticks += 1

        let now = sampler.system()
        system.load = system.load * (1 - w) + now.load * w
        system.diskBusy = system.diskBusy * (1 - w) + now.diskBusy * w
        system.gpuBusy = system.gpuBusy * (1 - w) + now.gpuBusy * w
        if ticks % Tuning.diskSpaceTicks == 1 { diskFreeGB = Headroom.diskFreeGB() }

        if panelOpen || ticks % Tuning.idleAppTicks == 1 {
            var fresh = sampler.apps(roots: panelOpen)
            // After a gap the rates already average a long window; smooth only consecutive samples.
            let wApps = ticks - lastAppsTick == 1 ? w : 1
            let old = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for i in fresh.indices {
                guard let before = old[fresh[i].id] else { continue }
                fresh[i].cpu = before.cpu * (1 - wApps) + fresh[i].cpu * wApps
                fresh[i].disk = before.disk * (1 - wApps) + fresh[i].disk * wApps
                fresh[i].gpu = before.gpu * (1 - wApps) + fresh[i].gpu * wApps
            }
            apps = fresh
            lastAppsTick = ticks
        }
        return Snapshot(apps: apps, headroom: .now(system, diskFreeGB: diskFreeGB))
    }
}

struct NimmersattApp: App {
    @State private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }  // no Dock icon under `swift run`

    var body: some Scene {
        MenuBarExtra {
            PanelHost(model: model)
        } label: {
            // Pressure ring: faint and default colour while calm; fills and thickens, orange then red, as room runs out.
            // Reads only ringScore, so panel data changes do not redraw the status item.
            Image(nsImage: Headroom.ring(model.ringScore))
                .accessibilityLabel("Pressure \(100 - model.ringScore) of 100")
        }
        .menuBarExtraStyle(.window)  // the system supplies the panel's glass; content adds no material
    }
}

// Owns the panel's dependency on `model.state`, keeping it out of the scene body.
private struct PanelHost: View {
    let model: Model

    var body: some View {
        Panel(state: model.state)
            .background(GeometryReader { geo in
                WindowFit(height: geo.size.height) { open in
                    model.panel(open: open)
                    log.info("panel \(open ? "open" : "closed", privacy: .public)")
                }
            })
            .frame(maxHeight: .infinity, alignment: .top)  // never re-center while the window catches up
    }
}

// MenuBarExtra's window grows with its content but never shrinks back, leaving the
// panel floating in an oversized window. Pin the window height to the content height
// ourselves, top edge fixed. Idempotent, so it agrees with the system when that resizes.
//
// Also reports whether the window is on screen. onAppear/onDisappear cannot: the system keeps
// the panel's views alive after it closes, so onDisappear never fires and the app would go on
// sampling and rendering for a hidden panel (10% CPU instead of under 1%).
private struct WindowFit: NSViewRepresentable {
    let height: CGFloat
    let visible: (Bool) -> Void

    final class Probe: NSView {
        var visible: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            observer.map(NotificationCenter.default.removeObserver)
            observer = window.map { window in
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                       object: window, queue: .main) { [weak self] _ in
                    self?.visible(window.occlusionState.contains(.visible))
                }
            }
            visible(window?.occlusionState.contains(.visible) ?? false)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let probe = Probe()
        probe.visible = visible
        return probe
    }

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
            HStack(spacing: 14) {
                Ring(score: headroom.score, size: 56, stroke: 5)
                    .overlay {
                        Text("\(100 - headroom.score)").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Headroom.alarm(headroom.score).map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(.primary))
                            .contentTransition(.identity)  // digits snap; only the colour eases
                            .animation(Ring.motion, value: headroom.score)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Pressure \(100 - headroom.score) of 100")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pressure").fontWeight(.bold)
                    Text(state.verdict).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)  // plus the panel's 6 = 14, same as the side margin

            // One ring per contributor, its glyph inside. Facts are in the tooltip.
            // Outer rings sit on the content edges, in line with the hero ring and the chevron.
            HStack(spacing: 0) {
                contributor("cpu", headroom.cpu, "CPU: \(Int(headroom.load))% of all cores busy")
                Spacer(minLength: 0)
                contributor("memorychip", headroom.memory,
                            "Memory: \(headroom.memoryFree)% free, \(headroom.swapUsed.formatted(.byteCount(style: .memory))) swap")
                Spacer(minLength: 0)
                contributor("display", headroom.gpu, "GPU: \(Int(headroom.gpuBusy))% busy")
                Spacer(minLength: 0)
                contributor("thermometer.medium", headroom.thermal,
                            "Thermal: " + ["nominal", "fair", "serious", "critical"][headroom.thermalState.rawValue])
                Spacer(minLength: 0)
                contributor("internaldrive", headroom.disk,
                            "Disk: \(Int(headroom.diskFreeGB)) GB free, \(Int(headroom.diskBusy))% busy")
            }
            .padding(.vertical, 14)

            if !culprits.isEmpty {
                Divider().padding(.bottom, 4)
                ForEach(culprits) { culprit in
                    Row(icon: culprit.app.icon, name: culprit.app.name, value: culprit.value, detail: culprit.detail)
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
        Ring(score: score, size: 34, stroke: 3)
            .overlay {
                // The glyph takes the alarm colour too, so the eye lands on what hurts.
                Image(systemName: symbol).font(.system(size: 13))
                    .foregroundStyle(Headroom.alarm(score).map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(.secondary))
                    .animation(Ring.motion, value: score)
            }
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

/// The panel's ring: same idea as `Headroom.ring` (the menu bar image, larger and heavier), drawn as shapes
/// so arc, width and colour animate between samples.
struct Ring: View {
    static let motion = Animation.smooth(duration: 0.3)  // ponytail: feel knob; samples arrive every 2s
    let score: Int
    let size: CGFloat
    let stroke: CGFloat

    var body: some View {
        let pressure = Double(100 - score) / 100
        let alarm = Headroom.alarm(score)
        let ink = alarm.map { Color(nsColor: $0) } ?? .primary
        let width = stroke * (0.6 + 0.8 * pressure)
        let diameter = size - stroke * 1.4 - 1.5
        ZStack {
            Circle().stroke(ink.opacity(alarm == nil ? 0.3 : 0.5), lineWidth: width)
            Circle().trim(from: 0, to: pressure)
                .stroke(ink, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))  // start at 12 o'clock
                .scaleEffect(x: -1)             // run counter-clockwise
        }
        .frame(width: diameter, height: diameter)
        .frame(width: size, height: size)
        .animation(Self.motion, value: score)
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
