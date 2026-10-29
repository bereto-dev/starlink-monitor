import Darwin
import Foundation

/// Stats for the network the Mac is on when it isn't Starlink, shaped like the dish's:
/// latency (HTTPS round trip), packet loss (failed checks), throughput (interface byte
/// counters, i.e. current usage) and outages (checks failing for a while).
/// Needs no permissions.
@MainActor
final class NetworkStats {
    struct Snapshot {
        var interface: String?
        var connection: String?
        var connectedSince = Date()
        var state = "ok"               // ok / degraded / down, same rules as the dish
        var latencyMs: Double?
        var avgLatencyMs: Double?      // last 30 s
        var latency: [Point] = []      // last 15 min
        var lossPercent = 0.0          // last 60 s
        var downBps: Double?
        var upBps: Double?
        var download: [Point] = []     // Mbps, last 15 min
        var upload: [Point] = []       // Mbps, last 15 min
        var loss: [Point] = []         // %, last 15 min
        var downSince: Date?
        var outages = Outages(count: 0, totalS: 0, items: [])

        /// Same shape as the dish's readings. There is no power reading off Starlink.
        var readings: Readings {
            var r = Readings()
            r.value = [.latency: latencyMs, .download: downBps.map { $0 / 1e6 }, .upload: upBps.map { $0 / 1e6 },
                       .loss: lossPercent].compactMapValues { $0 }
            r.series = [.latency: latency, .download: download, .upload: upload, .loss: loss]
            r.average[.latency] = avgLatencyMs
            for m in [Metric.download, .upload, .loss] { r.average[m] = Readings.recentAverage(r.series[m] ?? []) }
            return r
        }
    }

    static let probeEvery: TimeInterval = 4
    static let probeURL = URL(string: "https://www.apple.com/library/test/success.html")!
    static let lossWindow: TimeInterval = 60
    static let latencyWindow: TimeInterval = 30
    static let downAfter: TimeInterval = 5          // like the dish rules
    static let minOutage: TimeInterval = 2          // shorter blips aren't listed

    private(set) var snapshot = Snapshot()
    private var probes: [(date: Date, ok: Bool)] = []
    private var lastProbe = Date.distantPast
    private var lastCounters: (date: Date, rx: UInt64, tx: UInt64)?
    private var outageDay = Calendar.current.startOfDay(for: Date())

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        return URLSession(configuration: c)
    }()

    /// A different network: start over (outages are kept for the day).
    func start(interface: String?, connection: String?) {
        let outages = snapshot.outages
        snapshot = Snapshot(interface: interface, connection: connection)
        snapshot.outages = outages
        probes = []
        lastProbe = .distantPast
        lastCounters = nil
    }

    /// Called on every poll tick: refreshes throughput, and checks the internet when due.
    func poll() async {
        updateThroughput()
        if Date().timeIntervalSince(lastProbe) >= Self.probeEvery {
            _ = await probe()
        }
    }

    /// One internet check. Records latency/loss/outages; returns whether it worked.
    @discardableResult
    func probe() async -> Bool {
        lastProbe = Date()
        var req = URLRequest(url: Self.probeURL, cachePolicy: .reloadIgnoringLocalCacheData)
        req.timeoutInterval = 4
        let metrics = MetricsCollector()
        var ok = false
        if let (data, resp) = try? await session.data(for: req, delegate: metrics),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            ok = String(decoding: data, as: UTF8.self).contains("Success")
        }
        record(ok: ok, rtt: ok ? metrics.requestRoundTripMs : nil)
        return ok
    }

    // MARK: - Bookkeeping

    private func record(ok: Bool, rtt: Double?) {
        let now = Date()
        rollDayIfNeeded(now)

        probes.append((now, ok))
        probes.removeAll { now.timeIntervalSince($0.date) > Self.lossWindow }
        let failed = probes.filter { !$0.ok }.count
        snapshot.lossPercent = probes.isEmpty ? 0 : Double(failed) / Double(probes.count) * 100

        if let rtt {
            snapshot.latencyMs = rtt
            snapshot.latency.append(Point(date: now, value: rtt))
        }
        snapshot.loss.append(Point(date: now, value: snapshot.lossPercent))
        snapshot.latency.removeAll { now.timeIntervalSince($0.date) > 900 }
        snapshot.loss.removeAll { now.timeIntervalSince($0.date) > 900 }
        let recent = snapshot.latency.filter { now.timeIntervalSince($0.date) <= Self.latencyWindow }
        snapshot.avgLatencyMs = recent.isEmpty ? nil : recent.map(\.value).reduce(0, +) / Double(recent.count)

        if ok {
            if let start = snapshot.downSince {
                let duration = now.timeIntervalSince(start)
                if duration >= Self.minOutage { addOutage(start: start, duration: duration) }
            }
            snapshot.downSince = nil
        } else if snapshot.downSince == nil {
            // The previous successful check is the last moment we know it worked.
            snapshot.downSince = probes.dropLast().last(where: { $0.ok })?.date ?? now
        }
        snapshot.state = state(now)
    }

    private func state(_ now: Date) -> String {
        if let since = snapshot.downSince, now.timeIntervalSince(since) > Self.downAfter { return "down" }
        if (snapshot.avgLatencyMs ?? 0) > 80 || snapshot.lossPercent > 2 { return "degraded" }
        return "ok"
    }

    private func addOutage(start: Date, duration: TimeInterval) {
        var items = snapshot.outages.items
        items.insert(Outages.Item(startTs: start.timeIntervalSince1970, durationS: duration, cause: "no_internet"), at: 0)
        snapshot.outages = Outages(count: items.count, totalS: items.reduce(0) { $0 + $1.durationS }, items: items)
    }

    private func rollDayIfNeeded(_ now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        if day != outageDay {
            outageDay = day
            snapshot.outages = Outages(count: 0, totalS: 0, items: [])
        }
    }

    private func updateThroughput() {
        guard let name = snapshot.interface, let (rx, tx) = Self.counters(name) else { return }
        let now = Date()
        if let last = lastCounters {
            let dt = now.timeIntervalSince(last.date)
            if dt >= 0.5 {
                snapshot.downBps = Double(Self.delta(rx, last.rx)) * 8 / dt
                snapshot.upBps = Double(Self.delta(tx, last.tx)) * 8 / dt
                lastCounters = (now, rx, tx)
                snapshot.download.append(Point(date: now, value: (snapshot.downBps ?? 0) / 1e6))
                snapshot.upload.append(Point(date: now, value: (snapshot.upBps ?? 0) / 1e6))
                snapshot.download.removeAll { now.timeIntervalSince($0.date) > 900 }
                snapshot.upload.removeAll { now.timeIntervalSince($0.date) > 900 }
            }
        } else {
            lastCounters = (now, rx, tx)
        }
    }

    /// The Mac's IPv4 address on an interface (e.g. "192.168.1.107").
    static func ipv4(_ name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: a.pointee.ifa_name) == name else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            return String(cString: host)
        }
        return nil
    }

    /// Interface counters are 32-bit and wrap around at 4 GB.
    private static func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : new + (1 << 32) - old
    }

    /// Total bytes received/sent on an interface (e.g. "en0"), from getifaddrs.
    private static func counters(_ name: String) -> (UInt64, UInt64)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let a = p {
            defer { p = a.pointee.ifa_next }
            guard let addr = a.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: a.pointee.ifa_name) == name,
                  let data = a.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            return (UInt64(data.pointee.ifi_ibytes), UInt64(data.pointee.ifi_obytes))
        }
        return nil
    }
}
