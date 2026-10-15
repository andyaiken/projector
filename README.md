# Prospect

Prospect is a native macOS app for running projections in live theatre. Text decrypts out of ciphertext, scene images turn into place tile by tile, and video clips play. An operator fires cues from a console on the Mac's own display while the projector window runs full-screen on a second display.

[spec.md](spec.md) is the source of truth for behaviour and for every decision taken so far. This README covers building, testing and finding your way around the code.

## Status

All seven phases of the build are done, along with show defaults, per-cue overrides and Preferences. Everything that can be checked without a person at the keyboard has been: unit tests, offscreen renders, printed PDFs read back, and a scripted Save and reopen round trip.

These have not been checked yet:

- a real projector and a second display, including unplugging and replugging it during a show
- interactive flows: the recovery panel for a damaged show, resuming after a crash, and dragging media onto cues
- ProRes clips, and clips with audio

Book projector time early. The spec explains why under Build and distribution.

## Requirements

- Xcode 27 with Swift 6.4. The code builds under strict concurrency with no warnings, and should stay that way.
- macOS 26 or later to run it. The booth Mac runs macOS 27.

## Building and running

Open `Prospect.xcodeproj` and run the Prospect scheme (⌘R). From the command line:

```bash
xcodebuild -project Prospect.xcodeproj -scheme Prospect -derivedDataPath DerivedData build
```

```bash
open DerivedData/Build/Products/Debug/Prospect.app
```

On first launch Prospect opens a new, empty show. To try it:

1. A new show opens in edit mode. Add cues with Add Cue in the header or from the Edit menu; the tabs are Cue, Cue Settings, Show and Projection Area.
2. Choose Show › Enter Show Mode, then Show › Open Projector.
3. Press Space to fire the standby cue.

| Key | In show mode |
| --- | --- |
| Space | Fire the standby cue. Nothing else fires a cue |
| → ↓ PageDown, ← ↑ PageUp | Stand by the next or previous cue |
| 0–9 and `.`, then Return | Stand by a cue by number |
| R | Run the live cue again |
| B | Blackout |

Entering and leaving show mode is deliberately done from the menu only, with no shortcut. The spec explains why.

## Repository layout

```
spec.md                      the specification and every decision taken
Prospect.xcodeproj           the app project and its shared scheme
Config/Prospect-Info.plist   document type and the .prospect UTI
Prospect/                    the app: AppKit windows, menus, documents
  AppIcon.icon               the app icon, an Icon Composer document
ProspectCore/                a Swift package with two libraries
  Sources/ProspectCore       the show model; no AppKit
  Sources/ProspectStage      the renderers and the show controller; no windows
  Tests/                     tests for both, including recorded outputs
tools/package.sh             builds the zip and disk image for another Mac
```

The split follows the spec's architecture, in three layers:

- **ProspectCore** is plain logic: the cue and show model, the cipher and decryption reveal, tile schedules, numbering, the playhead, the tick clock, the `.prospect` package format and the cue sheet rows. Its tests compare its output exactly against recorded outputs.
- **ProspectStage** paints cues into Core Animation layer trees and runs the show. Its pieces:
  - `SurfaceLayer`: a surface to paint into.
  - One renderer per cue kind: `TitleRenderer`, `ImageRenderer`, `VideoRenderer` and `BlankRenderer`, all conforming to `CueRenderer`.
  - `StageRunner`: drives the renderers on every tick.
  - `ShowController`: the keys, the playhead, modes and editing.
  - `ProjectorState`: where the projector window goes.
  - `CueSheetView`: prints the cue sheet.

  None of it needs a window, so its tests render offscreen.
- **Prospect**, the app, holds only what needs AppKit. Its main files:
  - [ShowDocument.swift](Prospect/ShowDocument.swift) and [DocumentController.swift](Prospect/DocumentController.swift): the document, with one show open at a time.
  - [ConsoleWindow.swift](Prospect/ConsoleWindow.swift): the console window.
  - [Projector.swift](Prospect/Projector.swift): the projector window and display handling.
  - [SettingsPanels.swift](Prospect/SettingsPanels.swift) and [ConsoleEditor.swift](Prospect/ConsoleEditor.swift): the editing panels.
  - [ProspectApp.swift](Prospect/ProspectApp.swift): launch, menus and the crash record.

### How a cue gets on screen

`TickClock` counts logical frames. A display link samples it, from the projector's screen when the projector is open and from the console's otherwise, and `StageRunner.tick` asks the live renderer to paint that frame.

The projector window and the console's live preview are both surfaces. A renderer paints every surface from one shared plan, so any randomness is rolled once per frame and the two surfaces never disagree. Only `VideoRenderer` treats the two differently: the preview shows a poster and a position readout instead of a second player.

`ShowController` owns the `Playhead`. Its model is standby and live: only GO puts a cue on stage, and a cue marked to follow fires when the one before it settles.

In edit mode, every change goes through `ShowController.edit`. That makes it one undo step, and slider drags are merged into a single step. If the cue on stage is affected, it is redrawn in its finished state.

## Tests

The two package test targets hold all the tests. To run them, use either:

