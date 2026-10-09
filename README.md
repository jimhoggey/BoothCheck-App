# Booth Check

A menu bar app that keeps the lighting booth Mac ready for a service. At login it starts the show in
the right order and checks everything; if it's all green it stays out of the way, and if not it opens
its window once so whoever sits down sees what to fix.

## How it behaves

- **Lives in the menu bar.** No Dock icon, not in Cmd-Tab, never takes focus from Lightkey. The icon's
  shape shows the state: a tick when everything's fine, a triangle or cross with a count when
  something needs attention. Click it to see just the problems, **Get the show started**, **Shut
  down the booth**, and **Open Booth Check** for the full window.
- **At login** it runs the start-up in a fixed order, shown as numbered steps in a small panel at
  the top right that floats over everything, full-screen Lightkey included, without taking focus:

  1. Wait for the DMX interface to appear on USB, so Lightkey can attach to it. Usually it's found at
     once and nothing is asked. If it isn't there after 10 seconds, a **big sign in the middle of the
     screen** (over a dimmed backdrop) says to unplug the USB cable from the DMX box and plug it back
     in, with a short animation of exactly that: an interface left plugged in sometimes only shows up
     again that way. The replug is picked up within a second ("Found it"), the wait runs up to 90
     seconds so someone can get to the cable, and **Carry on without it** skips it
  2. Open any other apps, such as ProPresenter
  3. With a Stream Deck: open **Lightkey without the show**, wait for its MIDI input (the Stream
     Deck plugin looks for it when it starts), switch App Nap off if it's on, open **Stream Deck in
     the background**, and give its plugin 10 seconds to connect. Lightkey sends every cue's state
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
  5. Confirm Lightkey has the DMX interface open (experimental)
  6. Without Lightkey on this Mac, Stream Deck opens here instead
  7. Check everything

  After the start-up, **Stream Deck stays open**: when it's switched on in This Mac and its app
  isn't running (switched on just now, Booth Check reopened after an update, or someone quit it),
  Booth Check opens it in the background within 15 seconds, App Nap off first. On a Lightkey Mac it
  waits until Lightkey's MIDI input is there, it tries at most once a minute, and never while a
  start-up or shutdown is opening or closing apps.

  **Stream Deck's keys start clean.** A latch key (a colour, a house level) lights when Lightkey says
  its cue is on but ignores "off", so a key left lit stays lit after Lightkey restarts (Lavender lit
  on the church Mac, 9 Oct 2026). A freshly opened Stream Deck has every key dark: it saves no key
  state. So when the start-up finds Stream Deck already open it restarts it, and when Lightkey is
  started any other way (by hand, after a crash) Booth Check restarts Stream Deck once Lightkey is
  ready (tested: 3 seconds after Lightkey reopened). Quitting Stream Deck yourself does the same:
  Booth Check reopens it clean.

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
| **Stream Deck** | checks the deck is plugged in, its app is open, App Nap is off, and Lightkey is listening for it; opens it once Lightkey is ready |
| **ProPresenter**, or any app added with **Add an app…** | checks it's open, and opens it when the show starts |
| **Stays on for services** | checks the charger, sleep, Low Power Mode, starting from the charger, macOS updates, and what opens at login |
| **Start the show when the Mac starts** | opens the apps above at login, in order, instead of macOS login items doing it all at once; the switch's description says exactly what it will open |
| **Shut down by itself** | at the days and time set under it (Sundays at 1 pm to start with), shuts the booth down if nobody has: see [Shut down the booth](#shut-down-the-booth). Off until switched on |
| **Shut down when the power goes off** | MacBooks only: when the charger loses power, shuts the booth down after a 1-minute warning (see [Shut down the booth](#shut-down-the-booth)). Off until switched on |

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
| Stream Deck | Stream Deck plugged in · Stream Deck app running |
| Power & sleep | on the charger · starts up when the charger is plugged in *(laptops, optional)* · never sleeps on the charger · Low Power Mode off · App Nap off |
| Start at login | Booth Check opens at login · Booth Check starts the show · no show opens on its own · Stream Deck waits for Lightkey (each offers Remove when something else would race it; This Mac also lists anything else macOS opens at login) |
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

**Lightkey asks for the Mac's password** (Authenticate) when it connects to the DMX interface, on
Intel and Apple silicon alike: it unloads the Mac's FTDI driver first. Its hidden setting
`DontUnloadFTDIDrivers` skips that, and on the church Mac with its Open DMX USB the lights work with it
on and nothing asks (tested 9 October 2026). **Lightkey connects without the password** checks the
setting, and **Switch it on…** shows the command (`defaults write de.monospc.Lightkey
DontUnloadFTDIDrivers -bool true`) and its undo before running it. With it on, the start-up's sign
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

**Booth Check keeps itself awake** by opting out of App Nap (`NSAppSleepDisabled` plus a background
activity), so its checks keep running behind full-screen Lightkey. It has no row of its own: nobody
could fix anything there, and whether the Mac stays awake is what the Power & sleep checks are for.

## Get the show started

The green button, in the window header and the menu bar dropdown, runs the same numbered start-up
by hand, in the same floating panel: anything already open is left alone (the show is just brought to
the front). It only opens apps; it changes no settings. Each step is kept in the Log. The hands-off
sign is only for the start-up at login: whoever clicks the button is already at the Mac.

## Shut down the booth

**Shut down the booth**, in the menu bar dropdown, ends the service in one click:

1. A **10-second countdown** comes up in the middle of the screen, with **Not yet** (stops it) and
   **Shut down now**.
2. Behind a "Shutting the booth down" sign, **Stream Deck closes**. It has nothing to save, so if
   it hangs it's made to quit after 5 seconds.
3. **Lightkey closes.** If it asks about saving the show, the sign moves to the bottom of the screen
   and waits for an answer. It never answers for you. If Lightkey is still open after 2 minutes,
   Booth Check stops there and the Mac stays on.
4. **macOS shuts down** (`tell application "System Events" to shut down`). Any other app can still
   say no, and then the Mac stays on and the sign says so.

Closing Stream Deck and Lightkey first also keeps macOS from reopening them at the next login, where
they'd race the start-up. Every step is kept in the Log.

**Shut down by itself** (in This Mac) is the backstop for when nobody remembers. At the set time it
gives a **5-minute** countdown, then does the same. **Not yet** asks again in half an hour. It only
goes off within half an hour of the set time, so a Mac that was off or asleep then doesn't shut down
the moment it comes back, and it waits for a running start-up to finish.

**Shut down when the power goes off** (in This Mac, MacBooks only) does the same when the charger
loses power while Booth Check is running: a **1-minute** countdown, which stops by itself if the power
comes back (a bumped plug), or with **Not yet** (then it doesn't ask again until the power comes back
and goes off once more). A Mac started on battery on purpose is left alone. Together with **Starts up
when the charger is plugged in**, one switched socket or smart plug turns the whole booth on and off.
macOS has no setting for this on a MacBook's own battery; its power-cut shutdown is only for a UPS.

## Nothing runs behind your back

- **Checks only read.** Every command a check runs is listed in the **Log** (⌘L) with its output.
  It's the same short list each time, repeated every 15 seconds.
- **Changes wait for you.** A button that changes something (turn App Nap off, add Booth Check to
  login, remove something from login) first shows the exact Terminal command or AppleScript, and runs
  it only when you press **Run**. The output appears straight away, and the change is kept in the
  Log. App Nap also shows the command that undoes it.
- **No admin password.** Anything that would need it, such as switching sleep off, opens the right
  page of System Settings instead and says which setting to change.

Other buttons only open things: the show, the Stream Deck app, or a page of System Settings. The one
exception is **Shut down the booth**, which closes Stream Deck and Lightkey and shuts the Mac down
once its countdown runs out (**Not yet** stops it). Its timed version only runs if it's switched on
in This Mac. Both keep every step in the Log.

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
   - Lock Screen → screen saver and "Require password…" → **Never**.
   - Control Centre → Focus → **Do Not Disturb** on.
   - The Stream Deck app's own **Launch at login**, off: Booth Check opens it once Lightkey is ready,
     and starting on its own it can beat Lightkey and the keys stay dead.
8. Look after the battery. Always on the charger, an Intel MacBook's battery can swell: turn on
   battery health management (Battery → ⓘ next to Battery Health), and replace it if the case bulges.
9. Install macOS updates between services, never just before one. The password at start-up is
   FileVault unlocking the disk; keep it on.
10. Print `docs/Lighting_SOP.pdf` for the booth: one page for volunteers with starting, finishing and
    what to do when something's wrong.

To quit it, click the menu bar icon → Quit. To bring the window back, click the icon → Open Booth
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
