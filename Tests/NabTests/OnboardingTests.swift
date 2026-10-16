import Testing

@testable import NabCore

@Suite("Onboarding")
struct OnboardingTests {
    @Test("an empty library that has not seen the welcome opens it")
    func opensForNewcomers() {
        #expect(Onboarding.opensAutomatically(libraryIsEmpty: true, seenVersion: 0))
    }

    @Test("a library with videos never opens it by itself")
    func existingUsers() {
        #expect(!Onboarding.opensAutomatically(libraryIsEmpty: false, seenVersion: 0))
    }

    @Test("a seen welcome stays closed, a newer version opens again")
    func versions() {
        #expect(!Onboarding.opensAutomatically(libraryIsEmpty: true, seenVersion: Onboarding.currentVersion))
        #expect(Onboarding.opensAutomatically(libraryIsEmpty: true, seenVersion: Onboarding.currentVersion - 1))
    }

    @Test("the icon style reads stored text and falls back to color")
    func iconStyle() {
        #expect(MenuBarIconStyle(stored: "mono") == .mono)
        #expect(MenuBarIconStyle(stored: "color") == .color)
        #expect(MenuBarIconStyle(stored: nil) == .color)
        #expect(MenuBarIconStyle(stored: "white") == .color)
    }
}
