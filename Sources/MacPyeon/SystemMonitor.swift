import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps
import MacPyeonCore

struct BatteryInfo: Equatable {
    var percent: Double            // 0...1
    var isCharging: Bool
    var onAC: Bool
    var minutesRemaining: Int?     // 방전/충전까지 남은 시간
    var cycleCount: Int?
    var health: Double?            // 최대 용량 / 설계 용량
    var temperature: Double?       // °C
    var watts: Double?             // + 충전, - 방전
    var adapterWatts: Int?
}

struct ProcessUsage: Identifiable, Equatable {
    let id: Int32
    let name: String
    let cpu: Double
}

/// CPU·GPU·메모리·배터리·디스크·네트워크 상태를 주기적으로 읽는다.
/// 필요한 곳(메뉴 막대 표시, 경고, 설정 화면)이 있을 때만 돈다.
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let historyLength = 60

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpu: Double?
    @Published private(set) var memoryUsed: UInt64 = 0
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var memoryPressure: Int = 1          // 1 정상, 2 주의, 4 위험
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var diskFree: UInt64 = 0
    @Published private(set) var diskTotal: UInt64 = 0
    @Published private(set) var netIn: Double = 0
    @Published private(set) var netOut: Double = 0
    @Published private(set) var netInHistory: [Double] = []
    @Published private(set) var netOutHistory: [Double] = []
    @Published private(set) var netSessionIn: UInt64 = 0
    @Published private(set) var netSessionOut: UInt64 = 0
    @Published private(set) var localIP: String?
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal
    /// 1분·5분·15분 평균 부하(실행을 기다리는 작업 수). 코어 수보다 크면 밀려 있다는 뜻.
    @Published private(set) var loadAverage: [Double] = [0, 0, 0]
    @Published private(set) var topProcesses: [ProcessUsage] = []
    @Published private(set) var temperatures = Temperatures()
    @Published private(set) var temperatureHistory: [Double] = []

    let memoryTotal = ProcessInfo.processInfo.physicalMemory

    /// 매 측정 뒤에 불린다(메뉴 막대 표시, 경고 검사용).
    let sampled = PassthroughSubject<Void, Never>()

    private var users = Set<String>()
    private var timer: Timer?
    /// GPU 사용률은 순간값이라 많이 튄다. 0.25초마다 재서 측정 주기(2초) 평균을 쓴다.
    private var gpuTimer: Timer?
    private var gpuSum = 0.0
    private var gpuCount = 0
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: (inBytes: UInt64, outBytes: UInt64, time: TimeInterval)?
    private var tick = 0
    private var wantsProcesses = false

    // MARK: 켜고 끄기

    /// 이름을 붙여 사용 등록한다. 아무도 안 쓰면 측정을 멈춘다.
    func use(_ name: String, _ on: Bool) {
        if on { users.insert(name) } else { users.remove(name) }
        wantsProcesses = users.contains("dashboard")
        if users.isEmpty {
            timer?.invalidate()
            timer = nil
            gpuTimer?.invalidate()
            gpuTimer = nil
        } else if timer == nil {
            sampleGPU()
            sample()
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            let g = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.sampleGPU() }
            g.tolerance = 0.05
            RunLoop.main.add(g, forMode: .common)
            gpuTimer = g
        }
    }

    // MARK: 측정

    private func sample() {
        tick += 1
        if let c = readCPU() { cpu = c; push(&cpuHistory, c) }
        // 지난 측정 이후 0.25초마다 모은 GPU 값의 평균
        if gpuCount > 0 {
            gpu = gpuSum / Double(gpuCount)
        } else {
            gpu = readGPU()
        }
        gpuSum = 0
        gpuCount = 0
        memoryUsed = readMemoryUsed()
        push(&memoryHistory, Double(memoryUsed) / Double(max(memoryTotal, 1)))
        memoryPressure = readMemoryPressure()
        readNetwork()
        thermal = ProcessInfo.processInfo.thermalState
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { loadAverage = loads }
        if tick % 5 == 1 {
            battery = readBattery()
            readDisk()
            localIP = readLocalIP()
        }
        if wantsProcesses && tick % 3 == 1 { readTopProcesses() }
        if tick % 2 == 1 || temperatures.chipAverage == nil {
            temperatures = TemperatureSensors.read()
            if let t = temperatures.chipAverage { push(&temperatureHistory, min(t / 110, 1)) }
        }
        sampled.send()
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private func readCPU() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let busy = user + system + nice, total = busy + idle
        defer { lastCPUTicks = (busy, total) }
        guard let last = lastCPUTicks, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    private func readMemoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        // 활동 모니터의 '사용된 메모리' = 앱 메모리 + 와이어드 + 압축됨
        let app = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    private func readMemoryPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return Int(level)
    }

    private func sampleGPU() {
        guard let value = readGPU() else { return }
        gpuSum += value
        gpuCount += 1
    }

    private func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let util = stats["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, util.doubleValue / 100)
        }
        return best
    }

    private func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let max = (desc[kIOPSMaxCapacityKey] as? Int) ?? 100
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let key = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (desc[key] as? Int).flatMap { $0 > 0 ? $0 : nil }
            var info = BatteryInfo(percent: Double(current) / Double(Swift.max(max, 1)), isCharging: charging,
                                   onAC: onAC, minutesRemaining: minutes)
            readSmartBattery(into: &info)
            if onAC, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                info.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            }
            return info
        }
        return nil
    }

    private func readSmartBattery(into info: inout BatteryInfo) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }
        info.cycleCount = dict["CycleCount"] as? Int
        let design = dict["DesignCapacity"] as? Int
        let maxCap = (dict["AppleRawMaxCapacity"] as? Int) ?? (dict["NominalChargeCapacity"] as? Int)
        if let design, let maxCap, design > 0 { info.health = min(Double(maxCap) / Double(design), 1.0) }
        if let t = dict["Temperature"] as? Int { info.temperature = Double(t) / 100 }
        if let mv = dict["Voltage"] as? Int, let ma = dict["Amperage"] as? Int {
            info.watts = Double(mv) * Double(ma) / 1_000_000
        }
    }

    private func readDisk() {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        diskTotal = UInt64(values?.volumeTotalCapacity ?? 0)
        diskFree = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private func readNetwork() {
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            // 실제 네트워크 장치만(Wi-Fi·이더넷·셀룰러). VPN(utun)은 중복 집계라 뺀다.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            inBytes += UInt64(d.ifi_ibytes)
            outBytes += UInt64(d.ifi_obytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastNet = (inBytes, outBytes, now) }
        guard let last = lastNet, now > last.time else { return }
        // if_data 카운터는 32비트라 4GB마다 0으로 돌아간다.
        // 인터페이스가 사라지면 합계가 줄 수 있다. 32비트 한 바퀴 넘김으로 보이는 경우만 보정하고 나머지는 0.
        func delta(_ new: UInt64, _ old: UInt64) -> UInt64 {
            if new >= old { return new - old }
            let wrapped = new &+ (1 << 32) &- old
            return wrapped < (1 << 31) ? wrapped : 0
        }
        let di = delta(inBytes, last.inBytes), dout = delta(outBytes, last.outBytes)
        netSessionIn += di
        netSessionOut += dout
        netIn = Double(di) / (now - last.time)
        netOut = Double(dout) / (now - last.time)
        push(&netInHistory, netIn)
        push(&netOutHistory, netOut)
    }

    private func readLocalIP() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        var found: String?
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if name == "en0" { return ip }
                found = found ?? ip
            }
        }
        return found
    }

    private func readTopProcesses() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-Aceo", "pid=,pcpu=,comm=", "-r"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(8)
            let result: [ProcessUsage] = lines.compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { return nil }
                return ProcessUsage(id: pid, name: String(parts[2]), cpu: cpu)
            }
            DispatchQueue.main.async { self.topProcesses = result }
        }
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: return "정상"
        case .fair: return "약간 따뜻함"
        case .serious: return "뜨거움"
        case .critical: return "매우 뜨거움"
        @unknown default: return "알 수 없음"
        }
    }
}

