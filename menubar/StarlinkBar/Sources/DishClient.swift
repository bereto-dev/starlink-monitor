import Foundation

/// Read-only gRPC-web client for the Starlink dish (Swift port of collector/starlink.py).
/// Only get_status and get_history are ever sent; never commands (reboot, stow, ...).
struct DishClient {
    struct Status {
        var uptimeS: Double?
        var dropRate: Double
        var latencyMs: Double?
        var downBps: Double
        var upBps: Double
        var obstructionFraction: Double
        var currentlyObstructed: Bool
        var alerts: [String]
        var hardware: String?
        var software: String?
        var service = ServiceState()
    }

    struct Sample {
        let counter: Int
        let latencyMs: Double?
        let dropRate: Double?
        let downBps: Double?
        let upBps: Double?
        let powerW: Double?
    }

    struct Outage {
        let startTs: Double
        let durationS: Double
        let cause: String
    }

    /// An entry of the dish's own event log (about two days long).
    struct Event {
        static let highDownlinkPacketLoss: UInt64 = 12  // EventReason, from the dish's reflection

        let reason: UInt64
        let startTs: Double    // Unix seconds
        let durationS: Double
    }

    struct History {
        let current: Int
        let samples: [Sample]   // oldest -> newest; newest counter is current - 1
        let outages: [Outage]
        let events: [Event]
    }

    enum DishError: Error { case badResponse, grpc(String) }

    var host: String

    private static let getStatus = 1004
    private static let getHistory = 1007
    private static let gpsToUnix = 315_964_800.0 - 18  // GPS epoch minus current leap seconds

    // DishAlerts fields, from the dish's own gRPC reflection (firmware 2026.09).
    private static let alertNames: [Int: String] = [
        1: "motors_stuck", 2: "thermal_shutdown", 3: "thermal_throttle", 4: "unexpected_location",
        5: "mast_not_near_vertical", 6: "slow_ethernet_speeds", 8: "install_pending", 9: "is_heating",
        10: "power_supply_thermal_throttle", 11: "is_power_save_idle", 14: "dbf_telem_stale",
        16: "low_motor_current", 17: "lower_signal_than_predicted", 18: "slow_ethernet_speeds_100",
        19: "obstruction_map_reset", 20: "dish_water_detected", 21: "router_water_detected",
        22: "upsu_router_port_slow", 23: "no_ethernet_link",
    ]
    private static let causes: [UInt64: String] = [
        0: "unknown", 1: "booting", 2: "stowed", 3: "thermal_shutdown", 4: "no_schedule", 5: "no_sats",
        6: "obstructed", 7: "no_downlink", 8: "no_pings", 9: "actively_hunting", 10: "dish_unreachable",
    ]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        return URLSession(configuration: c)
    }()

    // MARK: - Requests

    func status() async throws -> Status {
        let top = try await call(Self.getStatus)
        guard let body = top.bytes(2004) else { throw DishError.badResponse }
        let s = Proto.fields(body)
        let info = Proto.fields(s.bytes(1) ?? Data())
        let state = Proto.fields(s.bytes(2) ?? Data())
        let obs = Proto.fields(s.bytes(1004) ?? Data())
        let alerts = Proto.parse(s.bytes(1005) ?? Data()).compactMap { f -> String? in
            if case .varint(let v) = f.value, v != 0 { return Self.alertNames[f.number] ?? "alert_\(f.number)" }
            return nil
        }
        return Status(
            uptimeS: state.uint(1).map { Double($0) },
            dropRate: s.float(1003) ?? 0,
            latencyMs: s.float(1009),
            downBps: s.float(1007) ?? 0,
            upBps: s.float(1008) ?? 0,
            obstructionFraction: obs.float(1) ?? 0,
            currentlyObstructed: (obs.uint(5) ?? 0) != 0,
            alerts: alerts,
            hardware: info.string(2),
            software: info.string(3),
            service: Self.service(s))
    }

    /// Plan limits, account state and pending updates (dish_get_status fields 1021-1045, 2000).
    private static func service(_ s: Proto.Message) -> ServiceState {
        let update = Proto.fields(s.bytes(1026) ?? Data())
        let config = Proto.fields(s.bytes(2000) ?? Data())
        var st = ServiceState()
        st.disablement = s.uint(1024) ?? 0
        st.downloadLimit = s.uint(1044) ?? 0
        st.uploadLimit = s.uint(1045) ?? 0
        st.updateState = s.uint(1021) ?? 0
        st.updateProgress = update.float(2)
        st.rebootReady = (s.uint(1030) ?? 0) != 0 || st.updateState == ServiceState.rebootRequired
        st.rebootHour = config.uint(9).map(Int.init)
        st.rebootScheduled = update.uint(4).flatMap(Self.unixSeconds)
        return st
    }

    /// reboot_scheduled_utc_time doesn't document its unit: accept s, ms or ns if it lands in the next few days.
    private static func unixSeconds(_ v: UInt64) -> Date? {
        let raw = Double(v)
        let s = raw > 1e17 ? raw / 1e9 : raw > 1e14 ? raw / 1e6 : raw > 1e11 ? raw / 1e3 : raw
        let d = Date(timeIntervalSince1970: s)
        return d.timeIntervalSinceNow > 0 && d.timeIntervalSinceNow < 4 * 86400 ? d : nil
    }

    func history() async throws -> History {
        let top = try await call(Self.getHistory)
        guard let body = top.bytes(2006) else { throw DishError.badResponse }
        var current = 0
        var arrays: [Int: [Float]] = [:]
        var outages: [Outage] = []
        var events: [Event] = []
        for f in Proto.parse(body) {
            switch (f.number, f.value) {
            case (1, .varint(let v)):
                current = Int(v)
            case (1001...1004, .bytes(let d)), (1010, .bytes(let d)):  // 1010 = power_in (W)
                arrays[f.number] = Proto.floats(d)
            case (1009, .bytes(let d)):
                let o = Proto.fields(d)
                outages.append(Outage(
                    startTs: Double(o.uint(2) ?? 0) / 1e9 + Self.gpsToUnix,
                    durationS: Double(o.uint(3) ?? 0) / 1e9,
                    cause: Self.causes[o.uint(1) ?? 0] ?? "cause_\(o.uint(1) ?? 0)"))
            case (1011, .bytes(let d)):  // event_log -> repeated events (field 1)
                for e in Proto.parse(d) {
                    guard e.number == 1, case .bytes(let ev) = e.value else { continue }
                    let m = Proto.fields(ev)
                    events.append(Event(reason: m.uint(2) ?? 0,
                                        startTs: Double(m.uint(3) ?? 0) / 1e9,
                                        durationS: Double(m.uint(4) ?? 0) / 1e9))
                }
            default:
                break
            }
        }
        let size = arrays.values.map(\.count).min() ?? 0
        guard size > 0 else { return History(current: current, samples: [], outages: outages, events: events) }
        let n = min(current, size)  // after a dish reboot the buffer is not full yet
        func at(_ f: Int, _ i: Int) -> Double? { arrays[f].map { Double($0[i]) } }
        let samples = (current - n..<current).map { c -> Sample in
            let i = c % size
            return Sample(counter: c, latencyMs: at(1002, i), dropRate: at(1001, i), downBps: at(1003, i),
                          upBps: at(1004, i), powerW: at(1010, i))
        }
        return History(current: current, samples: samples, outages: outages, events: events)
    }

    // MARK: - Transport

    private func call(_ request: Int) async throws -> Proto.Message {
        precondition(request == Self.getStatus || request == Self.getHistory, "read-only client")
        var body = Proto.varint(UInt64(request << 3 | 2))
        body.append(0)  // empty message
        var frame = Data([0])
        frame.append(contentsOf: withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init))
        frame.append(body)

        var req = URLRequest(url: URL(string: "http://\(host):9201/SpaceX.API.Device.Device/Handle")!)
        req.httpMethod = "POST"
        req.httpBody = frame
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        let (data, resp) = try await Self.session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw DishError.badResponse }

        var msg: Data?
        var i = data.startIndex
        while i + 5 <= data.endIndex {
            let flag = data[i]
            let len = data[i + 1..<i + 5].reduce(0) { $0 << 8 | Int($1) }
            let payload = data[i + 5..<min(i + 5 + len, data.endIndex)]
            i += 5 + len
            if flag & 0x80 != 0 {
                let text = String(decoding: payload, as: UTF8.self)
                if text.contains("grpc-status:") && !text.contains("grpc-status: 0") {
                    throw DishError.grpc(text)
                }
            } else if msg == nil {
                msg = Data(payload)
            }
        }
        guard let msg else { throw DishError.badResponse }
        return Proto.fields(msg)
    }
}

