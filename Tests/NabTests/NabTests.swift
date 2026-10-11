import Foundation
import Testing

@testable import NabAI
@testable import NabCore
@testable import NabYouTube

@Test func videoIDsFromEveryLinkShape() {
    let cases = [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s": "dQw4w9WgXcQ",
        "https://youtu.be/dQw4w9WgXcQ?si=abc": "dQw4w9WgXcQ",
        "https://m.youtube.com/shorts/dQw4w9WgXcQ": "dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ": "dQw4w9WgXcQ",
        "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ": "dQw4w9WgXcQ",
    ]
    for (link, id) in cases { #expect(YouTubeURL.videoID(in: URL(string: link)!) == id, "\(link)") }
    #expect(YouTubeURL.videoID(in: URL(string: "https://www.youtube.com/@channel")!) == nil)
    #expect(YouTubeURL.videoID(in: URL(string: "https://example.com/watch?v=dQw4w9WgXcQ")!) == nil)
}

@Test func chaptersNeedAStartAtZero() {
    let description = """
        Links below.
        0:00 Intro
        1:30 - The setup
        (12:05) Results
        1:02:03 Q&A
        """
    let chapters = YouTubeChapters.parse(description)
    #expect(chapters.map(\.start) == [0, 90, 725, 3723])
    #expect(chapters.map(\.title) == ["Intro", "The setup", "Results", "Q&A"])
    #expect(YouTubeChapters.parse("2:00 Late start\n3:00 More").isEmpty)
}

@Test func timedTextDropsEmptyEvents() throws {
    let json =
        #"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"Hello"},{"utf8":" world"}]},{"tStartMs":900,"segs":[{"utf8":"\n"}]},{"tStartMs":2000,"dDurationMs":500}]}"#
    let segments = try TimedText.segments(from: Data(json.utf8))
    #expect(segments == [Segment(start: 0, duration: 1, text: "Hello world")])
}

@Test func paragraphsBreakAtChaptersAndSentences() {
    let segments = (0..<20).map { Segment(start: Double($0) * 10, duration: 10, text: $0 % 6 == 5 ? "end." : "word") }
    let transcript = Transcript(languageCode: "en", languageName: "English", isGenerated: false, segments: segments)
    let paragraphs = transcript.paragraphs(chapters: [Chapter(start: 0, title: "A"), Chapter(start: 100, title: "B")])
    #expect(paragraphs.map(\.start) == [0, 60, 100, 180])
    #expect(paragraphs.first?.chapter == "A")
    #expect(paragraphs[2].chapter == "B")
}

@Test func registryFindsLinksInFreeText() {
    let registry = SourceRegistry([YouTubeSource()])
    let text =
        "watch https://youtu.be/dQw4w9WgXcQ and https://www.youtube.com/watch?v=dQw4w9WgXcQ, also https://example.com"
    #expect(registry.links(in: text).count == 1)
}

@Test func citationsBecomeLinks() {
    let linked = Citation.link(
        "Starts at [1:05], again at [2 12:40] and [1:02:03–1:03:00]; keep [link](https://x.y) and [note].")
    #expect(linked.contains("[1:05](nab-cite://t/0/65)"))
    #expect(linked.contains("[2 · 12:40](nab-cite://t/2/760)"))
    #expect(linked.contains("[1:02:03–1:03:00](nab-cite://t/0/3723)"))
    #expect(linked.contains("[link](https://x.y)"))
    #expect(linked.contains("[note]"))
    #expect(Citation(url: URL(string: "nab-cite://t/2/760")!) == Citation(video: 2, seconds: 760))
}

@Test func failedTurnsAreNotSentBack() {
    var chat = Conversation(entryIDs: ["youtube:a"])
    chat.messages = [
        ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "a1"),
        ChatMessage(role: .user, text: "q2"), ChatMessage(role: .assistant, text: "HTTP 500", failed: true),
        ChatMessage(role: .user, text: "q3"),
    ]
    #expect(chat.sendable.map(\.text) == ["q1", "a1", "q3"])
    #expect(Conversation.id(for: ["b", "a"]) == Conversation.id(for: ["a", "b"]))
}

@Test func cliPromptCarriesHistory() {
    let turns = [
        ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "a1"),
        ChatMessage(role: .user, text: "q2"),
    ]
    var settings = AISettings()
    settings.language = "Turkish"
    #expect(settings.resolvedSummaryPrompt.hasPrefix("Summarize in Turkish."))
    #expect(settings.resolvedSystemPrompt.contains("Write in Turkish."))
    let prompt = AIClient.flatten(context: "<ctx/>", turns: turns)
    #expect(prompt.hasPrefix("<ctx/>"))
    #expect(prompt.contains("User: q1\n\nAssistant: a1"))
    #expect(prompt.hasSuffix("User: q2"))
    let first = AIClient.anthropicMessages(context: "<ctx/>", turns: turns)
    #expect(first.count == 3)
    #expect((first[0]["content"] as? [[String: Any]])?.count == 2)
}

