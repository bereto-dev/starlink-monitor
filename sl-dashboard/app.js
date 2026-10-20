/* Starlink Dashboard. Runs on old smart-TV browsers too (pure ES5: var, function, XMLHttpRequest). */
(function () {
  'use strict';

  var NOW_EVERY_MS = 3000;
  var HISTORY_EVERY_MS = 60000;
  var OUTAGES_EVERY_MS = 60000;
  var STALE_AFTER_MS = 12000;      // no answer from the collector => warning
  var SHIFT_EVERY_MS = 10 * 60000; // screen burn-in protection
  var WINDOW_S = 900;

  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var CAUSES = {
    unknown: 'unknown', booting: 'booting', stowed: 'stowed',
    thermal_shutdown: 'thermal shutdown', no_schedule: 'no schedule',
    no_sats: 'no satellites', obstructed: 'obstructed', no_downlink: 'no downlink',
    no_pings: 'no network response', actively_hunting: 'searching for satellite',
    dish_unreachable: 'dish unreachable'
  };
  var ALERTS = {
    motors_stuck: 'motors stuck',
    thermal_shutdown: 'thermal shutdown',
    thermal_throttle: 'thermal throttling',
    unexpected_location: 'unexpected location',
    mast_not_near_vertical: 'mast not vertical',
    slow_ethernet_speeds: 'slow Ethernet',
    install_pending: 'update pending',
    is_heating: 'melting snow',
    power_supply_thermal_throttle: 'power supply hot',
    is_power_save_idle: 'power save',
    dbf_telem_stale: 'stale telemetry',
    low_motor_current: 'low motor current',
    lower_signal_than_predicted: 'weaker signal than expected',
    slow_ethernet_speeds_100: 'Ethernet at 100 Mbps',
    obstruction_map_reset: 'obstruction map reset',
    dish_water_detected: 'water in the dish',
    router_water_detected: 'water in the router',
    upsu_router_port_slow: 'slow router port',
    no_ethernet_link: 'no Ethernet link'
  };
  var STATES = { ok: 'CONNECTED', degraded: 'DEGRADED', down: 'NO INTERNET' };

  var $ = function (id) { return document.getElementById(id); };

  // Chart series: t (s), latency (ms), download (bps)
  var series = { t: [], lat: [], down: [] };
  var last = null;          // latest /api/now
  var lastOkMs = 0;         // local time of the last response
  var skewS = 0;            // server clock - browser clock
  var shiftIdx = 0;

  // ---------- helpers ----------
  function get(url, ok, fail) {
    var x = new XMLHttpRequest();
    var sep = url.indexOf('?') < 0 ? '?' : '&';
    x.open('GET', url + sep + '_=' + new Date().getTime(), true);
    try { x.timeout = 8000; } catch (e) {}
    x.onreadystatechange = function () {
      if (x.readyState !== 4) return;
      if (x.status === 200) {
        var data;
        try { data = JSON.parse(x.responseText); } catch (e) { if (fail) fail(); return; }
        ok(data);
      } else if (fail) {
        fail();
      }
    };
    try { x.send(null); } catch (e) { if (fail) fail(); }
  }

  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function hhmm(d) { return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
  function mbps(bps) {
    if (bps === null || bps === undefined) return '--';
    var m = bps / 1e6;
    return m >= 100 ? m.toFixed(0) : m >= 10 ? m.toFixed(1) : m.toFixed(2);
  }
  function setText(id, s) {
    var el = $(id);
    if (el && el.innerHTML !== s) el.innerHTML = s;
  }
  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function alertName(a) {
    if (ALERTS[a]) return ALERTS[a];
    if (a.indexOf('alert_') === 0) return 'unknown alert (' + a.substring(6) + ')';
    return a.replace(/_/g, ' ');
  }
  function ago(s) {
    s = Math.max(0, Math.floor(s));
    var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d > 0) return d + ' d ' + h + ' h';
    if (h > 0) return h + ' h ' + m + ' min';
    return m + ' min';
  }
  function serverNow() { return new Date().getTime() / 1000 + skewS; }

  // ---------- scale to the screen ----------
  function fit() {
    var w = window.innerWidth || document.documentElement.clientWidth || 1920;
    var h = window.innerHeight || document.documentElement.clientHeight || 1080;
    var k = Math.min(w / 1920, h / 1080);
    var st = $('stage').style;
    var tr = 'scale(' + k + ')';
    st.webkitTransform = tr;
    st.transform = tr;
    st.left = Math.round((w - 1920 * k) / 2) + 'px';
    st.top = Math.round((h - 1080 * k) / 2) + 'px';
  }

  function burnShift() {
    var offs = [[40, 30], [46, 26], [34, 28], [44, 22], [36, 24]];
    shiftIdx = (shiftIdx + 1) % offs.length;
    $('shift').style.left = offs[shiftIdx][0] + 'px';
    $('shift').style.top = offs[shiftIdx][1] + 'px';
  }

  // ---------- clock ----------
  function tickClock() {
    var d = new Date(serverNow() * 1000);
    setText('clock', MONTHS[d.getMonth()] + ' ' + d.getDate() + ' &middot; ' + hhmm(d));
    updateOverlays();
  }

  // ---------- /api/now ----------
  function pollNow() {
    get('/api/now', function (n) {
      last = n;
      lastOkMs = new Date().getTime();
      skewS = n.ts - lastOkMs / 1000;
      renderNow(n);
      if (n.dish_reachable && n.latency_ms !== null) {
        pushPoint(Math.floor(n.ts), n.latency_ms, n.down_bps);
        drawChart();
      }
    }, function () { updateOverlays(); });
  }

  function renderNow(n) {
    var bar = $('bar');
    var cls = 'bar st-' + (STATES[n.state] ? n.state : 'wait');
    if (bar.className !== cls) bar.className = cls;
    setText('state', STATES[n.state] || '--');

    setText('lat', n.latency_ms === null ? '--' : Math.round(n.latency_ms) + '');
    setText('down', mbps(n.down_bps));
    setText('up', mbps(n.up_bps));
    setText('obs', n.obstruction_fraction === null ? '--' : (n.obstruction_fraction * 100).toFixed(2));

    var alerts = n.alerts || [];
    var lbl = $('obslbl');
    if (n.currently_obstructed) alerts = ['obstructed now'].concat(alerts);
    if (alerts.length) {
      var names = [];
      for (var i = 0; i < alerts.length; i++) names.push(alertName(alerts[i]));
      setText('obslbl', esc(names.join(' · ')));
      lbl.className = 'lbl warn';
    } else {
      setText('obslbl', 'obstructed · no alerts');
      lbl.className = 'lbl';
    }

    setText('uptime', n.uptime_s ? 'Dish up for ' + ago(n.uptime_s) : '--');
    var st = n.last_speedtest;
    if (st) {
      setText('speed', Math.round(st.down_mbps) + ' &darr; / ' + Math.round(st.up_mbps) +
        ' &uarr; Mbps <span class="muted">(' + ago(n.ts - st.ts) + ' ago)</span>');
    } else {
      setText('speed', '<span class="muted">No tests yet</span>');
    }
    if (n.device) {
      setText('dev', esc((n.device.hardware || '') + ' · ' + (n.device.software || '') +
        ' · ' + (n.device.country || '')));
    }
    updateOverlays();
  }

  function updateOverlays() {
    var stale = !lastOkMs || new Date().getTime() - lastOkMs > STALE_AFTER_MS;
    $('stale-overlay').style.display = (stale && lastOkMs) ? 'table' : 'none';
    var down = !stale && last && last.state === 'down';
    $('down-overlay').style.display = down ? 'table' : 'none';
    if (down) {
      var secs = last.down_since ? Math.max(0, Math.floor(serverNow() - last.down_since)) : 0;
      var m = Math.floor(secs / 60), s = secs % 60, h = Math.floor(m / 60);
      setText('downtimer', h > 0 ? h + ':' + pad(m % 60) + ':' + pad(s) : m + ':' + pad(s));
      setText('downsub', last.dish_reachable ? 'The dish responds but there is no connection'
        : 'The dish is not responding');
    }
  }

  // ---------- /api/history ----------
  function pollHistory() {
    get('/api/history?range=15m', function (h) {
      var t = [], lat = [], down = [];
      for (var i = 0; i < h.t.length; i++) {
        t.push(h.t[i]); lat.push(h.latency_ms[i]); down.push(h.down_bps[i]);
      }
      // keep live points newer than the stored history
      var lastT = t.length ? t[t.length - 1] : 0;
      for (var j = 0; j < series.t.length; j++) {
        if (series.t[j] > lastT) { t.push(series.t[j]); lat.push(series.lat[j]); down.push(series.down[j]); }
      }
      series = { t: t, lat: lat, down: down };
      trim();
      drawChart();
    });
  }

  function pushPoint(t, lat, down) {
    var n = series.t.length;
    if (n && series.t[n - 1] >= t) return;
    series.t.push(t); series.lat.push(lat); series.down.push(down);
    trim();
  }

  function trim() {
    var cut = serverNow() - WINDOW_S;
    var k = 0;
    while (k < series.t.length && series.t[k] < cut) k++;
    if (k) { series.t.splice(0, k); series.lat.splice(0, k); series.down.splice(0, k); }
  }

  // ---------- /api/outages ----------
  function pollOutages() {
    get('/api/outages', function (o) {
      setText('outsum', 'Outages today: ' + o.count + ' &middot; ' + fmtDur(o.total_s) + ' total');
      var html = '';
      if (!o.items.length) html = '<div class="oi muted">No outages today</div>';
      for (var i = 0; i < o.items.length && i < 3; i++) {
        var it = o.items[i];
        html += '<div class="oi"><span class="tm">' + hhmm(new Date(it.start_ts * 1000)) +
          '</span><span class="du">' + fmtDur(it.duration_s) + '</span>' +
          esc(CAUSES[it.cause] || it.cause) + '</div>';
      }
      if (o.items.length > 3) html += '<div class="oi muted">and ' + (o.items.length - 3) + ' more</div>';
      setText('outlist', html);
    });
  }

  function fmtDur(s) {
    if (s < 10) return s.toFixed(1) + ' s';
    if (s < 60) return Math.round(s) + ' s';
    var m = Math.floor(s / 60);
    if (m < 60) return m + ' min ' + Math.round(s % 60) + ' s';
    return Math.floor(m / 60) + ' h ' + (m % 60) + ' min';
  }

  // ---------- chart (2D canvas) ----------
  function niceMax(v, steps) {
    if (!(v > 0)) return steps[0];
    for (var i = 0; i < steps.length; i++) if (v <= steps[i]) return steps[i];
    return Math.ceil(v / steps[steps.length - 1]) * steps[steps.length - 1];
  }

  function drawChart() {
    var c = $('chart');
    if (!c.getContext) return;
    var g = c.getContext('2d');
    var W = c.width, H = c.height;
    var L = 110, R = 130, T = 20, B = 50;
    var pw = W - L - R, ph = H - T - B;
    g.clearRect(0, 0, W, H);

    var now = serverNow();
    var t0 = now - WINDOW_S;
    var maxLat = 0, maxDown = 0, i;
    for (i = 0; i < series.t.length; i++) {
      if (series.lat[i] !== null && series.lat[i] > maxLat) maxLat = series.lat[i];
      if (series.down[i] !== null && series.down[i] > maxDown) maxDown = series.down[i];
    }
    var latTop = niceMax(maxLat * 1.1, [40, 80, 120, 200, 400, 800, 1200]);
    var downTop = niceMax(maxDown / 1e6 * 1.1, [4, 8, 20, 40, 100, 200, 400, 800]);

    function x(t) { return L + (t - t0) / WINDOW_S * pw; }
    function yLat(v) { return T + ph - Math.min(v, latTop) / latTop * ph; }
    function yDown(v) { return T + ph - Math.min(v / 1e6, downTop) / downTop * ph; }

    // grid and axes
    g.lineWidth = 1;
    g.font = '26px Helvetica, Arial, sans-serif';
    for (i = 0; i <= 4; i++) {
      var yy = Math.round(T + ph * i / 4) + 0.5;
      g.strokeStyle = '#1e2a38';
      g.beginPath(); g.moveTo(L, yy); g.lineTo(L + pw, yy); g.stroke();
      g.fillStyle = '#cbd5e1';
      g.textAlign = 'right';
      g.fillText(Math.round(latTop * (4 - i) / 4) + '', L - 16, yy + 9);
      g.fillStyle = '#60a5fa';
      g.textAlign = 'left';
      var dv = downTop * (4 - i) / 4;
      g.fillText((dv % 1 ? dv.toFixed(1) : dv) + '', L + pw + 16, yy + 9);
    }
    g.fillStyle = '#64748b';
    g.textAlign = 'center';
    for (var mnt = 15; mnt >= 0; mnt -= 5) {
      var tx = x(now - mnt * 60);
      g.fillText(mnt ? '-' + mnt + ' min' : 'now', tx, H - 12);
    }

    var n = series.t.length;
    if (!n) return;
    var gapS = 5; // gap in the data => break the line

    // download: blue area
    g.fillStyle = 'rgba(59,130,246,0.35)';
    g.strokeStyle = '#3b82f6';
    g.lineWidth = 3;
    var open = false, startX = 0, prevX = 0;
    function closeArea() {
      g.lineTo(prevX, T + ph); g.lineTo(startX, T + ph); g.closePath(); g.fill();
    }
    g.beginPath();
    for (i = 0; i < n; i++) {
      var v = series.down[i];
      if (v === null || series.t[i] < t0) { if (open) { closeArea(); g.beginPath(); open = false; } continue; }
      var px = x(series.t[i]), py = yDown(v);
      if (open && series.t[i] - series.t[i - 1] > gapS) { closeArea(); g.beginPath(); open = false; }
      if (!open) { g.moveTo(px, T + ph); g.lineTo(px, py); startX = px; open = true; }
      else g.lineTo(px, py);
      prevX = px;
    }
    if (open) closeArea();

    // latency: white line
    g.strokeStyle = '#f8fafc';
    g.lineWidth = 3;
    g.beginPath();
    open = false;
    for (i = 0; i < n; i++) {
      var lv = series.lat[i];
      if (lv === null || series.t[i] < t0) { open = false; continue; }
      var lx = x(series.t[i]), ly = yLat(lv);
      if (!open || series.t[i] - series.t[i - 1] > gapS) g.moveTo(lx, ly);
      else g.lineTo(lx, ly);
      open = true;
    }
    g.stroke();
  }

  // ---------- startup ----------
  function start() {
    fit();
    window.onresize = fit;
    tickClock();
    pollNow(); pollHistory(); pollOutages();
    setInterval(pollNow, NOW_EVERY_MS);
    setInterval(pollHistory, HISTORY_EVERY_MS);
    setInterval(pollOutages, OUTAGES_EVERY_MS);
    setInterval(tickClock, 1000);
    setInterval(burnShift, SHIFT_EVERY_MS);
  }

  if (document.readyState === 'complete' || document.readyState === 'interactive') start();
  else document.addEventListener('DOMContentLoaded', start, false);
})();
