# Contributing to Nab

Thank you for helping. Nab reads what people watch and sends it to a model they chose, so every change is held to two
standards: it must work the way the user expects, and it must never send their library or their chats anywhere they
did not choose.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security and privacy problems go through the private process in [SECURITY.md](SECURITY.md), not public issues.

## Setting up

You need macOS 26 or later and Xcode 26 or later (Swift 6.2). The project is a Swift package with no third-party code,
so nothing is downloaded during a build.

```sh
git clone https://github.com/tunatavsan/nab.git
cd nab
swift build
swift test
scripts/build.sh --run   # package a release build into dist/Nab.app and open it
```

## Making a change

1. Create a branch from `main`.
2. Keep the change focused. Refactors and behavior changes belong in separate pull requests.
3. Add or update tests. New behavior in `NabCore`, `NabYouTube` or `NabAI` needs a test that fails without your change.
   Tests use Swift Testing and must not depend on the network, the user's library or their keychain; anything live
   goes behind an environment variable, like `NAB_LIVE`.
4. Run the same check as CI:

   ```sh
   scripts/check.sh
   ```

   It checks formatting (`scripts/format.sh` fixes it), builds with warnings treated as errors and runs every
   test.
5. Open a pull request and describe what changed, why, and how you tested it. For anything visible, describe what you
   checked in the running app; passing tests do not prove that the shortcut, the browser bridge or a provider works.

## Guidelines

- **Data goes only where the user sends it.** Nab talks to the source of a link and to the provider the user picked.
  Do not add analytics, crash reporters, update pings or any other connection.
- **Secrets stay in the keychain.** API keys are stored with `Keychain` and never written to defaults, files or logs.
- **Say what happened.** When a fetch fails, a transcript is missing or a provider refuses, the interface says so in
  plain words and keeps what it has. Do not swallow an error the user would want to know about.
- **One source, one provider.** A new site is a `SourceProvider`, which also supplies its cover images and links to a
  moment; a new model service is a `ProviderKind`. Neither should need changes in the UI. See
  [ARCHITECTURE.md](ARCHITECTURE.md).
- **Design tokens.** Colors, type, radii and motion come from `Sources/NabApp/Design`; a view that needs a new one adds
  a token instead of a literal. A one-off padding or frame size may stay with its view. Prefer native controls where
  they fit.
- **Motion that holds up.** Animations must stay smooth at 120 Hz. Measure with `NAB_FRAME_PROBE=1` when you change
  one, and respect Reduce Motion.
- **Concurrency.** The package uses Swift 6 strict concurrency. Keep network, disk and process work off the main actor.
- **Write like an engineer.** Comments explain why, not what the next line does. Interface text is short, specific and
  free of filler. AI-assisted changes are welcome, but you own every line: read it, test it and cut what does not
  earn its place.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `perf:`, `refactor:`, `test:`,
`docs:`, `build:`, `ci:` or `chore:`, optionally with a scope, followed by a short summary in the imperative, for
example `fix(youtube): prefer the human track in the spoken language`. Explain the why in the body.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
