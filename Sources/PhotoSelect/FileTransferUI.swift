import AppKit

enum FileClipboard {
    static func read(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    @discardableResult static func write(_ urls: [URL], to board: NSPasteboard = .general) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        board.clearContents()
        return board.writeObjects(urls.map { $0 as NSURL })
    }
}

/// Finder owns external copies. Advertise only copy, for both local and external
/// sessions, including modifier keys. Never perform a source deletion on drag end.
final class CopyDragSource: NSObject, NSDraggingSource {
    static let shared = CopyDragSource()
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

final class CopyProgressController: NSWindowController {
    private let label = NSTextField(labelWithString: "복사 준비 중…")
    private let progress = NSProgressIndicator()
    private let button = NSButton(title: "취소", target: nil, action: nil)
    private let cancellation: FileCopyCancellation
    init(destination: URL, cancellation: FileCopyCancellation) {
        self.cancellation = cancellation
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "복사 → " + destination.path
        super.init(window: panel)
        let content = panel.contentView!
        let target = NSTextField(wrappingLabelWithString: "대상: " + destination.path + "\n원본을 유지합니다. 같은 이름은 건너뜁니다.")
        target.frame = NSRect(x: 18, y: 115, width: 544, height: 64)
        label.frame = NSRect(x: 18, y: 82, width: 544, height: 25)
        label.lineBreakMode = .byTruncatingMiddle
        progress.frame = NSRect(x: 18, y: 54, width: 544, height: 18)
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        button.frame = NSRect(x: 466, y: 12, width: 96, height: 30)
        button.bezelStyle = .rounded; button.target = self; button.action = #selector(cancel)
        for view in [target, label, progress, button] { content.addSubview(view) }
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func cancel() {
        cancellation.cancel(); button.isEnabled = false; label.stringValue = "현재 검사를 마친 뒤 중단합니다…"
    }
    func update(_ value: FileCopyProgress) {
        progress.doubleValue = Double(value.completed) / Double(max(1, value.total))
        label.stringValue = "\(value.completed)/\(value.total)개 · \(ByteCountFormatter.string(fromByteCount: value.bytes, countStyle: .file)) · \(value.name)"
    }
    func finish(_ report: FileCopyReport, parent: NSWindow?) {
        close()
        let alert = NSAlert()
        alert.messageText = report.cancelled ? "복사를 취소했습니다" : "복사 결과"
        alert.informativeText = "성공 \(report.copied.count)개 · 실패/건너뜀 \(report.failures.count)개. 원본은 유지했습니다."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 240))
        text.isEditable = false
        text.string = report.copied.map { "완료: " + $0.path }.joined(separator: "\n") + "\n" + report.failures.map {
            "실패/건너뜀: \($0.source.path)\n대상(부분 결과가 남을 수 있음): \($0.destination.path)\n\($0.message)" +
                ($0.retainedTemporaryURL.map { "\n검토용 임시 데이터 보존: " + $0.path } ?? "")
        }.joined(separator: "\n\n")
        let scroll = NSScrollView(frame: text.frame); scroll.hasVerticalScroller = true
        scroll.documentView = text; alert.accessoryView = scroll
        if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
    }
}
