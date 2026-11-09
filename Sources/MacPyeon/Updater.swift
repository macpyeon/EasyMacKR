import AppKit
import Combine
import CryptoKit
import Foundation
import MacPyeonCore

/// GitHub 릴리스에서 새 버전이 나왔는지 확인하고, 업데이트한 뒤에는 한 번 알려 준다.
/// 보내는 것은 공개 API 요청 하나뿐이고 사용자 정보는 넣지 않는다.
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "macpyeon/EasyMacKR"
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases")!
    private static let checkInterval: TimeInterval = 12 * 3600

    /// 새 버전이 있으면 그 정보. 마지막으로 받은 릴리스를 저장해 두어 앱을 다시 켜도 유지된다.
    @Published private(set) var available: ReleaseInfo?
    /// 방금 이 버전으로 업데이트됐으면 그 버전(사용자가 닫을 때까지 유지).
    @Published private(set) var justUpdated: AppVersion?
    @Published private(set) var checking = false
    @Published private(set) var lastResult: String?
    /// 업데이트 버튼을 누른 뒤 진행 중이면 보여 줄 문구.
    @Published private(set) var installStep: String?
    @Published private(set) var installError: String?
    /// 이번 실행이 지난 실행과 다른 버전인지(업데이트·재설치 직후).
    private(set) var versionChangedThisLaunch = false

    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck)
            lastResult = nil
            if autoCheck {
                scheduleTimer()
                restoreSavedRelease()
                check(manual: false)
            } else {
                timer?.invalidate()
                timer = nil
                available = nil
            }
        }
    }

    private(set) var current: AppVersion? = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// 렌더링 확인용 실행에서는 설정에 아무것도 남기지 않는다.
    private var persists = true

    private enum Keys {
        static let autoCheck = "updateAutoCheck"
        static let lastCheck = "updateLastCheck"
        static let latestJSON = "updateLatestRelease"
        static let skipped = "updateSkippedVersion"
        static let lastRun = "updateLastRunVersion"
        static let pendingUpdated = "updatePendingUpdatedVersion"
    }

    private init() {
        autoCheck = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true
    }

    var currentText: String { current?.description ?? "개발판" }

    /// cask가 깔린 brew. 두 군데 다 있으면 Caskroom에 맥편해가 있는 쪽을 쓴다.
    var brewPath: String? {
        let candidates = [("/opt/homebrew/Caskroom/macpyeon", "/opt/homebrew/bin/brew"),
                          ("/usr/local/Caskroom/macpyeon", "/usr/local/bin/brew")]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.0) && FileManager.default.isExecutableFile(atPath: $0.1)
        }?.1
    }

    /// brew로 설치했는지(그러면 뒤에서 brew로 업데이트한다).
    var installedWithBrew: Bool { brewPath != nil }

    func start() {
        noteLaunchVersion()
        reportUnfinishedUpdate()
        guard current != nil else { return }   // 번들 없이 돌리는 개발판은 확인하지 않는다
        guard autoCheck else { return }
        restoreSavedRelease()
        scheduleTimer()
        // 로그인 직후 네트워크가 잡힐 시간을 둔다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self?.checkIfDue() }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 지난번에 받아 둔 릴리스로 알림을 되살린다(앱을 다시 켜도 12시간 기다리지 않게).
    private func restoreSavedRelease() {
        guard let current, let data = UserDefaults.standard.data(forKey: Keys.latestJSON),
              let release = ReleaseInfo.parse(json: data, repo: Self.repo) else { return }
        available = UpdatePolicy.shouldNotify(current: current, latest: release.version, skipped: skippedVersion) ? release : nil
    }

    private var skippedVersion: AppVersion? {
        UserDefaults.standard.string(forKey: Keys.skipped).flatMap(AppVersion.init)
    }

    private func checkIfDue() {
        guard autoCheck, current != nil else { return }
        let last = UserDefaults.standard.double(forKey: Keys.lastCheck)
        guard Date().timeIntervalSince1970 - last >= Self.checkInterval else { return }
        check(manual: false)
    }

    /// manual이면 결과를 글로 남기고, 건너뛴 버전도 다시 알린다(건너뛰기 취소).
    func check(manual: Bool) {
        guard let current else {
            if manual { lastResult = "개발판이라 확인하지 않아요" }
            return
        }
        guard !checking else { return }
        checking = true
        if manual { lastResult = nil }
        var request = URLRequest(url: Self.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacPyeon-update-check", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = status == 200 ? data : nil
            let release = body.flatMap { ReleaseInfo.parse(json: $0, repo: Self.repo) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                guard let release, let body else {
                    if manual { self.lastResult = Self.failureText(error: error, status: status) }
                    return
                }
                if self.persists {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheck)
                    UserDefaults.standard.set(body, forKey: Keys.latestJSON)
                    if manual { UserDefaults.standard.removeObject(forKey: Keys.skipped) }
                }
                let skipped = manual ? nil : self.skippedVersion
                if UpdatePolicy.shouldNotify(current: current, latest: release.version, skipped: skipped) {
                    self.available = release
                    if manual { self.lastResult = "새 버전 \(release.version.withSubject) 있어요" }
                } else {
                    self.available = nil
                    if manual { self.lastResult = "최신 버전이에요" }
                }
            }
        }.resume()
    }

    private static func failureText(error: Error?, status: Int) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "인터넷에 연결되지 않아 확인하지 못했어요"
            case .timedOut:
                return "GitHub 응답이 늦어 확인하지 못했어요"
            default:
                return "GitHub에 연결하지 못했어요"
            }
        }
        if status == 200 { return "릴리스 정보를 읽지 못했어요" }
        if status == 403 || status == 429 { return "확인 요청이 많아 잠시 막혔어요. 나중에 다시 해 주세요" }
        return "지금은 확인할 수 없어요 (\(status))"
    }

    /// 이번 새 버전은 알리지 않는다(다음 버전이 나오면 다시 알림).
    func skip() {
        guard let available else { return }
        UserDefaults.standard.set(available.version.description, forKey: Keys.skipped)
        self.available = nil
        lastResult = nil
    }

    // MARK: 앱 안에서 업데이트
    //
    // 버튼 한 번으로: 맥편해가 스스로 끝난 뒤, 뒤에서 도는 작은 스크립트가 새 버전을 깔고 다시 켠다.
    // (brew 7부터는 brew를 띄운 앱을 brew가 끄지 않으므로, 끄는 일은 맥편해가 직접 한다)

    /// 이 앱이 brew가 관리하는 그 사본인지(직접 빌드한 다른 사본에서 누르면 brew로 가지 않는다).
    private var isBrewCopy: Bool {
        installedWithBrew && Bundle.main.bundlePath == "/Applications/MacPyeon.app"
    }

    /// 배포판 zip으로 바꿔도 되는 사본인지: 배포판이고, 앱 폴더에 쓸 수 있어야 한다.
    private var canSwapFromZip: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "MacPyeonReleaseBuild") as? Bool == true else { return false }
        let app = Bundle.main.bundlePath
        let parent = (app as NSString).deletingLastPathComponent
        return FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: app)
    }

    /// 버튼 한 번으로 업데이트할 수 있는지(아니면 릴리스 페이지로 안내).
    var canInstallInApp: Bool {
        guard current != nil else { return false }
        return isBrewCopy || (available?.downloadURL != nil && canSwapFromZip)
    }

    private var workDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPyeon", isDirectory: true)
    }
    private var resultFile: URL { workDir.appendingPathComponent("update-result.txt") }

    func install() {
        guard installStep == nil else { return }
        guard let release = available, canInstallInApp else {
            NSWorkspace.shared.open(available?.pageURL ?? Self.releasesPage)
            return
        }
        installError = nil
        if isBrewCopy, let brew = brewPath {
            prepareBrew(brew)
        } else if let url = release.downloadURL {
            downloadZip(url, sha256: release.downloadSHA256, target: release.version)
        }
    }

    private func fail(_ message: String) {
        installStep = nil
        installError = message
        DebugLog.write("update failed: \(message)")
    }

    // MARK: brew

    /// 1단계(맥편해가 켜진 채): brew 목록을 새로 받고, 정말 새 버전이 있는지 본다.
    private func prepareBrew(_ brew: String) {
        installStep = "새 버전을 확인하는 중…"
        let info = workDir.appendingPathComponent("brew-info.json")
        try? FileManager.default.removeItem(at: info)
        let script = """
        #!/bin/zsh
        BREW="$1"; INFO="$2"
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export HOMEBREW_NO_ENV_HINTS=1
        echo "== $(date) prepare"
        "$BREW" update --quiet
        echo "update-exit=$?"
        HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" info --cask --json=v2 macpyeon/tap/macpyeon > "$INFO"
        echo "info-exit=$?"
        """
        run(script: script, name: "update-prepare.sh", arguments: [brew, info.path], timeout: 600) { [weak self] status, log in
            guard let self else { return }
            let tapVersion = (try? Data(contentsOf: info))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["casks"] as? [[String: Any]])?.first?["version"] as? String }
                .flatMap(AppVersion.init)
            if let tapVersion, let current = self.current, current < tapVersion {
                self.upgradeWithBrew(brew)
            } else if status == nil {
                self.fail("brew가 너무 오래 걸려서 멈췄어요. 잠시 뒤 다시 눌러 주세요.")
            } else if !log.contains("update-exit=0") {
                self.fail("brew 목록을 새로 받지 못했어요. 인터넷 연결을 확인하고 다시 눌러 주세요.")
            } else if tapVersion == nil {
                self.fail("brew에서 맥편해를 찾지 못했어요. 터미널에서 brew upgrade --cask macpyeon 을 실행해 주세요.")
            } else {
                self.fail("새 버전이 아직 brew 목록에 올라오지 않았어요. 몇 분 뒤 다시 눌러 주세요.")
            }
        }
    }

    /// 2단계: 맥편해가 끝나기를 기다렸다가 brew로 올리고 다시 켜는 스크립트를 띄우고 끝낸다.
    private func upgradeWithBrew(_ brew: String) {
        let script = """
        #!/bin/zsh
        BREW="$1"; APP="$2"; PID="$3"; RESULT="$4"
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        export HOMEBREW_NO_ENV_HINTS=1
        echo "== $(date) upgrade"
        for i in {1..600}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$PID" 2>/dev/null; then echo "app still running"; exit 1; fi
        HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" upgrade --cask macpyeon/tap/macpyeon
        echo "brew-exit=$?" > "$RESULT"
        # 성공하든 못 하든 맥편해는 다시 켠다.
        /usr/bin/pgrep -qfx "$APP/Contents/MacOS/MacPyeon" || /usr/bin/open "$APP"
        """
        launchAndQuit(script: script, name: "update-brew.sh",
                      arguments: [brew, Bundle.main.bundlePath, pidString, resultFile.path])
    }

    // MARK: zip 직접 설치

    private func downloadZip(_ url: URL, sha256: String?, target: AppVersion) {
        installStep = "새 버전을 받는 중…"
        // 시도마다 새 폴더(같은 경로의 번들 정보가 캐시되지 않게).
        let work = workDir.appendingPathComponent("update", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier
        URLSession.shared.downloadTask(with: url) { [weak self] tmp, response, _ in
            let result: Result<URL, UpdateFailure> = {
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return .failure(UpdateFailure(message: "내려받지 못했어요. 인터넷 연결을 확인하고 다시 눌러 주세요."))
                }
                let fm = FileManager.default
                try? fm.removeItem(at: work.deletingLastPathComponent())
                let zip = work.appendingPathComponent("MacPyeon.zip")
                let unpacked = work.appendingPathComponent("new", isDirectory: true)
                do {
                    try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
                    try fm.moveItem(at: tmp, to: zip)
                } catch {
                    return .failure(UpdateFailure(message: "받은 파일을 저장하지 못했어요."))
                }
                if let sha256, Self.sha256(of: zip) != sha256 {
                    return .failure(UpdateFailure(message: "받은 파일이 릴리스와 달라요. 다시 눌러 주세요."))
                }
                guard Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else {
                    return .failure(UpdateFailure(message: "받은 파일을 풀지 못했어요."))
                }
                let app = unpacked.appendingPathComponent("MacPyeon.app")
                // 맞는 앱인지: 같은 번들 ID, 기대한 버전, 서명이 손상되지 않았는지.
                let plist = (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                guard let plist, plist["CFBundleIdentifier"] as? String == bundleID,
                      (plist["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == target,
                      Self.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
                else { return .failure(UpdateFailure(message: "받은 파일이 올바르지 않아요. 릴리스 페이지에서 직접 받아 주세요.")) }
                return .success(app)
            }()
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let f): self.fail(f.message)
                case .success(let app): self.swapAndRelaunch(newApp: app)
                }
            }
        }.resume()
    }

    /// 새 앱을 먼저 지금 앱 옆에 복사해 두고, 맥편해가 끝나면 이름만 바꿔 교체한 뒤 다시 켠다.
    private func swapAndRelaunch(newApp: URL) {
        let script = """
        #!/bin/zsh
        PID="$1"; NEW="$2"; DEST="$3"; RESULT="$4"
        PARENT="${DEST:h}"; STAGE="$PARENT/.MacPyeon-update.app"; OLD="$PARENT/.MacPyeon-old.app"
        echo "== $(date) swap"
        rm -rf "$STAGE" "$OLD"
        # 같은 폴더로 먼저 복사(여기서 실패해도 지금 앱은 그대로다).
        if ! /usr/bin/ditto "$NEW" "$STAGE"; then
          rm -rf "$STAGE"; echo "stage-failed" > "$RESULT"
          /usr/bin/pgrep -qfx "$DEST/Contents/MacOS/MacPyeon" || /usr/bin/open "$DEST"
          exit 1
        fi
        for i in {1..600}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$PID" 2>/dev/null; then rm -rf "$STAGE"; echo "app still running"; exit 1; fi
        # 같은 폴더 안에서 이름만 바꾸므로 중간에 반쯤 바뀐 앱이 남지 않는다.
        if mv "$DEST" "$OLD"; then
          if mv "$STAGE" "$DEST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            rm -rf "$OLD"
            echo "ok" > "$RESULT"
          else
            mv "$OLD" "$DEST"
            echo "swap-failed" > "$RESULT"
          fi
        else
          echo "swap-failed" > "$RESULT"
        fi
        rm -rf "$STAGE"
        /usr/bin/open "$DEST"
        """
        launchAndQuit(script: script, name: "update-swap.sh",
                      arguments: [pidString, newApp.path, Bundle.main.bundlePath, resultFile.path])
    }

    // MARK: 도우미

    private var pidString: String { String(ProcessInfo.processInfo.processIdentifier) }

    /// 마무리 스크립트를 띄우고 맥편해를 끝낸다. 무언가 종료를 막아 끝나지 않으면 알리고 멈춘다.
    private func launchAndQuit(script: String, name: String, arguments: [String]) {
        try? FileManager.default.removeItem(at: resultFile)
        guard run(script: script, name: name, arguments: arguments, timeout: nil, completion: nil) else { return }
        installStep = "새 버전으로 다시 켜는 중…"
        DebugLog.write("update: quitting so \(name) can finish")
        DispatchQueue.main.async { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.fail("맥편해가 꺼지지 않아 업데이트를 멈췄어요. 열려 있는 창을 닫고 다시 눌러 주세요.")
        }
    }

    /// 지난번 업데이트가 끝나지 못했으면(새 버전으로 바뀌지 않았으면) 알려 준다. noteLaunchVersion 뒤에 부른다.
    private func reportUnfinishedUpdate() {
        guard let text = try? String(contentsOf: resultFile, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: resultFile)
        guard !versionChangedThisLaunch else { return }
        installError = text.contains("stage-failed") || text.contains("swap-failed")
            ? "새 버전으로 바꾸지 못했어요. 앱 폴더 권한을 확인하거나 릴리스 페이지에서 직접 받아 주세요."
            : "지난 업데이트가 끝나지 않았어요. 다시 눌러 주세요."
    }

    /// 스크립트를 파일로 써서 뒤에서 실행한다(맥편해가 끝나도 계속 돈다). 출력은 update.log에.
    /// completion의 상태값이 nil이면 시간 제한에 걸려 멈춘 것.
    @discardableResult
    private func run(script: String, name: String, arguments: [String], timeout: TimeInterval?,
                     completion: ((Int32?, String) -> Void)?) -> Bool {
        let fm = FileManager.default
        let url = workDir.appendingPathComponent(name)
        let logURL = workDir.appendingPathComponent("update.log")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            fm.createFile(atPath: logURL.path, contents: nil)
        } catch {
            fail("업데이트를 시작하지 못했어요.")
            return false
        }
        let log = try? FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [url.path] + arguments
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        var timedOut = false
        if let completion {
            p.terminationHandler = { proc in
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                DispatchQueue.main.async { completion(timedOut ? nil : proc.terminationStatus, text) }
            }
        }
        do {
            try p.run()
        } catch {
            fail("업데이트를 시작하지 못했어요.")
            return false
        }
        if let timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard p.isRunning else { return }
                timedOut = true
                p.terminate()
            }
        }
        return true
    }

    private struct UpdateFailure: Error { let message: String }

    private static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func runTool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// 알고 있는 릴리스면 그 페이지, 아니면 태그 주소.
    func openReleasePage(_ version: AppVersion? = nil) {
        if let available, version == nil || available.version == version {
            NSWorkspace.shared.open(available.pageURL)
            return
        }
        let url = version.flatMap { URL(string: "https://github.com/\(Self.repo)/releases/tag/v\($0)") }
        NSWorkspace.shared.open(url ?? Self.releasesPage)
    }

    /// 문서·확인용 렌더링에서만: 지금 버전을 가정하고 실제로 확인한다. 설정에는 남기지 않는다.
    func previewCheck(assuming version: String) {
        persists = false
        current = AppVersion(version)
        check(manual: true)
    }

    func dismissJustUpdated() {
        UserDefaults.standard.removeObject(forKey: Keys.pendingUpdated)
        justUpdated = nil
    }

    /// 예전 버전이 남긴 상태 파일. AppController.start()보다 먼저 확인해야 한다.
    private static var ranBefore: Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("MacPyeon/status.txt").path)
    }

    /// 지난번 실행보다 버전이 올라갔으면 "업데이트됐어요"를 닫을 때까지 보여 준다.
    private func noteLaunchVersion() {
        guard let current else { return }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Keys.lastRun).flatMap(AppVersion.init)
        defaults.set(current.description, forKey: Keys.lastRun)
        versionChangedThisLaunch = previous.map { $0 != current } ?? Self.ranBefore
        if let previous, previous < current {
            defaults.set(current.description, forKey: Keys.pendingUpdated)
        } else if previous == nil, Self.ranBefore {
            // 업데이트 알림이 생기기 전 버전에서 올라온 경우(기록이 없음): 예전에 실행한 흔적이 있으면 알려 준다.
            defaults.set(current.description, forKey: Keys.pendingUpdated)
        }
        if let pending = defaults.string(forKey: Keys.pendingUpdated).flatMap(AppVersion.init) {
            if pending == current { justUpdated = pending } else { defaults.removeObject(forKey: Keys.pendingUpdated) }
        }
        if let skipped = skippedVersion, !(current < skipped) {
            defaults.removeObject(forKey: Keys.skipped)
        }
        // 이미 그 버전 이상이면 저장해 둔 릴리스 알림도 필요 없다.
        if let data = defaults.data(forKey: Keys.latestJSON), let saved = ReleaseInfo.parse(json: data), !(current < saved.version) {
            defaults.removeObject(forKey: Keys.latestJSON)
        }
    }
}
