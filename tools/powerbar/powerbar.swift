// powerbar: menu-bar readout of battery charge/discharge power and CPU package power.
// Battery: AppleSmartBattery InstantAmperage (mA, negative = discharging) x Voltage (mV).
// CPU: AMDRyzenCPUPowerManagement user client selector 4 (first float = package watts).
import Cocoa
import IOKit

func batteryInfo() -> (watts: Double, percent: Int, external: Bool)? {
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
    return (Double(a) * Double(v) / 1_000_000.0, pct, ext)
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
    var cpuAvg: Double? = nil

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.addItem(detail); menu.addItem(cpuLine); menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 powerbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        tick()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.tick() }
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
        } else { detail.title = "读不到电池" }
        if let c = cpu.read() {
            cpuAvg = cpuAvg.map { $0 * 0.6 + c.watts * 0.4 } ?? c.watts
            cpuLine.title = String(format: "CPU+核显 %.1f W · %.0f°C", cpuAvg!, c.temp)
        } else { cpuLine.title = "读不到 CPU 功耗" }
        item.button?.title = title
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
