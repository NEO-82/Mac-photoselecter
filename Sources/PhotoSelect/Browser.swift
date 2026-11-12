import AppKit
import OSLog

final class PhotoCollectionView: NSCollectionView {
    var openCurrent: (() -> Void)?
    var trashCurrent: (() -> Void)?
    var toggleTag: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { openCurrent?() }; return
        }
        guard let action = PhotoShortcuts.editingAction(event) else { super.keyDown(with: event); return }
        guard !event.isARepeat else { return }
        switch action {
        case .trash: trashCurrent?()
        case .toggleTag: toggleTag?()
        }
    }
}

final class ThumbnailItem: NSCollectionViewItem {
    var request: Operation?
    var representedURL: URL?
    let tagMarker = TagMarkerView()
    override func loadView() {
        let container = ProSurfaceView(); container.fillColor = .clear; container.cornerRadius = 8
        let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 2
        label.alignment = .center; label.font = .systemFont(ofSize: 11, weight: .medium); label.textColor = ProTheme.text
        for view in [image, label, tagMarker] {
            view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            image.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            image.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -4),
            label.heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            tagMarker.topAnchor.constraint(equalTo: image.topAnchor, constant: 4),
            tagMarker.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: -4),
            tagMarker.widthAnchor.constraint(equalToConstant: 11),
            tagMarker.heightAnchor.constraint(equalToConstant: 11)
        ])
        view = container; imageView = image; textField = label
    }
    override func prepareForReuse() {
        super.prepareForReuse(); request?.cancel(); request = nil; representedURL = nil
        imageView?.image = nil; tagMarker.isHidden = true; view.toolTip = nil
    }
    override var isSelected: Bool {
        didSet {
            (view as? ProSurfaceView)?.fillColor = isSelected ? ProTheme.selection : .clear
        }
    }
}

final class FittingPreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

final class PreviewPane: ProSurfaceView {
    let imageView = FittingPreviewImageView()
    let filename = NSTextField(labelWithString: "선택한 사진 없음")
    let detail = NSTextField(wrappingLabelWithString: "")
    let tagMarker = TagMarkerView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "미리보기")
        title.font = .boldSystemFont(ofSize: 12)
        fillColor = ProTheme.panel
        let imageBox = ProSurfaceView(); imageBox.fillColor = ProTheme.canvas; imageBox.cornerRadius = 6
        title.textColor = ProTheme.secondary; filename.textColor = ProTheme.text
        filename.font = .systemFont(ofSize: 12, weight: .medium)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        filename.alignment = .center; filename.maximumNumberOfLines = 2; filename.lineBreakMode = .byWordWrapping
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.alignment = .center; detail.textColor = ProTheme.secondary; detail.font = .systemFont(ofSize: 11)
        detail.maximumNumberOfLines = 3
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [title, imageBox, filename, detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        for view in [imageView, tagMarker] { view.translatesAutoresizingMaskIntoConstraints = false; imageBox.addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageBox.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            imageBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageBox.bottomAnchor.constraint(equalTo: filename.topAnchor, constant: -10),
            filename.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            filename.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            filename.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -6),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            imageView.leadingAnchor.constraint(equalTo: imageBox.leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: imageBox.trailingAnchor, constant: -6),
            imageView.topAnchor.constraint(equalTo: imageBox.topAnchor, constant: 6),
            imageView.bottomAnchor.constraint(equalTo: imageBox.bottomAnchor, constant: -6),
            tagMarker.trailingAnchor.constraint(equalTo: imageBox.trailingAnchor, constant: -10),
            tagMarker.topAnchor.constraint(equalTo: imageBox.topAnchor, constant: 10),
            tagMarker.widthAnchor.constraint(equalToConstant: 12),
            tagMarker.heightAnchor.constraint(equalToConstant: 12)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func clear() {
        imageView.image = nil; filename.stringValue = "선택한 사진 없음"
        filename.toolTip = nil; detail.stringValue = ""; detail.toolTip = nil; tagMarker.isHidden = true
    }
    func select(_ photo: Photo) {
        imageView.image = nil; filename.stringValue = photo.url.lastPathComponent
        filename.toolTip = photo.url.path; detail.stringValue = "불러오는 중…"; detail.toolTip = nil
    }
    func display(_ decoded: DecodedImage) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        imageView.imageScaling = decoded.raw ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
        let pointSize = decoded.raw ? NSSize(width: CGFloat(decoded.image.width) / scale, height: CGFloat(decoded.image.height) / scale) : .zero
        imageView.image = NSImage(cgImage: decoded.image, size: pointSize)
        detail.toolTip = decoded.qualityDescription
        let size = decoded.sourceSize.width > 0 ? decoded.sourceSize : CGSize(width: decoded.image.width, height: decoded.image.height)
        detail.stringValue = "\(Int(size.width)) × \(Int(size.height)) · \(decoded.raw ? "ARW 내장 JPEG" : "JPEG")"
    }
}

