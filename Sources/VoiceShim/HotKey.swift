import Carbon.HIToolbox
import Foundation

/// Global hold-to-talk hotkey via Carbon RegisterEventHotKey.
/// This path needs no Accessibility or Input Monitoring permission, and the
/// key combination is swallowed so it never reaches the focused app.
final class HotKey {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    static func carbonModifiers(_ names: [String]) -> UInt32 {
        var mods: UInt32 = 0
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": mods |= UInt32(cmdKey)
            case "option", "opt", "alt": mods |= UInt32(optionKey)
            case "control", "ctrl": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: break
            }
        }
        return mods
    }

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installErr = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        hotKey.onDown?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        hotKey.onUp?()
                    }
                }
                return noErr
            },
            eventTypes.count, &eventTypes, selfPtr, &handlerRef
        )
        guard installErr == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4443), id: 1) // "STDC"
        let registerErr = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef
        )
        return registerErr == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
