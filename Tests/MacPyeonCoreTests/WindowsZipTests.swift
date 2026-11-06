import Foundation
import Testing
@testable import MacPyeonCore

/// 테스트용 최소 zip 읽기: 중앙 디렉터리에서 (이름 바이트, 플래그, 확장 필드)를 꺼낸다.
private struct CentralEntry {
    let nameBytes: [UInt8]
    let flags: UInt16
    let extra: [UInt8]
}

private func readCentralDirectory(_ data: [UInt8]) -> [CentralEntry] {
    func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    let eocd = data.count - 22
    precondition(u32(eocd) == 0x0605_4B50)
    let count = u16(eocd + 10)
    var p = u32(eocd + 16)
    var result: [CentralEntry] = []
    for _ in 0..<count {
        precondition(u32(p) == 0x0201_4B50)
        let flags = UInt16(u16(p + 8))
        let n = u16(p + 28), e = u16(p + 30), c = u16(p + 32)
        let name = Array(data[(p + 46)..<(p + 46 + n)])
        let extra = Array(data[(p + 46 + n)..<(p + 46 + n + e)])
        result.append(CentralEntry(nameBytes: name, flags: flags, extra: extra))
        p += 46 + n + e + c
    }
    return result
}

private func makeSample() throws -> String {
    let root = try makeTempDir()
    let folder = PosixFS.join(root, "보고서".decomposedStringWithCanonicalMapping)
    #expect(mkdir(folder, 0o755) == 0)
    let file = PosixFS.join(folder, "회의록 최종.txt".decomposedStringWithCanonicalMapping)
    try PosixFS.createEmptyFile(file)
    try Data(String(repeating: "안녕하세요 맥편해\n", count: 500).utf8).write(to: URL(fileURLWithPath: file))
    try PosixFS.createEmptyFile(PosixFS.join(folder, ".DS_Store"))
    try PosixFS.createEmptyFile(PosixFS.join(folder, "._회의록 최종.txt"))
    try PosixFS.createEmptyFile(PosixFS.join(folder, "readme.md"))
    return folder
}

private func unzipTest(_ zip: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    p.arguments = ["-tq", zip]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

@Suite struct WindowsZipTests {
    @Test func koreanWindowsEncoding() throws {
        let folder = try makeSample()
        let out = WindowsZip.suggestedOutputPath(for: [folder])
        #expect(PosixFS.lastComponent(out) == "보고서.zip")
        #expect(!Hangul.needsNFC(PosixFS.lastComponent(out)))

        let count = try WindowsZip.createArchive(of: [folder], to: out, encoding: .windowsKorean)
        #expect(count == 3) // 폴더, 회의록, readme — .DS_Store 와 ._ 파일은 빠짐
        #expect(unzipTest(out) == 0) // CRC·구조가 올바른지 Info-ZIP으로 검사

        let entries = readCentralDirectory([UInt8](try Data(contentsOf: URL(fileURLWithPath: out))))
        let names = entries.map { String(data: Data($0.nameBytes), encoding: WindowsZip.cp949) ?? "?" }
        #expect(names == ["보고서/", "보고서/readme.md", "보고서/회의록 최종.txt"])
        for (entry, name) in zip(entries, names) {
            #expect(entry.flags & 0x0800 == 0) // CP949 이므로 UTF-8 표시 없음
            // 한글이 있으면 UTF-8 이름이 담긴 0x7075 확장 필드가 붙는다.
            let hasKorean = !name.allSatisfy(\.isASCII)
            #expect(!entry.extra.isEmpty == hasKorean)
            if hasKorean {
                #expect(entry.extra[0] == 0x75 && entry.extra[1] == 0x70)
                let utf8 = String(decoding: entry.extra[9...], as: UTF8.self)
                #expect(Hangul.sameScalars(utf8, name.precomposedStringWithCanonicalMapping))
            }
        }
    }

    @Test func utf8Encoding() throws {
        let folder = try makeSample()
        let out = PosixFS.join(PosixFS.parent(folder), "out.zip")
        try WindowsZip.createArchive(of: [folder], to: out, encoding: .utf8)
        #expect(unzipTest(out) == 0)
        let entries = readCentralDirectory([UInt8](try Data(contentsOf: URL(fileURLWithPath: out))))
        let korean = entries.first { String(decoding: $0.nameBytes, as: UTF8.self).hasSuffix(".txt") }!
        #expect(korean.flags & 0x0800 != 0)
        let name = String(decoding: korean.nameBytes, as: UTF8.self)
        #expect(Hangul.sameScalars(name, "보고서/회의록 최종.txt".precomposedStringWithCanonicalMapping))
    }

    @Test func extractedContentMatches() throws {
        let folder = try makeSample()
        let out = PosixFS.join(PosixFS.parent(folder), "check.zip")
        try WindowsZip.createArchive(of: [folder], to: out, encoding: .utf8)
        let dest = try makeTempDir()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", out, dest]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let original = try Data(contentsOf: URL(fileURLWithPath: PosixFS.join(folder, "회의록 최종.txt")))
        let extracted = try Data(contentsOf: URL(fileURLWithPath: dest + "/보고서/회의록 최종.txt"))
        #expect(original == extracted)
    }

    @Test func multipleItemsName() throws {
        let root = try makeTempDir()
        let a = PosixFS.join(root, "a.txt"), b = PosixFS.join(root, "b.txt")
        try PosixFS.createEmptyFile(a)
        try PosixFS.createEmptyFile(b)
        #expect(PosixFS.lastComponent(WindowsZip.suggestedOutputPath(for: [a, b])) == "압축파일.zip")
        #expect(PosixFS.lastComponent(WindowsZip.suggestedOutputPath(for: [a])) == "a.zip")
    }

    @Test func crc32KnownValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}
