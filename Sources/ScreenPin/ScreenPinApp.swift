import AppKit

@main
enum ScreenPinApp {
    static func main() {
        // 诊断探针：ScreenPin --check-permission 直接打印屏幕录制授权状态后退出
        if CommandLine.arguments.contains("--check-permission") {
            print(CaptureService.hasPermission ? "PERMISSION_GRANTED" : "PERMISSION_MISSING")
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // 菜单栏 App，不出现在 Dock
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager()
    private let snipController = SnipOverlayController()
    private var pinControllers: [PinWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        hotkeyManager.onHotkey = { [weak self] in self?.startSnip() }
        hotkeyManager.register()
        if !UserDefaults.standard.bool(forKey: "screenpin.launchedBefore") {
            UserDefaults.standard.set(true, forKey: "screenpin.launchedBefore")
            showHelp()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "scissors",
            accessibilityDescription: "ScreenPin"
        )

        let menu = NSMenu()

        let snipItem = NSMenuItem(title: L("Snip (⌃⌥X)"), action: #selector(snipAction), keyEquivalent: "")
        snipItem.target = self
        menu.addItem(snipItem)

        let clearItem = NSMenuItem(title: L("Close All Pins"), action: #selector(closeAllPinsAction), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let helpItem = NSMenuItem(title: L("How to Use…"), action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("Quit ScreenPin"), action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func snipAction() {
        startSnip()
    }

    @objc private func closeAllPinsAction() {
        // close() 会回调 onClose 从数组移除自身，先拷贝再清空避免遍历中修改
        let all = pinControllers
        pinControllers.removeAll()
        all.forEach { $0.close() }
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    /// 使用说明（首次启动自动弹出，也可从菜单栏菜单打开）
    @objc private func showHelp() {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = L("ScreenPin Guide")
        alert.informativeText = L("""
        This app has no main window or Dock icon — it lives in the menu bar as a ✂ icon at the top right.

        ⌃⌥X Snip: freezes the screen first, then drag to select (even pull-down menus can be captured). The image pins in place and is copied to the clipboard. ESC cancels while selecting.
        Annotate: B pen, A arrow, T text (click to place; long text wraps automatically), C cycles colors; or click the ✕ button at the top-left of the pin.
        Enter confirms and steps out layer by layer: while typing = commit text, in annotation mode = exit annotation (back to dragging), on a plain pin = finish and close.
        ESC cancels and discards: while typing = discard this text, in annotation mode = exit and discard the strokes made this round, on a plain pin = discard the pin.
        ⌘S save to Desktop, ⇧⌘S save and copy the file path instead, ⌘C copy (annotations included), ⌘Z undo last stroke, ⌘W discard. Annotations sync to the clipboard after every stroke — just ⌘V.
        Right-click a pin: colors, opacity, click-through.

        Screen Recording permission is required on first snip.
        """)
        alert.addButton(withTitle: L("Got It"))
        if !CaptureService.hasPermission {
            alert.addButton(withTitle: L("Grant Screen Recording"))
        }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            CaptureService.ensurePermission() // 触发系统授权弹窗
            CaptureService.openScreenRecordingSettings()
        }
    }

    private func startSnip() {
        snipController.begin { [weak self] image, cocoaFrame in
            guard let self, let image else { return }
            SaveService.copyToPasteboard(image) // 松手即进剪贴板，贴屏悬浮窗照常出现
            let pin = PinWindowController(image: image, cocoaFrame: cocoaFrame)
            pin.onClose = { [weak self, weak pin] in
                guard let self, let pin else { return }
                self.pinControllers.removeAll { $0 === pin }
            }
            self.pinControllers.append(pin)
            pin.show()
        }
    }
}
