import Carbon
import AppKit

/// 全局快捷键（Carbon RegisterEventHotKey，系统级可靠，无需辅助功能权限）。
/// ⌃⌥X：框选抠图（先快照再框选，可截下拉菜单等瞬态界面）。
/// 换键改下面 register() 里的 keyCode / modifiers 即可。
final class HotkeyManager {

    var onHotkey: (() -> Void)?

    private static let snipID: UInt32 = 1

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotkey?() }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )

        registerHotKey(keyCode: UInt32(kVK_ANSI_X),
                       modifiers: UInt32(controlKey | optionKey),
                       id: Self.snipID)
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: 0x53504E31, id: id) // 'SPN1'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { hotKeyRefs.append(ref) }
    }

    deinit {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
