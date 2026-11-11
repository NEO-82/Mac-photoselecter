import AppKit

final class FolderNode: NSObject {
    let url: URL
    var lease: FolderLease
    let title: String
    var isDirectory: Bool
    var children: [FolderNode]?
    var loading = false
    var expanded = false
    var error: String?
    var requestID = UUID()
    init(url: URL, lease: FolderLease, title: String? = nil, isDirectory: Bool? = nil) {
        self.url = url; self.lease = lease
        self.isDirectory = isDirectory ?? ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath)
        self.title = title ?? url.lastPathComponent
    }
    func invalidate(lease: FolderLease? = nil) {
        if let lease { self.lease = lease }
        requestID = UUID(); loading = false; children = nil; error = nil
    }
}

// Keep AppKit's target/action and hit testing for disclosure. Supplying a real
// NSTableCellView below prevents content views from covering its reserved gutter.
final class FileOutlineView: NSOutlineView {
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let result = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier, let button = result as? NSButton {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "폴더 펼치기")?.withSymbolConfiguration(configuration)
            button.alternateImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "폴더 접기")?.withSymbolConfiguration(configuration)
            button.contentTintColor = ProTheme.secondary
        }
        return result
    }
}

private final class FolderRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        ProTheme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 5, yRadius: 5).fill()
    }
}

