import Compression
import Foundation

/// 윈도우에서 열어도 한글 파일명이 깨지지 않는 zip을 만든다.
///
/// macOS 기본 압축은 파일명을 NFD(자소 분리) 그대로, 인코딩 표시 없이 넣는다.
/// 그래서 윈도우 탐색기에서 풀면 이름이 깨지거나 'ㅎㅏㄴㄱㅡㄹ'처럼 보인다.
/// 여기서는 이름을 NFC로 바꾸고, 인코딩을 명확히 해서 넣는다. .DS_Store, __MACOSX 같은 맥 전용 파일은 뺀다.
public enum ZipNameEncoding: String, CaseIterable, Sendable {
    /// 이름을 CP949로 쓰고, UTF-8 이름도 확장 필드(0x7075)에 같이 넣는다. 한국어 윈도우, 알집·반디집 모두 호환.
    case windowsKorean
    /// 이름을 UTF-8로 쓰고 UTF-8 표시(비트 11)를 켠다. 윈도우 10 이상, 해외 사용자에게 보낼 때.
    case utf8

    public var title: String {
        switch self {
        case .windowsKorean: return "한국어 윈도우 호환 (CP949)"
        case .utf8: return "UTF-8 (윈도우 10 이상·해외)"
        }
    }
}

public enum ZipError: Error, CustomStringConvertible {
    case tooLarge(String)
    case cannotRead(String)
    case cannotWrite(String)
    case nothingToZip

    public var description: String {
        switch self {
        case .tooLarge(let p): return "4GB가 넘는 파일은 아직 지원하지 않아요: \(p)"
        case .cannotRead(let p): return "파일을 읽을 수 없어요: \(p)"
        case .cannotWrite(let p): return "압축 파일을 쓸 수 없어요: \(p)"
        case .nothingToZip: return "압축할 파일이 없어요."
        }
    }
}

public enum WindowsZip {
    /// 맥에서만 쓰는 파일. 압축에 넣지 않는다.
    public static func isMacJunk(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX" || name == "Icon\r" || name == ".localized"
    }

    /// 압축 파일을 둘 기본 위치. 항목 하나면 "이름.zip", 여러 개면 "압축파일.zip".
    public static func suggestedOutputPath(for items: [String]) -> String {
        let dir = PosixFS.parent(items[0])
        let base: String
        if items.count == 1 {
            let name = Hangul.nfc(PosixFS.lastComponent(items[0]))
            if PosixFS.type(of: items[0]) == .directory {
                base = name
            } else if let dot = name.lastIndex(of: "."), dot != name.startIndex {
                base = String(name[..<dot])
            } else {
                base = name
            }
        } else {
            base = "압축파일"
        }
        return NFCRenamer.uniquePath(in: dir, base: base, ext: "zip")
    }

    /// 항목들을 zip으로 묶는다. 넣은 항목 수를 돌려준다.
    @discardableResult
    public static func createArchive(of items: [String], to output: String, encoding: ZipNameEncoding) throws -> Int {
        var entries: [Entry] = []
        for item in items {
            collect(path: item, relative: Hangul.nfc(PosixFS.lastComponent(item)), into: &entries)
        }
        guard !entries.isEmpty else { throw ZipError.nothingToZip }

        try PosixFS.createEmptyFile(output)
        guard let handle = FileHandle(forWritingAtPath: output) else { throw ZipError.cannotWrite(output) }
        var writer = ArchiveWriter(handle: handle, encoding: encoding)
        do {
            for entry in entries { try writer.add(entry) }
            try writer.finish()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(output)
            throw error
        }
        return entries.count
    }

    // MARK: - 내부

    struct Entry {
        let source: String
        /// zip 안에서의 경로. NFC, "/" 구분. 폴더는 "/"로 끝난다.
        let name: String
        let isDirectory: Bool
        let modified: Date
    }

    private static func collect(path: String, relative: String, into entries: inout [Entry]) {
        guard let type = PosixFS.type(of: path) else { return }
        let modified = PosixFS.modificationDate(path) ?? Date()
        switch type {
        case .file:
            entries.append(Entry(source: path, name: relative, isDirectory: false, modified: modified))
        case .directory:
            entries.append(Entry(source: path, name: relative + "/", isDirectory: true, modified: modified))
            let children = PosixFS.names(in: path)
                .filter { !isMacJunk($0) }
                .sorted { Hangul.nfc($0) < Hangul.nfc($1) }
            for child in children {
                collect(path: PosixFS.join(path, child), relative: relative + "/" + Hangul.nfc(child), into: &entries)
            }
        case .symlink, .other:
            return
        }
    }

    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        let d = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let t = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        return (t, d)
    }

    static let cp949 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    /// 이름을 zip 헤더용 바이트로 바꾼다.
    static func encodeName(_ name: String, encoding: ZipNameEncoding) -> (bytes: [UInt8], utf8Flag: Bool, unicodeExtra: [UInt8]) {
        let utf8 = Array(name.utf8)
        if name.allSatisfy(\.isASCII) { return (utf8, false, []) }
        if encoding == .windowsKorean, let data = name.data(using: cp949, allowLossyConversion: false) {
            let primary = [UInt8](data)
            // Info-ZIP Unicode Path Extra Field
            var extra = ByteBuffer()
            extra.u16(0x7075)
            extra.u16(UInt16(1 + 4 + utf8.count))
            extra.u8(1)
            extra.u32(CRC32.checksum(primary))
            extra.bytes(utf8)
            return (primary, false, extra.data)
        }
        return (utf8, true, [])
    }
}

