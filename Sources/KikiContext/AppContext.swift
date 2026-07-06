import AppKit
import KikiCore

/// Maps bundle identifiers to application profiles using prefix matching.
///
/// This struct provides a deterministic mapping from bundle IDs to `AppProfile` values.
/// The matching is done using `hasPrefix` to handle versioned suffixes (e.g., Electron apps).
///
/// - Important: The standard map is iterated in a deterministic order (sorted keys)
///   to ensure stable matching when multiple prefixes could apply.
public struct BundleProfileMap {
    /// Standard bundle ID to AppProfile mapping.
    ///
    /// Covers common development, communication, and productivity apps:
    /// - `.code`: VSCode, Xcode, terminals, JetBrains IDEs
    /// - `.chat`: Slack, Discord, Telegram, WhatsApp, SMS
    /// - `.email`: Mail, Outlook, Spark
    /// - `.docs`: Notes, TextEdit, Obsidian, Word, Notion
    /// - `.neutral`: Everything else
    public static let standard: [String: AppProfile] = [
        // Code editors & IDEs
        "com.microsoft.VSCode": .code,
        "com.apple.dt.Xcode": .code,
        "com.googlecode.iterm2": .code,
        "com.apple.Terminal": .code,
        "dev.warp.Warp": .code,
        "com.sublimetext.": .code, // prefix for "com.sublimetext.3", ".4", etc.
        "com.jetbrains.": .code,   // prefix: covers intellij, goland, phpstorm, etc.

        // Chat
        "com.tinyspeck.slackmacgap": .chat,
        "com.hnc.Discord": .chat,
        "ru.keepcoder.Telegram": .chat,
        "net.whatsapp.WhatsApp": .chat,
        "com.apple.MobileSMS": .chat,

        // Email (restricted: only Mail, Outlook, Spark)
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email,

        // Docs (text editors and note-taking)
        "com.apple.Notes": .docs,
        "com.apple.TextEdit": .docs,
        "md.obsidian": .docs,
        "com.microsoft.Word": .docs,
        "notion.id": .docs,
    ]

    /// Returns the application profile for a given bundle identifier.
    ///
    /// Matching is done via `hasPrefix` to support versioned bundle IDs.
    /// - Parameters:
    ///   - bundleId: The bundle identifier to look up (e.g., "com.microsoft.VSCode").
    ///   - map: The mapping dictionary. Defaults to `standard`.
    /// - Returns: The matching `AppProfile`, or `.neutral` if no match is found or if `bundleId` is nil/empty.
    public static func profile(forBundleId bundleId: String?, map: [String: AppProfile] = standard) -> AppProfile {
        guard let bundleId = bundleId, !bundleId.isEmpty else {
            return .neutral
        }

        // Iterate through sorted keys to ensure deterministic matching.
        // Longer prefixes are checked first to avoid shorter prefixes matching prematurely.
        let sortedKeys = map.keys.sorted { $0.count > $1.count }

        for key in sortedKeys {
            if bundleId.hasPrefix(key) {
                return map[key] ?? .neutral
            }
        }

        return .neutral
    }
}

/// Provides the current application profile based on the frontmost (active) app.
///
/// This class queries the macOS system to determine which app is currently in focus
/// and returns its corresponding `AppProfile`.
public final class FrontmostAppContext: ContextProviding {
    /// Initializes a new frontmost app context.
    public init() {}

    /// Returns the profile of the currently active (frontmost) application.
    ///
    /// Uses `NSWorkspace.shared.frontmostApplication` to determine the active app,
    /// then looks up its bundle identifier in the standard profile map.
    /// - Returns: The `AppProfile` of the frontmost app, or `.neutral` if no app is active.
    public func currentProfile() -> AppProfile {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return BundleProfileMap.profile(forBundleId: bundleId)
    }
}
