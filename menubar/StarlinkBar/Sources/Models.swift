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
