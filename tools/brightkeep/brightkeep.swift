// brightkeep: remember built-in panel brightness across boots (PhxAMDFB starts at max).
// usage: brightkeep get | set <0..1> | daemon
import Foundation
import CoreGraphics
import IOKit

typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
guard h != nil, let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else {
    print("DisplayServices unavailable"); exit(1)
}
let getB = unsafeBitCast(g, to: GetFn.self), setB = unsafeBitCast(s, to: SetFn.self)

func panel() -> CGDirectDisplayID {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
    CGGetOnlineDisplayList(8, &ids, &n)
    return ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
}
func get() -> Float? { var v: Float = -1; return getB(panel(), &v) == 0 && v >= 0 ? v : nil }
let store = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences/local.brightkeep.txt")
// seconds since last keyboard/mouse/trackpad input
func hidIdle() -> Double {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &it) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(it) }
    let e = IOIteratorNext(it); defer { IOObjectRelease(e) }
    guard e != 0, let v = IORegistryEntryCreateCFProperty(e, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return 0 }
    return v.doubleValue / 1e9
}
// current "turn display off after" in seconds (0 = never), from pmset (follows the active power source)
func displaySleepSecs() -> Double {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g"]
    let pipe = Pipe(); p.standardOutput = pipe
    guard (try? p.run()) != nil else { return 0 }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    for line in out.split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        if f.count >= 2, f[0] == "displaysleep", let m = Double(f[1]) { return m * 60 }
    }
    return 0
}
func log(_ m: String) { FileHandle.standardError.write("\(Date()) \(m)\n".data(using: .utf8)!) }

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "get": print(get().map { String($0) } ?? "error")
case "set": print(setB(panel(), Float(a[2]) ?? 0.5))
case "daemon":
    let saved = (try? String(contentsOf: store, encoding: .utf8)).flatMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    log("start, saved=\(saved.map { String($0) } ?? "none")")
    // GPU bring-up (phxboot) re-arms the panel after login and resets it to max: re-apply a few times over ~3 min
    var last = saved
    if let v = saved {
        var elapsed = 0
        for t in [5, 20, 45, 90, 180] {
            Thread.sleep(forTimeInterval: TimeInterval(t - elapsed)); elapsed = t
            if let cur = get(), abs(cur - v) > 0.02 { log("t=\(t)s cur=\(cur) -> \(v): \(setB(panel(), v))") }
        }
    }
    // backlight stays lit when macOS turns the display off: drop brightness to 0 after the display-sleep timeout,
    // put it back on the first input
    var blanked: Float? = nil
    var tick = 0, ds = 0.0
    while true {
        if tick % 30 == 0 { ds = displaySleepSecs() }
        let idle = hidIdle()
        if blanked == nil, ds > 0, idle >= ds, let cur = get(), cur > 0.001 {
            blanked = cur; log("idle \(Int(idle))s: backlight off (was \(cur)) \(setB(panel(), 0))")
        } else if let v = blanked, idle < ds {
            log("input: backlight \(v) \(setB(panel(), v))"); blanked = nil
        }
        if blanked == nil, tick % 30 == 0, let cur = get(), last == nil || abs(cur - last!) > 0.005 {
            try? String(cur).write(to: store, atomically: true, encoding: .utf8); last = cur
        }
        tick += 1
        Thread.sleep(forTimeInterval: 1)
    }
default: print("usage: brightkeep get | set <0..1> | daemon")
}
