// powerbar: menu-bar readout of battery charge/discharge power and CPU package power.
// Battery: AppleSmartBattery InstantAmperage (mA, negative = discharging) x Voltage (mV).
// CPU: AMDRyzenCPUPowerManagement user client selector 4 (first float = package watts).
// CPU mode: writes the choice to /Users/Shared/cppc/mode ("auto" or "epp <0-255>"); the root service cppcd applies it
// through PhxCPPC.kext (AMD CPPC energy-performance preference) and reports in /Users/Shared/cppc/status.
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

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let cpu = CPUPower()
    let detail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let cpuLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let timeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var lastWatts: Double = 0
    var battAvg: Double? = nil      // battery watts averaged over about a minute: the estimate should not jump
    var pendingWrite: Timer? = nil
    var pendingMode: String? = nil  // chosen but not yet reported back by the service
    var cpuAvg: Double? = nil
    // CPU mode (CPPC energy-performance preference): presets, a stepless slider, and what the service applied
    let modeDir = "/Users/Shared/cppc"
    let presets: [(zh: String, en: String, mode: String)] = [
        ("自动（插电均衡 · 电池省电）", "Automatic (balanced on AC, saver on battery)", "auto"),
        ("高性能", "High performance", "epp 0"), ("均衡", "Balanced", "epp 128"),
        ("省电", "Power saver", "epp 192"), ("极致省电", "Maximum saver", "epp 255")]
    // closing the lid: sleep (hibernate) or keep running; applied by the root service (pmset disablesleep)
    let lidItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    func lidAwake() -> Bool {
        ((try? String(contentsOfFile: modeDir + "/lid", encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "awake"
    }
    @objc func toggleLid() {
        try? FileManager.default.createDirectory(atPath: modeDir, withIntermediateDirectories: true)
        try? ((lidAwake() ? "sleep" : "awake") + "\n").write(toFile: modeDir + "/lid", atomically: true, encoding: .utf8)
        lidItem.state = lidAwake() ? .on : .off
    }
    let langItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    func sliderText(_ v: Int) -> String { L("性能 ← \(v) → 省电", "Performance ← \(v) → Saver") }
    @objc func toggleLanguage() {
        english.toggle(); UserDefaults.standard.set(english, forKey: "english")
        relabel(); tick()
    }
    func relabel() {
        for (i, it) in modeItems.enumerated() { it.title = L(presets[i].zh, presets[i].en) }
        langItem.title = english ? "中文" : "English"
        lidItem.title = L("合盖不休眠（继续运行）", "Keep running with the lid closed")
        quitItem.title = L("退出 powerbar", "Quit powerbar")
    }
    var modeItems: [NSMenuItem] = []
    let modeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let slider = NSSlider(value: 128, minValue: 0, maxValue: 255, target: nil, action: nil)
    let sliderLabel = NSTextField(labelWithString: "")

    func currentMode() -> String {
        ((try? String(contentsOfFile: modeDir + "/mode", encoding: .utf8)) ?? "auto").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func setMode(_ m: String) {
        try? FileManager.default.createDirectory(atPath: modeDir, withIntermediateDirectories: true)
        try? (m + "\n").write(toFile: modeDir + "/mode", atomically: true, encoding: .utf8)
        pendingMode = m
        refreshMode()
    }
    @objc func pickPreset(_ s: NSMenuItem) { setMode(presets[s.tag].mode) }
    @objc func slid(_ s: NSSlider) {
        let v = Int(s.doubleValue.rounded())
        sliderLabel.stringValue = sliderText(v)
        // a drag sends a value for every step: write only the one it settles on (0.3 s without another)
        pendingWrite?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in self.setMode("epp \(v)") }
        RunLoop.main.add(t, forMode: .common); pendingWrite = t
    }
    func refreshMode() {
        let m = currentMode()
        for (i, it) in modeItems.enumerated() { it.state = presets[i].mode == m ? .on : .off }
        let st = ((try? String(contentsOfFile: modeDir + "/status", encoding: .utf8)) ?? "").split(separator: " ").map(String.init)
        if st.count >= 3, let epp = Int(st[1]) {
            // the service takes up to a second to apply a choice: until its report matches, say so instead of showing
            // the old value, and leave the slider where the user put it
            let want = m.hasPrefix("epp ") ? Int(m.dropFirst(4)) : nil
            let applied = (want == nil && st[0] == "auto") || (want != nil && st[0] == "epp" && want == epp)
            if applied { pendingMode = nil }
            let src = st[2] == "ac" ? L("插电", "AC") : L("电池", "battery")
            let how = st[0] == "auto" ? L("自动", "auto") : L("手动", "manual")
            if pendingMode != nil && !applied { modeLine.title = L("CPU 模式：正在应用…", "CPU mode: applying…") }
            else { modeLine.title = L("CPU 模式：EPP \(epp)（\(how) · \(src)）", "CPU mode: EPP \(epp) (\(how), \(src))") }
            if pendingWrite?.isValid != true && pendingMode == nil { slider.doubleValue = Double(epp); sliderLabel.stringValue = sliderText(epp) }
        } else { modeLine.title = L("CPU 模式：服务未运行", "CPU mode: service not running") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.addItem(detail); menu.addItem(timeLine); menu.addItem(cpuLine); menu.addItem(.separator())
        menu.addItem(modeLine)
        for (i, p) in presets.enumerated() {
            let it = NSMenuItem(title: L(p.zh, p.en), action: #selector(pickPreset(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; modeItems.append(it); menu.addItem(it)
        }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 46))
        sliderLabel.frame = NSRect(x: 20, y: 26, width: 290, height: 16)
        sliderLabel.font = NSFont.menuFont(ofSize: 11); sliderLabel.textColor = .secondaryLabelColor; sliderLabel.alignment = .center
        slider.frame = NSRect(x: 20, y: 4, width: 290, height: 22)
        slider.target = self; slider.action = #selector(slid(_:)); slider.isContinuous = true
        box.addSubview(sliderLabel); box.addSubview(slider)
        let sl = NSMenuItem(); sl.view = box; menu.addItem(sl)
        menu.addItem(.separator())
        lidItem.target = self; lidItem.action = #selector(toggleLid); lidItem.state = lidAwake() ? .on : .off
        menu.addItem(lidItem); menu.addItem(.separator())
        langItem.target = self; langItem.action = #selector(toggleLanguage)
        menu.addItem(langItem); menu.addItem(quitItem)
        relabel()
        // one width for every state: the lines change length (a status line while a choice is applied, the estimate),
        // and the menu must not resize under the pointer while the slider is dragged
        menu.minimumWidth = 330
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        tick()
        // .common: the lines keep updating while the menu is open
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
            let state = w > 0.05 ? L("充电", "charging") : (w < -0.05 ? L("放电", "discharging") : L("未充放电", "idle"))
            detail.title = String(format: L("电池 %@ %.1f W · %d%% · %@", "Battery %@ %.1f W · %d%% · %@"), state, abs(w), b.percent,
                                  b.external ? L("已接电源", "on AC") : L("电池供电", "on battery"))
            // a new direction (plugged in / unplugged) starts the average again
            if let a = battAvg, (a > 0) == (w > 0) { battAvg = a * 0.93 + w * 0.07 } else { battAvg = w }
            func hm(_ h: Double) -> String { let m = Int((h * 60).rounded()); return m >= 60 ? L("\(m / 60) 小时 \(m % 60) 分", "\(m / 60) h \(m % 60) min") : L("\(m) 分钟", "\(m) min") }
            let avg = battAvg ?? w
            if avg < -0.3, let left = b.whLeft { timeLine.title = L("预计还能用 ", "About ") + hm(left / -avg) + String(format: L(" · 剩 %.0f Wh · 均 %.1f W", " left · %.0f Wh · avg %.1f W"), left, -avg) }
            else if avg > 0.3, let left = b.whLeft, let full = b.whFull, full > left { timeLine.title = L("预计 ", "Full in about ") + hm((full - left) / avg) + L(" 后充满", "") }
            else if let m = b.minutes { timeLine.title = (b.external ? L("预计充满还需 ", "Full in about ") : L("预计还能用 ", "Time left: about ")) + hm(Double(m) / 60) }
            else { timeLine.title = b.external ? L("已接电源", "On AC power") : L("预计时间：计算中", "Estimating time left…") }
        } else { detail.title = L("读不到电池", "No battery data"); timeLine.title = "" }
        if let c = cpu.read() {
            cpuAvg = cpuAvg.map { $0 * 0.6 + c.watts * 0.4 } ?? c.watts
            cpuLine.title = String(format: L("CPU+核显 %.1f W · %.0f°C", "CPU + GPU %.1f W · %.0f°C"), cpuAvg!, c.temp)
        } else { cpuLine.title = L("读不到 CPU 功耗", "No CPU power data") }
        item.button?.title = title
        refreshMode()
        lidItem.state = lidAwake() ? .on : .off
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
