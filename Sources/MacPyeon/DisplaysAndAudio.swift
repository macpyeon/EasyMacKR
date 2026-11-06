import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import IOKit
import MacPyeonCore

// MARK: - 디스플레이

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Int
    let pointHeight: Int
    let refreshRate: Double
    let scale: CGFloat

    var resolutionText: String { "\(pixelWidth) × \(pixelHeight)" }
    var looksLikeText: String { "\(pointWidth) × \(pointHeight)" + (scale > 1 ? " (HiDPI)" : "") }
}

/// 밝기를 바꾸는 방법.
enum BrightnessMethod: Equatable {
    /// 내장 화면: macOS 밝기 기능
    case builtin
    /// 외장 모니터: 케이블로 모니터 자체 밝기를 바꿈(DDC/CI)
    case ddc
    /// DDC를 지원하지 않는 모니터: 화면 위에 반투명 검은 막을 덮음
    case software
    case checking

    var title: String {
        switch self {
        case .builtin: return "내장 화면 밝기"
        case .ddc: return "모니터 밝기 (DDC)"
        case .software: return "화면 덮개로 어둡게 (모니터가 DDC 미지원)"
        case .checking: return "확인 중…"
        }
    }
}

/// 연결된 모니터 목록과 밝기 조절.
final class Displays: ObservableObject {
    static let shared = Displays()

    @Published private(set) var list: [DisplayInfo] = []
    /// 0...1 (1 = 가장 밝게)
    @Published private(set) var brightness: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var methods: [CGDirectDisplayID: BrightnessMethod] = [:]

    private let ddcQueue = DispatchQueue(label: "macpyeon.ddc", qos: .userInitiated)
    private var ddcServices: [CGDirectDisplayID: CFTypeRef] = [:]
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]
    private var pendingDDC: [CGDirectDisplayID: Double] = [:]
    private var ddcBusy = false
    private var overlays: [CGDirectDisplayID: NSWindow] = [:]

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    // MARK: 목록

    func refresh() {
        list = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(id)
            return DisplayInfo(
                id: id,
                name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0,
                pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor),
                pointWidth: Int(screen.frame.width),
                pointHeight: Int(screen.frame.height),
                refreshRate: mode?.refreshRate ?? 0,
                scale: screen.backingScaleFactor)
        }
        // 빠진 모니터의 덮개는 치운다.
        let ids = Set(list.map(\.id))
        for (id, w) in overlays where !ids.contains(id) { w.orderOut(nil); overlays[id] = nil }
        for (id, w) in overlays { positionOverlay(w, for: id) }
        detectMethods()
    }

    /// 모니터마다 밝기 조절 방법을 정하고 지금 밝기를 읽는다. DDC 응답은 느려서 백그라운드에서 한다.
    private func detectMethods() {
        for d in list where methods[d.id] == nil || methods[d.id] == .checking {
            if d.isBuiltin, let value = BuiltinBrightness.get(d.id) {
                methods[d.id] = .builtin
                brightness[d.id] = value
            } else if d.isBuiltin {
                methods[d.id] = .software
                brightness[d.id] = brightness[d.id] ?? 1
            } else {
                methods[d.id] = .checking
            }
        }
        let externals = list.filter { !$0.isBuiltin && methods[$0.id] == .checking }
        guard !externals.isEmpty else { return }
        ddcQueue.async { [weak self] in
            let services = DDCServices.byDisplay(externals.map(\.id))
            var found: [CGDirectDisplayID: (CFTypeRef, UInt16, UInt16)] = [:]
            for (id, service) in services {
                if let r = DDCServices.read(service, vcp: DDC.brightness) { found[id] = (service, r.current, r.max) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for d in externals {
                    if let (service, current, maxValue) = found[d.id] {
                        self.ddcServices[d.id] = service
                        self.ddcMax[d.id] = maxValue
                        self.methods[d.id] = .ddc
                        self.brightness[d.id] = Double(current) / Double(maxValue)
                    } else {
                        self.methods[d.id] = .software
                        self.brightness[d.id] = self.brightness[d.id] ?? 1
                    }
                }
            }
        }
    }

    // MARK: 밝기

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        let v = min(max(value, 0), 1)
        brightness[id] = v
        switch methods[id] ?? .software {
        case .builtin:
            BuiltinBrightness.set(id, v)
        case .ddc:
            pendingDDC[id] = v
            flushDDC()
        case .software, .checking:
            setOverlay(id, brightness: v)
        }
    }

    /// 슬라이더를 끌 때 DDC 명령이 쌓이지 않게 마지막 값만 보낸다(모니터는 초당 몇 번만 받을 수 있음).
    private func flushDDC() {
        guard !ddcBusy, let (id, value) = pendingDDC.first else { return }
        pendingDDC[id] = nil
        guard let service = ddcServices[id], let maxValue = ddcMax[id] else { return }
        ddcBusy = true
        ddcQueue.async { [weak self] in
            DDCServices.write(service, vcp: DDC.brightness, value: UInt16((value * Double(maxValue)).rounded()))
            usleep(60_000)
            DispatchQueue.main.async {
                self?.ddcBusy = false
                self?.flushDDC()
            }
        }
    }

    /// 덮개(소프트웨어 밝기)는 앱을 끄면 사라진다.
    func resetSoftware() {
        overlays.values.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        for (id, m) in methods where m == .software { brightness[id] = 1 }
    }

    private func setOverlay(_ id: CGDirectDisplayID, brightness v: Double) {
        // 완전히 까맣게 되지 않도록 최대 90%까지만 덮는다.
        let alpha = (1 - v) * 0.9
        if alpha < 0.01 {
            overlays[id]?.orderOut(nil)
            overlays[id] = nil
            return
        }
        let w = overlays[id] ?? {
            let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .black
            w.ignoresMouseEvents = true
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.sharingType = .none   // 스크린샷·화면 공유에는 덮개가 찍히지 않게
            w.hasShadow = false
            return w
        }()
        overlays[id] = w
        positionOverlay(w, for: id)
        w.alphaValue = alpha
        w.orderFrontRegardless()
    }

    private func positionOverlay(_ w: NSWindow, for id: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return }
        w.setFrame(screen.frame, display: true)
    }
}

