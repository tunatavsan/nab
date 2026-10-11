<p align="center">
  <img src="docs/images/icon.png" width="160" height="160" alt="Nab app icon">
</p>

<h1 align="center">Nab</h1>

<p align="center">
  <strong>Turn the video in your browser into something an AI can read.</strong><br>
  One shortcut grabs the transcript. Copy it as clean context, or ask questions and get answers that cite the moment.
</p>

<p align="center">
  <a href="https://github.com/tunatavsan/nab/actions/workflows/ci.yml"><img src="https://github.com/tunatavsan/nab/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black.svg?logo=apple" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138.svg?logo=swift&logoColor=white" alt="Swift 6.2">
</p>

<p align="center">
  <img src="docs/images/chat.png" alt="The Nab library: a TED talk with its transcript on the left and a chat about it on the right" width="860">
</p>

Nab lives in the menu bar. Press **⌃⌥N** while a YouTube video is open in your browser and Nab reads the tab's
address, fetches the video's details, chapters and transcript, and adds it to the tray. Collect one video or twenty,
then copy them as a single context pack, or open the library and talk to a model about them. Nab works with the model
you already use: Claude Code, Codex, the Anthropic or OpenAI API, OpenRouter, or a local model through Ollama or
LM Studio.

## Why Nab

- **No copy and paste.** The shortcut works from the browser you are in. Nab never opens a page, so there is nothing to
  scroll, expand or clean up.
- **Context, not a wall of text.** Every source is tagged, chapters are kept, and the transcript is grouped into
  timecoded passages, so a model can quote a moment and you can check it.
- **Answers you can verify.** In the chat, every claim carries its timecode. In a chat about one video, a click scrolls
  the transcript to the passage it rests on; ⌘-click, or any click in a chat about several videos, opens the video at
  that second.
- **Your model, your rules.** Pick the provider, the model and the language, and edit the system prompt and the
  summary request in Settings. API keys are kept in the macOS keychain.
- **Many at once.** Videos are fetched in parallel, and a request that stalls is retried on a fresh connection, so a
  batch of twenty takes seconds, not minutes.

## Features

| | |
| --- | --- |
| **Capture** | ⌃⌥N takes the front tab of Safari, Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Comet or Helium. Paste any number of links at once, or drive Nab from Shortcuts, Raycast and scripts through `nab://` URLs. |
| **Transcript** | Details, chapters and captions in the video's spoken language, preferring a human-made track over automatic captions. |
| **Context pack** | One block of text for any number of videos: tagged sources, an index, chapters, the description and the timecoded transcript. Copy it, or export it as Markdown. |
| **Chat** | Summarize a video or a whole tray, then keep asking. Answers stream in, cite timecodes and are saved with the video. |
| **Library** | Everything you collected, with cover images, a reader for each transcript and the chat beside it. |
| **Command line** | `nab <links>` prints the same context pack, for scripts and agents. |

## Getting started

Nab is an early preview. Signed and notarized downloads are not available yet, so for now you build it from source.

**Requirements:** macOS 26 or later and Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/tunatavsan/nab.git
cd nab
scripts/build.sh --run
```

`scripts/build.sh` builds a release copy into `dist/Nab.app`, signs it and, with `--run`, opens it. It signs with the
first Apple Development or Developer ID identity in your keychain, or ad hoc when there is none; set
`NAB_SIGN_IDENTITY` to choose one. macOS ties the browser permission to the signature, so an ad hoc build may ask for
it again after every rebuild. `scripts/build.sh --install` replaces `/Applications/Nab.app` with the new build and
opens it.

### Choosing a model

Open **Settings** (⌘,) in the library window and pick a provider:

| Provider | What you need |
| --- | --- |
| Claude Code | The `claude` command, signed in. Nab runs it in your login shell from an empty folder. |
| Codex CLI | The `codex` command, signed in. |
| Anthropic API, OpenAI API, OpenRouter | An API key, stored in your keychain. |
| Ollama, LM Studio | The local server running with a model loaded. Nothing leaves your Mac. |
| OpenAI-compatible server | Its address, and a key if it needs one. |

**Test** sends a one-word question so you know the setup works before you ask a real one.

### Permissions

| Permission | Needed for |
| --- | --- |
| Automation (your browser) | Reading the address and title of the front tab when you press ⌃⌥N. macOS asks the first time. |

You can review it in **System Settings › Privacy & Security › Automation**.

### What leaves your Mac

Nab sends requests to YouTube to read a video, and to the AI provider you choose when you summarize or ask a question.
The provider receives the video's details and transcript and your chat with it. Nab has no account, no analytics and
no server of its own. Your library and chats are stored as JSON files in `~/Library/Application Support/Nab`.

## Command line and URLs

The app bundle contains the `nab` command:

```sh
Nab.app/Contents/Resources/nab "https://youtu.be/…" "https://www.youtube.com/watch?v=…"   # context pack
Nab.app/Contents/Resources/nab --json "https://youtu.be/…"                                 # structured data
```

| URL | Does |
| --- | --- |
| `nab://front` | What ⌃⌥N does. |
| `nab://add?url=…` | Adds one or more links (repeat `url=`). |
| `nab://chat?url=…` | Adds the links, opens the chat and summarizes them. |
| `nab://library` | Opens the library. |

## Development

Nab is a Swift package with no Xcode project and no third-party code, so a build never downloads anything.

```sh
swift build          # build everything
swift test           # run the tests
scripts/format.sh    # format the sources with swift-format
scripts/check.sh     # what CI runs: formatting, a build that treats warnings as errors, then every test
```

| Target | Purpose |
| --- | --- |
| `NabCore` | The data model, the source registry, the context pack, conversations and the library store. No UI, no network. |
| `NabYouTube` | Reads a YouTube video: details, caption tracks, captions and chapters. |
| `NabAI` | Providers, settings and the keychain: one streaming client for HTTP APIs and command-line tools. |
| `NabApp` | The menu bar app: shortcut, browser bridge, tray, library, reader, chat, settings and the design system. |
| `NabCLI` | The `nab` command. |

[ARCHITECTURE.md](ARCHITECTURE.md) explains how a capture and a chat flow through these parts, and how to add a new
source.

Nab reads YouTube through the same player interface the YouTube app uses. It is not a public API and it can change;
when it does, `YouTubeSource` is the one place to update. Nab is not affiliated with YouTube or Google.

## Roadmap

- [ ] Signed, notarized releases and a Homebrew cask
- [ ] An MCP server, so agents can search and read your library
- [ ] More sources: podcasts, X and Instagram videos
- [ ] PDF reports of summaries
- [ ] A Turkish interface

Ideas and bug reports are welcome in [Issues](https://github.com/tunatavsan/nab/issues).

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and report
security or privacy problems privately as described in [SECURITY.md](SECURITY.md).

## License

Nab is released under the [MIT License](LICENSE). Third-party components are listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
