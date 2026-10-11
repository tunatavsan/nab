import Foundation
import NabCore
import NabYouTube
import Testing

@testable import NabAI

/// Fetches a real talk and asks the default provider (Claude Code) for a summary, then a follow-up.
/// Run with `NAB_LIVE=1 swift test --filter LiveTests`.
@Suite("Live", .enabled(if: ProcessInfo.processInfo.environment["NAB_LIVE"] != nil), .timeLimit(.minutes(3)))
struct LiveTests {
    @Test func summaryAndFollowUp() async throws {
        let capture = try await YouTubeSource().fetch(URL(string: "https://www.youtube.com/watch?v=8jPQjjsBbIc")!)
        let settings = AISettings()
        let client = AIClient(settings: settings, apiKey: nil)
        let context = ChatContext.pack([capture])

        var turns = [ChatMessage(role: .user, text: settings.resolvedSummaryPrompt, isSummaryRequest: true)]
        let summary = try await collect(client.reply(context: context, turns: turns))
        print("SUMMARY:\n\(summary)\n")
        #expect(summary.count > 200)
        #expect(Citation.link(summary).contains("nab-cite://"))

        turns.append(ChatMessage(role: .assistant, text: summary))
        turns.append(
            ChatMessage(role: .user, text: "What exactly is a pre-mortem, according to the talk? One short paragraph."))
        let answer = try await collect(client.reply(context: context, turns: turns))
        print("FOLLOW-UP:\n\(answer)\n")
        #expect(answer.count > 60)
    }
}
