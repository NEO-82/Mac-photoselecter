import AppKit

final class FolderNode: NSObject {
    let url: URL
    var lease: FolderLease
    let title: String
    var children: [FolderNode]?
    var loading = false
    var expanded = false
    var error: String?
    var requestID = UUID()
    init(url: URL, lease: FolderLease, title: String? = nil) {
        self.url = url; self.lease = lease
        self.title = title ?? url.lastPathComponent
    }
    func invalidate(lease: FolderLease? = nil) {
        if let lease { self.lease = lease }
        requestID = UUID(); loading = false; children = nil; error = nil
    }
}

final class FolderTree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let view = NSOutlineView()
    var onSelect: ((FolderNode) -> Void)?
    private(set) var roots: [FolderNode]
    private let directoryReader: (URL) throws -> [URL]
    private var suppressSelection = false

    init(roots: [FolderNode]? = nil, directoryReader: @escaping (URL) throws -> [URL] = {
        try FolderReader.entries($0, directories: true)
    }) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ??
            home.appendingPathComponent("Desktop", isDirectory: true)
        let filesystem = URL(fileURLWithPath: "/", isDirectory: true)
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        self.roots = roots ?? [FolderNode(url: home, lease: FolderLease(home), title: "홈 · " + home.lastPathComponent),
                 FolderNode(url: desktop, lease: FolderLease(desktop), title: "데스크탑"),
                 FolderNode(url: filesystem, lease: FolderLease(filesystem), title: "이 Mac"),
                 FolderNode(url: volumes, lease: FolderLease(volumes), title: "저장장치")]
        self.directoryReader = directoryReader
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.title = "폴더"; column.width = 210
        view.addTableColumn(column); view.outlineTableColumn = column
        view.headerView = nil; view.rowHeight = 26
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

    func select(_ url: URL, lease: FolderLease? = nil, renewAccess: Bool = false) {
        func findPath(_ nodes: [FolderNode]) -> [FolderNode]? {
            for node in nodes {
                if sameLocation(node.url, url) { return [node] }
                if let found = findPath(node.children ?? []) { return [node] + found }
            }
            return nil
        }
        let node: FolderNode
        var path = roots.first(where: { sameLocation($0.url, url) }).map { [$0] } ?? findPath(roots)
        suppressSelection = true
        if let existing = path?.last, lease.map({ sameLocation(existing.lease.url, $0.url) }) ?? true {
            node = existing
        }
        else {
            node = FolderNode(url: url, lease: lease ?? FolderLease(url))
            roots.insert(node, at: 0)
            view.reloadData()
            path = [node]
        }
        let grantChanged = lease.map { node.lease !== $0 } ?? false
        if renewAccess || node.error != nil || (grantChanged && node.loading) {
            node.invalidate(lease: lease)
            if view.row(forItem: node) >= 0 { view.reloadItem(node, reloadChildren: true) }
        } else if let lease { node.lease = lease }
        for ancestor in (path ?? []).dropLast() {
            ancestor.expanded = true
            view.expandItem(ancestor)
        }
        let row = view.row(forItem: node)
        if row >= 0 { view.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        suppressSelection = false
        node.expanded = true
        load(node)
        view.expandItem(node)
        onSelect?(node)
    }

    func refresh(all: Bool = false) {
        suppressSelection = true
        let selected = view.item(atRow: view.selectedRow) as? FolderNode
        let nodes = all ? roots : selected.map { [$0] } ?? roots
        for node in nodes {
            node.invalidate()
            view.reloadItem(node, reloadChildren: true)
        }
        for node in nodes where node.expanded { load(node) }
        suppressSelection = false
    }

    private func load(_ node: FolderNode) {
        guard node.children == nil, !node.loading else { return }
        node.loading = true
        let token = node.requestID
        let lease = node.lease
        let reader = directoryReader
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak node] in
            guard let node else { return }
            let result = Result { try withExtendedLifetime(lease) { try reader(node.url) } }
            DispatchQueue.main.async {
                guard let self, node.requestID == token else { return }
                node.loading = false
                switch result {
                case .success(let urls):
                    node.children = urls.map { FolderNode(url: $0, lease: lease) }; node.error = nil
                case .failure(let error): node.children = []; node.error = FolderReader.errorMessage(for: error)
                }
                // A collapsed ancestor or refreshed tree may no longer contain this row.
                guard self.view.row(forItem: node) >= 0 else { return }
                self.suppressSelection = true
                self.view.reloadItem(node, reloadChildren: true)
                if node.expanded { self.view.expandItem(node) }
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
        return node.error != nil || node.children == nil || !(node.children?.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        if node.error != nil { node.invalidate() }
        node.expanded = true; load(node); return true
    }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        (item as? FolderNode)?.expanded = false
        return true
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
        let label = NSTextField(labelWithString: (node.error == nil ? "📁 " : "⚠︎ ") + node.title)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = node.error.map { $0 + "\n" + node.url.path } ?? node.url.path
        if node.error != nil { label.textColor = .systemRed }
        return label
    }
}
