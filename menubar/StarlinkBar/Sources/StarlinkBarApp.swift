import AppKit
import Charts
import ServiceManagement
import SwiftUI

@main
struct StarlinkBarApp: App {
    @StateObject private var monitor = Monitor()
    @AppStorage("barDisplay") private var barDisplay = "latency"  // latency / download / none

    init() {
        // Debug: `StarlinkBar --snapshot out.png` renders the panel to a PNG and quits.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            let delay = UserDefaults.standard.double(forKey: "snapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 4)) { [monitor] in
                let r = ImageRenderer(content: PanelView().environmentObject(monitor)
                    .background(Color(nsColor: .windowBackgroundColor)))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(monitor)
        } label: {
            Image(nsImage: StatusIcon.image(for: monitor.status))
            if let text = barText { Text(text) }
        }
        .menuBarExtraStyle(.window)
    }

    private var barText: String? {
        guard monitor.status != .unreachable, let n = monitor.now else { return nil }
        if monitor.status == .down { return "offline" }
        switch barDisplay {
        case "latency": return n.latencyMs.map { "\(Int($0.rounded())) ms" }
        case "download": return "\(Fmt.mbps(n.downBps)) Mbps"
        default: return nil
        }
    }
}

// MARK: - Status colors and icon

extension Monitor.Status {
    var color: NSColor {
        switch self {
        case .ok: return .systemGreen
        case .degraded: return .systemOrange
        case .down: return .systemRed
        case .unreachable, .starting: return .systemGray
        }
    }

    var title: String {
        switch self {
        case .ok: return "Connected"
        case .degraded: return "Degraded"
        case .down: return "No internet"
        case .unreachable: return "Not connected"
        case .starting: return "Connecting…"
        }
    }
}

enum StatusIcon {
    private static let symbols = ["satellite.fill", "antenna.radiowaves.left.and.right"]

