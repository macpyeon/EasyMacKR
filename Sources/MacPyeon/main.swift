import AppKit

// 보조 프로세스: 맥편해가 끝나면(강제 종료 포함) 기본 ⌘Tab을 되살린다.
if let i = CommandLine.arguments.firstIndex(of: NativeCommandTab.guardianFlag), i + 1 < CommandLine.arguments.count,
   let pid = pid_t(CommandLine.arguments[i + 1]) {
    NativeCommandTab.runGuardian(watching: pid)
}

// `MacPyeon --reset` : 바꾼 시스템 설정을 모두 원래대로 돌리고 끝낸다(삭제 스크립트가 쓴다).
if CommandLine.arguments.contains("--reset") {
    AppController.resetEverything()
    exit(0)
}

// `MacPyeon --render-panel <폴더>` : 간단 패널의 탭별 화면을 PNG로 저장한다(확인·문서용).
if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    PanelRenderer.render(to: CommandLine.arguments[i + 1])
    exit(0)
}

// `MacPyeon --demo-switcher` : 창 전환 목록을 몇 초 띄우고 창 번호를 출력한다(화면 확인용).
if CommandLine.arguments.contains("--demo-switcher") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    WindowSwitcher.demo = true
    DispatchQueue.main.async { WindowSwitcher.shared.open(forward: true) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        print("panel=\(WindowSwitcher.shared.panelWindowNumber ?? -1) count=\(WindowSwitcher.shared.windows.count)")
        fflush(stdout)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}

// `MacPyeon --demo-taskmanager` : 작업 관리자를 묶음을 펼친 채 몇 초 띄운다(화면 확인용).
if CommandLine.arguments.contains("--demo-taskmanager") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    TaskManagerView.demoExpandAll = true
    DispatchQueue.main.async { TaskManagerWindow.show() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        print("window=\(NSApp.windows.first { $0.title == "작업 관리자" }?.windowNumber ?? -1)")
        fflush(stdout)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
