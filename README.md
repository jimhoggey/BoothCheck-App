# Booth Check

A menu bar app that keeps the lighting booth Mac ready for a service. At login it starts the show in
the right order and checks everything; if it's all green it stays out of the way, and if not it opens
its window once so whoever sits down sees what to fix.

## How it behaves

- **Lives in the menu bar.** No Dock icon, not in Cmd-Tab, never takes focus from Lightkey. The icon's
  shape shows the state: a tick when everything's fine, a triangle or cross with a count when
  something needs attention. Click it to see just the problems, **Get the show started**, and
  **Open Booth Check** for the full window.
- **At login** it opens the chosen show in Lightkey, waits for Lightkey's MIDI input, then opens the
  Stream Deck app, in that order, then checks everything. If anything needs attention it opens its
  window once. After that it never pops up during a service; only the icon changes.
- **Opened by hand**, it shows the window straight away.
- **Checks every 15 seconds** in the background, window open or not.

Starting the show at login can be switched off in the window ("Start the show when the Mac starts").
Then it only checks, and expects the show and Stream Deck to be login items themselves.

## What this Mac does

Not every Mac is the booth. **This Mac** (in the window's header) asks what this one is for, with a
switch for each part of the rig:

| Switch | Checks it covers |
|---|---|
| Lightkey runs the show on this Mac | Lightkey running, the right show open, Get the show started |
| A DMX interface is plugged into this Mac | the interface connected, Lightkey using it |
| A Stream Deck controls Lightkey here | the deck and its app, Lightkey's MIDI input, App Nap, opening Stream Deck after Lightkey |
| This Mac stays on for services | charger, sleep, Low Power Mode, starting from the charger, macOS updates, what opens at login |

Two presets fill them in: **Booth Mac** (everything) and **Lightkey only** (building shows with no
hardware attached). The first time the window opens, the sheet appears already filled in from what
Booth Check finds: with the Stream Deck app installed it guesses Booth Mac, otherwise Lightkey only.

Any single check can also be **muted** with the 🔕 button on its row (or right-click). Muted checks
stay listed under "Muted on this Mac" with an Unmute button.

Nothing is hidden quietly: the header and the menu bar dropdown always say "N checks off for this Mac
· N muted", and every change is kept in the Log. When the Stream Deck app isn't installed at all, its
row offers **No Stream Deck on this Mac**. The DMX interface deliberately has no such shortcut: at a
service, a cable falling out looks exactly like a Mac without one, so it can only be switched off in
the sheet.

## What it checks

| Group | Checks |
|---|---|
| Lighting | DMX interface plugged in · Lightkey running · the right show open · Lightkey sending DMX *(experimental)* · Lightkey's MIDI input ready for the Stream Deck |
| Stream Deck | Stream Deck plugged in · Stream Deck app running |
| Power & sleep | on the charger · starts up when the charger is plugged in *(laptops, optional)* · never sleeps on the charger · Low Power Mode off · Booth Check itself stays awake · App Nap off |
| Start at login | Booth Check opens at login · Booth Check starts the show · no show opens on its own · Stream Deck waits for Lightkey · the full list of what opens at login, each with a Remove button |
| Updates | macOS won't install updates by itself |
| Check these yourself | USB accessories allowed without asking · no password after idle (macOS doesn't let apps read these two) |

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

**Lightkey sending DMX** is experimental. An app can't see the DMX signal, but it can see whether
Lightkey has the interface open: macOS records which app opened each USB driver connection
(`ioreg`), and `lsof` lists the serial ports Lightkey holds. Either one counts. If the lights respond
and this row disagrees, trust the lights.

**Booth Check stays awake** because it opts out of App Nap (`NSAppSleepDisabled` plus a background
activity). It proves it by timing its own 15-second checks, and warns if a gap ever passes a minute
while the Mac was awake.

## Get the show started

The green button, in the window header and the menu bar dropdown, does by hand what login does: opens
the chosen show in Lightkey (or brings it to the front), waits up to 30 seconds for Lightkey's MIDI
input, then opens the Stream Deck app if it isn't open. It only opens apps; it changes no settings.
What it did is shown and kept in the Log.

## Nothing runs behind your back

- **Checks only read.** Every command a check runs is listed in the **Log** (⌘L) with its output.
  It's the same short list each time, repeated every 15 seconds.
- **Changes wait for you.** A button that changes something (turn App Nap off, add Booth Check to
  login, remove something from login) first shows the exact Terminal command or AppleScript, and runs
  it only when you press **Run**. The output appears straight away, and the change is kept in the
  Log. App Nap also shows the command that undoes it.
- **No admin password.** Anything that would need it, such as switching sleep off, opens the right
  page of System Settings instead and says which setting to change.

Other buttons only open things: the show, the Stream Deck app, or a page of System Settings.

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
3. In **What does this Mac do?**, pick **Booth Mac** (it appears the first time; later it's under
   **This Mac**).
4. Click **Choose show…** and pick the show file this Mac should run.
5. Allow the two permissions when it asks:
   - **System Events** (asked straight away): to read and change what opens at login.
   - **Accessibility** (click *Allow access…* on "The right show is open"): to read which show
     Lightkey has open. Turn Booth Check on in the list, then quit and reopen Booth Check.
6. Under **Start at login**, click **Add to login…** on "Booth Check opens at login", and remove any
   show or Stream Deck entries it points out.

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
6. Reopen. macOS asks for the two permissions again, because it's a new build.

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
the app ad hoc, and zips it. Rebuilding changes the app's signature, so macOS asks for the two
permissions again.

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
