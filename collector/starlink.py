"""Read-only gRPC-web client for the Starlink dish (no dependencies).

Only sends get_status and get_history. Never sends commands (reboot, stow, ...).
All field-number mapping lives here: if SpaceX changes them in a new
firmware, this is the only file to touch.

Quick test:  python3 starlink.py          (prints status and history)
"""
import json
import struct
import sys
import time
import urllib.request

URL = "http://192.168.100.1:9201/SpaceX.API.Device.Device/Handle"
TIMEOUT_S = 4

# Request fields (oneof). Read-only: do not add commands here.
REQ_GET_STATUS = 1004
REQ_GET_HISTORY = 1007
_ALLOWED_REQUESTS = (REQ_GET_STATUS, REQ_GET_HISTORY)

# Response fields
RESP_DISH_GET_STATUS = 2004
RESP_DISH_GET_HISTORY = 2006

HISTORY_SIZE = 900  # 15-min ring buffer at 1 Hz

# GPS epoch (1980-01-06) in Unix time minus the current 18 leap seconds.
GPS_TO_UNIX_S = 315964800 - 18

ALERTS = {
    1: "motors_stuck",
    2: "thermal_shutdown",
    3: "thermal_throttle",
    4: "unexpected_location",
    5: "mast_not_near_vertical",
    6: "slow_ethernet_speeds",
    7: "roaming",
    8: "install_pending",
    9: "is_heating",
    10: "power_supply_thermal_throttle",
    11: "is_power_save_idle",
    12: "moving_while_not_mobile",
    14: "dbf_telem_stale",
}

OUTAGE_CAUSES = {
    0: "unknown",
    1: "booting",
    2: "stowed",
    3: "thermal_shutdown",
    4: "no_schedule",
    5: "no_sats",
    6: "obstructed",
    7: "no_downlink",
    8: "no_pings",
    9: "actively_hunting",
    10: "dish_unreachable",
}


class DishError(Exception):
    pass


# --- minimal protobuf -------------------------------------------------------

