import Foundation

/// The two families of on-device models kiki manages: speech-to-text (WhisperKit)
/// and text refinement (MLX LLM).
public enum ModelKind: String {
    case stt
    case refine
}

/// A single selectable model variant, curated for display in Settings.
public struct ModelOption: Equatable, Identifiable {
    /// Engine identifier: a WhisperKit variant folder suffix (e.g. "large-v3_turbo_954MB")
    /// for `.stt`, or an MLX-community repo id (e.g. "mlx-community/Qwen2.5-3B-Instruct-4bit")
    /// for `.refine`.
    public let id: String
    /// Short label for pickers, e.g. "Rápido (small)", "Balanceado ★".
    public let displayName: String
    /// Approximate on-disk download size, e.g. "~216 MB".
    public let sizeLabel: String
    /// One-line positioning/trade-off description shown under the option.
    public let detail: String
    /// Whether this is the recommended default for its kind.
    public let isBase: Bool

    public init(id: String, displayName: String, sizeLabel: String, detail: String, isBase: Bool) {
        self.id = id
        self.displayName = displayName
        self.sizeLabel = sizeLabel
        self.detail = detail
        self.isBase = isBase
    }
}

/// Curated catalog of supported STT and refine model variants.
///
/// Consistency note: the base STT id below (`large-v3_turbo_954MB`) MUST stay in
/// lockstep with `WhisperTranscriber.preferredModel`, and the base refine id
/// (`mlx-community/Qwen2.5-3B-Instruct-4bit`) MUST stay in lockstep with
/// `LLMRefiner.preferredModel`. KikiStore cannot depend on KikiSTT/KikiRefine
/// (dependency direction: those targets depend on KikiCore, not KikiStore), so the
/// string cannot be shared directly. Task 2 adds runtime asserts in AppDelegate
/// (`assert(ModelCatalog.baseOption(for: .stt).id == WhisperTranscriber.preferredModel)`,
/// and the equivalent for `.refine`) to catch drift between the two constants.
///
/// STT id verification: ids map to WhisperKit's `argmaxinc/whisperkit-coreml` repo
/// folder names with the `openai_whisper-` prefix stripped (e.g. id
/// `large-v3_turbo_954MB` <-> folder `openai_whisper-large-v3_turbo_954MB`). Verified
/// 2026-07-11 via `https://huggingface.co/api/models/argmaxinc/whisperkit-coreml`:
/// the repo contains a distinct multilingual `openai_whisper-small` folder (no size
/// suffix) alongside `openai_whisper-small.en` and `openai_whisper-small.en_217MB`
/// (English-only variants, correctly excluded here) and `openai_whisper-small_216MB`
/// (an alternate, size-suffixed multilingual folder name). This catalog intentionally
/// uses the bare `small` id to match the existing `large-v3_turbo`/`large-v3_turbo_954MB`
/// naming convention already used by `large-v3_turbo_954MB` (base) and `large-v3_turbo`.
public enum ModelCatalog {
    public static let sttOptions: [ModelOption] = [
        ModelOption(
            id: "small",
            displayName: "Rápido (small)",
            sizeLabel: "~216 MB",
            detail: "Descarga rápida y bajo uso de memoria; menor precisión en audio ruidoso.",
            isBase: false
        ),
        ModelOption(
            id: "large-v3_turbo_954MB",
            displayName: "Balanceado ★",
            sizeLabel: "~954 MB",
            detail: "Recomendado: buen balance entre precisión y velocidad de transcripción.",
            isBase: true
        ),
        ModelOption(
            id: "large-v3_turbo",
            displayName: "Máxima precisión",
            sizeLabel: "~1.5 GB",
            detail: "Mayor precisión; la primera ejecución compila para ANE y puede tardar varios minutos.",
            isBase: false
        ),
    ]

    public static let refineOptions: [ModelOption] = [
        ModelOption(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Rápido",
            sizeLabel: "~1 GB",
            detail: "Refinamiento veloz con menor consumo de memoria; para Macs con menos RAM.",
            isBase: false
        ),
        ModelOption(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            displayName: "Balanceado ★",
            sizeLabel: "~1.9 GB",
            detail: "Recomendado: buen balance entre calidad de redacción y velocidad.",
            isBase: true
        ),
        ModelOption(
            id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            displayName: "Máxima calidad",
            sizeLabel: "~4.3 GB",
            detail: "Mejor calidad de refinamiento; recomendado en Macs con 32 GB de RAM o más.",
            isBase: false
        ),
    ]

    public static func options(for kind: ModelKind) -> [ModelOption] {
        switch kind {
        case .stt: return sttOptions
        case .refine: return refineOptions
        }
    }

    public static func baseOption(for kind: ModelKind) -> ModelOption {
        // Precondition: each catalog is curated with exactly one `isBase` entry,
        // enforced by ModelCatalogTests.testCatalogsHaveThreeOptionsAndExactlyOneBase.
        options(for: kind).first { $0.isBase }!
    }
}

/// Reads/writes the user's model preference, resolving it against the current
/// catalog so a retired or unknown id never gets returned as "effective".
public enum ModelPreference {
    public static func defaultsKey(for kind: ModelKind) -> String {
        switch kind {
        case .stt: return "kiki.sttModel"
        case .refine: return "kiki.refineModel"
        }
    }

    /// The id that should actually be used: the persisted preference if present
    /// and still listed in the catalog, otherwise the base option's id.
    public static func effectiveModelId(for kind: ModelKind, defaults: UserDefaults = .standard) -> String {
        let key = defaultsKey(for: kind)
        if let stored = defaults.string(forKey: key),
           options(for: kind).contains(where: { $0.id == stored }) {
            return stored
        }
        return ModelCatalog.baseOption(for: kind).id
    }

    public static func setPreferred(_ id: String, for kind: ModelKind, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: defaultsKey(for: kind))
    }

    private static func options(for kind: ModelKind) -> [ModelOption] {
        ModelCatalog.options(for: kind)
    }
}