final class FolderTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let view = FileOutlineView()
    var onSelect: ((FolderNode) -> Void)?
    private(set) var roots: [FolderNode]
    var showHidden = false { didSet { if oldValue != showHidden { refresh(all: true) } } }
    private let directoryReader: (URL) throws -> [URL]
    private var suppressSelection = false
    private var expandedLocations: Set<String> = []
    private var selectionToRestore: URL?

    init(roots: [FolderNode]? = nil, directoryReader: @escaping (URL) throws -> [URL] = {
        try FolderReader.entries($0, directories: true, allFiles: true, showHidden: true)
    }) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ??
            home.appendingPathComponent("Desktop", isDirectory: true)
        let filesystem = URL(fileURLWithPath: "/", isDirectory: true)
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        self.roots = roots ?? [FolderNode(url: home, lease: FolderLease(home), title: "홈 · " + home.lastPathComponent, isDirectory: true),
                 FolderNode(url: desktop, lease: FolderLease(desktop), title: "데스크탑", isDirectory: true),
                 FolderNode(url: filesystem, lease: FolderLease(filesystem), title: "이 Mac", isDirectory: true),
                 FolderNode(url: volumes, lease: FolderLease(volumes), title: "저장장치", isDirectory: true)]
        self.directoryReader = directoryReader
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "파일 탐색기"; column.width = 250; column.minWidth = 80
        view.addTableColumn(column); view.outlineTableColumn = column
        view.headerView = nil; view.rowHeight = 28
        view.style = .sourceList
        view.indentationPerLevel = 18
        view.indentationMarkerFollowsCell = true
        view.intercellSpacing = NSSize(width: 0, height: 2)
        view.backgroundColor = ProTheme.panel
        view.selectionHighlightStyle = .regular
        view.usesAlternatingRowBackgroundColors = false
        view.autoresizingMask = [.width]
        view.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        view.dataSource = self; view.delegate = self
        view.allowsEmptySelection = false
        view.reloadData()
    }

    private func sameLocation(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.path.precomposedStringWithCanonicalMapping ==
            second.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    private func location(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }

    private func rememberExpanded(_ nodes: [FolderNode]) {
        for node in nodes {
            if node.expanded { expandedLocations.insert(location(node.url)) }
            rememberExpanded(node.children ?? [])
        }
    }

    private func restoreSelectionIfVisible() {
        guard let url = selectionToRestore else { return }
        for row in 0..<view.numberOfRows {
            if let node = view.item(atRow: row) as? FolderNode, sameLocation(node.url, url) {
                view.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                selectionToRestore = nil
                return
            }
        }
    }

    func select(_ url: URL, lease: FolderLease? = nil, renewAccess: Bool = false) {
        func findPath(_ nodes: [FolderNode]) -> [FolderNode]? {
            for node in nodes {
                if sameLocation(node.url, url) { return [node] }
                if let found = findPath(node.children ?? []) { return [node] + found }
            }
            return nil
        }
        selectionToRestore = nil
        let node: FolderNode
        var path = roots.first(where: { sameLocation($0.url, url) }).map { [$0] } ?? findPath(roots)
        suppressSelection = true
        if let existing = path?.last, lease.map({ sameLocation(existing.lease.url, $0.url) }) ?? true {
            node = existing
        }
        else {
            node = FolderNode(url: url, lease: lease ?? FolderLease(url), isDirectory: true)
            roots.insert(node, at: 0)
            view.reloadData()
            path = [node]
        }
        // select is the folder-navigation API; failed metadata reads must not
        // turn a previously denied directory into a non-expandable file.
        node.isDirectory = true
        let grantChanged = lease.map { node.lease !== $0 } ?? false
        if renewAccess || node.error != nil || (grantChanged && node.loading) {
            node.invalidate(lease: lease)
            if view.row(forItem: node) >= 0 { view.reloadItem(node, reloadChildren: true) }
        } else if let lease { node.lease = lease }
        for ancestor in (path ?? []).dropLast() {
            ancestor.expanded = true
            expandedLocations.insert(location(ancestor.url))
            view.expandItem(ancestor)
        }
        let row = view.row(forItem: node)
        if row >= 0 { view.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        suppressSelection = false
        node.expanded = true
        expandedLocations.insert(location(node.url))
        load(node)
        view.expandItem(node)
        onSelect?(node)
    }

    func refresh(all: Bool = false) {
        rememberExpanded(roots)
        suppressSelection = true
        let selected = view.item(atRow: view.selectedRow) as? FolderNode
        if let selected {
            let hidden = selected.url.lastPathComponent.hasPrefix(".") || (try? selected.url.resourceValues(forKeys: [.isHiddenKey]).isHidden) == true
            selectionToRestore = !showHidden && hidden ? selected.url.deletingLastPathComponent() : selected.url
        }
        let nodes = all ? roots : selected.flatMap { $0.isDirectory ? [$0] : nil } ?? roots
        for node in nodes {
            node.invalidate()
            view.reloadItem(node, reloadChildren: true)
        }
        for node in nodes where node.expanded { load(node) }
        restoreSelectionIfVisible()
        suppressSelection = false
    }

    // Refresh one directory after a file operation, retaining its ancestors and
    // location in the sidebar. A selected child may have just been removed.
    func refresh(url: URL) {
        func find(_ nodes: [FolderNode]) -> FolderNode? {
            for node in nodes {
                if node.isDirectory && sameLocation(node.url, url) { return node }
                if let match = find(node.children ?? []) { return match }
            }
            return nil
        }
        guard let node = find(roots) else { return }
        rememberExpanded(roots)
        let selected = view.item(atRow: view.selectedRow) as? FolderNode
        let selectFolder = selected === node || node.children?.contains(where: { $0 === selected }) == true
        if let selected { selectionToRestore = selectFolder ? node.url : selected.url }
        suppressSelection = true
        node.invalidate()
        view.reloadItem(node, reloadChildren: true)
        if node.expanded { load(node) }
        if selectFolder {
            let row = view.row(forItem: node)
            if row >= 0 { view.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        suppressSelection = false
    }

    private func load(_ node: FolderNode) {
        guard node.isDirectory, node.children == nil, !node.loading else { return }
        node.loading = true
        let token = node.requestID
        let lease = node.lease
        let reader = directoryReader
        let showHidden = self.showHidden
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak node] in
            guard let node else { return }
            // File metadata and Finder ordering can be expensive on removable
            // media. Resolve each entry once here, never in the main-queue sort.
            let result = Result { () throws -> [FolderNode] in
                try withExtendedLifetime(lease) {
                    let entries = try reader(node.url).compactMap { url -> (url: URL, directory: Bool)? in
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
                        guard showHidden || (values?.isHidden != true && !url.lastPathComponent.hasPrefix(".")) else { return nil }
                        return (url, values?.isDirectory ?? url.hasDirectoryPath)
                    }
                    return entries.sorted { first, second in
                        if first.directory != second.directory { return first.directory }
                        return first.url.lastPathComponent.localizedStandardCompare(second.url.lastPathComponent) == .orderedAscending
                    }.map { FolderNode(url: $0.url, lease: lease, isDirectory: $0.directory) }
                }
            }
            DispatchQueue.main.async {
                guard let self, node.requestID == token else { return }
                node.loading = false
                switch result {
                case .success(let children):
                    node.children = children; node.error = nil
                case .failure(let error): node.children = []; node.error = FolderReader.errorMessage(for: error)
                }
                // A collapsed ancestor or refreshed tree may no longer contain this row.
                guard self.view.row(forItem: node) >= 0 else { return }
                self.suppressSelection = true
                self.view.reloadItem(node, reloadChildren: true)
                if node.error == nil && node.expanded { self.view.expandItem(node) }
                for child in node.children ?? [] where child.isDirectory && self.expandedLocations.contains(self.location(child.url)) {
                    child.expanded = true
                    self.view.expandItem(child)
                    self.load(child)
                }
                self.restoreSelectionIfVisible()
                self.suppressSelection = false
            }
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FolderNode else { return roots.count }
        load(node)
        return node.children?.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FolderNode { return node.children![index] }
        return roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        return node.isDirectory && (node.error != nil || node.children == nil || !(node.children?.isEmpty ?? true))
    }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode, node.isDirectory else { return false }
        if node.error != nil && !suppressSelection { node.invalidate() }
        node.expanded = true; expandedLocations.insert(location(node.url)); load(node); return true
    }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if !suppressSelection, let node = item as? FolderNode {
            node.expanded = false; expandedLocations.remove(location(node.url))
        }
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        self.outlineView(outlineView, isItemExpandable: item)
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FolderRowView()
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = view.item(atRow: view.selectedRow) as? FolderNode else { return }
        if node.error != nil {
            node.invalidate(); load(node)
            suppressSelection = true
            view.reloadItem(node, reloadChildren: true)
            suppressSelection = false
        }
        onSelect?(node)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: node.title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = node.error == nil ? ProTheme.text : .systemRed
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let icon = NSImageView()
        if node.isDirectory {
            icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "폴더")
            icon.contentTintColor = ProTheme.accent
        } else { icon.image = NSWorkspace.shared.icon(forFile: node.url.path) }
        icon.imageScaling = .scaleProportionallyDown
        for child in [icon, label] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
        cell.imageView = icon; cell.textField = label
        cell.toolTip = node.error.map { $0 + "\n" + node.url.path } ?? node.url.path
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
