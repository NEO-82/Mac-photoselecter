import AppKit

enum PhotoEditingAction { case trash, toggleTag }

enum PhotoShortcuts {
    static func editingAction(_ event: NSEvent) -> PhotoEditingAction? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return nil }
        if [51, 117].contains(event.keyCode), !event.modifierFlags.contains(.option) { return .trash }
        if event.charactersIgnoringModifiers == "\\" ||
            (event.keyCode == 42 && !event.modifierFlags.contains(.shift)) { return .toggleTag }
        return nil
    }
}

final class TagMarkerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("태그됨")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill(); bounds.fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PhotoCanvas: NSView {
    var decoded: DecodedImage? { didSet { needsDisplay = true } }
    var zoomChanged: ((Bool) -> Void)?
    var navigate: ((Int) -> Void)?
    var close: (() -> Void)?
    var trashCurrent: (() -> Void)?
    var toggleTag: (() -> Void)?
    private var pressed = false
    private var cursor = CGPoint.zero
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let decoded, let context = NSGraphicsContext.current?.cgContext else { return }
        let image = decoded.image
        // A preview is displayed at the original pixel geometry, but explicitly marked in the HUD.
        let size = decoded.sourceSize.width > 0 && decoded.sourceSize.height > 0 ? decoded.sourceSize : CGSize(width: image.width, height: image.height)
        let rect: CGRect
        if pressed {
            rect = ZoomGeometry.rect(image: size, view: bounds.size, cursor: cursor,
                                     backingScale: window?.backingScaleFactor ?? 1)
        } else {
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            rect = CGRect(x: (bounds.width - size.width * scale) / 2,
                          y: (bounds.height - size.height * scale) / 2,
                          width: size.width * scale, height: size.height * scale)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }
    override func mouseDown(with event: NSEvent) {
        // The second press closes before it can request another full decode.
        if event.clickCount == 2 { resetZoom(); close?(); return }
        pressed = true; cursor = convert(event.locationInWindow, from: nil)
        zoomChanged?(true); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { resetZoom() }
    func resetZoom() { pressed = false; zoomChanged?(false); needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if let action = PhotoShortcuts.editingAction(event) {
            if !event.isARepeat {
                switch action {
                case .trash: trashCurrent?()
                case .toggleTag: toggleTag?()
                }
            }
            return
        }
        switch event.keyCode {
        case 123: navigate?(-1)
        case 124: navigate?(1)
        case 53: resetZoom(); close?()
        default: super.keyDown(with: event)
        }
    }
}

final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ViewerController: NSWindowController, NSWindowDelegate {
    let canvas = PhotoCanvas()
    let hud = NSTextField(labelWithString: "")
    let tagMarker = TagMarkerView()
    var didClose: (() -> Void)?
    private var deactivate: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = WindowLayout.minimumSize(in: screen, kind: .viewer)
        window.maxSize = screen.size
        window.setFrame(WindowLayout.initialFrame(in: screen, kind: .viewer), display: false)
        window.title = AppBranding.displayName
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.delegate = self
        canvas.frame = NSRect(origin: .zero, size: window.contentView?.bounds.size ?? window.contentLayoutRect.size)
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas
        hud.textColor = .white; hud.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        hud.drawsBackground = true; hud.maximumNumberOfLines = 5
        hud.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(hud)
        tagMarker.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(tagMarker)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 16),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: tagMarker.leadingAnchor, constant: -12),
            hud.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 16),
            tagMarker.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -16),
            tagMarker.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 16),
            tagMarker.widthAnchor.constraint(equalToConstant: 12),
            tagMarker.heightAnchor.constraint(equalToConstant: 12)
        ])
        canvas.close = { [weak self] in self?.close() }
        deactivate = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.canvas.resetZoom() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.fitToCurrentScreen() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let deactivate { NotificationCenter.default.removeObserver(deactivate) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
    func present(on screen: NSScreen?) {
        if let screen = screen ?? window?.screen ?? NSScreen.main, let window {
            let initial = !window.isVisible || window.screen?.frame != screen.frame
            fit(to: screen, initial: initial)
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(canvas)
    }
    private func fit(to screen: NSScreen, initial: Bool = false) {
        guard let window else { return }
        window.minSize = WindowLayout.minimumSize(in: screen.visibleFrame, kind: .viewer)
        window.maxSize = screen.visibleFrame.size
        let frame = initial ? WindowLayout.initialFrame(in: screen.visibleFrame, kind: .viewer) :
            WindowLayout.fittedFrame(window.frame, in: screen.visibleFrame, kind: .viewer)
        if frame != window.frame { window.setFrame(frame, display: true) }
        canvas.needsDisplay = true
    }
    private func fitToCurrentScreen() {
        if let screen = window?.screen ?? NSScreen.main { fit(to: screen) }
    }
    func windowDidChangeScreen(_ notification: Notification) { fitToCurrentScreen() }
    func windowDidChangeBackingProperties(_ notification: Notification) { fitToCurrentScreen() }
    func windowWillClose(_ notification: Notification) { canvas.resetZoom(); didClose?() }
}
