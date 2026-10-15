# Prospect — Specification

Oct 14, 2026 · @Andy

## Purpose

Prospect is a native macOS application for running projections in live theatre. Title cards resolve out of ciphertext, scene images flip into place tile by tile, and an operator fires cues from a console while a projector window runs full-screen on a second display.

It is a full rewrite in Swift and AppKit, not a wrapper around the existing HTML prototype. The production has months of lead time and access to the rig, which makes the rewrite both affordable and better: Core Animation, Core Text and `CVDisplayLink` do this work more precisely than a browser can, and two of the three cue renderers are simpler in native code than they are in CSS.

The existing HTML prototype is the reference implementation. It runs the show today, its behaviour has been debugged in practice, and the specification below describes the same behaviour unless it explicitly says otherwise. Where a decision was already made and tested there, it says so and should not be reopened without discussion.

## Decisions taken

Four questions were settled before this document was written, and they define its scope.

| Question | Answer | Consequence |
| --- | --- | --- |
| Booth machine | A Mac the production owns | macOS only; no Windows path is specified |
| Build approach | Full native rewrite | No web view, no JavaScript, no bridge |
| Show storage | Openable documents on disk | `NSDocument` package format, standard Save and Open |
| Native capabilities wanted | Printable cue sheet only | No MIDI, OSC, Syphon, NDI or machine-to-machine sync in scope |

The fourth answer removes the three largest optional pieces of work. The second is the significant one, and it was taken on the basis of lead time: with months before the show and real access to the projector, the rewrite is affordable. The cost it accepts is set out under Build and distribution.

### Constraints carried over from the prototype

These were established while building and running the HTML prototype, and hold without change. Breaking any of them breaks the show.

- **The projector output is black.** Not near-black. Anything else is light spilling onto a set.
- **Nothing reaches the projector that is not a cue.** Alignment guides already switch themselves off when entering show mode; the native app must not introduce overlays, update prompts or notifications that can appear on that screen.
- **Monospace glyphs must share an advance width.** The title reveal rotates characters in place; a substituted glyph of a different width makes the line shiver. The existing runtime width check stays.
- **Cue numbers are stable identifiers, not positions.** The DSM writes them in the prompt book. Inserting a cue must never renumber its neighbours.
- **One operator, one machine, one keyboard.** LX, sound and projection are three separate operators, so no cross-application focus handling is needed.

## Architecture

Three layers. A pure model with no AppKit dependency, a renderer protocol with one conformer per cue type, and the AppKit views.

The layering is inherited from the prototype, where it proved its worth: adding the blank cue type took twenty lines and touched nothing generic. Keep it.

### The renderer protocol

```swift
protocol CueRenderer: AnyObject {
    var isInstant: Bool { get }          // skips the hold; blank cues are instant
    func mount(on surface: SurfaceLayer)  // called once per surface
    func clear(_ surface: SurfaceLayer)   // wipe stale state before a cue loads
    func prepare(_ cue: Cue)              // compute the shared plan once
    func frame(_ f: Int) -> Bool          // paint all surfaces; true when settled
    func fit(_ surface: SurfaceLayer)     // geometry changed
}
```

Four conformers: `TitleRenderer`, `ImageRenderer`, `VideoRenderer` and `BlankRenderer`. Adding a fifth means writing one class and adding one case. Nothing generic is touched.

`VideoRenderer` is the one that strains the contract. It does not resolve over a frame count, it plays; it satisfies `frame(f)` by reporting whether its player has reached the end, and it is the only renderer that does not paint every surface identically. See Video cues.

`clear` exists because of a bug found in the prototype: tiles from the previous image cue stayed face-up while the next image loaded. It is called on **every** renderer before a cue prepares, not just the incoming one.

### Surfaces, not windows

A *surface* is any layer tree a cue paints into: the projector window's, and the console's live preview. Renderers never know which is which.

Anything random within a frame, such as the loose glyphs during a reveal or the tile order, is computed **once per frame** and applied to every surface. The prototype learned this the hard way; two surfaces each rolling their own dice visibly disagree.

Each surface is a black `CALayer` filling the output, containing an inset surface layer sized by percentage geometry. Renderers measure the inset layer, never the output.

## Windows and displays

