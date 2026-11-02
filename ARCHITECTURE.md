# Architecture

Nab is a Swift package of seven targets, built with Swift 6 strict concurrency and no third-party code. The app is an
agent (`LSUIElement`): it lives in the menu bar and shows a Dock icon only while its library window is open.

| Target | Depends on | Contents |
| --- | --- | --- |
| `NabCore` | Foundation, CryptoKit, AVFoundation, ImageIO | `Capture` with its transcript and its `Media` (photos and clips), `SourceProvider` and `SourceRegistry`, `ContextPack`, `CopyPayload`, `Conversation`, `Citation`, `LibraryStore`, `Gate`, the media pipeline (`MediaFolder`, `MediaFileName`, `MediaDownloader`, `MediaProbe`), and the pure logic behind the interface: `HomeLayout`, `HomeGrid`, `LibrarySearch`, `TranscriptSearch`, `AskScope`, `ChatStamp`, `RackText` and `SessionGrouping`. |
| `NabYouTube` | `NabCore` | `YouTubeSource`: link parsing, the player request, caption tracks, captions and chapters. |
| `NabPinterest` | `NabCore` | `PinterestSource`: link parsing, share links, the pin request and its page fallback, and the choice of the best photo or clip. |
| `NabSources` | `NabCore`, `NabYouTube`, `NabPinterest` | `SourceRegistry.standard`: the one list of sources. |
| `NabAI` | `NabCore` | `AISettings`, `ProviderKind`, `Keychain` and `AIClient`, which streams one assistant turn from any provider; `ModelNames`, `ModelChoices` and `ProviderInfo` (provider status and probe) feed the settings page. |
| `NabApp` | all of the above | The app: `Capture/` (shortcut, browser bridge, `CaptureCenter`, `Assistant`), `UI/` (menu panel, rack, library and its pages, ask window, search palette, chat, settings) and `Design/` (tokens, motion, fonts, the reveal and the frame probe). |
| `NabCLI` | `NabCore`, `NabSources` | The `nab` command. |

`NabCore` has no UI and makes no requests to any site; its only network code is the downloader that streams a file to
disk. Everything else in it can be tested with plain values.

## Capturing an item

1. ⌃⌥N is a Carbon hot key (`HotKey`), which needs no permission. `nab://front` does the same. Before reading the
   tab, Nab notes the pasteboard's change count; when the transcript lands and nothing else was copied meanwhile, the
   video's context pack goes on the clipboard.
2. `BrowserBridge` asks the frontmost browser for its active tab's URL and title with one Apple Event, on a serial
   queue with a four second timeout. Chromium browsers and Safari use different dictionaries; both are covered.
3. `SourceRegistry` finds the `SourceProvider` that recognizes the link and gives it a stable entry id
   (`youtube:<video id>`, `pinterest:<pin id>`). A share link such as `pin.it/…` names its item only after one
   request, so `CaptureCenter` follows it first (`SourceProvider.expand`) and then adds the item's own link, which
   keeps one pin from becoming two entries. A link already in the library is moved into the open session instead of
   fetched again.
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
6. A pin is read by `PinterestSource` (see Reading a pin). Its photos and clips are then saved to disk (see Saving
   photos and clips) while the entry shows **Saving…**.
7. The finished `Capture` is saved by `LibraryStore` as one JSON file per entry in
   `~/Library/Application Support/Nab/Library`. Each entry records its `sessionID`; `SessionGrouping` rebuilds the
   sets from it, and clusters entries saved before sessions existed by a pause of more than five minutes.

A session ends when it is copied (⌃⌥A) or when a question about the whole session is sent, the next nab then starting a new one, on ⌃⌥X, or after five
minutes without a nab. Its id and last activity are kept in `UserDefaults`, so a relaunch inside those five minutes
resumes it.

## Reading a pin

`PinterestSource` needs no account and sends no cookie. `PinterestURL` recognizes links without a request: `pinterest.<tld>`
and regional hosts, `/pin/<id>` and `/pin/<slug>--<id>`, `pin.it/<code>` as a share link, and a direct `i.pinimg.com`
photo. At most eight requests for a pin's details run at once, and its files download through their own queue of six;
a 429 or 503 is tried up to three times with a growing wait.

1. A `pin.it` link is followed with one request to `api.pinterest.com/url_shortener/<code>/redirect/`. The redirect is
   read, not followed, and the pin id is taken from its `Location`.
