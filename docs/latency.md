# Latency

Every interaction in Wax shows its result within **50 ms** (#656): every click, key, scroll,
menu, playback control, search keystroke and page change. When the real result needs the network
or Apple Music, the app shows at once that it heard the input (the button changes, the page opens
with a loading state), and that first reaction is what counts.

A PR that touches an interaction runs `scripts/latency-test.sh` and puts the times before and
after in its description.

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

The time checked against 50 ms drops the single slowest try, since a shared CI machine now and
then stalls for a frame; a try that never showed within 3 s counts as the slowest. The report
lands in `build/latency/report.json`, with what the app showed for every try that went wrong.

CI runs the script on every pull request (job "Interaction latency (Release)"). Interactions
that are over 50 ms today are listed in [`scripts/latency-baseline.json`](../scripts/latency-baseline.json)
with the issue that fixes each one. They're reported but don't fail the job. Anything else over
50 ms fails it. When a fix lands, its entry goes.

## Every interaction

Measured on 2026-11-24, Release build of 0.8.62, Mac mini M4, 60 Hz. Median and checked time
in ms. "Before" is main when the probe went in; it changes no behaviour, so there's no "after"
yet. Each fix fills in its own column.

| Interaction | What you do | Median | Checked | Issue |
|---|---|---|---|---|
| `playback.toggle.key` | Space pauses or resumes | 40 | 53 | #678 |
| `playback.toggle.click` | Click the play/pause button | 44 | 51 | #678 |
| `playback.next` | ⇧⌘→ skips to the next song | 26 | 31 | |
| `playback.previous` | ⇧⌘← goes back a song | 25 | 25 | |
| `playback.seek` | ⌘→ jumps ahead in the song | never | never | #677 |
| `playback.shuffle` | ⌥⌘S turns shuffle on or off | never | never | #677 |
| `playback.repeat` | ⌥⌘R changes repeat | never | never | #677 |
| `palette.open` | ⌘K opens the command palette | 100 | 104 | #671 |
| `palette.type` | Typing a letter in the palette | 71 | 76 | #671 |
| `palette.close` | Esc closes the palette | 67 | 71 | #671 |
| `sidebar.toggle` | ⌘S hides or shows the sidebar | 92 | 102 | #672 |
| `queue.toggle` | ⌥⌘Q opens or closes the queue | 84 | 102 | #673 |
| `lyrics.toggle` | ⌥⌘L opens or closes the lyrics | 137 | 146 | #674 |
| `page.search` | ⌘F opens Search | 105 | 106 | #675 |
| `page.back` | ⌘[ goes back a page | never | never | #677 |
| `page.sidebarClick` | Click a playlist in the sidebar | 78 | 89 | #675 |
| `list.scroll` | Scrolling a 1000-song playlist | 31 | 39 | |
| `settings.open` | ⌘, opens Settings | 113 | 120 | #676 |

"never" means nothing changed on screen within 3 s in any try (#677).

## What isn't measured yet

- **The sound.** Pause, resume and skipping must change what you hear within 50 ms, with the
  songs around the current one loaded ahead. The sample library plays nothing, so the probe only
  sees the screen. Apple Music's press-to-sound times are #679.
- **Apple Music's screens.** The probe runs on screenshot mode's Spotify stand-in, because CI has
  no Apple Music account. The views are the same for both services; the data behind them isn't.
- Drag and drop, context menus, the queue's own buttons, Settings changes, the service switcher,
  the scrubber and volume aren't in the list yet (#680). Add a `Step` to
  `InteractionLatencyProbe.steps` with what to press and how to tell it showed.
