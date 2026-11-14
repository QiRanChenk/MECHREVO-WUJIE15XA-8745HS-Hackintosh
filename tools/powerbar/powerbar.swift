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
    var battAvg: Double? = nil      // battery watts averaged over about a minute: the estimate should not jump
    var pendingWrite: Timer? = nil
    var pendingMode: String? = nil  // chosen but not yet reported back by the service
    var cpuAvg: Double? = nil
    // CPU mode (CPPC energy-performance preference): presets, a stepless slider, and what the service applied
    let modeDir = "/Users/Shared/cppc"
    let presets: [(String, String)] = [("自动（插电均衡 · 电池省电）", "auto"), ("高性能", "epp 0"), ("均衡", "epp 128"),
                                       ("省电", "epp 192"), ("极致省电", "epp 255")]
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
    @objc func pickPreset(_ s: NSMenuItem) { setMode(presets[s.tag].1) }
    @objc func slid(_ s: NSSlider) {
        let v = Int(s.doubleValue.rounded())
        sliderLabel.stringValue = "性能 ← \(v) → 省电"
        // a drag sends a value for every step: write only the one it settles on (0.3 s without another)
        pendingWrite?.invalidate()
        let t = Timer(timeInterval: 0.3, repeats: false) { _ in self.setMode("epp \(v)") }
        RunLoop.main.add(t, forMode: .common); pendingWrite = t
    }
    func refreshMode() {
        let m = currentMode()
        for (i, it) in modeItems.enumerated() { it.state = presets[i].1 == m ? .on : .off }
        let st = ((try? String(contentsOfFile: modeDir + "/status", encoding: .utf8)) ?? "").split(separator: " ").map(String.init)
        if st.count >= 3, let epp = Int(st[1]) {
            // the service takes up to a second to apply a choice: until its report matches, say so instead of showing
            // the old value, and leave the slider where the user put it
            let want = m.hasPrefix("epp ") ? Int(m.dropFirst(4)) : nil
            let applied = (want == nil && st[0] == "auto") || (want != nil && st[0] == "epp" && want == epp)
            if applied { pendingMode = nil }
            let src = st[2] == "ac" ? "插电" : "电池"
            if pendingMode != nil && !applied { modeLine.title = "CPU 模式：正在应用…" }
            else { modeLine.title = "CPU 模式：EPP \(epp)（\(st[0] == "auto" ? "自动" : "手动") · \(src)）" }
            if pendingWrite?.isValid != true && pendingMode == nil { slider.doubleValue = Double(epp); sliderLabel.stringValue = "性能 ← \(epp) → 省电" }
        } else { modeLine.title = "CPU 模式：服务未运行" }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.addItem(detail); menu.addItem(timeLine); menu.addItem(cpuLine); menu.addItem(.separator())
        menu.addItem(modeLine)
        for (i, p) in presets.enumerated() {
            let it = NSMenuItem(title: p.0, action: #selector(pickPreset(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; modeItems.append(it); menu.addItem(it)
        }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 46))
        sliderLabel.frame = NSRect(x: 20, y: 26, width: 220, height: 16)
        sliderLabel.font = NSFont.menuFont(ofSize: 11); sliderLabel.textColor = .secondaryLabelColor; sliderLabel.alignment = .center
        slider.frame = NSRect(x: 20, y: 4, width: 220, height: 22)
        slider.target = self; slider.action = #selector(slid(_:)); slider.isContinuous = true
        box.addSubview(sliderLabel); box.addSubview(slider)
        let sl = NSMenuItem(); sl.view = box; menu.addItem(sl)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 powerbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        tick()
        // .common: the lines keep updating while the menu is open
        let t = Timer(timeInterval: 2, repeats: true) { _ in self.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    func tick() {
        var title = "—"
        if let b = batteryInfo() {
            let w = b.watts
            if abs(w) < 0.05 { title = b.external ? "⚡︎0W" : "0W" }
            else if w > 0 { title = String(format: "⚡︎+%.1fW", w) }
            else { title = String(format: "%.1fW", w) }
            let state = w > 0.05 ? "充电" : (w < -0.05 ? "放电" : "未充放电")
            detail.title = String(format: "电池 %@ %.1f W · %d%% · %@", state, abs(w), b.percent, b.external ? "已接电源" : "电池供电")
            // a new direction (plugged in / unplugged) starts the average again
            if let a = battAvg, (a > 0) == (w > 0) { battAvg = a * 0.93 + w * 0.07 } else { battAvg = w }
            func hm(_ h: Double) -> String { let m = Int((h * 60).rounded()); return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(m) 分钟" }
            let avg = battAvg ?? w
            if avg < -0.3, let left = b.whLeft { timeLine.title = "预计还能用 " + hm(left / -avg) + String(format: "（剩 %.0f Wh · 平均 %.1f W）", left, -avg) }
            else if avg > 0.3, let left = b.whLeft, let full = b.whFull, full > left { timeLine.title = "预计 " + hm((full - left) / avg) + " 后充满" }
            else if let m = b.minutes { timeLine.title = (b.external ? "预计充满还需 " : "预计还能用 ") + hm(Double(m) / 60) }
            else { timeLine.title = b.external ? "已接电源" : "预计时间：计算中" }
        } else { detail.title = "读不到电池"; timeLine.title = "" }
        if let c = cpu.read() {
            cpuAvg = cpuAvg.map { $0 * 0.6 + c.watts * 0.4 } ?? c.watts
            cpuLine.title = String(format: "CPU+核显 %.1f W · %.0f°C", cpuAvg!, c.temp)
        } else { cpuLine.title = "读不到 CPU 功耗" }
        item.button?.title = title
        refreshMode()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
