// powerbar: menu-bar readout of battery charge/discharge power and CPU package power.
// Battery: AppleSmartBattery InstantAmperage (mA, negative = discharging) x Voltage (mV).
// CPU: AMDRyzenCPUPowerManagement user client selector 4 (first float = package watts).
// CPU mode: writes the choice to /Users/Shared/cppc/mode ("auto" or "epp <0-255>"); the root service cppcd applies it
// through PhxCPPC.kext (AMD CPPC energy-performance preference) and reports in /Users/Shared/cppc/status.
// GPU clock cap: /Users/Shared/cppc/gpu ("auto" or MHz), applied by cppcd too (SMU SetSoftMaxGfxClk); status in gpu-status.
// External monitor: /Users/Shared/hdmi/state ("<brightness> <max> <volume> <max>", written by the root service hdmid
// while a monitor answers DDC/CI) shows brightness and volume sliders; choices go to /Users/Shared/hdmi/brightness|volume.
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
struct Sample { let t: Double; let pct: Int; let wh: Double; let w: Double; let ext: Bool }
struct Session { var start: Double, end: Double; var ext: Bool; var active: Double; var pct0: Int, pct1: Int; var wh0: Double, wh1: Double; var wsum: Double; var n: Int
    var avgW: Double { n > 0 ? wsum / Double(n) : 0 } }
