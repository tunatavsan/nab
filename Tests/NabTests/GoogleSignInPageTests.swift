import Foundation
import NabCore
import Testing

@Suite("Google sign-in page")
struct GoogleSignInPageTests {
    @Test func recognisesTheRefusalByAddressOrTitle() {
        #expect(
            GoogleSignInPage.isBlocked(url: URL(string: "https://accounts.google.com/signin/rejected?x=1"), title: nil))
        #expect(GoogleSignInPage.isBlocked(url: nil, title: "Couldn't sign you in"))
        #expect(
            GoogleSignInPage.isBlocked(url: nil, title: "Sign in - This browser or app may not be secure"))
    }

    @Test func ordinarySignInPagesPass() {
        #expect(
            !GoogleSignInPage.isBlocked(
                url: URL(string: "https://accounts.google.com/v3/signin/identifier"), title: "Sign in - Google Accounts"
            ))
        #expect(!GoogleSignInPage.isBlocked(url: nil, title: nil))
    }

    @Test func signOutTouchesOnlyGoogleAndYouTubeRecords() {
        #expect(GoogleSignInPage.isSignInRecord("google.com"))
        #expect(GoogleSignInPage.isSignInRecord("youtube.com"))
        #expect(!GoogleSignInPage.isSignInRecord("example.com"))
        #expect(!GoogleSignInPage.isSignInRecord("notgoogle.org"))
    }
}
