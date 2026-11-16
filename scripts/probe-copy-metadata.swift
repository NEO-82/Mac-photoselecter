import Foundation
import Darwin

// Only newly-created fixture directories are written; no input photo is used.
guard CommandLine.arguments.count == 2 else { fatalError("usage: probe-copy-metadata.swift <test volume>") }
let fm = FileManager.default
let sourceRoot = fm.temporaryDirectory.appendingPathComponent("J-S-metadata-source-" + UUID().uuidString)
let targetRoot = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("J-S-metadata-probe-" + UUID().uuidString)
try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
try fm.createDirectory(at: targetRoot, withIntermediateDirectories: false)
defer { try? fm.removeItem(at: sourceRoot); try? fm.removeItem(at: targetRoot) }
let source = sourceRoot.appendingPathComponent("source.ARW")
let data = Data("original data".utf8), marker = Data("metadata bytes".utf8)
try data.write(to: source)
let names = ["dev.photoselect.copy-test", "com.apple.ResourceFork"]
for name in names {
    let result = marker.withUnsafeBytes { setxattr(source.path, name, $0.baseAddress, $0.count, 0, 0) }
    print("COPY_METADATA_SOURCE_XATTR \(name) result=\(result) errno=\(result == 0 ? 0 : errno)")
}
func attributes(_ url: URL) -> String {
    names.map { name in
        let count = getxattr(url.path, name, nil, 0, 0, 0)
        return "\(name)=\(count)/errno\(count >= 0 ? 0 : errno)"
    }.joined(separator: " ")
}
let byPath = targetRoot.appendingPathComponent("path.ARW")
try data.write(to: byPath)
let pathResult = copyfile(source.path, byPath.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
let pathError = pathResult == 0 ? 0 : errno
print("COPY_METADATA_PATH result=\(pathResult) errno=\(pathError) \(attributes(byPath))")

let byFD = targetRoot.appendingPathComponent("fd.ARW")
let input = open(source.path, O_RDONLY | O_NOFOLLOW)
let output = open(byFD.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
guard input >= 0, output >= 0 else { fatalError("fixture descriptor creation failed") }
defer { close(input); close(output) }
_ = data.withUnsafeBytes { Darwin.write(output, $0.baseAddress, $0.count) }
let fdResult = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA))
let fdError = fdResult == 0 ? 0 : errno
print("COPY_METADATA_FD result=\(fdResult) errno=\(fdError) \(attributes(byFD))")

let full = targetRoot.appendingPathComponent("full.ARW")
let fullResult = copyfile(source.path, full.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW))
let fullError = fullResult == 0 ? 0 : errno
print("COPY_METADATA_ALL result=\(fullResult) errno=\(fullError) \(attributes(full))")

let direct = targetRoot.appendingPathComponent("direct.ARW")
try data.write(to: direct)
for name in names {
    let result = marker.withUnsafeBytes { setxattr(direct.path, name, $0.baseAddress, $0.count, 0, 0) }
    let error = result == 0 ? 0 : errno
    print("COPY_METADATA_SETXATTR \(name) result=\(result) errno=\(error)")
}
print("COPY_METADATA_DIRECT \(attributes(direct))")

var rootBefore = stat(); _ = lstat(targetRoot.path, &rootBefore)
let growth = targetRoot.appendingPathComponent("growth.ARW")
let growing = open(growth.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
guard growing >= 0 else { fatalError("growth fixture creation failed") }
defer { close(growing) }
var before = stat(), after = stat(), named = stat(), rootAfter = stat()
_ = fstat(growing, &before)
let buffer = Data(repeating: 73, count: 1024 * 1024)
_ = buffer.withUnsafeBytes { Darwin.write(growing, $0.baseAddress, $0.count) }
_ = fsync(growing)
_ = fstat(growing, &after); _ = lstat(growth.path, &named); _ = lstat(targetRoot.path, &rootAfter)
print("COPY_FILE_IDS before=\(before.st_ino) after=\(after.st_ino) path=\(named.st_ino) directoryBefore=\(rootBefore.st_ino) directoryAfter=\(rootAfter.st_ino)")