/// Minimal protobuf wire-format decoder.
enum Proto {
    enum Value {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case bytes(Data)
    }

    struct Field {
        let number: Int
        let value: Value
    }

    /// Last value of each field.
    struct Message {
        let values: [Int: Value]

        func uint(_ n: Int) -> UInt64? {
            if case .varint(let v)? = values[n] { return v }
            return nil
        }

        func float(_ n: Int) -> Double? {
            if case .fixed32(let v)? = values[n] { return Double(Float(bitPattern: v)) }
            return nil
        }

        func bytes(_ n: Int) -> Data? {
            if case .bytes(let d)? = values[n] { return d }
            return nil
        }

        func string(_ n: Int) -> String? { bytes(n).map { String(decoding: $0, as: UTF8.self) } }
    }

    static func varint(_ v: UInt64) -> Data {
        var v = v, out = Data()
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }

    static func parse(_ data: Data) -> [Field] {
        let b = [UInt8](data)
        var i = 0, out: [Field] = []
        func readVarint() -> UInt64? {
            var r: UInt64 = 0, s: UInt64 = 0
            while i < b.count {
                let c = b[i]; i += 1
                if s < 64 { r |= UInt64(c & 0x7F) << s }
                s += 7
                if c < 0x80 { return r }
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { break }
            let n = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return out }
                out.append(Field(number: n, value: .varint(v)))
            case 5:
                guard i + 4 <= b.count else { return out }
                let v = b[i..<i + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                i += 4
                out.append(Field(number: n, value: .fixed32(v)))
            case 1:
                guard i + 8 <= b.count else { return out }
                let v = b[i..<i + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                i += 8
                out.append(Field(number: n, value: .fixed64(v)))
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { return out }
                out.append(Field(number: n, value: .bytes(Data(b[i..<i + Int(len)]))))
                i += Int(len)
            default:
                return out  // unsupported wire type: stop
            }
        }
        return out
    }

    static func fields(_ data: Data) -> Message {
        var values: [Int: Value] = [:]
        for f in parse(data) { values[f.number] = f.value }
        return Message(values: values)
    }

    static func floats(_ data: Data) -> [Float] {
        let b = [UInt8](data)
        return stride(from: 0, to: b.count - 3, by: 4).map { i in
            Float(bitPattern: b[i..<i + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
    }
}