Two windows: the console and the projector. Both are real `NSWindow`s, which removes pop-up blocking as a failure mode and gives precise control over placement, window level and collection behaviour.

### Console window

Standard resizable window on the operator's screen. Its title shows the show name and the current cue number. It holds the cue list, the standby panel, GO, the keyboard reference and a live preview of the projector, rendered by the same renderers into a second surface.

### Projector window

Borderless, no title bar, black background, cursor hidden, not movable by the operator. It goes full-screen on a chosen display and stays there.

- The display is picked by name in a menu, not by dragging a window onto it.
- The choice is stored in the show document, so opening the show on the same rig restores it.
- It opens on the display it was last on. If that display is gone, it opens on the console's display in a window rather than full-screen, and the console says so plainly.
- `NSWindow.collectionBehavior` keeps it out of Mission Control and Spaces switching, so a trackpad gesture cannot pull it away mid-show.

### Display disconnect during a performance

The realistic failure is a knocked HDMI cable. When the projector display disappears, the app must not quit, must not lose its place, and must not throw a dialog onto the remaining screen.

It holds the current cue in memory, shows a clear warning in the console, and restores the projector full-screen on the same display automatically if it comes back. The operator should be able to carry on pressing GO throughout, so the show is in the right state whenever the picture returns.

## Cue types and rendering

Four cue types, each a `CueRenderer`. Two of them are markedly simpler in native code than in the browser, which is a large part of why the rewrite is worth doing.

### Title cues

A place name resolves out of Vigenere ciphertext, character by character, over a 45-glyph ring: A to Z, 0 to 9, `/!?[],.-` and the space. Each character rolls backwards through the ring from its ciphertext glyph to its plaintext one.

Rules carried over from the prototype, all of which were arrived at by watching it run:

- A character whose shift is short gets a burst of random glyphs first, then rotates home. Every glyph moves for at least 16 frames. An extra full turn of a 45-glyph ring was tried and looked uneven against longer shifts.
- An unresolved space draws as `U+2423 OPEN BOX`; a settled one is a real gap. The marker hides word boundaries during the reveal while leaving the final line readable.
- Characters warm from cold slate to bone as they travel, so meaning arriving is visible per character.
- The Vigenere key drives the ciphertext and is **never displayed**.

Core Text replaces the DOM here, and improves it. Lay out each character as its own positioned glyph using `CTFontGetAdvancesForGlyphs`, with a monospace font bundled in the app. Glyph coverage can then be asserted at build time rather than measured against an `M` at launch and hoped for. The width-shiver failure mode disappears.

Beneath the title sits a live letter-frequency histogram against expected English frequency, with `solved`, `key length` and chi-squared readouts. Chi-squared falls as the text resolves, which is what makes it read as cryptanalysis rather than decoration. The bars are scaled against the settled text, not the current frame, and the first paint of a cue lands without animation.

### Image cues

A photograph arrives as a grid of flipping tiles, four to twenty-eight across.

This is what Core Animation is for. One `CALayer` per tile, `transform.rotation.y` driven by a `CABasicAnimation`, `isDoubleSided` false on each face, and `m34` on the sublayer transform for perspective. Around eighty layers is trivial and GPU-composited, so it will run more smoothly than the CSS version does.

- The unflipped face carries the **average colour of the image behind it**, pulled two-thirds toward the cold slate. Draw the image once into a `CGContext` at exactly the grid dimensions and read the bytes: one averaged pixel per tile, in one call. No cross-origin problem, no tainted canvas, no fallback path.
- Order is a diagonal sweep or random, selectable. Random shuffles the order and paces the starts evenly; independent random starts look like rainfall, with clumps and stragglers.
- Both orders span the same duration, so switching does not change cue timing.
- The flip is an animation with its own duration; the clock only triggers each tile.

### Video cues

Moving footage. Unlike the other three, a video cue does not *resolve* — it plays. That difference reaches into the architecture, so it is set out here rather than treated as a fourth variation.

**What video breaks.** The `CueRenderer` contract assumes a renderer paints every surface identically from one frame number. Video cannot. An `AVPlayer` drives a single `AVPlayerLayer`, so the same clip cannot be shown live on the projector and in the console preview without either decoding it twice or routing frames by hand through `AVPlayerItemVideoOutput`.

