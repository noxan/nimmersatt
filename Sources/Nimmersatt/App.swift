import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--check") {
            check()
        } else if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1])
        } else {
            NimmersattApp.main()
        }
    }

    // Self-check: `swift run Nimmersatt --check`. Fails if sampling or grouping breaks.
    static func check() {
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
        print("ok: \(apps.count) groups, \(Int(total))% of \(Int(cores * 100))%")
    }

    // Renders the panel with live data to a PNG, to review layout without clicking the menu bar.
    @MainActor static func snapshot(to path: String) {
        let sampler = Sampler()
        _ = sampler.sample()
        sleep(1)
        let renderer = ImageRenderer(content: Panel(apps: sampler.sample()).background(.background))
        renderer.scale = 2
        let tiff = renderer.nsImage!.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try! png.write(to: URL(fileURLWithPath: path))
    }
}

@Observable
final class Model {
    var apps: [AppUsage] = []
    private let sampler = Sampler()
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    init() {
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let apps = self.sampler.sample()
            DispatchQueue.main.async { self.apps = apps }
        }
        timer.resume()
    }
}

struct NimmersattApp: App {
    @State private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }  // no Dock icon under `swift run`

    var body: some Scene {
        MenuBarExtra {
            Panel(apps: model.apps)
        } label: {
            // Name the hog in the menu bar only when one app holds half a core or more.
            if let top = model.apps.max(by: { $0.cpu < $1.cpu }), top.cpu >= 50 {
                Text("\(top.name) \(Int(top.cpu))%")
            } else {
                Image(systemName: "gauge.with.needle")
            }
        }
        .menuBarExtraStyle(.window)  // the system supplies the panel's glass; content adds no material
    }
}

// Laid out like the system's Wi-Fi panel: bold title, inset dividers, bold section
// headers, rows of round icon + name + trailing value, plain footer actions.
struct Panel: View {
    let apps: [AppUsage]

    var body: some View {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let load = apps.reduce(0) { $0 + $1.cpu } / cores

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Nimmersatt").fontWeight(.bold)
                Spacer()
                Text("\(Int(load))% CPU").foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

            section("CPU", apps.sorted { $0.cpu > $1.cpu }) { app in
                Row(app: app, value: "\(Int(app.cpu))%", detail: app.busiestCPU >= 1 ? app.busiest : nil)
            }
            section("Memory", apps.sorted { $0.memory > $1.memory }) { app in
                Row(app: app, value: app.memory.formatted(.byteCount(style: .memory)), detail: nil)
            }

            Divider().padding(.bottom, 4)
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

    @ViewBuilder
    private func section(_ title: String, _ sorted: [AppUsage], row: @escaping (AppUsage) -> Row) -> some View {
        Divider()
        Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
        ForEach(sorted.prefix(5)) { row($0) }
        Spacer().frame(height: 6)
    }
}

struct Row: View {
    let app: AppUsage
    let value: String
    let detail: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: Circle())
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).lineLimit(1)
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
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
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