// MARK: - 온도

struct Temperatures: Equatable {
    /// 칩(SoC) 다이 센서 평균·최고 (°C). Apple Silicon은 CPU·GPU가 한 칩이다.
    var chipAverage: Double?
    var chipMax: Double?
    var ssd: Double?
    var battery: Double?
}

/// HID 온도 센서(관리자 권한 필요 없음). 센서 이름은 Apple Silicon 기준.
enum TemperatureSensors {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(handle, name).map { unsafeBitCast($0, to: type) }
    }
    private static let createClient = sym("IOHIDEventSystemClientCreate", CreateClient.self)
    private static let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatching.self)
    private static let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServices.self)
    private static let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyProperty.self)
    private static let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEvent.self)
    private static let getFloat = sym("IOHIDEventGetFloatValue", GetFloat.self)

    private static let temperatureEvent: Int64 = 15

    /// 센서 연결. 센서 목록이 이 연결에 매여 있어서, 연결이 해제되면 센서를 읽는 순간 앱이 죽는다. 앱이 끝날 때까지 붙잡아 둔다.
    private static let client: CFTypeRef? = createClient?(kCFAllocatorDefault)?.takeRetainedValue()

    /// 센서 목록은 한 번만 만든다.
    private static let services: [(name: String, service: CFTypeRef)] = {
        guard let client, let setMatching, let copyServices, let copyProperty else { return [] }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = (copyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        return list.map { s in
            ((copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String) ?? "", s)
        }
    }()

    static func read() -> Temperatures {
        guard client != nil, let copyEvent, let getFloat else { return Temperatures() }
        var chip: [Double] = [], ssd: [Double] = [], battery: [Double] = []
        for (name, service) in services {
            guard let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let t = getFloat(event, Int32(temperatureEvent << 16))
            guard t > 0, t < 130 else { continue }   // 고장·미사용 센서는 엉터리 값을 낸다
            if name.contains("tdie") { chip.append(t) }
            else if name.hasPrefix("NAND") { ssd.append(t) }
            else if name.lowercased().contains("battery") { battery.append(t) }
        }
        func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        return Temperatures(chipAverage: avg(chip), chipMax: chip.max(), ssd: avg(ssd), battery: avg(battery))
    }
}