// MARK: - zip 파일 쓰기

private struct ArchiveWriter {
    let handle: FileHandle
    let encoding: ZipNameEncoding
    var offset: UInt64 = 0
    var central = ByteBuffer()
    var count = 0

    init(handle: FileHandle, encoding: ZipNameEncoding) {
        self.handle = handle
        self.encoding = encoding
    }

    mutating func write(_ bytes: [UInt8]) throws {
        // handle.write(_:)는 디스크가 꽉 차면 잡을 수 없는 예외로 앱을 죽인다. 오류를 던지는 판을 쓴다.
        try handle.write(contentsOf: Data(bytes))
        offset += UInt64(bytes.count)
    }

    mutating func add(_ entry: WindowsZip.Entry) throws {
        let (nameBytes, utf8Flag, extra) = WindowsZip.encodeName(entry.name, encoding: encoding)
        let (dosTime, dosDate) = WindowsZip.dosDateTime(entry.modified)
        let method: UInt16 = entry.isDirectory ? 0 : 8
        let flags: UInt16 = utf8Flag ? 0x0800 : 0
        guard offset <= UInt64(UInt32.max) else { throw ZipError.tooLarge(entry.source) }
        let headerOffset = offset

        var local = ByteBuffer()
        local.u32(0x0403_4B50)
        local.u16(20)
        local.u16(flags)
        local.u16(method)
        local.u16(dosTime)
        local.u16(dosDate)
        local.u32(0) // crc — 나중에 채움
        local.u32(0) // 압축 크기
        local.u32(0) // 원래 크기
        local.u16(UInt16(nameBytes.count))
        local.u16(UInt16(extra.count))
        local.bytes(nameBytes)
        local.bytes(extra)
        try write(local.data)

        var crc: UInt32 = 0
        var compressed: UInt64 = 0
        var uncompressed: UInt64 = 0

        if !entry.isDirectory {
            guard let input = FileHandle(forReadingAtPath: entry.source) else {
                throw ZipError.cannotRead(entry.source)
            }
            defer { try? input.close() }
            let out = handle
            let filter = try OutputFilter(.compress, using: .zlib) { chunk in
                if let chunk {
                    try out.write(contentsOf: chunk)
                    compressed += UInt64(chunk.count)
                }
            }
            var running = CRC32()
            while true {
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                running.update(chunk)
                uncompressed += UInt64(chunk.count)
                try filter.write(chunk)
            }
            try filter.finalize()
            crc = running.value
            offset += compressed
            if uncompressed > UInt64(UInt32.max) || compressed > UInt64(UInt32.max) {
                throw ZipError.tooLarge(entry.source)
            }

            // 헤더의 crc·크기 자리를 채운다.
            let end = offset
            var patch = ByteBuffer()
            patch.u32(crc)
            patch.u32(UInt32(compressed))
            patch.u32(UInt32(uncompressed))
            try handle.seek(toOffset: headerOffset + 14)
            try handle.write(contentsOf: Data(patch.data))
            try handle.seek(toOffset: end)
        }

        central.u32(0x0201_4B50)
        central.u16(20)           // 만든 곳: MS-DOS (윈도우가 속성을 그대로 읽게)
        central.u16(20)
        central.u16(flags)
        central.u16(method)
        central.u16(dosTime)
        central.u16(dosDate)
        central.u32(crc)
        central.u32(UInt32(compressed))
        central.u32(UInt32(uncompressed))
        central.u16(UInt16(nameBytes.count))
        central.u16(UInt16(extra.count))
        central.u16(0)            // 설명
        central.u16(0)            // 디스크 번호
        central.u16(0)            // 내부 속성
        central.u32(entry.isDirectory ? 0x10 : 0x20) // DOS 속성: 폴더 / 보관
        central.u32(UInt32(headerOffset))
        central.bytes(nameBytes)
        central.bytes(extra)
        count += 1
    }

    mutating func finish() throws {
        guard count <= Int(UInt16.max), offset <= UInt64(UInt32.max) else { throw ZipError.tooLarge("항목 수") }
        let centralOffset = offset
        try write(central.data)
        var end = ByteBuffer()
        end.u32(0x0605_4B50)
        end.u16(0)
        end.u16(0)
        end.u16(UInt16(count))
        end.u16(UInt16(count))
        end.u32(UInt32(central.data.count))
        end.u32(UInt32(centralOffset))
        end.u16(0)
        try write(end.data)
    }
}

struct ByteBuffer {
    var data: [UInt8] = []
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((v >> UInt32(shift)) & 0xFF)) }
    }
    mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
}

/// zip이 쓰는 CRC-32 (IEEE 802.3).
public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(UnsafeRawBufferPointer($0)) }
    }

    public mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = state
        Self.table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        state = c
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc = CRC32()
        bytes.withUnsafeBytes { crc.update($0) }
        return crc.value
    }
}
