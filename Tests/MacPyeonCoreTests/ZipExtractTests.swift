import Foundation
import Testing
@testable import MacPyeonCore

struct ZipExtractTests {
    private func tempDir() -> String {
        let p = NSTemporaryDirectory() + "mp-unzip-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// 한국어 윈도우 탐색기처럼: 이름을 CP949로, 표시 없이, 저장(무압축) 방식으로.
    private func windowsStyleZip(_ files: [(String, String)], at path: String) {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32, _ d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xFF)) } }
        for (name, body) in files {
            let n = name.data(using: WindowsZip.cp949)!
            let b = Data(body.utf8)
            let crc = CRC32.checksum([UInt8](b))
            let offset = UInt32(out.count)
            u32(0x04034B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0x5A21, &out)
            u32(crc, &out); u32(UInt32(b.count), &out); u32(UInt32(b.count), &out); u16(n.count, &out); u16(0, &out)
            out.append(n); out.append(b)
            u32(0x02014B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0x5A21, &central); u32(crc, &central); u32(UInt32(b.count), &central); u32(UInt32(b.count), &central)
            u16(n.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(0x20, &central); u32(offset, &central); central.append(n)
        }
        let cdOffset = out.count
        out.append(central)
        u32(0x06054B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(UInt32(cdOffset), &out); u16(0, &out)
        try! out.write(to: URL(fileURLWithPath: path))
    }

    @Test func decodesCP949WithoutFlag() {
        let raw = [UInt8]("한글.txt".data(using: WindowsZip.cp949)!)
        #expect(ZipExtract.decodeName(raw, flags: 0, extra: []) == "한글.txt")
        #expect(ZipExtract.decodeName(Array("한글.txt".utf8), flags: 0x800, extra: []) == "한글.txt")
        #expect(ZipExtract.decodeName(Array("abc.txt".utf8), flags: 0, extra: []) == "abc.txt")
    }

    /// 회·화·호처럼 CP949 바이트가 우연히 올바른 UTF-8이 되는 이름도 윈도우 압축이면 CP949로.
    @Test func cp949NamesThatLookLikeUTF8() throws {
        let dir = tempDir()
        let zip = dir + "/회의.zip"
        windowsStyleZip([("회화/회화.hwp", "a"), ("회화/다른.txt", "b")], at: zip)
        let names = try ZipExtract.entries(of: zip).map(\.name)
        #expect(names == ["회화/회화.hwp", "회화/다른.txt"])
        let result = try ZipExtract.extract(zip)
        #expect(PosixFS.lastComponent(result.folder) == "회화")
        #expect(PosixFS.names(in: result.folder).sorted() == ["다른.txt", "회화.hwp"])
    }

    @Test func duplicateNamesGetNumbered() throws {
        let dir = tempDir()
        let zip = dir + "/dup.zip"
        windowsStyleZip([("A.txt", "1"), ("a.txt", "2")], at: zip)
        let result = try ZipExtract.extract(zip)
        #expect(result.files == 2)
        #expect(PosixFS.names(in: result.folder).count == 2)
    }

    @Test func failedExtractionLeavesNothing() throws {
        let dir = tempDir()
        let zip = dir + "/half.zip"
        windowsStyleZip([("ok.txt", "fine"), ("bad.txt", "broken")], at: zip)
        var data = try Data(contentsOf: URL(fileURLWithPath: zip))
        // 두 번째 항목 내용 망가뜨리기: 첫 항목(헤더 30 + 이름 6 + 내용 4) 뒤 두 번째 헤더 30 + 이름 7
        data[30 + 6 + 4 + 30 + 7] ^= 0xFF
        try data.write(to: URL(fileURLWithPath: zip))
        #expect(throws: ZipExtract.Failure.self) { try ZipExtract.extract(zip) }
        #expect(PosixFS.names(in: dir) == ["half.zip"])
    }

    @Test func safePaths() {
        #expect(ZipExtract.safeComponents("../../etc/passwd") == ["etc", "passwd"])
        #expect(ZipExtract.safeComponents("/abs/x") == ["abs", "x"])
        #expect(ZipExtract.safeComponents("폴더\\파일.txt") == ["폴더", "파일.txt"])
    }

    @Test func extractsWindowsZip() throws {
        let dir = tempDir()
        let zip = dir + "/보고서.zip"
        windowsStyleZip([("보고서/1월 결과.txt", "하나"), ("보고서/사진/표지.txt", "둘")], at: zip)
        let result = try ZipExtract.extract(zip)
        #expect(result.files == 2)
        #expect(PosixFS.lastComponent(result.folder) == "보고서")   // 최상위 폴더 하나면 그대로
        let names = PosixFS.names(in: result.folder).sorted()
        #expect(names.contains("1월 결과.txt"))
        #expect(names.allSatisfy { !Hangul.needsNFC($0) })
        let body = try String(contentsOfFile: result.folder + "/사진/표지.txt", encoding: .utf8)
        #expect(body == "둘")
        // 같은 zip을 또 풀면 새 폴더
        let again = try ZipExtract.extract(zip)
        #expect(again.folder != result.folder)
    }

    @Test func roundTripsOwnDeflateZip() throws {
        let dir = tempDir()
        let src = dir + "/원본"
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        let big = String(repeating: "가나다라마바사 ", count: 50_000)
        try big.write(toFile: src + "/긴 문서.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: src + "/.DS_Store", atomically: true, encoding: .utf8)
        let zip = dir + "/out.zip"
        _ = try WindowsZip.createArchive(of: [src], to: zip, encoding: .windowsKorean)
        let outDir = dir + "/풀기"
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let result = try ZipExtract.extract(zip, into: outDir)
        #expect(result.files == 1)
        #expect(try String(contentsOfFile: result.folder + "/긴 문서.txt", encoding: .utf8) == big)
    }

    /// 맥 /usr/bin/zip: 이름을 자소 분리(NFD) UTF-8로, 표시 없이 넣는다.
    @Test func extractsMacZipCommandArchive() throws {
        let dir = tempDir()
        let src = dir + "/" + "맥 자료".decomposedStringWithCanonicalMapping
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        try "본문".write(toFile: src + "/" + "한글.txt".decomposedStringWithCanonicalMapping, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.arguments = ["-qr", "mac.zip", PosixFS.lastComponent(src)]
        try p.run(); p.waitUntilExit()
        let out = dir + "/out"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let result = try ZipExtract.extract(dir + "/mac.zip", into: out)
        #expect(PosixFS.lastComponent(result.folder) == "맥 자료")
        #expect(!Hangul.needsNFC(PosixFS.lastComponent(result.folder)))
        #expect(PosixFS.names(in: result.folder) == ["한글.txt"])
    }

    @Test func rejectsCorruptData() throws {
        let dir = tempDir()
        let zip = dir + "/bad.zip"
        windowsStyleZip([("a.txt", "hello")], at: zip)
        var data = try Data(contentsOf: URL(fileURLWithPath: zip))
        data[30 + 5] ^= 0xFF   // 내용 한 바이트를 망가뜨림 → CRC 불일치
        try data.write(to: URL(fileURLWithPath: zip))
        #expect(throws: ZipExtract.Failure.corrupt("a.txt")) { try ZipExtract.extract(zip) }
        #expect(throws: ZipExtract.Failure.notZip) { try ZipExtract.entries(of: dir + "/없음.zip") }
    }
}
