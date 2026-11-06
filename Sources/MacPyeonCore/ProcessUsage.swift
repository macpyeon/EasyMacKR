import Foundation

/// 누적 CPU·GPU 시간(나노초)을 두 번 재서 사용률로 바꾼다.
public struct UsageTracker: Sendable {
    private var lastCPU: [Int32: UInt64] = [:]
    private var lastGPU: [Int32: UInt64] = [:]
    private var lastTime: UInt64?

    public init() {}

    /// - Returns: pid별 사용률. CPU는 코어 하나 = 1.0 (여러 코어를 쓰면 1을 넘는다, 활동 모니터와 같음). GPU는 GPU 전체 = 1.0.
    ///   처음 부를 때는 비교할 값이 없어 빈 결과다.
    public mutating func update(now: UInt64, cpu: [Int32: UInt64], gpu: [Int32: UInt64]) -> (cpu: [Int32: Double], gpu: [Int32: Double]) {
        defer {
            lastCPU = cpu
            lastGPU = gpu
            lastTime = now
        }
        guard let last = lastTime, now > last else { return ([:], [:]) }
        let elapsed = Double(now - last)
        func rates(_ current: [Int32: UInt64], _ previous: [Int32: UInt64]) -> [Int32: Double] {
            var result: [Int32: Double] = [:]
            for (pid, value) in current {
                guard let old = previous[pid], value >= old else { continue }
                result[pid] = Double(value - old) / elapsed
            }
            return result
        }
        return (rates(cpu, lastCPU), rates(gpu, lastGPU))
    }
}

public enum ProcessRules {
    /// 끄면 Mac이 멈추거나 로그아웃되는 프로세스. 강제 종료를 막는다.
    public static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logind", "opendirectoryd",
        "securityd", "trustd", "configd", "mds", "coreservicesd", "SystemUIServer", "Dock", "Finder",
        "UserEventAgent", "powerd", "kextd", "syspolicyd", "tccd", "cfprefsd", "distnoted", "notifyd",
    ]

    public static func isProtected(pid: Int32, name: String, ownPID: Int32) -> Bool {
        pid <= 1 || pid == ownPID || protectedNames.contains(name)
    }

    /// 실행 파일이 들어 있는 가장 바깥쪽 .app 경로.
    /// 예) Chrome 도우미 프로세스 → "/Applications/Google Chrome.app" 로 묶는다.
    public static func outermostAppBundle(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// `ps -axo pid=,uid=,pcpu=,rss=,comm=` 한 줄을 읽는다. 명령 경로에는 공백이 있을 수 있다.
    public static func parsePSLine(_ line: Substring) -> (pid: Int32, uid: UInt32, cpu: Double, rssKB: UInt64, path: String)? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count == 5, let pid = Int32(parts[0]), let uid = UInt32(parts[1]),
              let cpu = Double(parts[2]), let rss = UInt64(parts[3]) else { return nil }
        return (pid, uid, cpu, rss, String(parts[4]))
    }

    /// ioreg의 "pid 407, WindowServer" 형식에서 pid를 꺼낸다.
    public static func pidFromCreator(_ text: String) -> Int32? {
        guard text.hasPrefix("pid ") else { return nil }
        let rest = text.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        return Int32(digits)
    }
}
