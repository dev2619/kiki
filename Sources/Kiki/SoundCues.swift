import AppKit

/// Cues de audio para los momentos clave del flujo manos-libres (`.armed`,
/// `.captureStart`, `.disarmed`) y de ambos modos de dictado (`.inserted`,
/// hotkey Y manos-libres) — Fase 3.6, task-361. Solo sonidos de sistema
/// (`NSSound`), sin assets nuevos.
enum SoundCue {
    case armed
    case captureStart
    case inserted
    case disarmed

    fileprivate var soundName: NSSound.Name {
        switch self {
        case .armed: return "Glass"
        case .captureStart: return "Tink"
        case .inserted: return "Pop"
        case .disarmed: return "Bottle"
        }
    }
}

/// Gatea la reproducción con el toggle "Sonidos de confirmación" de Ajustes
/// (`kiki.soundCuesEnabled`, default **true**). Se lee con
/// `object(forKey:) == nil ? true : bool(forKey:)` en vez de registrar un
/// default en `UserDefaults.standard` para no acoplar el arranque de la app
/// a un side effect global de este archivo.
enum SoundCues {
    static let enabledDefaultsKey = "kiki.soundCuesEnabled"

    @MainActor
    static func play(_ cue: SoundCue) {
        guard isEnabled else { return }
        NSSound(named: cue.soundName)?.play()
    }

    private static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: enabledDefaultsKey)
    }
}
