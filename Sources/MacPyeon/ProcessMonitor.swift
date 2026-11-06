import AppKit
import Darwin
import IOKit
import MacPyeonCore

/// 작업 관리자 한 줄: 앱(도우미 프로세스 포함) 또는 프로세스 하나.
struct ProcessRow: Identifiable, Equatable {
    let id: Int32                 // 대표 pid
    let name: String
    let pids: [Int32]
    let app: NSRunningApplication?
    let isMine: Bool
    let user: String
    let cpu: Double               // 코어 하나 = 1.0
    let memory: UInt64            // 바이트
    let gpu: Double               // GPU 전체 = 1.0
    let isProtected: Bool

    var isApp: Bool { app != nil }
    var helperCount: Int { pids.count - 1 }

    static func == (a: ProcessRow, b: ProcessRow) -> Bool {
        a.id == b.id && a.cpu == b.cpu && a.memory == b.memory && a.gpu == b.gpu && a.pids == b.pids
    }
}

/// 프로세스별 CPU·메모리·GPU 사용량. 작업 관리자 창이 열려 있을 때만 잰다.
final class ProcessMonitor: ObservableObject {
    static let shared = ProcessMonitor()

    @Published private(set) var rows: [ProcessRow] = []
    @Published var groupByApp = true { didSet { rebuild() } }

    private var timer: Timer?
    private var tracker = UsageTracker()
    private let queue = DispatchQueue(label: "macpyeon.processes", qos: .utility)
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let ownUID = getuid()
    private var lastSamples: [Sample] = []
    private var users = 0

    struct Sample {
        let pid: Int32
        let uid: UInt32
        let path: String
        var cpu: Double
        var memory: UInt64
        var gpu: Double
    }

    func use(_ on: Bool) {
        users += on ? 1 : -1
        if users > 0, timer == nil {
            refresh()
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if users <= 0 {
            users = 0
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let samples = self.collect()
            DispatchQueue.main.async {
                self.lastSamples = samples
                self.rebuild()
            }
        }
    }

    // MARK: 측정 (백그라운드)

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    private func collect() -> [Sample] {
        let ps = readPS()
        var cpuNanos: [Int32: UInt64] = [:]
        var footprint: [Int32: UInt64] = [:]
        for entry in ps where entry.uid == ownUID {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(entry.pid, RUSAGE_INFO_V4, $0) }
            }
            guard rc == 0 else { continue }
            // Apple Silicon에서는 mach 시간 단위로 들어온다.
            let ticks = info.ri_user_time + info.ri_system_time
            cpuNanos[entry.pid] = ticks * Self.timebase.numer / Self.timebase.denom
            footprint[entry.pid] = info.ri_phys_footprint
        }
        let gpuNanos = readGPUTimes()
        let rates = tracker.update(now: DispatchTime.now().uptimeNanoseconds, cpu: cpuNanos, gpu: gpuNanos)

        return ps.map { e in
            // 내 프로세스는 정확한 값, 시스템 프로세스는 ps 값(권한 때문에 자세히 못 읽음)
            let cpu = rates.cpu[e.pid] ?? (cpuNanos[e.pid] == nil ? e.cpu / 100 : 0)
            let memory = footprint[e.pid] ?? e.rssKB * 1024
            return Sample(pid: e.pid, uid: e.uid, path: e.path, cpu: cpu, memory: memory, gpu: rates.gpu[e.pid] ?? 0)
        }
    }

    private func readPS() -> [(pid: Int32, uid: UInt32, cpu: Double, rssKB: UInt64, path: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,uid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap(ProcessRules.parsePSLine)
    }

    /// GPU 드라이버가 앱별로 기록하는 누적 GPU 시간(나노초).
    private func readGPUTimes() -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS
        else { return result }
        defer { IOObjectRelease(accelerators) }
        while case let accel = IOIteratorNext(accelerators), accel != 0 {
            defer { IOObjectRelease(accel) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      let pid = ProcessRules.pidFromCreator(creator),
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]]
                else { continue }
                let total = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                result[pid, default: 0] += total
            }
        }
        return result
    }

    // MARK: 표 만들기 (메인)

    private func rebuild() {
        let apps = NSWorkspace.shared.runningApplications
        let appByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        var appByBundlePath: [String: NSRunningApplication] = [:]
        for app in apps where app.activationPolicy == .regular {
            if let path = app.bundleURL?.path { appByBundlePath[path] = app }
        }

        func userName(_ uid: UInt32) -> String {
            if uid == ownUID { return "나" }
            if uid == 0 { return "시스템" }
            if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
            return "\(uid)"
        }

        func row(leader: Sample, members: [Sample], app: NSRunningApplication?) -> ProcessRow {
            let name = app?.localizedName ?? PosixFS.lastComponent(leader.path)
            return ProcessRow(
                id: leader.pid,
                name: name,
                pids: members.map(\.pid),
                app: app,
                isMine: leader.uid == ownUID,
                user: userName(leader.uid),
                cpu: members.reduce(0) { $0 + $1.cpu },
                memory: members.reduce(0) { $0 + $1.memory },
                gpu: members.reduce(0) { $0 + $1.gpu },
                isProtected: ProcessRules.isProtected(pid: leader.pid, name: PosixFS.lastComponent(leader.path), ownPID: ownPID))
        }

        guard groupByApp else {
            rows = lastSamples.map { row(leader: $0, members: [$0], app: appByPID[$0.pid]) }
            return
        }
        // 앱 번들 안에서 실행된 도우미 프로세스는 그 앱으로 묶는다.
        var groups: [String: [Sample]] = [:]
        var singles: [Sample] = []
        for s in lastSamples {
            if let bundle = ProcessRules.outermostAppBundle(forExecutable: s.path), appByBundlePath[bundle] != nil {
                groups[bundle, default: []].append(s)
            } else {
                singles.append(s)
            }
        }
        var result: [ProcessRow] = []
        for (bundle, members) in groups {
            guard let app = appByBundlePath[bundle] else { continue }
            let leader = members.first { $0.pid == app.processIdentifier } ?? members[0]
            result.append(row(leader: leader, members: members, app: app))
        }
        result += singles.map { row(leader: $0, members: [$0], app: appByPID[$0.pid]) }
        rows = result
    }

    // MARK: 종료

    enum KillResult { case done, needsAdmin, failed }

    /// force가 false면 정상 종료(앱은 저장 여부를 물을 수 있음), true면 강제 종료.
    @discardableResult
    func terminate(_ row: ProcessRow, force: Bool) -> KillResult {
        guard !row.isProtected else { return .failed }
        if let app = row.app {
            let ok = force ? app.forceTerminate() : app.terminate()
            if force { row.pids.filter { $0 != app.processIdentifier }.forEach { kill($0, SIGKILL) } }
            refreshSoon()
            return ok ? .done : .failed
        }
        var needsAdmin = false
        for pid in row.pids where kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            if errno == EPERM { needsAdmin = true }
        }
        refreshSoon()
        return needsAdmin ? .needsAdmin : .done
    }

    /// 다른 사용자(시스템) 프로세스를 관리자 암호를 받아 강제 종료한다.
    func terminateAsAdmin(_ row: ProcessRow) {
        guard !row.isProtected else { return }
        let pids = row.pids.map(String.init).joined(separator: " ")
        DispatchQueue.global().async {
            FileActions.runAppleScript("do shell script \"/bin/kill -9 \(pids)\" with administrator privileges")
            DispatchQueue.main.async { self.refreshSoon() }
        }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
    }
}