/// 내장 화면 밝기(macOS DisplayServices).
enum BuiltinBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: GetFn? = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    static func get(_ id: CGDirectDisplayID) -> Double? {
        guard let getFn else { return nil }
        var value: Float = 0
        return getFn(id, &value) == 0 ? Double(value) : nil
    }

    static func set(_ id: CGDirectDisplayID, _ value: Double) {
        _ = setFn?(id, Float(value))
    }
}

/// 외장 모니터의 DDC 통로(Apple Silicon: IOAVService).
enum DDCServices {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private static let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create: CreateFn? = dlsym(io, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let writeI2C: I2CFn? = dlsym(io, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2CFn.self) }
    private static let readI2C: I2CFn? = dlsym(io, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2CFn.self) }

    /// 레지스트리를 순서대로 돌며 외장 화면(EDID)과 바로 뒤의 DDC 통로를 짝짓고, 제조사·모델 번호로 모니터에 연결한다.
    static func byDisplay(_ displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CFTypeRef] {
        guard let create else { return [:] }
        var found: [(vendor: UInt32, model: UInt32, service: CFTypeRef)] = []
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }
        var lastUUID: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var buf = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &buf)
            let cls = String(cString: buf)
            if cls == "IOMobileFramebufferShim" || cls == "AppleCLCD2" {
                lastUUID = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            } else if cls == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                guard location == "External", let uuid = lastUUID,
                      let ids = DDC.vendorAndModel(fromEDIDUUID: uuid),
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append((ids.vendor, ids.model, service))
                lastUUID = nil
            }
        }
        var result: [CGDirectDisplayID: CFTypeRef] = [:]
        for id in displays {
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
            if let i = found.firstIndex(where: { $0.vendor == vendor && $0.model == model }) {
                result[id] = found.remove(at: i).service
            }
        }
        return result
    }

    static func read(_ service: CFTypeRef, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let writeI2C, let readI2C else { return nil }
        for _ in 0..<3 {
            var request = DDC.getPacket(vcp)
            _ = request.withUnsafeMutableBytes { writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let rc = reply.withUnsafeMutableBytes { readI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            if rc == kIOReturnSuccess, let r = DDC.parseReply(reply, vcp: vcp) { return r }
            usleep(40_000)
        }
        return nil
    }

    static func write(_ service: CFTypeRef, vcp: UInt8, value: UInt16) {
        guard let writeI2C else { return }
        var packet = DDC.setPacket(vcp, value: value)
        // 일부 모니터는 첫 명령을 놓쳐서 두 번 보낸다.
        for _ in 0..<2 {
            _ = packet.withUnsafeMutableBytes { writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            usleep(20_000)
        }
    }
}

// MARK: - 사운드 장치

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
}

enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let out = channels(id, kAudioDevicePropertyScopeOutput) > 0
            let inp = channels(id, kAudioDevicePropertyScopeInput) > 0
            guard out || inp else { return nil }
            return AudioDevice(id: id, name: name(id) ?? "알 수 없는 장치", hasOutput: out, hasInput: inp)
        }
    }

    private static func name(_ id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func setDefault(_ id: AudioDeviceID, input: Bool) {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        if !input {
            // 알림음 출력도 같이 바꾼다.
            var sys = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sys, 0, nil,
                                       UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        }
    }

    // MARK: 출력 볼륨

    static func outputVolume() -> Double? {
        let id = defaultDevice(input: false)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func setOutputVolume(_ v: Double) {
        let id = defaultDevice(input: false)
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var value = Float32(min(max(v, 0), 1))
        AudioHardwareServiceSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if v > 0, isOutputMuted() { setOutputMuted(false) }
    }

    static func isOutputMuted() -> Bool {
        let id = defaultDevice(input: false)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted)
        return muted != 0
    }

    static func setOutputMuted(_ on: Bool) {
        let id = defaultDevice(input: false)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value: UInt32 = on ? 1 : 0
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: 마이크 음소거

    /// 음소거 속성이 없는 마이크는 입력 볼륨을 0으로 내렸다가 되돌린다.
    /// 앱이 꺼지거나 재부팅돼도 복구할 수 있게 저장한다.
    private static var savedInputVolume: Float32? {
        get { (UserDefaults.standard.object(forKey: "savedInputVolume") as? NSNumber)?.floatValue }
        set { UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: "savedInputVolume") }
    }

    /// 볼륨 0 방식으로 음소거해 둔 마이크를 원래 볼륨으로 돌린다.
    static func restoreMicIfMutedByVolume() {
        guard let saved = savedInputVolume else { return }
        let id = defaultDevice(input: true)
        var vol = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
        var v = saved
        AudioObjectSetPropertyData(id, &vol, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        savedInputVolume = nil
    }

    static func isMicMuted() -> Bool {
        let id = defaultDevice(input: true)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        if AudioObjectHasProperty(id, &addr) {
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted)
            return muted != 0
        }
        return savedInputVolume != nil
    }

    /// 음소거 상태를 바꾸고 바뀐 뒤 상태(true = 음소거)를 돌려준다.
    @discardableResult
    static func toggleMicMute() -> Bool {
        let id = defaultDevice(input: true)
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &addr), AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue {
            var value: UInt32 = isMicMuted() ? 0 : 1
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            return value != 0
        }
        var vol = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput)
        var size = UInt32(MemoryLayout<Float32>.size)
        if let saved = savedInputVolume {
            var v = saved
            AudioObjectSetPropertyData(id, &vol, 0, nil, size, &v)
            savedInputVolume = nil
            return false
        }
        var current: Float32 = 0
        AudioObjectGetPropertyData(id, &vol, 0, nil, &size, &current)
        var zero: Float32 = 0
        AudioObjectSetPropertyData(id, &vol, 0, nil, size, &zero)
        savedInputVolume = current
        return true
    }
}
