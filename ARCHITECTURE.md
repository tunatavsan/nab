# Architecture

Nab is a Swift package of five targets, built with Swift 6 strict concurrency and no third-party code. The app is an
agent (`LSUIElement`): it lives in the menu bar and shows a Dock icon only while its library window is open.

| Target | Depends on | Contents |
| --- | --- | --- |
| `NabCore` | Foundation, CryptoKit | `Capture` and its transcript, `SourceProvider` and `SourceRegistry`, `ContextPack`, `Conversation`, `Citation`, `LibraryStore`, `Gate`. |
| `NabYouTube` | `NabCore` | `YouTubeSource`: link parsing, the player request, caption tracks, captions and chapters. |
| `NabAI` | `NabCore` | `AISettings`, `ProviderKind`, `Keychain` and `AIClient`, which streams one assistant turn from any provider. |
| `NabApp` | all three | The app: `Capture/` (shortcut, browser bridge, `CaptureCenter`, `Assistant`), `UI/` (panel, toast, library, reader, chat, settings) and `Design/` (tokens, motion, fonts, the reveal and the frame probe). |
| `NabCLI` | `NabCore`, `NabYouTube` | The `nab` command. |

`NabCore` has no UI and makes no network requests, so everything above it can be tested with plain values.

## Capturing a video

1. ⌃⌥N is a Carbon hot key (`HotKey`), which needs no permission. `nab://front` does the same.
2. `BrowserBridge` asks the frontmost browser for its active tab's URL and title with one Apple Event, on a serial
   queue with a four second timeout. Chromium browsers and Safari use different dictionaries; both are covered.
3. `SourceRegistry` finds the `SourceProvider` that recognizes the link and gives it a stable entry id
   (`youtube:<video id>`). A link already in the library is moved back into the tray instead of fetched again.
4. `CaptureCenter` adds the entry right away, so the tray and the toast show it while it loads, and fetches it through
   a `Gate` that runs at most six requests at once. The fetch holds a `ProcessInfo` activity, because App Nap otherwise
   throttles a background menu bar app's network work.
5. `YouTubeSource` sends one request to YouTube's player endpoint, using the Android client, which answers without an
   API key and without the proof-of-origin token the web client needs. The response lists caption tracks; Nab takes
   a human-made track in the spoken language, then the automatic one, and downloads it as `json3`. Chapters are parsed
   from the description the way YouTube derives them. Each request is hedged: if it has not answered in 1.2 seconds,
   a second copy goes out on a separate connection pool and the first answer wins.
6. The finished `Capture` is saved by `LibraryStore` as one JSON file per entry in
   `~/Library/Application Support/Nab/Library`.

## The context pack

`ContextPack.render` turns any number of captures into one block of text. XML tags mark where each source starts and
ends, and Markdown carries the structure inside: title, facts, chapters, description and the transcript.
`Transcript.paragraphs` groups caption segments into passages that start at a chapter, or once 45 seconds have passed
and a sentence ends. The reader shows the same passages, so a timecode a model quotes points at a passage the user can
see.

## Chatting

1. `Assistant` keeps one `Conversation` per video, or per set of videos asked about together. **Summarize** is the
   first question of a chat; its text is the summary request from Settings.
2. Each turn sends the context pack and the conversation so far to `AIClient`, which streams the answer back as text:
   - **Anthropic API:** the Messages API over HTTP with server-sent events. The context pack is its own content block
     with a cache breakpoint, so follow-up questions read it from the prompt cache.
   - **OpenAI-compatible servers** (OpenAI, OpenRouter, Ollama, LM Studio, others): chat completions with
     server-sent events.
   - **Command-line tools** (Claude Code, Codex): the user's command runs in their login shell from an empty
     temporary folder, the prompt goes in on standard input, and `$NAB_SYSTEM` and `$NAB_MODEL` carry the system
     prompt and model. Claude Code's `stream-json` output is parsed for token deltas.
3. Answers are written to the conversation about 30 times a second while they stream, and saved under
   `~/Library/Application Support/Nab/Chats` when the turn ends. A finished summary of a single video is also stored
   on its capture, so it travels with the video in copied context packs.
4. `Citation.link` turns `[12:40]` and `[2 12:40]` in an answer into `nab-cite:` links. In a single-video chat, a click
   scrolls the reader to the passage and highlights it; otherwise it opens the video at that second. While an answer
   is being written its links reach the chat's `OpenURLAction`; once it is selectable, macOS sends them to the system,
   which hands `nab-cite:` back to the app because Nab claims that scheme. Both paths end in `LibraryModel.open`.

## Interface

SwiftUI views live in AppKit windows and panels: the menu bar panel and the toast are borderless `NSPanel`s, and the
library is an `NSWindow` with a `NavigationSplitView` and the chat as its inspector. Settings is a page in the library
window. Colors, type, radii and motion come from `Design/`; views define no color, font or animation of their own, and
keep only one-off layout numbers. Animations that loop or bounce stand still when Reduce Motion is on.

Panels open and close on Core Animation springs with a preferred frame rate of 120 Hz. Answers write themselves in with
`RevealRenderer`, a `TextRenderer` that draws each glyph sharpening out of a blur behind a moving edge. `RevealClock`
moves that edge toward the text that has arrived, so a stream that comes in bursts reads as one motion. Selectable text
on macOS skips custom renderers, so an answer becomes selectable once it has been fully drawn.

Set `NAB_FRAME_PROBE=1` to log how many display refreshes each animation actually drew to
`~/Library/Logs/Nab/frames.log`.

## Adding a source

A source is one type that conforms to `SourceProvider`:

```swift
public protocol SourceProvider: Sendable {
    var kind: SourceKind { get }
    /// Returns the source's stable id for `url`, or nil when this provider does not handle it.
    func identify(_ url: URL) -> String?
    func fetch(_ url: URL) async throws -> Capture
    /// Cover images for an item, largest first, known from its id alone so they show before the fetch ends.
    func covers(forID id: String) -> [URL]
    /// A link that opens the item at a moment.
    func link(to capture: Capture, at seconds: TimeInterval) -> URL
}
```

`covers` and `link` have defaults (no covers until the fetch finds one; links open the item itself). Add a
`SourceKind`, implement the provider in its own target, and register it in `SourceRegistry.standard` in the app and in
the CLI. The library, the reader, the context pack, the chat and the CLI work with it unchanged.

## Tests

`Tests/NabTests` uses Swift Testing, one suite per area, and needs neither the network nor the user's library or
keychain:

- **YouTube:** link shapes, chapters, captions, caption track choice, covers and links to a moment.
- **Library and context pack:** passages, the registry, the pack's structure, text from a video that tries to close the
  pack's tags, timecodes, the store's files (including long chat ids and unreadable entries) and the `Gate`.
- **Conversations and settings:** citations, failed turns, prompt language, what is stored and how old defaults
  migrate.
- **AI client:** the prompts sent to each provider, server-sent events, server addresses, and the Anthropic and
  OpenAI-compatible streams end to end against a stubbed `URLSession`.
- **Command-line providers:** small shell commands that ignore their input, flood standard error, fail, print Markdown
  paragraphs, emit Claude Code's `stream-json`, or ignore SIGTERM.

The `Live` suite fetches a real video and asks the configured provider for a summary and a follow-up; it runs only
when `NAB_LIVE=1` is set.