final class History {
    var samples: [Sample] = []
    let path: String
    var accW = 0.0, accN = 0, lastWrite = 0.0, lastExt: Bool? = nil
    init() {
        let dir = NSHomeDirectory() + "/Library/Application Support/powerbar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/history.csv"
        let cut = Date().timeIntervalSince1970 - 60 * 86400
        for line in ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n") {
            let f = line.split(separator: ",")
            if f.count >= 5, let t = Double(f[0]), t > cut, let p = Int(f[1]), let wh = Double(f[2]), let w = Double(f[3]) { samples.append(Sample(t: t, pct: p, wh: wh, w: w, ext: f[4] == "1")) }
        }
        // rewrite without the lines that fell out of the window
        try? samples.map { "\(Int($0.t)),\($0.pct),\(String(format: "%.2f", $0.wh)),\(String(format: "%.2f", $0.w)),\($0.ext ? 1 : 0)" }.joined(separator: "\n").appending(samples.isEmpty ? "" : "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
    // called every tick with the current reading; writes a sample once a minute, and at once when the power source changes
    func add(pct: Int, wh: Double?, w: Double, ext: Bool) {
        accW += w; accN += 1
        let now = Date().timeIntervalSince1970
        guard now - lastWrite >= 60 || (lastExt != nil && lastExt != ext) else { return }
        let smp = Sample(t: now, pct: pct, wh: wh ?? 0, w: accW / Double(accN), ext: ext)
        accW = 0; accN = 0; lastWrite = now; lastExt = ext
        samples.append(smp)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write("\(Int(smp.t)),\(smp.pct),\(String(format: "%.2f", smp.wh)),\(String(format: "%.2f", smp.w)),\(smp.ext ? 1 : 0)\n".data(using: .utf8)!)
            h.closeFile()
        } else { try? "".write(toFile: path, atomically: true, encoding: .utf8) }
    }
    // a gap of more than five minutes between samples is sleep or power-off: it splits nothing but adds no awake time
    func sessions() -> [Session] {
        var out: [Session] = []
        var prev: Sample? = nil
        for s in samples {
            if out.isEmpty || out[out.count - 1].ext != s.ext {
                out.append(Session(start: s.t, end: s.t, ext: s.ext, active: 0, pct0: s.pct, pct1: s.pct, wh0: s.wh, wh1: s.wh, wsum: 0, n: 0))
            } else if let p = prev, s.t - p.t <= 300 { out[out.count - 1].active += s.t - p.t }
            out[out.count - 1].end = s.t; out[out.count - 1].pct1 = s.pct; out[out.count - 1].wh1 = s.wh
            if abs(s.w) < 150 { out[out.count - 1].wsum += s.w; out[out.count - 1].n += 1 }
            prev = s
        }
        return out
    }
    // The usual power on battery (positive watts) or while charging, over the last 14 days: samples between the 10th and
    // the 90th percentile only, so a stuck gauge, a sample taken across a wake or a short burst do not move it.
    func typicalWatts(charging: Bool) -> (watts: Double, minutes: Int)? {
        let cut = Date().timeIntervalSince1970 - 14 * 86400
        var v = samples.filter { $0.t > cut && $0.ext == charging && abs($0.w) < 150 && (charging ? $0.w > 1 : $0.w < -1) }.map { abs($0.w) }
        guard v.count >= 30 else { return nil }
        v.sort()
        let lo = v.count / 10, hi = v.count - v.count / 10
        let mid = v[lo..<hi]
        return (mid.reduce(0, +) / Double(mid.count), v.count)
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
        for s in samples where now - s.t <= span {
            if let p = prev, s.t - p.t <= 300 {
                (s.ext ? NSColor.systemGreen : NSColor.labelColor).setStroke()
                let path = NSBezierPath(); path.move(to: pt(p)); path.line(to: pt(s)); path.lineWidth = 1.6; path.lineCapStyle = .round; path.stroke()
            }
            prev = s
        }
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
    @objc func showRecords() {
        let all = history.sessions().reversed().filter { $0.active >= 60 }.prefix(80)
        let text = all.isEmpty ? L("还没有记录", "No records yet") : all.map { describe($0, long: true) }.joined(separator: "\n")
        let w = recordsWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L("充放电记录（时长为机器实际运行的时间，不含休眠）", "Charge and discharge records (time the machine was awake)")
        w.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: w.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let tv = NSTextView(frame: scroll.bounds); tv.isEditable = false; tv.autoresizingMask = [.width]
        tv.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular); tv.textContainerInset = NSSize(width: 10, height: 10); tv.string = text
        scroll.documentView = tv; w.contentView = scroll
        recordsWindow = w; w.center(); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
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
    let extSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    let volSlider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    let extValue = label(size: 12, mono: true), volValue = label(size: 12, mono: true)
    var extRow: NSView!, volRow: NSView!
    var extSent = [Date.distantPast, Date.distantPast], extSet = [Date.distantPast, Date.distantPast]
    var extTimer: [Timer?] = [nil, nil]

    // options
    let lidSwitch = NSSwitch()
    let lidLabel = label(size: 12)
    let langButton = NSButton(title: "", target: nil, action: nil), quitButton = NSButton(title: "", target: nil, action: nil)

    var cards: [Card] = []
    var extCard: Card!
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

    // ---- external monitor: brightness (0) and volume (1) ----
    func extSend(_ which: Int, _ v: Int) {
        // follow the drag: a value goes out at once, at most one every 0.12 s (a DDC/CI write takes about that long),
        // and the one the slider settles on always does
        extSet[which] = Date()
        extTimer[which]?.invalidate()
        let file = extDir + (which == 0 ? "/brightness" : "/volume")
        let send = { self.writeLine(file, "\(v)"); self.extSent[which] = Date() }
        let since = Date().timeIntervalSince(extSent[which])
        if since >= 0.12 { send() }
        else {
            let t = Timer(timeInterval: 0.12 - since, repeats: false) { _ in send() }
            RunLoop.main.add(t, forMode: .common); extTimer[which] = t
        }
    }
    @objc func extSlid(_ s: NSSlider) { let v = Int(s.doubleValue.rounded()); extValue.stringValue = "\(v)%"; extSend(0, v) }
    @objc func volSlid(_ s: NSSlider) { let v = Int(s.doubleValue.rounded()); volValue.stringValue = "\(v)%"; extSend(1, v) }
    func refreshExt() {
        let st = readLine(extDir + "/state").split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        let hasB = st.count >= 2 && st[1] > 0, hasV = st.count >= 4 && st[3] > 0
        let was = extCard.isHidden
        extCard.isHidden = !(hasB || hasV); extRow.isHidden = !hasB; volRow.isHidden = !hasV
        if hasB, Date().timeIntervalSince(extSet[0]) > 5 { let p = Int((Double(st[0]) * 100 / Double(st[1])).rounded()); extSlider.doubleValue = Double(p); extValue.stringValue = "\(p)%" }
        if hasV, Date().timeIntervalSince(extSet[1]) > 5 { let p = Int((Double(st[2]) * 100 / Double(st[3])).rounded()); volSlider.doubleValue = Double(p); volValue.stringValue = "\(p)%" }
        if was != extCard.isHidden { resize() }
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
            else { if abs(v - saved) > 0.02 { _ = set(d, saved) }; panelLevel = saved; return }
        }
        panelLevel = v
        if abs(v - savedLevel) > 0.005 { savedLevel = v; UserDefaults.standard.set(v, forKey: "panel-level") }
    }
    var savedLevel: Float = UserDefaults.standard.float(forKey: "panel-level")
    lazy var bootLevel: Float? = (ProcessInfo.processInfo.systemUptime < 240 && savedLevel > 0.004) ? savedLevel : nil