/// Live: fetches a talk, asks the default provider (Claude Code) for a summary, then a follow-up.
/// Run with `NAB_LIVE=1 swift test --filter liveSummaryAndFollowUp`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NAB_LIVE"] != nil), .timeLimit(.minutes(3)))
func liveSummaryAndFollowUp() async throws {
    let capture = try await YouTubeSource().fetch(URL(string: "https://www.youtube.com/watch?v=8jPQjjsBbIc")!)
    let settings = AISettings()
    let client = AIClient(settings: settings, apiKey: nil)
    let context = ChatContext.pack([capture])

    func ask(_ turns: [ChatMessage]) async throws -> (String, Int, Duration) {
        let clock = ContinuousClock()
        var text = ""
        var chunks = 0
        let elapsed = try await clock.measure {
            for try await chunk in client.reply(context: context, turns: turns) {
                text += chunk
                chunks += 1
            }
        }
        return (text, chunks, elapsed)
    }

    var turns = [ChatMessage(role: .user, text: settings.resolvedSummaryPrompt, isSummaryRequest: true)]
    let (summary, chunks, took) = try await ask(turns)
    print("SUMMARY (\(chunks) chunks, \(took)):\n\(summary)\n")
    #expect(summary.count > 200)
    #expect(Citation.link(summary).contains("nab-cite://"))

    turns.append(ChatMessage(role: .assistant, text: summary))
    turns.append(
        ChatMessage(role: .user, text: "What exactly is a pre-mortem, according to the talk? One short paragraph."))
    let (answer, _, took2) = try await ask(turns)
    print("FOLLOW-UP (\(took2)):\n\(answer)\n")
    #expect(answer.count > 60)
}

@Test func settingsStoreOnlyWhatDiffers() throws {
    var settings = AISettings()
    settings.language = "Turkish"
    settings.command = settings.kind.defaultCommand
    let json = try #require(String(data: JSONEncoder().encode(settings), encoding: .utf8))
    #expect(!json.contains("systemPrompt") && !json.contains("summaryPrompt") && !json.contains("claude -p"))
    let back = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
    #expect(back.language == "Turkish" && back.systemPrompt == AISettings.defaultSystemPrompt)
    #expect(AISettings.languages.contains { $0.name == "Turkish" && $0.native == "Türkçe" })
    #expect(AISettings.languages.map(\.name) == AISettings.languages.map(\.name).sorted())
}

@Test func storedOldDefaultsFollowNewOnes() throws {
    let old = try #require(AISettings.previousSystemPrompts.first)
    let oldCommand = try #require(AISettings.previousCommands.first)
    let stored: [String: Any] = [
        "kind": "claudeCLI", "language": "German", "systemPrompt": old,
        // Dictionaries keyed by an enum are stored as [key, value, ...] arrays.
        "summaryPrompt": "Three bullets only.", "commands": ["claudeCLI", oldCommand],
    ]
    let settings = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: stored))
    #expect(settings.systemPrompt == AISettings.defaultSystemPrompt)
    #expect(settings.command == ProviderKind.claudeCLI.defaultCommand)
    #expect(settings.summaryPrompt == "Three bullets only.")
    #expect(settings.language == "German")
}

@Test func contextPackKeepsStructureAndTimecodes() {
    let segments = [
        Segment(start: 0, duration: 5, text: "Hello and welcome."),
        Segment(start: 3_700, duration: 5, text: "Thanks for watching."),
    ]
    var capture = Capture(
        source: .youtube, sourceID: "abc", url: URL(string: "https://www.youtube.com/watch?v=abc")!,
        title: "A talk", author: "Someone", duration: 3_725,
        chapters: [Chapter(start: 0, title: "Intro"), Chapter(start: 3_600, title: "Close")],
        transcript: Transcript(languageCode: "en", languageName: "English", isGenerated: true, segments: segments)
    )
    capture.aiSummary = "Earlier summary."
    let day = Date(timeIntervalSince1970: 1_790_000_000)

    let pack = ContextPack.render([capture], capturedAt: day)
    #expect(pack.hasPrefix(#"<nab_context sources="1" packed="2026-09-21">"#))
    #expect(pack.contains(#"<source type="youtube" id="abc" url="https://www.youtube.com/watch?v=abc">"#))
    #expect(pack.contains("- Duration: 1:02:05\n- Transcript: English, auto-generated"))
    #expect(pack.contains("## Chapters\n[0:00] Intro\n[1:00:00] Close"))
    #expect(pack.contains("### Close\n[1:01:40] Thanks for watching."))
    #expect(pack.contains("Earlier summary."))
    #expect(!ChatContext.pack([capture]).contains("Earlier summary."))
    #expect(ContextPack.render([capture, capture], capturedAt: day).contains("Index:\n1. A talk — Someone (1:02:05)"))
}

@Test func timecodesCoverHoursAndClampNegatives() {
    #expect(Timecode.string(65) == "1:05")
    #expect(Timecode.string(3_723.9) == "1:02:03")
    #expect(Timecode.string(-4) == "0:00")
}