**The decision: don't.** The projector gets the video. The console preview shows a poster frame with elapsed and remaining time, not a moving picture. That is better for the operator as well as cheaper — at preview size a moving image tells them nothing, while a countdown to the end of the clip tells them exactly when to stand by.

**Audio is muted, always.** A video cue plays its video track and mutes its audio track unconditionally, with no per-cue setting. Sound is a separate operator on a separate machine running QLab; two systems playing into the same room is a failure the first time it happens, and a switch that permits it is the switch that gets left on by accident. If a clip's audio is wanted, it is pulled out and given to sound as a QLab cue.

**Arming.** `AVPlayer` needs time to load and buffer, and a clip that stutters on GO is unacceptable. The next video cue in the sheet is prepared as soon as the current cue settles: asset loaded, first frame decoded, player paused at zero. GO then starts an already-ready player. The standby panel shows whether the next video cue is armed, and says so plainly if it is not.

**Its own clock.** `AVPlayer` keeps its own time base. It is not driven from the `CVDisplayLink`; the display link only polls its position for the readouts. Do not try to make the two agree.

**End behaviour**, set per cue:

| Setting | On reaching the end |
| --- | --- |
| Hold | Freeze on the last frame (default) |
| Black | Cut to black, as a blank cue |
| Loop | Repeat until the next cue fires |
| Follow | Fire the next cue automatically |

**Follow is new machinery.** Auto-follow was previously out of scope, and video drags it in: a clip that must hand straight to a title card cannot wait for a human. Once it exists it belongs to the cue model rather than to video cues, and the printed cue sheet must mark followed cues clearly — a cue the operator does *not* press GO for is exactly the kind of thing a prompt book gets wrong.

**Files.** ProRes 422 preferred: it decodes cheaply, seeks reliably and survives being re-cut. H.264 and HEVC are accepted, with the caveat that long-GOP seeking is slower and in-point accuracy suffers.

### Video files are imported

**Decided: video is copied into the package, like images.** The clips planned are not large, and anything that ever is moves on a thumb drive — which is how the document travels between machines in any case.

That keeps one rule for all media. A show stays a single object that cannot lose half of itself in a move, and there is no second code path for missing or relinked media to get wrong on a get-in day.

Two notes for the build. Import copies the file as it stands and never re-encodes, so whatever the edit exported is what plays. And on APFS a Duplicate clones unchanged files rather than copying their bytes, so duplicating a show and keeping version history stay cheap even when the package runs to several gigabytes.

### Blank cues

A flat colour, black by default, selectable per cue. Instant: it declares `isInstant` and skips the hold.

Distinct from the blackout key, deliberately. Blackout is an override you toggle back when something has gone wrong. A blank cue is a planned point in the sheet that the operator advances into like any other. The operator should never reach for the panic control to make a scheduled scene change.

## Timing, power and interruption

The clock is a `CVDisplayLink` bound to the projector's display, so frames advance on that screen's actual refresh. This is strictly better than the browser, where `setInterval` is throttled to roughly 1 Hz whenever the window is backgrounded or occluded, silently, with the first symptom appearing during a performance.

The cue clock counts frames, as the prototype does. At 60 Hz a frame is 16.7 ms rather than the 44 ms the prototype uses, so every stored frame count must be scaled on import, and the reveal timings should be re-dialled on the real projector rather than assumed to transfer.

| Concern | Handling |
| --- | --- |
| Display sleep and screensaver | `IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoDisplaySleep`, held while a show document is open, not only while a cue runs |
| Notifications over the projector | Do Not Disturb enabled while the projector window is live, restored on quit |
| Automatic updates | None. The app updates only when someone chooses to |
| Projector refresh differs from console | The display link follows the projector; the console preview is repainted from the same frame number |

The power assertion covers the whole document, not the running cue. The gap between cues in a quiet scene can be twenty minutes, well inside any default sleep timer.

### Quitting during a show

**Decided: warn.** While the projector window is live, Quit presents a confirmation sheet. It appears on the console, never on the projector, and the projector keeps showing its current cue while the sheet is up.

The sheet is dismissible with Escape and its default button is Cancel, so a reflexive Return does not quit. Closing the console window does the same thing rather than quitting silently.

## The show document

