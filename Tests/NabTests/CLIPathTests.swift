import Foundation
import Testing

@testable import NabAI

@Suite("CLI PATH")
struct CLIPathTests {
    @Test func launchdPathGetsTheInstallFoldersAtTheEnd() {
        let path = CLIPath.augmented("/usr/bin:/bin:/usr/sbin:/sbin", home: "/Users/x")
        #expect(path == "/usr/bin:/bin:/usr/sbin:/sbin:/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func theUsersOrderIsKeptAndNothingIsAddedTwice() {
        let path = CLIPath.augmented("/usr/local/bin:/a:/Users/x/.local/bin::/b", home: "/Users/x")
        #expect(path == "/usr/local/bin:/a:/Users/x/.local/bin:/b:/opt/homebrew/bin")
        #expect(CLIPath.augmented(path, home: "/Users/x") == path)
    }

    @Test func aMissingPathStillGetsTheFolders() {
        #expect(CLIPath.augmented(nil, home: "/h") == "/h/.local/bin:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func theCommandRunsWithThatPath() {
        let env = AIClient.commandEnvironment(
            settings: AISettings(), system: "s", base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(env["PATH"]?.hasPrefix("/usr/bin:/bin:/usr/sbin:/sbin:") == true)
        #expect(env["PATH"]?.hasSuffix(":/usr/local/bin") == true)
    }
}
