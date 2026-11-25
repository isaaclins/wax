# Latency

Every interaction in Wax shows its result within **50 ms** (#656): every click, key, scroll,
menu, playback control, search keystroke and page change. When the real result needs the network
or Apple Music, the app shows at once that it heard the input (the button changes, the page opens
with a loading state), and that first reaction is what counts.

A PR that touches an interaction runs `scripts/latency-test.sh` on a Mac and puts the times before
and after in its description.

## How it's measured

```sh
scripts/latency-test.sh                                # every interaction, Release build
scripts/latency-test.sh --only palette.open,list.scroll # just these
```

The script builds the Release app and starts it in [screenshot mode](screenshots.md) on the sample
library, with a 1000-song playlist added for scrolling. No account and no sound are involved. The app
then runs its own probe
([`InteractionLatencyProbe`](../Spotiglass/Infrastructure/InteractionLatencyProbe.swift)): it
presses each shortcut and clicks each control 8 times, posting real key, mouse and scroll events to
its own event queue, so they go through the same key monitors, menu shortcuts and hit testing as a
press on the keyboard. The window server step before that is left out.

A try ends at the first frame Core Animation commits after the state the screen draws from has
changed (the player says paused, the palette is open, the list has moved). One display refresh
(16.7 ms at 60 Hz) is added for that frame to reach the screen. A main thread that is busy after
the input delays that frame, so it counts in full.

The time checked against 50 ms drops the single slowest try, since a busy machine now and then
stalls for a frame; a try that never showed within 3 s counts as the slowest. The report lands in
`build/latency/report.json`, with what the app showed for every try that went wrong. Run it on a
quiet Mac: with builds or tests running next to it, times rise.

Interactions that are over 50 ms on a Mac today are listed under `known` in
[`scripts/latency-baseline.json`](../scripts/latency-baseline.json), with the issue that fixes
each one and its time when it was listed. They're reported but don't fail the run, unless one gets
more than twice as slow as that time or stops showing. Anything else over 50 ms fails it. When a
fix lands, its entry goes.

## In CI

CI runs `scripts/latency-test.sh --ci` on every pull request (job "Interaction latency (Release)").
GitHub's macOS runners are 3-4 times slower than a Mac: play/pause takes about 80 ms there and ⌘K
about 290 ms, so the 50 ms line can't be checked on them. Instead every interaction has its median
on that runner under `ci` in the baseline file, and the job fails when one gets more than twice as
slow, stops showing, or is new and has no time there yet. That catches a change like #645 (play/pause
going from 50 to 610 ms). Whether something is within 50 ms is what the run on a Mac says, and a PR
that touches an interaction puts that run's times in its description.

When a change makes an interaction faster, set its `ci` time from the job's uploaded report, so it
can't drift back.

## Every interaction

Measured on 2026-11-25, Release build of 0.8.64, Mac mini M4, 60 Hz. Median and checked time
in ms. These are the "before": the probe changes no behaviour. Each fix adds its "after" here.

| Interaction | What you do | Median | Checked | Issue |
|---|---|---|---|---|
| `playback.toggle.key` | Space pauses or resumes | 40 | 40 | #678 |
| `playback.toggle.click` | Click the play/pause button | 37 | 41 | #678 |
| `playback.next` | ⇧⌘→ skips to the next song | never | never | #687 |
| `playback.previous` | ⇧⌘← goes back a song | never | never | #687 |
| `playback.seek` | ⌘→ jumps ahead in the song | never | never | #677 |
| `playback.shuffle` | ⌥⌘S turns shuffle on or off | never | never | #677 |
| `playback.repeat` | ⌥⌘R changes repeat | never | never | #677 |
| `palette.open` | ⌘K opens the command palette | 79 | 88 | #671 |
| `palette.type` | Typing a letter in the palette | 71* | never | #671 |
| `palette.close` | Esc closes the palette | 72 | 78 | #671 |
| `sidebar.toggle` | ⌘S hides or shows the sidebar | 81 | 83 | #672 |
| `queue.toggle` | ⌥⌘Q opens or closes the queue | 72 | 77 | #673 |
| `lyrics.toggle` | ⌥⌘L opens or closes the lyrics | 114 | 123 | #674 |
| `page.search` | ⌘F opens Search | 86 | 89 | #675 |
| `page.back` | ⌘[ goes back a page | never | never | #677 |
| `page.sidebarClick` | Click a playlist in the sidebar | 60 | 66 | #675 |
| `list.scroll` | Scrolling a 1000-song playlist | 30 | 37 | |
| `settings.open` | ⌘, opens Settings | 99 | 113 | #676 |

\* Run on its own; after the palette has been opened and closed 8 times, the letters never reach
the field (#671).
"never" means nothing changed on screen within 3 s in any try. Next and previous count once the
player bar names another song; screenshot mode's player can't change its song for a skip sent
through the Web API, so there it never does (#687).
Play/pause is within 50 ms on a quiet Mac, but its slower tries reach 50-59 ms on a busy one, so
it stays listed until #678 gives it room.

## What isn't measured yet

- **The sound.** Pause, resume and skipping must change what you hear within 50 ms, with the
  songs around the current one loaded ahead. The sample library plays nothing, so the probe only
  sees the screen. Apple Music's press-to-sound times are #679.
- **Apple Music's screens.** The probe runs on screenshot mode's Spotify stand-in, because CI has
  no Apple Music account. The views are the same for both services; the data behind them isn't.
- **Some interactions on CI's runner.** There, clicking a sidebar playlist never shows and ⌘F
  misses about 3 tries in 8, while both work on a Mac, so CI can't yet tell when the first gets slower
  (#688).
- Drag and drop, context menus, the queue's own buttons, Settings changes, the service switcher,
  the scrubber and volume aren't in the list yet (#680). Add a `Step` to
  `InteractionLatencyProbe.steps` with what to press and how to tell it showed.