A show is a file bundle with the extension `.prospect`, registered as an `NSDocument` package. It behaves as one file in Finder, can be copied to a USB stick, emailed, or committed to a repository.

```
DaVinciCode.prospect/
  show.json          cue sheet, settings, display choice
  media/             every image and clip, copied in on import
    louvre-gallery.jpg
    rosslyn-pillar.jpg
    cryptex-reveal.mov
  version            format version integer
```

A package rather than a single file because media must travel with the show. A show that references pictures on someone's Desktop is a show that breaks on the second machine.

### show.json

A `Codable` encoding of the model. JSON rather than a binary format so it can be diffed in a repository and repaired by hand if it ever has to be.

- `version` so a future format change can migrate rather than fail
- `cues` every field in the cue model, including the video end behaviour and the follow flag
- `settings` as now, plus the projector display identifier
- `title` for the window and the printed cue sheet header

### Saving

Standard Save, Save As and Duplicate. Autosave in place, with macOS version history so a cue deleted on the Tuesday can be recovered on the Wednesday.

One exception, **decided rather than assumed: autosave is suspended in show mode.** During a performance the document is not written to at all. Changes made in show mode live in memory and are discarded on close, and the console says so on entering the mode. The trade is accepted knowingly: a genuine fix made during a performance is lost, and should be made again in edit mode afterwards.

### Recent documents

Standard Open Recent. The app opens the most recent show on launch, so the operator's first action on the night is pressing GO rather than finding a file.

## Images

Images are imported, not linked. Dragging a file onto an image cue, or choosing one through an open panel, copies it into the document package's `media/` folder and stores a relative path. The original can then be moved or deleted without breaking the show.

### What the rewrite fixes

In the browser, a local image taints the canvas, so reading pixels back to compute tile colours throws. The prototype catches this and falls back to flat slate, losing the colour-blocked opening state that makes the reveal work.

Natively the problem does not exist. `CGContext` reads any image the app can open. The average-colour faces work with real photographs exactly as they do with generated placeholders, with no special case and no fallback path to maintain.

This is the one place where going native is visibly better on stage rather than merely more reliable.

### Handling

- Accept anything `NSImage` opens: JPEG, PNG, HEIC, TIFF.
- Downscale on import to twice the projector's resolution. A 48-megapixel phone photograph in a tile grid is wasted memory.
- Keep the file's name, de-duplicated on collision.
- An image cue with no file uses a generated placeholder, drawn deterministically from the cue name, so the sheet can be built and timed before the photographs exist.
- Removing an image from a cue leaves the file in the package. A **Remove unused media** menu command cleans up, rather than deleting where an undo would be expected.
- Decode on a background queue and cache the tile faces. A cue must never stall the clock while it loads.

## The printable cue sheet

The one capability requested beyond running the show. It exists so the DSM can transcribe projection cues into the prompt book without copying eighteen rows off a screen by hand, which is how errors get into the book.

Print and Export as PDF, both through `NSPrintOperation` over a custom `NSView` that paginates the cue list. Drawn from the same model the show runs from, so the sheet cannot disagree with what fires.

### Contents

One row per cue, in running order:

| Column | Holds |
| --- | --- |
| Cue | The cue number, as set. Right-aligned, tabular figures |
| Type | Title, Image, Video or Blank. A cue fired automatically by the one before it is marked FOLLOW here |
| Content | Place and city, image label and caption, or the blank's colour |
| Cue point | The line or action the operator is waiting for |

### Layout rules

These are not cosmetic. A cue sheet is read on a music stand under a single lamp.

- Portrait A4 and US Letter, black on white, no dark theme.
- At least 11 pt body text. The cue number larger and bolder than anything else in its row.
- Rows never split across a page break.
- A repeating header on every page: show title, the date printed, and page `n` of `m`.
- Generous row spacing, with room to write. The DSM will annotate this in pencil.
- A cue with no cue point set prints an empty cell, not a dash, so the gap is obvious and gets filled in.

### The operator layout

**Decided: build both.** A second layout, chosen in the print panel, for the projection operator rather than the DSM.

Same one row per cue in running order, different columns: cue number, type, content, and the settings that cue runs with. For a title cue that is the hold, clock and wave; for an image cue the grid, flip duration and order; for a blank cue its colour.

