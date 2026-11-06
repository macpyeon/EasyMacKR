import Foundation
import MacPyeonCore

/// defaults 값을 바꾸고, 처음 바꾸기 전 값을 보관했다가 되돌린다.
enum DefaultsApplier {
    private static let store = UserDefaults.standard

    private static func appID(_ domain: String) -> CFString {
        domain == DefaultsTweak.globalDomain ? kCFPreferencesAnyApplication : domain as CFString
    }

    private static func read(_ t: DefaultsTweak) -> Any? {
        CFPreferencesCopyValue(t.key as CFString, appID(t.domain), kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func write(_ t: DefaultsTweak, _ value: Any?) {
        let app = appID(t.domain)
        CFPreferencesSetValue(t.key as CFString, value as CFPropertyList?, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func same(_ a: Any?, _ b: Any) -> Bool {
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }

    /// 값을 적용한다. 실제로 바뀌었으면 true.
    @discardableResult
    static func apply(_ t: DefaultsTweak) -> Bool {
        let current = read(t)
        if store.object(forKey: t.backupKey) == nil {
            let backup: [String: Any] = current.map { ["value": $0] } ?? ["absent": true]
            store.set(backup, forKey: t.backupKey)
        }
        guard !same(current, t.value.propertyListValue) else { return false }
        write(t, t.value.propertyListValue)
        return true
    }

    /// 보관해 둔 원래 값으로 되돌린다. 실제로 바뀌었으면 true.
    @discardableResult
    static func revert(_ t: DefaultsTweak) -> Bool {
        guard let backup = store.dictionary(forKey: t.backupKey) else { return false }
        store.removeObject(forKey: t.backupKey)
        let original = backup["value"]
        let current = read(t)
        if let original, same(current, original) { return false }
        if original == nil && current == nil { return false }
        write(t, original)
        return true
    }

    static func restart(_ targets: Set<RestartTarget>) {
        for target in targets {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = [target.rawValue]
            try? p.run()
            p.waitUntilExit()
        }
    }
}

/// ~/Library/KeyBindings/DefaultKeyBinding.dict 관리.
enum KeyBindingFile {
    private static let store = UserDefaults.standard
    private static let managedKeysKey = "keyBinding.managedKeys"
    private static let overriddenKey = "keyBinding.overridden"
    private static let createdKey = "keyBinding.createdFile"

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/KeyBindings/DefaultKeyBinding.dict")
    }

    static func sync(enabled: Set<FeatureID>) {
        let managed = KeyBindings.entries(for: enabled)
        let previousKeys = Set(store.stringArray(forKey: managedKeysKey) ?? [])
        if managed.isEmpty && previousKeys.isEmpty { return }

        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        var existing: [String: Any] = [:]
        if exists {
            guard let data = try? Data(contentsOf: url) else { return }
            // 원래 사용자 파일은 내용과 상관없이 한 번만 그대로 보관한다.
            let backup = url.appendingPathExtension("macpyeon-backup")
            if previousKeys.isEmpty && !fm.fileExists(atPath: backup.path) {
                try? data.write(to: backup)
            }
            guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                // 사용자가 직접 고친 파일에 문법 오류가 있으면 덮어쓰지 않는다.
                DebugLog.write("keybinding: 기존 파일을 읽을 수 없어 손대지 않음")
                return
            }
            existing = parsed
        }
        if !exists { store.set(true, forKey: createdKey) }

        let result = KeyBindings.merge(
            existing: existing,
            previouslyManaged: previousKeys,
            previouslyOverridden: store.dictionary(forKey: overriddenKey) ?? [:],
            managed: managed
        )

        if result.contents.isEmpty && store.bool(forKey: createdKey) {
            try? fm.removeItem(at: url)
            store.removeObject(forKey: createdKey)
        } else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: result.contents, format: .xml, options: 0) {
                try? data.write(to: url, options: .atomic)
            }
        }
        store.set(Array(result.managedKeys), forKey: managedKeysKey)
        store.set(result.overridden, forKey: overriddenKey)
    }
}

/// Caps Lock을 F18로 바꿔(hidutil) 지연 없이 한/영 전환에 쓴다. 재부팅하면 풀리므로 앱이 켜질 때마다 다시 건다.
enum CapsLockRemap {
    /// 앱이 비정상 종료돼도 다음 실행 때 풀 수 있게 저장해 둔다.
    private static var active: Bool {
        get { UserDefaults.standard.bool(forKey: "capsLockRemapActive") }
        set { UserDefaults.standard.set(newValue, forKey: "capsLockRemapActive") }
    }

    private static let capsLock: UInt64 = 0x7_0000_0039
    private static let f18: UInt64 = 0x7_0000_006D

    /// 앱을 시작할 때 부른다. 재부팅·강제 종료 뒤에는 저장된 상태와 실제 상태가 다를 수 있어서,
    /// 켤 거면 다시 걸고, 끌 거면(예전에 걸어 둔 게 남아 있을 수 있으니) 확실히 푼다.
    static func reconcile() {
        // 예전에 맥편해가 걸어 둔 기록이 있을 때만 푼다(다른 도구의 매핑은 건드리지 않음).
        // 다시 걸어야 하면 키보드 장치가 동작을 시작할 때 건다.
        if active { set(false) }
    }

    static func set(_ on: Bool) {
        guard on != active else { return }
        let mapping = on
            ? "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(capsLock),\"HIDKeyboardModifierMappingDst\":\(f18)}]}"
            : "{\"UserKeyMapping\":[]}"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", mapping]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            active = on
        } catch {
            NSLog("hidutil 실행 실패: \(error)")
        }
    }
}
