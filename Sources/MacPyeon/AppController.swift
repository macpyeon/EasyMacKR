import AppKit
import ApplicationServices
import Carbon
import IOKit.pwr_mgt
import MacPyeonCore
import ServiceManagement

/// 켜진 기능 목록을 실제 시스템 동작으로 옮긴다.
final class AppController {
    let store = FeatureStore()
    private let router = KeyRouter()
    private lazy var tap = EventTap { [router] type, event in router.handle(type: type, event: event) }
    private var watcher: FolderWatcher?
    private var permissionTimer: Timer?
    let services = ServiceProvider()
    let readout = StatsReadout()
    private let alerts = SystemAlerts()
    var onOpenDashboard: (() -> Void)?

    func start() {
        store.onChange = { [weak self] old, new in self?.featuresChanged(from: old, to: new, initial: false) }
        store.onOptionsChange = { [weak self] in self?.syncRouter() }
        store.onLaunchAtLoginChange = { [weak self] on in self?.setLaunchAtLogin(on) }
        store.onRequestAccessibility = { [weak self] in self?.requestAccessibility(prompt: true) }
        router.onNewTextFile = { FileActions.createNewTextFile() }
        router.onClipboardHistory = { ClipboardPanel.shared.toggle() }
        router.onTaskManager = { [store] in store.openTaskManager() }
        CleaningMode.shared.onChange = { [weak self] on in
            guard let self else { return }
            self.router.lockKeyboard = on
            self.updateTap()
        }
        services.zipEncoding = { [store] in store.zipEncoding }

        // 메뉴를 열었을 때 바로 정확한 수치를 보여 주도록 가볍게 계속 측정한다(2초 간격).
        SystemMonitor.shared.use("app", true)
        InputSourceSwitcher.remember()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { _ in InputSourceSwitcher.remember() }

        if store.isFirstLaunch {
            store.markLaunched()
            store.showWelcome = true
            // 설치하면 바로 추천 설정이 적용되게 한다. 로그인 시 자동 실행도 켠다.
            store.applyRecommended()
            setLaunchAtLogin(true)
        } else {
            featuresChanged(from: [], to: store.enabled, initial: true)
        }
        store.launchAtLogin = SMAppService.mainApp.status == .enabled
        requestAccessibility(prompt: store.needsAccessibility)
        startWatchdog()
    }

    func stop() {
        CapsLockRemap.set(false)
        AudioDevices.restoreMicIfMutedByVolume()
        KeepAwake.shared.stop()
        Displays.shared.resetSoftware()
        tap.stop()
        watcher?.stop()
    }

    // MARK: 기능 적용

    private func featuresChanged(from old: Set<FeatureID>, to new: Set<FeatureID>, initial: Bool) {
        var restarts = Set<RestartTarget>()
        for info in FeatureCatalog.all where info.kind == .defaults {
            let wasOn = old.contains(info.id), isOn = new.contains(info.id)
            for tweak in DefaultsTweaks.tweaks(for: info.id) {
                if isOn && (initial || !wasOn) {
                    if DefaultsApplier.apply(tweak), let r = tweak.restart { restarts.insert(r) }
                } else if !isOn && wasOn {
                    if DefaultsApplier.revert(tweak), let r = tweak.restart { restarts.insert(r) }
                }
            }
        }
        if !restarts.isEmpty { DefaultsApplier.restart(restarts) }

        let keyBindingIDs = FeatureCatalog.all.filter { $0.kind == .keyBinding }.map(\.id)
        if initial || keyBindingIDs.contains(where: { old.contains($0) != new.contains($0) }) {
            KeyBindingFile.sync(enabled: new)
        }

        // Caps Lock → F18 리매핑은 F18을 받아 줄 키보드 장치가 돌 때만 건다(아니면 Caps Lock이 먹통이 된다).
        if initial { CapsLockRemap.reconcile() }

        if new.contains(.nfcFilenames) {
            if watcher == nil {
                let w = FolderWatcher()
                watcher = w
                w.start()
            }
        } else {
            watcher?.stop()
            watcher = nil
        }

        checkConflicts()
        readout.set(new.contains(.menuBarStats))
        alerts.set(new.contains(.systemAlerts))
        ClipboardHistory.shared.update(record: new.contains(.clipboardHistory), clean: new.contains(.cleanURLs))

        syncRouter()
        if !initial && store.needsAccessibility && !store.accessibilityGranted {
            requestAccessibility(prompt: true)
        }
    }

    private func syncRouter() {
        router.rules.enabled = store.enabled
        router.scroll = ScrollOptions(enabled: store.enabled, linesPerNotch: store.linesPerNotch)
        readout.items = store.statItems
        if router.tapDetector.choice != store.hangulKey {
            router.tapDetector = ModifierTapDetector(choice: store.hangulKey)
        }
        updateTap()
    }

    private var tapRetryTimer: Timer?
    private var tapFailures = 0