```bash
cd ProspectCore && swift test
```

```bash
xcodebuild -project Prospect.xcodeproj -scheme Prospect test
```

Set `PROSPECT_SNAPSHOTS` to a folder and the stage tests write PNGs of what they rendered:

```bash
cd ProspectCore && PROSPECT_SNAPSHOTS=/tmp/stage swift test
```

### Recorded outputs

The JSON files in `ProspectCore/Tests/ProspectCoreTests/Fixtures/` are known-good outputs: cipher text, reveal timing, tile schedules and numbering, each from a seeded run. The tests replay the same seeds with `SeededRandom` and compare exactly, so anything that would change what the audience sees fails a test. If a change to one of them is deliberate, update the recorded values with it.

## Debug tools

Debug builds accept two launch arguments. Both are for checking the app without a second display or anyone at the keyboard. Each one does its job and quits.

```bash
DerivedData/Build/Products/Debug/Prospect.app/Contents/MacOS/Prospect -ProspectSnapshot /tmp/console
```

This renders the console offscreen in several states (show mode, an image turning, edit mode, the settings tabs, the Settings window) and writes the PNGs to the folder.

```bash
DerivedData/Build/Products/Debug/Prospect.app/Contents/MacOS/Prospect -ProspectDocumentCheck /tmp/documents
```

This takes a show through importing media, Save As, Save and reopening, with a check at each step, and writes PASS or FAIL lines to `result.txt` in the folder.

## The app icon

`Prospect/AppIcon.icon` is a layered Icon Composer document, so macOS 26 draws it with Liquid Glass and makes the dark, clear and tinted versions itself. It shows a projection screen of tiles caught in an image cue's diagonal sweep, upstage of a perspective floor: the tiles that have turned are bone, the diagonal that is turning is brass, and the rest are still slate. These are the console's own colours.

Each layer is an SVG in `Assets/`. Open the document in Icon Composer, which comes with Xcode, to change it. To render it from the command line:

```bash
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Prospect/AppIcon.icon --export-image --output-file /tmp/icon.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

## The show document

A show is a `.prospect` package that behaves as one file in Finder:

```
DaVinciCode.prospect/
  show.json    the cue sheet, show defaults, geometry and projector display
  media/       every image and clip, copied in on import
  version      the format version
```

`show.json` is readable JSON, so a show can be diffed in a repository and repaired by hand if it ever has to be. Prospect autosaves in place and keeps versions with macOS's version history. If a show won't open, the file is left untouched and Prospect offers to restore an earlier version. A show saved by a newer version of Prospect is refused rather than rewritten. See [ShowPackage.swift](ProspectCore/Sources/ProspectCore/ShowPackage.swift).

## Copying to another Mac

```bash
tools/package.sh
```

This builds a Release copy from clean and writes two packages to `dist/`. Either one carries the app intact on a thumb drive:

- `Prospect-<version>.zip`
- `Prospect-<version>.dmg`, a disk image that opens to the app beside a link to Applications

The app runs on Intel and Apple silicon Macs with macOS 26 or later. On the other Mac, drag Prospect into Applications and open it. Keep shows on that Mac's internal disk, not on the stick.

### Gatekeeper

Until it is notarised, the app is signed ad hoc, and Gatekeeper rejects it. That only matters when macOS has marked a copy as coming from the internet:

- **Copied from a thumb drive in Finder:** normally not marked, so it opens straight away.
- **Downloaded, emailed or AirDropped:** marked, so macOS blocks it until it is allowed with Open Anyway in System Settings › Privacy & Security.

### Notarising

A notarised app opens on any Mac with no warnings, however it got there. To notarise as well as package:

```bash
tools/package.sh --notarise
```

With `--notarise`, the script:

- signs the app with the team's Developer ID (team `3G846V4G68`)
- sends it to Apple and waits for the result, which usually takes a few minutes
- staples the result to the app
- signs, notarises and staples the disk image in the same way

If Apple refuses either one, the script prints Apple's log and stops.

Each Mac that notarises needs two things, set up once. Andy's Mac has both.

1. **The Developer ID Application certificate in its keychain.** To add it, sign in to the team in Xcode, go to Settings › Accounts, then Manage Certificates… › + › Developer ID Application. Only the account holder can create one.
2. **The notarisation password, saved as the `prospect-notary` profile.** Make an app-specific password at [account.apple.com](https://account.apple.com), under Sign-In and Security › App-Specific Passwords. Then run this command, which asks for the password and keeps it in the keychain:

   ```bash
   xcrun notarytool store-credentials prospect-notary --apple-id <your Apple ID> --team-id 3G846V4G68
   ```

The script checks both before it builds anything, and says which one is missing. `PROSPECT_SIGN_IDENTITY` and `PROSPECT_NOTARY_PROFILE` override the certificate and the profile it uses.

## Before the first real show

- Package the copy for the booth Mac with `tools/package.sh --notarise`.
- Run the booth checklist in spec.md, under Booth Mac setup: the console is the main display, a Focus mode is on, the projector's wallpaper is black, automatic updates are off and the show runs from the internal disk.
