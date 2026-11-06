import AppKit
import MacPyeonCore
import SwiftUI
import Vision

/// 메뉴와 단축키로 부르는 한 번짜리 도구들.
enum QuickTools {
    // MARK: 화면

    static func toggleDarkMode() {
        DispatchQueue.global().async {
            FileActions.runAppleScript("""
            tell application "System Events" to tell appearance preferences to set dark mode to not dark mode
            """)
        }
    }

    static var desktopIconsHidden: Bool {
        let v = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool
        return v == false
    }

    static func setDesktopIconsHidden(_ hidden: Bool) {
        let app = "com.apple.finder" as CFString
        CFPreferencesSetAppValue("CreateDesktop" as CFString, hidden ? false as CFBoolean : nil, app)
        CFPreferencesAppSynchronize(app)
        DefaultsApplier.restart([.finder])
    }

    static func lockScreen() {
        // 시스템의 화면 잠금 단축키(⌃⌘Q)
        KeySender.post(key: KeyCode.q, modifiers: [.control, .command])
    }

    static func sleepDisplays() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    // MARK: 파일·앱

    static func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "휴지통을 비울까요?"
        alert.informativeText = "휴지통의 항목이 영구적으로 지워집니다."
        alert.addButton(withTitle: "비우기")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global().async {
            FileActions.runAppleScript("tell application \"Finder\" to empty trash")
        }
    }

    static func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !(v.volumeIsInternal ?? true)
        }
    }

    static func ejectAll() {
        let volumes = ejectableVolumes()
        guard !volumes.isEmpty else {
            HUD.show("꺼낼 디스크가 없어요", symbol: "externaldrive")
            return
        }
        DispatchQueue.global().async {
            var failed: [String] = []
            for url in volumes {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { failed.append(url.lastPathComponent) }
            }
            DispatchQueue.main.async {
                if failed.isEmpty {
                    HUD.show("디스크 \(volumes.count)개를 꺼냈어요", symbol: "eject.fill")
                } else {
                    HUD.show("사용 중이라 못 꺼냈어요: \(failed.joined(separator: ", "))", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    static func quitApps(exceptFrontmost: Bool) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in runningApps() where !(exceptFrontmost && app.processIdentifier == front) {
            app.terminate()
        }
    }

    // MARK: 색상·글자

    static func pickColor() {
        NSColorSampler().show { color in
            guard let rgb = color?.usingColorSpace(.sRGB) else { return }
            let hex = Format.hex(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            HUD.show("\(hex) 복사함", symbol: "eyedropper", color: Color(nsColor: rgb))
        }
    }

    /// 영역을 고르면 그 안의 글자(한국어·영어)를 인식해 클립보드에 복사한다.
    static func copyTextFromScreen() {
        DispatchQueue.global(qos: .userInitiated).async {
            let path = NSTemporaryDirectory() + "macpyeon-ocr-\(UUID().uuidString).png"
            defer { unlink(path) }
            run("/usr/sbin/screencapture", ["-i", "-x", path])
            guard let image = NSImage(contentsOfFile: path),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR", "en-US"]
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            DispatchQueue.main.async {
                guard !lines.isEmpty else {
                    HUD.show("글자를 찾지 못했어요", symbol: "text.viewfinder")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                HUD.show("글자 \(lines.count)줄을 복사했어요", symbol: "text.viewfinder")
            }
        }
    }

    static func toggleMicMute() {
        let muted = AudioDevices.toggleMicMute()
        HUD.show(muted ? "마이크 꺼짐" : "마이크 켜짐", symbol: muted ? "mic.slash.fill" : "mic.fill")
    }

    // MARK: Finder 이미지 붙여넣기

    /// 클립보드에 파일이 아니라 이미지가 있으면 지금 Finder 폴더에 PNG로 저장한다. 저장했으면 true.
    static func pasteImageIntoFinder() -> Bool {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        guard !types.contains(.fileURL), types.contains(.png) || types.contains(.tiff) else { return false }
        let pngData = pb.data(forType: .png)
        let tiffData = pngData == nil ? pb.data(forType: .tiff) : nil
        DispatchQueue.global(qos: .userInitiated).async {
            guard let png = pngData ?? tiffData.flatMap({ NSImage(data: $0)?.pngData }) else { return }
            let dir = FileActions.finderFrontFolder() ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let path = NFCRenamer.uniquePath(in: dir, base: "붙여넣은 이미지 \(f.string(from: Date()))", ext: "png")
            do {
                try PosixFS.createEmptyFile(path)
                try png.write(to: URL(fileURLWithPath: path))
                DispatchQueue.main.async { HUD.show("이미지를 파일로 저장했어요", symbol: "photo") }
            } catch {
                DispatchQueue.main.async { HUD.show("이미지를 저장하지 못했어요", symbol: "exclamationmark.triangle") }
            }
        }
        return true
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - 잠자기 방지 (타이머)

final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    @Published private(set) var isOn = false
    @Published private(set) var until: Date?
    private let caffeine = Caffeine()
    private var timer: Timer?

    /// minutes가 nil이면 끌 때까지.
    func start(minutes: Int?) {
        caffeine.set(true)
        isOn = caffeine.isOn
        timer?.invalidate()
        until = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        if let minutes {
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        until = nil
        caffeine.set(false)
        isOn = false
    }
}

// MARK: - 화면 안내(HUD)

enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String, color: Color? = nil) {
        let view = HStack(spacing: 10) {
            if let color {
                RoundedRectangle(cornerRadius: 5).fill(color).frame(width: 22, height: 22)
            } else {
                Image(systemName: symbol).font(.title2)
            }
            Text(text).font(.headline)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()

        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hasShadow = true
            return p
        }()
        panel = p
        p.contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.18, width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}

// MARK: - 청소 모드

/// 키보드 입력을 잠그고 화면을 검게 덮는다. 마우스로 '끝내기'를 눌러 빠져나온다.
final class CleaningMode {
    static let shared = CleaningMode()
    private var windows: [NSWindow] = []
    var onChange: ((Bool) -> Void)?

    var isOn: Bool { !windows.isEmpty }

    func start() {
        guard !isOn else { return }
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.isOpaque = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: CleaningView { [weak self] in self?.stop() })
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        onChange?(true)
    }

    func stop() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        onChange?(false)
    }
}

private struct CleaningView: View {
    let onExit: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6))
            Text("청소 모드").font(.largeTitle.bold()).foregroundStyle(.white)
            Text("키보드가 잠겨 있어요. 마음껏 닦으세요.").foregroundStyle(.white.opacity(0.7))
            Button("청소 끝내기", action: onExit)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - 포트 관리

struct ListeningPort: Identifiable, Hashable {
    var id: String { "\(pid)-\(address)" }
    let pid: Int32
    let process: String
    let address: String

    var port: String { address.split(separator: ":").last.map(String.init) ?? address }
}

enum PortManager {
    /// 지금 연결을 기다리는(LISTEN) TCP 포트. 내 계정의 프로세스만 보인다.
    static func list() -> [ListeningPort] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var result = Set<ListeningPort>()
        var pid: Int32 = 0, command = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n": result.insert(ListeningPort(pid: pid, process: command, address: value))
            default: break
            }
        }
        return result.sorted { (Int($0.port) ?? 0, $0.pid) < (Int($1.port) ?? 0, $1.pid) }
    }

    @discardableResult
    static func stop(_ pid: Int32, force: Bool = false) -> Bool {
        kill(pid, force ? SIGKILL : SIGTERM) == 0
    }
}
