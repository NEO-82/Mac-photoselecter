import AppKit

final class BatchRenameWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let folder: URL, photos: [BrowserEntry], existingNames: Set<String>, orderTitle: String
    private let engine: BatchRenameEngine, tags: TagStore, lease: FolderLease
    private let recoveryURL: URL?
    private let base = NSTextField(string: "Photo"), separator = NSTextField(string: "_"), start = NSTextField(string: "1"), digits = NSPopUpButton(frame: .zero, pullsDown: false)
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let outcome = NSTextField(wrappingLabelWithString: "실행 전에는 파일을 변경하지 않습니다. 태그 필터와 무관하게 현재 폴더의 모든 사진이 대상입니다.")
    private let run = NSButton(title: "이름 변경 실행", target: nil, action: nil), closeButton = NSButton(title: "닫기", target: nil, action: nil)
    private let table = NSTableView(), progress = NSProgressIndicator()
    private(set) var plan: RenamePlan?
    private(set) var busy = false
    private var notifiedClose = false
    var onBusy: (() -> Void)?
    var onComplete: ((RenameOutcome) -> Void)?
    var onClose: (() -> Void)?
    init(folder: URL, photos: [BrowserEntry], existingNames: Set<String>, orderTitle: String, engine: BatchRenameEngine, tags: TagStore, lease: FolderLease, recoveryURL: URL? = nil) {
        self.folder = folder; self.photos = photos; self.existingNames = existingNames; self.orderTitle = orderTitle
        self.engine = engine; self.tags = tags; self.lease = lease; self.recoveryURL = recoveryURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "일괄 이름 변경 — " + AppBranding.displayName
        window.minSize = NSSize(width: 700, height: 620); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let content = ProSurfaceView(); content.fillColor = ProTheme.background; window.contentView = content
        let fields = NSStackView(); fields.orientation = .horizontal; fields.spacing = 12; fields.alignment = .bottom
        for (label, control, width) in [("기본 이름", base as NSView, CGFloat(210)), ("구분 문자", separator as NSView, 70), ("시작 번호", start as NSView, 100), ("자릿수", digits as NSView, 80)] {
            let title = NSTextField(labelWithString: label); title.textColor = ProTheme.secondary; title.font = .systemFont(ofSize: 11)
            let stack = NSStackView(views: [title, control]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
            control.widthAnchor.constraint(equalToConstant: width).isActive = true; fields.addArrangedSubview(stack)
        }
        for field in [base, separator, start] {
            field.delegate = self; field.font = .systemFont(ofSize: 12); field.textColor = ProTheme.text; field.backgroundColor = ProTheme.canvas
        }
        base.identifier = NSUserInterfaceItemIdentifier("RenameBase")
        for value in 1...12 { digits.addItem(withTitle: String(value)) }; digits.selectItem(withTitle: "4")
        digits.target = self; digits.action = #selector(settingsChanged)
        summary.textColor = ProTheme.accent; summary.font = .systemFont(ofSize: 12, weight: .medium)
        outcome.isSelectable = true; outcome.textColor = ProTheme.secondary; outcome.font = .systemFont(ofSize: 11); outcome.maximumNumberOfLines = 5
        for (id, title, width) in [("original", "기존 파일명", CGFloat(240)), ("proposed", "변경 예정 파일명", 240), ("status", "충돌 / 상태", 280)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 23; table.usesAutomaticRowHeights = false
        table.backgroundColor = ProTheme.canvas; table.selectionHighlightStyle = .none
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        run.target = self; run.action = #selector(execute); run.bezelStyle = .rounded; run.contentTintColor = ProTheme.accent
        run.identifier = NSUserInterfaceItemIdentifier("RenameExecute")
        closeButton.target = self; closeButton.action = #selector(dismiss); closeButton.bezelStyle = .rounded; closeButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), closeButton, run]); buttons.orientation = .horizontal; buttons.spacing = 10
        let stack = NSStackView(views: [fields, summary, scroll, progress, outcome, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor), outcome.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        if let recoveryURL {
            for field in [base, separator, start] { field.isEnabled = false }; digits.isEnabled = false
            if let journal = try? engine.readJournal(recoveryURL, folder: folder) {
                plan = RenamePlan(folder: folder, orderTitle: journal.orderTitle, rows: journal.items.map { RenamePreview(original: $0.original, proposed: $0.destination) })
                summary.stringValue = "중단 작업 \(journal.items.count)개 · " + journal.orderTitle
            }
            run.title = "중단 작업 복구"; outcome.stringValue = "이미 모든 새 이름이 적용됐으면 태그 연결을 마칩니다. 일부만 진행됐으면 원래 이름으로 복구합니다. 다른 파일은 덮어쓰지 않습니다."
            table.reloadData()
        } else { rebuild() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ notification: Notification) { rebuild() }
    @objc private func settingsChanged() { rebuild() }
    private func rebuild() {
        guard !busy, recoveryURL == nil else { return }
        do {
            guard let number = Int(start.stringValue) else { throw RenameProblem(message: "시작 번호를 정수로 입력하세요.") }
            plan = try RenamePlan.make(folder: folder, photos: photos, orderTitle: orderTitle,
                settings: RenameSettings(base: base.stringValue, separator: separator.stringValue, start: number, digits: Int(digits.titleOfSelectedItem ?? "4") ?? 4), existingNames: existingNames)
            let conflicts = plan?.rows.filter { $0.issue != nil }.count ?? 0
            summary.stringValue = "대상 \(photos.count)개 · \(orderTitle) · 변경 \(plan?.changedCount ?? 0)개 · 충돌 \(conflicts)개"
            run.isEnabled = plan?.valid == true && (plan?.changedCount ?? 0) > 0
        } catch { plan = nil; summary.stringValue = error.localizedDescription; run.isEnabled = false }
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { plan?.rows.count ?? 0 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let value = plan?.rows[row], let column = tableColumn else { return nil }
        let field = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = column.identifier; field.font = .systemFont(ofSize: 11); field.textColor = value.issue != nil && !["완료", "원래 이름 복구"].contains(value.issue!) ? .systemRed : ProTheme.text
        switch column.identifier.rawValue {
        case "original": field.stringValue = value.original
        case "proposed": field.stringValue = value.proposed
        default: field.stringValue = value.issue ?? (value.original == value.proposed ? "변경 없음" : "대기")
        }
        field.lineBreakMode = .byTruncatingMiddle; field.toolTip = field.stringValue; return field
    }
    @objc private func execute() {
        guard !busy, recoveryURL != nil || plan?.valid == true else { return }
        busy = true; run.isEnabled = false; closeButton.isEnabled = false
        for field in [base, separator, start] { field.isEnabled = false }; digits.isEnabled = false
        onBusy?()
        let update: BatchRenameEngine.Progress = { [weak self] done, total, phase in
            self?.progress.maxValue = Double(total); self?.progress.doubleValue = Double(done)
            self?.outcome.stringValue = "\(phase) · \(done)/\(total)"
        }
        let finish: (RenameOutcome) -> Void = { [weak self] result in
            guard let self else { return }
            self.busy = false; self.closeButton.isEnabled = true
            self.progress.maxValue = 1; self.progress.doubleValue = result.completed || result.restored ? 1 : 0
            let changed = self.plan?.changedCount ?? 0
            self.outcome.stringValue = "정상 완료 \(result.completed ? changed : 0)개 · 실패/취소 \(result.completed ? 0 : changed)개\n" + result.message
            if let plan = self.plan {
                self.plan?.rows = plan.rows.map { row in
                    var updated = row
                    if result.completed { updated.issue = "완료" }
                    else if result.restored { updated.issue = "원래 이름 복구" }
                    else if result.mapping.isEmpty && result.journalURL == nil { updated.issue = "실행 전 확인 실패 · 변경 안 함" }
                    else {
                        let old = TagStore.key(self.folder.appendingPathComponent(row.original))
                        let current = result.mapping.first { TagStore.key($0.key) == old }?.value.lastPathComponent ?? "위치 확인 불가"
                        updated.issue = "복구 확인 필요 · " + current
                    }
                    return updated
                }
                self.table.reloadData()
            }
            self.onComplete?(result)
        }
        if let recoveryURL { engine.recover(recoveryURL, folder: folder, tagStore: tags, lease: lease, progress: update, completion: finish) }
        else if let plan { engine.execute(plan, tagStore: tags, lease: lease, progress: update, completion: finish) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    private func notifyClose() { if !notifiedClose { notifiedClose = true; onClose?() } }
    func windowWillClose(_ notification: Notification) {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        notifyClose()
    }
    @objc private func dismiss() {
        guard !busy else { return }
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        close(); notifyClose()
    }
}