    private func updateTap() {
        let wanted = store.needsAccessibility || CleaningMode.shared.isOn
        // 권한 여부는 매번 다시 확인한다(설정에서 껐다 켰을 수 있음).
        store.accessibilityGranted = AXIsProcessTrusted()
        if wanted && store.accessibilityGranted {
            if tap.isRunning || tap.start() {
                tapFailures = 0
                tapRetryTimer?.invalidate()
                tapRetryTimer = nil
                store.tapStatus = .running
                CapsLockRemap.set(store.isOn(.capsLockHangul))
                DebugLog.write("event tap running")
            } else {
                // 권한을 막 허용한 직후에는 탭 생성이 실패할 때가 있다. 잠시 뒤 다시 시도한다.
                tapFailures += 1
                store.tapStatus = tapFailures >= 3 ? .needsRestart : .starting
                DebugLog.write("event tap failed (\(tapFailures))")
                if tapRetryTimer == nil {
                    tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                        self?.updateTap()
                    }
                }
            }
        } else if wanted {
            CapsLockRemap.set(false)
            store.tapStatus = .needsPermission
        } else {
            tap.stop()
            CapsLockRemap.set(false)
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
            store.tapStatus = .off
        }
        writeStatus("updateTap")
    }

    // MARK: 안정화

    private var watchdog: Timer?
    private var watchdogTicks = 0

    /// 3초마다: 시스템이 꺼 버린 키보드·마우스 탭을 다시 켜고, 권한이 사라졌는지 보고,
    /// 같은 기능을 켠 다른 앱이 있는지 확인한다.
    private func startWatchdog() {
        checkConflicts()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.watchdogTicks += 1
            if self.tap.reviveIfNeeded() {
                DebugLog.write("event tap was disabled by the system, re-enabled")
                self.writeStatus("revived")
            }
            let trusted = AXIsProcessTrusted()
            if trusted != self.store.accessibilityGranted || (trusted && self.store.needsAccessibility && !self.tap.isRunning) {
                self.updateTap()
            }
            if self.watchdogTicks % 3 == 0 {
                self.checkConflicts()
                self.writeStatus("watchdog")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func checkConflicts() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let found = Conflicts.find(
            enabled: store.enabled,
            readBool: { domain, key in
                (CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber)?.boolValue
            },
            isRunning: { running.contains($0) })
        if found != store.conflicts { store.conflicts = found }
    }

    /// 진단용: 현재 상태를 파일에 남긴다. (~/Library/Application Support/MacPyeon/status.txt)
    private func writeStatus(_ note: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPyeon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = """
        time=\(Date())
        pid=\(ProcessInfo.processInfo.processIdentifier)
        axTrusted=\(AXIsProcessTrusted())
        needsAccessibility=\(store.needsAccessibility)
        tapRunning=\(tap.isRunning)
        tapStatus=\(store.tapStatus)
        failures=\(tapFailures)
        conflicts=\(store.conflicts.map { "\($0.appName):\($0.feature.rawValue)" })
        displays=\(Displays.shared.list.map { "\($0.name)=\(Displays.shared.methods[$0.id].map { "\($0)" } ?? "?"):\(Int((Displays.shared.brightness[$0.id] ?? -1) * 100))%" })
        note=\(note)
        """
        try? text.write(to: dir.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    }

    /// 앱을 다시 실행한다(권한을 허용했는데 키보드 기능이 안 켜질 때).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 경로를 셸 문자열에 끼워 넣지 않고 인자($0)로 넘긴다.
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: 권한

    /// 시스템 권한 요청 창은 실행할 때마다 한 번만 띄운다(설정 화면의 버튼은 시스템 설정을 직접 연다).
    private var didPrompt = false

    func requestAccessibility(prompt: Bool) {
        let showPrompt = prompt && !didPrompt
        if showPrompt { didPrompt = true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: showPrompt] as CFDictionary
        store.accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        updateTap()
        guard !store.accessibilityGranted, permissionTimer == nil else { return }
        // 허용할 때까지 기다렸다가 자동으로 켠다.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.writeStatus("poll")
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.permissionTimer = nil
                self.store.accessibilityGranted = true
                self.updateTap()
            }
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 로그인 시 실행

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("로그인 항목 변경 실패: \(error)")
        }
        store.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: 전부 되돌리기 (삭제용)

    static func resetEverything() {
        let saved = UserDefaults.standard.stringArray(forKey: FeatureStore.Keys.enabled) ?? []
        let enabled = Set(saved.compactMap(FeatureID.init(rawValue:)))
        var restarts = Set<RestartTarget>()
        for id in FeatureID.allCases {
            for tweak in DefaultsTweaks.tweaks(for: id) {
                if DefaultsApplier.revert(tweak), let r = tweak.restart { restarts.insert(r) }
            }
        }
        if !restarts.isEmpty { DefaultsApplier.restart(restarts) }
        if !enabled.isEmpty || UserDefaults.standard.stringArray(forKey: "keyBinding.managedKeys") != nil {
            KeyBindingFile.sync(enabled: [])
        }
        CapsLockRemap.set(false)
        AudioDevices.restoreMicIfMutedByVolume()
        if QuickTools.desktopIconsHidden { QuickTools.setDesktopIconsHidden(false) }
        try? SMAppService.mainApp.unregister()
        UserDefaults.standard.set([String](), forKey: FeatureStore.Keys.enabled)
        print("맥편해: 바꾼 설정을 모두 원래대로 돌렸어요.")
    }
}

/// 잠자기 방지.
final class Caffeine {
    private var assertion: IOPMAssertionID = 0
    private(set) var isOn = false

    func set(_ on: Bool) {
        guard on != isOn else { return }
        if on {
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "맥편해 잠자기 방지" as CFString,
                &assertion)
            isOn = ok == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            isOn = false
        }
    }
}

/// 진단 기록: ~/Library/Application Support/MacPyeon/debug.log (최근 200줄만 유지)
enum DebugLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPyeon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 200 { lines = Array(lines.suffix(200)) }
        try? (lines.joined(separator: "\n") + line).write(to: url, atomically: true, encoding: .utf8)
    }
}
