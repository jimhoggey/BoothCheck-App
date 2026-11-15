# Booth Check

A menu bar app that keeps the lighting booth Mac ready for a service. At login it starts the show in
the right order and checks everything; if it's all green it stays out of the way, and if not it opens
its window once so whoever sits down sees what to fix.

## How it behaves

- **Lives in the menu bar.** No Dock icon, not in Cmd-Tab, never takes focus from Lightkey. The icon's
  shape shows the state: a tick when everything's fine, a triangle or cross with a count when
  something needs attention. Click it to see just the problems, **Get the show started**, **Shut
  down the booth**, and **Open Booth Check** for the full window. **Quit** shows only while you
  hold **Option**, so it isn't one stray click. The icon is kept in the menu bar: dragged off, it's
  put straight back, and each check makes sure it's showing (logged only when that changes; missing
  twice running, it's put back once more).
- **At login** it runs the start-up in a fixed order, shown as numbered steps in a small panel at
  the top right that floats over everything, full-screen Lightkey included, without taking focus:

  1. Wait for the DMX interface to appear on USB, so Lightkey can attach to it (either USB plane
     counts: `ioreg -p IOUSB` or `ioreg -r -c IOUSBHostDevice`). Usually it's found at
     once and nothing is asked. If it isn't there after 10 seconds, a **big sign in the middle of the
     screen** (over a dimmed backdrop) says to unplug the USB cable from the DMX box and plug it back
     in, with a short animation of exactly that: an interface left plugged in sometimes only shows up
     again that way. The replug is picked up within a second ("Found it"), the wait runs up to 90
     seconds so someone can get to the cable, and **Carry on without it** skips it
  2. Open any other apps, such as ProPresenter
  3. With a Stream Deck: open **Lightkey without the show**, wait for its MIDI input (the Stream
     Deck plugin looks for it when it starts; not there after 45 seconds, and the start-up opened
     Lightkey itself, Booth Check quits Lightkey the shutdown's no-questions way, clears any olad left
     behind, opens it again and waits once more, so the deck isn't dead all service; once only, never
     a Lightkey that was already open), with the [deck lights helper](#the-deck-lights-helper)
     also wait for its "Lightkey Feedback" port (launchd starts the helper at login; not there
     within 3 seconds, Booth Check starts or restarts it through launchd at once, logged, and waits
     up to 20 seconds in all, then carries on with a warning), switch App Nap off if it's on, put the
     deck on the [profile chosen for the service](#the-stream-deck-profile) if it isn't (while Stream
     Deck is closed), open **Stream Deck in the background**, and give its plugin 10 seconds to connect. Lightkey sends every cue's state
     once, at the moment the show opens, so the deck is listening by then and its Default key lights
     (tested with the DMX box and a Stream Deck XL, 9 Oct 2026: Lightkey 1.4 s, Stream Deck 2.4 s,
     the show 13.8 s, Default sent as on)
  4. Open the show in Lightkey (on Apple silicon, while it opens: "If macOS asks to allow an
     accessory, click Allow"; Intel Macs never ask). With an Open DMX USB, Lightkey doesn't load the
     show until someone clicks **Authenticate** and types the Mac's password (it frees the interface
     from the Mac's own FTDI driver), so with Accessibility allowed this step waits for the show, up to
     two minutes, and says what to do; the MIDI and DMX steps then don't run ahead. If Lightkey ends
     up behind another app (its alert, and the Touch Bar's Authenticate, only show while it's in
     front), Booth Check brings it forward: at most three times, ten seconds apart, and never over
     macOS's password box. It also sees when Lightkey's Authenticate alert is up and says so
  5. Confirm Lightkey has the DMX interface open (experimental), and **reconnect it if it hasn't**.
     After 20 seconds (a minute while Lightkey may ask for its password; at once when the link is
     suspect: Lightkey was already running before the box was seen, or its `olad` started before the
     box appeared), with the box on USB but not held, Booth Check tries in order, each logged with
     its command and output and checked for 12 seconds: `kill -HUP <olad>` (olad reloads its plugins
     and scans USB again), Lightkey's **Reset DMX Output** menu item (through Accessibility; skipped
     without it), then **restarting Lightkey** the shutdown's no-questions way and running steps 3
     and 4 again (at most twice). While it does, the hands-off sign says what it's doing ("The lights
     aren't connected. Reconnecting…", "Restarting Lightkey", then "The lights are connected" or
     "Couldn't reconnect the lights"). Nothing is tried while Lightkey asks for its password, or when
     the box is on neither USB plane (that's the replug sign's job). If it all fails, the step warns
     with what was tried
  6. Without Lightkey on this Mac, Stream Deck opens here instead
  7. Check everything: it waits for a check pass that starts after the steps above (a pass already
     running started too early to count), so the step and the panel's heading always give the same
     count, and the step follows each pass while the panel is up

  While the show opens, Booth Check also listens (read only) to "Lightkey Output" and notes in the Log
  whether Lightkey reported the show's start states (how many cues, how many on). That's evidence
  only: it never decides "Ready", since a show with nothing MIDI-mapped on at start reports nothing.

  **A login start-up also puts a few settings back by itself**, each with the exact command its
  row's change sheet runs, logged with the command, output and undo, and a `self_repair` event:
  - Before Lightkey opens: **Lightkey connects without the password** (`DontUnloadFTDIDrivers`) when
    it went missing (Lightkey's settings reset, say) though it's wanted here: Booth Check switched it
    on, or a start-up was ready with it on. Untick it in This Mac and it stays off. Only while
    Lightkey isn't running; read back afterwards.
  - After the apps are open, off the main thread: **Booth Check opens at login** (only a copy in
    Applications adds itself), **No show opens on its own at login**, **Stream Deck waits for Lightkey**
    and **Old apps don't reopen at start-up**, when the row is shown (switched on in This Mac, not
    muted) and orange or red. They take effect at the next login; the next pass confirms each. If
    Booth Check can't read the login items (System Events not allowed), it changes nothing there.
    AppleScript off the main thread goes through `osascript`, stopped after 20 seconds.

  After the start-up, **Stream Deck stays open**: when it's switched on in This Mac and its app
  isn't running (switched on just now, Booth Check reopened after an update, or someone quit it),
  Booth Check opens it in the background within 15 seconds, App Nap off first. On a Lightkey Mac it
  waits until Lightkey's MIDI input is there, it tries at most once a minute, and never while a
  start-up or shutdown is opening or closing apps.

  **Stream Deck's keys start clean.** A latch key (a colour, a house level) lights when Lightkey says
  its cue is on but ignores "off", so a key left lit stays lit after Lightkey restarts (Lavender lit
  on the church Mac, 9 Oct 2026). So when the start-up finds Stream Deck already open it restarts it,
  and when Lightkey is started any other way (by hand, after a crash) Booth Check restarts Stream Deck
  once Lightkey is ready (tested: 3 seconds after Lightkey reopened).
  A restart alone isn't a clean slate: Stream Deck 7 saves each key's state in its profile
  (`ProfilesV3/<profile>.sdProfile/Profiles/<page>/manifest.json`, `"State": 1` = the lit image) and
  a key saved lit comes back lit (church Mac, 15 Nov 2026: several keys on at boot with only Default
  on in Lightkey). So in those two places, while Stream Deck is closed, Booth Check also **resets the
  saved state to 0 on every MIDI key** (Trevliga plugin, two or more states) on every page of the
  profile the deck will show: the one chosen in This Mac and each deck's preferred profile. Then
  Lightkey drives the keys from the show's start states on. Only those digits in the file change;
  text and page keys and everything else stay byte for byte, and the result is re-read and compared
  with the original before it's written (atomically). A profile is only reset once Booth Check holds
  a copy of it as it is (below). If Stream Deck is running, a file doesn't read as expected, or it
  changes meanwhile, that page is left alone and the start-up carries on. The Log says which profile
  and pages and which keys (by title). There's no switch: it's part of "keys start clean". Quitting
  Stream Deck yourself mid-service doesn't reset anything; Booth Check just reopens it.

  **The Stream Deck profile mends itself.** In the same two places, while Stream Deck is closed,
  Booth Check first checks the service profile on disk (the one chosen in This Mac, else each deck's
  profile): its folder is there, its manifests are JSON, every page it lists is there, and it still
  has MIDI keys if Booth Check's copy had some. If it's **broken or gone** and Booth Check has a copy,
  it **puts the copy back by itself** before Stream Deck opens (the sign says "Putting the Stream
  Deck's keys back…"): the copy goes into a hidden folder next to the profile, is checked identical,
  swaps places with the broken one in one step, and the broken one is kept in Booth Check's folder
  (`deck-backups/<profile>/set-aside/<date>`, newest 3; never deleted). About 10 seconds after Stream
  Deck opens, Booth Check checks the profile again; if it broke again, it tries once more (quit,
  put back, reopen), then stops and the row asks a person. A healthy profile is never "repaired": if
  the tech changed it, the changed one simply becomes the new copy. JSON in a shape Booth Check
  doesn't know (a new Stream Deck version) is left alone.
  **The copy:** one per profile, `~/Library/Application Support/Booth Check/deck-backups/<profile
  uuid>/good/` (about 3 MB) plus `good.json`, made only while the profile is healthy, and only when it
  changed (a hash that counts saved key lights as dark, so the reset alone isn't a change). Stream
  Deck's own daily backups (`com.elgato.StreamDeck/BackupV3`) are the longer history.
  **Why before Stream Deck opens:** Stream Deck 7.6 compares its action count with the last session's
  when it starts, and if it's lower (a manifest that isn't JSON, a profile folder gone) it asks
  "Stream Deck detected an error restoring the last session… restore the backup from today?" and does
  nothing, keys included, until someone answers (tested on the dev Mac, 15 Nov 2026). The key reset
  and the swap of an identical folder don't raise it, nor does a force-quit (after one, Stream Deck
  skips that check). If the question is up anyway, the "Stream Deck app running" row goes red with
  **In Stream Deck's window, click Restore** (Booth Check reads it from Stream Deck's log; Restore puts
  back Stream Deck's backup of every profile from that morning).
  **During a service** Booth Check never quits Stream Deck to mend a profile: the "Stream Deck is on
  the right profile" row goes red ("The service profile '…' is damaged…") with **Restore the Stream
  Deck's keys…**, which shows the steps, the copy's date and the undo first. With no copy yet, the
  row says to import the `.streamDeckProfile` file again or pick the profile in This Mac.

  Only the steps for apps switched on in This Mac appear. If all are green the panel says "Ready for
  the service" and hides itself; if not it stays, with **Open Booth Check**. A step that warned on the
  way (say, the DMX link before the password was in) doesn't keep it up: once nothing needs fixing,
  the panel turns green and hides too. After that it never pops up during a service; only the icon
  changes.

  While it runs, a **hands-off sign** fills the middle of the screen over a dimmed backdrop: "Please
  don't touch the Mac", with the step it's on, so nobody clicks around in a half-open Lightkey. From
  the moment Lightkey opens until it has the DMX interface, the sign becomes a banner along the bottom
  with nothing dimmed, saying what Lightkey may need: Authenticate and the Mac's password, or a click
  on the show if it opens on its list of projects (with no show chosen in Booth Check). Lightkey's
  alert and macOS's password box come up in the middle, so the banner stays clear of them. At the end it says "Ready for the service" (or that something needs a
  look, and the panel says what) and goes. The replug sign takes its place while that's up. It never
  takes focus or catches a click, and **Open Booth Check** or **Hide** on the panel takes it away for
  the rest of that start-up.