2. The pin comes from `www.pinterest.com/resource/PinResource/get/` with the `unauth_react_main_pin` field set. When
   that answers 403 or nothing, the pin page's JSON-LD and `og:image` are read instead. `PinterestPin` parses either.
   The page's embedded state is not used.
3. What the pin is made of is read in this order: an idea pin's pages, a carousel's slots, a clip, a photo. Each page of
   an idea pin becomes one `Media`, in order; music and sticker blocks are skipped and text blocks join the
   description, so a model can use them.
4. A photo is `images.orig` as given: the extension is never guessed. If the original is refused (a 4xx other than
   429), `save` tries the same picture at 1200 and then 736 pixels wide, and the file is named for what arrived.
5. A clip is chosen among its plain MP4 files by asking each for its size with a HEAD request and taking the largest.
   A copy whose HEAD is refused (a 4xx other than 429) is never chosen, and if the chosen one is refused when it is
   saved, `save` tries the others, best first. The others are remembered for the last 256 clips; when there are none
   left (or none after a restart), `save` reads the pin once more for fresh copies, and never twice. A clip whose
   every copy is refused drops on its own: the rest of the pin is saved and a note says how many clips are missing.
   The width and height the API lists can be wrong, so `MediaProbe` reads the real ones from the saved file. A clip
   offered only as a stream is reported as one Nab can't save yet.
6. Every address from a pin is checked: `https` and `pinimg.com` only. Anything else is ignored.

If Pinterest changes these answers, `PinterestSource` is the one place to update, and the error says so.

## Saving photos and clips

An entry with a `Capture` whose `Media` has no `savedPath` is in the `.saving` phase. The phase is worked out from
what is stored (`Entry.phase`), so no flag can disagree with the files, and an entry still saving when the app quit
picks up where it stopped.

1. `MediaFolder.resolve` gives the folder: the `media.folder` setting, else `$NAB_DATA_DIR/Media` when that variable
   is set, else `~/Downloads/Nab`. `MediaFileName` names each file `Title (Source id)[ page].ext`, at most 100
   characters.
2. `SourceProvider.store` saves one `Media`. A file already under that name, at the size it was saved at (any size
   above zero when none was recorded), is kept and not downloaded again. Anything else under the name, such as the
   user's edit or a file cut short, is left alone: `MediaProbe.freeName` picks `name (2).ext` (brackets, because
   `name 2.ext` is a second page).
   Otherwise `save(_:of:to:progress:)` writes it. The default streams `media.url` through `MediaDownloader`; a source
   overrides it to resolve an address that has expired or to fall back to a smaller copy, as `PinterestSource` does.
3. `MediaDownloader` has its own `Gate` of six and its own `URLSession`, so a long clip never holds up the details of
   the next link. It downloads to a temporary file, moves it next to the target as `<name>.partial`, then renames it in
   one step, so a name in the folder is always a whole file. The rename (`renamex_np` with `RENAME_EXCL`) refuses a
   name that is taken, so Nab never replaces a file it did not just write. A 429 or 503 is tried up to three times, and the wait
   between tries holds no slot. Cancelling the task, even while it waits for a slot, stops it and leaves no `.partial`. At launch, `MediaFolder.leftovers` finds `.partial` files with a
   source's name pattern, and only those, and they are removed.
4. The pages of a pin save in parallel. Each finished file is written to the entry at once, so progress and a
   half-finished pin survive a quit.
5. `MediaProbe` reads the saved file: size, real width and height, a clip's length, and an image's real type. A fallback
   copy that is a JPEG is renamed to match (`.jpg`), to a free name.
6. When the last file lands, the entry is ready and, if **Copy each item when it lands** is on, copied. Every copy
   first checks the saved files: one moved, deleted or emptied puts nothing on the clipboard and offers **Save
   again**, which fetches only what is missing. A file the user edited since is theirs: Copy, a drag and the gallery
   use it as it is, and nabbing again does not fetch it. Removing an
   entry cancels its work and deletes its `.partial` file, never a saved file.

A saved file is not checked while a page is drawn. It is checked when it is used (copy, drag, opening a page), and a
file that is gone is saved again.

## What is copied and dragged

`CopyPayload` (in `NabCore`, pure) decides what a copy is. One item made of photos and clips, all saved, is `files`;
anything else is its context pack. A session is `files` only when every item is made of photos and clips; otherwise it
is one context pack. The AppKit writer in `Capture/Clipboard.swift` puts each file on the pasteboard as its own item
with a file URL, and a lone photo also as image data. A drag uses the same payload.

