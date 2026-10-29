import Foundation

// Mirrors the collector's JSON API (snake_case keys are converted by the decoder).

struct NowStatus: Decodable {
    struct Device: Decodable {
        let id: String?
        let hardware: String?
        let software: String?
        let country: String?
    }

    struct SpeedTest: Decodable {
        let ts: Double
        let downMbps: Double?
        let upMbps: Double?
    }

    let ts: Double
    let state: String           // ok / degraded / down
    let online: Bool
    let dishReachable: Bool
    let downSince: Double?
    let error: String?
    let latencyAvg30sMs: Double?
    let latencyMs: Double?
    let dropRate: Double?
    let downBps: Double?
    let upBps: Double?
    let obstructionFraction: Double?
    let currentlyObstructed: Bool?
    let alerts: [String]?
    let uptimeS: Double?
    let device: Device?
    let lastSpeedtest: SpeedTest?

    // convertFromSnakeCase turns "latency_avg_30s_ms" into "latencyAvg30SMs" (capital S),
    // so that one key needs an explicit mapping.
    enum CodingKeys: String, CodingKey {
        case ts, state, online, dishReachable, downSince, error
        case latencyAvg30sMs = "latencyAvg30SMs"
        case latencyMs, dropRate, downBps, upBps, obstructionFraction, currentlyObstructed
        case alerts, uptimeS, device, lastSpeedtest
    }
}

struct History: Decodable {
    let t: [Double]
    let latencyMs: [Double?]
    let downBps: [Double?]
}

struct Outages: Codable {
    struct Item: Codable, Identifiable {
        let startTs: Double
        let durationS: Double
        let cause: String
        var id: Double { startTs }
    }

    let count: Int
    let totalS: Double
    let items: [Item]
}

/// Last values seen from the dish, kept so they can be shown while off Starlink.
struct LastSeen: Codable {
    var date: Date
    var latencyMs: Double?
    var downBps: Double?
    var upBps: Double?
    var uptimeS: Double?
    var outages: Outages?

    /// Outages only make sense for the day they were recorded.
    var outagesToday: Outages? {
        guard let outages, Calendar.current.isDateInToday(date) else { return nil }
        return outages
    }
}

struct Point: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Account state, speed limits and pending updates, read from dish_get_status.
/// Enum values come from the dish's own reflection (firmware 2026.10).
struct ServiceState {
    static let rebootRequired: UInt64 = 6   // SoftwareUpdateState.REBOOT_REQUIRED

    var disablement: UInt64 = 0      // UtDisablementCode: 0 unknown, 1 OKAY
    var downloadLimit: UInt64 = 0    // RateLimitReason: 0 unknown, 1 NO_LIMIT
    var uploadLimit: UInt64 = 0
    var updateState: UInt64 = 0      // SoftwareUpdateState: 1 IDLE, 2-5 downloading/installing, 6 reboot required
    var updateProgress: Double?
    var rebootReady = false
    var rebootHour: Int?             // the dish's update window, local time
    var rebootScheduled: Date?

    struct Callout {
        enum Level { case problem, warning, info }
        let level: Level
        let text: String
    }

    static let disablementTexts: [UInt64: String] = [
        2: "No active Starlink plan on this dish. Check your account in the Starlink app.",
        3: "Service is limited: the dish is too far from its service address.",
        4: "Service is off: the dish is at sea without an ocean plan.",
        6: "Starlink isn't available in this country.",
        7: "Data limit reached. Service is restricted until you add data or the billing cycle resets.",
        8: "Starlink is disabled in this area right now.",
        10: "Roaming isn't allowed on this plan.",
        11: "Starlink can't confirm where the dish is, so service is limited.",
        12: "Your Starlink account is disabled. Check billing in the Starlink app.",
        13: "The dish software is too old for service and needs an update.",
        14: "Moving too fast for this plan, so service is paused.",
        15: "Service is limited while flying over this area.",
        16: "Starlink isn't allowed in this area.",
        17: "The dish is outside its home region, so service is limited.",
    ]

    static let limitTexts: [UInt64: String] = [
        2: "Speeds are limited by your plan's policy right now.",
        3: "Speeds are capped by a limit set on your Starlink account.",
        5: "Data limit reached. Speeds are reduced until you add data or the billing cycle resets.",
        6: "Speeds are reduced: your plan is on its low-speed tier.",
    ]

    /// When the dish will restart for its update, as "around 3:00".
    var rebootWhen: String {
        if let d = rebootScheduled { return "around " + Fmt.clock(d.timeIntervalSince1970) }
        if let h = rebootHour { return String(format: "around %d:00", h) }
        return "soon"
    }

    /// What to tell the user above the main reading, most serious first.
    var callouts: [Callout] {
        var out: [Callout] = []
        if disablement > 1 {
            out.append(Callout(level: .problem, text: Self.disablementTexts[disablement]
                ?? "Starlink service is restricted on this dish (code \(disablement)). Check the Starlink app."))
        }
        let down = downloadLimit > 1 ? downloadLimit : nil
        let up = uploadLimit > 1 ? uploadLimit : nil
        let overageSaid = disablement == 7  // DATA_OVERAGE_SANDBOX_POLICY already says "Data limit reached"
        if let reason = down ?? up, !(overageSaid && reason == 5) {
            var text = Self.limitTexts[reason] ?? "Speeds are limited on this dish (reason \(reason))."
            if down == nil { text += " Upload only." } else if up == nil { text += " Download only." }
            out.append(Callout(level: .warning, text: text))
        }
        if rebootReady {
            out.append(Callout(level: .info, text: "Update ready. The dish will restart \(rebootWhen), about a minute offline."))
        } else if (2...5).contains(updateState) {
            let pct = updateProgress.map { String(format: " (%.0f %%)", $0 * 100) } ?? ""
            out.append(Callout(level: .info, text: "The dish is downloading an update\(pct)."))
        }
        return out
    }
}

