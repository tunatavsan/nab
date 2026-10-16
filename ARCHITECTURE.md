# Architecture

Nab is a Swift package of five targets, built with Swift 6 strict concurrency and no third-party code. The app is an
agent (`LSUIElement`): it lives in the menu bar and shows a Dock icon only while its library window is open.

| Target | Depends on | Contents |
| --- | --- | --- |
| `NabCore` | Foundation, CryptoKit | `Capture` and its transcript, `SourceProvider` and `SourceRegistry`, `ContextPack`, `Conversation`, `Citation`, `LibraryStore`, `Gate`, and the pure logic behind the interface: `HomeLayout`, `HomeGrid`, `LibrarySearch`, `TranscriptSearch`, `AskScope`, `ChatStamp`, `RackText` and `SessionGrouping`. |
| `NabYouTube` | `NabCore` | `YouTubeSource`: link parsing, the player request, caption tracks, captions and chapters. |
| `NabAI` | `NabCore` | `AISettings`, `ProviderKind`, `Keychain` and `AIClient`, which streams one assistant turn from any provider; `ModelNames`, `ModelChoices` and `ProviderInfo` (provider status and probe) feed the settings page. |
| `NabApp` | all three | The app: `Capture/` (shortcut, browser bridge, `CaptureCenter`, `Assistant`), `UI/` (menu panel, rack, library and its pages, ask window, search palette, chat, settings) and `Design/` (tokens, motion, fonts, the reveal and the frame probe). |
| `NabCLI` | `NabCore`, `NabYouTube` | The `nab` command. |

`NabCore` has no UI and makes no network requests, so everything above it can be tested with plain values.

## Capturing a video

1. ⌃⌥N is a Carbon hot key (`HotKey`), which needs no permission. `nab://front` does the same. Before reading the
   tab, Nab notes the pasteboard's change count; when the transcript lands and nothing else was copied meanwhile, the
   video's context pack goes on the clipboard.
2. `BrowserBridge` asks the frontmost browser for its active tab's URL and title with one Apple Event, on a serial
   queue with a four second timeout. Chromium browsers and Safari use different dictionaries; both are covered.
3. `SourceRegistry` finds the `SourceProvider` that recognizes the link and gives it a stable entry id
   (`youtube:<video id>`). A link already in the library is moved into the open session instead of fetched again.
4. `CaptureCenter` adds the entry to the open session right away, so the rack and the menu show it while it loads,
   and fetches it through
   a `Gate` that runs at most six requests at once. The fetch holds a `ProcessInfo` activity, because App Nap otherwise
   throttles a background menu bar app's network work.
