import AppKit
import NabAI
import NabCore
import Observation

/// Conversations about videos. "Summarize" is the first question of a chat; follow-ups continue it
/// with the same transcripts in context. One chat per video, or per set of videos asked about together.
@MainActor
@Observable
final class Assistant {
    var settings: AISettings {
        didSet { if settings != oldValue { settings.save() } }
    }
    private(set) var conversations: [String: Conversation] = [:]
    private(set) var streaming: Set<String> = []
    /// Opens the settings page of the library window; set by the app delegate.
    @ObservationIgnored var openSettings: () -> Void = {}

    private let center: CaptureCenter
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var keyCache: [ProviderKind: String] = [:]
    private var keyRevision = 0

    init(center: CaptureCenter) {
        self.center = center
        settings = AISettings.load()
    }

    // MARK: Provider

    var client: AIClient {
        AIClient(settings: settings, apiKey: settings.kind.usesKey ? key(for: settings.kind) : nil)
    }

    /// Read once from the keychain, then from memory, so views can check it on every render.
    func key(for kind: ProviderKind) -> String {
        _ = keyRevision
        if let cached = keyCache[kind] { return cached }
        let value = Keychain.key(for: kind) ?? ""
        keyCache[kind] = value
        return value
    }

    func setKey(_ value: String, for kind: ProviderKind) throws {
        try Keychain.setKey(value, for: kind)
        keyCache[kind] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        keyRevision += 1
    }

    // MARK: Conversations

    func conversation(_ entryIDs: [String]) -> Conversation? { conversations[Conversation.id(for: entryIDs)] }
    func isStreaming(_ entryIDs: [String]) -> Bool { streaming.contains(Conversation.id(for: entryIDs)) }

    /// Loads a saved chat the first time its videos are shown.
    func load(_ entryIDs: [String]) async {
        let id = Conversation.id(for: entryIDs)
        guard conversations[id] == nil, let saved = await center.store.conversation(id), conversations[id] == nil else {
            return
        }
        conversations[id] = saved
    }

    func summarize(_ entryIDs: [String]) {
        send(ChatMessage(role: .user, text: settings.resolvedSummaryPrompt, isSummaryRequest: true), to: entryIDs)
    }

    /// Summarizes unless the chat already has one; for buttons that mean "show me what this is about".
    func summarizeIfNew(_ entryIDs: [String]) async {
        await load(entryIDs)
        if conversation(entryIDs)?.messages.isEmpty ?? true { summarize(entryIDs) }
    }

    func ask(_ text: String, about entryIDs: [String]) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(ChatMessage(role: .user, text: text), to: entryIDs)
    }

    /// Asks the last question again, replacing its answer.
    func regenerate(_ entryIDs: [String]) {
        let id = Conversation.id(for: entryIDs)
        guard var conversation = conversations[id], !streaming.contains(id),
            let index = conversation.messages.lastIndex(where: { $0.role == .user })
        else { return }
        let question = conversation.messages[index]
        conversation.messages.removeSubrange(index...)
        conversations[id] = conversation
        send(ChatMessage(role: .user, text: question.text, isSummaryRequest: question.isSummaryRequest), to: entryIDs)
    }

    func stop(_ entryIDs: [String]) {
        tasks[Conversation.id(for: entryIDs)]?.cancel()
    }

    func clear(_ entryIDs: [String]) {
        let id = Conversation.id(for: entryIDs)
        tasks[id]?.cancel()
        conversations[id] = Conversation(entryIDs: entryIDs)
        let store = center.store
        Task { await store.deleteConversation(id) }
    }

    private func send(_ question: ChatMessage, to entryIDs: [String]) {
        let id = Conversation.id(for: entryIDs)
        guard !streaming.contains(id) else { return }
        let captures = entryIDs.compactMap { center.entry($0)?.capture }
        guard !captures.isEmpty else { return }
        let client = client
        if client.problem != nil {
            openSettings()
            return
        }

        var conversation = conversations[id] ?? Conversation(entryIDs: entryIDs)
        conversation.messages.append(question)
        let turns = conversation.sendable
        let answer = ChatMessage(role: .assistant, text: "", model: client.modelLabel)
        conversation.messages.append(answer)
        conversations[id] = conversation
        streaming.insert(id)

        let context = ChatContext.pack(captures)
        tasks[id] = Task { [weak self] in
            // Answers keep streaming while Nab sits in the background.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Answering a question")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            var text = ""
            var failure: String?
            var lastShown = ContinuousClock.now
            do {
                for try await chunk in client.reply(context: context, turns: turns) {
                    text += chunk
                    // Redraw at most ~30 times a second; Markdown re-layout per token is wasted work.
                    if ContinuousClock.now - lastShown > .milliseconds(33) {
                        lastShown = .now
                        self?.update(id, answer.id) { $0.text = text }
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
            self?.complete(
                id, answerID: answer.id, text: text, failure: failure, cancelled: Task.isCancelled,
                summaryOf: question.isSummaryRequest && entryIDs.count == 1 ? entryIDs[0] : nil)
        }
    }

    private func update(_ id: String, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = conversations[id]?.messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&conversations[id]!.messages[index])
    }

    private func complete(
        _ id: String, answerID: UUID, text: String, failure: String?, cancelled: Bool, summaryOf entryID: String?
    ) {
        tasks[id] = nil
        streaming.remove(id)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id, answerID) { message in
            if let failure, !cancelled {
                message.text = failure
                message.failed = true
            } else if text.isEmpty {
                message.text = cancelled ? "Stopped." : "The model returned an empty answer."
                message.failed = true
            } else {
                message.text = text
            }
        }
        guard var conversation = conversations[id] else { return }
        conversation.updatedAt = .now
        conversations[id] = conversation
        let store = center.store
        Task { await store.save(conversation) }

        // A finished summary of one video also travels with it in copied context packs.
        if let entryID, failure == nil, !cancelled, !text.isEmpty,
            let model = conversation.messages.first(where: { $0.id == answerID })?.model
        {
            center.setAISummary(text, model: model, for: entryID)
        }
    }
}
