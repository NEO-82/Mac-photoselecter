import AppKit
import CoreGraphics

// Only the disposable hosted CI desktop may be reconfigured, never a user's Mac.
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
    fatalError("Display setup is restricted to GitHub Actions")
}
let display = CGMainDisplayID()
let modes = (CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode]) ?? []
let candidates = modes.filter { $0.width >= 1280 && $0.height >= 900 }
    .sorted { $0.width * $0.height < $1.width * $1.height }
print("CI display modes: " + modes.map { "\($0.width)x\($0.height)" }.joined(separator: ", "))
var configured = false
for mode in candidates {
    let status = CGDisplaySetDisplayMode(display, mode, nil)
    print("CI display \(mode.width)x\(mode.height): \(status.rawValue)")
    if status == .success { configured = true; break }
}
guard configured else { fatalError("A 1200x760 browser layout test needs a larger CI display") }
RunLoop.current.run(until: Date().addingTimeInterval(1))
let available = NSScreen.main?.visibleFrame.size ?? .zero
print("Configured CI visible area: \(available)")
guard available.width >= 1200 && available.height >= 792 else {
    fatalError("Configured CI visible area cannot contain the required browser frame")
}
