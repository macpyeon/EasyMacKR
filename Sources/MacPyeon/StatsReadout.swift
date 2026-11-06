import AppKit
import Combine
import MacPyeonCore
import UserNotifications

/// 메뉴 막대 수치. 따로 항목을 만들지 않고 '편' 아이콘 옆에 두 줄로 작게 쌓아 그린다
/// (노치 때문에 메뉴 막대 공간이 좁아, 항목이 여러 개면 macOS가 숨겨 버린다).
final class StatsReadout {
    private var cancellable: AnyCancellable?
    private(set) var isOn = false
    var items: [StatItem] = StatItem.defaults { didSet { onRefresh?() } }
    /// 수치가 바뀔 때마다 아이콘을 다시 그리게 한다.
    var onRefresh: (() -> Void)?

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        if on {
            SystemMonitor.shared.use("readout", true)
            cancellable = SystemMonitor.shared.sampled.sink { [weak self] in self?.onRefresh?() }
        } else {
            cancellable = nil
            SystemMonitor.shared.use("readout", false)
        }
        onRefresh?()
    }

    /// 짧은 글자 줄들. 두 줄씩 한 칸으로 쌓는다.
    var lines: [String] {
        guard isOn else { return [] }
        let m = SystemMonitor.shared
        var result: [String] = []
        for stat in items {
            switch stat {
            case .cpu: result.append("CPU \(Format.percent(m.cpu))")
            case .gpu: if let g = m.gpu { result.append("GPU \(Format.percent(g))") }
            case .memory: result.append("RAM \(Format.percent(Double(m.memoryUsed) / Double(max(m.memoryTotal, 1))))")
            case .network:
                result.append("↓\(Format.rate(m.netIn))")
                result.append("↑\(Format.rate(m.netOut))")
            case .battery: if let b = m.battery { result.append((b.isCharging ? "⚡" : "BAT ") + Format.percent(b.percent)) }
            case .disk: result.append("SSD \(Format.bytes(m.diskFree))")
            }
        }
        return result
    }
}

/// 시스템 상태가 나쁠 때 알림을 보낸다. 같은 알림은 30분에 한 번만.
final class SystemAlerts {
    private var cancellable: AnyCancellable?
    private var lastSent: [String: Date] = [:]
    private var busyStreak = 0
    private let cooldown: TimeInterval = 30 * 60

    func set(_ on: Bool) {
        if on, cancellable == nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            SystemMonitor.shared.use("alerts", true)
            cancellable = SystemMonitor.shared.sampled.sink { [weak self] in self?.check() }
        } else if !on, cancellable != nil {
            cancellable = nil
            SystemMonitor.shared.use("alerts", false)
        }
    }

    private func check() {
        let m = SystemMonitor.shared
        busyStreak = m.cpu > 0.9 ? busyStreak + 1 : 0
        if busyStreak >= 30 { // 2초 × 30 = 1분 동안 90% 넘음
            send("cpu", "CPU가 1분 넘게 바빠요", "CPU 사용률이 \(Format.percent(m.cpu))예요. 활동 모니터에서 원인을 확인해 보세요.")
        }
        if m.memoryPressure >= 4 {
            send("memory", "메모리가 부족해요", "안 쓰는 앱이나 브라우저 탭을 닫으면 빨라져요.")
        }
        if m.diskTotal > 0 && m.diskFree < 10_000_000_000 {
            send("disk", "디스크 공간이 얼마 안 남았어요", "\(Format.bytes(m.diskFree)) 남았어요.")
        }
        if let b = m.battery, !b.onAC, b.percent <= 0.15 {
            send("battery", "배터리가 \(Format.percent(b.percent)) 남았어요", "전원을 연결해 주세요.")
        }
        if m.thermal == .serious || m.thermal == .critical {
            send("thermal", "Mac이 \(m.thermal.title)", "무거운 작업을 잠시 멈추면 성능 저하를 막을 수 있어요.")
        }
    }

    private func send(_ key: String, _ title: String, _ body: String) {
        if let last = lastSent[key], Date().timeIntervalSince(last) < cooldown { return }
        lastSent[key] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key + UUID().uuidString, content: content, trigger: nil))
    }
}
