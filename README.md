# Booth Check

One window that says whether the lighting booth Mac is ready for a service, and what to do about
anything that isn't. It checks every 15 seconds while it's open.

| Group | Checks |
|---|---|
| Lighting | DMX interface plugged in · Lightkey running · the right show open · Lightkey's MIDI input ready for the Stream Deck |
| Stream Deck | Stream Deck plugged in · Stream Deck app running |
| Power & sleep | on the charger · never sleeps on the charger · Low Power Mode off · App Nap off |
| Start at login | the right show opens at login, and no older one · Stream Deck app opens at login · the full list of what opens at login |
| Updates | macOS won't install updates by itself |
| Check these yourself | USB accessories allowed without asking · no password after idle (macOS doesn't let apps read these two) |

## Nothing runs behind your back

- **Checks only read.** Every command a check runs is listed in the **Log** (⌘L) with its output.
  It's the same short list each time, repeated every 15 seconds.
- **Changes wait for you.** A button that changes something (turn App Nap off, make the chosen
  show the only one that opens at login, add the Stream Deck app to login) first shows the exact
  Terminal command or AppleScript, and runs it only when you press **Run**. The output appears
  straight away, and the change is kept in the Log. App Nap also shows the command that undoes it.
- **No admin password.** Anything that would need it, such as switching sleep off, opens the right
  page of System Settings instead and says which setting to change.

Other buttons only open things: the show, the Stream Deck app, or a page of System Settings.

## Putting it on the booth Mac

It needs nothing installed. It's one universal app for Apple silicon and Intel, macOS 13 or later.

1. Download `Booth.Check.zip` from this repo's latest release (or copy `build/Booth Check.zip`),
   double-click it, and drag **Booth Check** into Applications.
2. **First launch only:** right-click Booth Check → Open → Open. It isn't signed with a paid Apple
   developer account, so a plain double-click the first time gets "can't be opened". If there's no
   Open button, go to System Settings → Privacy & Security, scroll down, and click **Open Anyway**.
3. Click **Choose show…** and pick the show file this Mac should run.
4. Allow the two permissions when it asks:
   - **System Events** (asked straight away) — to read and change what opens at login.
   - **Accessibility** (click *Allow access…* on "The right show is open") — to read which show
     Lightkey has open. Turn Booth Check on in the list, then quit and reopen Booth Check.

To have it greet whoever sits down, add Booth Check itself to Login Items.

## Updates

Booth Check asks GitHub for the newest release when it opens, every six hours while it's open, and
when you click **Check for updates** (bottom of the window, or the Booth Check menu). When there's a
newer version an **Update to x.y** button appears. It shows what's new and every step before
anything happens:

1. Download the release zip from GitHub.
2. Check it against the SHA-256 checksum GitHub publishes for it.
3. Unzip it (`ditto`).
4. Check it's Booth Check at the version offered, with an intact signature (`codesign --verify`).
5. Move the current copy to the Trash and put the new one in its place.
6. Reopen. macOS asks for the two permissions again, because it's a new build.

If any check fails, nothing changes, and every step is kept in the Log. The app has to be somewhere
it can write, such as Applications, not run straight from Downloads.

1.0 has no updater, so a Mac on 1.0 needs 1.1 installed by hand once.

## Changing the show version

Click **Change…** at the top and pick the new file. "The right show opens at login" goes red; click
**Make it the login show** and the old version is removed from login and the new one added.

## Rebuilding

```bash
./build.sh
```

Needs the Xcode Command Line Tools on the Mac doing the build, and nowhere else. The script picks an
SDK the installed Swift compiler accepts, builds arm64 and x86_64, joins them, draws the icon, signs
the app ad hoc, and zips it. Rebuilding changes the app's signature, so macOS asks for the two
permissions again.

## Releasing an update

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Info.plist`, and commit.
2. Run:

```bash
./release.sh "What changed, in a line or two"
```

It builds, checks the built app carries that version, pushes, and publishes release `v<version>`
with the zip attached. Every copy of Booth Check offers it within six hours, or straight away from
Check for updates.
