// powerbar: menu-bar readout of battery charge/discharge power and CPU package power.
// Battery: AppleSmartBattery InstantAmperage (mA, negative = discharging) x Voltage (mV).
// CPU: AMDRyzenCPUPowerManagement user client selector 4 (first float = package watts).
// CPU mode: writes the choice to /Users/Shared/cppc/mode ("auto" or "epp <0-255>"); the root service cppcd applies it
// through PhxCPPC.kext (AMD CPPC energy-performance preference) and reports in /Users/Shared/cppc/status.
// GPU clock cap: /Users/Shared/cppc/gpu ("auto" or MHz), applied by cppcd too (SMU SetSoftMaxGfxClk); status in gpu-status.
// External monitor: /Users/Shared/hdmi/state ("<brightness> <max> <volume> <max>", written by the root service hdmid
// while a monitor answers DDC/CI) shows brightness and volume sliders; choices go to /Users/Shared/hdmi/brightness|volume.
// With a monitor on each port (HDMI and USB-C) the USB-C one has the same files with the suffix -dp, and a card of its own.
// The menu is one panel (a single view in the status item's menu): a readout card and a card per group of controls.
import Cocoa
import IOKit

func batteryInfo() -> (watts: Double, percent: Int, external: Bool, whLeft: Double?, whFull: Double?, minutes: Int?)? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    func num(_ k: String) -> Int64? {
        (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.int64Value
    }
    guard let v = num("Voltage") else { return nil }
    // InstantAmperage is stored as an unsigned 64-bit two's complement value
    let a = num("InstantAmperage") ?? num("Amperage") ?? 0
    let ext = (IORegistryEntryCreateCFProperty(svc, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    let cur = Double(num("CurrentCapacity") ?? 0), mx = Double(num("MaxCapacity") ?? 0)
    let pct = mx > 100 ? Int((cur / mx * 100).rounded()) : Int(cur)
    // energy left and at full charge from the raw mAh counters; the battery's own estimate (minutes) as a fallback
    var whLeft: Double? = nil, whFull: Double? = nil
    if let rc = num("AppleRawCurrentCapacity"), let rm = num("AppleRawMaxCapacity"), rm > 100 {
        whLeft = Double(rc) * Double(v) / 1_000_000.0; whFull = Double(rm) * Double(v) / 1_000_000.0
    }
    let t = num(ext ? "AvgTimeToFull" : "AvgTimeToEmpty") ?? num("TimeRemaining")
    let mins = (t != nil && t! > 0 && t! < 6000) ? Int(t!) : nil
    return (Double(a) * Double(v) / 1_000_000.0, pct, ext, whLeft, whFull, mins)
}

// UI language: Chinese or English, chosen in the menu (kept in the user defaults); the system language decides at first.
var english: Bool = {
    if let v = UserDefaults.standard.object(forKey: "english") as? Bool { return v }
    return !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
}()
func L(_ zh: String, _ en: String) -> String { english ? en : zh }

final class CPUPower {
    var conn: io_connect_t = 0
    init() {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AMDRyzenCPUPowerManagement"))
        if s != 0 { IOServiceOpen(s, mach_task_self_, 0, &conn); IOObjectRelease(s) }
    }
    func read() -> (watts: Double, temp: Double)? {
        guard conn != 0 else { return nil }
        var out = [Float](repeating: 0, count: 67)
        var size = out.count * MemoryLayout<Float>.size
        var scalar = [UInt64](repeating: 0, count: 1)
        var scalarCount: UInt32 = 1
        let kr = IOConnectCallMethod(conn, 4, nil, 0, nil, 0, &scalar, &scalarCount, &out, &size)
        return kr == KERN_SUCCESS ? (Double(out[0]), Double(out[1])) : nil
    }
}


// ---- permission prompts ---------------------------------------------------------------------------------------------
// With AMFI off (which the GPU driver needs: its Metal plugin is loaded into WindowServer and every app) tccd never
// shows a permission dialog: it logs "Policy disallows prompt" and denies. This watches tccd's log for those lines,
// asks the question itself for camera and microphone, and on "Allow" writes the grant into the user's TCC database
// (what System Settings would do; needs SIP off, as the driver does). One question per app and service per run; a
// refusal is remembered in the user defaults until "Reset" in a later prompt... it is simply not asked again.
final class TCCPrompter {
    let services: [String: (zh: String, en: String)] = ["kTCCServiceCamera": ("摄像头", "the camera"), "kTCCServiceMicrophone": ("麦克风", "the microphone")]
    var asked = Set<String>()
    var proc: Process?
    func start() {
        // a previous powerbar that was killed leaves its log stream behind
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-f", "log stream --style compact --predicate process == \"tccd\""]
        try? k.run(); k.waitUntilExit()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", "process == \"tccd\" AND eventMessage CONTAINS \"Policy disallows prompt\""]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        var rest = ""
        pipe.fileHandleForReading.readabilityHandler = { h in
            guard let chunk = String(data: h.availableData, encoding: .utf8), !chunk.isEmpty else { return }
            rest += chunk
            while let nl = rest.firstIndex(of: "\n") { let line = String(rest[..<nl]); rest = String(rest[rest.index(after: nl)...]); self.handle(line) }
        }
        try? p.run(); proc = p
    }
    func field(_ line: String, _ key: String, until: String) -> String? {
        guard let r = line.range(of: key) else { return nil }
        let tail = line[r.upperBound...]
        return String(tail[..<(tail.range(of: until)?.lowerBound ?? tail.endIndex)])
    }
    func handle(_ line: String) {
        // ... Resp:{TCCDProcess: identifier=com.x.y, pid=.., binary_path=/Applications/X.app/Contents/MacOS/X}; access to kTCCServiceCamera denied
        guard let resp = line.range(of: "Resp:{") else { return }
        let r = String(line[resp.upperBound...])
        guard let ident = field(r, "identifier=", until: ","), let bin = field(r, "binary_path=", until: "}"),
              let svc = field(line, "access to ", until: " denied"), let name = services[svc],
              !ident.hasPrefix("com.apple."), let appEnd = bin.range(of: ".app/") else { return }
        let app = String(bin[..<appEnd.lowerBound]) + ".app"
        let key = svc + " " + ident
        if asked.contains(key) || UserDefaults.standard.bool(forKey: "tcc-refused " + key) { return }
        asked.insert(key)
        DispatchQueue.main.async {
            let a = NSAlert()
            let title = FileManager.default.displayName(atPath: app)
            a.messageText = L("“\(title)”想使用\(name.zh)", "“\(title)” would like to use \(name.en)")
            a.informativeText = L("系统的权限弹窗在这台机器上不会出现（核显驱动需要关闭 AMFI）。选择“允许”后由 powerbar 写入授权；之后请退出并重新打开该程序，授权才会生效。",
                                  "The system's own permission dialog does not appear on this machine (the GPU driver needs AMFI off). “Allow” lets powerbar write the grant; quit and reopen the app afterwards for it to take effect.")
            a.addButton(withTitle: L("允许", "Allow")); a.addButton(withTitle: L("不允许", "Don't Allow"))
            a.icon = NSWorkspace.shared.icon(forFile: app)
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { self.grant(app, ident, svc) }
            else { UserDefaults.standard.set(true, forKey: "tcc-refused " + key) }
        }
    }
    func grant(_ app: String, _ ident: String, _ svc: String) {
        let script = """
        set -e
        DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
        REQ=$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'); [ -n "$REQ" ]
        T=$(mktemp); echo "$REQ" | csreq -r- -b "$T"; HEX=$(xxd -p "$T" | tr -d '\n'); rm -f "$T"
        sqlite3 "$DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags) VALUES ('$3', '$2', 0, 2, 3, 1, X'$HEX', 0);"
        killall tccd 2>/dev/null || true
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", script, "grant", app, ident, svc]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let a = NSAlert(); a.messageText = L("写入授权失败", "The grant could not be written")
            a.informativeText = L("程序没有可用的代码签名要求，或权限数据库不可写。", "The app has no usable code-signing requirement, or the permission database is not writable."); a.runModal()
        }
    }
}

// ---- energy history ----------------------------------------------------------------------------------------------
// One sample a minute (time, charge %, Wh left, average watts, on AC) in ~/Library/Application Support/powerbar/
// history.csv, 60 days kept. From it: sessions (the stretch between two changes of the power source, with the time the
// machine was actually awake in it), the chart of the last 12 hours, and the usual discharge power for the estimate.
struct Sample { let t: Double; let pct: Int; let wh: Double; let w: Double; let ext: Bool
    var brk: Bool = false }      // brk: the machine slept or was off before this sample (no awake time, no line to it)
struct Session { var start: Double, end: Double; var ext: Bool; var active: Double; var pct0: Int, pct1: Int; var wh0: Double, wh1: Double; var wsum: Double; var n: Int
    var avgW: Double { n > 0 ? wsum / Double(n) : 0 } }
final class History {
    static let interval = 300.0        // one sample every five minutes: 288 a day, about 0.5 MB for the 60 days kept
    static let gap = 750.0             // samples further apart than this count as a break even without the flag
    var samples: [Sample] = []
    let path: String
    var accW = 0.0, accN = 0, lastWrite = 0.0, lastExt: Bool? = nil
    var pendingBreak = true            // the first sample after a start or a wake carries the break flag
    var last: (pct: Int, wh: Double?, ext: Bool)? = nil
    private var typCache: [Bool: (count: Int, value: (watts: Double, minutes: Int)?)] = [:]
    static func line(_ s: Sample) -> String { "\(Int(s.t)),\(s.pct),\(String(format: "%.2f", s.wh)),\(String(format: "%.2f", s.w)),\(s.ext ? 1 : 0),\(s.brk ? 1 : 0)\n" }
    init() {
        let dir = NSHomeDirectory() + "/Library/Application Support/powerbar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/history.csv"
        let cut = Date().timeIntervalSince1970 - 60 * 86400
        // Read, drop what is older than 60 days, and thin what was written more often than the interval (files from
        // the one-a-minute version): a sample stays when the power source changes, after a break, or once the interval
        // has passed since the last one kept; its power is the mean of the ones it stands for.
        var prevT = 0.0, sumW = 0.0, cnt = 0, lines = 0
        for line in ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n") {
            lines += 1
            let f = line.split(separator: ",")
            guard f.count >= 5, let t = Double(f[0]), t > cut, t > prevT, let p = Int(f[1]), let wh = Double(f[2]), let w = Double(f[3]) else { continue }
            let ext = f[4] == "1", brk = (f.count >= 6 && f[5] == "1") || (prevT > 0 && t - prevT > History.gap) || samples.isEmpty
            prevT = t; sumW += w; cnt += 1
            if let k = samples.last, !brk, k.ext == ext, t - k.t < History.interval - 10 { continue }
            samples.append(Sample(t: t, pct: p, wh: wh, w: sumW / Double(cnt), ext: ext, brk: brk)); sumW = 0; cnt = 0
        }
        // a restart of powerbar itself is no break: the flag only when the last sample is old
        if let l = samples.last, Date().timeIntervalSince1970 - l.t <= History.gap { pendingBreak = false; lastWrite = l.t; lastExt = l.ext }
        if lines != samples.count || lines == 0 {
            try? samples.map { History.line($0) }.joined().write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    // first index with t >= the given time (samples are in time order)
    func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < t { lo = m + 1 } else { hi = m } }
        return lo
    }
    func slice(from: Double, to: Double) -> ArraySlice<Sample> { let a = lowerBound(from); return samples[a..<max(a, lowerBound(to.nextUp))] }
    // called every tick with the current reading; writes a sample every five minutes, and at once when the power source
    // changes or when forced (going to sleep)
    func add(pct: Int, wh: Double?, w: Double, ext: Bool, force: Bool = false) {
        accW += w; accN += 1; last = (pct, wh, ext)
        let now = Date().timeIntervalSince1970
        guard force || pendingBreak || now - lastWrite >= History.interval || (lastExt != nil && lastExt != ext) else { return }
        if let l = samples.last, now <= l.t { return }
        let smp = Sample(t: now, pct: pct, wh: wh ?? 0, w: accW / Double(accN), ext: ext, brk: pendingBreak)
        accW = 0; accN = 0; lastWrite = now; lastExt = ext; pendingBreak = false
        samples.append(smp)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(History.line(smp).data(using: .utf8)!); h.closeFile()
        } else { try? History.line(smp).write(toFile: path, atomically: true, encoding: .utf8) }
    }
    func willSleep() { if let l = last, accN > 0 { add(pct: l.pct, wh: l.wh, w: accW / Double(accN), ext: l.ext, force: true) } }
    func didWake() { pendingBreak = true; accW = 0; accN = 0 }
    // a gap of more than five minutes between samples is sleep or power-off: it splits nothing but adds no awake time
    func sessions(from: Double = 0, to: Double = .infinity) -> [Session] {
        var out: [Session] = []
        var prev: Sample? = nil
        for s in slice(from: from, to: to) {
            if out.isEmpty || out[out.count - 1].ext != s.ext {
                out.append(Session(start: s.t, end: s.t, ext: s.ext, active: 0, pct0: s.pct, pct1: s.pct, wh0: s.wh, wh1: s.wh, wsum: 0, n: 0))
            } else if let p = prev, !s.brk, s.t - p.t <= History.gap { out[out.count - 1].active += s.t - p.t }
            out[out.count - 1].end = s.t; out[out.count - 1].pct1 = s.pct; out[out.count - 1].wh1 = s.wh
            if abs(s.w) < 150 { out[out.count - 1].wsum += s.w; out[out.count - 1].n += 1 }
            prev = s
        }
        return out
    }
    // The usual power on battery (positive watts) or while charging, over the last 14 days: samples between the 10th and
    // the 90th percentile only, so a stuck gauge, a sample taken across a wake or a short burst do not move it.
    // Worked out again only when a sample was added. Needs half an hour of samples (six).
    func typicalWatts(charging: Bool) -> (watts: Double, minutes: Int)? {
        if let c = typCache[charging], c.count == samples.count { return c.value }
        var v = samples[lowerBound(Date().timeIntervalSince1970 - 14 * 86400)...].filter { $0.ext == charging && abs($0.w) < 150 && (charging ? $0.w > 1 : $0.w < -1) }.map { abs($0.w) }
        var out: (watts: Double, minutes: Int)? = nil
        if v.count >= 6 {
            v.sort()
            let mid = v[(v.count / 10)..<(v.count - v.count / 10)]
            out = (mid.reduce(0, +) / Double(mid.count), v.count * Int(History.interval / 60))
        }
        typCache[charging] = (samples.count, out)
        return out
    }
}
// battery charge over the last 12 hours: green while on AC, the text colour on battery; breaks where the machine slept
final class HistoryChart: NSView {
    var samples: [Sample] = []
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 64) }
    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 3)
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        for f in [0.0, 0.5, 1.0] { let y = r.minY + r.height * f; let p = NSBezierPath(); p.move(to: NSPoint(x: r.minX, y: y)); p.line(to: NSPoint(x: r.maxX, y: y)); p.lineWidth = 1; p.stroke() }
        let now = Date().timeIntervalSince1970, span = 12.0 * 3600
        func pt(_ s: Sample) -> NSPoint { NSPoint(x: r.maxX - CGFloat((now - s.t) / span) * r.width, y: r.minY + CGFloat(s.pct) / 100 * r.height) }
        var prev: Sample? = nil
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < now - span { lo = m + 1 } else { hi = m } }
        for s in samples[lo...] {
            if let p = prev, !s.brk, s.t - p.t <= History.gap {
                (s.ext ? NSColor.systemGreen : NSColor.labelColor).setStroke()
                let path = NSBezierPath(); path.move(to: pt(p)); path.line(to: pt(s)); path.lineWidth = 1.6; path.lineCapStyle = .round; path.stroke()
            }
            prev = s
        }
    }
}

// The records window's chart: any stretch of the history. Upper pane = charge in percent (green on AC, text colour on
// battery, grey bands where the machine slept or was off), lower pane = power in watts (up = charging, down =
// discharging). Moving the pointer over it reports the sample under it.
final class RangeChart: NSView {
    var samples: [Sample] = []
    var t0 = 0.0, t1 = 1.0
    var onHover: ((String) -> Void)?
    private var hoverX: CGFloat? = nil
    private var area: NSTrackingArea?
    var plot: NSRect { NSRect(x: 44, y: 22, width: max(10, bounds.width - 56), height: max(10, bounds.height - 30)) }
    var pctRect: NSRect { let p = plot; return NSRect(x: p.minX, y: p.minY + p.height * 0.36, width: p.width, height: p.height * 0.64) }
    var wRect: NSRect { let p = plot; return NSRect(x: p.minX, y: p.minY, width: p.width, height: p.height * 0.28) }
    func x(_ t: Double) -> CGFloat { plot.minX + CGFloat((t - t0) / max(1, t1 - t0)) * plot.width }
    func visible() -> ArraySlice<Sample> {
        var lo = 0, hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < t0 { lo = m + 1 } else { hi = m } }
        let a = lo; hi = samples.count
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t <= t1 { lo = m + 1 } else { hi = m } }
        return samples[a..<lo]
    }
    override func updateTrackingAreas() {
        if let a = area { removeTrackingArea(a) }
        area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area!)
    }
    override func mouseMoved(with e: NSEvent) { hoverX = convert(e.locationInWindow, from: nil).x; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hoverX = nil; needsDisplay = true; onHover?("") }
    func text(_ s: String, at p: NSPoint, right: Bool = false, center: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let sz = (s as NSString).size(withAttributes: a)
        (s as NSString).draw(at: NSPoint(x: right ? p.x - sz.width : center ? p.x - sz.width / 2 : p.x, y: p.y - sz.height / 2), withAttributes: a)
    }
    func hline(_ y: CGFloat, _ r: NSRect, alpha: CGFloat = 0.12) {
        NSColor.labelColor.withAlphaComponent(alpha).setStroke()
        let p = NSBezierPath(); p.move(to: NSPoint(x: r.minX, y: y)); p.line(to: NSPoint(x: r.maxX, y: y)); p.lineWidth = 1; p.stroke()
    }
    override func draw(_ dirty: NSRect) {
        let pr = pctRect, wr = wRect, vis = visible(), span = max(1, t1 - t0)
        for f in [0, 25, 50, 75, 100] { let y = pr.minY + pr.height * CGFloat(f) / 100; hline(y, pr); text("\(f)%", at: NSPoint(x: pr.minX - 5, y: y), right: true) }
        var wmax = 10.0
        for s in vis where abs(s.w) < 150 { wmax = max(wmax, abs(s.w)) }
        wmax = (wmax / 10).rounded(.up) * 10
        let wy = wr.midY
        hline(wr.maxY, wr, alpha: 0.06); hline(wr.minY, wr, alpha: 0.06); hline(wy, wr, alpha: 0.2)
        text("+\(Int(wmax))W", at: NSPoint(x: wr.minX - 5, y: wr.maxY), right: true); text("0", at: NSPoint(x: wr.minX - 5, y: wy), right: true)
        text("−\(Int(wmax))W", at: NSPoint(x: wr.minX - 5, y: wr.minY), right: true)
        // time ticks on local-time boundaries
        let steps: [Double] = [600, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 432000, 864000]
        let step = steps.first { span / $0 <= 8 } ?? 1728000
        let off = Double(TimeZone.current.secondsFromGMT())
        let f = DateFormatter(); f.dateFormat = step >= 86400 ? "MM-dd" : span > 86400 ? "MM-dd HH:mm" : "HH:mm"
        var t = ((t0 + off) / step).rounded(.up) * step - off
        while t <= t1 {
            let xx = x(t)
            NSColor.labelColor.withAlphaComponent(0.07).setStroke()
            let p = NSBezierPath(); p.move(to: NSPoint(x: xx, y: wr.minY)); p.line(to: NSPoint(x: xx, y: pr.maxY)); p.lineWidth = 1; p.stroke()
            text(f.string(from: Date(timeIntervalSince1970: t)), at: NSPoint(x: min(max(xx, plot.minX + 14), plot.maxX - 14), y: 9), center: true)
            t += step
        }
        // the curves; points closer than 0.7 px to the last drawn one are skipped (60 days = 86 000 samples)
        func py(_ s: Sample) -> CGFloat { pr.minY + CGFloat(s.pct) / 100 * pr.height }
        // (everything of one colour goes into one path: two strokes and two fills for the whole chart)
        let lines = [NSBezierPath(), NSBezierPath()], bars = [NSBezierPath(), NSBezierPath()], gaps = NSBezierPath()
        var anchor: Sample? = nil, prev: Sample? = nil
        for s in vis {
            if let p = prev, s.brk || s.t - p.t > History.gap {
                gaps.appendRect(NSRect(x: x(p.t), y: pr.minY, width: x(s.t) - x(p.t), height: pr.height))
                anchor = nil
            }
            if let a = anchor {
                let xa = x(a.t), xs = x(s.t)
                if xs - xa >= 0.7 || s.ext != a.ext {
                    let k = s.ext ? 1 : 0
                    lines[k].move(to: NSPoint(x: xa, y: py(a))); lines[k].line(to: NSPoint(x: xs, y: py(s)))
                    if abs(s.w) < 150 {
                        let h = CGFloat(s.w / wmax) * wr.height / 2
                        bars[k].appendRect(NSRect(x: xa, y: min(wy, wy + h), width: max(1, xs - xa), height: abs(h)))
                    }
                    anchor = s
                }
            } else { anchor = s }
            prev = s
        }
        NSColor.labelColor.withAlphaComponent(0.05).setFill(); gaps.fill()
        for (k, c) in [NSColor.labelColor, NSColor.systemGreen].enumerated() {
            c.withAlphaComponent(0.55).setFill(); bars[k].fill()
            c.setStroke(); lines[k].lineWidth = 1.6; lines[k].lineCapStyle = .round; lines[k].lineJoinStyle = .round; lines[k].stroke()
        }
        if vis.isEmpty { text(L("这段时间没有记录", "No records in this range"), at: NSPoint(x: pr.midX, y: pr.midY), center: true) }
        // the sample under the pointer
        guard let hx = hoverX, hx >= plot.minX, hx <= plot.maxX, !vis.isEmpty else { return }
        let ht = t0 + Double((hx - plot.minX) / plot.width) * span
        var best = vis.first!
        var lo = vis.startIndex, hi = vis.endIndex
        while lo < hi { let m = (lo + hi) / 2; if samples[m].t < ht { lo = m + 1 } else { hi = m } }
        for i in [lo - 1, lo] where i >= vis.startIndex && i < vis.endIndex { if abs(samples[i].t - ht) < abs(best.t - ht) { best = samples[i] } }
        guard abs(best.t - ht) <= max(History.interval, span / Double(plot.width) * 6) else { onHover?(""); return }
        let bx = x(best.t)
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let p = NSBezierPath(); p.move(to: NSPoint(x: bx, y: wr.minY)); p.line(to: NSPoint(x: bx, y: pr.maxY)); p.lineWidth = 1; p.stroke()
        (best.ext ? NSColor.systemGreen : NSColor.labelColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: bx - 3.5, y: py(best) - 3.5, width: 7, height: 7)).fill()
        let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
        onHover?(df.string(from: Date(timeIntervalSince1970: best.t)) + " · \(best.pct)% · " + (best.ext ? L("接电", "on AC") : L("用电池", "on battery")) + String(format: " %+.1f W", best.w))
    }
}

// ---- small view helpers ------------------------------------------------------------------------------------------
func label(_ s: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    t.textColor = color; t.lineBreakMode = .byTruncatingTail
    t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return t
}
func symbol(_ name: String, size: CGFloat = 14) -> NSImageView {
    let v = NSImageView()
    if let i = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
        v.image = i.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium))
    }
    v.contentTintColor = .secondaryLabelColor
    v.widthAnchor.constraint(equalToConstant: size > 20 ? 36 : 22).isActive = true
    v.heightAnchor.constraint(equalToConstant: size + 6).isActive = true
    v.imageScaling = .scaleProportionallyDown
    return v
}
func spacer() -> NSView {      // takes the free width of a row, no height of its own
    let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal)
    let h = v.heightAnchor.constraint(equalToConstant: 1); h.priority = .defaultHigh; h.isActive = true
    return v
}
func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY; return s
}
// a rounded card with a caption above its content
final class Card: NSView {
    let stack = NSStackView()
    let caption = label(size: 11, weight: .semibold, color: .secondaryLabelColor)
    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 10
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setHuggingPriority(.required, for: .vertical)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])
        stack.addArrangedSubview(caption)
        for r in rows { stack.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    override var wantsUpdateLayer: Bool { true }
}

// One external monitor's card: brightness and volume sliders (DDC/CI through the hdmid service). suffix "" = the HDMI
// port (or the one shared head), "-dp" = the USB-C port when each port has its own head.
final class ExtMonitor: NSObject {
    static let dir = "/Users/Shared/hdmi"
    let suffix: String, port: String
    let bright = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    let volume = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    let brightValue = label(size: 12, mono: true), volumeValue = label(size: 12, mono: true)
    var brightRow: NSView!, volumeRow: NSView!, card: Card!
    var sent = [Date.distantPast, Date.distantPast], set = [Date.distantPast, Date.distantPast]
    var timer: [Timer?] = [nil, nil]
    init(suffix: String, port: String) {
        self.suffix = suffix; self.port = port
        super.init()
        func row(_ icon: String, _ s: NSSlider, _ value: NSTextField) -> NSView {
            s.target = self; s.action = #selector(slid(_:)); s.isContinuous = true; s.controlSize = .small
            value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return hstack([symbol(icon), s, value])
        }
        brightRow = row("sun.max", bright, brightValue); volumeRow = row("speaker.wave.2", volume, volumeValue)
        card = Card([brightRow, volumeRow]); card.isHidden = true
    }
    static func read(_ path: String) -> String { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    // follow the drag: a value goes out at once, at most one every 0.12 s (a DDC/CI write takes about that long), and
    // the one the slider settles on always does
    @objc func slid(_ s: NSSlider) {
        let which = s === bright ? 0 : 1, v = Int(s.doubleValue.rounded())
        (which == 0 ? brightValue : volumeValue).stringValue = "\(v)%"
        set[which] = Date(); timer[which]?.invalidate()
        let file = ExtMonitor.dir + (which == 0 ? "/brightness" : "/volume") + suffix
        let send = { try? "\(v)\n".write(toFile: file, atomically: true, encoding: .utf8); self.sent[which] = Date() }
        let since = Date().timeIntervalSince(sent[which])
        if since >= 0.12 { send() }
        else {
            let t = Timer(timeInterval: 0.12 - since, repeats: false) { _ in send() }
            RunLoop.main.add(t, forMode: .common); timer[which] = t
        }
    }
    // returns true when the card appeared or went
    func refresh() -> Bool {
        let st = ExtMonitor.read(ExtMonitor.dir + "/state" + suffix).split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        let hasB = st.count >= 2 && st[1] > 0, hasV = st.count >= 4 && st[3] > 0
        let was = card.isHidden
        card.isHidden = !(hasB || hasV); brightRow.isHidden = !hasB; volumeRow.isHidden = !hasV
        if hasB, Date().timeIntervalSince(set[0]) > 5 { let p = Int((Double(st[0]) * 100 / Double(st[1])).rounded()); bright.doubleValue = Double(p); brightValue.stringValue = "\(p)%" }
        if hasV, Date().timeIntervalSince(set[1]) > 5 { let p = Int((Double(st[2]) * 100 / Double(st[3])).rounded()); volume.doubleValue = Double(p); volumeValue.stringValue = "\(p)%" }
        let name = ExtMonitor.read(ExtMonitor.dir + "/name" + suffix)
        card.caption.stringValue = L("外接显示器", "EXTERNAL DISPLAY") + (name.isEmpty ? "" : " · " + name) + (suffix.isEmpty && name.isEmpty ? "" : " · " + port)
        return was != card.isHidden
    }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cpu = CPUPower()
    let tcc = TCCPrompter()
    let history = History()
    let chart = HistoryChart()
    let axisL = label(size: 10, color: .tertiaryLabelColor), axisM = label(size: 10, color: .tertiaryLabelColor), axisR = label(size: 10, color: .tertiaryLabelColor)
    let sessionLine = label(size: 12), historyLine = label(size: 12, color: .secondaryLabelColor)
    let recordsButton = NSButton(title: "", target: nil, action: nil)
    var recordsWindow: NSWindow?
    func hm(_ secs: Double) -> String { let m = Int((secs / 60).rounded()); return m >= 60 ? L("\(m / 60) 小时 \(m % 60) 分", "\(m / 60) h \(m % 60) min") : L("\(m) 分钟", "\(m) min") }
    func describe(_ s: Session, long: Bool) -> String {
        let f = DateFormatter(); f.dateFormat = long ? "MM-dd HH:mm" : "HH:mm"
        let kind = s.ext ? L("接电", "On AC   ") : L("电池", "Battery ")
        let w = abs(s.avgW) >= 0.05 ? String(format: L(" · 均 %.1f W", " · avg %.1f W"), abs(s.avgW)) : ""
        return "\(kind) \(f.string(from: Date(timeIntervalSince1970: s.start)))–\(f.string(from: Date(timeIntervalSince1970: s.end))) · " + hm(s.active) + " · \(s.pct0)% → \(s.pct1)%" + w
    }
    func refreshHistory(whLeft: Double?, whFull: Double?, external: Bool) {
        chart.samples = history.samples; chart.needsDisplay = true
        if recordsWindow?.isVisible == true { refreshRecords() }
        if let cur = history.sessions().last {
            sessionLine.stringValue = (cur.ext ? L("本次接电已 ", "On AC for ") : L("本次用电池已 ", "On battery for ")) + hm(cur.active) + " · \(cur.pct0)% → \(cur.pct1)%"
        } else { sessionLine.stringValue = L("还没有记录", "No records yet") }
        if !external, let t = history.typicalWatts(charging: false), let left = whLeft {
            historyLine.stringValue = L("按历史用量还能用约 ", "At the usual rate: about ") + hm(left / t.watts * 3600) + String(format: L("（%.1f W）", " (%.1f W)"), t.watts)
        } else if external, let t = history.typicalWatts(charging: true), let left = whLeft, let full = whFull, full - left > 0.5 {
            historyLine.stringValue = L("按历史充电速度约 ", "At the usual rate: about ") + hm((full - left) / t.watts * 3600) + L(" 充满", " to full") + String(format: L("（%.0f W）", " (%.0f W)"), t.watts)
        } else if external { historyLine.stringValue = L("已接电源", "On AC power") }
        else { historyLine.stringValue = L("历史记录不足，用电池满半小时后给出估计", "Estimate after half an hour on battery") }
    }
    // ---- the records window: a chart of any stretch of the history, a summary of it and its sessions ----------------
    let rangeSeg = NSSegmentedControl(labels: ["", "", "", "", "", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    let rangeSpans: [Double] = [6 * 3600, 86400, 3 * 86400, 7 * 86400, 30 * 86400]      // then "all" and "custom"
    let fromPicker = NSDatePicker(), toPicker = NSDatePicker()
    let rangeChart = RangeChart()
    let rangeSummary = label(size: 12), rangeHover = label(size: 12, color: .secondaryLabelColor, mono: true)
    let recordsText = NSTextView()
    var recordsCount = -1
    func buildRecords() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.minSize = NSSize(width: 640, height: 460)
        rangeSeg.target = self; rangeSeg.action = #selector(rangePicked); rangeSeg.selectedSegment = 1; rangeSeg.controlSize = .small
        for p in [fromPicker, toPicker] {
            p.datePickerStyle = .textFieldAndStepper; p.datePickerElements = [.yearMonthDay, .hourMinute]; p.controlSize = .small
            p.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular); p.target = self; p.action = #selector(rangeTyped)
        }
        rangeChart.onHover = { [weak self] s in self?.rangeHover.stringValue = s.isEmpty ? L("把指针移到曲线上查看某一刻的电量和功率", "Move the pointer over the chart for the reading at that moment") : s }
        rangeChart.onHover?("")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        recordsText.isEditable = false; recordsText.drawsBackground = false; recordsText.autoresizingMask = [.width]
        recordsText.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular); recordsText.textContainerInset = NSSize(width: 2, height: 4)
        scroll.documentView = recordsText
        let top = hstack([rangeSeg, spacer(), fromPicker, label("–", color: .secondaryLabelColor), toPicker])
        let stack = NSStackView(views: [top, rangeSummary, rangeChart, rangeHover, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(); root.addSubview(stack); w.contentView = root
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                                     rangeChart.heightAnchor.constraint(greaterThanOrEqualToConstant: 240), scroll.heightAnchor.constraint(equalToConstant: 150)])
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        rangeChart.setContentHuggingPriority(.init(1), for: .vertical)
        return w
    }
    @objc func rangePicked() { recordsCount = -1; refreshRecords() }
    @objc func rangeTyped() { rangeSeg.selectedSegment = 6; recordsCount = -1; refreshRecords() }
    func refreshRecords() {
        // called every tick while the window is open: work only when a sample was added or the range was changed
        guard let w = recordsWindow, recordsCount != history.samples.count else { return }
        recordsCount = history.samples.count
        w.title = L("充放电记录", "Charge and discharge records")
        let names = [L("6 小时", "6 h"), L("24 小时", "24 h"), L("3 天", "3 d"), L("7 天", "7 d"), L("30 天", "30 d"), L("全部", "All"), L("自选", "Custom")]
        for (i, n) in names.enumerated() { rangeSeg.setLabel(n, forSegment: i) }
        let now = Date().timeIntervalSince1970, i = rangeSeg.selectedSegment
        var t0 = now - 86400, t1 = now
        if i >= 0 && i < rangeSpans.count { t0 = now - rangeSpans[i] }
        else if i == 5 { t0 = min(history.samples.first?.t ?? now - 3600, now - 600) }
        else { t0 = fromPicker.dateValue.timeIntervalSince1970; t1 = toPicker.dateValue.timeIntervalSince1970; if t1 < t0 + 600 { t1 = t0 + 600 } }
        if i != 6 { fromPicker.dateValue = Date(timeIntervalSince1970: t0); toPicker.dateValue = Date(timeIntervalSince1970: t1) }
        rangeChart.samples = history.samples; rangeChart.t0 = t0; rangeChart.t1 = t1; rangeChart.needsDisplay = true
        let ses = history.sessions(from: t0, to: t1)
        var batt = 0.0, ac = 0.0, bw = 0.0, bn = 0, cw = 0.0, cn = 0
        for s in ses { if s.ext { ac += s.active; cw += s.wsum; cn += s.n } else { batt += s.active; bw += s.wsum; bn += s.n } }
        if let a = ses.first, let b = ses.last {
            let asleep = max(0, b.end - a.start - batt - ac)
            rangeSummary.stringValue = L("这段时间：用电池 ", "In this range: on battery ") + hm(batt) + (bn > 0 && batt >= 60 ? String(format: L("（均 %.1f W）", " (avg %.1f W)"), abs(bw / Double(bn))) : "")
                + L(" · 接电 ", " · on AC ") + hm(ac) + (cn > 0 && ac >= 60 ? String(format: L("（均 %.1f W）", " (avg %.1f W)"), abs(cw / Double(cn))) : "")
                + L(" · 休眠或关机 ", " · asleep or off ") + hm(asleep) + L("（灰色段）", " (grey bands)")
        } else { rangeSummary.stringValue = L("这段时间没有记录", "No records in this range") }
        let rows = ses.reversed().filter { $0.active >= 60 }.prefix(300)
        recordsText.string = rows.isEmpty ? L("没有满一分钟的充放电记录", "No session of a minute or more") : rows.map { describe($0, long: true) }.joined(separator: "\n")
        recordsText.textColor = .labelColor
    }
    @objc func showRecords() {
        if recordsWindow == nil { recordsWindow = buildRecords(); recordsWindow!.center() }
        recordsCount = -1; refreshRecords()
        NSApp.activate(ignoringOtherApps: true); recordsWindow!.makeKeyAndOrderFront(nil)
        item.menu?.cancelTracking()
    }
    let width: CGFloat = 340
    var lastWatts: Double = 0
    var battAvg: Double? = nil      // battery watts averaged over about a minute: the estimate should not jump
    var cpuAvg: Double? = nil
    let modeDir = "/Users/Shared/cppc", extDir = "/Users/Shared/hdmi"

    // readout
    let bigWatts = label(size: 28, weight: .semibold, mono: true)
    let battState = label(size: 12, color: .secondaryLabelColor)
    let battIcon = symbol("battery.75", size: 22)
    let timeLine = label(size: 12)
    let cpuLine = label(size: 12, color: .secondaryLabelColor, mono: true)

    // CPU mode (CPPC energy-performance preference): presets, a stepless slider, and what the service applied
    let presets: [(zh: String, en: String, mode: String)] = [
        ("自动", "Auto", "auto"), ("性能", "Perf", "epp 0"), ("均衡", "Balanced", "epp 128"), ("省电", "Saver", "epp 192"), ("极省", "Max", "epp 255")]
    let modeSeg = NSSegmentedControl(labels: ["", "", "", "", ""], trackingMode: .selectOne, target: nil, action: nil)
    let slider = NSSlider(value: 128, minValue: 0, maxValue: 255, target: nil, action: nil)
    let sliderLeft = label(size: 11, color: .secondaryLabelColor), sliderRight = label(size: 11, color: .secondaryLabelColor)
    let modeLine = label(size: 11, color: .secondaryLabelColor, mono: true)
    var pendingWrite: Timer? = nil
    var pendingMode: String? = nil  // chosen but not yet reported back by the service

    // GPU clock cap: automatic (800 MHz alone, 1600 with an external display) or a value from 800 to 2600 MHz in 100 MHz steps
    let gpuAuto = NSSwitch()
    let gpuAutoLabel = label(size: 12)
    let gpuSlider = NSSlider(value: 800, minValue: 800, maxValue: 2600, target: nil, action: nil)
    let gpuValue = label(size: 12, weight: .medium, mono: true)
    let gpuLine = label(size: 11, color: .secondaryLabelColor)
    var gpuWrite: Timer? = nil
    var gpuSetAt = Date.distantPast

    // the external monitor's own brightness and speaker volume (DDC/CI), applied by the root service hdmid
    let ext = [ExtMonitor(suffix: "", port: "HDMI"), ExtMonitor(suffix: "-dp", port: "USB-C")]

    // options
    let lidSwitch = NSSwitch()
    let lidLabel = label(size: 12)
    let langButton = NSButton(title: "", target: nil, action: nil), quitButton = NSButton(title: "", target: nil, action: nil)

    var cards: [Card] = []
    let panel = NSStackView()
    let panelItem = NSMenuItem()

    func readLine(_ path: String) -> String { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func writeLine(_ path: String, _ s: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (s + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // ---- CPU mode ----
    func currentMode() -> String { let m = readLine(modeDir + "/mode"); return m.isEmpty ? "auto" : m }
    func setMode(_ m: String) { writeLine(modeDir + "/mode", m); pendingMode = m; refreshMode() }
    @objc func pickPreset(_ s: NSSegmentedControl) { setMode(presets[s.selectedSegment].mode) }
    @objc func slid(_ s: NSSlider) {
        let v = Int(s.doubleValue.rounded())
        modeLine.stringValue = "EPP \(v)"
        // a drag sends a value for every step: write only the one it settles on (0.3 s without another)
        pendingWrite?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in self.setMode("epp \(v)") }
        RunLoop.main.add(t, forMode: .common); pendingWrite = t
    }
    func refreshMode() {
        let m = currentMode()
        modeSeg.selectedSegment = presets.firstIndex { $0.mode == m } ?? -1
        let st = readLine(modeDir + "/status").split(separator: " ").map(String.init)
        if st.count >= 3, let epp = Int(st[1]) {
            // the service takes up to a second to apply a choice: until its report matches, say so instead of showing
            // the old value, and leave the slider where the user put it
            let want = m.hasPrefix("epp ") ? Int(m.dropFirst(4)) : nil
            let applied = (want == nil && st[0] == "auto") || (want != nil && st[0] == "epp" && want == epp)
            if applied { pendingMode = nil }
            let src = st[2] == "ac" ? L("插电", "AC") : L("电池", "battery")
            let how = st[0] == "auto" ? L("自动", "auto") : L("手动", "manual")
            if pendingMode != nil && !applied { modeLine.stringValue = L("正在应用…", "applying…") }
            else if pendingWrite?.isValid != true { modeLine.stringValue = "EPP \(epp) · \(how) · \(src)" }
            if pendingWrite?.isValid != true && pendingMode == nil { slider.doubleValue = Double(epp) }
        } else { modeLine.stringValue = L("服务未运行", "service not running") }
    }

    // ---- GPU clock cap ----
    @objc func gpuAutoToggled(_ s: NSSwitch) { writeLine(modeDir + "/gpu", s.state == .on ? "auto" : "\(Int(gpuSlider.doubleValue))"); gpuSetAt = Date(); refreshGpu() }
    @objc func gpuSlid(_ s: NSSlider) {
        let v = Int((s.doubleValue / 100).rounded()) * 100
        s.doubleValue = Double(v); gpuValue.stringValue = "\(v) MHz"; gpuSetAt = Date()
        gpuAuto.state = .off
        gpuWrite?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in self.writeLine(self.modeDir + "/gpu", "\(v)") }
        RunLoop.main.add(t, forMode: .common); gpuWrite = t
    }
    func refreshGpu() {
        let want = readLine(modeDir + "/gpu")
        let auto = Int(want) == nil
        let st = readLine(modeDir + "/gpu-status").split(separator: " ").map(String.init)
        let cap = st.count >= 2 ? Int(st[1]) : nil
        if Date().timeIntervalSince(gpuSetAt) > 3 {      // not under the user's hand
            gpuAuto.state = auto ? .on : .off
            if let v = auto ? cap : Int(want) { gpuSlider.doubleValue = Double(v); gpuValue.stringValue = "\(v) MHz" }
        }
        if let c = cap { gpuLine.stringValue = L("当前上限 \(c) MHz · 越高越流畅，也越耗电", "Cap now \(c) MHz · higher is smoother and draws more") }
        else { gpuLine.stringValue = L("服务未运行", "service not running") }
    }

    func refreshExt() {
        var changed = false
        for e in ext { if e.refresh() { changed = true } }
        if changed { resize() }
    }

    // ---- lid ----
    func lidAwake() -> Bool { readLine(modeDir + "/lid") == "awake" }
    @objc func toggleLid(_ s: NSSwitch) { writeLine(modeDir + "/lid", s.state == .on ? "awake" : "sleep") }

    // The panel's brightness across the lid. Beside an external monitor the panel leaves the desktop while the lid is
    // closed; when it comes back corebrightnessd starts over at full brightness in its books (the slider) without
    // touching the panel, which the driver has put back at its old level. The level from before the lid closed is
    // set again through DisplayServices, so the slider and the panel agree.
    typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias DSSet = @convention(c) (UInt32, Float) -> Int32
    let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    var panelLevel: Float? = nil
    var lidWasClosed = false
    var restoreTries = 0
    func builtinDisplay() -> UInt32? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        guard CGGetOnlineDisplayList(8, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }
    func lidClosed() -> Bool {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        return (IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    }
    func trackPanel() {
        guard let ds = ds, let g = dlsym(ds, "DisplayServicesGetBrightness"), let p = dlsym(ds, "DisplayServicesSetBrightness") else { return }
        let get = unsafeBitCast(g, to: DSGet.self), set = unsafeBitCast(p, to: DSSet.self)
        if lidClosed() { lidWasClosed = true; restoreTries = 0; return }
        guard let d = builtinDisplay() else { return }          // not back on the desktop yet
        if lidWasClosed {
            if let want = panelLevel, restoreTries < 2 { _ = set(d, want); restoreTries += 1; return }
            lidWasClosed = false
        }
        var v: Float = 0
        guard get(d, &v) == 0, v > 0.004 else { return }
        // Across boots: PhxAMDFB starts the panel at full brightness and corebrightnessd keeps it there. The level in use
        // is kept in the user defaults and put back during the first minutes after a boot (the GPU bring-up re-arms the
        // panel after login and resets it once more). This was the separate brightkeep agent before.
        let up = ProcessInfo.processInfo.systemUptime
        if let saved = bootLevel {
            if up > 240 { bootLevel = nil }
            // only a reset to full brightness is undone: a level the user picks in these minutes stays (and is kept)
            else if v >= 0.99 && saved < 0.99 { _ = set(d, saved); panelLevel = saved; return }
            else if abs(v - saved) > 0.02 { bootLevel = nil }
        }
        panelLevel = v
        if abs(v - savedLevel) > 0.005 { savedLevel = v; UserDefaults.standard.set(v, forKey: "panel-level") }
    }
    var savedLevel: Float = UserDefaults.standard.float(forKey: "panel-level")
    lazy var bootLevel: Float? = (ProcessInfo.processInfo.systemUptime < 240 && savedLevel > 0.004) ? savedLevel : nil

    // ---- language, layout ----
    @objc func toggleLanguage() {
        english.toggle(); UserDefaults.standard.set(english, forKey: "english")
        for e in ext { e.set = [Date.distantPast, Date.distantPast] }
        relabel(); tick(); resize()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func relabel() {
        let caps = [L("电源", "POWER"), L("电量记录 · 近 12 小时", "CHARGE HISTORY · LAST 12 HOURS"), L("处理器", "PROCESSOR"), L("核显", "GRAPHICS"), "", "", L("选项", "OPTIONS")]
        axisL.stringValue = L("12 小时前", "12 h ago"); axisM.stringValue = L("绿色 = 接电", "green = on AC"); axisR.stringValue = L("现在", "now")
        recordsButton.title = L("记录曲线与明细…", "Chart and records…"); recordsCount = -1; refreshRecords()
        for (i, c) in cards.enumerated() where !caps[i].isEmpty { c.caption.stringValue = caps[i] }
        refreshExt()
        for (i, p) in presets.enumerated() { modeSeg.setLabel(L(p.zh, p.en), forSegment: i) }
        sliderLeft.stringValue = L("性能", "Performance"); sliderRight.stringValue = L("省电", "Saver")
        gpuAutoLabel.stringValue = L("自动（单屏 800 · 外接屏 1600 MHz）", "Automatic (800 MHz alone, 1600 with a display)")
        lidLabel.stringValue = L("合盖不休眠（继续运行）", "Keep running with the lid closed")
        langButton.title = english ? "中文" : "English"
        quitButton.title = L("退出 powerbar", "Quit powerbar")
    }
    func resize() {
        panel.layoutSubtreeIfNeeded()
        let h = panel.fittingSize.height
        panel.setFrameSize(NSSize(width: width, height: h))
        panelItem.view = panel
    }
    func menuWillOpen(_ menu: NSMenu) { tick(); resize() }

    func sliderRow(_ icon: String, _ s: NSSlider, _ value: NSTextField, _ action: Selector) -> NSView {
        s.target = self; s.action = action; s.isContinuous = true; s.controlSize = .small
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return hstack([symbol(icon), s, value])
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // power card
        let top = hstack([bigWatts, spacer(), battIcon])
        let power = Card([top, battState, timeLine, cpuLine])
        power.stack.setCustomSpacing(2, after: top); power.stack.setCustomSpacing(6, after: battState)
        // processor card
        modeSeg.target = self; modeSeg.action = #selector(pickPreset(_:)); modeSeg.segmentDistribution = .fillEqually; modeSeg.controlSize = .small
        slider.target = self; slider.action = #selector(slid(_:)); slider.isContinuous = true; slider.controlSize = .small
        sliderLeft.setContentHuggingPriority(.required, for: .horizontal); sliderRight.setContentHuggingPriority(.required, for: .horizontal)
        let proc = Card([modeSeg, hstack([sliderLeft, slider, sliderRight]), modeLine])
        // graphics card
        gpuAuto.controlSize = .mini; gpuAuto.target = self; gpuAuto.action = #selector(gpuAutoToggled(_:))
        gpuSlider.target = self; gpuSlider.action = #selector(gpuSlid(_:)); gpuSlider.isContinuous = true; gpuSlider.controlSize = .small
        gpuSlider.numberOfTickMarks = 19; gpuSlider.allowsTickMarkValuesOnly = true
        gpuValue.alignment = .right; gpuValue.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let gfx = Card([hstack([gpuAutoLabel, spacer(), gpuAuto]), hstack([symbol("speedometer"), gpuSlider, gpuValue]), gpuLine])
        // external display card
        // options card
        lidSwitch.controlSize = .mini; lidSwitch.target = self; lidSwitch.action = #selector(toggleLid(_:))
        for b in [langButton, quitButton] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        langButton.action = #selector(toggleLanguage); quitButton.action = #selector(quit)
        let opts = Card([hstack([lidLabel, spacer(), lidSwitch]), hstack([langButton, spacer(), quitButton])])
        recordsButton.bezelStyle = .rounded; recordsButton.controlSize = .small; recordsButton.target = self; recordsButton.action = #selector(showRecords)
        let axis = hstack([axisL, spacer(), axisM, spacer(), axisR])
        let hist = Card([chart, axis, sessionLine, historyLine, hstack([spacer(), recordsButton])])
        hist.stack.setCustomSpacing(2, after: chart)
        cards = [power, hist, proc, gfx, ext[0].card, ext[1].card, opts]

        panel.orientation = .vertical; panel.alignment = .leading; panel.spacing = 8
        panel.setHuggingPriority(.required, for: .vertical)
        panel.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for c in cards { panel.addArrangedSubview(c); c.widthAnchor.constraint(equalToConstant: width - 20).isActive = true }
        panel.widthAnchor.constraint(equalToConstant: width).isActive = true
        relabel()

        let menu = NSMenu(); menu.delegate = self
        menu.addItem(panelItem)
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        tick(); resize()
        tcc.start()
        // a sample on the way into sleep, and the next one after the wake marked as following a break
        let wsn = NSWorkspace.shared.notificationCenter
        wsn.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.history.willSleep() }
        wsn.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.history.didWake() }
        // .common: the panel keeps updating while the menu is open
        let t = Timer(timeInterval: 2, repeats: true) { _ in self.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    func tick() {
        var title = "—"
        if var b = batteryInfo() {
            // the gauge reports nonsense for a sample or two when the adapter is plugged or unplugged (-435 W seen):
            // nothing here moves more than 150 W, so such a sample keeps the previous reading
            if abs(b.watts) > 150 { b.watts = lastWatts } else { lastWatts = b.watts }
            let w = b.watts
            if abs(w) < 0.05 { title = b.external ? "⚡︎0W" : "0W" }
            else if w > 0 { title = String(format: "⚡︎+%.1fW", w) }
            else { title = String(format: "%.1fW", w) }
            bigWatts.stringValue = abs(w) < 0.05 ? "0.0 W" : String(format: "%+.1f W", w)
            bigWatts.textColor = w > 0.05 ? .systemGreen : (w < -0.05 ? .labelColor : .secondaryLabelColor)
            let state = w > 0.05 ? L("充电", "Charging") : (w < -0.05 ? L("放电", "Discharging") : L("未充放电", "Idle"))
            battState.stringValue = "\(state) · \(b.percent)% · " + (b.external ? L("已接电源", "on AC") : L("电池供电", "on battery"))
            let level = b.percent >= 88 ? "100" : b.percent >= 63 ? "75" : b.percent >= 38 ? "50" : b.percent >= 13 ? "25" : "0"
            let name = w > 0.05 || (b.external && b.percent >= 99) ? "battery.100.bolt" : "battery.\(level)"
            battIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .regular))
            // a new direction (plugged in / unplugged) starts the average again
            if let a = battAvg, (a > 0) == (w > 0) { battAvg = a * 0.93 + w * 0.07 } else { battAvg = w }
            func hm(_ h: Double) -> String { let m = Int((h * 60).rounded()); return m >= 60 ? L("\(m / 60) 小时 \(m % 60) 分", "\(m / 60) h \(m % 60) min") : L("\(m) 分钟", "\(m) min") }
            let avg = battAvg ?? w
            if avg < -0.3, let left = b.whLeft { timeLine.stringValue = L("预计还能用 ", "About ") + hm(left / -avg) + String(format: L(" · 剩 %.0f Wh · 均 %.1f W", " left · %.0f Wh · avg %.1f W"), left, -avg) }
            else if avg > 0.3, let left = b.whLeft, let full = b.whFull, full > left { timeLine.stringValue = L("预计 ", "Full in about ") + hm((full - left) / avg) + L(" 后充满", "") }
            else if let m = b.minutes { timeLine.stringValue = (b.external ? L("预计充满还需 ", "Full in about ") : L("预计还能用 ", "Time left: about ")) + hm(Double(m) / 60) }
            else { timeLine.stringValue = b.external ? L("已接电源", "On AC power") : L("预计时间：计算中", "Estimating time left…") }
            history.add(pct: b.percent, wh: b.whLeft, w: w, ext: b.external)
            refreshHistory(whLeft: b.whLeft, whFull: b.whFull, external: b.external)
        } else { bigWatts.stringValue = "—"; battState.stringValue = L("读不到电池", "No battery data"); timeLine.stringValue = "" }
        if let c = cpu.read() {
            cpuAvg = cpuAvg.map { $0 * 0.6 + c.watts * 0.4 } ?? c.watts
            cpuLine.stringValue = String(format: L("CPU + 核显 %.1f W · %.0f°C", "CPU + GPU %.1f W · %.0f°C"), cpuAvg!, c.temp)
        } else { cpuLine.stringValue = L("读不到 CPU 功耗", "No CPU power data") }
        item.button?.title = title
        refreshMode()
        refreshGpu()
        refreshExt()
        trackPanel()
        lidSwitch.state = lidAwake() ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = App()
// powerbar --snapshot <file.png> [dark]: draw the panel once into a picture (for looking at the layout), with sample
// values where this machine has none
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot" {
    app.appearance = NSAppearance(named: CommandLine.arguments.count > 3 ? .darkAqua : .aqua)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    for (i, e) in delegate.ext.enumerated() {
        e.card.isHidden = false; e.brightRow.isHidden = false; e.volumeRow.isHidden = false
        e.brightValue.stringValue = "40%"; e.volumeValue.stringValue = "65%"; e.bright.doubleValue = 40; e.volume.doubleValue = 65
        e.card.caption.stringValue = L("外接显示器", "EXTERNAL DISPLAY") + (i == 0 ? " · CS3421 · HDMI" : " · F27B23Q Pro · USB-C")
    }
    if delegate.modeLine.stringValue.count > 12 { delegate.modeLine.stringValue = "EPP 128 · " + L("自动", "auto") + " · " + L("插电", "AC"); delegate.modeSeg.selectedSegment = 0 }
    delegate.gpuValue.stringValue = "1600 MHz"; delegate.gpuSlider.doubleValue = 1600; delegate.gpuAuto.state = .on
    delegate.gpuLine.stringValue = L("当前上限 1600 MHz · 越高越流畅，也越耗电", "Cap now 1600 MHz · higher is smoother and draws more")
    if delegate.history.samples.count < 30 {      // a made-up day for the picture
        var smp: [Sample] = []; let now = Date().timeIntervalSince1970; var pct = 96.0
        for i in stride(from: 700, to: 0, by: -1) {
            let t = now - Double(i) * 60
            if i > 520 { pct -= 0.25 } else if i > 430 { continue } else if i > 330 { pct = min(100, pct + 0.6) } else { pct -= 0.2 }
            smp.append(Sample(t: t, pct: Int(pct), wh: pct * 0.99, w: i > 330 && i <= 430 ? 45 : -19, ext: i > 330 && i <= 430))
        }
        delegate.history.samples = smp
        delegate.refreshHistory(whLeft: 30, whFull: 99, external: false)
    }
    delegate.resize()
    let v = delegate.panel
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: v.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.backgroundColor = .windowBackgroundColor; win.contentView = v; win.appearance = app.appearance
    v.layoutSubtreeIfNeeded(); v.display()
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
// powerbar --snapshot-records <file.png> [dark] [segment]: the records window with three made-up days
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--snapshot-records" {
    app.appearance = NSAppearance(named: CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "dark" ? .darkAqua : .aqua)
    var smp: [Sample] = []; let now = Date().timeIntervalSince1970; var pct = 80.0
    let days = CommandLine.arguments.count > 5 ? Int(CommandLine.arguments[5]) ?? 3 : 3
    for i in stride(from: days * 1440, to: 0, by: -5) {
        let c = i % 700
        if c > 300 { pct = max(5, pct - 0.2) } else if c > 220 { continue } else { pct = min(100, pct + 0.5) }
        let ac = c <= 220
        smp.append(Sample(t: now - Double(i) * 60, pct: Int(pct), wh: pct * 0.99, w: ac ? (pct >= 100 ? 0 : 48 - pct * 0.3) : -14 - Double(i % 37) * 0.4, ext: ac))
    }
    delegate.history.samples = smp
    let w = delegate.buildRecords(); delegate.recordsWindow = w
    if CommandLine.arguments.count > 4, let n = Int(CommandLine.arguments[4]) { delegate.rangeSeg.selectedSegment = n }
    w.appearance = app.appearance; delegate.refreshRecords()
    let v = w.contentView!; v.layoutSubtreeIfNeeded(); v.display()
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    var t = Date(); for _ in 0..<20 { delegate.recordsCount = -1; delegate.refreshRecords() }
    let tq = Date().timeIntervalSince(t) / 20; t = Date()
    for _ in 0..<20 { delegate.rangeChart.cacheDisplay(in: delegate.rangeChart.bounds, to: rep) }
    print(String(format: "%d samples: summary and sessions %.2f ms, chart redraw %.2f ms", smp.count, tq * 1000, Date().timeIntervalSince(t) / 20 * 1000))
    exit(0)
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
