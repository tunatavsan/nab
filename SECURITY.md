# Security Policy

Nab stores what people watch and sends transcripts and questions to a model they chose, so bugs that could expose a
library, a chat or an API key are treated as security issues.

## Reporting a vulnerability

Please do not open a public issue. Report privately through GitHub instead: open the
[Security tab](https://github.com/tunatavsan/nab/security) of this repository and choose **Report a vulnerability**.

Examples of what to report:

- Library entries, chats or transcripts reaching a place the user did not choose, such as a provider they did not
  select or an unexpected file.
- A pin that makes Nab write outside the media folder, overwrite or delete a file it did not create, or fetch from a
  host other than `pinimg.com`.
- An API key written anywhere outside the keychain, or shown in the interface or a log.
- A `nab://` URL that makes Nab do more than this: add links; open the library, a video, the open session's chat,
  Settings, the search palette or the menu bar panel; copy the session's context; start a new session; or open the
  floating AI window. No `nab://` URL sends anything to the AI provider: `nab://summarize`, `nab://chat` and
  `nab://ask` wait for the user to press Summarize or Return, and `nab://ask?q=` only pre-fills the field. Or a
  `nab-cite://` URL that does more than show a moment of a video.
- Text from a video or a model that can make Nab run a command or open something without the user acting.

Please include the macOS version, the Nab commit or version, the provider involved and steps to reproduce. Do not
attach API keys or private chats. You can expect an initial response within a week. Fixes are made as soon as they are
verified, and reporters are credited unless they prefer otherwise.

## What Nab does with your data

Nab sends requests to YouTube to read a video, to Pinterest to read a pin and download its photos and clips, and to
the AI provider you configure when you summarize or ask a question. It has no account, no analytics and no server of
its own. Your library and chats are JSON files in `~/Library/Application Support/Nab`; API keys are kept in the macOS
keychain. Saved photos and clips are ordinary files in the media folder (`~/Downloads/Nab` unless you chose another).

The Pinterest requests are made without an account and without cookies. Nab never signs in to Pinterest and never
reads your browser's cookies. It asks `www.pinterest.com` for a pin's details (and its page when that fails),
`api.pinterest.com` to follow a `pin.it` share link, and downloads files only from `https` addresses on `pinimg.com`:
an address in a pin's data that points anywhere else is ignored. A refusal from Pinterest is reported and not worked
around. The context pack sent to an AI provider names a saved file but never its path, and the files themselves are
not sent.

File names come from a pin's title, so Nab removes path separators, colons and control characters, drops leading dots,
and limits the name to 100 characters. A file is written next to its final name as `.partial` and renamed when whole;
at launch, Nab removes only `.partial` files that carry its own name pattern. Removing an item from the library never
deletes a saved file.

The Claude Code and Codex providers run the command shown in Settings in your login shell, as you. Treat that field
like a line in your shell profile. To show whether they are set up, Nab runs `--version`, `claude auth status` and
`codex login status`, reads only the state and the sign-in method from the answer, and never shows or logs the account.
It never runs an install or sign-in command itself.

## The player and the browser

The mini player is a web view that loads YouTube's IFrame player for a video id Nab has checked
(`[A-Za-z0-9_-]{11}`) and moves it with numbers built in Swift; no text from a page, a transcript or a model reaches its
scripts. Its main frame and new windows may only go to YouTube and Google hosts; any other address opens in your
browser. Messages from the page are read as player state, never as commands. The player keeps
its cookies in the app's persistent web data store, so signing in to YouTube from the player's menu lasts; **Sign
Out** removes the Google and YouTube records from that store. Nab never sees the password: Google's own page takes it.

When videos play in the browser, Nab asks the browser over AppleScript for its tabs' addresses and looks for the one
whose address carries the video's id. In that tab only, it sets the video's position with a line of JavaScript that
contains nothing but a number, or, when the browser does not allow JavaScript from Apple Events, reloads that tab at
the moment. It does not read page contents, and it does not touch other tabs.

## Supported versions

Nab is in early development. Security fixes are made on the `main` branch.
