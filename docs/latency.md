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
presses each shortcut and clicks each control 8 times. Keys and clicks are real events posted to
its own event queue, so they go through the same key monitors, menu shortcuts and hit testing as a
press on the keyboard; the window server step before that is left out. Keys are made the way the
keyboard makes them, from a Core Graphics event on the key that types each character on the Mac's
layout: SwiftUI's menu bar ignores a key made with `NSEvent.keyEvent` or with its characters set by
hand (#677), and macOS moves a shortcut the layout can't type to another key (⌘[ is ⌘ö on a Swiss
German keyboard), so Back is pressed with the key its menu item shows. A scroll goes straight to
the list's scroll view, where a real one ends up. The clock starts when the first event goes out.

A try ends at the first frame Core Animation commits after the state the screen draws from has
changed (the player says paused, the palette is open, the list has moved). One display refresh
(16.7 ms at 60 Hz) is added for that frame to reach the screen. A main thread that is busy after
the input delays that frame, so it counts in full. This rests on SwiftUI updating the views from
that state before the same commit, which is how it draws; the probe doesn't read pixels back.

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

CI runs `scripts/latency-test.sh --ci` on every push to `main` and once per pull request before it merges (job "Interaction latency (Release)", see [ci-and-releases.md](ci-and-releases.md)).
GitHub's macOS runners are 2-4 times slower than a Mac: play/pause takes about 80 ms there and ⌘K
200-290 ms, so the 50 ms line can't be checked on them. Instead every interaction has its median
on that runner under `ci` in the baseline file, and the job fails when its median gets more than
twice that, when its checked time is over four times that (a few tries got far slower), when more
than one try never shows, or when it is new and has no time there yet. That catches a change like
#645 (play/pause going from 50 to 610 ms with a long playlist open). Whether something is within 50 ms is what the run on a Mac says, and a PR
that touches an interaction puts that run's times in its description.

When a change makes an interaction faster, set its `ci` time from the job's uploaded report, so it
can't drift back.

## Every interaction

Measured on 2026-11-25, Release builds of 0.8.64 to 0.8.68, Mac mini M4, 60 Hz. Median and checked time
in ms. These are the "before": the probe changes no behaviour. Each fix adds its "after" here.

