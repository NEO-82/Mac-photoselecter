import AppKit

final class PhotoCanvas: NSView {
    var decoded: DecodedImage? { didSet { needsDisplay = true } }
    var zoomChanged: ((Bool) -> Void)?
    var navigate: ((Int) -> Void)?
    var close: (() -> Void)?
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
        switch event.keyCode {
        case 123: resetZoom(); navigate?(-1)
        case 124: resetZoom(); navigate?(1)
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
    var didClose: (() -> Void)?
    private var deactivate: NSObjectProtocol?
    init() {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = ViewerWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init(window: window)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        canvas.frame = NSRect(origin: .zero, size: screen.size)
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas
        hud.textColor = .white; hud.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        hud.drawsBackground = true; hud.maximumNumberOfLines = 3
        hud.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 16),
            hud.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -16),
            hud.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 16)
        ])
        canvas.close = { [weak self] in self?.close() }
        deactivate = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.canvas.resetZoom() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let deactivate { NotificationCenter.default.removeObserver(deactivate) } }
    func present(on screen: NSScreen?) {
        if let screen { window?.setFrame(screen.frame, display: true) }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(canvas)
    }
    func windowWillClose(_ notification: Notification) { canvas.resetZoom(); didClose?() }
}
