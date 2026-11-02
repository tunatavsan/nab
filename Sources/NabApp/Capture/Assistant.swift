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
    /// Every chat, newest first, for the home page and search. Loaded at launch.
    private(set) var conversations: [Conversation] = []
    /// Changes while an answer streams do not reindex (see `reindex`), so Home and search redraw on a new,
    /// finished or cleared chat instead of at 30 Hz; a chat view reads its live text through `conversation(_:)`.
    private var byID: [String: Conversation] = [:]
    @ObservationIgnored let previewCache = ChatPreviewCache()
    /// The clock a held question measures its wait with; tests and previews may replace it.
    @ObservationIgnored var clock: () -> ContinuousClock.Instant = { .now }
    private(set) var streaming: Set<String> = []
    /// Questions typed while their record was still being read, by chat. They go out by themselves when the capture
    /// arrives, even if the window that took them is gone; kept in memory only.
    private(set) var waiting: [String: ChatMessage] = [:]
    /// Opens the settings page of the library window; set by the app delegate.
    @ObservationIgnored var openSettings: () -> Void = {}

    /// The app's assistant, for views that are placed without being handed one (the provider chooser).
    @ObservationIgnored static weak var main: Assistant?

    private let center: CaptureCenter
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var keyCache: [ProviderKind: String] = [:]
    private var keyRevision = 0

    init(center: CaptureCenter) {
        self.center = center
        settings = AISettings.load()
        center.onRemove = { [weak self] ids in self?.entriesRemoved(ids) }
        Self.main = self
        Task { [weak self, store = center.store] in
            let saved = await store.allConversations()
            guard let self else { return }
            for chat in saved where byID[chat.id] == nil { byID[chat.id] = chat }
            reindex()
        }
    }

    /// Chats with messages, newest first; empty drafts stay out of the index. Called when the set of chats or a
    /// finished message changes: a new chat, load, regenerate, clear and complete; never for a streamed chunk.
    private func reindex() {
        conversations = byID.values.filter { !$0.messages.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Previews of `conversations`, built only for chats that changed since the last call.
    func previews(entries: [Entry]) -> [ChatPreview] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return previewCache.previews(
            for: conversations, titleOf: { byID[$0]?.title }, tallyOf: { Tally($0.compactMap { byID[$0] }) })
    }

    // MARK: Provider

    var client: AIClient {
        AIClient(settings: settings, apiKey: settings.kind.usesKey ? key(for: settings.kind) : nil)
    }

    /// Read once from the keychain, then from memory, so views can check it on every render.
    func key(for kind: ProviderKind) -> String {
        // Reading this registers an observation dependency, so views re-read the key after `setKey` bumps it.
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

    func conversation(_ entryIDs: [String]) -> Conversation? { byID[Conversation.id(for: entryIDs)] }
    func isStreaming(_ entryIDs: [String]) -> Bool { streaming.contains(Conversation.id(for: entryIDs)) }
    /// How many of these records have a transcript to read.
    func transcriptCount(_ entryIDs: [String]) -> Int {
        entryIDs.count { center.entry($0)?.capture?.transcript != nil }
    }
    func isWaiting(_ entryIDs: [String]) -> Bool { waiting[Conversation.id(for: entryIDs)] != nil }

    /// Loads a saved chat the first time its videos are shown.
    func load(_ entryIDs: [String]) async {
        let id = Conversation.id(for: entryIDs)
        guard byID[id] == nil, let saved = await center.store.conversation(id), byID[id] == nil else {
            return
        }
        byID[id] = saved
        reindex()
    }

    /// Whether a summary should first ask which AI to use: the user never chose one, or the chosen one cannot answer.
    var needsProviderChoice: Bool { !AISettings.isSaved || client.problem != nil }

    /// Starts the summary question. A provider that cannot answer is the caller's to handle (see
    /// `needsProviderChoice`); nothing opens here.
    @discardableResult
    func summarize(_ entryIDs: [String]) -> Bool {
        send(
            ChatMessage(role: .user, text: settings.resolvedSummaryPrompt, isSummaryRequest: true), to: entryIDs,
            opensSettings: false)
    }

    /// Summarizes unless the chat already has one; for buttons that mean "show me what this is about".
    func summarizeIfNew(_ entryIDs: [String]) async {
        await load(entryIDs)
        if conversation(entryIDs)?.messages.isEmpty ?? true { summarize(entryIDs) }
    }

    /// Returns whether the question went out; it does not when the provider still needs setting up.
    @discardableResult
    func ask(_ text: String, about entryIDs: [String]) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return send(ChatMessage(role: .user, text: text), to: entryIDs)
    }

    /// Asks the last question again, replacing its answer.
    func regenerate(_ entryIDs: [String]) {
        let id = Conversation.id(for: entryIDs)
        guard var conversation = byID[id], !streaming.contains(id),
            let index = conversation.messages.lastIndex(where: { $0.role == .user })
        else { return }
        let question = conversation.messages[index]
        conversation.messages.removeSubrange(index...)
        byID[id] = conversation
        reindex()
        send(ChatMessage(role: .user, text: question.text, isSummaryRequest: question.isSummaryRequest), to: entryIDs)
    }

    /// Videos left the library: chats left with no video stop streaming and are dropped, in memory and on disk, so
    /// a finishing answer cannot write them back. A chat that still has a video in the library is kept.
    private func entriesRemoved(_ removed: Set<String>) {
        let remaining = Set(center.entries.map(\.id))
        let gone = Conversation.ids(about: removed, keeping: remaining, in: byID.values)
        guard !gone.isEmpty else { return }
        for id in gone {
            tasks[id]?.cancel()
            tasks[id] = nil
            streaming.remove(id)
            waiting[id] = nil
            byID[id] = nil
        }
        reindex()
        let store = center.store
        Task { [center] in
            do {
                for id in gone { try await store.deleteConversation(id) }
            } catch {
                center.report(error, while: "removing chats of removed items")
            }
        }
    }

    func stop(_ entryIDs: [String]) {
        tasks[Conversation.id(for: entryIDs)]?.cancel()
    }

    func clear(_ entryIDs: [String]) {
        let id = Conversation.id(for: entryIDs)
        tasks[id]?.cancel()
        byID[id] = Conversation(entryIDs: entryIDs)
        reindex()
        let store = center.store
        Task { [center] in
            do {
                try await store.deleteConversation(id)
            } catch {
                center.report(error, while: "clearing the chat")
            }
        }
    }

    @discardableResult
    private func send(
        _ question: ChatMessage, to entryIDs: [String], opensSettings: Bool = true, timedOut: Bool = false
    ) -> Bool {
        let id = Conversation.id(for: entryIDs)
        guard !streaming.contains(id), waiting[id] == nil else { return false }
        let captures = entryIDs.compactMap { center.entry($0)?.capture }
        let reading = entryIDs.contains { center.entry($0)?.phase == .fetching }
        let plan = AskScope.sendPlan(
            readyCount: captures.count, reading: reading,
            failure: entryIDs.compactMap { center.entry($0)?.failure }.first, timedOut: timedOut)
        switch plan {
        case .refuse: return false
        case .fail(let reason):
            // A record that could not be read says so in the chat, whatever the provider.
            showFailure(question, for: entryIDs, reason)
            return true
        case .hold, .send: break
        }
        let client = client
        if client.problem != nil {
            if opensSettings { openSettings() }
            return false
        }
        if plan == .hold {
            hold(question, for: entryIDs)
            return true
        }

        var conversation = byID[id] ?? Conversation(entryIDs: entryIDs)
        conversation.messages.append(question)
        let turns = conversation.sendable
        let answer = ChatMessage(role: .assistant, text: "", model: client.modelLabel)
        conversation.messages.append(answer)
        byID[id] = conversation
        reindex()
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
        return true
    }

    /// Keeps a question until its record has been read, then sends it; a failed read puts the reason in the chat.
    private func hold(_ question: ChatMessage, for entryIDs: [String]) {
        let id = Conversation.id(for: entryIDs)
        waiting[id] = question
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            _ = await HeldWait.wait(
                reading: { entryIDs.contains { self.center.entry($0)?.phase == .fetching } },
                cancelled: { Task.isCancelled }, now: { self.clock() }, sleep: { try? await Task.sleep(for: $0) })
            self.release(id, question, entryIDs, cancelled: Task.isCancelled)
        }
    }

    private func release(_ id: String, _ question: ChatMessage, _ entryIDs: [String], cancelled: Bool) {
        waiting[id] = nil
        tasks[id] = nil
        guard !cancelled else { return }
        let ready = entryIDs.filter { center.entry($0)?.capture != nil }
        let failure = entryIDs.compactMap { center.entry($0)?.failure }.first
        switch AskScope.resolveHeld(readyCount: ready.count, failure: failure) {
        case .send:
            // A fetch still stuck after the limit does not hold the question back: it goes with what is ready, and
            // one chat line says what is missing.
            let missing = AskScope.missingRecords(
                entryIDs.map {
                    let entry = center.entry($0)
                    return (
                        id: $0, hasCapture: entry?.capture != nil, reading: entry?.phase == .fetching,
                        failed: entry?.failure != nil
                    )
                }
            ).map { center.entry($0)?.title ?? $0 }
            if !missing.isEmpty {
                var conversation = byID[id] ?? Conversation(entryIDs: entryIDs)
                conversation.messages.append(
                    ChatMessage(role: .assistant, text: AskScope.missingNote(titles: missing), failed: true))
                byID[id] = conversation
            }
            // Nothing opens in the background: a provider that cannot answer is one line in the chat.
            if !send(question, to: entryIDs, opensSettings: false, timedOut: true) {
                showFailure(question, for: entryIDs, client.problem ?? "The question could not be sent.")
            }
        case .fail(let reason):
            showFailure(question, for: entryIDs, reason)
        }
    }

    /// The question and a failed answer that says why nothing went out.
    private func showFailure(_ question: ChatMessage, for entryIDs: [String], _ reason: String) {
        let id = Conversation.id(for: entryIDs)
        var conversation = byID[id] ?? Conversation(entryIDs: entryIDs)
        conversation.messages.append(question)
        conversation.messages.append(ChatMessage(role: .assistant, text: reason, failed: true))
        conversation.updatedAt = .now
        byID[id] = conversation
        reindex()
        let store = center.store
        Task { [center] in
            do {
                try await store.save(conversation)
            } catch {
                center.report(error, while: "saving the chat")
            }
        }
    }

    private func update(_ id: String, _ messageID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = byID[id]?.messages.firstIndex(where: { $0.id == messageID }) else { return }
        change(&byID[id]!.messages[index])
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
        guard var conversation = byID[id] else { return }
        conversation.updatedAt = .now
        byID[id] = conversation
        reindex()
        let store = center.store
        Task { [center] in
            do {
                try await store.save(conversation)
            } catch {
                center.report(error, while: "saving the chat")
            }
        }

        // A finished summary of one video also travels with it in copied context packs.
        if let entryID, failure == nil, !cancelled, !text.isEmpty,
            let model = conversation.messages.first(where: { $0.id == answerID })?.model
        {
            center.setAISummary(text, model: model, for: entryID)
        }
    }
}
