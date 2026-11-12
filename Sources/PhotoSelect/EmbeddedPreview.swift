import Foundation
import CoreGraphics

enum EmbeddedColorSpace: Equatable { case sRGB, adobeRGB }

struct EmbeddedJPEG {
    let data: Data
    let orientation: UInt32
    let sensorSize: CGSize?
    let pixelWidth: Int
    let pixelHeight: Int
    let colorSpaceHint: EmbeddedColorSpace?
}

// ARW is a classic TIFF container. Read compressed camera JPEG bytes only: this
// code never asks an image framework to demosaic the sensor data. Sony's IFD0
// 0x201/0x202 preview is distinct from IFD1's much smaller thumbnail. Newer Sony
// MakerNote 0x2001 previews have a 32-byte prefix before the JPEG stream.
enum EmbeddedPreview {
    static let minimumLongEdge = 1600

    enum Failure: LocalizedError {
        case invalidContainer, noHighResolutionJPEG, resourceLimit
        var errorDescription: String? {
            switch self {
            case .invalidContainer: return "ARW의 TIFF 구조를 읽을 수 없습니다. 파일이 손상되었거나 지원하지 않는 형식입니다."
            case .noHighResolutionJPEG:
                return "이 ARW에서 고해상도 내장 JPEG 프리뷰를 찾지 못했습니다. 작은 썸네일을 확대하거나 RAW를 자동 현상하지 않습니다."
            case .resourceLimit: return "ARW 프리뷰 구조가 안전한 읽기 한도를 초과했습니다. RAW를 자동 현상하지 않습니다."
            }
        }
    }

