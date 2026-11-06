import CoreServices
import Foundation
import MacPyeonCore

/// 데스크탑·다운로드 폴더를 지켜보다가 NFD 이름이 생기면 NFC로 바꾼다.
/// 폴더 바로 아래 항목만 다루고, 하위 폴더 안(예: 프로젝트 저장소)은 건드리지 않는다.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let directories: [String]
    private var pending = Set<String>()
    private var scheduled = false
    /// 이름을 바꿀 수 없었던 경로. 계속 다시 시도하지 않게 기억한다.
    private var failed = Set<String>()

    var onRenamed: (([NFCRenamer.Rename]) -> Void)?

    static var defaultDirectories: [String] {
        let fm = FileManager.default
        return [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first?.resolvingSymlinksInPath().path }
    }

    init(directories: [String] = FolderWatcher.defaultDirectories) {
        self.directories = directories
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil, !directories.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, folderWatcherCallback, &context,
            directories as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags)
        else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        // 켜기 전에 이미 있던 파일도 한 번 정리한다.
        directories.forEach { pending.insert($0) }
        schedule()
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    fileprivate func received(paths: [String]) {
        for path in paths {
            let parent = PosixFS.parent(path)
            if let dir = directories.first(where: { $0 == parent || $0 == path }) {
                pending.insert(dir)
            }
        }
        schedule()
    }

    private func schedule() {
        guard !scheduled, !pending.isEmpty else { return }
        scheduled = true
        // 다운로드가 끝나고 앱이 파일을 다 쓸 때까지 잠깐 기다린다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.flush() }
    }

    private func flush() {
        scheduled = false
        let dirs = pending
        pending.removeAll()
        var renamed: [NFCRenamer.Rename] = []
        for dir in dirs {
            for name in PosixFS.names(in: dir) where !NFCRenamer.shouldSkip(name) && Hangul.needsNFC(name) {
                let path = PosixFS.join(dir, name)
                guard !failed.contains(path) else { continue }
                if let r = try? NFCRenamer.normalizeItem(at: path),
                   !Hangul.needsNFC(PosixFS.lastComponent(r.to)) {
                    renamed.append(r)
                } else {
                    failed.insert(path)
                }
            }
        }
        if !renamed.isEmpty { onRenamed?(renamed) }
    }
}

private func folderWatcherCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    count: Int,
    paths: UnsafeMutableRawPointer,
    flags: UnsafePointer<FSEventStreamEventFlags>,
    ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    // kFSEventStreamCreateFlagUseCFTypes 없이 만들었으므로 C 문자열 배열이다(이름 정규화 없이 그대로).
    let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let list = (0..<count).map { String(cString: cPaths[$0]) }
    watcher.received(paths: list)
}
