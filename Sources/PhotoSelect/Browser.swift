import AppKit
import OSLog

final class ThumbnailItem: NSCollectionViewItem {
    var request: Operation?
    var representedURL: URL?
    override func loadView() {
        let container = NSView()
        let image = NSImageView(); image.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: ""); label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center; label.font = .systemFont(ofSize: 11)
        image.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(image); container.addSubview(label)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            image.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            image.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        view = container; imageView = image; textField = label
    }
    override func prepareForReuse() {
        super.prepareForReuse(); request?.cancel(); request = nil; representedURL = nil; imageView?.image = nil
    }
    override var isSelected: Bool {
        didSet { view.wantsLayer = true; view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor }
    }
}

final class BrowserController: NSWindowController, NSCollectionViewDataSource, NSTableViewDataSource, NSTableViewDelegate {
    private let pipeline = ImagePipeline()
    private let thumbnails = ImagePipeline()
    private let folders = NSTableView()
    private let grid = NSCollectionView()
    private let status = NSTextField(labelWithString: "폴더 열기를 선택하세요")
    private var lease: FolderLease?
    private var root: URL?
    private var currentFolder: URL?
    private var directoryURLs: [URL] = []
    private var photos: [Photo] = []
    private var generation = UUID()
    private var imageGeneration = UUID()
    private var viewer: ViewerController?
    private var index = 0
    private var displayed: DecodedImage?
    private var zoom = false
    private var fullRequested = false
    private var fullError: String?
    private var request: Operation?
    private var fullRequest: Operation?
    private var volumeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "dev.photoselect", category: "navigation")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = AppBranding.displayName; window.center()
        super.init(window: window)
        let content = NSView(); window.contentView = content
        let open = NSButton(title: "폴더 열기…", target: self, action: #selector(openFolder))
        let up = NSButton(title: "상위 폴더", target: self, action: #selector(parentFolder))
        let refresh = NSButton(title: "새로고침", target: self, action: #selector(refreshFolder))
        let bar = NSStackView(views: [open, up, refresh, status]); bar.spacing = 12
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        let folderScroll = NSScrollView(); folderScroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder")); column.title = "하위 폴더"
        folders.addTableColumn(column); folders.headerView = nil
        folders.dataSource = self; folders.delegate = self
        folders.target = self; folders.doubleAction = #selector(enterFolder)
        folderScroll.documentView = folders
        let layout = NSCollectionViewFlowLayout(); layout.itemSize = NSSize(width: 160, height: 142)
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 8; layout.minimumLineSpacing = 8
        grid.collectionViewLayout = layout; grid.dataSource = self; grid.isSelectable = true
        grid.register(ThumbnailItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("thumbnail"))
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(openPhoto(_:)))
        doubleClick.numberOfClicksRequired = 2; grid.addGestureRecognizer(doubleClick)
        let photoScroll = NSScrollView(); photoScroll.hasVerticalScroller = true; photoScroll.documentView = grid
        split.addArrangedSubview(folderScroll); split.addArrangedSubview(photoScroll)
        for view in [bar, split] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            folderScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        split.setPosition(230, ofDividerAt: 0)
        status.lineBreakMode = .byTruncatingMiddle
        volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.pipeline.clear(); self.thumbnails.clear()
                self.generation = UUID(); self.imageGeneration = UUID()
                self.displayed = nil; self.viewer?.canvas.decoded = nil
                self.viewer?.hud.stringValue = "저장장치 변경 감지 — Esc로 돌아가 폴더를 다시 선택하세요"
                self.status.stringValue = "저장장치 변경 감지 — 새로고침하거나 폴더를 다시 선택하세요"
            }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let volumeObserver { NSWorkspace.shared.notificationCenter.removeObserver(volumeObserver) } }

    @objc private func openFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewer?.close(); lease = FolderLease(url); root = url; loadFolder(url)
    }
    @objc private func refreshFolder() { if let currentFolder { loadFolder(currentFolder) } }
    @objc private func parentFolder() {
        guard let currentFolder, let root, currentFolder != root else { return }
        loadFolder(currentFolder.deletingLastPathComponent())
    }
    @objc private func enterFolder() {
        let row = folders.clickedRow
        guard directoryURLs.indices.contains(row) else { return }
        loadFolder(directoryURLs[row])
    }
    private func loadFolder(_ url: URL) {
        guard let lease else { return }
        viewer?.close(); pipeline.clear(); thumbnails.clear()
        currentFolder = url; generation = UUID(); let token = generation
        photos = []; directoryURLs = []; grid.reloadData(); folders.reloadData()
        status.stringValue = "읽는 중: \(url.path)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> ([URL], [URL]) in
                try withExtendedLifetime(lease) {
                    (try FolderReader.entries(url, directories: true), try FolderReader.entries(url, directories: false))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let entries):
                    self.directoryURLs = entries.0; self.photos = entries.1.map { Photo(url: $0) }
                    self.status.stringValue = "\(url.path) — \(self.photos.count)장"
                case .failure(let error): self.status.stringValue = "폴더 읽기 실패: \(error.localizedDescription)"
                }
                self.grid.reloadData(); self.folders.reloadData()
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { directoryURLs.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "📁 " + directoryURLs[row].lastPathComponent)
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { photos.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("thumbnail"), for: path) as! ThumbnailItem
        let photo = photos[path.item]; let token = generation
        item.representedURL = photo.url; item.textField?.stringValue = photo.url.lastPathComponent
        item.imageView?.image = nil
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
        guard let path = grid.indexPathForItem(at: sender.location(in: grid)), photos.indices.contains(path.item) else { return }
        thumbnails.cancelAll()
        let viewer = ViewerController(); self.viewer = viewer
        viewer.canvas.navigate = { [weak self] step in
            guard let self else { return }; self.showPhoto(self.index + step)
        }
        viewer.canvas.zoomChanged = { [weak self] pressed in
            guard let self else { return }; self.zoom = pressed
            if pressed { self.loadFullResolution() }
            self.updateHUD()
        }
        viewer.didClose = { [weak self] in
            guard let self else { return }
            self.imageGeneration = UUID(); self.pipeline.cancelAll(); self.displayed = nil
            self.viewer = nil; self.grid.reloadData()
            self.grid.selectItems(at: [IndexPath(item: self.index, section: 0)], scrollPosition: .centeredVertically)
            self.window?.makeKeyAndOrderFront(nil)
        }
        viewer.present(on: window?.screen); showPhoto(path.item)
    }
    private func showPhoto(_ newIndex: Int) {
        guard photos.indices.contains(newIndex), let lease else { return }
        pipeline.cancelAll(); index = newIndex; imageGeneration = UUID(); let token = imageGeneration
        displayed = nil; fullRequested = false; fullError = nil; viewer?.canvas.decoded = nil
        viewer?.hud.stringValue = "\(photos[index].url.lastPathComponent) — 읽는 중…"
        let start = ProcessInfo.processInfo.systemUptime
        request = pipeline.load(photos[index], lease: lease, quality: .preview) { [weak self] result, hit in
            guard let self, self.imageGeneration == token else { return }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            self.logger.info("preview cacheHit=\(hit) latencyMs=\(ms)")
            switch result {
            case .success(let image):
                self.displayed = image; self.viewer?.canvas.decoded = image; self.updateHUD()
                if self.zoom { self.loadFullResolution() }
                for neighbor in [self.index - 1, self.index + 1] where self.photos.indices.contains(neighbor) {
                    self.pipeline.load(self.photos[neighbor], lease: lease, quality: .preview, prefetch: true) { _, _ in }
                }
            case .failure(let error): self.viewer?.hud.stringValue = error.localizedDescription + " — ←/→ 계속 탐색 · Esc 복귀"
            }
        }
    }
    private func loadFullResolution() {
        guard let displayed, !displayed.fullResolution, !fullRequested, let lease else { return }
        fullRequested = true; let token = imageGeneration
        let start = ProcessInfo.processInfo.systemUptime
        fullRequest = pipeline.load(photos[index], lease: lease, quality: .full) { [weak self] result, hit in
            guard let self, self.imageGeneration == token else { return }
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            self.logger.info("full cacheHit=\(hit) latencyMs=\(ms)")
            switch result {
            case .success(let image): self.displayed = image; self.viewer?.canvas.decoded = image; self.updateHUD()
            case .failure(let error): self.fullError = error.localizedDescription; self.updateHUD()
            }
        }
    }
    private func updateHUD() {
        guard photos.indices.contains(index), let displayed else { return }
        let quality = fullError ?? (displayed.fullResolution ? "원본 해상도" : "프리뷰 · 확대 정확도 제한")
        viewer?.hud.stringValue = "\(index + 1)/\(photos.count)  \(photos[index].url.lastPathComponent)  \(quality)\n←/→ 탐색 · 누르는 동안 100% (물리 픽셀 1:1) · Esc 복귀"
    }
}
