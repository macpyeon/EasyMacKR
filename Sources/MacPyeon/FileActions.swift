import AppKit
import MacPyeonCore

/// Finder 연동·파일 작업. 오래 걸릴 수 있는 일은 백그라운드에서 한다.
enum FileActions {
    private static let queue = DispatchQueue(label: "macpyeon.files", qos: .userInitiated)

    // MARK: 새 텍스트 문서

    static func createNewTextFile() {
        queue.async {
            let dir = finderFrontFolder() ?? desktopPath()
            let path = NFCRenamer.uniquePath(in: dir, base: "새 텍스트 문서", ext: "txt")
            do {
                try PosixFS.createEmptyFile(path)
            } catch {
                DispatchQueue.main.async { showError("새 텍스트 문서를 만들 수 없어요.", detail: "\(error)") }
                return
            }
            let selected = runAppleScript("""
            tell application "Finder"
                activate
                select (POSIX file "\(escape(path))" as alias)
            end tell
            return "ok"
            """)
            // 선택된 상태에서 Return을 눌러 바로 이름 바꾸기로 들어간다.
            // Finder 제어가 막혔거나 Finder가 앞에 오지 않았으면 보내지 않는다(다른 앱에 엔터가 들어가면 안 됨).
            guard selected?.contains("ok") == true else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
                KeySender.post(key: KeyCode.returnKey, modifiers: [])
            }
        }
    }

    /// 맨 앞 Finder 창이 보고 있는 폴더. 창이 없으면 nil.
    static func finderFrontFolder() -> String? {
        let output = runAppleScript("""
        tell application "Finder"
            if (count of Finder windows) is 0 then return ""
            try
                return POSIX path of ((target of front Finder window) as alias)
            on error
                return ""
            end try
        end tell
        """)
        guard let path = output?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    }

    private static func desktopPath() -> String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// osascript로 실행한다(메인 스레드를 막지 않게). 처음 한 번은 Finder 제어 허용 창이 뜬다.
    @discardableResult
    static func runAppleScript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: 한글 파일명 정리

    static func normalizeNames(_ paths: [String]) {
        queue.async {
            var renamed = 0
            var failed: [String] = []
            for path in paths {
                let r = NFCRenamer.normalizeTree(at: path)
                renamed += r.renamed.count
                failed += r.failed
            }
            DispatchQueue.main.async {
                if failed.isEmpty {
                    showInfo(renamed == 0 ? "정리할 이름이 없어요." : "파일 이름 \(renamed)개를 정리했어요.",
                             detail: renamed == 0 ? "이미 모두 윈도우와 호환되는 이름(NFC)이에요." : "이제 윈도우·웹에서도 한글이 깨지지 않아요.")
                } else {
                    showError("일부 이름을 바꾸지 못했어요. (\(failed.count)개)",
                              detail: failed.prefix(5).joined(separator: "\n"))
                }
            }
        }
    }

    static func chooseAndNormalize() {
        let panel = NSOpenPanel()
        panel.title = "한글 이름을 정리할 파일·폴더 선택"
        panel.prompt = "정리"
        panel.message = "선택한 항목과 폴더 안의 모든 파일 이름을 NFC(완성형)로 바꿉니다."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        normalizeNames(panel.urls.map(\.path))
    }

    // MARK: 윈도우용 압축

    static func zipForWindows(_ paths: [String], encoding: ZipNameEncoding) {
        guard !paths.isEmpty else { return }
        queue.async {
            let output = WindowsZip.suggestedOutputPath(for: paths)
            do {
                try WindowsZip.createArchive(of: paths, to: output, encoding: encoding)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)])
                }
            } catch {
                DispatchQueue.main.async { showError("압축하지 못했어요.", detail: "\(error)") }
            }
        }
    }

    static func chooseAndZip(encoding: ZipNameEncoding) {
        let panel = NSOpenPanel()
        panel.title = "윈도우용으로 압축할 항목 선택"
        panel.prompt = "압축"
        panel.message = "한글 이름이 윈도우에서 깨지지 않게 압축합니다. .DS_Store 같은 맥 전용 파일은 빠집니다."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        zipForWindows(panel.urls.map(\.path), encoding: encoding)
    }

    // MARK: 윈도우 zip 풀기

    static func unzip(_ paths: [String]) {
        let zips = paths.filter { $0.lowercased().hasSuffix(".zip") }
        guard !zips.isEmpty else {
            if !paths.isEmpty { DispatchQueue.main.async { showError("zip 파일만 풀 수 있어요.", detail: "") } }
            return
        }
        queue.async {
            var folders: [URL] = []
            var failures: [String] = []
            for zip in zips {
                do {
                    let result = try ZipExtract.extract(zip)
                    folders.append(URL(fileURLWithPath: result.folder))
                } catch {
                    failures.append("\(PosixFS.lastComponent(zip)): \(error)")
                }
            }
            DispatchQueue.main.async {
                if !folders.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(folders) }
                if !failures.isEmpty { showError("풀지 못한 파일이 있어요.", detail: failures.joined(separator: "\n")) }
            }
        }
    }

    static func chooseAndUnzip() {
        let panel = NSOpenPanel()
        panel.title = "한글 깨짐 없이 풀 zip 선택"
        panel.prompt = "풀기"
        panel.message = "윈도우에서 만든 zip의 한글 파일명을 바르게 읽어서 같은 위치에 풉니다."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        unzip(panel.urls.map(\.path))
    }

    // MARK: 경로 복사·터미널

    static func copyPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.map(Hangul.nfc).joined(separator: "\n"), forType: .string)
        HUD.show(paths.count > 1 ? "경로 \(paths.count)개를 복사했어요" : "경로를 복사했어요", symbol: "doc.on.doc")
    }

    /// 폴더면 그 폴더, 파일이면 들어 있는 폴더에서 터미널을 연다.
    static func openTerminal(at path: String) {
        let folder = PosixFS.type(of: path) == .directory && !NSWorkspace.shared.isFilePackage(atPath: path)
            ? path : PosixFS.parent(path)
        let app = TerminalApp.preferred
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalApp.terminal.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: appURL,
                                configuration: config) { _, error in
            if let error { DispatchQueue.main.async { showError("터미널을 열지 못했어요.", detail: error.localizedDescription) } }
        }
    }

    /// Finder에서 고른 폴더(하나) 또는 지금 보고 있는 폴더에서 터미널을 연다.
    static func openTerminalAtFinderLocation() {
        queue.async {
            let selected = runAppleScript("""
            tell application "Finder"
                try
                    set s to selection as alias list
                    if (count of s) is 1 then return POSIX path of (item 1 of s)
                end try
                return ""
            end tell
            """)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var path = (selected?.isEmpty == false ? selected : nil) ?? finderFrontFolder() ?? desktopPath()
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            DispatchQueue.main.async { openTerminal(at: path) }
        }
    }

    // MARK: 알림

    static func showInfo(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Finder 오른쪽 클릭 > 빠른 동작(서비스) 메뉴에 들어가는 항목.
final class ServiceProvider: NSObject {
    var zipEncoding: () -> ZipNameEncoding = { .windowsKorean }

    private func paths(from pboard: NSPasteboard) -> [String] {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.map(\.path) ?? []
    }

    @objc func zipForWindows(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        FileActions.zipForWindows(paths(from: pboard), encoding: zipEncoding())
    }

    @objc func normalizeHangulNames(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        FileActions.normalizeNames(paths(from: pboard))
    }

    @objc func unzipWindows(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        FileActions.unzip(paths(from: pboard))
    }

    @objc func copyPath(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let list = paths(from: pboard)
        DispatchQueue.main.async { FileActions.copyPaths(list) }
    }

    @objc func openTerminalHere(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let first = paths(from: pboard).first else { return }
        DispatchQueue.main.async { FileActions.openTerminal(at: first) }
    }
}

/// '여기서 터미널 열기'에 쓸 앱.
struct TerminalApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }

    static let terminal = TerminalApp(bundleID: "com.apple.Terminal", name: "터미널")
    static let known: [TerminalApp] = [
        terminal,
        TerminalApp(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
        TerminalApp(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        TerminalApp(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
    ]   // 폴더를 넘기면 그 위치에서 여는 앱만(kitty·Alacritty 등은 홈에서 열림)

    static var installed: [TerminalApp] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static let defaultsKey = "terminalApp"

    static var preferred: TerminalApp {
        let id = UserDefaults.standard.string(forKey: defaultsKey)
        return installed.first { $0.bundleID == id } ?? terminal
    }
}