    static func extract(from url: URL) throws -> EmbeddedJPEG {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Covers current Sony RAW sizes while bounding malformed-file work and
        // avoiding a permanent in-memory copy of the entire sensor payload.
        guard data.count <= 1024 * 1024 * 1024 else { throw Failure.resourceLimit }
        let parsed = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Parsed in
            var parser = try Parser(bytes: bytes)
            return try parser.extract()
        }
        return EmbeddedJPEG(data: data.subdata(in: parsed.range), orientation: parsed.orientation,
                            sensorSize: parsed.sensorSize, pixelWidth: parsed.width, pixelHeight: parsed.height, colorSpaceHint: parsed.colorSpaceHint)
    }

    private struct Parsed {
        let range: Range<Int>
        let width: Int
        let height: Int
        let orientation: UInt32
        let sensorSize: CGSize?
        let colorSpaceHint: EmbeddedColorSpace?
    }
    private struct Candidate {
        let range: Range<Int>
        let width: Int
        let height: Int
        var area: Int { width * height }
    }
    private struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        let slot: Int
    }

    private struct Parser {
        let bytes: UnsafeRawBufferPointer
        let littleEndian: Bool
        var remainingWork: Int
        var ranges: Set<Range<Int>> = []
        var inspectedStarts: [Int: Int] = [:]
        var candidates: [Candidate] = []
        var orientation: UInt32 = 1
        var rootWidth: Int?, rootHeight: Int?
        var exifWidth: Int?, exifHeight: Int?
        var rawWidth: Int?, rawHeight: Int?
        var exifColorSpace: Int?
        var interoperabilityIndex: String?

        init(bytes: UnsafeRawBufferPointer) throws {
            guard bytes.count >= 8 else { throw Failure.invalidContainer }
            if bytes[0] == 0x49 && bytes[1] == 0x49 { littleEndian = true }
            else if bytes[0] == 0x4D && bytes[1] == 0x4D { littleEndian = false }
            else { throw Failure.invalidContainer }
            self.bytes = bytes
            remainingWork = max(4096, bytes.count * 4)
            guard u16(2) == 42, let first = u32(4), first >= 8, contains(first, 2) else {
                throw Failure.invalidContainer
            }
        }

        func contains(_ offset: Int, _ count: Int) -> Bool {
            offset >= 0 && count >= 0 && offset <= bytes.count && count <= bytes.count - offset
        }
        func u16(_ offset: Int) -> Int? {
            guard contains(offset, 2) else { return nil }
            return littleEndian ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 :
                Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        func u32(_ offset: Int) -> Int? {
            guard contains(offset, 4) else { return nil }
            if littleEndian {
                return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
            }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        func big16(_ offset: Int) -> Int {
            Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        func values(_ entry: Entry) -> [Int] {
            // Only integer offset/dimension types are interpreted. Floating
            // values, arbitrary TIFF counts and signed offsets are not pointers.
            let size: Int
            if entry.type == 3 { size = 2 }
            else if entry.type == 4 || entry.type == 13 { size = 4 }
            else { return [] }
            guard entry.count > 0, entry.count <= 1024 else { return [] }
            let length = entry.count * size
            guard let start = length <= 4 ? entry.slot : u32(entry.slot), contains(start, length) else { return [] }
            return (0..<entry.count).compactMap { size == 2 ? u16(start + $0 * size) : u32(start + $0 * size) }
        }
        func payload(_ entry: Entry) -> Range<Int>? {
            guard entry.type == 1 || entry.type == 7, entry.count > 4,
                  let offset = u32(entry.slot), contains(offset, entry.count) else { return nil }
            return offset..<(offset + entry.count)
        }
        mutating func addRange(offset: Int?, length: Int?) {
            guard let offset, let length, length > 0, contains(offset, length), ranges.count < 512 else { return }
            ranges.insert(offset..<(offset + length))
        }

        func ascii(_ entry: Entry) -> String? {
            guard entry.type == 2, entry.count > 0, entry.count <= 64,
                  let start = entry.count <= 4 ? entry.slot : u32(entry.slot), contains(start, entry.count) else { return nil }
            return String(bytes: bytes[start..<(start + entry.count)].prefix { $0 != 0 }, encoding: .ascii)
        }

        mutating func extract() throws -> Parsed {
            guard let first = u32(4) else { throw Failure.invalidContainer }
            var pending: [(offset: Int, root: Bool)] = [(first, true)]
            var visited: Set<Int> = []
            var entryBudget = 16384
            while !pending.isEmpty && visited.count < 64 {
                let current = pending.removeFirst()
                guard visited.insert(current.offset).inserted,
                      let count = u16(current.offset), count <= 4096, count <= entryBudget,
                      contains(current.offset + 2, count * 12 + 4) else { continue }
                entryBudget -= count
                var entries: [Int: Entry] = [:]
                for index in 0..<count {
                    let start = current.offset + 2 + index * 12
                    guard let tag = u16(start), let type = u16(start + 2), let count = u32(start + 4) else { continue }
                    entries[tag] = Entry(tag: tag, type: type, count: count, slot: start + 8)
                }
                func scalar(_ tag: Int) -> Int? { entries[tag].flatMap { values($0).first } }
                if current.root {
                    rootWidth = scalar(0x100); rootHeight = scalar(0x101)
                    if let value = scalar(0x112), (1...8).contains(value) { orientation = UInt32(value) }
                } else if let width = scalar(0x100), let height = scalar(0x101),
                          width > (rawWidth ?? 0), height > (rawHeight ?? 0) {
                    rawWidth = width; rawHeight = height
                }
                if let width = scalar(0xA002), let height = scalar(0xA003) {
                    exifWidth = width; exifHeight = height
                }
                if let value = scalar(0xA001) { exifColorSpace = value }
                if let entry = entries[0x1], let value = ascii(entry), ["R03", "R98"].contains(value) { interoperabilityIndex = value }
                addRange(offset: scalar(0x201), length: scalar(0x202))
                // Some TIFF containers store the JPEG as a compressed strip.
                if [6, 7].contains(scalar(0x103) ?? 0), let offsets = entries[0x111], let lengths = entries[0x117] {
                    for (offset, length) in zip(values(offsets), values(lengths)) { addRange(offset: offset, length: length) }
                }
                if let preview = entries[0x2001], let range = payload(preview) { ranges.insert(range) }
                for tag in [0x14A, 0x8769, 0xA005] {
                    if let entry = entries[tag] {
                        for offset in values(entry) where contains(offset, 2) && pending.count < 64 { pending.append((offset, false)) }
                    }
                }
                if let note = entries[0x927C], let range = payload(note) {
                    ranges.insert(range)
                    // Sony IFD offsets inherit the TIFF byte order and base.
                    // ARW/SR2 can start directly at the IFD; DSC/CAM/MOBILE and
                    // \0\0SONY PIC/VHAB variants carry a 12-byte prefix.
                    let prefix = String(bytes: bytes[range.lowerBound..<min(range.upperBound, range.lowerBound + 12)], encoding: .ascii) ?? ""
                    let header = prefix.hasPrefix("SONY DSC") || prefix.hasPrefix("SONY CAM") ||
                        prefix.hasPrefix("SONY MOBILE") || prefix.hasPrefix("\0\0SONY PIC") || prefix.hasPrefix("VHAB")
                    let start = range.lowerBound + (header ? 12 : 0)
                    if contains(start, 2), pending.count < 64 { pending.append((start, false)) }
                }
                if let next = u32(current.offset + 2 + count * 12), next > 0,
                   contains(next, 2), pending.count < 64 { pending.append((next, false)) }
            }
            if pending.contains(where: { !visited.contains($0.offset) }) { throw Failure.resourceLimit }
            // Read declared preview/MakerNote regions first. Ordinary Sony ARWs
            // do not need a full sensor-payload scan for each thumbnail request.
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) { try scan(range) }
            if !candidates.contains(where: { max($0.width, $0.height) >= EmbeddedPreview.minimumLongEdge }) {
                // Recovery for unrecognised Sony metadata layouts. The same
                // byte/marker budget also covers corrupt overlapping candidates.
                try scan(8..<bytes.count)
            }
            guard let best = candidates.filter({ max($0.width, $0.height) >= EmbeddedPreview.minimumLongEdge })
                .max(by: { $0.area == $1.area ? $0.range.count < $1.range.count : $0.area < $1.area }) else {
                throw Failure.noHighResolutionJPEG
            }
            let width = exifWidth ?? rawWidth ?? rootWidth
            let height = exifHeight ?? rawHeight ?? rootHeight
            let size: CGSize?
            if let width, let height, width > 0, height > 0, width <= 100000, height <= 100000 {
                size = CGSize(width: width, height: height)
            } else { size = nil }
            let hint: EmbeddedColorSpace?
            if exifColorSpace == 1 || interoperabilityIndex == "R98" { hint = .sRGB }
            else if exifColorSpace == 65535 && interoperabilityIndex == "R03" { hint = .adobeRGB }
            else { hint = nil }
            return Parsed(range: best.range, width: best.width, height: best.height, orientation: orientation,
                          sensorSize: size, colorSpaceHint: hint)
        }

        mutating func spend(_ amount: Int) throws {
            guard amount <= remainingWork else { throw Failure.resourceLimit }
            remainingWork -= amount
        }
        mutating func scan(_ range: Range<Int>) throws {
            var position = range.lowerBound
            var accounted = position
            while position + 2 < range.upperBound {
                if position - accounted >= 4096 { try spend(position - accounted); accounted = position }
                if bytes[position] == 0xFF && bytes[position + 1] == 0xD8 && bytes[position + 2] == 0xFF {
                    if (inspectedStarts[position] ?? 0) < range.upperBound {
                        guard inspectedStarts.count < 4096 || inspectedStarts[position] != nil else { throw Failure.resourceLimit }
                        inspectedStarts[position] = range.upperBound
                        if let candidate = try jpeg(at: position, limit: range.upperBound) {
                            candidates.append(candidate); inspectedStarts[position] = Int.max
                        }
                    }
                    position += 3
                } else { position += 1 }
            }
            try spend(position - accounted)
        }

        mutating func jpeg(at start: Int, limit outerLimit: Int) throws -> Candidate? {
            // Large current-camera JPEGs fit below 128 MiB. A corrupt stream
            // cannot force traversal of the rest of a multi-gigabyte container.
            let limit = min(outerLimit, start + 128 * 1024 * 1024)
            var position = start + 2
            var width = 0, height = 0
            var inEntropy = false, sawScan = false
            var markers = 0
            while position < limit {
                if inEntropy {
                    let initial = position
                    while position < limit && bytes[position] != 0xFF { position += 1 }
                    try spend(position - initial)
                    guard position + 1 < limit else { return nil }
                    let markerStart = position
                    while position < limit && bytes[position] == 0xFF { position += 1 }
                    guard position < limit else { return nil }
                    let marker = bytes[position]
                    try spend(position - markerStart + 1)
                    if marker == 0 || (0xD0...0xD7).contains(marker) { position += 1; continue }
                    position = markerStart; inEntropy = false
                }
                guard position + 1 < limit, bytes[position] == 0xFF else { return nil }
                while position < limit && bytes[position] == 0xFF { position += 1; try spend(1) }
                guard position < limit else { return nil }
                let marker = bytes[position]; position += 1; markers += 1
                guard markers <= 65536 else { throw Failure.resourceLimit }
                if marker == 0xD9 {
                    guard width > 0, height > 0, sawScan else { return nil }
                    return Candidate(range: start..<position, width: width, height: height)
                }
                if marker == 0x01 { continue }
                guard marker != 0 && marker != 0xD8 && !(0xD0...0xD7).contains(marker), position + 2 <= limit else { return nil }
                let length = big16(position)
                guard length >= 2, length <= limit - position else { return nil }
                let isFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
                if isFrame {
                    guard length >= 8 else { return nil }
                    let components = Int(bytes[position + 7])
                    guard (1...4).contains(components), length >= 8 + components * 3 else { return nil }
                    let h = big16(position + 3), w = big16(position + 5)
                    guard h > 0, w > 0, w * h <= 200000000 else { return nil }
                    if width != 0 && (width != w || height != h) { return nil }
                    width = w; height = h
                }
                if marker == 0xDA {
                    guard width > 0, height > 0, length >= 6 else { return nil }
                    let components = Int(bytes[position + 2])
                    guard (1...4).contains(components), length >= 6 + components * 2 else { return nil }
                    inEntropy = true; sawScan = true
                }
                position += length
                try spend(length)
            }
            return nil
        }
    }
}
