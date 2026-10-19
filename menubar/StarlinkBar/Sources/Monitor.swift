import AppKit
import Foundation
import UserNotifications

/// Polls the dish directly (default) or a collector, and fires outage notifications.
@MainActor
final class Monitor: ObservableObject {
    enum Status { case ok, degraded, down, unreachable, starting }
    enum Source: String { case dish, collector }

    @Published private(set) var now: NowStatus?
    @Published private(set) var latency: [Point] = []
    @Published private(set) var download: [Point] = []
    @Published private(set) var outages: Outages?
    @Published private(set) var reachable = true   // dish or collector answering

    static let nowEvery: TimeInterval = 2
    static let historyEvery: TimeInterval = 30
    static let unreachableAfter: TimeInterval = 8
    static let outageNotifyAfter: TimeInterval = 10
    static let highLatencyMs = 80.0
    static let highLatencyNotifyAfter: TimeInterval = 5 * 60

    static let defaultDishHost = "192.168.100.1"
    static let defaultCollectorURL = "http://localhost:8766"

    private var timers: [Timer] = []
    private var rules = StateRules()
    private var lastOk: Date?
    private var generation = 0   // bumps on source change so stale responses are dropped
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        return URLSession(configuration: c)
    }()

    // Notification bookkeeping
    private var outageStart: Date?
    private var outageNotified = false
    private var highLatencySince: Date?
    private var highLatencyNotified = false

    var source: Source {
        Source(rawValue: UserDefaults.standard.string(forKey: "source") ?? "") ?? .dish
    }

    var dishHost: String {
        let h = UserDefaults.standard.string(forKey: "dishHost")?.trimmingCharacters(in: .whitespaces) ?? ""
        return h.isEmpty ? Self.defaultDishHost : h
    }

    var collectorURL: URL {
        let s = UserDefaults.standard.string(forKey: "collectorURL") ?? Self.defaultCollectorURL
        return URL(string: s) ?? URL(string: Self.defaultCollectorURL)!
    }

    var status: Status {
        if !reachable && (source == .collector || lastOk == nil) { return .unreachable }
        guard let now else { return .starting }
        switch now.state {
        case "ok": return .ok
        case "degraded": return .degraded
        default: return .down
        }
    }

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        start()
    }

    func start() {
        timers.forEach { $0.invalidate() }
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.nowEvery, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollNow() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.historyEvery, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.pollHistory() }
            },
        ]
        refreshAll()
    }

    /// Clears everything and starts over (after changing the data source).
    func reset() {
        generation += 1
        now = nil
        latency = []
        download = []
        outages = nil
        reachable = true
        lastOk = nil
        rules = StateRules()
        outageStart = nil
        outageNotified = false
        refreshAll()
    }

    func refreshAll() {
        Task {
            await pollNow()
            await pollHistory()
        }
    }

    // MARK: - Polling

    private func pollNow() async {
        let gen = generation
        switch source {
        case .dish:
            let s = try? await DishClient(host: dishHost).status()
            guard gen == generation else { return }
            rules.update(s)
            if s != nil { lastOk = Date() }
            reachable = s != nil || (lastOk.map { Date().timeIntervalSince($0) < Self.unreachableAfter } ?? false)
            // Before the dish has ever answered, don't report outages: we may simply not be on Starlink.
            guard lastOk != nil else { return }
            apply(rules.snapshot(s))
        case .collector:
            do {
                let n: NowStatus = try await getJSON("/api/now")
                guard gen == generation else { return }
                lastOk = Date()
                reachable = true
                apply(n)
            } catch {
                guard gen == generation else { return }
                if let lastOk, Date().timeIntervalSince(lastOk) < Self.unreachableAfter { return }
                reachable = false
            }
        }
    }

    private func apply(_ n: NowStatus) {
        now = n
        if n.dishReachable, let lat = n.latencyMs {
            appendLive(Date(timeIntervalSince1970: n.ts), lat, n.downBps)
        }
        checkNotifications(n)
    }

    private func pollHistory() async {
        let gen = generation
        switch source {
        case .dish:
            guard let h = try? await DishClient(host: dishHost).history(), gen == generation else { return }
            let fetched = Date()
            var lat: [Point] = [], down: [Point] = []
            for s in h.samples {
                let d = fetched.addingTimeInterval(-Double(h.current - 1 - s.counter))
                if let v = s.latencyMs, (s.dropRate ?? 0) < 1 { lat.append(Point(date: d, value: v)) }
                if let v = s.downBps { down.append(Point(date: d, value: v / 1e6)) }
            }
            latency = lat
            download = down
            let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let today = h.outages.filter { $0.startTs >= midnight }.sorted { $0.startTs > $1.startTs }
            outages = Outages(
                count: today.count,
                totalS: today.reduce(0) { $0 + $1.durationS },
                items: today.map { Outages.Item(startTs: $0.startTs, durationS: $0.durationS, cause: $0.cause) })
        case .collector:
            if let h: History = try? await getJSON("/api/history?range=15m"), gen == generation {
                var lat: [Point] = [], down: [Point] = []
                for (i, t) in h.t.enumerated() {
                    let d = Date(timeIntervalSince1970: t)
                    if let v = h.latencyMs[i] { lat.append(Point(date: d, value: v)) }
                    if let v = h.downBps[i] { down.append(Point(date: d, value: v / 1e6)) }
                }
                // keep live points that are newer than the stored history
                let lastStored = lat.last?.date ?? .distantPast
                latency = lat + latency.filter { $0.date > lastStored }
                download = down + download.filter { $0.date > lastStored }
                trim()
            }
            if let o: Outages = try? await getJSON("/api/outages"), gen == generation {
                outages = o
            }
        }
    }

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: path, relativeTo: collectorURL)!
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decoder.decode(T.self, from: data)
    }

    private func appendLive(_ date: Date, _ lat: Double, _ down: Double?) {
        if let last = latency.last?.date, last >= date.addingTimeInterval(-0.5) { return }
        latency.append(Point(date: date, value: lat))
        if let down { download.append(Point(date: date, value: down / 1e6)) }
        trim()
    }

    private func trim() {
        let cut = Date().addingTimeInterval(-900)
        latency.removeAll { $0.date < cut }
        download.removeAll { $0.date < cut }
    }

    // MARK: - Notifications

    private func checkNotifications(_ n: NowStatus) {
        let d = UserDefaults.standard
        let notifyOutages = d.object(forKey: "notifyOutages") as? Bool ?? true
        let notifyLatency = d.bool(forKey: "notifyHighLatency")

        if n.state == "down" {
            let start = n.downSince.map { Date(timeIntervalSince1970: $0) } ?? outageStart ?? Date()
            outageStart = start
            if !outageNotified, Date().timeIntervalSince(start) > Self.outageNotifyAfter {
                outageNotified = true
                if notifyOutages {
                    notify("Starlink offline",
                           n.dishReachable ? "The dish responds but there is no connection." : "The dish is not responding.")
                }
            }
        } else if let start = outageStart {
            if outageNotified, notifyOutages {
                notify("Starlink is back", "The outage lasted \(Fmt.duration(Date().timeIntervalSince(start))).")
            }
            outageStart = nil
            outageNotified = false
        }

        if let avg = n.latencyAvg30sMs, avg > Self.highLatencyMs, n.state != "down" {
            let since = highLatencySince ?? Date()
            highLatencySince = since
            if !highLatencyNotified, Date().timeIntervalSince(since) > Self.highLatencyNotifyAfter {
                highLatencyNotified = true
                if notifyLatency {
                    notify("Starlink latency is high", "Around \(Int(avg)) ms for the last 5 minutes.")
                }
            }
        } else {
            highLatencySince = nil
            highLatencyNotified = false
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func sendTestNotification() {
        notify("StarlinkBar", "Notifications are working.")
    }
}

/// State rules shared with the collector (collector/main.py):
/// down = dish silent or drop >= 0.5 for more than 5 s; degraded = 30 s avg latency > 80 ms,
/// drop > 0.02 or obstructed now; ok = everything else.
struct StateRules {
    static let downAfter: TimeInterval = 5
    static let downDrop = 0.5
    static let degradedLatency = 80.0
    static let degradedDrop = 0.02
    static let window: TimeInterval = 30

    private let started = Date()
    private var last: DishClient.Status?
    private var lastOk: Date?
    private var badSince: Date?
    private var downSince: Date?
    private var samples: [(Date, Double)] = []

    mutating func update(_ s: DishClient.Status?) {
        let now = Date()
        if let s {
            last = s
            lastOk = now
            if s.dropRate >= Self.downDrop {
                if badSince == nil { badSince = now }
            } else {
                badSince = nil
                if let l = s.latencyMs { samples.append((now, l)) }
            }
        }
        samples.removeAll { $0.0 < now.addingTimeInterval(-Self.window) }
        if state(now) == "down" {
            if downSince == nil { downSince = badSince ?? lastOk ?? started }
        } else {
            downSince = nil
        }
    }

    var avgLatency: Double? {
        samples.isEmpty ? nil : samples.reduce(0) { $0 + $1.1 } / Double(samples.count)
    }

    func state(_ now: Date) -> String {
        if now.timeIntervalSince(lastOk ?? started) > Self.downAfter { return "down" }
        if let badSince, now.timeIntervalSince(badSince) > Self.downAfter { return "down" }
        guard let s = last else { return "down" }
        if (avgLatency ?? 0) > Self.degradedLatency || s.dropRate > Self.degradedDrop || s.currentlyObstructed {
            return "degraded"
        }
        return "ok"
    }

    /// Builds the same shape the collector's /api/now returns.
    func snapshot(_ fresh: DishClient.Status?) -> NowStatus {
        let now = Date()
        let s = last
        return NowStatus(
            ts: now.timeIntervalSince1970,
            state: state(now),
            online: state(now) != "down",
            dishReachable: fresh != nil,
            downSince: downSince?.timeIntervalSince1970,
            error: nil,
            latencyAvg30sMs: avgLatency,
            latencyMs: s?.latencyMs,
            dropRate: s?.dropRate,
            downBps: s?.downBps,
            upBps: s?.upBps,
            obstructionFraction: s?.obstructionFraction,
            currentlyObstructed: s?.currentlyObstructed,
            alerts: s?.alerts,
            uptimeS: s?.uptimeS,
            device: s.map { NowStatus.Device(id: nil, hardware: $0.hardware, software: $0.software, country: nil) },
            lastSpeedtest: nil)
    }
}
