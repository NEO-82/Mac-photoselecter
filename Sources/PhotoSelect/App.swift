import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var browser: BrowserController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "PhotoSelect", action: nil, keyEquivalent: ""); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "PhotoSelect 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = main
        browser = BrowserController(); browser?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoSelectApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
