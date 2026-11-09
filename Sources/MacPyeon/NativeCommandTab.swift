import AppKit
import Darwin

/// 맥 기본 ⌘Tab(앱 전환기)을 끄고 켠다.
///
/// 시스템 단축키를 끄면 앱이 끝난 뒤에도 꺼진 채로 남는다(다시 로그인해야 돌아온다).
/// 그래서 끌 때는 반드시 되돌릴 길을 여러 겹 둔다.
/// - 기능 끄기·키보드 탭 중단·권한 없음·보안 입력: 앱이 바로 켠다.
/// - 정상 종료·종료 신호(SIGTERM 등): 앱이 켠다.
/// - 강제 종료·크래시·앱이 멈춤: 지켜보는 보조 프로세스가 켠다. 앱은 0.5초마다 파이프로 신호를 보내고,
///   신호가 끊기면(멈춤) 또는 파이프가 닫히면(종료) 보조 프로세스가 ⌘Tab을 되살린다.
///   보조 프로세스를 띄우지 못하면 아예 ⌘Tab을 넘겨받지 않는다.
enum NativeCommandTab {
    /// 시스템 단축키 번호: ⌘Tab, ⌘⇧Tab. (⌘`는 같은 앱 창 전환이라 그대로 둔다)
    private static let hotKeys: [Int32] = [1, 2]

