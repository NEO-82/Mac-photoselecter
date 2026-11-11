import AppKit

enum AppBranding {
    static let displayName = "정광이의 MAC 포토셀렉터"
}

// Semantic colors resolve for the view's effective appearance, including live theme changes.
enum ProTheme {
    private static func color(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static let background = color(0x202329, 0xF4F3F4)
    static let panel = color(0x2D3037, 0xECEBED)
    static let canvas = color(0x292C32, 0xFAF9FA)
    static let selection = color(0x614650, 0xE9D3DA)
    static let accent = color(0xD4A0AC, 0x95586B)
    static let text = color(0xF3F3F4, 0x252831)
    static let secondary = color(0xB9BBC3, 0x666974)
}

class ProSurfaceView: NSView {
    var fillColor: NSColor = ProTheme.panel { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

enum AppMenus {
    static func make(for browser: BrowserController) -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        let app = submenu(AppBranding.displayName)
        add(app, AppBranding.displayName + " 정보", #selector(AppDelegate.showAbout(_:)), target: NSApp.delegate as AnyObject?)
        app.addItem(.separator())
        add(app, AppBranding.displayName + " 가리기", #selector(NSApplication.hide(_:)), key: "h")
        add(app, "기타 가리기", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
        add(app, "모두 보기", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, AppBranding.displayName + " 종료", #selector(NSApplication.terminate(_:)), key: "q")

        let file = submenu("파일")
        add(file, "폴더 열기…", #selector(BrowserController.openFolder), key: "o", target: browser)
        add(file, "상위 폴더", #selector(BrowserController.parentFolder), key: "\u{f700}", target: browser)
        add(file, "새로고침", #selector(BrowserController.refreshFolder), key: "r", target: browser)
        file.addItem(.separator())
        add(file, "창 닫기", #selector(NSWindow.performClose(_:)), key: "w")

        let view = submenu("보기")
        add(view, "선택 사진 크게 보기", #selector(BrowserController.openSelectedPhoto), key: "\r", modifiers: [], target: browser)
        add(view, "숨김 파일 표시", #selector(BrowserController.toggleHiddenFiles(_:)), key: ".", modifiers: [.command, .shift], target: browser)
        for (title, tag) in [("시스템 테마", 0), ("라이트 모드", 1), ("다크 모드", 2)] {
            let item = NSMenuItem(title: title, action: #selector(BrowserController.changeAppearance(_:)), keyEquivalent: "")
            item.target = browser; item.tag = tag; view.addItem(item)
        }
        let photo = submenu("사진")
        add(photo, "이전 사진", #selector(BrowserController.previousPhoto), target: browser)
        add(photo, "다음 사진", #selector(BrowserController.nextPhoto), target: browser)
        photo.addItem(.separator())
        add(photo, "태그 지정/해제", #selector(BrowserController.toggleTagFromMenu), key: "\\", modifiers: [], target: browser)
        add(photo, "휴지통으로 이동", #selector(BrowserController.trashFromMenu), key: "\u{8}", modifiers: [], target: browser)

        let window = submenu("윈도우")
        add(window, "최소화", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(window, "확대/축소", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "모두 앞으로 가져오기", #selector(NSApplication.arrangeInFront(_:)))
        return main
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: "Made with love ♡", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    private var browser: BrowserController?
    private var terminationPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedTheme = UserDefaults.standard.object(forKey: "appearancePreference") as? Int ?? 2
        NSApp.appearance = savedTheme == 0 ? nil : NSAppearance(named: savedTheme == 1 ? .aqua : .darkAqua)
        let browser = BrowserController(); self.browser = browser
        NSApp.mainMenu = AppMenus.make(for: browser)
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "윈도우")?.submenu
        browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let browser else { return .terminateNow }
        if !terminationPending {
            terminationPending = true
            browser.finishPendingTagWrites { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
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
