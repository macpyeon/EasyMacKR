import Testing
@testable import MacPyeonCore

@Suite struct ProcessUsageTests {
    @Test func trackerComputesRatesFromDeltas() {
        var t = UsageTracker()
        let first = t.update(now: 1_000_000_000, cpu: [10: 0, 20: 5_000_000_000], gpu: [10: 0])
        #expect(first.cpu.isEmpty) // 처음엔 비교 대상 없음

        // 2초 동안 pid 10은 CPU 1초(=코어 하나의 50%), pid 20은 4초(=코어 2개 꽉 참)
        let second = t.update(now: 3_000_000_000, cpu: [10: 1_000_000_000, 20: 9_000_000_000, 30: 7], gpu: [10: 500_000_000])
        #expect(second.cpu[10] == 0.5)
        #expect(second.cpu[20] == 2.0)
        #expect(second.cpu[30] == nil) // 새로 생긴 프로세스는 다음 측정부터
        #expect(second.gpu[10] == 0.25)
    }

    @Test func trackerIgnoresReusedPIDs() {
        var t = UsageTracker()
        _ = t.update(now: 1, cpu: [10: 9_000], gpu: [:])
        let r = t.update(now: 2, cpu: [10: 100], gpu: [:]) // 같은 pid에 새 프로세스(값이 줄어듦)
        #expect(r.cpu[10] == nil)
    }

    @Test func protectsCriticalProcesses() {
        #expect(ProcessRules.isProtected(pid: 1, name: "launchd", ownPID: 500))
        #expect(ProcessRules.isProtected(pid: 400, name: "WindowServer", ownPID: 500))
        #expect(ProcessRules.isProtected(pid: 500, name: "MacPyeon", ownPID: 500))
        #expect(!ProcessRules.isProtected(pid: 900, name: "Google Chrome", ownPID: 500))
    }

    @Test func groupsHelpersUnderOutermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessRules.outermostAppBundle(forExecutable: helper) == "/Applications/Google Chrome.app")
        #expect(ProcessRules.outermostAppBundle(forExecutable: "/Applications/카카오톡.app/Contents/MacOS/KakaoTalk") == "/Applications/카카오톡.app")
        #expect(ProcessRules.outermostAppBundle(forExecutable: "/usr/sbin/cfprefsd") == nil)
    }

    @Test func parsesPSLines() {
        let row = ProcessRules.parsePSLine("  407    88  12.5 204800 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
        #expect(row?.pid == 407)
        #expect(row?.uid == 88)
        #expect(row?.cpu == 12.5)
        #expect(row?.rssKB == 204800)
        let spaced = ProcessRules.parsePSLine("123 501 0.0 1024 /Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        #expect(spaced?.path == "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        #expect(ProcessRules.parsePSLine("garbage") == nil)
    }

    @Test func parsesGPUCreator() {
        #expect(ProcessRules.pidFromCreator("pid 407, WindowServer") == 407)
        #expect(ProcessRules.pidFromCreator("something else") == nil)
    }
}

@Suite struct ConflictTests {
    @Test func detectsVorssaintScrollInverter() {
        let prefs: [String: Bool] = ["scrollInverterEnabled": true, "finderRenameEnabled": false]
        let found = Conflicts.find(
            enabled: [.mouseScrollReverse, .finderF2Rename, .windowSnap],
            readBool: { _, key in prefs[key] },
            isRunning: { $0 == "com.vorssaint.utils" })
        #expect(found == [FeatureConflict(appName: "Vorssaint", feature: .mouseScrollReverse)])
    }

    @Test func noConflictWhenOtherAppNotRunningOrFeatureOff() {
        let read: (String, String) -> Bool? = { _, _ in true }
        #expect(Conflicts.find(enabled: [.mouseScrollReverse], readBool: read, isRunning: { _ in false }).isEmpty)
        #expect(Conflicts.find(enabled: [], readBool: read, isRunning: { _ in true }).isEmpty)
    }
}
