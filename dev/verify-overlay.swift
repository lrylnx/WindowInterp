// Real WindowServer regression: move/resize the source, then observe across two 5s refresh ticks.
// Run only after other live checks finish. The fixture owns every window/process it closes.
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else { fatalError("usage: verify-overlay <WindowInterp.app>") }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let source = NSWindow(contentRect: NSRect(x: 60, y: 70, width: 480, height: 300),
                      styleMask: .borderless, backing: .buffered, defer: false)
source.isReleasedWhenClosed = false
source.ignoresMouseEvents = true
source.backgroundColor = .systemTeal
source.orderFrontRegardless()
let output = FileManager.default.temporaryDirectory.appendingPathComponent("wi-overlay-\(UUID().uuidString).log")
let launch = Process()
launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
launch.arguments = ["-n", "--stdout", output.path, "--stderr", output.path, args[1], "--args",
                    "--in-process", "--off", "--autostart", "--mode", "window",
                    "--window-id", String(source.windowNumber), "--no-space-switch",
                    "--test-pause", "3", "--test-seconds", "24"]
try launch.run()
// In-process diagnostic exec is not reliably exposed by bundle-ID lookup.
// Read the launched instance's PID from its private output, never another user's instance.
var childPID: Int32?
var samples = 0
var mismatches = 0
var missing = 0
var moved = false
let start = Date()

func rect(_ info: [String: Any]) -> CGRect? {
    guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: bounds)
}
let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
    let elapsed = Date().timeIntervalSince(start)
    if childPID == nil, let text = try? String(contentsOf: output, encoding: .utf8) {
        for line in text.split(separator: "\n") where line.hasPrefix("WI_EVENT ") {
            if let data = String(line.dropFirst(9)).data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               event["event"] as? String == "testProcess", let pid = event["pid"] as? Int32 { childPID = pid }
        }
    }
    if elapsed > 6, !moved {
        moved = true
        source.setFrame(NSRect(x: 170, y: 160, width: 560, height: 340), display: true)
    }
    if elapsed > 9, elapsed < 21 {
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let sourceRect = windows.first { ($0[kCGWindowNumber as String] as? Int) == source.windowNumber }.flatMap(rect)
        // The click-through overlay is floating; the controller is normal, HUD only 42pt tall.
        let overlay = windows.first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == childPID
                && ($0[kCGWindowLayer as String] as? Int) == Int(NSWindow.Level.floating.rawValue)
                && (rect($0)?.height ?? 0) > 200
        }.flatMap(rect)
        if let sourceRect, let overlay {
            samples += 1
            if abs(sourceRect.minX - overlay.minX) > 1 || abs(sourceRect.minY - overlay.minY) > 1
                || abs(sourceRect.width - overlay.width) > 1 || abs(sourceRect.height - overlay.height) > 1 {
                mismatches += 1
                print("MISMATCH t=\(elapsed) source=\(sourceRect) overlay=\(overlay)")
            }
        } else {
            if missing == 0 {
                print("MISSING child=\(childPID ?? -1) source=\(String(describing: sourceRect))")
                for info in windows where (info[kCGWindowOwnerPID as String] as? Int32) == childPID {
                    print("CHILD_WINDOW layer=\(info[kCGWindowLayer as String] ?? -1) bounds=\(String(describing: rect(info)))")
                }
            }
            missing += 1
        }
    }
    if elapsed >= 21 {
        if let childPID { kill(childPID, SIGTERM) }
        try? FileManager.default.removeItem(at: output)
        source.orderOut(nil)
        let passed = samples > 100 && mismatches == 0 && missing == 0
        print("\(passed ? "PASS" : "FAIL") real overlay follow: samples=\(samples), staleBounds=\(mismatches), missing=\(missing)")
        exit(passed ? 0 : 1)
    }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
