import Foundation
import Darwin

func identity(_ url: URL) throws -> String {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
    return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
}
func native(_ source: URL, _ destination: URL) throws {
    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
func relativeRename(_ source: URL, _ destination: URL) throws {
    let fd = Darwin.open(source.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
    guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
    if renameatx_np(fd, source.lastPathComponent, fd, destination.lastPathComponent, UInt32(RENAME_EXCL)) != 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
func linkProbe(_ source: URL, _ destination: URL) throws {
    if link(source.path, destination.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    if unlink(source.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
func capabilities(_ folder: URL) -> [String: Any] {
    var list = attrlist(); list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); list.volattr = (UInt32(ATTR_VOL_CAPABILITIES) | UInt32(ATTR_VOL_INFO))
    var words = [UInt32](repeating: 0, count: 9)
    let result = words.withUnsafeMutableBytes { getattrlist(folder.path, &list, $0.baseAddress!, $0.count, 0) }
    guard result == 0, words[0] >= 36 else { return ["capabilitiesAvailable": false] }
    return ["capabilitiesAvailable": true, "formatFlags": words[1], "interfaceFlags": words[2],
            "validFormatFlags": words[5], "validInterfaceFlags": words[6],
            "exclusiveRename": words[2] & UInt32(VOL_CAP_INT_RENAME_EXCL) != 0,
            "persistentFileIDs": words[1] & UInt32(VOL_CAP_FMT_PERSISTENTOBJECTIDS) != 0,
            "hardLinks": words[1] & UInt32(VOL_CAP_FMT_HARDLINKS) != 0]
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let work = root.appendingPathComponent("J-S-probe-" + UUID().uuidString)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: work) }
var results: [[String: Any]] = []
for (label, operation) in [("renamex-RENAME_EXCL", native), ("renameatx-RENAME_EXCL", relativeRename), ("link-unlink-diagnostic-only", linkProbe)] {
    let source = work.appendingPathComponent(label + ".ARW"), target = work.appendingPathComponent(label + "-destination.ARW")
    let a = Data("source".utf8), b = Data("occupied".utf8)
    try a.write(to: source); try b.write(to: target)
    var row: [String: Any] = ["api": label, "volume": root.lastPathComponent, "capabilities": capabilities(root)]
    do { try operation(source, target); row["collision"] = "UNSAFE-SUCCESS" }
    catch { row["collision"] = "\((error as NSError).domain):\((error as NSError).code)" }
    row["collisionPreserved"] = (try? Data(contentsOf: source)) == a && (try? Data(contentsOf: target)) == b
    try FileManager.default.removeItem(at: target)
    if (try? Data(contentsOf: source)) != a { try a.write(to: source) }
    let before = try identity(source)
    do {
        try operation(source, target)
        row["move"] = "success"; row["identityStable"] = try identity(target) == before
        row["bytesPreserved"] = try Data(contentsOf: target) == a
    } catch { row["move"] = "\((error as NSError).domain):\((error as NSError).code):\(error.localizedDescription)" }
    print(row)
    results.append(row)
}
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output)
