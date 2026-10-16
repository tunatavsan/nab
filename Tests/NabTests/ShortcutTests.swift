import Foundation
import Testing

@testable import NabCore

@Suite struct ShortcutTests {
    private let ctrlOpt = KeyCombo.control | KeyCombo.option

    @Test func defaultsApplyUntilSomethingIsStored() {
        let map = ShortcutMap()
        #expect(map.combo(for: .nab) == KeyCombo(keyCode: 45, modifiers: ctrlOpt))
        #expect(map.combo(for: .newSession) == KeyCombo(keyCode: 7, modifiers: ctrlOpt))
        #expect(map.isDefault)
    }

    @Test func explicitNilMeansNoShortcutAndResetBringsTheDefaultBack() {
        var map = ShortcutMap()
        map.set(nil, for: .summarize)
        #expect(map.combo(for: .summarize) == nil)
        #expect(!map.isDefault)
        map.reset(.summarize)
        #expect(map.combo(for: .summarize) == ShortcutMap.defaults[.summarize])
    }

    @Test func codingKeepsOverridesClearedActionsAndDefaults() {
        var map = ShortcutMap()
        let custom = KeyCombo(keyCode: 11, modifiers: KeyCombo.command | KeyCombo.shift | KeyCombo.option)
        map.set(custom, for: .copySession)
        map.set(nil, for: .newSession)
        let back = ShortcutMap.decode(map.encoded())
        #expect(back == map)
        #expect(back.combo(for: .copySession) == custom)
        #expect(back.combo(for: .newSession) == nil)
        #expect(back.combo(for: .nab) == ShortcutMap.defaults[.nab])
        #expect(ShortcutMap.decode(nil) == ShortcutMap())
        #expect(ShortcutMap.decode(Data("not json".utf8)) == ShortcutMap())
    }

    @Test func validationNeedsAControlOptionOrCommand() {
        let map = ShortcutMap()
        #expect(map.validate(KeyCombo(keyCode: 11, modifiers: 0), for: .nab) == .needsModifier)
        #expect(map.validate(KeyCombo(keyCode: 11, modifiers: KeyCombo.shift), for: .nab) == .needsModifier)
        #expect(map.validate(KeyCombo(keyCode: 11, modifiers: KeyCombo.option), for: .nab) == .valid)
        #expect(map.validate(KeyCombo(keyCode: 122, modifiers: KeyCombo.command), for: .nab) == .valid)
    }

    @Test func commandAloneCannotTakeLettersOrDigits() {
        let map = ShortcutMap()
        let shifted = KeyCombo.command | KeyCombo.shift
        #expect(map.validate(KeyCombo(keyCode: 11, modifiers: KeyCombo.command), for: .nab) == .takenByApps)
        #expect(map.validate(KeyCombo(keyCode: 18, modifiers: shifted), for: .nab) == .takenByApps)
        #expect(
            map.validate(KeyCombo(keyCode: 11, modifiers: KeyCombo.command | KeyCombo.control), for: .nab) == .valid)
    }

    @Test func aCombinationAnotherActionHoldsIsRefusedButYourOwnIsNot() throws {
        var map = ShortcutMap()
        let ofCopy = try #require(ShortcutMap.defaults[.copySession])
        #expect(map.validate(ofCopy, for: .summarize) == .conflict(.copySession))
        #expect(map.validate(ofCopy, for: .copySession) == .valid)
        map.set(nil, for: .copySession)
        #expect(map.validate(ofCopy, for: .summarize) == .valid)
    }

    @Test func eventFlagsBecomeACarbonMaskAndDropTheRest() {
        let flags: UInt = (1 << 18) | (1 << 19) | (1 << 16) | (1 << 23)  // control, option, caps lock, fn
        #expect(KeyCombo.carbonModifiers(eventFlags: flags) == ctrlOpt)
        #expect(KeyCombo.carbonModifiers(eventFlags: (1 << 17) | (1 << 20)) == KeyCombo.shift | KeyCombo.command)
        #expect(KeyCombo.carbonModifiers(eventFlags: 0) == 0)
    }

    @Test func modifiersComeInTheSystemOrder() {
        let mask = KeyCombo.command | KeyCombo.shift | KeyCombo.option | KeyCombo.control
        let all = KeyCombo(keyCode: 45, modifiers: mask)
        #expect(all.modifierSymbols == ["⌃", "⌥", "⇧", "⌘"])
        #expect(all.text(character: "N") == "⌃⌥⇧⌘N")
    }

    @Test func specialKeysUseTheSymbolTableAndLetterKeysTheLayoutCharacter() {
        #expect(KeyCombo(keyCode: 126, modifiers: ctrlOpt).parts(character: "?") == ["⌃", "⌥", "↑"])
        #expect(KeyCombo(keyCode: 49, modifiers: KeyCombo.option).text(character: " ") == "⌥Space")
        #expect(KeyCombo(keyCode: 111, modifiers: KeyCombo.command).text(character: "") == "⌘F12")
        #expect(KeyCombo(keyCode: 36, modifiers: KeyCombo.command).text(character: "") == "⌘↩")
        #expect(KeyCombo(keyCode: 51, modifiers: KeyCombo.command).text(character: "") == "⌘⌫")
        #expect(KeyCombo(keyCode: 53, modifiers: KeyCombo.command).text(character: "") == "⌘⎋")
        #expect(KeyCombo(keyCode: 45, modifiers: ctrlOpt).text(character: "N") == "⌃⌥N")
    }
}