| Interaction | What you do | Median | Checked | Issue |
|---|---|---|---|---|
| `playback.toggle.key` | Space pauses or resumes | 38 | 40 | |
| `playback.toggle.click` | Click the play/pause button | 36 | 38 | |
| `playback.next` | ⇧⌘→ skips to the next song | 37 | 39 | fixed in #687 (was never) |
| `playback.previous` | ⇧⌘← goes back a song | 38 | 39-53 | #704 (was never; shows at once since #687) |
| `playback.seek` | ⌘→ jumps ahead in the song | 24-30 → 24-29 | 30-46 → 26-45 | #730 (was never) |
| `playback.shuffle` | ⌥⌘S turns shuffle on or off | 38-55 → 25-33 | 42-59 → 26-35 | #730 (was never) |
| `playback.repeat` | ⌥⌘R changes repeat | 41-58 → 25-34 | 44-60 → 26-43 | #730 (was never) |
| `palette.open` | ⌘K opens the command palette | 79 → 26 | 88 → 36 | #671 |
| `palette.type` | Typing a letter in the palette | 71* → 41 | never → 44 | #671 |
| `palette.close` | Esc closes the palette | 72 → 37 | 78 → 46 | #671 |
| `sidebar.toggle` | ⌘S hides or shows the sidebar | 81 → 43 | 83 → 43 | #672 |
| `queue.toggle` | ⌥⌘Q opens or closes the queue | 72 → 52† | 77 → 61† | #673 |
| `lyrics.toggle` | ⌥⌘L opens or closes the lyrics | 114 | 123 | #674 |
| `page.search` | ⌘F opens Search | 86 | 89 | #675 |
| `page.back` | ⌘[ goes back a page | 41-62 → 35-38 | 45-63 → 38-48 | #730, the rest #675 (was never) |
| `page.sidebarClick` | Click a playlist in the sidebar | 60 | 66 | #675 |
| `playback.toggle.longList` | Space with the 1000-song playlist open | 36 | 37 | |
| `list.scroll` | Scrolling a 1000-song playlist | 30 | 37 | |
| `settings.open` | ⌘, opens Settings (Settings on screen) | 99 → 43-53 | 113 → 46-61 | #676 |

† After #673's first part (median 52, checked 61 on a busy Mac): closing takes 36-47 ms, opening
50-61 ms. Opening still builds the queue's list in its first frame; the rest of the window no
longer redraws.
\* Run on its own; after the palette had been opened and closed 8 times, the letters never reached
the field: ⌘K while the panel was still fading out brought that panel back without focusing its
field. "→" is the time after #671, measured on 2026-11-25 in the same full run.
"never" means nothing changed on screen within 3 s in any try. Next and previous count once the
player bar names another song, or for a previous more than 3 s into a song, shows it again from
its start. Since #687 the bar shows that at once, from the songs Spotify's page lists around the
current one, and settles on what Spotify reports. Screenshot
mode's player never moves for a skip, so it lists more songs around the current one than Spotify's
two, and a run of skips keeps finding the next one.
Settings after #676: the window is built once after launch and kept, so ⌘, only shows it, and
it takes key a turn of the run loop after it is on screen. The first ⌘, after launch went from
about 250 ms to 42.
Its checked time is 46-61 ms on a busy Mac, not yet under 40 in every run, so it stays listed.
Play/pause was measured again with the probe's fixes (the clock starts at the first input, and a
try's timer no longer ends a later try): every press showed, and one try in 8 reached 43-52 ms.
Seek, shuffle, repeat and ⌘[ are from 2026-11-25 with #677, on a Mac mini under load 5. Before it
they never showed: the probe's keys never reached SwiftUI's menu bar, and on the Mac mini's Swiss
German keyboard ⌘[ is ⌘ö. Once they did, shuffle and repeat took 65 ms and ⌘[ 58 ms, because every
change rebuilt the menu bar inside the frame that showed it and the next shortcut first brought
the menu bar's items up to date. The menu bar now hears of a change once, right after that frame,
and updates its items then. The lower times are from one run under load 5; on the final #677
branch, three runs under load 3-7 gave the higher ones. Play/pause is at 45-47 ms on main too
(#726), so that's not only load. Shuffle, repeat and ⌘[ stay on the `known` list until #730 gets
them to 40 ms checked, and so does seek: it passes, but its checked time reached 45-46 ms in two
runs, too close to 50 for the list's 40 ms rule (#678).

After #675 (same Mac, with other builds running beside it, so all four times are higher than the
table's): ⌘F to Search went from 94 / 110 to 36 / 39 ms, a sidebar click from 82 / 88 to 51 / 54.
A page change set some twenty of the palette's and the lyrics' values to what they already were,
and each set re-rendered the window from its root and rebuilt the menus; the player bar was also
built again on every page change. What's left of a sidebar click is SwiftUI's sidebar list: it
updates the browser twice for one selection.
On CI's runner ⌘F to Search went from 370 ms to 46-69 ms (median of three runs). The runner's
speed swings between runs (the lyrics toggle's median went from 351 to 793 ms with the same code),
so its `ci` time is the slowest of those medians with half again on top, 104 ms.
On the Mac, ⌘F's median is under 50 ms (43-45 ms with other builds running), but the try that's
checked is still 50-52 ms under load, above the 40 ms a listed interaction needs to come off the
list, so it stays listed at 52 ms with #675.

The "→" times for these four are from #730, 2026-11-26, ten runs on a Mac mini shared with other
builds (load 4-25). Two things made shuffle, repeat and ⌘[ slower than seek:

- **The menu bar's search.** They are menu-only commands, so their keys went to the menu bar,
  which looks through every menu and brings SwiftUI's items up to date before it runs one: 15-23 ms
  from the key to the command, where ⌘→ runs from the key monitor in under 2 ms. The key monitor
  now runs these three items itself (`MenuOnlyShortcuts`): the same item, only when it is enabled,
  with the key its menu shows.
- **The whole window drew again.** The menu bar's state (shuffle's checkmark, repeat, whether Back
  is enabled) is mirrored on the window's command palette manager, and the window's root view
  observed the scene that passes those changes on. So each change ran the root view's body and,
  under it, the whole browser's, in the frame that showed the change: 20 ms instead of seek's 5.
  The root view now keeps the scene without observing it.

Shuffle, repeat and seek are off the `known` list. Shuffle stayed at or under 40 ms checked in all
ten runs. Repeat did in the five runs on the final code, and reached 43 ms once in the five before
the player bar change. Seek did in those first five, and reached 45 ms once in the five on the
final code, under load 6-18. Seek's path didn't change (its median is 24-29 ms), so that's the load.
⌘[ is at 35-38 ms median, but its checked time still reached 42-48 ms in some runs:
what's left is the page change itself (the browser's body runs again and draws the sidebar and the
page a second time), the same work as ⌘F and a sidebar click. It stays listed, at 47 ms, with #675.

Again on top of #675's page-change work above (2026-11-26, three runs, load 3-4, median / checked):
shuffle 30-31 / 32-33 ms, repeat 31 / 32-34, seek 28-29 / 30-45, ⌘[ 31-40 / 39-45. ⌘[ came in under
40 checked in one of the three, so it stays listed with #675.

## The sound (Apple Music)

Pause, resume and skipping should change what you hear within 50 ms too (#679). The interaction
probe above sees only the screen, and the sample library plays nothing, so the sound has its own
tool:

```sh
scripts/sound-latency.sh               # Wax is running and playing an Apple Music playlist
scripts/sound-latency.sh --rounds 12 --only next,previous
```

It presses Space (pause, then resume), ⇧⌘→ and ⇧⌘← in the running Wax, 6 rounds by default, and
listens to the Mac's audio output through a Core Audio process tap. It times each press to the
first silent output cycle (pause), the first sound again (resume), and for a skip the first sound
after the old song went quiet. The tap hears the output before volume and mute, so the Mac can stay
muted. The first run asks for System Audio Recording permission for the terminal that runs it. The
tool is a script for your Mac only: the app itself never listens to audio
(`scripts/eq-mic-permission-audit.sh`). A song that begins with silence adds that silence to a
skip's time, so look at the fastest time next to the median.

### Measured

Release builds, Mac mini M4, built-in speakers, macOS 27, 8 rounds through Wax, Liked Songs
playing. Median, fastest and slowest, in ms:

| Press | Before (0.8.68) | After (this change) | MusicKit alone |
|---|---|---|---|
| Space, pause | 75 (72-108) | 74 (71-89) | 51-74 |
| Space, resume | 245 (243-248) | 249 (245-255) | 232-256 |
| ⇧⌘→, next | 204 (192-213) | 212 (199-217) | 206-223 |
| ⇧⌘←, previous | 445 (416-477) | 440 (410-465) | 455-545 |

"MusicKit alone" sends `ApplicationMusicPlayer`'s own commands from a test, with no Wax in
between. Wax sends a skip to the player in the same millisecond as the press, and a Space press
15-20 ms after it (the log's `sound` lines give both times), so nearly all of it is Apple's player:

- MusicKit doesn't play the sound in Wax's process. It hands it to a macOS service
  (`RemotePlayerService`), and the times above are that service's, whatever the app does. Keeping
  the speakers running with silence, pausing through the playback rate instead of `pause()`, and
  jumping to the next queue entry directly instead of skipping changed none of them.
- MusicKit has no way to load a song's audio ahead. Its queue already holds the songs around the
  current one, and next was as slow 25 s into a song as right after it started.
- Previous is slower than next with the same songs, also with MusicKit alone.

So 50 ms can't be reached for resume and skips with Apple Music. What Wax does instead:

- **It shows the press at once.** Play/pause flips as you press (see `playback.toggle.key` above).
  A song, album or playlist that is started and still being looked up (the first play of Liked
  Songs took 1.45 s to sound) turns Play into a small spinner at once, until the song plays or the
  play fails. The log's `bar updated to starting` line measured it 16 ms after the press.
- **The playback log says how long the player took.** After each pause, resume, skip and new
  queue, a `sound` line says when the player's position stopped or started moving, after the
  command and after the press, for example
  `sound skipToNext: playing 95.0 ms after the command, 98.0 ms after the press`. That position is
  what the app can see; the sound follows it by about another 30-200 ms (the table's times minus
  the log's). A start that never comes is logged after 10 s.

## What isn't measured yet

- **Apple Music's screens.** The probe runs on screenshot mode's Spotify stand-in, because CI has
  no Apple Music account. The views are the same for both services; the data behind them isn't.
- **A sidebar click on CI's runner.** There, clicking a sidebar playlist never shows, while it
  works on a Mac, so CI can't yet tell when it gets slower (#688). Next and previous have no CI
  time yet, since they only show since #687. Seek, shuffle, repeat and ⌘[ have shown there since
  #677; their CI times are the slower median of two runs each (seek 27 and 41 ms, ⌘[ 59 and 79),
  as one run is a thin base for a 2x check.
- Drag and drop, context menus, the queue's own buttons, Settings changes, the service switcher,
  the scrubber and volume aren't in the list yet (#680). Add a `Step` to
  `InteractionLatencyProbe.steps` with what to press and how to tell it showed.
