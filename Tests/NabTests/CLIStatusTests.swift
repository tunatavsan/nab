import Foundation
import Testing

@testable import NabAI

@Suite("CLI status")
struct CLIStatusTests {
    @Test func claudeAuthReadsExitAndMethodOnly() {
        let signedIn = #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.c"}"#
        #expect(CLIStatus.claudeAuth(exit: 0, output: signedIn) == (true, "Claude subscription"))
        #expect(
            CLIStatus.claudeAuth(exit: 0, output: #"{"loggedIn":true,"authMethod":"api_key"}"#) == (true, "API key"))
        #expect(CLIStatus.claudeAuth(exit: 1, output: signedIn).signedIn == false)
        #expect(CLIStatus.claudeAuth(exit: 0, output: #"{"loggedIn":false}"#).signedIn == false)
        #expect(CLIStatus.claudeAuth(exit: 0, output: "not json").signedIn)
    }

    @Test func codexIsSignedInOnExitZero() {
        #expect(CLIStatus.codexAuth(exit: 0) && !CLIStatus.codexAuth(exit: 1))
    }

    @Test func versionIsTheFirstDottedNumber() {
        #expect(CLIStatus.version(from: "2.1.301 (Claude Code)") == "2.1.301")
        #expect(CLIStatus.version(from: "codex-cli 0.5.0\n") == "0.5.0")
        #expect(CLIStatus.version(from: "no number") == nil)
    }

    @Test func installCommandsAreOfferedForCLIsOnly() {
        #expect(CLIStatus.installCommands(for: .claudeCLI) == ["curl -fsSL https://claude.ai/install.sh | bash"])
        #expect(CLIStatus.installCommands(for: .codexCLI).count == 2)
        #expect(CLIStatus.installCommands(for: .openAI).isEmpty)
    }

    @Test func aFakeCLIOnThePathReadsAsReadyOrSignedOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "codex")
        try "#!/bin/sh\n[ \"$1\" = --version ] && echo 'codex-cli 9.9.9'\n[ \"$1\" = login ] && exit \(1)\nexit 0\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let saved = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", folder.path + ":" + saved, 1)
        defer { setenv("PATH", saved, 1) }
        #expect(await CLIStatus.check(.codexCLI) == .signedOut)
    }
}