- **Opened by hand**, it shows the window straight away.
- **Checks every 15 seconds** in the background, window open or not.

Starting the show at login can be switched off in the window ("Start the show when the Mac starts").
Then it only checks, and expects the show and Stream Deck to be login items themselves.

## What this Mac does

Not every Mac is the lighting booth. **This Mac** (in the window's header) lists the apps this Mac
runs, each with a switch. Switching an app on switches on every check that belongs to it:

| On this Mac | What Booth Check does |
|---|---|
| **Lightkey** | checks it's open with the right show (chosen on the main window), and opens it when the show starts. **A DMX interface is plugged in here** sits inside this row and adds the interface-connected and Lightkey-is-using-it checks; switching Lightkey off switches those off too |
| **Stream Deck** | checks the deck is plugged in, its app is open, App Nap is off, and Lightkey is listening for it; opens it once Lightkey is ready. **Deck lights helper** (with Lightkey on) sits inside this row and adds its check, start-up wait and restarts. Until someone unticks it, it counts as on, so a Mac without the helper shows the row red with **Install…**. **Install / update…** under it installs the helper Booth Check carries. **Profile for the service** picks the Stream Deck profile that goes with the show (default **Don't check**; see [The Stream Deck profile](#the-stream-deck-profile)) |
| **ProPresenter**, or any app added with **Add an app…** | checks it's open, and opens it when the show starts |
| **Stays on for services** | checks the charger, sleep, Low Power Mode, starting from the charger, macOS updates, and what opens at login |
| **Start the show when the Mac starts** | opens the apps above at login, in order, instead of macOS login items doing it all at once; the switch's description says exactly what it will open |
| **Shut down by itself** | at the days and time set under it (Sundays at 1 pm to start with), shuts the booth down if nobody has: see [Shut down the booth](#shut-down-the-booth). Off until switched on |
| **Shut down when the power goes off** | MacBooks only: when the charger loses power, shuts the booth down after a 1-minute warning (see [Shut down the booth](#shut-down-the-booth)). Off until switched on |
| **Black out the stage first** | with Lightkey on: every shutdown sends the show's Blackout to Lightkey before it closes, so the stage lights don't flicker as it stops (see [Shut down the booth](#shut-down-the-booth)). The description says which note it will send and where that came from, or why it can't. Off until switched on |

So a ProPresenter Mac is: ProPresenter on, Lightkey and Stream Deck off, stays on, start at login.
Booth Check keeps it awake, opens ProPresenter at startup, and checks it's running.

The first time the window opens, the sheet appears filled in from what's installed: ProPresenter is
listed whenever it's installed, and switched on when Lightkey and Stream Deck aren't.

Any single check can also be **muted** with the 🔕 button on its row (or right-click). Muted checks
stay listed under "Muted on this Mac" with an Unmute button.

Nothing is hidden quietly: the header and the menu bar dropdown always say "N checks off for this Mac
· N muted", and every change is kept in the Log. With nothing switched on, the header says "Nothing to
check on this Mac" and the menu bar shows a dashed circle, never a tick. When the Stream Deck app isn't installed at all, its
row offers **No Stream Deck on this Mac**. The DMX interface deliberately has no such shortcut: at a
service, a cable falling out looks exactly like a Mac without one, so it can only be switched off in
the sheet.

## What it checks

| Group | Checks |
|---|---|
| Lighting | DMX interface plugged in · Lightkey running · the right show open · Lightkey sending DMX *(experimental)* · Lightkey connects without the password · Lightkey's MIDI input ready for the Stream Deck |
| Stream Deck | Stream Deck plugged in · Stream Deck app running · deck lights helper running *(where it's ticked in This Mac)* · Stream Deck is on the right profile *(where a profile is chosen in This Mac)* |
| Power & sleep | on the charger · starts up when the charger is plugged in *(laptops, optional)* · never sleeps on the charger · the screen stays on · Low Power Mode off · App Nap off |
| Start at login | Booth Check opens at login · Booth Check starts the show · no show opens on its own · Stream Deck waits for Lightkey (each offers Remove when something else would race it; This Mac also lists anything else macOS opens at login) · old apps don't reopen at start-up (macOS's "Reopen windows when logging back in"; **Switch it off…** runs `defaults write com.apple.loginwindow TALLogoutSavesState -bool false` and the same for `LoginwindowLaunchesRelaunchApps`, undo `-bool true`) |
| Updates | macOS won't install updates by itself |
| Check these yourself | USB accessories allowed without asking *(Apple silicon only; Intel Macs don't ask)* · no password after idle (macOS doesn't let apps read these two) |

**Booth Check won't click macOS's security prompts for you.** macOS blocks apps from pressing
buttons in its own security dialogs, and an app that could would be able to approve anything. The
accessory prompt is removed properly with its setting (above).

**Stream Deck opens in the background**, out of sight, which is exactly what App Nap puts to sleep.
So just before opening it, the start-up switches App Nap off if it's still on
(`defaults write -g NSAppSleepDisabled -bool true`, no password, logged). Apps read that setting when
they open, so Stream Deck opened straight after stays awake with no restart; if Stream Deck was
already open, the step says to quit and reopen it once, and the App Nap row stays orange until it has
been (it compares when Stream Deck opened with when App Nap was switched off).

**The screen stays on.** With **Stays on for services** switched on and the Mac on the charger,
Booth Check asks macOS to keep the display awake, the request a video player or Keynote makes
(`PreventUserIdleDisplaySleep`; the same as `caffeinate -d`). It changes no setting, needs no
password, ends when Booth Check quits or the Mac goes onto battery, and is logged when it starts and
stops. Why: on the church Mac the screen was set never to turn off, yet after a while untouched it
went to the screen saver (on macOS 26 that's the wallpaper, so it looks like the desktop picture),
and Stream Deck went quiet with it. **The screen stays on** reads the request back from
`pmset -g assertions`.

**Lightkey asks for the Mac's password** (Authenticate) when it connects to the DMX interface, on
Intel and Apple silicon alike: it unloads the Mac's FTDI driver first. Its hidden setting
`DontUnloadFTDIDrivers` skips that, and on the church Mac with its Open DMX USB the lights work with it
on and nothing asks (tested 9 October 2026). **Lightkey connects without the password** checks the
setting, and **Switch it on…** shows the command (`defaults write de.monospc.Lightkey
DontUnloadFTDIDrivers -bool true`) and its undo before running it. The same setting is a checkbox in
This Mac, under Lightkey's DMX interface: **Connect without asking for the password**. It shows the
command it will run (`defaults delete …` to undo), needs no Terminal and no password, logs the run,
and applies from the next time Lightkey opens. With it on, the start-up's sign
stays on "Please don't touch the Mac" the whole way. Without it, the start-up says to type the
password, and waits a minute for Lightkey to connect.

**Why only Booth Check should open at login.** Login items all start at once, in no set order. If
the Stream Deck app wins the race, its MIDI plugin can start before Lightkey's MIDI input exists and
the keys stay dead until Stream Deck is restarted. Booth Check opens them one after the other, so the
login checks ask for shows and Stream Deck to come off the login items. If the Stream Deck app has
its own "launch at login" option switched on in its preferences, Booth Check can't see that; switch
it off there too.

**Starts up when the charger is plugged in** (AutoBoot) matters in clamshell mode, where the lid
stays closed under a monitor. With it on, a shut-down MacBook starts when you unplug and replug the
charger, so nobody has to open the lid to press the power button. It only acts on a Mac that's shut
down; it doesn't wake a sleeping one or stop you shutting down. It's a firmware setting in NVRAM:
`AutoBoot` on Intel MacBooks from 2016 on (on from the factory), `BootPreference` on Apple silicon.
Booth Check reads it without a password. Turning it on is the one change that asks for the admin
password, because it has no System Settings page; the approval sheet shows the exact `sudo nvram`
command and its undo first, and you can copy it into Terminal instead. The ⓘ next to the check
explains it in the app.

**The right show is open** compares the file Lightkey has open with the chosen one, folder and all, so
a same-named copy in Downloads or a backup folder doesn't pass. (Lightkey is a document app, so macOS
reports each window's file; window titles are only a fallback, and must name the show exactly.) A show
that has been moved, renamed or deleted turns the row red straight away, even before Lightkey opens,
and the start-up says so instead of waiting for a show that can't open.

**Lightkey sending DMX** is experimental. An app can't see the DMX signal, but it can see whether
Lightkey has the interface open. Lightkey drives USB interfaces through its own OLA server, `olad`
(Open Lighting Architecture, installed in `/Library/OLA`), so a connection held by either counts:
macOS records which process opened each USB driver connection (`ioreg`), and `lsof` lists the serial
ports they hold. If the lights respond and this row disagrees, trust the lights.

**When the lights drop out during a service** (the box on USB, Lightkey open, but not holding it,
say after the cable was unplugged and plugged back in: olad scans for interfaces only when it starts),
the row turns red and offers **Reconnect the lights…**: the sheet shows `kill -HUP <olad pid>`, which
asks Lightkey's DMX server to look for the interface again (the lights should not change). If the row
is still red afterwards, it offers **Restart Lightkey…** instead, which warns that the lights go dark
for about 20 seconds, quits Lightkey and runs Get the show started. **Once the booth is ready, Booth
Check never does either by itself**; only the start-up retries on its own. Before the start-up opens
Lightkey, an `olad` left running without Lightkey (from a force-quit Lightkey; the next Lightkey would
reuse it, with no interface) is stopped (`kill -TERM`, `-KILL` after 3 seconds), logged.

**Whenever Booth Check fixes something by itself** (reconnecting the lights, reopening or restarting
Stream Deck, restarting the deck lights helper), the hands-off sign says what it's doing, then how it
went, and goes. Outside a start-up it's the bottom banner, with nothing dimmed, since someone may be
running the service in Lightkey.

**DMX snapshots** for a tech: when a DMX step fails, when the reconnect runs (and before each Lightkey
restart, which overwrites olad's log), when the DMX rows change after the start-up, and at the end of
every start-up, Booth Check saves `~/Library/Logs/Booth Check/dmx-<date-time>-<reason>.txt` (the newest
30 kept): the FTDI device from both USB planes (serial, location, speed, hub chain, driver), the
`/dev/cu.usbserial*` devices, olad's and Lightkey's processes with start times, olad's log
(`~/Library/Logs/Lightkey OLA.log`, e.g. "Found 0 FTDI devices"), the FTDI drivers, boot time, uptime
and the start-up's step timings. The Log gets one entry with the path and a summary.

**Booth Check keeps itself awake** by opting out of App Nap (`NSAppSleepDisabled` plus a background
activity), so its checks keep running behind full-screen Lightkey. It has no row of its own: nobody
could fix anything there, and whether the Mac stays awake is what the Power & sleep checks are for.

### The deck lights helper

The Stream Deck's keys can take their lights from a small helper instead of straight from Lightkey:
`deck_state_helper` listens to Lightkey's "Lightkey Output", keeps which cues are on, and repeats it
every half second on its own MIDI port, "Lightkey Feedback", which the deck's keys use as MIDI In.
Without it the key lights stop following Lightkey; presses still work (they go straight to "Lightkey
Input"). It sends nothing to Lightkey. It's built in the Lightkey-Skill repo
(`tools/deck_state_helper.swift`) and **Booth Check carries a copy** (`helper/deck_state_helper`, put in
the app by `build.sh`; the tests check it's the Summit show's build and that Booth Check starts it with
the show's rules from `install_helper.sh`).

**Install it from Booth Check**: This Mac → Stream Deck → **Install / update…**, or **Install…** on the
red row. The sheet shows the whole script before Run, no password: it stops any older copy (and one
started by hand, which would hold the helper's lock), copies the helper to `~/Library/Application
Support/DeckStateHelper/`, removes the quarantine flag, writes the LaunchAgent
`~/Library/LaunchAgents/com.c3b.deckstatehelper.plist` (start at login, KeepAlive, restart within 2 s,
log to `~/Library/Logs/DeckStateHelper.log`) and starts it. Then it watches the log for up to 6
seconds: the install only counts when launchd says `running` and the log shows the helper started with
all its `--alias` rules (an older helper ignores them without a word); otherwise the sheet says what
went wrong. Booth Check then restarts Stream Deck, if it's open, so the keys connect to the new port.
This Mac shows which version is installed and which one Booth Check carries.

**launchd runs it, not Booth Check**, so it keeps running while Booth Check is quit or updated.
**Deck lights helper running** is green when `launchctl print gui/<uid>/com.c3b.deckstatehelper` says
`state = running` and CoreMIDI lists a source named "Lightkey Feedback". Otherwise it's red, quoting the
last line of the helper's log, with:

| What it finds | Button | What runs (shown first, then Run; no password) |
|---|---|---|
| set up in launchd, but not running, or its port missing | **Restart…** | `launchctl kickstart -k gui/<uid>/com.c3b.deckstatehelper` |
| installed (the plist is in `~/Library/LaunchAgents`), not loaded | **Start…** | `launchctl bootstrap gui/<uid> ~/Library/LaunchAgents/com.c3b.deckstatehelper.plist` (undo: `launchctl bootout gui/<uid>/com.c3b.deckstatehelper`) |
| not installed | **Install…** | the install above |

**Booth Check fixes it by itself.** When the row has been red for 10 seconds (launchd restarts a crash
within 2 on its own), Booth Check runs the Restart or Start command itself and logs it. It does that at
most once a minute and 3 times in 30 minutes, because every restart makes the deck's port again and
many in a row lose the deck until Stream Deck restarts (rig, 28 Oct 2026). After the third, it stops,
the row says what to do, and Booth Check opens its window once so someone sees it. It never installs
by itself.

A helper started by hand (not through launchd) has the port but doesn't count: it wouldn't come
back after a restart. Restarting the helper doesn't need Stream Deck restarted: the plugin picks the
port up again by itself (rig, 28 Oct 2026). The check is under This Mac → Stream Deck → **Deck
lights helper**; Booth Check ticks it the first time it finds the helper installed, and after that
it's a plain setting, so a helper that goes missing shows red rather than vanishing.

The row also compares the installed LaunchAgent's `ProgramArguments` with what Booth Check would
install for this show: different, it's orange, "installed with old settings", with **Install…** (the
same install, with the right rules).

### The show's deck file

A show can carry a `<show name>.deck.json` next to it (for `BackupChurch_modular_v38.lightkeyproj`,
`BackupChurch_modular_v38.deck.json`), saying how its deck is meant to work:

```json
{"helper": {"channels": "2", "mask": "2:3-6", "while": "2:38-39", "alias": "2:22=2:40,2:23=2:41"},
 "profile": "Lightkey XL Service", "blackout": "2:0"}
```

- `helper`: the deck lights helper's rules for this show, passed as `--channels`, `--mask`, `--while`,
  `--alias` (each optional text; `mask` and `while` go together; every key inside `channels`, which
  defaults to 5-13). `"helper": null`: this show doesn't use the helper, so its rows and its start-up
  wait don't apply.
- `profile`: the Stream Deck profile name This Mac suggests (**Use it**), when none is chosen yet.
- `blackout` (optional): the show's Blackout as `"channel:note"`, for **Black out the stage first**.
  Left out, Booth Check uses the Stream Deck's Blackout key instead (nothing to write for the Sunday
  decks); `"blackout": null` says this show has no Blackout, so the shutdown doesn't send one.

No file: exactly the built-in Summit rules (`--mask 5:3-6 --while 6:38-39,8:38-39,10:38-39,13:38-39
--alias 5:22=5:40,5:23=5:41`). Unknown keys are ignored; a bad value means the built-in rules, with a
warning in the Log. What the file says goes in the Log when it changes.

### The Stream Deck profile

A tech picks the profile that goes with the show once, in This Mac → Stream Deck → **Profile for the
service**. The list shows each installed profile with a hint ("Lightkey XL Service · 44 keys · channel
2"); two with the same name are told apart by the hint, then by their keys' hash. Booth Check keeps
the profile's name, UUID and a **signature**: the set of (channel, note, mode, MIDI in, MIDI out) over
its MIDI keys. Importing a `.streamDeckProfile` makes a copy with a new UUID, and versions share a
name, so the chosen profile is found by UUID, then by signature, then by name; more than one left is
"can't tell", not a failure.

Booth Check reads the profiles from `~/Library/Application Support/com.elgato.StreamDeck/ProfilesV3`
(or `ProfilesV2` when it's the same shape), and which profile the deck shows from Stream Deck's
settings (`Devices` → the deck → `ESDProfilesInfo` → `ESDProfilesPreferred`), every 15 seconds,
logged. **Stream Deck is on the right profile** is green when the deck is on it (or on a copy with the
same keys), red with "Stream Deck is on '…', the service needs '…'" when it isn't, and unknown when
it can't be read. The same row is red when the profile isn't installed any more, and warns (orange)
when its keys changed since it was chosen (**Use it as it is now** keeps it as it is), when some MIDI keys don't
send to "Lightkey Input", and when its keys were made with different or older (before 4.3) MIDI
plugin versions.

There's no supported way to switch a profile, so Booth Check changes that one setting itself, **only
with Stream Deck closed** and only when it's exactly the shape above and the profile's folder exists;
anything else, it writes nothing. It reads `Devices`, changes the one value, writes it back with
`CFPreferencesSetAppValue` (never the plist file), logs before and after, opens Stream Deck in the
background, and 10 seconds later reads it back. At the start-up it does this in the Stream Deck
step, when Stream Deck is closed anyway, only if the deck is on the wrong profile, with the sign
"Putting Stream Deck on the '…' profile". Afterwards it never switches by itself: the red row's
**Switch Stream Deck to it…** shows the steps (Stream Deck closes for a few seconds, its keys go dark)
and the undo. If Stream Deck puts its own choice back, the Log says the write didn't take, and the row
says "In Stream Deck, choose '…' at the top of its window" instead.

## Get the show started

The green button, in the window header and the menu bar dropdown, runs the same numbered start-up
by hand, in the same floating panel: anything already open is left alone (the show is just brought to
the front). It only opens apps; it changes no settings. Each step is kept in the Log. The hands-off
sign is only for the start-up at login: whoever clicks the button is already at the Mac.

## Shut down the booth

**Shut down the booth**, in the menu bar dropdown, ends the service in one click:

1. A **10-second countdown** comes up in the middle of the screen, with **Not yet** (stops it) and
   **Shut down now**.
2. Behind a "Shutting the booth down" sign, **every other app is asked to quit** (Chrome, Mail…:
   anything with a Dock icon but Finder), as its own Quit would, never forced. Booth Check waits up
   to 8 seconds, logs any still open, and carries on; one asking to save holds up step 5.
   - **Black out the stage first** (This Mac, off unless switched on): the sign says "Turning the
     stage lights off…" and Booth Check sends the show's Blackout to "Lightkey Input" exactly as the
     deck's Blackout key does (a note-on, velocity 127; channel 2 note 0 on the Sunday decks), waits
     for Lightkey to report it on "Lightkey Output", then 2 seconds for the lights, and carries on.
     The note comes from the show's `.deck.json` (`"blackout"`), else the key titled Blackout on the
     Stream Deck profile chosen in This Mac, else on every profile on this Mac if they agree; if none
     of those gives one note, the switch says so and the shutdown goes on without it. **Toggle
     safety:** the Sunday show's Blackout is a Flash trigger, so a note-on only ever switches it on
     (sent to an already-on Blackout, Lightkey reports nothing and it stays on). If a show's binding
     toggled instead, the note-on would switch an already-on Blackout off; Lightkey reports that off,
     and Booth Check sends once more to put it back on (never more than twice). It never sends without
     "Lightkey Output" to listen to, and skips the step (logged) when Lightkey isn't open or its MIDI
     ports aren't there. At most about 5 seconds; every send, what Lightkey reported and the outcome
     go in the Log. Blackout leaves the house lights on, as on the deck.
3. **Stream Deck closes**. It has nothing to save, so if it hangs it's made to quit after 5 seconds.
4. **Lightkey closes.** In Live mode, when it's the front app, Lightkey asks "Are you sure you want to
   quit Lightkey?"; Booth Check presses its **Quit** (Accessibility, the permission it already has
   for reading the show). Still open after 15 seconds, say asking to save the show, it's made to
   quit, as Force Quit does: changes since the show opened aren't saved, the same as **Don't Save**,
   and Booth Check opens the chosen show file next time anyway. Nothing waits for a person. Only if
   Lightkey survives even that does Booth Check stop and leave the Mac on.
5. **macOS shuts down** (`tell application "System Events" to shut down`). Any other app can still
   say no, and then the Mac stays on and the sign says so.

Closing the apps first also keeps macOS from reopening them at the next login, where they'd race
the start-up (the "Old apps don't reopen at start-up" check covers a shutdown from the Apple menu).
At a login start-up the Log lists the apps that were already open, and says so when macOS reopened
Lightkey before the start-up. Every step is kept in the Log.

**Shut down by itself** (in This Mac) is the backstop for when nobody remembers. At the set time it
gives a **5-minute** countdown, then does the same. **Not yet** asks again in half an hour. It only
goes off within half an hour of the set time, so a Mac that was off or asleep then doesn't shut down
the moment it comes back, and it waits for a running start-up to finish. **If the lights were used in
the last 10 minutes** (Lightkey reported a cue changing on "Lightkey Output", which Booth Check hears
read only, counting MIDI note and control messages, never clock), it doesn't count down at all: it
treats that as Not yet, asks again in half an hour, and says why in the Log.

**Shut down when the power goes off** (in This Mac, MacBooks only) does the same when the charger
loses power while Booth Check is running: a **1-minute** countdown, which stops by itself if the power
comes back (a bumped plug), or with **Not yet** (then it doesn't ask again until the power comes back
and goes off once more). A Mac started on battery on purpose is left alone. Together with **Starts up
when the charger is plugged in**, one switched socket or smart plug turns the whole booth on and off.
macOS has no setting for this on a MacBook's own battery; its power-cut shutdown is only for a UPS.

## Nothing runs behind your back

- **Checks only read.** Every command a check runs is listed in the **Log** (⌘L) with its output.
  It's the same short list each time, repeated every 15 seconds. The exception is a login start-up,
  which puts a few settings back by itself (see the start-up above), each logged in full with its undo.
- **Changes wait for you.** A button that changes something (turn App Nap off, add Booth Check to
  login, remove something from login) first shows the exact Terminal command or AppleScript, and runs
  it only when you press **Run**. The output appears straight away, and the change is kept in the
  Log. App Nap also shows the command that undoes it.
- **No admin password.** Anything that would need it, such as switching sleep off, opens the right
  page of System Settings instead and says which setting to change.

Other buttons only open things: the show, the Stream Deck app, or a page of System Settings. The one
exception is **Shut down the booth**, which closes the open apps and shuts the Mac down
once its countdown runs out (**Not yet** stops it). Its timed version only runs if it's switched on
in This Mac. Both keep every step in the Log.

## The log on disk and diagnostics

- **The Log is kept on disk** in `~/Library/Logs/Booth Check/BoothCheck.log` (plain text, a header
  per launch, every change and start-up step in full; the 15-second checks in full at the first pass,
  during a start-up, when a check changes and once an hour, otherwise one line). It rotates at 5 MB,
  5 files kept, next to the DMX snapshots. In memory the Log keeps the newest 500 entries. A file
  `~/Library/Application Support/Booth Check/running.json` is there while Booth Check runs; left
  behind at the next launch, the last run ended uncleanly (power cut, force quit, or a crash when
  macOS wrote a crash report).
- **Diagnostics go to the developer** through Aptabase (`us.aptabase.com`): when Booth Check starts,
  each start-up step and how long it took, checks failing and recovering, DMX snapshots and
  recovery, self-repairs, power changes, shutdown and update steps, settings, and, when something
  goes wrong (a start-up warning, a check failing over a minute, the DMX recovery, a shutdown that
  stayed on, an unclean exit), the relevant part of the log. Everything is scrubbed first: the home
  folder becomes `~`, the user's and the Mac's names are removed, USB serial numbers are hashed,
  emails and IP addresses removed; passwords are never in it. Events wait in
  `aptabase-queue.jsonl` (sent after the start-up, then every 5 minutes, and before a shutdown);
  each send is in the Log with the server's answer. Every event is also one line in the log on disk
  (`event <name>: key=value …`), diagnostics on or off.
- **The session** is one run of Booth Check, from launch to quit or shutdown. Every event carries its
  id as the Aptabase session and the `launch` prop. Durations use the Mac's monotonic clock, which
  stops while it sleeps; times are UTC. The running tallies are saved in
  `~/Library/Application Support/Booth Check/session.json` (on a row change, after a start-up and
  every 5 minutes), so if the Mac loses power, the next launch sends that session's summary with
  `ended: unclean` and `late: 1`. A normal Sunday (one start-up, a 3-hour service, one shutdown) is
  roughly 50 to 120 events; nothing is sent per 15-second pass unless a check changed.

| Event | When | Main props |
|---|---|---|
| `app_start` | Booth Check starts | `how` (login_item, login_flag, after_restart, by_hand), `at_login`, `uptime_s`, `version`, `setup`, `prev_exit` (clean, update, unclean, crash, first), `prev_ran_at`, `prev_session_s`, `prev_ended`, `since_prev_h` |
| `apps_open_at_login` | login start-up | apps already open, `lightkey_reopened` |
| `startup_step` | each start-up step ends | `step`, `n`, `result` (done, warn, failed), `seconds`, `at_s` (since the start-up began), `detail` |
| `startup_done` | the start-up ends | `ready` (1 = "Ready for the service"), `total_s`, `how` (login, by_hand, check_only, restart_lightkey), `steps`, `steps_ok`/`_warn`/`_failed`/`_not_run`, `problems`, `dmx_rungs`, `dmx_recovery`, `replug_shown`, `auth_wait_s`, `people` (person events during it), `started` |
| `check_failed` | a row goes warn or fail (not during a start-up) | `check`, `title`, `status`, `detail`, `spell` (how many times this session) |
| `check_recovered` | it's OK again | `check`, `title`, `for_s`, `cleared_by`: `by_itself`, `fix:<button>`, `run:<change>`, `self_repair:<what>`, `startup` (Get the show started) |
| `check_cleared` | a row muted or switched off while not OK | `check`, `for_s`, `cleared_by` (muted, gone) |
| `person` | someone acted, or had to | `action`, `during` (startup, service, shutdown), and for a row `check`, `title`, `row_status`. Actions: `fix` (a row's button, `button`), `run` / `cancel` (the change sheet, `key`: e.g. `dmxReconnect` is Reconnect the lights…, `dmxRestart` Restart Lightkey…), `check_again`, `start_show`, `mute`, `unmute`, `not_yet` (`trigger`, `left_s`), `update`, `replug` (the replug card: `result` found, skipped or timeout, `wait_s`), `authenticate` (Lightkey asked for the password: `wait_s`, `result`) |
| `settings_changed` | This Mac settings changed | `keys`, `this_mac_open` (0 = Booth Check changed it itself) |
| `setting` | a logged setting (mute, show, profile…) | `key`, `value` |
| `self_repair`, `dmx_recovery`, `dmx_snapshot`, `deck_profile`, `power_change` | Booth Check fixing or recording something | `what`/`rung`, `result` (`what` `deck_profile_restore`: `broke_again`, `no_copy`, `asks_restore` = Stream Deck's own restore question is up) |
| `deck_keys_cleared` | the saved key lights reset, Stream Deck closed | `why`, `keys`, `pages`, `profiles`, `skipped`, `result` |
| `deck_profile_copy` | a new last-good copy of a profile | `why`, `pages`, `keys`, `kb`, `first` |
| `deck_profile_restored` | a broken or missing profile put back from the copy | `why` (what was wrong), `during`, `how` (automatic, button), `result`, `identical`, `pages`, `keys`, `copy_age_h` |
| `shutdown` | each shutdown step | `reason`, `step`, `detail` |
| `shutdown_blackout`, `apps_quit_at_shutdown` | the Blackout, other apps closing | `sends`, `on`; `apps`, `stayed` |
| `shutdown_done` | the apps closed (or it stayed on) | `trigger` (menu, weekly_time, power_off), `result` (shutting_down, stayed_on), `countdown_s`, `other_apps_s`, `blackout_s`, `stream_deck_s`, `lightkey_s`, `total_s`, `lightkey_forced`, `lightkey_quit_pressed`, `stream_deck_forced` |
| `update` | each update step | `from`, `to`, `step`, `result` |
| `app_quit` | the session ends | `reason` (quit, menu_quit, update, mac_logout_or_shutdown, shutdown_menu/_weekly_time/_power_off), `session_s`, `startup`, `problems_now`, `people` |
| `session_summary` | with app_quit (or at the next launch) | `ended`, `session_s`, `launch_how`, `started`, `startup` (ready, not_ready, none), `startup_s`, `startups`, `rows`, `rows_ok` (never warn or fail), `rows_bad`, `bad_at_end`, `bad_rows`, `people`, `passes`, `version` |
| `session_row` | one per row that was ever warn or fail | `check`, `title`, `worst`, `bad_s`, `share_pct` (of the session), `whole` (never OK all session), `bad_at_end`, `spells`, `first_bad_s`, `fix_clicks`, `muted`, `cleared_by` (`still_bad` if so), `ended` |
| `log_chunk` | an incident's scrubbed log | `incident`, `part`, `parts`, `t00`… |

  `startup_done` also has `start_state` (`reported`, `none`, `not_listened`: whether Lightkey reported
  the show's start states while it opened), `start_state_msgs` and `start_state_on`. `self_repair`
  `what` adds `lightkey_no_password` and `login_<row>` (`login_selfLogin`, `login_loginShows`,
  `login_deckLogin`, `login_reopen`; `result` ok, not_confirmed or failed).

  **Error reports** go to the dashboard's Errors page (`POST /api/v0/error`, one report per request,
  202 = accepted; kept for later on no answer, 408, 429 or 5xx; dropped on 403, the month's error
  quota, and any other 4xx). Each type goes once a session, at most 10 a session; message and trace
  are scrubbed like everything else; they wait in `aptabase-errors.jsonl`, sent with the events.
  Every report is also a line in the log on disk (`error report <type> …`), diagnostics on or off.

| errorType | severity, kind | When | stackTrace |
|---|---|---|---|
| the exception type (`EXC_BAD_ACCESS`…) | fatal, crash | the launch after a crash: Booth Check's newest crash report (`~/Library/Logs/DiagnosticReports/Booth Check*.ips` or `.crash`) since the crashed run began, with the crashed run's session id | the crashed thread's frames |
| `UncleanExit` | error, unhandled | the launch after an unclean end with no readable crash report (power cut, force quit) | the last 40 lines of that run's log |
| `StartupNotReady` | error, handled | a start-up ends not ready | the Log's last 40 lines |
| `DMXRecoveryFailed` | error, handled | the start-up's DMX recovery ran and Lightkey still didn't take the interface | the same |
| `LightkeyForceQuit` | error, handled | Lightkey had to be made to quit (shutdown, restart) | the same |
| `ShutdownStayedOn` | error, handled | a shutdown stopped and the Mac stayed on | the same |
| `DeckProfileRestoreFailed` | error, handled | a damaged Stream Deck profile couldn't be put back, or broke again | the same |
| `StreamDeckRestoreDialog` | error, handled | Stream Deck is asking whether to restore its backup | the same |
| `CheckFailed:<row id>` | error, handled | a row red (not orange) over a minute outside a start-up: the same moment as its `log_chunk` incident | the same |

  Start-ups aren't counted in the session's rows (rows are red while apps open), nor the shutdown
  once it closes the apps. A shutdown that stops and leaves the Mac on can send a second summary for
  the same session; the later one counts.
- **Switch it off** in This Mac → Booth Check → **Send diagnostics to the developer** (that also
  deletes the queue; the log on disk is still written). **Send now** sends the queue straight away.
- **Save diagnostics…** in the Log window zips scrubbed copies of the logs, the DMX snapshots, the
  queue and a short summary, and offers AirDrop. **Show in Finder** shows the log.
- The Aptabase key isn't in git: `build.sh` reads `aptabase.key` (git-ignored) into the app's
  Info.plist. Built without it, Booth Check sends nothing and says so in the Log.

## Putting it on the booth Mac

It needs nothing installed. It's one universal app for Apple silicon and Intel, macOS 13 or later.

1. Download `Booth.Check.zip` from this repo's latest release, double-click it, and drag
   **Booth Check** into Applications.
2. **First launch only.** It isn't signed with a paid Apple developer account, so macOS says it
   "could not be verified" and won't open it. Current macOS no longer lets right-click → Open get
   past this. Either run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Booth Check.app"
   ```

   or try to open it once, then go to System Settings → Privacy & Security, scroll down, and click
   **Open Anyway**. `docs/Open Booth Check on a new Mac.txt` has the same steps, ready to AirDrop.
3. In **This Mac** (it opens by itself the first time), switch on the apps this Mac runs, plus
   **Stays on for services** and **Start the show when the Mac starts**.
4. Click **Choose show…** and pick the show file this Mac should run.
5. Allow the two permissions when it asks:
   - **System Events** (asked straight away): to read and change what opens at login.
   - **Accessibility** (click *Allow access…* on "The right show is open"): to read which show
     Lightkey has open. Turn Booth Check on in the list, then quit and reopen Booth Check.
6. Under **Start at login**, click **Add to login…** on "Booth Check opens at login", and remove any
   show or Stream Deck entries it points out.
7. Work down Booth Check's list until everything is a tick. Then the settings it can't read:
   - On Apple silicon, Privacy & Security → Allow accessories to connect → **Always** (Intel Macs
     don't have it).
   - The screen saver → **Never**. On macOS 26 it's under **Wallpaper → Screen Saver… → Start Screen
     Saver**, not Lock Screen, and it starts after 20 minutes unless changed; earlier macOS has it in
     Lock Screen. Also Lock Screen → "Require password…" → **Never**. (Booth Check keeps the screen
     awake anyway; this is the backstop.)
   - Control Centre → Focus → **Do Not Disturb** on.
   - The Stream Deck app's own **Launch at login**, off: Booth Check opens it once Lightkey is ready,
     and starting on its own it can beat Lightkey and the keys stay dead.
8. Look after the battery. Always on the charger, an Intel MacBook's battery can swell: turn on
   battery health management (Battery → ⓘ next to Battery Health), and replace it if the case bulges.
9. Install macOS updates between services, never just before one. The password at start-up is
   FileVault unlocking the disk; keep it on.
10. Print `docs/Lighting_SOP.pdf` for the booth: one page for volunteers with starting, finishing and
    what to do when something's wrong.

To quit it, click the menu bar icon, hold **Option** and click **Quit**. To bring the window back, click the icon → Open Booth
Check, or open Booth Check again from Applications.

## Updates

Booth Check asks GitHub for the newest release when it starts, every six hours, and when you click
**Check for updates** at the bottom of the window. When there's a newer version, an **Update to x.y**
button appears in the window and the menu bar dropdown. It shows what's new and every step before
anything happens:

1. Download the release zip from GitHub.
2. Check it against the SHA-256 checksum GitHub publishes for it.
3. Unzip it (`ditto`).
4. Check it's Booth Check at the version offered, with an intact signature (`codesign --verify`).
5. Move the current copy to the Trash and put the new one in its place.
6. Reopen. Since 1.21 every build is signed with the same certificate, so macOS keeps both
   permissions. Before that, each build was new to macOS: the update to 1.21 (or later) from an older
   version needs them once more. In Accessibility, remove the old Booth Check entry with **−**, then
   click **Allow access…** in Booth Check and turn the new one on.

If any check fails, nothing changes, and every step is kept in the Log. The app has to be somewhere
it can write, such as Applications, not run straight from Downloads.

1.0 has no updater, so a Mac on 1.0 needs a newer version installed by hand once.

## Changing the show version

Click **Change…** at the top of the window and pick the new file. Booth Check opens that one from the
next login, and "The right show is open" checks against it straight away.

## Rebuilding

```bash
./build.sh
```

Needs the Xcode Command Line Tools on the Mac doing the build, and nowhere else. The script picks an
SDK the installed Swift compiler accepts, builds arm64 and x86_64, joins them, draws the icon, signs
the app, and zips it. It signs with the **Booth Check Signing** certificate when that's in the Mac's
keychain (a self-signed code-signing certificate, made once on the Mac that releases Booth Check), so
every build has the same signature and macOS keeps Booth Check's permissions across updates. Without
it, the build is signed ad hoc, a new signature each time.

The unit tests cover the check logic that doesn't need a running Mac (the show match, App Nap, the
DMX server, the start-up's waits, the replug animation, the hands-off sign, the shutdown's timing).
They build next to a copy of the app in a temporary folder and change nothing:

```bash
bash tests/run.sh
```

To try the login behaviour without restarting, open it with `--login`:

```bash
open "build/Booth Check.app" --args --login
```

## Releasing an update

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Info.plist`, and commit.
2. Run:

```bash
./release.sh "What changed, in a line or two"
```

It builds, checks the built app carries that version, pushes, and publishes release `v<version>`
with the zip attached. Every copy of Booth Check offers it within six hours, or straight away from
Check for updates.

---

Made by [Fynn Projects](https://www.fynnprojects.com.au), custom apps for church production teams,
trades and small businesses.