    // ---- language, layout ----
    @objc func toggleLanguage() {
        english.toggle(); UserDefaults.standard.set(english, forKey: "english")
        extSet = [Date.distantPast, Date.distantPast]
        relabel(); tick(); resize()
    }
    @objc func quit() { NSApp.terminate(nil) }
    func relabel() {
        let caps = [L("电源", "POWER"), L("电量记录 · 近 12 小时", "CHARGE HISTORY · LAST 12 HOURS"), L("处理器", "PROCESSOR"), L("核显", "GRAPHICS"), L("外接显示器", "EXTERNAL DISPLAY"), L("选项", "OPTIONS")]
        axisL.stringValue = L("12 小时前", "12 h ago"); axisM.stringValue = L("绿色 = 接电", "green = on AC"); axisR.stringValue = L("现在", "now")
        recordsButton.title = L("查看全部记录…", "All records…")
        for (i, c) in cards.enumerated() { c.caption.stringValue = caps[i] }
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
        extRow = sliderRow("sun.max", extSlider, extValue, #selector(extSlid(_:)))
        volRow = sliderRow("speaker.wave.2", volSlider, volValue, #selector(volSlid(_:)))
        extCard = Card([extRow, volRow]); extCard.isHidden = true
        // options card
        lidSwitch.controlSize = .mini; lidSwitch.target = self; lidSwitch.action = #selector(toggleLid(_:))
        for b in [langButton, quitButton] { b.bezelStyle = .rounded; b.controlSize = .small; b.target = self }
        langButton.action = #selector(toggleLanguage); quitButton.action = #selector(quit)
        let opts = Card([hstack([lidLabel, spacer(), lidSwitch]), hstack([langButton, spacer(), quitButton])])
        recordsButton.bezelStyle = .rounded; recordsButton.controlSize = .small; recordsButton.target = self; recordsButton.action = #selector(showRecords)
        let axis = hstack([axisL, spacer(), axisM, spacer(), axisR])
        let hist = Card([chart, axis, sessionLine, historyLine, hstack([spacer(), recordsButton])])
        hist.stack.setCustomSpacing(2, after: chart)
        cards = [power, hist, proc, gfx, extCard, opts]

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
    delegate.extCard.isHidden = false; delegate.extRow.isHidden = false; delegate.volRow.isHidden = false
    delegate.extValue.stringValue = "40%"; delegate.volValue.stringValue = "65%"; delegate.extSlider.doubleValue = 40; delegate.volSlider.doubleValue = 65
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
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
