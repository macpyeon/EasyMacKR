import Foundation
import Testing
@testable import MacPyeonCore

/// 테스트마다 쓰는 빈 임시 폴더.
func makeTempDir() throws -> String {
    let path = NSTemporaryDirectory() + "macpyeon-test-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

let nfdName = "한글 문서.txt".decomposedStringWithCanonicalMapping
let nfcName = "한글 문서.txt".precomposedStringWithCanonicalMapping

@Suite struct HangulTests {
    @Test func detectsDecomposedNames() {
        #expect(Hangul.needsNFC(nfdName))
        #expect(!Hangul.needsNFC(nfcName))
        #expect(!Hangul.needsNFC("report.pdf"))
        // Swift의 == 는 둘을 같다고 본다. 그래서 스칼라 비교가 필요하다.
        #expect(nfdName == nfcName)
        #expect(!Hangul.sameScalars(nfdName, nfcName))
    }

    @Test func renamesTreeToNFC() throws {
        let root = try makeTempDir()
        let dirName = "사진 폴더".decomposedStringWithCanonicalMapping
        let dir = PosixFS.join(root, dirName)
        #expect(mkdir(dir, 0o755) == 0)
        try PosixFS.createEmptyFile(PosixFS.join(dir, nfdName))

        let result = NFCRenamer.normalizeTree(at: dir)

        #expect(result.failed.isEmpty)
        #expect(result.renamed.count == 2)
        let top = PosixFS.names(in: root)
        #expect(top.count == 1)
        #expect(Hangul.sameScalars(top[0], Hangul.nfc(dirName)))
        let inner = PosixFS.names(in: PosixFS.join(root, top[0]))
        #expect(inner.count == 1)
        #expect(Hangul.sameScalars(inner[0], nfcName))
    }

    @Test func childrenOnlySkipsHiddenPartialAndNested() throws {
        let root = try makeTempDir()
        let sub = PosixFS.join(root, "폴더".decomposedStringWithCanonicalMapping)
        #expect(mkdir(sub, 0o755) == 0)
        try PosixFS.createEmptyFile(PosixFS.join(sub, nfdName))
        try PosixFS.createEmptyFile(PosixFS.join(root, nfdName))
        try PosixFS.createEmptyFile(PosixFS.join(root, "받는 중.zip.crdownload".decomposedStringWithCanonicalMapping))
        try PosixFS.createEmptyFile(PosixFS.join(root, ".숨김".decomposedStringWithCanonicalMapping))

        let renamed = NFCRenamer.normalizeChildren(of: root)

        #expect(renamed.count == 2) // 파일 1개 + 폴더 1개
        let names = PosixFS.names(in: root)
        #expect(names.filter(Hangul.needsNFC).count == 2) // .crdownload, 숨김 파일은 그대로
        let nested = PosixFS.names(in: PosixFS.join(root, "폴더".precomposedStringWithCanonicalMapping))
        #expect(Hangul.needsNFC(nested[0])) // 하위 폴더 안은 건드리지 않음
    }

    @Test func createdFileKeepsNFCName() throws {
        // FileManager는 NFD로 만들지만 PosixFS는 NFC 그대로 만든다.
        let root = try makeTempDir()
        let path = NFCRenamer.uniquePath(in: root, base: "새 텍스트 문서", ext: "txt")
        try PosixFS.createEmptyFile(path)
        let second = NFCRenamer.uniquePath(in: root, base: "새 텍스트 문서", ext: "txt")
        #expect(PosixFS.lastComponent(second) == "새 텍스트 문서 (2).txt")
        let names = PosixFS.names(in: root)
        #expect(names.count == 1)
        #expect(!Hangul.needsNFC(names[0]))
    }

    @Test func pathHelpers() {
        #expect(PosixFS.parent("/a/b/c.txt") == "/a/b")
        #expect(PosixFS.parent("/a") == "/")
        #expect(PosixFS.lastComponent("/a/b/") == "b")
        #expect(PosixFS.join("/a/", "b") == "/a/b")
    }
}