5. `YouTubeSource` sends one request to YouTube's player endpoint, using the Android client, which answers without an
   API key and without the proof-of-origin token the web client needs. The response lists caption tracks, one
   automatic track per dub language on a dubbed video. Nab reads the original language from the audio track whose id
   ends in `.4` (the default audio track follows the viewer's language and can be a dub), takes a human-made track in
   it, then the automatic one, and downloads it as `json3`. Chapters are parsed from the description the way YouTube
   derives them. Each request is hedged: if it has not answered in 0.45 seconds, a second copy goes out on a separate
   connection pool and the first answer wins.
6. The finished `Capture` is saved by `LibraryStore` as one JSON file per entry in
   `~/Library/Application Support/Nab/Library`. Each entry records its `sessionID`; `SessionGrouping` rebuilds the
   sets from it, and clusters entries saved before sessions existed by a pause of more than five minutes.

A session ends when it is copied (⌃⌥A) or summarized (⌃⌥S), the next nab then starting a new one, on ⌃⌥X, or after five
minutes without a nab. Its id and last activity are kept in `UserDefaults`, so a relaunch inside those five minutes
resumes it.

## The context pack

`ContextPack.render` turns any number of captures into one block of text. XML tags mark where each source starts and
ends, and Markdown carries the structure inside: title, facts, chapters, description and the transcript.
`Transcript.paragraphs` groups caption segments into passages that start at a chapter, or once 45 seconds have passed
and a sentence ends. The transcript views show the same passages, so a timecode a model quotes points at a passage the user can
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
     temporary folder, the prompt goes in on standard input, and `$NAB_SYSTEM`, `$NAB_MODEL` and `$NAB_EFFORT` carry
     the system prompt, model and effort. `CLIPath` appends `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`
     to `PATH`, because an app opened from the Dock starts with the system path. Claude Code's `stream-json` output is
     parsed for token deltas. `CLIStatus` reads `--version`, `claude auth status` and `codex login status` for the
     setup guide in Settings; Nab never runs an install or sign-in command.
3. Answers are written to the conversation about 30 times a second while they stream, and saved under
   `~/Library/Application Support/Nab/Chats` when the turn ends. A finished summary of a single video is also stored
   on its capture, so it travels with the video in copied context packs.
4. `Citation.link` turns `[12:40]` and `[2 12:40]` in an answer into `nab-cite:` links, and every timecode click in the
   app, cited or not, goes to `PlaybackRouter.play(entryID:at:)` (see Playing a moment). ⌘-click opens the transcript
   at that moment instead. Links in an answer reach the app's own `OpenURLAction` whether the text is streaming or
   selectable; other links in an answer open only when they are `http` or `https`.

## Interface

SwiftUI views live in AppKit windows and panels: the menu bar panel, the rack and the ask window are borderless
`NSPanel`s, and the library is an `NSWindow` of one fixed size (1240 × 800 pt) that shows one page at a time under a
toolbar that stays the same on every page; actions that belong to one page sit on that page. Colors, type, radii and motion come
from `Sources/NabApp/Design`: `Tokens.swift` (palette, type, radii), `Motion.swift`, `Fonts.swift`, `Reveal.swift` and
`FrameProbe.swift`. Views define no color, font or animation of their own, and keep only one-off layout numbers.
Animations that loop or bounce stand still when Reduce Motion is on.

### Playing a moment

`PlaybackRouter` (`Player/`) is the one entry point for playing a video at a second. It checks the YouTube id, then asks
`PlaybackPlan` (pure, in `NabCore`) for the targets to try in order: the video's open browser tab first, whatever the
setting; then the pinned player if it is open; then the library window, or a new tab when `player.target` is
`browser`. A video YouTube will not embed goes to a new tab.

- **Player** (`MiniPlayer.swift`, `PinPanel.swift`): one web view running YouTube's IFrame player, seeked with numbers
  built in Swift. It sits above the video page in the library; **Pin** moves the same web view into a floating panel
  that keeps 16:9 when resized and remembers its frame, and **Unpin** brings it back. Main-frame and new-window
  navigation is limited to YouTube and Google hosts; anything else opens in the browser. The web view uses the
  persistent website data store, so a sign-in made from the player's menu lasts until **Sign Out**.
- **Browser** (`BrowserSeek.swift`, on `BrowserBridge`'s queue): `BrowserSeekScript` builds the AppleScript from a
  checked id and a whole number of seconds. It finds the tab whose address carries that id, sets the video's position
  with JavaScript, or reloads that same tab at `t=` when JavaScript from Apple Events is off, and opens a new tab only
  when there is none.

### Shortcuts

`ShortcutMap` and `KeyCombo` (`NabCore/Shortcuts.swift`) hold the four global shortcuts as Carbon key codes and
modifiers, with the defaults ⌃⌥N, ⌃⌥A, ⌃⌥S and ⌃⌥X when nothing is stored, and check a new combination before it is
saved. `ShortcutStore` keeps them under the `shortcuts` key, registers them with `RegisterEventHotKey` and re-registers
on every change. Every place that shows a shortcut draws it with `KeyCaps`.

### Library routing

`LibraryModel` (in `UI/Library.swift`) owns what the window shows. `Route` is `home`, `session([ids])`, `video(id)`,
`settings` or `welcome`. `go(_:)` pushes the current route on `backStack` and clears `forwardStack`; `goBack` and `goForward` (⌘[,
⌘]) walk them. `searchQuery` is the ⌘K palette's text, nil while it is closed. `focus` carries a transcript moment
(entry id and seconds, with a token so a repeated click scrolls again) that a page scrolls to and lights.

| Page | File |
| --- | --- |
| Home: the open session, earlier sessions by day, their chats; `FirstRun.swift` while the library is empty | `Home.swift` |
| Welcome: four steps on first launch, again from the menu bar icon's right-click menu | `Onboarding.swift` |
| Session: sources, thread, composer and the transcript drawer | `SessionPage.swift`, `Chat.swift`, `TranscriptDrawer.swift` |
| Video: cover, chapters, transcript with find and a timeline | `VideoPage.swift` |
| Settings: AI, capture, shortcuts and prompts as grouped rows in one column | `SettingsView.swift`, `SettingsAICard.swift`, `SettingsRows.swift` |
| ⌘K palette: videos, chats, transcript lines | `SearchPalette.swift` over `LibrarySearch` |

`Home` is grouped by `HomeLayout` and placed on a fixed column grid by `HomeGrid` (five columns for earlier days, four
for the open session), find in a transcript by `TranscriptSearch`, and the text under a chat title by
`ChatStamp`. Shared passage grouping lives in `TranscriptSupport.swift`.

### The ask window

`AskWindow.swift` holds `AskWindowController` and `AskView`. It opens on ⌃⌥S, the Ask AI buttons, `nab://summarize`,
`nab://chat` and `nab://ask`, and asks about the open session or the latest video (`AskScope` decides which and whether
the choice is offered). The shortcut and the buttons summarize right away; a link sets `holdsSummary`, so nothing is
sent until the user presses Summarize or Return (`nab://ask?q=` only pre-fills the field). Streaming and saving stay in
`Assistant`, so closing the window never stops an answer. The window is a
`FloatingPanel`, placed by `placeTopCenter(offset:)` on the screen under the mouse.

A non-activating panel never makes Nab the active app, so the browser keeps its tab, but the main menu's Edit shortcuts
do not reach the text field either. The controller installs a local `keyDown` monitor for the panel and routes keys
itself: Esc closes, ⇥ switches scope, ⌘O opens the chat in the library, ⌘C copies a selection or else the answer, and
⌘V, ⌘X, ⌘A and ⌘Z go to the field. A mouse click outside the panel (global and local monitors) closes it, except a
click in the mini player; following a timecode leaves it open.

### Motion

`Motion.swift` opens with a table of every kind of motion (windows, pages, content, lists, drawers, hover, press) and
the one token and transition each uses. Panels open and close on Core Animation springs with a preferred frame rate of 120 Hz. Library pages swap with
`AnyTransition.page`: the old page leaves at once and the new one fades in over 0.16 s, so two layouts never blend into
each other; a chat's intro and its thread swap the same way. Thumbnails and covers are kept in memory, so a page that
comes back draws them in its first frame. Answers write themselves in with
`RevealRenderer`, a `TextRenderer` that draws each glyph sharpening out of a blur behind a moving edge. `RevealClock`
moves that edge toward the text that has arrived, so a stream that comes in bursts reads as one motion. Selectable text
on macOS skips custom renderers, so an answer becomes selectable once it has been fully drawn.

Set `NAB_FRAME_PROBE=1` to log how many display refreshes each animation actually drew to
`~/Library/Logs/Nab/frames.log`. `NAB_PLAYER_PROBE=1` logs where the mini player is against where it was sent.
`NAB_DATA_DIR` moves the data folder, and `NAB_OPEN='nab://…'` handles a URL at launch (debug builds only).

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
the CLI. The library, the transcript views, the context pack, the chat and the CLI work with it unchanged.

## Tests

`Tests/NabTests` uses Swift Testing, one suite per area, and needs neither the network nor the user's library or
keychain:

- **YouTube:** link shapes, chapters, captions, caption track choice, covers and links to a moment.
- **Library and context pack:** passages, the registry, the pack's structure, text from a video that tries to close the
  pack's tags, timecodes, the store's files (including long chat ids and unreadable entries) and the `Gate`.
- **Interface logic:** home grouping, filters and grid placement, library search, find in a transcript, the ask scope, chat stamps,
  rack text and session grouping, all as plain values.
- **Conversations and settings:** citations, failed turns, prompt language, model names and choices, what is stored and
  how old defaults migrate.
- **AI client:** the prompts sent to each provider, server-sent events, server addresses, and the Anthropic and
  OpenAI-compatible streams end to end against a stubbed `URLSession`.
- **Command-line providers:** small shell commands that ignore their input, flood standard error, fail, print Markdown
  paragraphs, emit Claude Code's `stream-json`, or ignore SIGTERM.

The `Live` suite fetches a real video and asks the configured provider for a summary and a follow-up; it runs only
when `NAB_LIVE=1` is set.
