import CoreBluetooth
import Foundation
import IOKit
import MacPyeonCore

/// 블루투스 기기(에어팟, 키보드, 마우스 등)의 배터리.
///
/// 세 군데에서 모아 합친다.
/// 1. 시스템 정보(system_profiler): 에어팟·애플 기기
/// 2. IORegistry의 BatteryPercent: 매직 키보드·마우스·트랙패드
/// 3. 저전력 블루투스 배터리 서비스(0x180F): 다른 회사 키보드·마우스. 블루투스 권한이 필요해서 사용자가 켤 때만.
final class BluetoothBatteryMonitor: NSObject, ObservableObject {
    static let shared = BluetoothBatteryMonitor()

    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var loading = false
    @Published private(set) var bleState: String?

    private static let bleKey = "bluetoothBatteryLE"
    var bleEnabled: Bool { UserDefaults.standard.bool(forKey: Self.bleKey) }

    private var users = Set<String>()
    private var timer: Timer?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var bleLevels: [UUID: (name: String, level: Int)] = [:]
    /// 우리가 connect()로 맺은 연결(시스템이 이미 연결해 둔 것과 별개).
    private var ownConnections = Set<UUID>()
    private var profilerDevices: [DeviceBattery] = []
    private var registryDevices: [DeviceBattery] = []

    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    /// 화면에 보일 때만 1분마다 갱신한다.
    func use(_ who: String, _ on: Bool) {
        if on { users.insert(who) } else { users.remove(who) }
        if !users.isEmpty && timer == nil {
            refresh()
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if users.isEmpty {
            timer?.invalidate()
            timer = nil
            releaseBLE()
        }
    }

    /// 화면을 닫으면 앱이 맺은 연결을 놓는다(시스템 연결은 그대로).
    private func releaseBLE() {
        guard let central else { return }
        for p in peripherals.values where ownConnections.contains(p.identifier) {
            central.cancelPeripheralConnection(p)
        }
        ownConnections.removeAll()
        peripherals.removeAll()
    }

    /// 사용자가 '다른 회사 기기 배터리도 보기'를 누르면 블루투스 권한을 요청한다.
    func enableBLE() {
        UserDefaults.standard.set(true, forKey: Self.bleKey)
        startBLE()
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let profiler = Self.readSystemProfiler()
            let registry = Self.readRegistry()
            DispatchQueue.main.async {
                self.profilerDevices = profiler
                self.registryDevices = registry
                self.loading = false
                self.publish()
            }
        }
        if bleEnabled { startBLE() }
    }

    private func publish() {
        let ble = bleLevels.values.map { DeviceBattery(name: $0.name, kind: "", main: $0.level) }
        // 시스템 정보 목록이 기준(연결된 기기 전부), 나머지로 잔량을 채운다.
        devices = BluetoothBatteryParser.merge([profilerDevices, registryDevices, ble])
    }

    // MARK: 시스템 정보

    private static func readSystemProfiler() -> [DeviceBattery] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        // 멈추면 5초 뒤 포기한다.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return BluetoothBatteryParser.parseSystemProfiler(data)
    }

    // MARK: IORegistry

    private static func readRegistry() -> [DeviceBattery] {
        var result: [DeviceBattery] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let name = prop("Product") as? String, let level = (prop("BatteryPercent") as? NSNumber)?.intValue,
                  (0...100).contains(level) else { continue }
            result.append(DeviceBattery(name: name, kind: "", main: level))
        }
        return result
    }

    // MARK: 저전력 블루투스

    private func startBLE() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn {
            scanConnected()
        }
    }

    private func scanConnected() {
        guard let central else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        // 더 이상 연결돼 있지 않은 기기의 지난 잔량은 지운다.
        let ids = Set(connected.map(\.identifier))
        bleLevels = bleLevels.filter { ids.contains($0.key) }
        publish()
        for p in connected {
            peripherals[p.identifier] = p
            p.delegate = self
            if p.state == .connected {
                p.discoverServices([Self.batteryService])
            } else {
                ownConnections.insert(p.identifier)
                central.connect(p)
            }
        }
    }
}

extension BluetoothBatteryMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bleState = nil
            scanConnected()
        case .unauthorized:
            bleState = "블루투스 권한이 없어요. 시스템 설정 > 개인정보 보호 및 보안 > 블루투스에서 맥편해를 켜 주세요."
        case .poweredOff:
            bleState = "블루투스가 꺼져 있어요."
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        bleLevels[peripheral.identifier] = nil
        ownConnections.remove(peripheral.identifier)
        publish()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == Self.batteryLevel {
            peripheral.readValue(for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first, byte <= 100,
              let name = peripheral.name else { return }
        bleLevels[peripheral.identifier] = (name, Int(byte))
        publish()
    }
}
