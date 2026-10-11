# Security Policy

Nab stores what people watch and sends transcripts and questions to a model they chose, so bugs that could expose a
library, a chat or an API key are treated as security issues.

## Reporting a vulnerability

Please do not open a public issue. Report privately through GitHub instead: open the
[Security tab](https://github.com/tunatavsan/nab/security) of this repository and choose **Report a vulnerability**.

Examples of what to report:

- Library entries, chats or transcripts reaching a place the user did not choose, such as a provider they did not
  select or an unexpected file.
- An API key written anywhere outside the keychain, or shown in the interface or a log.
- A `nab://` URL that makes Nab do more than add links, open the library, or open a chat and summarize the links it
  was given, or a `nab-cite://` URL that does more than show a moment of a video in the open chat.
- Text from a video or a model that can make Nab run a command or open something without the user acting.

Please include the macOS version, the Nab commit or version, the provider involved and steps to reproduce. Do not
attach API keys or private chats. You can expect an initial response within a week. Fixes are made as soon as they are
verified, and reporters are credited unless they prefer otherwise.

## What Nab does with your data

Nab sends requests to YouTube to read a video and to the AI provider you configure when you summarize or ask a
question. It has no account, no analytics and no server of its own. Your library and chats are JSON files in
`~/Library/Application Support/Nab`; API keys are kept in the macOS keychain.

The Claude Code and Codex providers run the command shown in Settings in your login shell, as you. Treat that field
like a line in your shell profile.

## Supported versions

Nab is in early development. Security fixes are made on the `main` branch.
