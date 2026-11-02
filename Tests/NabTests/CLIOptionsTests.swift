import Testing

@testable import NabCore

@Suite("Reading nab's arguments")
struct CLIOptionsTests {
    @Test func optionsAndLinksInAnyOrder() {
        let parsed = CLIOptions.parse(["https://youtu.be/a", "--save", "~/Pins", "--json", "pin.it/b"])
        #expect(
            parsed == .success(CLIOptions(json: true, saveFolder: "~/Pins", links: ["https://youtu.be/a", "pin.it/b"])))
        #expect(CLIOptions.parse(["--help"]) == .success(CLIOptions(help: true)))
    }

    /// A folder that is really the next option, a missing folder, and an unknown option are usage errors.
    @Test func mistakesAreNotTakenAsFoldersOrIgnored() {
        #expect(CLIOptions.parse(["--save", "--json", "https://youtu.be/a"]) == .failure(.missingFolder))
        #expect(CLIOptions.parse(["https://youtu.be/a", "--save"]) == .failure(.missingFolder))
        #expect(CLIOptions.parse(["--jsno", "https://youtu.be/a"]) == .failure(.unknownOption("--jsno")))
    }
}