It is a tech-week document. It exists so settings dialled in on the rig can be written down, checked against, and restored if a document is ever lost or rebuilt. It carries no cue points, because an operator reading settings is not the operator waiting for a line.

## The cue model

Carried over from the prototype unchanged. A `Cue` is a struct with an enum payload per kind, so an invalid combination cannot be represented.

| Field | Applies to | Notes |
| --- | --- | --- |
| `num` | all | String, not an integer. `9.5` and `P12` are both valid |
| `kind` | all | `title`, `image`, `video` or `blank` |
| `line` | all | The cue point: the spoken line or action to wait for |
| `text` | all | Place name on a title cue, label on an image or video cue |
| `sub` | title, image, video | City on a title cue, caption on an image or video cue |
| `key` | title | Vigenere key. Drives the ciphertext; never shown on stage or in the cue list |
| `src` | image, video | Relative path inside the package. Empty on an image cue means the generated placeholder; empty on a video cue is an error flagged in the console |
| `colour` | blank | Any CSS colour; falls back to black if unrecognised |
| `atEnd` | video | hold, black, loop or follow. Default hold |
| `follows` | all | True when this cue is fired automatically by the one before it rather than by GO |

### Numbering rules

- Numbers are identifiers. Adding, deleting or reordering a cue never changes another cue's number.
- Decimals are supported so a cue can be inserted between two existing ones without disturbing the book.
- Duplicates are permitted but flagged in the console, since a called cue number must be unambiguous.
- **Renumber all** stays available, warns clearly, and should be used once before tech and never after.

## Menus and shortcuts

The prototype's keyboard controls carry over unchanged: space to fire, arrows to step, number keys to jump, R to re-run, B to black out, F to full-screen. They work in whichever window has focus. The menu bar adds what macOS users will look for, and nothing that duplicates a show control.

| Menu | Items |
| --- | --- |
| File | New, Open, Open Recent, Save, Duplicate, Print Cue Sheet, Export Cue Sheet as PDF, Remove Unused Media |
| Edit | Undo, Redo, Cut, Copy, Paste, plus Add Title Cue, Add Image Cue, Add Video Cue, Add Blank Cue |
| Show | Enter Show Mode, Enter Edit Mode, Open Projector, Choose Projector Display, Blackout |
| Window | Console, Projector, standard items |

### What must not get a shortcut

GO has no menu item and no key equivalent beyond the existing spacebar. A second way to fire a cue is a second way to fire it by accident.

Entering and leaving show mode has no shortcut either, for the reason already settled in the prototype: a key that silently unlocks the cue sheet mid-performance is a liability. Menu items only.

### Preferences

Almost nothing belongs here. Everything that varies by production belongs in the show document, so it travels with the show. The only genuine preferences are which display to prefer when a show names one that is absent, and whether to reopen the last show on launch.

## Failure and recovery

The design assumption is that something will go wrong during a performance and nobody will have time to think. Every behaviour below is chosen so the operator's next action is still pressing GO.

| Failure | Behaviour |
| --- | --- |
| Projector display unplugged | Keep running, warn in the console only, restore automatically when it returns |
| Image or clip missing from the package | An image falls back to its generated placeholder; a missing clip goes to black. Either way the console says so and the next cue still fires |
| Image fails to decode | Same as missing |
| A renderer throws mid-cue | Caught at the cue boundary: that surface goes to black, the console reports it, and the next cue still fires |
| App crashes | On relaunch, reopen the show and offer to resume at the last fired cue |
| Corrupt `show.json` | Refuse to open, keep the file untouched, and point at macOS version history rather than attempting repair |

### Never on the projector

No dialog, alert, sheet, progress indicator, file picker or error message may appear on the projector display. Every message goes to the console window. If something is so wrong that the projector cannot show a cue, it shows black.

### The crash record

The app writes the current cue number to a small file outside the document whenever a cue fires. It is the one piece of state worth recovering after a crash, and firing a cue is already the moment the model changes, so it costs nothing.

## Build and distribution

Not going to the App Store. Sandbox restrictions on display control and power assertions make it a poor fit, and there is no reason to distribute it publicly.