    private typealias SetFn = @convention(c) (Int32, Bool) -> Int32
    private typealias IsFn = @convention(c) (Int32) -> Bool
    private static let setFn: SetFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(s, to: SetFn.self)
    }()
    private static let isFn: IsFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "CGSIsSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(s, to: IsFn.self)
    }()

    /// 이 Mac에서 기본 ⌘Tab을 끌 수 있는지(못 끄면 맥편해 창 전환은 쓰지 않는다).
    static var canTakeOver: Bool { setFn != nil }

    private(set) static var takenOver = false
    private static var guardian: Process?
    private static var heartbeatFD: Int32 = -1
    /// 맥편해가 기본 ⌘Tab을 꺼 둔 상태인지(앱이 끝난 뒤에도 남는다). 다른 앱이 꺼 둔 것은 건드리지 않으려고 쓴다.
    private static let markerKey = "nativeCommandTabTakenOver"

    /// true면 기본 ⌘Tab을 끄고 맥편해가 받는다. 0.5초마다 불러도 된다(다른 쪽이 켜 놨으면 다시 끈다).
    /// false일 때 restoreNative가 false면 켜지 않고 표시만 지운다(⌘Tab을 쓰는 다른 전환 앱에 넘길 때).
    static func set(takenOver want: Bool, restoreNative: Bool = true) {
        guard let setFn else { return }
        if want {
            installSignalHandlers()
            // 지켜보는 보조 프로세스 없이 끄면, 강제 종료 때 ⌘Tab을 영영 잃는다.
            guard startGuardian() else {
                if takenOver { set(takenOver: false) }
                return
            }
            heartbeat()
            if !takenOver || isSystemEnabled {
                UserDefaults.standard.set(true, forKey: markerKey)
                for k in hotKeys { _ = setFn(k, false) }
                if !takenOver { DebugLog.write("native ⌘Tab off (MacPyeon window switcher)") }
            }
            takenOver = true
        } else if takenOver || UserDefaults.standard.bool(forKey: markerKey) {
            // 지난번에 비정상으로 끝나 꺼진 채 남은 경우도 여기서 되살린다.
            if restoreNative { restore() }
            UserDefaults.standard.removeObject(forKey: markerKey)
            takenOver = false
            DebugLog.write(restoreNative ? "native ⌘Tab restored" : "⌘Tab handed to another switcher")
        }
    }

    private static var isSystemEnabled: Bool {
        guard let isFn else { return true }
        return hotKeys.contains { isFn($0) }
    }

    /// 기본 ⌘Tab을 켠다.
    static func restore() {
        guard let setFn else { return }
        for k in hotKeys { _ = setFn(k, true) }
    }

    /// 정상 종료·삭제 때: 맥편해가 꺼 둔 경우에만 켠다.
    static func restoreAndClearMarker() {
        guard UserDefaults.standard.bool(forKey: markerKey) || takenOver else { return }
        restore()
        UserDefaults.standard.removeObject(forKey: markerKey)
        takenOver = false
    }

    // MARK: 종료 신호

    private static var handlersInstalled = false

    /// 종료 신호에서만 되살린다. 크래시 신호에서는 잠금이 걸린 채일 수 있어 아무것도 하지 않고 보조 프로세스에 맡긴다.
    private static func installSignalHandlers() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        signal(SIGPIPE, SIG_IGN)   // 보조 프로세스가 죽은 뒤 파이프에 써도 앱이 끝나지 않게
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig) { s in
                if NativeCommandTab.takenOver { NativeCommandTab.restore() }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        NSSetUncaughtExceptionHandler { _ in
            if NativeCommandTab.takenOver { NativeCommandTab.restore() }
        }
    }

    // MARK: 보조 프로세스

    /// 보조 프로세스가 돌고 있으면 true(없으면 띄운다).
    private static func startGuardian() -> Bool {
        if let g = guardian, g.isRunning { return true }
        if heartbeatFD >= 0 { close(heartbeatFD); heartbeatFD = -1 }
        guard let exe = Bundle.main.executableURL else { return false }
        let pipe = Pipe()
        let p = Process()
        p.executableURL = exe
        p.arguments = [guardianFlag, String(ProcessInfo.processInfo.processIdentifier)]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            DebugLog.write("guardian start failed: \(error)")
            return false
        }
        // 읽는 쪽은 보조 프로세스만 갖는다(그래야 앱이 끝나면 파이프가 닫힌 걸 알 수 있다).
        try? pipe.fileHandleForReading.close()
        heartbeatFD = dup(pipe.fileHandleForWriting.fileDescriptor)
        try? pipe.fileHandleForWriting.close()
        guardian = p
        return true
    }

    /// 앱이 살아 있다는 신호. 메인 스레드에서 불러야 의미가 있다(멈추면 신호도 끊긴다).
    private static func heartbeat() {
        guard heartbeatFD >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(heartbeatFD, &byte, 1)
    }

    static let guardianFlag = "--guard-command-tab"
    /// 앱 신호가 이만큼 끊기면 멈춘 것으로 보고 ⌘Tab을 되살린다(앱이 깨어나면 다시 넘겨받는다).
    private static let hangLimit: TimeInterval = 2.5

    /// 보조 프로세스 본체.
    static func runGuardian(watching pid: pid_t) -> Never {
        // 앱과 다른 프로세스 그룹으로(앱 쪽 정리에 같이 끝나지 않게).
        setsid()
        for s in [SIGINT, SIGHUP, SIGTERM, SIGPIPE] { signal(s, SIG_IGN) }

        func markerSet() -> Bool {
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            return UserDefaults.standard.bool(forKey: markerKey)
        }
        func finish() -> Never {
            // 앱이 정상으로 끝나며 이미 되돌렸으면 표시가 지워져 있다. 그때는 손대지 않는다(다른 창 전환 앱 보호).
            if markerSet() {
                restore()
                UserDefaults.standard.removeObject(forKey: markerKey)
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            }
            exit(0)
        }

        var lastBeat = Date()
        var restoredForHang = false
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        input.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64)
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n <= 0 { finish() }   // 파이프가 닫힘: 앱이 끝났다(강제 종료 포함)
            lastBeat = Date()
            restoredForHang = false
        }
        input.resume()
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { finish() }
        exitSource.resume()
        let check = DispatchSource.makeTimerSource(queue: .main)
        check.schedule(deadline: .now() + 1, repeating: 0.5)
        check.setEventHandler {
            if kill(pid, 0) != 0 && errno == ESRCH { finish() }
            // 앱이 멈췄다: ⌘Tab만 되살려 둔다(표시는 남겨 둬서, 앱이 깨어나면 다시 넘겨받는다).
            if !restoredForHang, Date().timeIntervalSince(lastBeat) > hangLimit, markerSet() {
                restore()
                restoredForHang = true
            }
        }
        check.resume()
        if kill(pid, 0) != 0 && errno == ESRCH { finish() }
        dispatchMain()
    }
}
