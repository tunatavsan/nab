import NabCore
import Testing

@Suite("Browser seek script")
struct BrowserSeekTests {
    private let id = "dQw4w9WgXcQ"

    @Test func invalidInputsProduceNoScript() {
        #expect(
            BrowserSeekScript.source(
                bundleID: "com.google.Chrome", family: .chromium, videoID: "x\" & (do shell script \"id\")",
                action: .raise) == nil)
        #expect(
            BrowserSeekScript.source(
                bundleID: "a\" b", family: .chromium, videoID: id, action: .raise) == nil)
    }

    @Test func scriptMatchesTheTabByIdAndSetsOnlyANumber() throws {
        let source = try #require(
            BrowserSeekScript.source(
                bundleID: "com.google.Chrome", family: .chromium, videoID: id, action: .script(seconds: 372)))
        #expect(source.contains("youtu.be/\(id)"))
        #expect(source.contains("v=\(id)"))
        #expect(
            source.contains(
                "execute t javascript \"var v=document.querySelector('video');if(v){v.currentTime=372;v.play();}\""))
        #expect(source.contains("script-denied"))
    }

    @Test func safariUsesItsOwnVocabulary() throws {
        let source = try #require(
            BrowserSeekScript.source(
                bundleID: "com.apple.Safari", family: .safari, videoID: id, action: .script(seconds: 5)))
        #expect(source.contains("do JavaScript"))
        #expect(source.contains("set current tab of w to t"))
    }

    @Test func addressActionKeepsTheTabAndClampsSeconds() throws {
        let source = try #require(
            BrowserSeekScript.source(
                bundleID: "net.imput.helium", family: .chromium, videoID: id, action: .address(seconds: -40)))
        #expect(source.contains("set URL of t to \"https://www.youtube.com/watch?v=\(id)&t=0s\""))
        #expect(!source.contains("make new tab"))
    }
}
