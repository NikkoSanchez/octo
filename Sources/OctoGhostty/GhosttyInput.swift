import AppKit
import Carbon
import GhosttyKit

// Native event mapping follows the pinned official macOS host's C contract.
// See Vendor/Ghostty.lock.json and Vendor/Ghostty-NOTICES.md for provenance.
enum GhosttyInput {
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var bits: UInt32 = 0
        let pairs: [(NSEvent.ModifierFlags, ghostty_input_mods_e)] = [
            (.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT),
            (.command, GHOSTTY_MODS_SUPER), (.capsLock, GHOSTTY_MODS_CAPS)]
        for (flag, value) in pairs where flags.contains(flag) { bits |= value.rawValue }
        for (flag, value) in [(NX_DEVICERSHIFTKEYMASK, GHOSTTY_MODS_SHIFT_RIGHT),
                              (NX_DEVICERCTLKEYMASK, GHOSTTY_MODS_CTRL_RIGHT),
                              (NX_DEVICERALTKEYMASK, GHOSTTY_MODS_ALT_RIGHT),
                              (NX_DEVICERCMDKEYMASK, GHOSTTY_MODS_SUPER_RIGHT)] where flags.rawValue & UInt(flag) != 0 {
            bits |= value.rawValue
        }
        return ghostty_input_mods_e(bits)
    }
    static func translationFlags(_ original: NSEvent.ModifierFlags, ghostty: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var result = original
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
                            (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if ghostty.rawValue & bit.rawValue != 0 { result.insert(flag) } else { result.remove(flag) }
        }
        return result
    }
    static func key(_ event: NSEvent, action: ghostty_input_action_e, translated: NSEvent? = nil) -> ghostty_input_key_s {
        var result = ghostty_input_key_s()
        result.action = action
        result.keycode = UInt32(event.keyCode)
        result.mods = modifiers(event.modifierFlags)
        result.consumed_mods = modifiers((translated ?? event).modifierFlags.subtracting([.control, .command]))
        if event.type == .keyDown || event.type == .keyUp {
            result.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        }
        return result
    }
    static func keyText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        // Ghostty encodes controls/function keys from the physical key and modifiers.
        if value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first,
           scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) || scalar.value == 0x7F { return nil }
        return value.utf8.contains(0) ? nil : value
    }
    static func scrollModifiers(precise: Bool, momentum: NSEvent.Phase) -> Int32 {
        let phase: ghostty_input_mouse_momentum_e
        switch momentum {
        case .began: phase = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: phase = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: phase = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: phase = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: phase = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: phase = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: phase = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        return (precise ? 1 : 0) | Int32(phase.rawValue << 1)
    }
    static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return unsafeBitCast(pointer, to: CFString.self) as String
    }
    static func shellQuotedPath(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