- Xcode project, Swift, bundle identifier `uk.co.<company>.prospect`, **AppKit rather than SwiftUI**. Window placement, display selection, `NSWindow` collection behaviour and printing are all precise in AppKit and fought for in SwiftUI.
- Core Animation and Core Text directly, not a drawing abstraction.
- Signed with a Developer ID and notarised. Unsigned apps need a Gatekeeper override that a venue's IT may have disabled, and discovering that on a get-in day would be bad.
- Minimum target: whatever the production's Mac runs, minus one major version.

### The cost being accepted

This should be stated plainly now rather than discovered in two years.

The HTML prototype runs on any machine anyone can borrow. A Mac app runs on your Mac. If the production's machine fails on a get-in, the fallback is gone unless the prototype is kept alive alongside, which means maintaining two implementations and is not recommended.

Maintenance needs Xcode, a Mac and someone who writes Swift. A single HTML file could be fixed by anyone with a text editor. For a revival in two years with a different team, that is a real barrier.

And the bugs get re-found. The stale image flash, the load race, the histogram collapse, the glyph-width shiver: none of those were predicted. They were found by running the thing in front of someone. A rewrite reintroduces that class of bug, and the natural time to discover them is tech week.

The mitigations are to keep the prototype in the repository as the behavioural reference, to port the pure logic first and test it against known outputs, and to book projector time early rather than at the end.

## Out of scope

Deliberately excluded, with what would bring each back.

| Excluded | Would be needed if |
| --- | --- |
| MIDI or OSC input from QLab | One operator ends up running sound and projection together, or the DSM wants projections to follow sound cues |
| Syphon or NDI video output | A projection designer joins and wants to composite this with other content |
| A synchronised backup machine | The production decides a projection failure would stop the show |
| Keystone and corner pinning | The projector cannot be hung close to square. Try lens shift and physical trim first; software keystone softens exactly the monospace detail this show depends on |
| Fades between cues | A cut off an image reads too harshly in the space. Would be a general transition at stage level, not a per-cue-type option |
| Multiple projector surfaces | More than one surface is being projected onto |

### Worth noting

None of these is hard to add later, because cue types are renderers behind a protocol. A fourth is one class and one enum case. The architecture was built for this and should be left that way.

## Migration plan

Seven phases. Each leaves something demonstrable, and the risky work is front-loaded so a wrong assumption surfaces while there is time to act on it.

1. **The model.** `Cipher`, `Cue`, `Show`, the per-character travel plan, tile ordering, chi-squared. Pure Swift, no AppKit. Unit-tested against outputs captured from the prototype, so a regression is caught by a test rather than by an audience.
2. **Title cues on screen.** One window, Core Text, the reveal and the histogram. The first phase with something to look at, and the one that proves the type rendering holds up.
3. **Two windows.** Console, projector, display selection, full-screen, percentage geometry, the live preview as a second surface. The surface abstraction is load-bearing and should be exercised early.
4. **Image and blank cues.** Core Animation tiles, average-colour faces, both orders, the blank renderer.
5. **Video cues.** `AVPlayer`, arming, end behaviour, auto-follow, and the position readouts in the console. Last of the cue types because it is the only one that changes generic machinery, and because the auto-follow it introduces touches the cue model and the printed sheet.
6. **Documents.** The `.prospect` package, Save and Open, image import, autosave suspended in show mode.
7. **Cue sheet.** Print and PDF export.

### Order, and why

The model first because it is the only part with a known-correct reference to test against, and because it is where a quiet error would be invisible until it is twenty feet tall behind an actor.

Title cues before anything else visual because they are the show's signature effect, and because Core Text layout is the one place the rewrite could disappoint. Find that out in week two, not week ten.

Documents late because the prototype's cue sheet can be exported as JSON and loaded from a file in the meantime. Nothing is blocked by their absence. Video is later still, because it is the only cue type whose absence can be worked around on the night with a held image, and the only one that pulls new machinery into the cue model.

### Before anything else

Commit the HTML prototype to the repository and tag it. It is the behavioural reference for every phase above, and the only thing that can run the show until phase four is done.

### Projector time

Book it early and more than once. The things that will need it are the glyph legibility from the back of the house, the tile grid density, whether the cold slate ciphertext survives the projector's contrast, and the reveal timings at 60 Hz. None of those can be judged on a desk.