/// The five readings the popup shows. The chosen one is the big number + chart (and the menu bar);
/// the other four are the columns.
enum Metric: String, CaseIterable {
    case latency, download, upload, loss, power

    var title: String { rawValue.uppercased() }

    var name: String {
        switch self {
        case .latency: return "Latency"
        case .download: return "Download speed"
        case .upload: return "Upload speed"
        case .loss: return "Packet loss"
        case .power: return "Power use"
        }
    }

    var unit: String {
        switch self {
        case .latency: return "ms"
        case .download, .upload: return "Mbps"
        case .loss: return "%"
        case .power: return "W"
        }
    }

    /// Smallest top of the chart's scale, so a quiet line doesn't fill the whole height.
    var chartFloor: Double {
        switch self {
        case .latency: return 40
        case .download: return 1
        case .upload: return 0.5
        case .loss: return 5
        case .power: return 40
        }
    }

    /// The number alone (speeds in Mbps, loss in %, power in W).
    func format(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        switch self {
        case .latency: return "\(Int(v.rounded()))"
        case .download, .upload: return v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        case .loss: return String(format: "%.1f", v)
        case .power: return "\(Int(v.rounded()))"
        }
    }

    func text(_ v: Double?) -> String { "\(format(v)) \(unit)" }

    /// The reading shown big in the popup and in the menu bar.
    static var main: Metric {
        get {
            let d = UserDefaults.standard
            if let m = d.string(forKey: "mainMetric").flatMap(Metric.init) { return m }
            return d.string(forKey: "barDisplay") == "download" ? .download : .latency  // before 0.5
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mainMetric") }
    }

    /// Whether the menu bar shows the main reading next to the icon.
    static var showInMenuBar: Bool {
        get {
            let d = UserDefaults.standard
            return d.object(forKey: "menuBarShowsValue") as? Bool ?? (d.string(forKey: "barDisplay") != "none")
        }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarShowsValue") }
    }
}

/// Current value, recent average and last 15 minutes of every metric, from the dish or the other network.
struct Readings {
    var value: [Metric: Double] = [:]
    var average: [Metric: Double] = [:]
    var series: [Metric: [Point]] = [:]

    /// Average of the last 30 s of a series (measured from its newest point).
    static func recentAverage(_ points: [Point], window: TimeInterval = 30) -> Double? {
        guard let last = points.last?.date else { return nil }
        let recent = points.filter { last.timeIntervalSince($0.date) <= window }
        return recent.map(\.value).reduce(0, +) / Double(recent.count)
    }
}

enum Labels {
    static let causes: [String: String] = [
        "unknown": "unknown", "booting": "booting", "stowed": "stowed",
        "thermal_shutdown": "thermal shutdown", "no_schedule": "no schedule",
        "no_sats": "no satellites", "obstructed": "obstructed", "no_downlink": "no downlink",
        "no_pings": "no network response", "no_internet": "no internet", "actively_hunting": "searching for satellite",
        "dish_unreachable": "dish unreachable",
    ]

    static let alerts: [String: String] = [
        "motors_stuck": "Motors stuck",
        "thermal_shutdown": "Thermal shutdown",
        "thermal_throttle": "Thermal throttling",
        "unexpected_location": "Unexpected location",
        "mast_not_near_vertical": "Mast not vertical",
        "slow_ethernet_speeds": "Slow Ethernet",
        "install_pending": "Update pending",
        "is_heating": "Melting snow",
        "power_supply_thermal_throttle": "Power supply hot",
        "is_power_save_idle": "Power save",
        "dbf_telem_stale": "Stale telemetry",
        "low_motor_current": "Low motor current",
        "lower_signal_than_predicted": "Weaker signal than expected",
        "slow_ethernet_speeds_100": "Ethernet at 100 Mbps",
        "obstruction_map_reset": "Obstruction map reset",
        "dish_water_detected": "Water in the dish",
        "router_water_detected": "Water in the router",
        "upsu_router_port_slow": "Slow router port",
        "no_ethernet_link": "No Ethernet link",
    ]

    /// Readable alert name; unknown ones (a newer firmware) read "Unknown alert (17)".
    static func alert(_ name: String) -> String {
        if let label = alerts[name] { return label }
        if name.hasPrefix("alert_") { return "Unknown alert (\(name.dropFirst(6)))" }
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum Fmt {
    static func mbps(_ bps: Double?) -> String {
        guard let bps else { return "--" }
        let m = bps / 1e6
        return m >= 100 ? String(format: "%.0f", m) : m >= 10 ? String(format: "%.1f", m) : String(format: "%.2f", m)
    }

    static func ago(_ s: Double) -> String {
        let s = max(0, Int(s))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return "\(m) min"
    }

    static func duration(_ s: Double) -> String {
        if s < 10 { return String(format: "%.1f s", s) }
        if s < 60 { return "\(Int(s.rounded())) s" }
        let m = Int(s) / 60
        if m < 60 { return "\(m) min \(Int(s) % 60) s" }
        return "\(m / 60) h \(m % 60) min"
    }

    static func clock(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
