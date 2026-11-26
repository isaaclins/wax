<!--
Thanks for the pull request. Fill in what applies and delete what doesn't,
except the Security section, which every PR keeps.
If nothing on screen changes, delete the "How it looks" section.
-->

## How it looks

<!-- Anything visible: before and after, in light and dark mode.
Use screenshot mode (docs/screenshots.md) so no real library shows up. -->

| | Before | After |
|---|---|---|
| Light | | |
| Dark | | |

## What it fixes

Fixes #

## What changed for the user

<!-- One or two sentences, in the words someone using Wax would use. -->

## How I tested it

- [ ] `make build` and `make test` pass
- [ ] A test replays the real failure (not only that the code runs)
- [ ] Tried in the real app with: Spotify / Apple Music / both / not needed (say why)
- [ ] VoiceOver, keyboard and Reduce Motion still work where this changes the UI ([ACCESSIBILITY.md](https://github.com/isaaclins/wax/blob/main/ACCESSIBILITY.md))

<!-- What you did in the app and what you saw. -->

## Security

<!-- Keep this section in every PR: tick what applies and write n/a after the
rest. CONTRIBUTING.md#security explains each one.
The repository's own checks (secret scanning, push protection, Dependabot,
pinned actions) are in #385. -->

- [ ] Privileged code (`SpotiglassEQPrivilegedHelper/`, `SpotiglassEQDriver/`, the install path): who can call it, how that is checked, and what it writes as root, with which owner and mode
- [ ] Files: created only where this user alone can write, no symlinks followed, narrowest mode; a file the app can't read is never overwritten
- [ ] Data from outside (Spotify, Apple Music, LRCLIB, the update feed, the sign-in callback): numbers parsed with bounds, never trapping conversions; URLs that get a token checked against the expected host; text escaped before the log or the screen
- [ ] Secrets and privacy: no tokens, codes, search text, library contents or device IDs in the log; nothing new outside the Keychain that another account or app could read
- [ ] Dependencies: an update to Sparkle or another package names that version's security advisories (Dependabot alerts, #385)
- [ ] Tests: a security fix comes with a test that replays the attack and fails on the old code
