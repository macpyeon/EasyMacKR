import Foundation

/// 한글 파일명 자소 분리(NFD) 문제를 다룬다.
///
/// macOS 앱이 만든 파일 이름은 자주 NFD(ㅎ+ㅏ+ㄴ 처럼 자모가 풀린 형태)로 저장된다.
/// 윈도우·웹은 NFC(완성형)를 기대하므로 그대로 보내면 이름이 깨져 보인다.
///
/// 주의: Swift의 String 비교(==)는 NFC와 NFD를 같다고 본다. 반드시 유니코드 스칼라 단위로 비교해야 한다.
/// 또 FileManager는 경로를 넘길 때 NFD로 바꿔 버리므로, 이름을 만들거나 바꿀 때는 POSIX 함수를 쓴다.
public enum Hangul {
    public static func nfc(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// NFC가 아닌 이름인지.
    public static func needsNFC(_ name: String) -> Bool {
        !name.unicodeScalars.elementsEqual(nfc(name).unicodeScalars)
    }

    /// 두 문자열이 바이트(스칼라) 단위로 같은지. `==`는 정규화를 무시하므로 쓰지 않는다.
    public static func sameScalars(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }
}

/// 정규화 없이 파일 시스템을 다루는 얇은 POSIX 래퍼.
public enum PosixFS {
    public struct Failure: Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String { "\(path): \(String(cString: strerror(code)))" }
    }

    /// 디렉터리 안의 이름을 디스크에 적힌 그대로 돌려준다. ".", ".." 제외.
    public static func names(in directory: String) -> [String] {
        guard let dir = directory.withCString({ opendir($0) }) else { return [] }
        defer { closedir(dir) }
        var result: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            result.append(name)
        }
        return result
    }

    public enum ItemType { case file, directory, symlink, other }

    public static func type(of path: String) -> ItemType? {
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    public static func exists(_ path: String) -> Bool { type(of: path) != nil }

    /// (장치, inode). 같은 파일인지 확인할 때 쓴다.
    public static func identity(_ path: String) -> (dev: Int32, ino: UInt64)? {
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }

    public static func rename(_ from: String, to: String) throws {
        let rc = from.withCString { a in to.withCString { b in Darwin.rename(a, b) } }
        if rc != 0 { throw Failure(path: from, code: errno) }
    }

    /// 빈 파일을 만든다. 이미 있으면 실패한다.
    public static func createEmptyFile(_ path: String) throws {
        let fd = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        if fd < 0 { throw Failure(path: path, code: errno) }
        close(fd)
    }

    public static func modificationDate(_ path: String) -> Date? {
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    public static func size(_ path: String) -> UInt64? {
        var st = stat()
        guard path.withCString({ stat($0, &st) }) == 0 else { return nil }
        return UInt64(st.st_size)
    }

    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func lastComponent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if let idx = p.lastIndex(of: "/") { return String(p[p.index(after: idx)...]) }
        return p
    }

    public static func parent(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let idx = p.lastIndex(of: "/") else { return "." }
        if idx == p.startIndex { return "/" }
        return String(p[..<idx])
    }
}

/// NFD 이름을 NFC로 바꾼다.
public enum NFCRenamer {
    public struct Rename: Equatable {
        public let from: String
        public let to: String
    }

    /// 자동 정리에서 건드리지 않을 이름: 숨김 파일, 다운로드 중인 임시 파일.
    public static func shouldSkip(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        let partialSuffixes = [".crdownload", ".download", ".part", ".partial", ".tmp", ".opdownload"]
        return partialSuffixes.contains { lower.hasSuffix($0) }
    }

    /// 경로 하나의 마지막 이름만 NFC로 바꾼다. 바꿨으면 새 경로를 돌려준다.
    @discardableResult
    public static func normalizeItem(at path: String) throws -> Rename? {
        let name = PosixFS.lastComponent(path)
        guard Hangul.needsNFC(name) else { return nil }
        let target = PosixFS.join(PosixFS.parent(path), Hangul.nfc(name))
        // APFS에서는 NFC·NFD 이름이 같은 파일을 가리키지만, 일부 NAS·외장 볼륨에서는 서로 다른 파일일 수 있다.
        // rename(2)은 대상을 말없이 덮어쓰므로, 다른 파일이 있으면 건너뛴다.
        if let source = PosixFS.identity(path), let existing = PosixFS.identity(target),
           source.dev != existing.dev || source.ino != existing.ino {
            throw PosixFS.Failure(path: target, code: EEXIST)
        }
        try PosixFS.rename(path, to: target)
        return Rename(from: path, to: target)
    }

    /// 폴더 바로 아래 항목만 정리한다(자동 감시용). 하위 폴더 안은 건드리지 않는다.
    public static func normalizeChildren(of directory: String, skip: (String) -> Bool = shouldSkip) -> [Rename] {
        var done: [Rename] = []
        for name in PosixFS.names(in: directory) where !skip(name) && Hangul.needsNFC(name) {
            if let r = try? normalizeItem(at: PosixFS.join(directory, name)) { done.append(r) }
        }
        return done
    }

    /// 항목 자신과 그 안의 모든 하위 항목을 정리한다(수동 정리용). 심볼릭 링크는 따라가지 않는다.
    public static func normalizeTree(at path: String) -> (renamed: [Rename], failed: [String]) {
        var renamed: [Rename] = []
        var failed: [String] = []
        var current = path
        do {
            if let r = try normalizeItem(at: path) {
                renamed.append(r)
                current = r.to
            }
        } catch {
            failed.append(path)
        }
        if PosixFS.type(of: current) == .directory {
            for name in PosixFS.names(in: current) {
                let sub = normalizeTree(at: PosixFS.join(current, name))
                renamed += sub.renamed
                failed += sub.failed
            }
        }
        return (renamed, failed)
    }

    /// 겹치지 않는 새 파일 경로를 만든다. "새 텍스트 문서.txt", "새 텍스트 문서 (2).txt" …
    public static func uniquePath(in directory: String, base: String, ext: String) -> String {
        let first = PosixFS.join(directory, Hangul.nfc("\(base).\(ext)"))
        if !PosixFS.exists(first) { return first }
        var n = 2
        while true {
            let candidate = PosixFS.join(directory, Hangul.nfc("\(base) (\(n)).\(ext)"))
            if !PosixFS.exists(candidate) { return candidate }
            n += 1
        }
    }
}