final class BrowserController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    private let pipeline = ImagePipeline()
    private let thumbnails = ImagePipeline(cacheLimit: 96 * 1024 * 1024)
    private let tree = FolderTree()
    private let grid = PhotoCollectionView()
    private let preview = PreviewPane()
    private let columns = NSSplitView()
    private var arrangingColumns = false
    private var folderWidth: NSLayoutConstraint?
    private var previewWidth: NSLayoutConstraint?
    private var preferredFolderWidth: CGFloat?
    private var preferredPreviewWidth: CGFloat?
    private let photoActions = NSStackView()
    private let showButton = NSButton(title: "크게 보기", target: nil, action: nil)
    private let tagButton = NSButton(title: "태그", target: nil, action: nil)
    private let trashButton = NSButton(title: "휴지통", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "폴더를 선택하세요")
    private let up = NSButton(title: "상위 폴더", target: nil, action: nil)
    private let tagStore: TagStore
    private let trashService: PhotoTrash
    private var taggedPaths: Set<String> = []
    private var tagStorageError: String?
    private var finishingTagWrites = false
    private var list = PhotoList()
    private var entries: [BrowserEntry] = []
    private var selectedURL: URL?
    private var lease: FolderLease?
    private var currentFolder: URL?
    private var generation = UUID()
    private var imageGeneration = UUID()
    private var viewer: ViewerController?
    private var displayed: DecodedImage?
    private var previewError: String?
    private var actionMessage: String?
    private var isTrashing = false
    private var syncingSelection = false
    private var request: Operation?
    private var volumeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "dev.photoselect", category: "navigation")

    init(tagStore: TagStore = TagStore(), trashService: PhotoTrash = PhotoTrash(),
         initialFolder: URL? = FileManager.default.homeDirectoryForCurrentUser) {
        self.tagStore = tagStore; self.trashService = trashService
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppBranding.displayName
        window.minSize = WindowLayout.minimumSize(in: available, kind: .browser)
        window.maxSize = available.size
        window.setFrame(WindowLayout.initialFrame(in: available, kind: .browser), display: false)
        super.init(window: window)
        let content = ProSurfaceView(); content.fillColor = ProTheme.background; window.contentView = content
        window.backgroundColor = ProTheme.background
        status.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(status)
        let credit = NSTextField(labelWithString: "Made with Seoa ♡")
        credit.identifier = NSUserInterfaceItemIdentifier("PhotoBrowserCredit")
        credit.font = .systemFont(ofSize: 11)
        credit.textColor = ProTheme.accent
        credit.alignment = .right
        credit.setContentCompressionResistancePriority(.required, for: .horizontal)
        credit.setContentHuggingPriority(.required, for: .horizontal)
        credit.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(credit)
        let open = NSButton(title: "폴더 열기…", target: self, action: #selector(openFolder))
        up.target = self; up.action = #selector(parentFolder); up.isEnabled = false
        let refresh = NSButton(title: "새로고침", target: self, action: #selector(refreshFolder))
        for (button, symbol) in [(open, "folder.badge.plus"), (up, "arrow.up"), (refresh, "arrow.clockwise")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
            button.imagePosition = .imageOnly; button.toolTip = button.title
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.setAccessibilityLabel(button.title)
            button.bezelStyle = .texturedRounded; button.controlSize = .regular
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        for (button, symbol, action) in [(showButton, "arrow.up.left.and.arrow.down.right", #selector(openSelectedPhoto)),
                                          (tagButton, "tag", #selector(toggleTagFromMenu)),
                                          (trashButton, "trash", #selector(trashFromMenu))] {
            button.target = self; button.action = action; button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.imagePosition = .imageOnly; button.toolTip = button.title; button.setAccessibilityLabel(button.title)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true; button.isEnabled = false
            photoActions.addArrangedSubview(button)
        }
        photoActions.spacing = 8
        let bar = NSStackView(views: [open, up, refresh, NSView(), photoActions]); bar.spacing = 8
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.distribution = .fill
        bar.identifier = NSUserInterfaceItemIdentifier("PhotoBrowserToolbar")
        let split = columns; split.isVertical = true; split.dividerStyle = .thin
        split.identifier = NSUserInterfaceItemIdentifier("PhotoBrowserColumns")
        let folderScroll = NSScrollView(); folderScroll.hasVerticalScroller = true; folderScroll.documentView = tree.view
        folderScroll.drawsBackground = false
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = NSSize(width: 164, height: 154)
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 8
        grid.collectionViewLayout = layout; grid.dataSource = self; grid.delegate = self
        grid.autoresizingMask = [.width]
        grid.backgroundColors = [ProTheme.canvas]
        grid.isSelectable = true; grid.allowsMultipleSelection = false
        grid.register(ThumbnailItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("thumbnail"))
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(openPhoto(_:)))
        doubleClick.numberOfClicksRequired = 2; grid.addGestureRecognizer(doubleClick)
        grid.openCurrent = { [weak self] in self?.openSelectedPhoto() }
        grid.trashCurrent = { [weak self] in self?.trashCurrentPhoto() }
        grid.toggleTag = { [weak self] in self?.toggleCurrentTag() }
        let photoScroll = NSScrollView(); photoScroll.hasVerticalScroller = true; photoScroll.documentView = grid
        photoScroll.backgroundColor = ProTheme.canvas
        let folderPane = pane(title: "파일 탐색기", content: folderScroll)
        let photoPane = pane(title: "현재 폴더 · 모든 항목", content: photoScroll)
        split.addArrangedSubview(folderPane); split.addArrangedSubview(photoPane); split.addArrangedSubview(preview)
        // setPosition alone is only an initial frame hint. Auto Layout can discard
        // it on the first image/label update, so keep explicit preferred widths.
        let folderWidth = folderPane.widthAnchor.constraint(equalToConstant: 220)
        let previewWidth = preview.widthAnchor.constraint(equalToConstant: 280)
        for constraint in [folderWidth, previewWidth] { constraint.priority = .defaultHigh }
        NSLayoutConstraint.activate([folderWidth, previewWidth])
        self.folderWidth = folderWidth; self.previewWidth = previewWidth
        for view in [bar, split] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: 32),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: credit.leadingAnchor, constant: -12),
            credit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            credit.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            credit.widthAnchor.constraint(equalToConstant: ceil(credit.intrinsicContentSize.width)),
            credit.heightAnchor.constraint(equalToConstant: 16),
            status.heightAnchor.constraint(equalToConstant: 22),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4)
        ])
        content.layoutSubtreeIfNeeded()
        split.delegate = self
        arrangeColumns()
        window.delegate = self
        status.font = .systemFont(ofSize: 11); status.identifier = NSUserInterfaceItemIdentifier("PhotoBrowserStatus")
        status.lineBreakMode = .byTruncatingMiddle; status.maximumNumberOfLines = 1; status.textColor = ProTheme.secondary
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tree.onSelect = { [weak self] node in
            guard let self else { return }
            if node.isDirectory { self.loadFolder(node.url, lease: node.lease) }
            else if Photo.accepts(node.url), let index = self.list.photos.firstIndex(where: { $0.url == node.url }) {
                self.showPhoto(index)
            }
        }
        tagStore.load { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let paths): self.taggedPaths = paths; self.updateBadges()
            case .failure(let error):
                self.tagStorageError = error.localizedDescription
                self.setStatus("태그 읽기 실패: \(error.localizedDescription)", error: true)
            }
        }
        volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.pipeline.clear(); self.thumbnails.clear(); self.tree.refresh(all: true)
                self.generation = UUID(); self.imageGeneration = UUID(); self.displayed = nil
                self.previewError = "저장장치 변경 감지 — 새로고침하거나 폴더를 다시 선택하세요"
                self.viewer?.canvas.decoded = nil; self.preview.clear()
                self.viewer?.hud.stringValue = "저장장치 변경 감지 — Esc로 돌아가 폴더를 다시 선택하세요"
                self.setStatus("저장장치 변경 감지 — 새로고침하거나 폴더를 다시 선택하세요", error: true)
            }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.fitToCurrentScreen() }
        if let initialFolder { tree.select(initialFolder) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let volumeObserver { NSWorkspace.shared.notificationCenter.removeObserver(volumeObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func arrangeColumns() {
        guard !arrangingColumns, columns.arrangedSubviews.count == 3, columns.bounds.width > 0 else { return }
        arrangingColumns = true
        defer { arrangingColumns = false }
        let sizes = WindowLayout.columns(for: columns.bounds.width, divider: columns.dividerThickness, preferredFolders: preferredFolderWidth, preferredPreview: preferredPreviewWidth)
        folderWidth?.constant = sizes.folders; previewWidth?.constant = sizes.preview
        columns.setPosition(sizes.folders, ofDividerAt: 0)
        columns.setPosition(columns.bounds.width - sizes.preview - columns.dividerThickness, ofDividerAt: 1)
        columns.layoutSubtreeIfNeeded()
    }
    func windowDidResize(_ notification: Notification) {
        window?.contentView?.layoutSubtreeIfNeeded()
        arrangeColumns()
    }
    func windowDidChangeScreen(_ notification: Notification) { fitToCurrentScreen() }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        fitToCurrentScreen()
        if let displayed { preview.display(displayed) }
    }
    private func fitToCurrentScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        window.minSize = WindowLayout.minimumSize(in: screen.visibleFrame, kind: .browser)
        window.maxSize = screen.visibleFrame.size
        let fitted = WindowLayout.fittedFrame(window.frame, in: screen.visibleFrame, kind: .browser)
        if window.frame != fitted { window.setFrame(fitted, display: true) }
        window.contentView?.layoutSubtreeIfNeeded(); arrangeColumns()
    }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if arrangingColumns { return proposedMinimumPosition }
        let width = max(0, splitView.bounds.width - splitView.dividerThickness * 2)
        if dividerIndex == 0 { return max(proposedMinimumPosition, min(144, width * 0.22)) }
        return max(proposedMinimumPosition, splitView.arrangedSubviews[0].frame.maxX + splitView.dividerThickness + min(300, width * 0.5))
    }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if arrangingColumns { return proposedMaximumPosition }
        let width = max(0, splitView.bounds.width - splitView.dividerThickness * 2)
        if dividerIndex == 1 {
            return min(proposedMaximumPosition, splitView.bounds.width - min(168, width * 0.24) - splitView.dividerThickness)
        }
        return min(proposedMaximumPosition, splitView.arrangedSubviews[1].frame.maxX - min(300, width * 0.5) - splitView.dividerThickness)
    }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if !arrangingColumns {
            if dividerIndex == 0 {
                preferredFolderWidth = proposedPosition; folderWidth?.constant = proposedPosition
            } else {
                preferredPreviewWidth = splitView.bounds.width - proposedPosition - splitView.dividerThickness
                previewWidth?.constant = preferredPreviewWidth ?? 280
            }
        }
        return proposedPosition
    }

    private func pane(title: String, content: NSView) -> NSView {
        let box = ProSurfaceView(); box.fillColor = ProTheme.panel; let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = ProTheme.secondary
        for view in [label, content] { view.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(view) }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            content.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return box
    }
    private func setStatus(_ message: String, error: Bool = false) {
        let suffix = tagStorageError != nil && !message.contains("태그") ? " · 태그 저장소 오류" : ""
        let summary = currentFolder.map { "\($0.path) — \(entries.count)개 항목 · \(list.photos.count)장 사진" }
        let visible = summary.flatMap { message.contains(currentFolder?.path ?? "") ? nil : $0 + " · " } ?? ""
        status.stringValue = visible + message + suffix
        status.setAccessibilityLabel(status.stringValue)
        status.toolTip = visible + message + (tagStorageError.map { "\n태그: " + $0 } ?? "")
        status.textColor = error || tagStorageError != nil ? .systemRed : ProTheme.secondary
    }
    @objc func toggleHiddenFiles(_ sender: NSMenuItem) {
        tree.showHidden.toggle(); sender.state = tree.showHidden ? .on : .off
        if let currentFolder, let lease { loadFolder(currentFolder, lease: lease) }
    }
    @objc func changeAppearance(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "appearancePreference")
        NSApp.appearance = sender.tag == 1 ? NSAppearance(named: .aqua) : sender.tag == 2 ? NSAppearance(named: .darkAqua) : nil
    }
    @objc func openFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tree.select(url, lease: FolderLease(url), renewAccess: true)
        window?.makeFirstResponder(grid)
    }
    @objc func refreshFolder() {
        tree.refresh()
        if let currentFolder, let lease { loadFolder(currentFolder, lease: lease) }
    }
    @objc func parentFolder() {
        guard let currentFolder, let lease, currentFolder != lease.url else { return }
        tree.select(currentFolder.deletingLastPathComponent(), lease: lease)
    }
    @objc func openSelectedPhoto() {
        guard let entry = entries.first(where: { $0.url == selectedURL }) else { return }
        if entry.isDirectory, let lease { tree.select(entry.url, lease: lease) }
        else if let index = list.selectedIndex { openViewer(at: index) }
    }
    @objc func previousPhoto() {
        if let index = list.selectedIndex { showPhoto(index - 1) }
    }
    @objc func nextPhoto() {
        if let index = list.selectedIndex { showPhoto(index + 1) }
    }
    @objc func toggleTagFromMenu() {
        guard acceptsPhotoMenuEvent() else { return }
        toggleCurrentTag()
    }
    @objc func trashFromMenu() {
        guard acceptsPhotoMenuEvent() else { return }
        trashCurrentPhoto()
    }
    private func acceptsPhotoMenuEvent() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return true }
        guard !event.isARepeat else { return false }
        // Menu key equivalents must retain the existing grid/viewer focus rule.
        let responder = NSApp.keyWindow?.firstResponder
        return responder === grid || (viewer.map { responder === $0.canvas } ?? false)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !finishingTagWrites, NSApp.modalWindow == nil else { return false }
        switch menuItem.action {
        case #selector(changeAppearance(_:)):
            let saved = UserDefaults.standard.object(forKey: "appearancePreference") as? Int ?? 2
            menuItem.state = menuItem.tag == saved ? .on : .off
            return true
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = tree.showHidden ? .on : .off; return true
        case #selector(openFolder): return true
        case #selector(parentFolder): return up.isEnabled
        case #selector(refreshFolder): return currentFolder != nil
        case #selector(previousPhoto): return (list.selectedIndex ?? 0) > 0
        case #selector(nextPhoto): return list.selectedIndex.map { $0 + 1 < list.photos.count } ?? false
        case #selector(trashFromMenu): return list.selectedPhoto != nil && !isTrashing
        case #selector(openSelectedPhoto): return selectedURL != nil && (list.selectedPhoto != nil || entries.contains { $0.url == selectedURL && $0.isDirectory })
        case #selector(toggleTagFromMenu): return list.selectedPhoto != nil
        default: return false
        }
    }
    func finishPendingTagWrites(completion: @escaping () -> Void) {
        finishingTagWrites = true
        tagStore.finishPendingWrites(completion: completion)
    }
    private func loadFolder(_ url: URL, lease: FolderLease) {
        generation = UUID(); let token = generation
        imageGeneration = UUID(); entries = []; selectedURL = nil; list.replace(with: []); pipeline.clear(); thumbnails.clear()
        viewer?.close(); displayed = nil; previewError = nil; preview.clear()
        self.lease = lease; currentFolder = url; actionMessage = nil
        updateBadges()
        up.isEnabled = url != lease.url
        synchronizeGrid(reload: true)
        setStatus("읽는 중: \(url.path)")
        let showHidden = tree.showHidden
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try withExtendedLifetime(lease) { try BrowserEntry.read(url, showHidden: showHidden) } }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let urls):
                    self.entries = urls
                    self.list.replace(with: urls.filter(\.isPhoto).map { Photo(url: $0.url) })
                    self.setStatus("\(url.path) — \(self.entries.count)개 항목 · \(self.list.photos.count)장 사진")
                    self.synchronizeGrid(reload: true)
                    if let index = self.list.selectedIndex { self.showPhoto(index) }
                    else if !self.entries.isEmpty { self.selectEntry(at: 0) }
                case .failure(let error):
                    let message = FolderReader.errorMessage(for: error)
                    self.setStatus("폴더 읽기 실패: \(message)", error: true)
                    self.preview.detail.stringValue = message
                }
            }
        }
    }
    private func synchronizeGrid(reload: Bool = false) {
        syncingSelection = true
        if reload { grid.reloadData() }
        if let index = entries.firstIndex(where: { $0.url == selectedURL }) {
            let path = IndexPath(item: index, section: 0)
            grid.selectionIndexPaths = [path]
            grid.scrollToItems(at: [path], scrollPosition: .centeredVertically)
        } else { grid.selectionIndexPaths = [] }
        syncingSelection = false
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard !syncingSelection, let path = indexPaths.first, entries.indices.contains(path.item),
              entries[path.item].url != selectedURL else { return }
        selectEntry(at: path.item)
    }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("thumbnail"), for: path) as! ThumbnailItem
        let entry = entries[path.item]
        let photo = Photo(url: entry.url); let token = generation
        item.request?.cancel(); item.request = nil
        item.imageView?.imageScaling = entry.isPhoto ? .scaleProportionallyUpOrDown : .scaleProportionallyDown
        item.representedURL = photo.url; item.textField?.stringValue = photo.url.lastPathComponent
        item.textField?.toolTip = photo.url.lastPathComponent; item.view.toolTip = photo.url.lastPathComponent
        item.imageView?.image = nil; item.tagMarker.isHidden = !taggedPaths.contains(TagStore.key(photo.url))
        guard entry.isPhoto else {
            item.imageView?.image = entryIcon(entry)
            item.tagMarker.isHidden = true
            return item
        }
        if let lease {
            item.request = thumbnails.load(photo, lease: lease, quality: .thumbnail) { [weak self, weak item] result, _ in
                guard let self, self.generation == token, let item, item.representedURL == photo.url else { return }
                switch result {
                case .success(let decoded): item.imageView?.image = NSImage(cgImage: decoded.image, size: .zero)
                case .failure(let error):
                    item.imageView?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "읽기 실패")
                    item.view.toolTip = error.localizedDescription
                }
            }
        }
        return item
    }
    @objc private func openPhoto(_ sender: NSClickGestureRecognizer) {
        guard let path = grid.indexPathForItem(at: sender.location(in: grid)), entries.indices.contains(path.item) else { return }
        selectEntry(at: path.item)
        openSelectedPhoto()
    }
    private func selectEntry(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        if entry.isPhoto, let photoIndex = list.photos.firstIndex(where: { $0.url == entry.url }) {
            showPhoto(photoIndex); return
        }
        request?.cancel(); imageGeneration = UUID(); displayed = nil; previewError = nil
        selectedURL = entry.url; list.clearSelection()
        preview.clear()
        preview.imageView.imageScaling = .scaleProportionallyDown
        preview.imageView.image = entryIcon(entry)
        preview.filename.stringValue = entry.url.lastPathComponent
        preview.filename.toolTip = entry.url.path
        preview.detail.stringValue = entry.isDirectory ? "폴더 · 더블클릭 또는 Return으로 열기" :
            (entry.url.pathExtension.isEmpty ? "파일" : entry.url.pathExtension.uppercased() + " 파일")
        synchronizeGrid(); updateBadges(); setStatus(entry.url.lastPathComponent)
    }
    private func entryIcon(_ entry: BrowserEntry) -> NSImage {
        if !entry.isDirectory, ["txt", "xmp", "json"].contains(entry.url.pathExtension.lowercased()),
           let document = NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: "문서") {
            let style = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [ProTheme.secondary]))
            return document.withSymbolConfiguration(style) ?? document
        }
        let icon = NSWorkspace.shared.icon(forFile: entry.url.path).copy() as! NSImage
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }
    private func openViewer(at index: Int) {
        if viewer == nil {
            let viewer = ViewerController(); self.viewer = viewer
            viewer.canvas.navigate = { [weak self] step in
                guard let self, let index = self.list.selectedIndex else { return }
                self.showPhoto(index + step)
            }
            viewer.canvas.zoomChanged = { [weak self] _ in self?.updateHUD() }
            viewer.canvas.trashCurrent = { [weak self] in self?.trashCurrentPhoto() }
            viewer.canvas.toggleTag = { [weak self] in self?.toggleCurrentTag() }
            viewer.didClose = { [weak self] in
                guard let self else { return }
                // Keep the decoded image, thumbnail views and scroll position on return.
                self.viewer = nil
                self.window?.makeKeyAndOrderFront(nil); self.window?.makeFirstResponder(self.grid)
            }
        }
        viewer?.window?.title = (list.photos.indices.contains(index) ? list.photos[index].url.lastPathComponent + " — " : "") + AppBranding.displayName
        viewer?.present(on: window?.screen)
        if list.selectedIndex == index {
            viewer?.canvas.decoded = displayed
            if displayed == nil { viewer?.hud.stringValue = previewError.map { $0 + " — ←/→ 계속 탐색 · Esc 복귀" } ?? ((list.selectedPhoto?.url.lastPathComponent ?? "") + " — 읽는 중…") }
            updateHUD(); updateBadges()
        } else { showPhoto(index) }
    }
    private func showPhoto(_ index: Int) {
        guard let lease, list.select(index), let photo = list.selectedPhoto else { return }
        selectedURL = photo.url
        // Keep useful neighboring work alive. Only this UI subscriber is canceled.
        request?.cancel()
        imageGeneration = UUID(); let token = imageGeneration
        let neighbors = [index - 1, index + 1].filter { list.photos.indices.contains($0) }.map { list.photos[$0] }
        pipeline.retain(photos: [photo] + neighbors)
        previewError = nil; actionMessage = nil
        preview.filename.stringValue = photo.url.lastPathComponent
        preview.filename.toolTip = photo.url.path
        viewer?.window?.title = photo.url.lastPathComponent + " — " + AppBranding.displayName
        synchronizeGrid(); updateBadges()
        setStatus("\(currentFolder?.path ?? "") — \(entries.count)개 항목 · 1장 선택")
        let start = ProcessInfo.processInfo.systemUptime
        if let cached = pipeline.cached(photo, quality: .preview) {
            displayed = cached; viewer?.canvas.decoded = cached; preview.display(cached); updateHUD()
            logger.info("preview cacheHit=true latencyMs=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        } else {
            // A loading state is preferable to enlarging a thumbnail or showing
            // a different source that would change sharpness/color a moment later.
            displayed = nil; viewer?.canvas.decoded = nil; preview.select(photo)
            viewer?.hud.stringValue = photo.url.lastPathComponent + " — 고해상도 프리뷰 읽는 중…"
            request = pipeline.load(photo, lease: lease, quality: .preview) { [weak self] result, hit in
                guard let self, self.imageGeneration == token else { return }
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.logger.info("preview cacheHit=\(hit) latencyMs=\(ms)")
                switch result {
                case .success(let image):
                    self.displayed = image; self.viewer?.canvas.decoded = image
                    self.preview.display(image); self.updateHUD()
                case .failure(let error):
                    self.previewError = error.localizedDescription
                    self.preview.detail.stringValue = error.localizedDescription
                    self.viewer?.hud.stringValue = error.localizedDescription + " — ←/→ 계속 탐색 · Esc 복귀"
                }
            }
        }
        // Start both neighbors now, not only after a slow current decode completes.
        for neighbor in neighbors {
            pipeline.load(neighbor, lease: lease, quality: .preview, prefetch: true) { _, _ in }
        }
    }
    private func updateHUD() {
        guard let photo = list.selectedPhoto, let index = list.selectedIndex, let displayed else { return }
        let quality = displayed.qualityDescription
        viewer?.hud.stringValue = "\(index + 1)/\(list.photos.count)  \(photo.url.lastPathComponent)  \(quality)\n←/→ 탐색 · 누르는 동안 100% · \\ 태그 · Delete 휴지통 · Esc/더블클릭 복귀" + (actionMessage.map { "\n" + $0 } ?? "")
    }
    private func updateBadges() {
        showButton.isEnabled = list.selectedPhoto != nil
        tagButton.isEnabled = list.selectedPhoto != nil && !finishingTagWrites
        trashButton.isEnabled = list.selectedPhoto != nil && !isTrashing
        let tagged = list.selectedPhoto.map { taggedPaths.contains(TagStore.key($0.url)) } ?? false
        tagButton.contentTintColor = tagged ? ProTheme.accent : nil
        tagButton.state = tagged ? .on : .off
        preview.tagMarker.isHidden = !tagged; viewer?.tagMarker.isHidden = !tagged
        for case let item as ThumbnailItem in grid.visibleItems() {
            item.tagMarker.isHidden = !(item.representedURL.map { taggedPaths.contains(TagStore.key($0)) } ?? false)
        }
    }
    private func toggleCurrentTag() {
        guard !finishingTagWrites, let photo = list.selectedPhoto else { return }
        tagStore.toggle(photo.url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tagged):
                if tagged { self.taggedPaths.insert(TagStore.key(photo.url)) }
                else { self.taggedPaths.remove(TagStore.key(photo.url)) }
                self.updateBadges()
                self.setStatus("\(photo.url.lastPathComponent) · \(tagged ? "태그 지정됨" : "태그 해제됨")")
            case .failure(let error): self.reportActionError("태그 저장 실패: \(error.localizedDescription)", target: photo.url)
            }
        }
    }
    private func trashCurrentPhoto() {
        guard !isTrashing, let photo = list.selectedPhoto, let lease else { return }
        isTrashing = true; updateBadges(); let token = generation
        actionMessage = "휴지통으로 옮기는 중…"; updateHUD()
        trashService.trash(photo, lease: lease) { [weak self] result in
            guard let self else { return }
            self.isTrashing = false; self.updateBadges()
            switch result {
            case .failure(let error): self.reportActionError(PhotoTrash.errorMessage(for: error), target: photo.url)
            case .success(let receipt):
                guard self.generation == token else { return }
                let selectedURL = self.selectedURL
                guard self.list.remove(photo.url) else { return }
                self.entries.removeAll { $0.url == photo.url }
                if self.selectedURL == photo.url { self.selectedURL = self.list.selectedPhoto?.url }
                if let selectedURL, self.entries.contains(where: { $0.url == selectedURL && !$0.isPhoto }) {
                    self.list.clearSelection()
                }
                self.actionMessage = nil
                if let folder = self.currentFolder { self.tree.refresh(url: folder) }
                self.synchronizeGrid(reload: true)
                if let index = self.list.selectedIndex {
                    if selectedURL == photo.url { self.showPhoto(index) }
                    else { self.updateHUD(); self.updateBadges() }
                } else {
                    self.imageGeneration = UUID(); self.pipeline.cancelAll(); self.displayed = nil
                    self.viewer?.close()
                    if let index = self.entries.firstIndex(where: { $0.url == self.selectedURL }) { self.selectEntry(at: index) }
                    else { self.preview.clear(); self.updateBadges() }
                }
                let completion = "\(photo.url.lastPathComponent) 휴지통 이동 완료" + (receipt.storageNotice.map { " · " + $0 } ?? "")
                self.actionMessage = receipt.storageNotice; self.updateHUD()
                self.setStatus(completion)
            }
        }
    }
    private func reportActionError(_ message: String, target: URL) {
        setStatus(message, error: true)
        if list.selectedPhoto?.url == target {
            actionMessage = message; preview.detail.stringValue = message; updateHUD()
        }
    }
}
