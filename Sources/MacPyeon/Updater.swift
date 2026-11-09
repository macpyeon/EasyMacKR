import AppKit
import Combine
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
    private var lastInstallLaunch: Date?
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

    /// brew로 설치했는지(그러면 터미널에서 brew로 업데이트한다).
    var installedWithBrew: Bool { brewPath != nil }

    func start() {
        noteLaunchVersion()
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
              let release = ReleaseInfo.parse(json: data) else { return }
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
            let release = body.flatMap(ReleaseInfo.parse(json:))
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

    /// brew로 깔았으면 터미널에서 업데이트 명령을 실행하고, 아니면 릴리스 페이지를 연다.
    func install() {
        let page = available?.pageURL ?? Self.releasesPage
        guard let brew = brewPath, let target = available?.version else {
            NSWorkspace.shared.open(page)
            return
        }
        // 연달아 누르면 brew가 두 번 돌다 잠금 때문에 실패한다: 잠깐은 열린 터미널만 앞으로.
        if let last = lastInstallLaunch, Date().timeIntervalSince(last) < 120 {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            return
        }
        // target은 숫자와 점으로만 이뤄진 문자열(AppVersion.description), brew는 고정 경로라 끼어들 여지가 없다.
        let script = """
        #!/bin/zsh
        clear
        BREW="\(brew)"
        TARGET="\(target.description)"
        APP="/Applications/MacPyeon.app"
        echo "맥편해를 $TARGET 버전으로 업데이트합니다…"
        echo
        echo "▸ 최신 목록 받는 중 (brew update)"
        "$BREW" update --quiet
        echo
        echo "▸ 업데이트 중"
        "$BREW" upgrade --cask macpyeon/tap/macpyeon
        NOW=$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
        echo
        if [[ "$NOW" == "$TARGET" ]]; then
          echo "✓ $TARGET 버전으로 업데이트했어요. 맥편해가 다시 켜집니다."
          echo "  키보드·마우스 기능이 멈추면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서"
          echo "  '맥편해'를 한 번 껐다가 다시 켜 주세요."
        else
          echo "✗ 아직 ${NOW:-이전} 버전이에요."
          echo "  새 버전이 막 나와서 brew 목록에 아직 안 올라왔을 수 있어요. 몇 분 뒤 다시 눌러 주세요."
        fi
        echo
        echo "이 창은 닫아도 됩니다."
        """
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPyeon", isDirectory: true)
        let url = dir.appendingPathComponent("update.command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            NSWorkspace.shared.open(page)
            return
        }
        lastInstallLaunch = Date()
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil {
                DispatchQueue.main.async {
                    self.lastInstallLaunch = nil
                    NSWorkspace.shared.open(page)
                }
            }
        }
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
