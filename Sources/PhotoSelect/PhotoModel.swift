import Foundation
import CoreGraphics

struct Photo: Hashable {
    let url: URL
    static func accepts(_ url: URL) -> Bool {
        ["arw", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }
}

struct PhotoList {
    private(set) var photos: [Photo] = []
    private(set) var selectedIndex: Int?
    var selectedPhoto: Photo? { selectedIndex.map { photos[$0] } }

    mutating func replace(with photos: [Photo]) {
        self.photos = photos
        selectedIndex = photos.isEmpty ? nil : 0
    }
    @discardableResult
    mutating func select(_ index: Int) -> Bool {
        guard photos.indices.contains(index) else { return false }
        selectedIndex = index
        return true
    }
    @discardableResult
    mutating func remove(_ url: URL) -> Bool {
        guard let removed = photos.firstIndex(where: { $0.url == url }) else { return false }
        let selectedURL = selectedPhoto?.url
        photos.remove(at: removed)
        if photos.isEmpty { selectedIndex = nil }
        else if selectedURL == url { selectedIndex = min(removed, photos.count - 1) }
        else { selectedIndex = photos.firstIndex(where: { $0.url == selectedURL }) ?? 0 }
        return true
    }
}

// All coordinates here are in view points. One source pixel occupies 1/backingScale points.
enum ZoomGeometry {
    static func rect(image: CGSize, view: CGSize, cursor: CGPoint, backingScale: CGFloat) -> CGRect {
        let fit = min(view.width / image.width, view.height / image.height)
        let origin = CGPoint(x: (view.width - image.width * fit) / 2,
                             y: (view.height - image.height * fit) / 2)
        let u = min(1, max(0, (cursor.x - origin.x) / (image.width * fit)))
        let v = min(1, max(0, (cursor.y - origin.y) / (image.height * fit)))
        let size = CGSize(width: image.width / backingScale, height: image.height / backingScale)
        func offset(_ cursor: CGFloat, _ fraction: CGFloat, _ size: CGFloat, _ viewport: CGFloat) -> CGFloat {
            size <= viewport ? (viewport - size) / 2 : min(0, max(viewport - size, cursor - fraction * size))
        }
        return CGRect(x: offset(cursor.x, u, size.width, view.width),
                      y: offset(cursor.y, v, size.height, view.height), width: size.width, height: size.height)
    }
}

// The folder lease stays alive in every decode operation, including canceled operations
// whose synchronous system decoder has not returned yet.
final class FolderLease {
    let url: URL
    private let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

enum FolderReader {
    static func errorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let denied = (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.fileReadNoPermission.rawValue) ||
            (nsError.domain == NSPOSIXErrorDomain && [1, 13].contains(nsError.code))
        if denied {
            return "접근 권한이 필요합니다. ‘폴더 열기…’에서 이 폴더를 다시 선택해 주세요."
        }
        return error.localizedDescription
    }
    static func entries(_ url: URL, directories: Bool) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]).filter { item in
                let values = try item.resourceValues(forKeys: keys)
                // Do not follow symlinks outside the selected security scope.
                guard values.isSymbolicLink != true else { return false }
                return directories ? values.isDirectory == true : values.isRegularFile == true && Photo.accepts(item)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