def _varint(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return r, i


def _encode_varint(n):
    out = bytearray()
    while True:
        c = n & 0x7F
        n >>= 7
        if n:
            out.append(c | 0x80)
        else:
            out.append(c)
            return bytes(out)


def parse(b):
    """bytes -> [(field, wire_type, value)]"""
    i, out = 0, []
    while i < len(b):
        k, i = _varint(b, i)
        f, w = k >> 3, k & 7
        if w == 0:
            v, i = _varint(b, i)
        elif w == 5:
            v = struct.unpack("<f", b[i:i + 4])[0]
            i += 4
        elif w == 1:
            v = struct.unpack("<d", b[i:i + 8])[0]
            i += 8
        elif w == 2:
            n, i = _varint(b, i)
            v = b[i:i + n]
            i += n
        else:
            raise DishError("unsupported wire type: %d" % w)
        out.append((f, w, v))
    return out


def fields(b):
    """Last value of each field (for messages without repeated fields)."""
    return {f: v for f, _, v in parse(b)}


def floats(b):
    return struct.unpack("<%df" % (len(b) // 4), b)


# --- transport ------------------------------------------------------------

def _call(req_field):
    if req_field not in _ALLOWED_REQUESTS:
        raise ValueError("request not allowed (read-only): %r" % req_field)
    body = _encode_varint((req_field << 3) | 2) + b"\x00"  # empty message
    frame = b"\x00" + struct.pack(">I", len(body)) + body
    req = urllib.request.Request(URL, data=frame, method="POST", headers={
        "Content-Type": "application/grpc-web+proto",
        "X-Grpc-Web": "1",
    })
    try:
        raw = urllib.request.urlopen(req, timeout=TIMEOUT_S).read()
    except Exception as e:
        raise DishError("dish not responding: %s" % e)

    msg, i = None, 0
    while i + 5 <= len(raw):
        flag = raw[i]
        n = struct.unpack(">I", raw[i + 1:i + 5])[0]
        payload = raw[i + 5:i + 5 + n]
        i += 5 + n
        if flag & 0x80:  # trailers
            text = payload.decode("ascii", "replace")
            if "grpc-status:" in text and "grpc-status: 0" not in text:
                raise DishError("gRPC error: %s" % text.strip())
        elif msg is None:
            msg = payload
    if msg is None:
        raise DishError("empty response")
    return fields(msg)


# --- get_status ------------------------------------------------------------

def get_status():
    top = _call(REQ_GET_STATUS)
    if RESP_DISH_GET_STATUS not in top:
        raise DishError("response without dish_get_status")
    s = fields(top[RESP_DISH_GET_STATUS])

    info = fields(s.get(1, b""))
    state = fields(s.get(2, b""))
    obs = fields(s.get(1004, b""))
    alerts = [ALERTS.get(f, "alert_%d" % f)
              for f, w, v in parse(s.get(1005, b"")) if w == 0 and v]
    gps = fields(s.get(1015, b""))

    def txt(d, k):
        v = d.get(k)
        return v.decode("utf-8", "replace") if isinstance(v, bytes) else None

    return {
        "device": {
            "id": txt(info, 1),
            "hardware": txt(info, 2),
            "software": txt(info, 3),
            "country": txt(info, 4),
        },
        "uptime_s": state.get(1, 0),
        "drop_rate": s.get(1003, 0.0),
        "latency_ms": s.get(1009),
        "down_bps": s.get(1007, 0.0),
        "up_bps": s.get(1008, 0.0),
        "obstruction_fraction": obs.get(1, 0.0),
        "currently_obstructed": bool(obs.get(5, 0)),
        "alerts": alerts,
        "azimuth_deg": s.get(1011),
        "elevation_deg": s.get(1012),
        "gps_valid": bool(gps.get(1, 0)),
        "gps_sats": gps.get(2),
        "eth_speed_mbps": s.get(1016),
    }


# --- get_history -----------------------------------------------------------

def get_history():
    """Returns the 15-min buffer ordered oldest to newest.

    samples[k] carries the absolute `counter`; the newest sample is
    `current - 1`. Outages carry start_ts in Unix time (s).
    """
    top = _call(REQ_GET_HISTORY)
    if RESP_DISH_GET_HISTORY not in top:
        raise DishError("response without dish_get_history")
    raw = parse(top[RESP_DISH_GET_HISTORY])

    current = 0
    arrays = {}
    outages = []
    for f, w, v in raw:
        if f == 1 and w == 0:
            current = v
        elif f in (1001, 1002, 1003, 1004, 1010) and w == 2:
            arrays[f] = floats(v)
        elif f == 1009 and w == 2:
            o = fields(v)
            start_ns = o.get(2, 0)
            outages.append({
                "cause": OUTAGE_CAUSES.get(o.get(1, 0), "cause_%d" % o.get(1, 0)),
                "start_ts": start_ns / 1e9 + GPS_TO_UNIX_S,
                "duration_s": o.get(3, 0) / 1e9,
                "did_switch": bool(o.get(4, 0)),
            })

    size = min(len(a) for a in arrays.values()) if arrays else 0
    n = min(current, size)  # after a dish reboot the buffer is not full yet
    first = current - n
    names = {1001: "drop_rate", 1002: "latency_ms", 1003: "down_bps",
             1004: "up_bps", 1010: "power_w"}
    samples = []
    for c in range(first, current):
        idx = c % size
        row = {"counter": c}
        for f, name in names.items():
            a = arrays.get(f)
            row[name] = a[idx] if a else None
        samples.append(row)
    return {"current": current, "samples": samples, "outages": outages}


if __name__ == "__main__":
    t0 = time.time()
    st = get_status()
    print(json.dumps(st, indent=2))
    h = get_history()
    print("history: current=%d samples=%d outages=%d (%.2fs)"
          % (h["current"], len(h["samples"]), len(h["outages"]), time.time() - t0))
    print("latest sample:", h["samples"][-1] if h["samples"] else None)
    for o in h["outages"][-5:]:
        print("outage:", time.strftime("%H:%M:%S", time.localtime(o["start_ts"])),
              "%.1fs" % o["duration_s"], o["cause"])
    sys.exit(0)