## The context pack

`ContextPack.render` turns any number of captures into one block of text. XML tags mark where each source starts and
ends, and Markdown carries the structure inside: title, facts, chapters, description and the transcript.
A photo or clip item has no transcript. Its pack lists its photos and clips (kind, size and file name) and its
description. The pack goes to an AI service, so it holds a saved file's name and never its path. A video's pack is
unchanged. `Transcript.paragraphs` groups caption segments into passages that start at a chapter, or once 45 seconds have passed
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
`nab://chat` and `nab://ask`, and asks about the open session, the latest item or, from ⌃⌥S, the front tab's item
(`AskScope` decides which and whether the choice is offered). Nothing that opens it sends anything: `holdsSummary` is set, so
nothing goes until the user asks or presses Summarize (⌘↩ or the button; `nab://ask?q=` only pre-fills the field). The
**Summarize** buttons in the library are the exception: they send at once, and are named for it.

⌃⌥S reads the front tab like ⌃⌥N does (`CaptureCenter.nabFrontTabForAsk`). A supported item is added to the session
and the library, with no copy, and the window opens on that one item with the field focused. A question typed while it
loads is kept and sent when it arrives. With no supported tab, or no permission, the window opens on the session or
the latest item. A question about one item does not end the session; one about the whole session does. Streaming and
saving stay in `Assistant`, so closing the window never stops an answer. The window is a `FloatingPanel`, placed by `placeTopCenter(offset:)` on the screen under the mouse.

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

A source is one type that conforms to `SourceProvider`, in its own target:

```swift
public protocol SourceProvider: Sendable {
    var kind: SourceKind { get }
    var name: String { get }
    /// Returns the source's stable id for `url`, or nil when this provider does not handle it. No network.
    func identify(_ url: URL) -> String?
    /// A share link that names its item only after one request. No network.
    func isShortLink(_ url: URL) -> Bool
    /// Follows a share link to the item's own link, with one request.
    func expand(_ url: URL) async throws -> URL
    func fetch(_ url: URL) async throws -> Capture
    /// Cover images for an item, largest first, known from its id alone so they show before the fetch ends.
    func covers(forID id: String) -> [URL]
    /// A link that opens the item at a moment.
    func link(to capture: Capture, at seconds: TimeInterval) -> URL
    /// Writes one photo or clip of `capture` to `file`.
    func save(_ media: Media, of capture: Capture, to file: URL, progress: …) async throws
}
```

Only `kind`, `identify` and `fetch` are required. The rest have defaults: the name is the kind capitalized, no link is
a share link, `expand` returns its link, there are no covers until the fetch finds one, links open the item itself,
and `save` streams `media.url` to disk through `MediaDownloader`.

To add one:

1. Add a `SourceKind`, and a target with the provider. `fetch` returns a `Capture`: a title, an author, a description
   in `summary` and either a `transcript` (an item read as text) or `media` (an item kept as photos and clips). The
   library, the pages, the context pack, the chat, copy and drag, and the CLI work from those fields and never ask
   which source made them.
2. Add the target to `Package.swift`, and one line to `SourceRegistry.standard` in `Sources/NabSources/Standard.swift`:

   ```swift
   public static let standard = SourceRegistry([
       YouTubeSource(),
       PinterestSource(),
   ])
   ```

   The app and the CLI both read this list, so there is no second registration.
3. Override `save` only if the default stream will not do, for instance to fall back to a smaller copy on a 403.
   `MediaFolder`, `MediaFileName`, `.partial` files, progress, the gate, retries and `MediaProbe` come with the default.

Names the user sees (the file name, "Open on …", the unsupported-link message) come from `name`. Cancellation, retries
and the `.saving` phase belong to `CaptureCenter` and need nothing from the provider.

## Tests

`Tests/NabTests` uses Swift Testing, one suite per area, and needs neither the network nor the user's library or
keychain:

- **YouTube:** link shapes, chapters, captions, caption track choice, covers and links to a moment.
- **Pinterest:** link shapes (regions, slugs, share links, direct photos), pin JSON as the API and the page give it,
  idea pins, carousels, the choice of clip, and rejected addresses, all from made-up fixtures with the real structure.
- **Media:** the folder choice, file names (cleaning, length, page numbers), the downloader against a stubbed
  `URLSession` (partial files, retries, cancelling), the saved file's facts, and what a copy or a drag carries.
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
