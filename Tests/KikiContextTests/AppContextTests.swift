import XCTest
@testable import KikiContext
@testable import KikiCore

final class BundleProfileMapTests: XCTestCase {
    // MARK: - Exact Mappings

    func testVSCodeMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.microsoft.VSCode")
        XCTAssertEqual(profile, .code)
    }

    func testXcodeMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.apple.dt.Xcode")
        XCTAssertEqual(profile, .code)
    }

    func testIterm2MapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.googlecode.iterm2")
        XCTAssertEqual(profile, .code)
    }

    func testTerminalMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.apple.Terminal")
        XCTAssertEqual(profile, .code)
    }

    func testWarpMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "dev.warp.Warp")
        XCTAssertEqual(profile, .code)
    }

    func testSublimeTextMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.sublimetext.4")
        XCTAssertEqual(profile, .code)
    }

    // MARK: - JetBrains Prefix Matching

    func testJetBrainsIntelliJMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.jetbrains.intellij")
        XCTAssertEqual(profile, .code)
    }

    func testJetBrainsIntelliJUltimateMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.jetbrains.intellij.ce")
        XCTAssertEqual(profile, .code)
    }

    func testJetBrainsGolandMapsToCode() {
        let profile = BundleProfileMap.profile(forBundleId: "com.jetbrains.goland")
        XCTAssertEqual(profile, .code)
    }

    // MARK: - Chat

    func testSlackMapsToChatViaDeprecatedId() {
        // Legacy Slack ID
        let profile = BundleProfileMap.profile(forBundleId: "com.tinyspeck.slackmacgap")
        XCTAssertEqual(profile, .chat)
    }

    func testDiscordMapsToChat() {
        let profile = BundleProfileMap.profile(forBundleId: "com.hnc.Discord")
        XCTAssertEqual(profile, .chat)
    }

    func testTelegramMapsToChat() {
        let profile = BundleProfileMap.profile(forBundleId: "ru.keepcoder.Telegram")
        XCTAssertEqual(profile, .chat)
    }

    func testWhatsAppMapsToChat() {
        let profile = BundleProfileMap.profile(forBundleId: "net.whatsapp.WhatsApp")
        XCTAssertEqual(profile, .chat)
    }

    func testSMSMapsToChat() {
        let profile = BundleProfileMap.profile(forBundleId: "com.apple.MobileSMS")
        XCTAssertEqual(profile, .chat)
    }

    // MARK: - Email

    func testMailMapsToEmail() {
        let profile = BundleProfileMap.profile(forBundleId: "com.apple.mail")
        XCTAssertEqual(profile, .email)
    }

    func testOutlookMapsToEmail() {
        let profile = BundleProfileMap.profile(forBundleId: "com.microsoft.Outlook")
        XCTAssertEqual(profile, .email)
    }

    func testSparkMapsToEmail() {
        let profile = BundleProfileMap.profile(forBundleId: "com.readdle.smartemail-Mac")
        XCTAssertEqual(profile, .email)
    }

    // MARK: - Docs

    func testNotesMapsToDoc() {
        let profile = BundleProfileMap.profile(forBundleId: "com.apple.Notes")
        XCTAssertEqual(profile, .docs)
    }

    func testTextEditMapsToDocs() {
        let profile = BundleProfileMap.profile(forBundleId: "com.apple.TextEdit")
        XCTAssertEqual(profile, .docs)
    }

    func testObsidianMapsToDocs() {
        let profile = BundleProfileMap.profile(forBundleId: "md.obsidian")
        XCTAssertEqual(profile, .docs)
    }

    func testWordMapsToDocs() {
        let profile = BundleProfileMap.profile(forBundleId: "com.microsoft.Word")
        XCTAssertEqual(profile, .docs)
    }

    func testNotionMapsToDocs() {
        let profile = BundleProfileMap.profile(forBundleId: "notion.id")
        XCTAssertEqual(profile, .docs)
    }

    // MARK: - Browser apps (NOT docs)

    func testChromeMapsToNeutral() {
        // Browsers are NOT docs
        let profile = BundleProfileMap.profile(forBundleId: "com.google.Chrome")
        XCTAssertEqual(profile, .neutral)
    }

    // MARK: - Unknown and nil cases

    func testUnknownBundleIdMapsToNeutral() {
        let profile = BundleProfileMap.profile(forBundleId: "com.unknown.app")
        XCTAssertEqual(profile, .neutral)
    }

    func testNilBundleIdMapsToNeutral() {
        let profile = BundleProfileMap.profile(forBundleId: nil)
        XCTAssertEqual(profile, .neutral)
    }

    func testEmptyStringMapsToNeutral() {
        let profile = BundleProfileMap.profile(forBundleId: "")
        XCTAssertEqual(profile, .neutral)
    }

    // MARK: - Custom map usage

    func testCustomMapOverridesStandard() {
        let customMap: [String: AppProfile] = [
            "com.custom.app": .chat
        ]
        let profile = BundleProfileMap.profile(forBundleId: "com.custom.app", map: customMap)
        XCTAssertEqual(profile, .chat)
    }

    func testCustomMapFallsBackToNeutral() {
        let customMap: [String: AppProfile] = [
            "com.custom.app": .chat
        ]
        let profile = BundleProfileMap.profile(forBundleId: "com.unknown.app", map: customMap)
        XCTAssertEqual(profile, .neutral)
    }

    // MARK: - Standard map is deterministic

    func testStandardMapIsConsistent() {
        // Run multiple times to ensure consistency
        for _ in 0..<5 {
            XCTAssertEqual(
                BundleProfileMap.profile(forBundleId: "com.microsoft.VSCode"),
                .code
            )
        }
    }
}

final class FrontmostAppContextTests: XCTestCase {
    // Note: FrontmostAppContext is not unit-tested as it uses NSWorkspace
    // which requires the real system. This is integration testing territory.
    // The pure function BundleProfileMap.profile is tested above.

    func testFrontmostAppContextCanBeInitialized() {
        let context = FrontmostAppContext()
        XCTAssertNotNil(context)
    }

    func testFrontmostAppContextConformsToContextProviding() {
        let context: ContextProviding = FrontmostAppContext()
        XCTAssertNotNil(context)
    }
}
