import Compression
import Foundation

/// 윈도우에서 만든 zip을 한글 파일명이 깨지지 않게 푼다.
///
/// 한국어 윈도우(탐색기·알집·반디집 기본값)는 파일명을 CP949로 쓰고 인코딩 표시를 하지 않는다.
/// 맥 기본 '압축 해제'는 이를 다른 인코딩으로 읽어서 `ÇÑ±Û.txt` 같은 이름이 된다.
/// 여기서는 이름마다 UTF-8 표시 → 유니코드 경로 확장 필드(0x7075) → UTF-8로 읽히는지 → CP949 순서로 판단한다.
public enum ZipExtract {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notZip
        case encrypted(String)
        case unsupportedMethod(String, Int)
        case corrupt(String)
        case cannotWrite(String)

        public var description: String {
            switch self {
            case .notZip: return "zip 파일이 아니거나 손상됐어요."
            case .encrypted(let n): return "암호가 걸린 파일은 풀 수 없어요: \(n)"
            case .unsupportedMethod(let n, let m): return "지원하지 않는 압축 방식(\(m))이에요: \(n)"
            case .corrupt(let n): return "손상된 항목이 있어요: \(n)"
            case .cannotWrite(let p): return "파일을 쓸 수 없어요: \(p)"
            }
        }
    }

    public struct Entry: Equatable {
        public let name: String
        public let isDirectory: Bool
        public let method: Int
        public let flags: Int
        public let crc: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
        public let modified: Date?
        public let isSymlink: Bool
    }

    public struct Result: Equatable {
        public let folder: String
        public let files: Int
        public let skipped: [String]
    }

    // MARK: 이름 해석

    /// zip에 들어 있는 이름 바이트를 사람이 읽을 이름으로.
    /// - Parameter preferCP949: 표시 없는 한글 이름을 CP949로 먼저 읽을지(압축 파일 전체를 보고 정한다).
    ///   CP949의 일부 글자(회·화·호 등)는 우연히 올바른 UTF-8이기도 해서, 항목마다 따로 판단하면 틀린다.
    public static func decodeName(_ raw: [UInt8], flags: Int, extra: [UInt8], preferCP949: Bool = true) -> String {
        if flags & 0x0800 != 0, let s = String(bytes: raw, encoding: .utf8) { return s }
        if let unicode = unicodePath(in: extra, matching: raw) { return unicode }
        if raw.allSatisfy({ $0 < 0x80 }) { return String(decoding: raw, as: UTF8.self) }
        let utf8 = String(bytes: raw, encoding: .utf8)
        let cp949 = String(data: Data(raw), encoding: WindowsZip.cp949)
        if let s = preferCP949 ? (cp949 ?? utf8) : (utf8 ?? cp949) { return s }
        // 마지막 수단: 깨지더라도 읽을 수 있게.
        return String(data: Data(raw), encoding: .isoLatin1) ?? String(decoding: raw, as: UTF8.self)
    }

    /// 압축 파일 전체를 보고 표시 없는 이름의 인코딩을 정한다.
    /// 올바른 UTF-8이 아닌 이름이 하나라도 있으면 CP949, 모두 UTF-8로 읽히면 만든 곳(윈도우/유닉스)으로 판단.
    static func prefersCP949(_ names: [(raw: [UInt8], flags: Int, extra: [UInt8], host: Int)]) -> Bool {
        let unmarked = names.filter { n in
            n.flags & 0x0800 == 0 && !n.raw.allSatisfy({ $0 < 0x80 }) && unicodePath(in: n.extra, matching: n.raw) == nil
        }
        guard !unmarked.isEmpty else { return false }
        if unmarked.contains(where: { String(bytes: $0.raw, encoding: .utf8) == nil }) { return true }
        guard unmarked.allSatisfy({ String(data: Data($0.raw), encoding: WindowsZip.cp949) != nil }) else { return false }
        // 0 = MS-DOS(FAT), 11 = NTFS, 14 = VFAT: 윈도우에서 만든 압축
        let windowsHosts: Set<Int> = [0, 11, 14]
        return unmarked.filter { windowsHosts.contains($0.host) }.count * 2 > unmarked.count
    }

    /// Info-ZIP 유니코드 경로(0x7075). 원래 이름의 CRC가 맞을 때만 쓴다.
    static func unicodePath(in extra: [UInt8], matching raw: [UInt8]) -> String? {
        var i = 0
        while i + 4 <= extra.count {
            let id = Int(extra[i]) | Int(extra[i + 1]) << 8
            let size = Int(extra[i + 2]) | Int(extra[i + 3]) << 8
            let start = i + 4
            guard start + size <= extra.count else { return nil }
            if id == 0x7075, size >= 5, extra[start] == 1 {
                let crc = UInt32(extra[start + 1]) | UInt32(extra[start + 2]) << 8 | UInt32(extra[start + 3]) << 16 | UInt32(extra[start + 4]) << 24
                if crc == CRC32.checksum(raw) {
                    return String(bytes: extra[(start + 5)..<(start + size)], encoding: .utf8)
                }
            }
            i = start + size
        }
        return nil
    }

    /// 압축 안의 경로를 안전한 상대 경로 조각으로. 위로 올라가거나(..) 절대 경로면 그 부분을 버린다.
    public static func safeComponents(_ name: String) -> [String] {
        name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .map { Hangul.nfc($0).replacingOccurrences(of: ":", with: "_") }
    }

    // MARK: 목록 읽기

    public static func entries(of path: String) throws -> [Entry] {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure.notZip }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw Failure.notZip }

        // 끝에서 중앙 디렉터리 끝 레코드(EOCD)를 찾는다. 설명이 붙으면 최대 64KB 앞.
        let tailLength = min(size, 22 + 65_535)
        try handle.seek(toOffset: size - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            tail[$0] == 0x50 && tail[$0 + 1] == 0x4B && tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06
        }) else { throw Failure.notZip }

        var count = UInt64(le16(tail, eocd + 10))
        var cdSize = UInt64(le32(tail, eocd + 12))
        var cdOffset = UInt64(le32(tail, eocd + 16))

        // ZIP64: 값이 꽉 차 있으면 ZIP64 EOCD를 본다.
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocd >= 20,
           le32(tail, eocd - 20) == 0x0706_4B50 {
            let z64Offset = le64(tail, eocd - 20 + 8)
            try handle.seek(toOffset: z64Offset)
            let z = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard z.count >= 56, le32(z, 0) == 0x0606_4B50 else { throw Failure.notZip }
            count = le64(z, 32)
            cdSize = le64(z, 40)
            cdOffset = le64(z, 48)
        }
        let (cdEnd, overflow) = cdOffset.addingReportingOverflow(cdSize)
        guard !overflow, cdEnd <= size, cdSize < 512 << 20 else { throw Failure.notZip }
        try handle.seek(toOffset: cdOffset)
        let cd = [UInt8](try handle.read(upToCount: Int(cdSize)) ?? Data())
        guard cd.count == Int(cdSize) else { throw Failure.notZip }

        struct Raw { let name: [UInt8]; let extra: [UInt8]; let flags: Int; let host: Int; let method: Int
                     let time: UInt16; let date: UInt16; let crc: UInt32; let compressed: UInt64; let uncompressed: UInt64
                     let external: UInt32; let offset: UInt64 }
        var raws: [Raw] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, le32(cd, p) == 0x0201_4B50 else { throw Failure.notZip }
            let madeBy = Int(le16(cd, p + 4)) >> 8
            let flags = Int(le16(cd, p + 8))
            let method = Int(le16(cd, p + 10))
            let time = le16(cd, p + 12), date = le16(cd, p + 14)
            let crc = le32(cd, p + 16)
            var compressed = UInt64(le32(cd, p + 20))
            var uncompressed = UInt64(le32(cd, p + 24))
            let nameLen = Int(le16(cd, p + 28)), extraLen = Int(le16(cd, p + 30)), commentLen = Int(le16(cd, p + 32))
            let external = le32(cd, p + 38)
            var offset = UInt64(le32(cd, p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen + commentLen <= cd.count else { throw Failure.notZip }
            let rawName = Array(cd[nameStart..<(nameStart + nameLen)])
            let extra = Array(cd[(nameStart + nameLen)..<(nameStart + nameLen + extraLen)])

            // ZIP64 확장 필드(0x0001): 꽉 찬 값만 순서대로 들어 있다.
            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || offset == 0xFFFF_FFFF,
               let z = field(0x0001, in: extra) {
                var q = 0
                if uncompressed == 0xFFFF_FFFF, q + 8 <= z.count { uncompressed = le64(z, q); q += 8 }
                if compressed == 0xFFFF_FFFF, q + 8 <= z.count { compressed = le64(z, q); q += 8 }
                if offset == 0xFFFF_FFFF, q + 8 <= z.count { offset = le64(z, q) }
            }

            // 조작된 값으로 범위를 벗어나면 손상으로 본다.
            guard offset < size, compressed <= size else { throw Failure.notZip }
            raws.append(Raw(name: rawName, extra: extra, flags: flags, host: madeBy, method: method, time: time, date: date,
                            crc: crc, compressed: compressed, uncompressed: uncompressed, external: external, offset: offset))
            p = nameStart + nameLen + extraLen + commentLen
        }

        let cp949First = prefersCP949(raws.map { ($0.name, $0.flags, $0.extra, $0.host) })
        var result: [Entry] = []
        for r in raws {
            let name = decodeName(r.name, flags: r.flags, extra: r.extra, preferCP949: cp949First)
            let isDir = name.hasSuffix("/") || name.hasSuffix("\\") || (r.host == 0 && r.external & 0x10 != 0)
            // 유닉스에서 만든 항목의 심볼릭 링크(S_IFLNK)는 풀지 않는다(압축 밖을 가리킬 수 있음).
            let isLink = r.host == 3 && (r.external >> 16) & 0o170000 == 0o120000
            result.append(Entry(name: name, isDirectory: isDir, method: r.method, flags: r.flags, crc: r.crc,
                                compressedSize: r.compressed, uncompressedSize: r.uncompressed,
                                localHeaderOffset: r.offset, modified: dosDate(time: r.time, date: r.date), isSymlink: isLink))
        }
        return result
    }

    // MARK: 풀기

    /// zip 옆에 같은 이름 폴더를 만들어 푼다. 이미 있으면 "이름 2" 식으로.
    public static func extract(_ zipPath: String, into parent: String? = nil) throws -> Result {
        let list = try entries(of: zipPath)
        let dir = parent ?? PosixFS.parent(zipPath)
        var base = Hangul.nfc(PosixFS.lastComponent(zipPath))
        if base.lowercased().hasSuffix(".zip") { base = String(base.dropLast(4)) }
        if base.isEmpty { base = "압축 해제" }

        // 모든 항목이 같은 최상위 폴더 하나에 들어 있으면 그 폴더를 그대로 쓴다(폴더 안에 폴더가 생기지 않게).
        let usable = list.filter { !$0.isSymlink && !isJunk($0.name) }
        let tops = Set(usable.compactMap { safeComponents($0.name).first })
        let singleRoot = tops.count == 1 && usable.allSatisfy { safeComponents($0.name).count > 1 || $0.isDirectory }
        let rootName = singleRoot ? tops.first! : base
        let root = uniqueFolder(in: dir, name: rootName)
        guard mkdirs(root) else { throw Failure.cannotWrite(root) }

        guard let handle = FileHandle(forReadingAtPath: zipPath) else { throw Failure.notZip }
        defer { try? handle.close() }

        var files = 0
        var skipped: [String] = []
        do {
            for entry in list {
                if entry.isSymlink || isJunk(entry.name) { skipped.append(entry.name); continue }
                var parts = safeComponents(entry.name)
                if singleRoot { parts = Array(parts.dropFirst()) }
                guard !parts.isEmpty else { continue }
                let target = parts.reduce(root) { PosixFS.join($0, $1) }
                if entry.isDirectory {
                    guard mkdirs(target) else { throw Failure.cannotWrite(target) }
                    continue
                }
                guard entry.flags & 0x1 == 0 else { throw Failure.encrypted(entry.name) }
                guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupportedMethod(entry.name, entry.method) }
                guard mkdirs(PosixFS.parent(target)) else { throw Failure.cannotWrite(target) }
                let written = try writeEntry(entry, from: handle, to: target)
                if let date = entry.modified {
                    var times = [timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0),
                                 timespec(tv_sec: Int(date.timeIntervalSince1970), tv_nsec: 0)]
                    _ = utimensat(AT_FDCWD, written, &times, 0)
                }
                files += 1
            }
        } catch {
            // 반쯤 풀린 폴더를 남기지 않는다(이번에 새로 만든 폴더라 지워도 안전).
            try? FileManager.default.removeItem(atPath: root)
            throw error
        }
        return Result(folder: root, files: files, skipped: skipped)
    }

    private static func isJunk(_ name: String) -> Bool {
        safeComponents(name).contains { WindowsZip.isMacJunk($0) || $0 == "Thumbs.db" || $0 == "desktop.ini" }
    }

    /// 실제로 쓴 경로를 돌려준다(같은 이름이 이미 있으면 "이름 2.확장자").
    private static func writeEntry(_ entry: Entry, from handle: FileHandle, to wanted: String) throws -> String {
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, le32(header, 0) == 0x0403_4B50 else { throw Failure.corrupt(entry.name) }
        let skip = UInt64(le16(header, 26)) + UInt64(le16(header, 28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + skip)   // offset < 파일 크기라 넘치지 않음

        // 이름은 NFC 그대로 남기려고 POSIX open을 쓴다(FileManager는 자소를 나눌 수 있음).
        // 대소문자만 다른 이름처럼 이미 있으면 번호를 붙인다(덮어쓰지 않음).
        var target = wanted
        var fd = open(target, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        var n = 2
        while fd < 0 && errno == EEXIST && n < 1000 {
            let name = PosixFS.lastComponent(wanted)
            let dot = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 }
            let alt = dot.map { "\(name[..<$0]) \(n)\(name[$0...])" } ?? "\(name) \(n)"
            target = PosixFS.join(PosixFS.parent(wanted), alt)
            fd = open(target, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            n += 1
        }
        guard fd >= 0 else { throw Failure.cannotWrite(target) }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var ok = false
        defer {
            try? out.close()
            if !ok { unlink(target) }
        }

        var crc = CRC32()
        var written: UInt64 = 0
        func emit(_ data: Data) throws {
            crc.update(data)
            written += UInt64(data.count)
            guard written <= entry.uncompressedSize else { throw Failure.corrupt(entry.name) }
            do { try out.write(contentsOf: data) } catch { throw Failure.cannotWrite(target) }
        }

        var remaining = entry.compressedSize
        if entry.method == 0 {
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else { throw Failure.corrupt(entry.name) }
                remaining -= UInt64(chunk.count)
                try emit(chunk)
            }
        } else {
            var pending: Error?
            let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
                guard let chunk, pending == nil else { return }
                do { try emit(chunk) } catch { pending = error }
            }
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else { throw Failure.corrupt(entry.name) }
                remaining -= UInt64(chunk.count)
                do { try filter.write(chunk) } catch { throw Failure.corrupt(entry.name) }
                if let pending { throw pending }
            }
            do { try filter.finalize() } catch { throw Failure.corrupt(entry.name) }
            if let pending { throw pending }
        }
        guard written == entry.uncompressedSize, crc.value == entry.crc else { throw Failure.corrupt(entry.name) }
        ok = true
        return target
    }

    private static func uniqueFolder(in dir: String, name: String) -> String {
        var candidate = PosixFS.join(dir, name)
        var n = 2
        while PosixFS.exists(candidate) {
            candidate = PosixFS.join(dir, "\(name) \(n)")
            n += 1
        }
        return candidate
    }

    /// 중간 폴더까지 만든다. 이름은 NFC 그대로(POSIX mkdir).
    private static func mkdirs(_ path: String) -> Bool {
        if PosixFS.type(of: path) == .directory { return true }
        guard PosixFS.type(of: path) == nil else { return false }
        let parent = PosixFS.parent(path)
        if parent != path, !mkdirs(parent) { return false }
        return mkdir(path, 0o755) == 0 || PosixFS.type(of: path) == .directory
    }

    private static func field(_ id: Int, in extra: [UInt8]) -> [UInt8]? {
        var i = 0
        while i + 4 <= extra.count {
            let fid = Int(le16(extra, i)), size = Int(le16(extra, i + 2))
            guard i + 4 + size <= extra.count else { return nil }
            if fid == id { return Array(extra[(i + 4)..<(i + 4 + size)]) }
            i += 4 + size
        }
        return nil
    }

    private static func dosDate(time: UInt16, date: UInt16) -> Date? {
        var c = DateComponents()
        c.year = 1980 + Int(date >> 9)
        c.month = Int((date >> 5) & 0xF)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        guard (1...12).contains(c.month ?? 0), (1...31).contains(c.day ?? 0) else { return nil }
        return Calendar.current.date(from: c)
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }
}