@Test func spokenLanguageTrackWinsByLanguageNotPrefix() throws {
    func tracks(_ json: String) throws -> [Player.Track] {
        try JSONDecoder().decode([Player.Track].self, from: Data(json.utf8))
    }
    let english = try tracks(
        #"[{"baseUrl":"a","languageCode":"en","kind":"asr"},{"baseUrl":"b","languageCode":"de"},{"baseUrl":"c","languageCode":"en-GB"}]"#
    )
    #expect(YouTubeSource.preferredTrack(english)?.baseUrl == "c")
    // Filipino ("fil") and Finnish ("fi") share a prefix but not a language.
    let filipino = try tracks(
        #"[{"baseUrl":"a","languageCode":"fil","kind":"asr"},{"baseUrl":"b","languageCode":"fi"}]"#)
    #expect(YouTubeSource.preferredTrack(filipino)?.baseUrl == "a")
    #expect(YouTubeSource.preferredTrack(try tracks(#"[{"baseUrl":"b","languageCode":"fi"}]"#))?.baseUrl == "b")
}

@Test func serverSentEventsJoinDataLinesUntilABlankLine() {
    var parser = ServerSentEvents()
    let lines = [": keep-alive", "event: delta", "data: {\"a\":", "data: 1}\r", "", "", "data:[DONE]", ""]
    #expect(lines.compactMap { parser.feed($0) } == ["{\"a\":\n1}", "[DONE]"])
}

@Test func serverAddressIsCheckedNotTrusted() throws {
    var settings = AISettings()
    settings.kind = .ollama
    settings.model = "llama"
    #expect(AIClient(settings: settings, apiKey: nil).problem == nil)
    #expect(
        try AIClient(settings: settings, apiKey: nil).endpoint("/models").absoluteString
            == "http://localhost:11434/v1/models")
    for address in ["http://a b", "localhost:11434", "file:///etc", "https://"] {
        settings.baseURL = address
        #expect(AIClient(settings: settings, apiKey: nil).problem != nil, "\(address)")
    }
}

@Test func longPackIDsGetTheirOwnChatFile() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "nab-tests-\(UUID().uuidString)/Library")
    defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
    let store = LibraryStore(folder: folder)
    // Two sets of twelve videos that differ only in the first one.
    let shared = (1...11).map { "youtube:video\($0)abcd" }
    let a = Conversation(entryIDs: ["youtube:aaaaaaaaaaa"] + shared)
    var b = Conversation(entryIDs: ["youtube:bbbbbbbbbbb"] + shared)
    b.messages = [ChatMessage(role: .user, text: "only in b")]
    await store.save(a)
    await store.save(b)
    #expect(await store.conversation(a.id)?.messages.isEmpty == true)
    #expect(await store.conversation(b.id)?.messages.first?.text == "only in b")
    #expect(LibraryStore.fileName(for: "youtube:abc") == "youtube_abc.json")
}

// MARK: Command-line providers

private func runCLI(_ command: String, prompt: String = "question") async throws -> String {
    var settings = AISettings()
    settings.command = command
    var text = ""
    for try await chunk in AIClient(settings: settings, apiKey: nil)
        .reply(context: prompt, turns: [ChatMessage(role: .user, text: "q")])
    { text += chunk }
    return text
}

@Test(.timeLimit(.minutes(1))) func commandThatIgnoresItsInputDoesNotKillTheApp() async throws {
    // Larger than a pipe buffer, so the write is still in progress when the command exits.
    #expect(try await runCLI("echo ok", prompt: String(repeating: "x", count: 1_000_000)) == "ok\n")
}

@Test(.timeLimit(.minutes(1))) func chattyStderrDoesNotStallTheAnswer() async throws {
    #expect(try await runCLI("head -c 300000 /dev/zero | tr '\\0' x >&2; echo done") == "done\n")
}

@Test(.timeLimit(.minutes(1))) func failingCommandReportsItsStderr() async throws {
    do {
        _ = try await runCLI("echo 'not signed in' >&2; exit 3")
        Issue.record("expected the command to fail")
    } catch {
        #expect(error.localizedDescription.contains("exit 3"))
        #expect(error.localizedDescription.contains("not signed in"))
    }
}

@Test(.timeLimit(.minutes(1))) func plainOutputKeepsParagraphBreaks() async throws {
    #expect(try await runCLI("printf 'one\\n\\ntwo\\n'") == "one\n\ntwo\n")
}

@Test(.timeLimit(.minutes(1))) func stoppingAnAnswerEndsACommandThatIgnoresSIGTERM() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "nab-test-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let answer = Task { try await runCLI("echo $$ > '\(pidFile.path)'; trap '' TERM; sleep 30") }
    var pid: pid_t?
    for _ in 0..<100 where pid == nil {
        try await Task.sleep(for: .milliseconds(50))
        pid = (try? String(contentsOf: pidFile, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    let running = try #require(pid)
    answer.cancel()
    _ = await answer.result
    try await Task.sleep(for: .seconds(3))
    #expect(kill(running, 0) != 0, "the command is still running")
}