    /// Non-template image so the menu bar keeps the status color.
    static func image(for status: Monitor.Status) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(.init(paletteColors: [status.color]))
        for name in symbols {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Starlink")?
                .withSymbolConfiguration(config) {
                img.isTemplate = false
                return img
            }
        }
        return NSImage()
    }
}

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if monitor.status == .unreachable {
                unreachable
            } else {
                metrics
                charts
                obstruction
                Divider()
                outages
                if monitor.source == .collector { speedTest }
            }
            Divider()
            if showSettings { SettingsView().environmentObject(monitor); Divider() }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(Color(nsColor: monitor.status.color)).frame(width: 10, height: 10)
            Text(monitor.status.title).font(.headline)
            if monitor.status == .down, let since = monitor.now?.downSince {
                Text("· " + Fmt.duration(Date().timeIntervalSince1970 - since)).font(.headline)
            }
            Spacer()
            if let up = monitor.now?.uptimeS {
                Text("Dish up \(Fmt.ago(up))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var unreachable: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.source == .dish {
                Text("Can't reach the Starlink dish at \(monitor.dishHost).").font(.callout)
                Text("Make sure this Mac is on the Starlink network. If macOS asked for Local Network access, allow it in System Settings › Privacy & Security › Local Network.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The collector at \(monitor.collectorURL.absoluteString) is not answering.")
                    .font(.callout)
                Text("Start it with:").font(.caption).foregroundStyle(.secondary)
                Text("python3 collector/main.py")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var metrics: some View {
        let n = monitor.now
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Metric(label: "Latency", value: n?.latencyMs.map { "\(Int($0.rounded()))" } ?? "--", unit: "ms")
                Metric(label: "Packet loss", value: n?.dropRate.map { String(format: "%.1f", $0 * 100) } ?? "--", unit: "%")
            }
            GridRow {
                Metric(label: "Download", value: Fmt.mbps(n?.downBps), unit: "Mbps")
                Metric(label: "Upload", value: Fmt.mbps(n?.upBps), unit: "Mbps")
            }
        }
    }

    private var charts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 15 min").font(.caption).foregroundStyle(.secondary)
            Sparkline(points: monitor.latency, color: .primary, label: "ms")
            Sparkline(points: monitor.download, color: .blue, label: "Mbps", area: true)
        }
    }

    private var obstruction: some View {
        let n = monitor.now
        var alerts = (n?.alerts ?? []).map { Labels.alerts[$0] ?? $0 }
        if n?.currentlyObstructed == true { alerts.insert("Obstructed now", at: 0) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Obstructed %.2f %%", (n?.obstructionFraction ?? 0) * 100)).font(.callout)
            if alerts.isEmpty {
                Text("No alerts").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(alerts.joined(separator: " · ")).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var outages: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let o = monitor.outages {
                Text("Outages today: \(o.count) · \(Fmt.duration(o.totalS)) total").font(.callout.bold())
                if o.items.isEmpty {
                    Text("No outages today").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(o.items.prefix(5)) { it in
                    HStack {
                        Text(Fmt.clock(it.startTs)).monospacedDigit().frame(width: 44, alignment: .leading)
                        Text(Fmt.duration(it.durationS)).monospacedDigit().frame(width: 60, alignment: .leading)
                        Text(Labels.causes[it.cause] ?? it.cause).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if o.items.count > 5 {
                    Text("and \(o.items.count - 5) more").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Outages today: --").font(.callout.bold())
            }
        }
    }

    private var speedTest: some View {
        HStack {
            Text("Last speed test").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let st = monitor.now?.lastSpeedtest, let n = monitor.now {
                Text("\(Int(st.downMbps ?? 0)) ↓ / \(Int(st.upMbps ?? 0)) ↑ Mbps (\(Fmt.ago(n.ts - st.ts)) ago)")
                    .font(.caption)
            } else {
                Text("No tests yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if monitor.source == .collector {
                Button("Open dashboard") {
                    NSWorkspace.shared.open(monitor.collectorURL.appendingPathComponent("tv/"))
                }
            }
            Spacer()
            Button(showSettings ? "Done" : "Settings…") { showSettings.toggle() }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

struct Metric: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Sparkline: View {
    let points: [Point]
    let color: Color
    let label: String
    var area = false

    var body: some View {
        HStack(spacing: 6) {
            Chart(points) { p in
                if area {
                    AreaMark(x: .value("Time", p.date), y: .value(label, p.value))
                        .foregroundStyle(color.opacity(0.35))
                }
                LineMark(x: .value("Time", p.date), y: .value(label, p.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: Date().addingTimeInterval(-900)...Date())
            .frame(height: 34)
            Text(peak).font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }

    private var peak: String {
        guard let m = points.map(\.value).max() else { return label }
        return "\(m >= 10 ? String(format: "%.0f", m) : String(format: "%.1f", m)) \(label)"
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var monitor: Monitor
    @AppStorage("barDisplay") private var barDisplay = "latency"
    @AppStorage("notifyOutages") private var notifyOutages = true
    @AppStorage("notifyHighLatency") private var notifyHighLatency = false
    @AppStorage("source") private var source = Monitor.Source.dish.rawValue
    @AppStorage("dishHost") private var dishHost = Monitor.defaultDishHost
    @AppStorage("collectorURL") private var collectorURL = Monitor.defaultCollectorURL
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Menu bar shows", selection: $barDisplay) {
                Text("Latency").tag("latency")
                Text("Download").tag("download")
                Text("Icon only").tag("none")
            }
            Toggle("Notify on outages (> 10 s)", isOn: $notifyOutages)
            Toggle("Notify on high latency (> 80 ms for 5 min)", isOn: $notifyHighLatency)
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in setLogin(on) }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            Picker("Data source", selection: $source) {
                Text("Dish (direct)").tag(Monitor.Source.dish.rawValue)
                Text("Collector").tag(Monitor.Source.collector.rawValue)
            }
            .onChange(of: source) { _ in monitor.reset() }
            HStack {
                if source == Monitor.Source.dish.rawValue {
                    Text("Dish address")
                    TextField(Monitor.defaultDishHost, text: $dishHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { monitor.reset() }
                } else {
                    Text("Collector")
                    TextField(Monitor.defaultCollectorURL, text: $collectorURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { monitor.reset() }
                }
            }
            Button("Send test notification") { monitor.sendTestNotification() }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
