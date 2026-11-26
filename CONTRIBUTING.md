# Contributing to Wax

Thank you for your interest in improving Wax. This project is a personal
macOS client for Spotify and Apple Music; contributions are welcome within the scope below.

## License

By contributing, you agree that your contributions will be licensed under the
same terms as the repository. See [LICENSE](LICENSE) for use restrictions
(personal / non-commercial vs commercial licensing).

## Before you start

1. Read [docs/getting-started.md](docs/getting-started.md) for Spotify setup.
2. Read [docs/architecture.md](docs/architecture.md) for module layout.
3. Check open work in the [issue tracker](https://github.com/isaaclins/wax/issues).

## Build and test

From the repository root:

```sh
make build          # Debug build
make test           # unit tests (unsigned: make test UNSIGNED=1)
make coverage       # tests + coverage report
```

See [docs/building-and-testing.md](docs/building-and-testing.md) for Xcode,
Release bundles, and coverage gates.

## Code style

Run formatting locally when you touch Swift files:

```sh
make format         # rewrites the files in place
make lint           # what CI's format check runs; it must pass before a PR merges
```

Both use the swift-format that ships with Xcode (or a standalone install) and the
repo's `.swift-format` rules. CI pins the formatter version, so if your local
result ever differs from CI's, CI is the one that counts.

Avoid drive-by reformatting of unrelated files in the same change.

## Speed

Every interaction responds within 50 ms, and a PR that touches one shows its measured time (`scripts/latency-test.sh`, see [docs/latency.md](docs/latency.md)).

## Errors

Errors are never dropped silently: a `catch` logs with `SpotiglassLog` or rethrows, and a `try?` explains itself on the same line or the line above with `// try?: <why losing the error is fine>`.
A failure the user sees goes through `ErrorReporting.report`, which logs it once and returns the `DisplayError` to show as a page, a banner or a toast ([architecture](docs/architecture.md#errors)); views and view models never hold an error as text.
`scripts/audit-error-handling.sh` (run by `make test` and CI) checks this plus print logging, blocking waits, `localizedDescription` on screen and ignored Core Audio statuses; when you fix a site it lists, `--update-baseline` removes it from `scripts/error-handling-baseline.json`.

## Adding a new test file

The Xcode project uses explicit file references. After adding
`SpotiglassTests/YourTests.swift`:

```sh
python3 scripts/register-test-files.py YourTests.swift
```

Running it again for the same file changes nothing, and the object IDs it
writes are derived from the file's path, so two branches adding different
files do not collide. Main-target files go through
`scripts/register-source-files.py` the same way.
`./scripts/audit-orphaned-sources.sh` then confirms every Swift file is in its
target's Sources phase exactly once, and `make test` confirms it compiles.

## Parallel work / merge conflicts

If other agents or branches are active, avoid editing these areas unless you
own that slice:

- `Spotiglass/CommandPalette/`
- `Spotiglass/Views/`
- `Spotiglass/Playback/Session/`
- `Spotiglass/Playback/QueueViewModel.swift`
- `Spotiglass/Auth/`
- `Spotiglass/Browsing/`
- `Spotiglass/Services/`
- `SpotiglassTests/` (when a test rework is in flight)

Coordinate before editing `Spotiglass.xcodeproj/project.pbxproj`.

## Pull requests

1. Keep changes focused; one concern per PR when possible.
2. Update the narrowest doc in `docs/` if behavior or setup changes (start
   from [docs/README.md](docs/README.md), the doc index).
3. Do not commit secrets, `.env` files, or Keychain exports.
4. Confirm `make build` (and `make test` when you change testable logic).
5. Fill in the [pull request template](.github/pull_request_template.md): the
   issue it fixes, what changed for the user, how you tested it, and before and
   after screenshots in light and dark mode for anything visible.
6. Keep VoiceOver labels, keyboard access and Reduce Motion working when you
   touch the UI. [ACCESSIBILITY.md](ACCESSIBILITY.md) says what the app
   supports today.

## Accessibility

See [ACCESSIBILITY.md](ACCESSIBILITY.md) for what Wax supports, what doesn't
work yet, and how to report a barrier.

## Security

Wax holds a Spotify sign-in, drives Music.app, ships a root helper and a Core
Audio driver, and installs its own updates, so a PR answers these questions
when they apply (the [pull request template](.github/pull_request_template.md)
has the same list; tick it or write "n/a"):

- **Privileged code** (`SpotiglassEQPrivilegedHelper/`, `SpotiglassEQDriver/`,
  the install path): who can call it and how that is checked; what it writes as
  root, with which owner and mode.
- **Files**: created only where this user alone can write, without following
  symlinks and with the narrowest mode; a file the app can't read is never
  overwritten.
- **Data from outside** (Spotify, Apple Music, LRCLIB, the update feed, the
  sign-in callback): numbers are parsed with bounds, never with trapping
  conversions; a URL that gets a token is checked against the expected host;
  text is escaped before it goes into the log or on screen.
- **Secrets and privacy**: no tokens, codes, search text, library contents or
  device IDs in the log; nothing new is written outside the Keychain where
  another account or app could read it.
- **Dependencies**: an update to Sparkle or another package names that
  version's security advisories.
- **Tests**: a security fix comes with a test that replays the attack and fails
  on the old code.

Secret scanning, push protection, Dependabot alerts and pinned actions run on
the repository itself ([#385](https://github.com/isaaclins/wax/issues/385)).

Found a vulnerability? Don't open an issue; see [SECURITY.md](SECURITY.md).
