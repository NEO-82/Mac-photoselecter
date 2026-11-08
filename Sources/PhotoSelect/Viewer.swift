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
    init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = ViewerWindow(contentRect: screen, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        super.init(window: window)
        window.setFrame(screen, display: false)
        window.title = AppBranding.displayName
        window.minSize = NSSize(width: 640, height: 480)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.delegate = self
        canvas.frame = NSRect(origin: .zero, size: screen.size)
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let deactivate { NotificationCenter.default.removeObserver(deactivate) } }
    func present(on screen: NSScreen?) {
        if let screen { window?.setFrame(screen.visibleFrame, display: true) }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(canvas)
    }
    func windowWillClose(_ notification: Notification) { canvas.resetZoom(); didClose?() }
}
