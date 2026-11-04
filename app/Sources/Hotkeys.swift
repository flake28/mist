import Carbon.HIToolbox

/// Global hotkeys via Carbon (no extra permission needed, and the keypress is consumed).
enum Hotkeys {
    static var handlers: [UInt32: () -> Void] = [:]

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            Hotkeys.handlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func register(key: Int, modifiers: Int, id: UInt32, _ handler: @escaping () -> Void) {
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4D495354), id: id), // 'MIST'
                            GetApplicationEventTarget(), 0, &ref)
    }
}
