import Foundation
import NabCore
import Testing

@Suite("Playback plan")
struct PlaybackPlanTests {
    @Test func onlyElevenCharacterIdsPass() {
        #expect(YouTubeID.isValid("dQw4w9WgXcQ"))
        #expect(YouTubeID.isValid("-_aZ09-_aZ0"))
        for bad in ["", "short", "dQw4w9WgXcQ1", "dQw4w9WgXc\"", "dQw4w9WgX;Q", "dQw4w9Wg Xc", "dQw4w9WgXcé"] {
            #expect(!YouTubeID.isValid(bad), "\(bad)")
        }
        #expect(YouTubeID.id(fromEntryID: "youtube:dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(YouTubeID.id(fromEntryID: "vimeo:dQw4w9WgXcQ") == nil)
        #expect(YouTubeID.id(fromEntryID: "youtube:x'); evil") == nil)
    }

    @Test func nabSettingTriesTheMiniPlayerFirst() {
        #expect(PlaybackPlan.targets(setting: .nab, embedFailed: false) == [.mini, .tabScript, .tabAddress, .newTab])
        #expect(PlaybackPlan.targets(setting: .nab, embedFailed: true) == [.tabScript, .tabAddress, .newTab])
    }

    @Test func browserSettingSkipsTheMiniPlayer() {
        #expect(PlaybackPlan.targets(setting: .browser, embedFailed: false) == [.tabScript, .tabAddress, .newTab])
    }

    @Test func whatTheBrowserAnswersNarrowsTheList() {
        #expect(
            PlaybackPlan.targets(setting: .browser, embedFailed: false, tabMatch: true, jsAllowed: false)
                == [.tabAddress, .newTab])
        #expect(PlaybackPlan.targets(setting: .browser, embedFailed: false, tabMatch: false) == [.newTab])
    }

    @Test func unknownSettingFallsBackToNab() {
        #expect(PlaybackPlan.Setting(stored: nil) == .nab)
        #expect(PlaybackPlan.Setting(stored: "browser") == .browser)
        #expect(PlaybackPlan.Setting(stored: "chrome") == .nab)
    }

    @Test func citationsRejectForgedVideoNumbers() {
        for tail in ["-9223372036854775808", "1000", "99999999999", "-1"] {
            #expect(Citation(url: URL(string: "nab-cite://t/\(tail)/0")!) == nil, "\(tail)")
        }
        #expect(Citation(url: URL(string: "nab-cite://t/999/0")!) == Citation(video: 999, seconds: 0))
    }
}
