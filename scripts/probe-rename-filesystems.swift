import Foundation
import Darwin
import CoreServices

func identity(_ url: URL) throws -> String {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
    return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
}
func native(_ source: URL, _ destination: URL) throws {
    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
func carbonRename(_ source: URL, _ destination: URL) throws {
    var ref = FSRef(), result = FSRef()
    let status = source.withUnsafeFileSystemRepresentation { ptr in
        FSPathMakeRef(UnsafeRawPointer(ptr!).assumingMemoryBound(to: UInt8.self), &ref, nil)
    }
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    let name = Array(destination.lastPathComponent.utf16)
    let renamed = name.withUnsafeBufferPointer {
        FSRenameUnicode(&ref, UniCharCount($0.count), $0.baseAddress, TextEncoding(kTextEncodingUnknown), &result)
    }
    guard renamed == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(renamed)) }
}
func carbonMove(_ source: URL, _ destination: URL) throws {
    let status = FSPathMoveObjectSync(source.path, destination.deletingLastPathComponent().path,
        destination.lastPathComponent as CFString, nil, OptionBits(kFSFileOperationDoNotMoveAcrossVolumes))
    guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let work = root.appendingPathComponent("J-S-probe-" + UUID().uuidString)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: work) }
var results: [[String: Any]] = []
for (label, operation) in [("renamex-RENAME_EXCL", native), ("FSRenameUnicode", carbonRename), ("FSPathMoveObjectSync-no-overwrite", carbonMove)] {
    let source = work.appendingPathComponent(label + ".ARW"), target = work.appendingPathComponent(label + "-destination.ARW")
    let a = Data("source".utf8), b = Data("occupied".utf8)
    try a.write(to: source); try b.write(to: target)
    var row: [String: Any] = ["api": label, "volume": root.lastPathComponent]
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
