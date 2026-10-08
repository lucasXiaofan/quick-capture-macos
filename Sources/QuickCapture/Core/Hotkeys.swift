import AppKit
import Carbon.HIToolbox

/// A global shortcut. Stored in config.json in pynput-style syntax (`<cmd>+<shift>+i`)
/// so older config files keep working.
struct Shortcut: Hashable {
    var keyCode: UInt32
    var command = false, shift = false, option = false, control = false

    private static let keys: [(name: String, code: Int, label: String)] = {
        var list: [(String, Int, String)] = [
            ("a", kVK_ANSI_A, "A"), ("b", kVK_ANSI_B, "B"), ("c", kVK_ANSI_C, "C"), ("d", kVK_ANSI_D, "D"),
            ("e", kVK_ANSI_E, "E"), ("f", kVK_ANSI_F, "F"), ("g", kVK_ANSI_G, "G"), ("h", kVK_ANSI_H, "H"),
            ("i", kVK_ANSI_I, "I"), ("j", kVK_ANSI_J, "J"), ("k", kVK_ANSI_K, "K"), ("l", kVK_ANSI_L, "L"),
            ("m", kVK_ANSI_M, "M"), ("n", kVK_ANSI_N, "N"), ("o", kVK_ANSI_O, "O"), ("p", kVK_ANSI_P, "P"),
            ("q", kVK_ANSI_Q, "Q"), ("r", kVK_ANSI_R, "R"), ("s", kVK_ANSI_S, "S"), ("t", kVK_ANSI_T, "T"),
            ("u", kVK_ANSI_U, "U"), ("v", kVK_ANSI_V, "V"), ("w", kVK_ANSI_W, "W"), ("x", kVK_ANSI_X, "X"),
            ("y", kVK_ANSI_Y, "Y"), ("z", kVK_ANSI_Z, "Z"),
            ("0", kVK_ANSI_0, "0"), ("1", kVK_ANSI_1, "1"), ("2", kVK_ANSI_2, "2"), ("3", kVK_ANSI_3, "3"),
            ("4", kVK_ANSI_4, "4"), ("5", kVK_ANSI_5, "5"), ("6", kVK_ANSI_6, "6"), ("7", kVK_ANSI_7, "7"),
            ("8", kVK_ANSI_8, "8"), ("9", kVK_ANSI_9, "9"),
            ("-", kVK_ANSI_Minus, "-"), ("=", kVK_ANSI_Equal, "="), ("[", kVK_ANSI_LeftBracket, "["),
            ("]", kVK_ANSI_RightBracket, "]"), (";", kVK_ANSI_Semicolon, ";"), ("'", kVK_ANSI_Quote, "'"),
            (",", kVK_ANSI_Comma, ","), (".", kVK_ANSI_Period, "."), ("/", kVK_ANSI_Slash, "/"),
            ("\\", kVK_ANSI_Backslash, "\\"), ("`", kVK_ANSI_Grave, "`"),
            ("<space>", kVK_Space, "Space"), ("<tab>", kVK_Tab, "⇥"), ("<enter>", kVK_Return, "↩"),
            ("<left>", kVK_LeftArrow, "←"), ("<right>", kVK_RightArrow, "→"),
            ("<up>", kVK_UpArrow, "↑"), ("<down>", kVK_DownArrow, "↓"),
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, code) in fkeys.enumerated() { list.append(("<f\(i + 1)>", code, "F\(i + 1)")) }
        return list
    }()

    var isFunctionKey: Bool { Shortcut.keys.first { $0.code == keyCode }?.name.hasPrefix("<f") ?? false }
    var hasRequiredModifier: Bool { command || option || control || isFunctionKey }

    init?(config: String, allowBare: Bool = false) {
        var key: UInt32?
        for raw in config.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let token = raw.trimmingCharacters(in: .whitespaces)
            switch token {
            case "<cmd>", "<cmd_l>", "<cmd_r>", "<command>": command = true
            case "<shift>", "<shift_l>", "<shift_r>": shift = true
            case "<alt>", "<alt_l>", "<alt_r>", "<option>", "<opt>": option = true
            case "<ctrl>", "<ctrl_l>", "<ctrl_r>", "<control>": control = true
            default:
                guard key == nil, let k = Shortcut.keys.first(where: { $0.name == token }) else { return nil }
                key = UInt32(k.code)
            }
        }
        guard let key else { return nil }
        keyCode = key
        guard allowBare || hasRequiredModifier else { return nil }
    }

    init?(event: NSEvent, allowBare: Bool = false) {
        guard Shortcut.keys.contains(where: { $0.code == Int(event.keyCode) }) else { return nil }
        let f = event.modifierFlags
        keyCode = UInt32(event.keyCode)
        command = f.contains(.command); shift = f.contains(.shift)
        option = f.contains(.option); control = f.contains(.control)
        guard allowBare || hasRequiredModifier else { return nil }
    }

    var configString: String {
        var parts: [String] = []
        if control { parts.append("<ctrl>") }
        if option { parts.append("<alt>") }
        if shift { parts.append("<shift>") }
        if command { parts.append("<cmd>") }
        parts.append(Shortcut.keys.first { $0.code == keyCode }?.name ?? "?")
        return parts.joined(separator: "+")
    }

    var keyLabel: String { Shortcut.keys.first { $0.code == keyCode }?.label ?? "?" }

    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + keyLabel
    }

    /// ⌘ or ⌘⇧ plus a printable key: the family most apps use for their own menu commands.
    var overlapsAppCommands: Bool { command && !option && !control && menuKeyEquivalent != nil }

    var carbonModifiers: UInt32 {
        UInt32((command ? cmdKey : 0) | (shift ? shiftKey : 0) | (option ? optionKey : 0) | (control ? controlKey : 0))
    }

    /// For showing the shortcut next to menu items (display only).
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        guard let name = Shortcut.keys.first(where: { $0.code == keyCode })?.name, name.count == 1 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return (name, flags)
    }
}

/// System-wide hotkeys via Carbon's RegisterEventHotKey. Unlike an event tap, this needs
/// no Accessibility or Input Monitoring permission, and the shortcut is not passed on to
/// the frontmost app (so ⌘⇧I won't also open Obsidian's developer tools).
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotkeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Registers shortcuts, replacing previous ones. Returns messages for shortcuts that
    /// another app already owns.
    @discardableResult
    func register(_ bindings: [(Shortcut, String, () -> Void)]) -> [String] {
        install()
        unregisterAll()
        var failures: [String] = []
        for (index, (shortcut, label, handler)) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                             EventHotKeyID(signature: OSType(0x5143_4150), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                handlers[id] = handler
            } else {
                failures.append("\(shortcut.display) (\(label)) is already used by another app.")
            }
        }
        return failures
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}
