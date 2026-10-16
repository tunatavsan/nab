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

    @Test func anOpenTabAlwaysComesFirst() {
        for setting in [PlaybackPlan.Setting.nab, .browser] {
            for pin in [true, false] {
                let plan = PlaybackPlan.targets(setting: setting, pinOpen: pin, embedFailed: false)
                #expect(Array(plan.prefix(2)) == [.tabScript, .tabAddress], "\(setting) pin \(pin)")
            }
        }
    }

    @Test func withoutATabThePinThenTheMainWindowFollow() {
        #expect(
            PlaybackPlan.targets(setting: .nab, pinOpen: true, embedFailed: false, tabMatch: false) == [.pin])
        #expect(
            PlaybackPlan.targets(setting: .nab, pinOpen: false, embedFailed: false, tabMatch: false) == [.mainWindow])
        #expect(
            PlaybackPlan.targets(setting: .nab, pinOpen: false, embedFailed: false)
                == [.tabScript, .tabAddress, .mainWindow])
    }

    @Test func browserSettingReplacesTheMainWindowButNotThePin() {
        #expect(
            PlaybackPlan.targets(setting: .browser, pinOpen: false, embedFailed: false, tabMatch: false) == [.newTab])
        #expect(PlaybackPlan.targets(setting: .browser, pinOpen: true, embedFailed: false, tabMatch: false) == [.pin])
    }

    @Test func aVideoThatWillNotEmbedGoesToTheBrowser() {
        #expect(PlaybackPlan.targets(setting: .nab, pinOpen: true, embedFailed: true, tabMatch: false) == [.newTab])
    }

    @Test func whatTheBrowserAnswersNarrowsTheList() {
        #expect(
            PlaybackPlan.targets(setting: .nab, pinOpen: false, embedFailed: false, tabMatch: true, jsAllowed: false)
                == [.tabAddress, .mainWindow])
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
