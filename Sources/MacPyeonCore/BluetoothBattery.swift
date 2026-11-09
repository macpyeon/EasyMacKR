import Foundation

/// 블루투스 기기 하나의 배터리.
public struct DeviceBattery: Equatable, Identifiable, Sendable {
    public let name: String
    public let kind: String
    /// 본체(또는 하나뿐인) 잔량. 에어팟은 왼쪽·오른쪽·케이스.
    public var main: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    public var id: String { name }

    public init(name: String, kind: String, main: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.name = name
        self.kind = kind
        self.main = main
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
    }

    public var hasLevel: Bool { main != nil || left != nil || right != nil || caseLevel != nil }

    /// 가장 낮은 잔량(경고용).
    public var lowest: Int? { [main, left, right].compactMap { $0 }.min() }

    public var symbol: String {
        switch kind.lowercased() {
        case let k where k.contains("keyboard"): return "keyboard"
        case let k where k.contains("mouse"): return "computermouse"
        case let k where k.contains("trackpad"): return "rectangle.and.hand.point.up.left"
        case let k where k.contains("headphone") || k.contains("headset") || k.contains("airpods"): return "airpodspro"
        case let k where k.contains("speaker"): return "hifispeaker"
        case let k where k.contains("gamepad") || k.contains("controller"): return "gamecontroller"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

public enum BluetoothBatteryParser {
    /// `system_profiler SPBluetoothDataType -json` 결과에서 연결된 기기의 배터리.
    public static func parseSystemProfiler(_ data: Data) -> [DeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var result: [DeviceBattery] = []
        for controller in controllers {
            guard let connected = controller["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    var device = DeviceBattery(name: name, kind: info["device_minorType"] as? String ?? "")
                    device.main = percent(info["device_batteryLevelMain"]) ?? percent(info["device_batteryLevel"])
                    device.left = percent(info["device_batteryLevelLeft"])
                    device.right = percent(info["device_batteryLevelRight"])
                    device.caseLevel = percent(info["device_batteryLevelCase"])
                    result.append(device)
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "85%", "85", 85 → 85
    static func percent(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return (0...100).contains(n.intValue) ? n.intValue : nil }
        guard let s = value as? String else { return nil }
        let digits = s.filter(\.isNumber)
        guard let n = Int(digits), (0...100).contains(n) else { return nil }
        return n
    }

    /// 여러 출처를 이름으로 합친다. 앞의 값이 있으면 그대로 두고 빈 값만 채운다.
    public static func merge(_ lists: [[DeviceBattery]]) -> [DeviceBattery] {
        var order: [String] = []
        var byName: [String: DeviceBattery] = [:]
        for list in lists {
            for d in list {
                if var existing = byName[d.name] {
                    existing.main = existing.main ?? d.main
                    existing.left = existing.left ?? d.left
                    existing.right = existing.right ?? d.right
                    existing.caseLevel = existing.caseLevel ?? d.caseLevel
                    byName[d.name] = existing
                } else {
                    byName[d.name] = d
                    order.append(d.name)
                }
            }
        }
        return order.compactMap { byName[$0] }
    }
}
