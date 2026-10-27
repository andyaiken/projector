# Prospect — Specification

Oct 14, 2026 · @Andy · revised Oct 15, 2026 after review

## Purpose

Prospect is a native macOS application for running projections in live theatre. Title cards resolve out of ciphertext, scene images flip into place tile by tile, and an operator fires cues from a console while a projector window runs full-screen on a second display.

It is written in Swift and AppKit, with no web view. Core Animation, Core Text and the display link give it precise control of timing, type and the projector display.

Much of the behaviour below was settled by running the show in front of people. Where a decision was made and tested that way, the document says so, and it should not be reopened without discussion.

## Decisions taken

Four questions were settled before this document was written, and they define its scope.

| Question | Answer | Consequence |
| --- | --- | --- |
| Booth machine | A Mac the production owns | macOS only; no Windows path is specified |
| Build approach | Fully native | No web view, no JavaScript, no bridge |
| Show storage | Openable documents on disk | `NSDocument` package format, standard Save and Open |
| Native capabilities wanted | Printable cue sheet only | No MIDI, OSC, Syphon, NDI or machine-to-machine sync in scope |

The fourth answer removes the three largest optional pieces of work. The second is the significant one, and it was taken on the basis of lead time: with months before the show and real access to the projector, a native app is affordable. The cost it accepts is set out under Build and distribution.

### Settled in review

A review of this document on Oct 15 found places where it contradicted itself or left a question open. These were settled then, and the sections below are written to match.

| Question | Answer |
| --- | --- |
| Timing settings: per cue or show-wide? | Show defaults, which any cue can override |
| What the cue clock counts | A logical tick of a set length in milliseconds, sampled by the display link, so timings don't depend on the refresh rate |
| How the show moves on by itself | Continue, on each cue: when cued, a wait after it fires, or a wait after it finishes. Video end behaviour is hold, black or loop |
| Ways to fire a cue | Space only. Everything else moves the standby cue |
| Keys that change a setting | None. Settings change in edit mode |
| Notifications, given no public Do Not Disturb API | Shielding window level, a main-display warning, and the booth checklist |
| Title font | The system's SF Mono |
| Shows open at once | One |
| Mode a show opens in | Show mode, always. Mode is not stored in the document |
| Blank cue colours | Stored as hex, edited with a colour well |
| Where Add Cue inserts | After the selected cue, numbered between its neighbours |
| What New contains | An empty sheet |
| Image sizing | Originals kept untouched, decoded down to size on load |
| Resuming after a crash | Last fired cue straight up, settled, with the next on standby |
| How one cue gives way to the next | A transition into each cue: snap, or fade through black. Crossfade later |
| Default transition | Fade through black, 0.5 s each way, overridable on any cue |
| Minimum macOS | 26. The booth Mac runs 27 |
| Bundle identifier | `com.andyaiken.prospect`, matching the developer's other apps; the document type is `com.andyaiken.prospect.show` |

### Settled Oct 27, for anagram cues

Anagram cues were extended to hold several anagrams and the working on the way to each. These were settled then, and the sections below are written to match.

| Question | Answer |
| --- | --- |
| How many anagrams a cue holds | Any number, on stage together, stacked, solved one after another |
| Working | Any number of steps between each phrase and its answer, which may be partial or wrong |
| Letters a step of working doesn't use | They dim, and gather on a line beneath it until a later step takes them up |
| Colour through the working | Slate. Letters warm to bone only as they land in the answer, so a wrong guess never looks solved |
| Pacing | A Pause setting, and an Advance setting: by itself, each anagram on GO, or each step on GO |
| A GO partway through a cue | Space carries the live cue on. The cue keeps one number, and the printed sheet marks each GO under it |
| Editing them | One text box: a paragraph an anagram, the phrase first, the answer last, working between |
| Anagrams the cue doesn't solve | `~` before a phrase ignores its anagram: it stands jumbled, in slate. A paragraph of one line is solved already: it stands solved, in bone. The cue skips both, and neither takes a GO or is flagged |
| show.json | Format version 2, which lists a cue's anagrams. A version 1 show opens as it was |

### Constraints

These were established by running the show, and hold without change. Breaking any of them breaks the show.

- **The projector output is black.** Not near-black. Anything else is light spilling onto a set.
- **Nothing reaches the projector that is not a cue.** Alignment guides already switch themselves off when entering show mode; Prospect must not introduce overlays, update prompts or notifications that can appear on that screen.
- **Monospace glyphs must share an advance width.** The title reveal rotates characters in place; a substituted glyph of a different width makes the line shiver. A unit test checks every glyph against the system font; see Decryption cues.
- **Cue numbers are stable identifiers, not positions.** The DSM writes them in the prompt book. Inserting a cue must never renumber its neighbours, and every message the app shows names cues by number. A message that names a cue by its position is a bug.
- **One operator, one machine, one keyboard.** LX, sound and projection are three separate operators, so no cross-application focus handling is needed.

## Architecture

Three layers. A pure model with no AppKit dependency, a renderer protocol with one conformer per cue type, and the AppKit views.

The first two are libraries in one Swift package, `ProspectCore` and `ProspectStage`, so both are tested without a window: the model against recorded outputs, the renderers by rendering their layer trees offscreen. The app target holds only the AppKit views.

The layering has proved its worth: adding the blank cue type took twenty lines and touched nothing generic. Keep it.

### The renderer protocol

```swift
protocol CueRenderer: AnyObject {
    var isInstant: Bool { get }                           // skips the hold; blank cues are instant
    func mount(on surface: SurfaceLayer)                   // called once per surface
    func unmount(from surface: SurfaceLayer)               // the projector window closed
    func setVisible(_ visible: Bool, on surface: SurfaceLayer)  // only the active cue's renderer shows
    func clear(_ surface: SurfaceLayer)                    // wipe stale state before a cue loads
    func prepare(_ cue: Cue, defaults: ShowSettings)       // compute the shared plan once
    func frame(_ f: Int) -> Bool                           // paint all surfaces; true when settled
    func fit(_ surface: SurfaceLayer)                      // geometry changed
}
```

Five conformers: `TitleRenderer`, `AnagramRenderer`, `ImageRenderer`, `VideoRenderer` and `BlankRenderer`. Adding a sixth means writing one class and adding one case. Nothing generic is touched.

A renderer whose cue can stop partway and wait for GO also conforms to `WaitsForGO`: it says when it is waiting, so the clock can rest, and carries on when told. Only `AnagramRenderer` does. The playhead counts the GOs; the renderer keeps the time.

`VideoRenderer` is the one that strains the contract. It does not resolve over a frame count, it plays; it satisfies `frame(f)` by reporting whether its player has reached the end, and it is the only renderer that does not paint every surface identically. See Video cues.

`clear` exists because of a bug found in practice: tiles from the previous image cue stayed face-up while the next image loaded. It is called on **every** renderer before a cue prepares, not just the incoming one.

### Surfaces, not windows

A *surface* is any layer tree a cue paints into: the projector window's, and the console's live preview. Renderers never know which is which, with one exception: each surface carries a role, live or preview, which only `VideoRenderer` reads.

Anything random within a frame, such as the loose glyphs during a reveal or the tile order, is computed **once per frame** and applied to every surface. Two surfaces each rolling their own dice visibly disagree.

Each surface is a black `CALayer` filling the output, containing an inset surface layer sized by percentage geometry. Renderers measure the inset layer, never the output.

## Windows and displays

Two windows: the console and the projector. Both are real `NSWindow`s, which removes pop-up blocking as a failure mode and gives precise control over placement, window level and collection behaviour.

### Console window

Standard resizable window on the operator's screen. Its title shows the show name and the current cue number. It holds the cue list, the standby panel, GO, the keyboard reference and a live preview of the projector, rendered by the same renderers into a second surface. In edit mode it adds the projection area: width, height and offsets, alignment guides, and Fill the Output.

When the console first opens, the Prospect wordmark in its header decrypts the way a title cue does: a moment of ciphertext, then each letter cycling home and warming from slate to the desk's text colour, in under two seconds. It runs once per window, and not at all with Reduce Motion on.

Nothing in the console takes keyboard focus except the Go-to field, so the show keys always reach the show. A focused button would be pressed by Space as well, firing twice, and a focused slider would take the arrow keys from the standby cue. Return or Escape in the Go-to field hands the keyboard straight back.

### Projector window

Borderless, no title bar, black background, cursor hidden, not movable by the operator. It covers the whole of a chosen display and stays there.

This is a borderless window sized to the display's frame at shielding window level (`CGShieldingWindowLevel`), not a native full-screen Space. It sits over that display's menu bar and Dock, involves no Space-switching animation, and has no full-screen toggle for a stray key to hit.

- The display is picked by name in a menu, not by dragging a window onto it.
- The choice is stored in the show document, so opening the show on the same rig restores it. It is stored by the display's UUID (`CGDisplayCreateUUIDFromDisplayID`), with vendor, model and name as fallbacks. `CGDirectDisplayID` is not used, because it can change when a cable is replugged.
- It opens on the display it was last on. If that display is gone, it opens on the console's display in a window rather than full-screen, and the console says so plainly.
- `NSWindow.collectionBehavior` keeps it out of Mission Control and Spaces switching, so a trackpad gesture cannot pull it away mid-show.
- Hide Prospect does not hide it, since that would show the desktop on the projector.
- It never goes full-screen on the console's display. If the console is moved onto the projector's display, the projector hides until the console moves off again.
- In the fallback it is an ordinary titled window, with the cursor visible. Full-screen, the cursor is hidden over it.

### Display disconnect during a performance

The realistic failure is a knocked HDMI cable. When the projector display disappears, the app must not quit, must not lose its place, and must not throw a dialog onto the remaining screen.

It holds the current cue in memory, shows a clear warning in the console, and restores the projector full-screen on the same display automatically if it comes back. Meanwhile the window is hidden, not moved: macOS would otherwise move it onto a remaining display, which here means over the console. The operator should be able to carry on pressing GO throughout, so the show is in the right state whenever the picture returns.

The cue clock is driven by the projector display's display link. While that display is gone the clock switches to the console display's link, so frames keep advancing, cues keep settling, and follows keep firing.

## Cue types and rendering

Five cue types, each a `CueRenderer`.

### Decryption cues

Stored in show.json as the kind `title`; everything the operator sees calls them decryption cues.

The text resolves out of Vigenere ciphertext, character by character, over a 45-glyph ring: A to Z, 0 to 9, `/!?[],.-` and the space. Each character rolls backwards through the ring from its ciphertext glyph to its plaintext one.

Rules arrived at by watching the reveal run:

- A character whose shift is short gets a burst of random glyphs first, then rotates home. Every glyph moves for at least 16 frames. An extra full turn of a 45-glyph ring was tried and looked uneven against longer shifts.
- An unresolved space draws as `U+2423 OPEN BOX`; a settled one is a real gap. The marker hides word boundaries during the reveal while leaving the final line readable.
- Characters warm from cold slate to bone as they travel, so meaning arriving is visible per character.
- The Vigenere key drives the ciphertext and is **never displayed**.
- **Letters** is cycling or dials, selectable like the image cues' order. Cycling is the reveal above. On **dials**, each letter sits in a window the height of its line, as a cryptex's letters do, and the ring rolls through it: A above B, one glyph sliding out as the next slides in, a little dimmer away from the middle, the window's top and bottom edges softened. A dial turns backwards a full turn and its shift, fast at first and slowing cubically to settle on its letter, over exactly the frames the letter would take cycling, so the cue's timing and the histogram's behaviour don't change. Nothing random is drawn: a dial passes through every glyph between. The positions are worked out by the model; the clock moves them.

Each character is laid out as its own positioned glyph using `CTFontGetAdvancesForGlyphs`, in the system's SF Mono (`NSFont.monospacedSystemFont`, medium weight).

**Decided: the system font, not a bundled one.** It keeps the look the show has been built around and raises no licence question. Coverage of the 45-glyph ring and of `U+2423` at a single advance width is asserted by a unit test; both were checked on macOS 27. macOS updates are installed only deliberately, and the test is rerun after one, so the width shiver cannot creep in.

Beneath the title sits a live letter-frequency histogram against expected English frequency, with `solved`, `key length` and chi-squared readouts. Chi-squared falls as the text resolves, which is what makes it read as cryptanalysis rather than decoration. The bars are scaled against the settled text, not the current frame, and the first paint of a cue lands without animation.

- **A long text wraps.** Past 24 characters it splits at the space nearest its middle, and again if a line is still too long, exactly as an anagram's phrases do. Every line has the same cells, sized by the longest line, and each is centred; the subtext sits beneath the last. The space a line breaks at is drawn on neither line. Shorter texts are laid out exactly as before.
- **Bars** is letters or digraphs, selectable like the letters. On digraphs the 26 bars are the 26 commonest pairs of neighbouring letters in English, commonest first (th, he, in, er…, from Peter Norvig's counts over Google Books), each against its expected share, and each counts the pairs in the text as it currently reads. Anything not a letter, an unsettled space's open box included, breaks a pair, so the bars give word boundaries away no sooner than the text does. They are scaled against the settled text as letters are. Digraphs tell more on a long text; on a short place name most bars stay empty.
- **Chi-squared stays on letters with digraph bars.** Tried on digraphs, it rose as the text resolved: over a text of stage length each pair is expected well under once, so a real text's repeated THs read as surprising. Letters it is, which still falls.

### Anagram cues

A phrase whose letters lift out of line and travel to spell another, as the book's clues do: "O, Draconian devil! Oh, lame saint!" becomes "Leonardo da Vinci! The Mona Lisa!". The cue holds both phrases, the one that appears and the answer.

- Both phrases are set as typed, one size for both so the letters keep their size as they travel, and each line is centred. A phrase longer than 24 characters splits at the space nearest its middle, as the book sets those two.
- **Font** is the stage's own SF Mono, opened out to a decryption's 0.72 em cells, or any font family on the Mac, as a show default with a per-cue override; a hand-drawn look is the reason it exists. Every line is measured in its font, so each letter starts and lands where the font sets it, its own width and the kerning between letters included; a monospaced font is just one case of that. Each letter is drawn on its own, so a joined-up script loses its joins and a printed hand suits best. The menu names each family in its own type. A font the Mac doesn't have, as on a booth Mac it was never installed on, falls back to SF Mono, and the console says so when the cue fires; the menu lists it as not on this Mac.
- Letters are matched in reading order, whatever their case: the first A of the phrase goes to the first A or a of the answer, so no two of the same letter cross. A letter that changes case on the way, as the l of devil becoming the L of Leonardo, cross-fades from its old form to its new one as it warms. When both phrases are the same words or numbers in a new order, each moves whole instead: 13-3-2-21-1-1-8-5 sorts itself into 1-1-2-3-5-8-13-21 with 13 travelling as 13.
- A letter heading right arcs over the line and one heading left dips under it, so the two streams pass without touching. The bow is a third of the distance across, between half a line and a line and a half. Each letter warms from slate to bone as it goes.
- They set off in reading order, a wave apart, but the departures close up to fit within one journey, so every letter has left before the first lands and nothing lands on a letter still waiting to go. A journey is 24 steps of the clock, eased in and out; like a tile's flip, it is an animation with its own duration that the clock only triggers.
- A character only one phrase has, such as a comma, fades: out of the phrase as its turn comes, or into the answer as the last letters land. Punctuation and spaces may differ freely, but a letter or digit only one phrase has is flagged in the console, since an inexact anagram is usually a typing slip.
- Hold, clock and wave are set as for the other cues, and text size is shared with decryption cues.

**Several anagrams to a cue.** A cue can hold any number of anagrams. They are on stage together from the start, stacked down the stage in one size of type, each in a block with room for its longest step, and they are solved one after another, the first after the hold.

**Working.** Between each phrase and its answer can come steps of working, as someone solving it might try them: "Dracula? No.", or "LEONARDO" with the rest still to place. Each step is a move like any other, letters travelling and leftover punctuation fading. Working may be partial or wrong, so only the phrase and its answer are checked against each other; a step may bring in letters the phrase doesn't have, which fade in.

- A letter a step of working doesn't use isn't lost: it dims, and gathers on a line beneath the step, in the order the letters stood, until a later step takes it up, rising and brightening as it goes. "O, Draconian devil!" worked to LEONARDO leaves c i a n d v i dimmed beneath. The answer takes what it needs, and anything left fades, as it always has.
- Working stays slate. Letters warm to bone only as they land in the answer, so a wrong guess never looks solved.
- A cue's anagrams and working are written in one text box in the Cue tab: a paragraph an anagram, the phrase on its first line, the answer on its last, any working between, and a blank line before the next.
- **Skipping one.** `~` before a phrase ignores its anagram: it stands jumbled, as its phrase, in slate, and is never solved. A paragraph of one line is an anagram solved already: it stands solved, in bone, so a later cue can show the board with earlier answers in place. One line wins: an ignored anagram of one line stands solved. The cue skips both as it solves the rest, neither takes a GO, and neither is checked or flagged.

**Pacing: Pause and Advance**, both show defaults any anagram cue can override.

- **Pause** is how many steps of the clock an anagram rests on each step of its working, and once solved, before the next moves. It reads in steps and seconds, as a hold does.
- **Advance** is by itself, each anagram on GO, or each step on GO. By itself, everything follows a pause after what came before. Each anagram on GO waits for GO before every anagram, the first included, and runs its working by itself. Each step on GO waits before every step.
- While the live cue waits, its next GO point stands by ahead of the next cue: the standby panel shows the cue's number with "anagram 2 of 3" or "step 2 of 4" and what GO brings on, and Space carries the cue on. → skips past it to stand by the next cue, abandoning the rest; ← comes back to it. Clicking a cue, or going to one by number, stands that cue by instead.
- A GO before the cue can move, during the hold or while its last part is still moving, carries it on as soon as it can, so nothing jumps.
- The cue keeps one number: a GO partway is a GO for that cue. The printed sheet marks every line a GO brings on, so the DSM can see each one.
- A cue that waits hasn't finished, so a continue when finished comes only after the last GO has run. R runs the cue again from the start, its first GO point standing by again; an edit to the cue on stage shows it finished, waiting for nothing; resuming after a crash shows it finished.

### Image cues

A photograph arrives as a grid of tiles, four to twenty-eight across, each flipping over or sharpening into place.

This is what Core Animation is for. One `CALayer` per tile, `transform.rotation.y` driven by a `CABasicAnimation`, `isDoubleSided` false on each face, and `m34` on the sublayer transform for perspective. Around eighty layers is trivial and GPU-composited, so it will run more smoothly than the CSS version does.

- The unflipped face carries the **average colour of the image behind it**, pulled two-thirds toward the cold slate. Draw the image once into a `CGContext` at sixteen pixels a tile, without interpolation, and average each tile's block. A smoothing filter would bleed each tile's neighbours into its average. No cross-origin problem, no tainted canvas, no fallback path.
- Tile edges land on whole device pixels, so neighbouring tiles meet exactly. Between pixels they could leave a hairline of the black output showing through the picture.
- Order is a diagonal sweep, random or a golden spiral, selectable. Random shuffles the order and paces the starts evenly; independent random starts look like rainfall, with clumps and stragglers.
- **The golden spiral** cuts the grid into squares the way a Fibonacci rectangle is cut: the largest square off one side, then the largest off the next side round, clockwise, until nothing is left. An 8 x 5 grid, which is what eight columns make of a 16:9 or 16:10 picture, gives squares of 5, 3, 2, 1 and 1; 13 x 8 gives 8, 5, 3, 2, 1 and 1. The spiral turns a quarter in each square, about the corner where it meets the rest, so it runs from square to square without a break. The reveal starts at the spiral's eye and goes outward, each square swept like a clock hand, so tiles in line with the corner start together. Pacing follows the spiral's length, which in each square is in proportion to its side, so the curve is traced at one speed. Other grids cut just as cleanly, but the spiral sometimes has to skip a side.
- Every order spans the same duration, so switching does not change cue timing.
- The flip is an animation with its own duration; the clock only triggers each tile.
- **Reveal by** is flipping or sharpening, selectable like the order. A sharpening tile stays square on and steps, over the same time a flip takes, from its flat colour through its part of the picture as one block, then 2 x 2, 3 x 3, 5 x 5, 8 x 8 and on through the Fibonacci numbers, until a block would be smaller than two of the picture's pixels; then the picture itself. Each step is drawn down from the next finer one. The blocks are drawn crisp, not smoothed, and the steps fall on the clock's frames, each for a frame at least; a flip too short for every step leaves out the finest, which are the least missed.

### Video cues

Moving footage. Unlike the other three, a video cue does not *resolve* — it plays. That difference reaches into the architecture, so it is set out here rather than treated as a fourth variation.

**What video breaks.** The `CueRenderer` contract assumes a renderer paints every surface identically from one frame number. Video cannot. An `AVPlayer` drives a single `AVPlayerLayer`, so the same clip cannot be shown live on the projector and in the console preview without either decoding it twice or routing frames by hand through `AVPlayerItemVideoOutput`.

**The decision: don't.** The projector gets the video. The console preview shows a poster frame with elapsed and remaining time, not a moving picture. That is better for the operator as well as cheaper — at preview size a moving image tells them nothing, while a countdown to the end of the clip tells them exactly when to stand by.

**Audio is muted, always.** A video cue plays its video track and mutes its audio track unconditionally, with no per-cue setting. Sound is a separate operator on a separate machine running QLab; two systems playing into the same room is a failure the first time it happens, and a switch that permits it is the switch that gets left on by accident. If a clip's audio is wanted, it is pulled out and given to sound as a QLab cue.

**Arming.** `AVPlayer` needs time to load and buffer, and a clip that stutters on GO is unacceptable. A video cue is prepared as soon as it becomes the cue that will fire next, either the standby cue or the cue the live one continues into: asset loaded, first frame decoded, player paused at zero. GO then starts an already-ready player.

Arming begins when the current cue *starts*, not when it settles. A held clip settles only when it reaches its end and a looping one never does, so arming on settle would leave the next clip cold whenever the operator cuts a clip short on a line. Moving the standby cue re-arms. The standby panel shows whether the standby video cue is armed, and says so plainly if it is not: *Video armed*, *Video loading — not armed yet*, or *No clip — this cue goes to black*.

Each armed clip gets its own player layer on the projector, transparent until GO, so its first frame is already in place when it becomes visible. Up to four players are kept: whatever may fire next, what is on stage, and what was on stage last, so R restarts a clip at once. A clip that stops for another cue goes back to its start and stays armed. A looping clip uses `AVPlayerLooper`, so the loop has no gap.

The preview's countdown rounds up, so it reads 0:00 only when the picture has actually finished. A clip that can't be played is reported when it is armed and again as it fires, since that is when the operator needs to know the stage has gone black.

**Its own clock.** `AVPlayer` keeps its own time base. It is not driven from the display link, which only polls its position for the readouts. Do not try to make the two agree.

**End behaviour**, set per cue:

| Setting | On reaching the end |
| --- | --- |
| Hold | Freeze on the last frame (default) |
| Black | Cut to black, as a blank cue |
| Loop | Repeat until the next cue fires |

**Continue is cue machinery.** Video is what brings it in: a clip that must hand straight to a title card cannot wait for a human. It belongs to the cue model rather than to video cues.

**Decided: Continue, on each cue, saying what happens after it.** The show moves on to the next cue in the sheet:

- **When cued**, the default: only GO fires the next cue.
- **After a wait** from this cue firing, in seconds, whatever its transition, and whether or not it has finished.
- **When finished, after a wait**: this cue finishes, then the wait passes, then the show continues. The wait is in seconds and is often none. A reveal finishes when its text has resolved, a picture when its tiles have landed, and a clip on reaching its end, whether it holds on the last frame or cuts to black. A blank is instant and a looping clip never ends, so neither offers it; a blank uses a wait after firing instead. A looping clip set to it anyway, by changing its end behaviour afterwards, is flagged in the console, as is a last cue set to continue, with nothing after it.

The next cue is the next in the sheet, even if the operator has stood by another; a GO before the continue comes fires the standby cue as usual, and the continue then has nothing to do. Resuming after a crash never continues by itself: the next cue waits for GO. In the cue list, a cue that continues has a mark at the right of its row: a down arrow if it continues when finished, with or without a wait after, or the moment it fires, and a clock if it continues a while after it fires; resting the pointer on the row says which. The printed cue sheet marks a cue fired this way clearly — a cue the operator does *not* press GO for is exactly the kind of thing a prompt book gets wrong.

Shows saved before Continue marked the cue fired, with `follows`. Opening one moves each follow onto the cue before it as when finished with no wait, or as a wait of nothing after firing on a blank.

**Files.** ProRes 422 preferred: it decodes cheaply, seeks reliably and survives being re-cut. H.264 and HEVC are accepted, with the caveat that long-GOP seeking is slower and in-point accuracy suffers.

### Video files are imported

**Decided: video is copied into the package, like images.** The clips planned are not large, and anything that ever is moves on a thumb drive — which is how the document travels between machines in any case.

That keeps one rule for all media. A show stays a single object that cannot lose half of itself in a move, and there is no second code path for missing or relinked media to get wrong on a get-in day.

Two notes for the build. Import copies the file as it stands and never re-encodes, so whatever the edit exported is what plays. And on APFS a Duplicate clones unchanged files rather than copying their bytes, so duplicating a show and keeping version history stay cheap even when the package runs to several gigabytes.

### Blank cues

A flat colour, black by default, chosen per cue with a standard colour well and stored as `#RRGGBB`. Instant: it declares `isInstant` and skips the hold.

Distinct from the blackout key, deliberately. Blackout is an override you toggle back when something has gone wrong. A blank cue is a planned point in the sheet that the operator advances into like any other. The operator should never reach for the panic control to make a scheduled scene change.

## Transitions

**Decided: a transition belongs to the change between cues, and is set on the way into each cue.** The operator can stand by any cue and press GO, so cue 7 does not always follow cue 6. The transition into a cue applies however the stage arrives at it: in sheet order, after a jump, or from a continue.

Two styles:

- **Snap.** The old picture goes and the new one appears at once.
- **Fade through black.** The old picture fades out to black, then the new one fades in. The fade time is the length of each half, so 0.5 s takes half a second out and half a second in.

**Decided: the show default is fade through black, 0.5 s.** It sits in the Show tab with the other defaults, and any cue can override the style, the fade time or both in Cue Settings. A cue whose transition differs from the default shows it in brass above its name in the cue list, so the change reads as sitting between that cue and the one before.

- The incoming cue's clock starts as it begins to fade in, so its hold runs while it appears. After a fade out, the next cue starts one fade time after GO.
- With nothing on stage, as for the first cue of the night, there is nothing to fade out, and the cue fades straight in.
- A GO during a transition starts the next one from wherever the fade has got to, so nothing flashes up: a fade out carries on down to black, and a fade in turns round and goes back down.
- R runs the live cue again from its transition: out, then in from the start.
- A cue fired by a continue uses its own transition like any other.
- Resuming after a crash, and edits that redraw the cue on stage, are instant.
- Blackout is separate, with its own fade, and works the same during a transition.

Every surface fades together, so the preview shows what the audience sees. The fade is a black layer over the picture, not something each renderer does, so every cue type gets it alike.

**Crossfade later.** A crossfade, the old and new pictures overlapping, is the obvious third style, and the design leaves room for it. It needs two cues on stage at once, and since one renderer draws every cue of its type, two cues of the same type need two renderers. The stage would run two decks, each a full set of renderers mounted on the same surfaces, and fade between them, as a vision mixer does. The style is an enum and the stage's change of cue switches on it, so a crossfade is a new case there and a second deck in the runner; the cue model, the panels and the printed sheet already carry the style and the fade time.

## Timing, power and interruption

The clock is driven by a display link bound to the projector's display (`NSScreen.displayLink(target:selector:)`; `CVDisplayLink` is deprecated as of the macOS 15 SDK), so frames are painted on that screen's actual refresh, and drawing never slows down because a window is in the background or covered.

The cue clock counts frames. **Decided: a frame is a logical tick, not a refresh.** Each cue runs with a clock setting in milliseconds (default 44). On every refresh the display link reads the elapsed time, and the frame number advances by however many ticks have passed. So the projector's refresh rate does not change how long a cue takes. Glyphs step at the tick rate; tile flips and histogram bars are Core Animation animations and move smoothly regardless. The reveal timings should still be checked on the real projector.

| Concern | Handling |
| --- | --- |
| Display sleep and screensaver | `IOPMAssertionCreateWithName` with `kIOPMAssertionTypeNoDisplaySleep`, held while a show document is open, not only while a cue runs |
| Notifications over the projector | macOS has no public API to turn on Do Not Disturb or a Focus mode. Banners appear on the main display, so the console warns if the projector display has become the main one. The projector window's shielding level covers its display's menu bar and Dock. Turning on a Focus mode is on the booth checklist |
| Automatic updates | None. The app updates only when someone chooses to |
| Projector refresh differs from console | The display link follows the projector; the console preview is repainted from the same frame number |
| Projector display unplugged | The clock moves to the console display's link until the projector returns |

The power assertion covers the whole document, not the running cue. The gap between cues in a quiet scene can be twenty minutes, well inside any default sleep timer.

### Quitting during a show

**Decided: warn.** While the projector window is live, Quit presents a confirmation sheet before anything is saved or closed. It appears on the console, never on the projector, and the projector keeps showing its current cue while the sheet is up.

The sheet is dismissible with Escape and its default button is Cancel, so a reflexive Return does not quit. Closing the console window does the same thing rather than quitting silently.

### One show at a time

**Decided: one show open at a time.** Opening another show closes the current one, with the same confirmation as Quit if the projector is live. That keeps one projector window, one power assertion and one crash record.

Prospect runs only while a show is open. Closing the console quits, and so does anything else that leaves no show open, such as a show that won't open after the one before it has closed. At launch, a show that won't open is replaced by a new one instead.

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

- `version` so a future format change can migrate rather than fail. Version 2 lists an anagram cue's anagrams and working; a version 1 reader would take such a cue for an empty one, so it refuses the file instead
- `cues` every field in the cue model, including the video end behaviour, Continue and per-cue overrides
- `settings` the show's default for every per-cue setting, the text size, the projection geometry and the projector display identity
- `title` for the window and the printed cue sheet header

Show mode is not stored, because every show opens in show mode. Alignment guides are not stored either.

### Saving

Standard Save, Save As and Duplicate. Autosave in place, with macOS version history so a cue deleted on the Tuesday can be recovered on the Wednesday.

One exception, **decided rather than assumed: the document is read-only in show mode.** During a performance it is not written to at all. Show mode allows no edits: the cue sheet, settings and geometry are locked, and no key changes a setting. So there is nothing to hold in memory or discard on close. Entering show mode saves any edits still pending, and Save is unavailable until edit mode. A fix needed during a performance means switching to edit mode, which is a deliberate menu choice, and autosave resumes there.

Autosave must stay cheap however large the package grows. The document keeps the `FileWrapper` it was read from and replaces only `show.json` on save, so media files are never rewritten. Version history needs an APFS or HFS+ volume, and a thumb drive formatted as exFAT keeps none, so a show is copied to the internal disk and run from there.

### Recent documents

Standard Open Recent. The app opens the most recent show on launch, so the operator's first action on the night is pressing GO rather than finding a file.

**Decided: a show always opens in show mode**, including at launch: sheet locked, nothing on stage, the first cue on standby. Editing is one menu item away.

### New shows

**Decided:** File › New opens an empty sheet with a prompt to add a cue. An empty sheet is valid, and GO is disabled until it has a cue.

New shows start in edit mode: they are being written, not run. A show opened from disk always opens in show mode.

### The cue editor

Edit mode adds a cue editor beside the projection area. It edits the cue standing by, so clicking a cue in the list opens it.

- **Add Cue**, a pull-down in the console's header in edit mode, adds a Decryption, Anagram, Image, Video or Blank cue, as the Edit menu's Add items do. The new cue goes in after the standby cue, numbered by the rules below, stands by, and opens in the Cue tab. Its fields start empty. Keeping Add in the header leaves the Cue tab to the cue's own details.
- Two columns. On the left, what the cue shows: text, subtext and key for a decryption cue; the text box of anagrams and their working for an anagram cue; a label and a picture for an image cue; a label, caption, clip and end behaviour for a video cue; a label and colour for a blank. On the right, where it comes in the book: number, cue point and Continue, a menu of When cued, After and When finished, after, each but the first with a seconds field, and When finished disabled for a cue that doesn't take time. Tab moves down the left column, then the right, and round again.
- A picture or clip is dropped on the editor or on the cue's row in the list, or chosen with Choose…. Remove takes it off the cue and leaves the file in the package.
- In edit mode each row in the cue list has a delete button and a grip at its right. Dragging a row by its grip moves the cue, its number with it, with a brass line showing where it will land; the list scrolls if the pointer reaches its edge. Delete removes the cue at once, without asking: both are one step of undo, and the Cue tab keeps to the cue's own details.
- Edit › Renumber All Cues… asks first, with Cancel as the default. It is a menu item rather than a button in the editor, so it is never one stray click away.
- Every change is one step of undo. Undo is unavailable in show mode, where the sheet is locked.

## Images

Images are imported, not linked. Dragging a file onto an image cue, or choosing one through an open panel, copies it into the document package's `media/` folder and stores a relative path. The original can then be moved or deleted without breaking the show.

### Tile colours from any picture

Each tile opens on a flat block of its picture's average colour, which is what makes the reveal read as a picture assembling itself. `CGContext` reads any image the app can open, so the average-colour faces work with any photograph, with no special case and no fallback path to maintain.

### Handling

- Accept anything `NSImage` opens: JPEG, PNG, HEIC, TIFF.
- Import copies the file untouched, the same rule as video: no re-encoding. **Decided** in place of downscaling on import, which would have needed the projector's resolution at a moment the projector may not be connected.
- A 48-megapixel phone photograph in a tile grid is still wasted memory, so ImageIO decodes it straight down to the size the surface needs (`CGImageSourceCreateThumbnailAtIndex`), and the full-size image never sits in memory. One decoded image serves every tile, each showing its part through `contentsRect`.
- Keep the file's name, de-duplicated on collision.
- An image cue with no file shows its label on black, centred in the stage's type, so the sheet can be built and timed before the photographs exist and the operator can see which picture belongs there.
- Removing an image from a cue leaves the file in the package. A **Remove unused media** menu command cleans up, rather than deleting where an undo would be expected.
- Decode on a background queue and cache the tile faces. A cue must never stall the clock while it loads. The picture for the cue that will fire next is decoded while the current cue runs, as video cues are armed, so GO doesn't wait for it.

## The printable cue sheet

The one capability requested beyond running the show. It exists so the DSM can transcribe projection cues into the prompt book without copying eighteen rows off a screen by hand, which is how errors get into the book.

Print and Export as PDF, both through `NSPrintOperation` over a custom `NSView` that paginates the cue list. Drawn from the same model the show runs from, so the sheet cannot disagree with what fires.

Print Cue Sheet… (⌘P) shows the standard print panel as a sheet on the console, with the layout chosen in it. Export Cue Sheet as PDF… (⌥⌘P) asks for the layout and the paper in its save panel and writes the file without a print panel. Both work in show mode, since neither changes the show.

### Contents

One row per cue, in running order:

| Column | Holds |
| --- | --- |
| Cue | The cue number, as set. Right-aligned, tabular figures |
| Type | Decryption, Image, Video or Blank. A cue the one before it continues into is marked AUTO here |
| Content | A decryption cue's text and subtext, an anagram cue's phrases with their working and answers, an image cue's label, a video cue's label and caption, or a blank's colour. Each line an anagram cue's GO brings on starts GO; an anagram solved already ends "(solved)", and one ignored "(ignored)" |
| Cue point | The line or action the operator is waiting for |

### Layout rules

These are not cosmetic. A cue sheet is read on a music stand under a single lamp.

- Portrait A4 and US Letter, black on white, no dark theme.
- At least 11 pt body text. The cue number larger and bolder than anything else in its row.
- Rows never split across a page break.
- A repeating header on every page: show title, the date printed, and page `n` of `m`.
- Generous row spacing, with room to write. The DSM will annotate this in pencil.
- A cue with no cue point set prints an empty cell, not a dash, so the gap is obvious and gets filled in.
- The cue number is 17 pt bold with tabular figures; the body is 11 pt throughout. A cue fired by the one before it carries a boxed AUTO under its type. Rows are separated by hairline rules, and the DSM's rows are at least 60 pt tall.

### The operator layout

**Decided: build both.** A second layout, chosen in the print panel, for the projection operator rather than the DSM.

Same one row per cue in running order, different columns: cue number, type, content, and the settings that cue runs with once its overrides are applied to the show defaults. For a decryption cue that is the hold, clock and wave, whether the histogram and subtext are on, its letters and its bars. For an anagram it is the hold, clock, wave, advance, pause and font. For an image cue it is the hold, clock, wave, grid, flip duration, order and reveal. For a video cue it is the end behaviour, and for a blank cue its colour. Every cue also lists its transition in: the style, and the fade time when it fades; and a cue that continues says when. A value the cue overrides is marked, so a setting changed for one cue is not mistaken for the show default.

It is a tech-week document. It exists so settings dialled in on the rig can be written down, checked against, and restored if a document is ever lost or rebuilt. It carries no cue points, because an operator reading settings is not the operator waiting for a line.

A value set on the cue, rather than taken from the show's defaults, is bold and starred, and the key is printed under the header. Each image cue also lists its picture file and each video cue its clip, so a lost show can be rebuilt from the sheet and the media.

## The cue model

A `Cue` is a struct with an enum payload per kind, so an invalid combination cannot be represented.

| Field | Applies to | Notes |
| --- | --- | --- |
| `id` | all | A UUID, never shown. The identity used by undo, the playhead and the crash record, since numbers may be duplicated |
| `num` | all | String, not an integer. `9.5` and `P12` are both valid |
| `kind` | all | `title` (a decryption cue), `anagram`, `image`, `video` or `blank` |
| `line` | all | The cue point: the spoken line or action to wait for |
| `text` | all | Text on a decryption cue, the phrase that appears on an anagram, label on an image or video cue |
| `answer` | anagram | The phrase an anagram's letters rearrange into. A missing phrase, or letters only one of them has, is flagged in the console |
| `anagrams` | anagram | In place of `text` and `answer`, when a cue has more than one anagram or any working: a list, each with its `text`, `working` (a list of steps), `answer` and, if it is ignored, `"ignored": true`. Each anagram the cue solves is checked on its own; working isn't |
| `sub` | title, video | Subtext on a decryption cue, caption on a video cue. An image cue has none |
| `key` | title | Vigenere key. Drives the ciphertext; never shown on stage or in the cue list. A decryption cue with no key, or no text, is flagged in the console |
| `src` | image, video | Relative path inside the package. Empty on an image cue shows the cue's label on black; empty on a video cue is an error flagged in the console |
| `colour` | blank | `#RRGGBB`. Black by default. A hand-edited show.json may also use `rgb()` or a CSS colour name; anything unrecognised reads as black |
| `atEnd` | video | hold, black or loop. Default hold |
| `continue` | all | What happens after this cue: absent for when cued; `{"after": 5}` for seconds after it fires; `{"finished": 2}` for seconds after it finishes. Flagged in the console on the last cue, or on a looping clip set to continue when finished |
| `transition` | all | The cue's own transition in, overriding the show's: a style, `snap` or `fade`, a fade time in milliseconds, or both. Absent means the show's default |
| `overrides` | title, anagram, image | This cue's values for settings the show holds defaults for. Absent means inherit. Decryption: clock, wave, hold, histogram, subtext, letters, bars. Anagram: clock, wave, hold, advance, pause, font. Image: clock, wave, hold, grid, flip, order, reveal by |

### Show defaults and overrides

**Decided: timing is per cue, with show defaults.** The show holds a default for every per-cue setting, and the settings panel edits those defaults. A cue's editor shows each value it inherits, and lets any of them be overridden or reset to the default. Text size and the projection geometry stay show-wide.

In edit mode the panels beneath the preview are tabs: Cue, Cue Settings, Show Defaults and Projection Area.

- **Show Defaults** has three groups side by side: timing (clock, wave, hold), decryption cues (text size, histogram, subtext, letters, bars) and image cues (grid, flip, order, reveal by), with anagram cues (advance, pause, font) and transitions (style, fade time) beneath, and how timing works beside them, each setting with its own range and step. A change applies when a cue next runs, except text size, which refits a title on stage at once.
- **Cue Settings** shows what the cue standing by runs with, in the same groups. Values the cue sets itself are in brass, each with a Reset that puts it back on the show's default. A video or blank cue has only its transition in here: a video plays on its own clock and a blank is instant.
- A slider drag is one step of undo, however far it moves.
- The console, the printed operator sheet and the panels word every setting the same way, from one definition of each. That definition also explains each setting, shown when the pointer rests on it, and the panels explain clock, wave and hold together: timing is counted in steps of the clock. A hold reads in steps and in seconds, as "44 · 1.9 s", on screen and on paper.

### Numbering rules

- Numbers are identifiers. Adding, deleting or reordering a cue never changes another cue's number.
- Decimals are supported so a cue can be inserted between two existing ones without disturbing the book.
- **Add Cue inserts after the selected cue**, and takes the shortest decimal strictly between its neighbours, preferring the midpoint: 4 and 5 give 4.5, 4 and 4.5 give 4.3, 9 and 9.1 give 9.05. After the last cue, or with nothing selected, it goes at the end with the next whole number above the highest. If either neighbour is not a plain number, such as `P12`, or the two are out of order, the number is left empty for the operator to type.
- Duplicates are permitted but flagged in the console, since a called cue number must be unambiguous.
- **Renumber All Cues**, in the Edit menu, stays available, warns clearly, and should be used once before tech and never after.

## Menus and shortcuts

**Decided: only Space fires a cue.** The arrow keys, PageDown, the number keys and a click on the cue list only move the standby cue. If any of them put a cue on stage, each would be a second way to fire one by accident.

| Key | Action |
| --- | --- |
| Space | Fire the standby cue, or carry on a live anagram cue waiting for GO |
| → ↓ PageDown | Stand by the next cue, skipping any GO the live cue still waits for. Nothing changes on stage |
| ← ↑ PageUp | Stand by the previous cue |
| 0–9 and `.` | Build a cue number in the standby panel, so `12` and `9.5` can be typed. Return stands that cue by, Escape clears the entry, and Backspace edits it. Space fires the standby cue already shown and discards the entry |
| R | Run the live cue again, from its transition |
| B | Blackout |

Clicking a cue in the list, or entering a number in the Go-to field, stands that cue by. The Go-to field is how a number containing letters, such as `P12`, is reached. Firing a cue, by GO or by a continue, stands by the one after it in the sheet. The keys work in whichever window has focus.

Holding a key down never repeats it, so a held Space fires one cue. And no key makes the Mac's alert sound: a key the app doesn't use is swallowed, because the beep is heard in the room.

**No key changes a setting.** The projector never leaves its display, and the histogram and subtext are per-cue settings changed in edit mode.

The menu bar adds what macOS users will look for, and nothing that duplicates a show control.

| Menu | Items |
| --- | --- |
| File | New, Open, Open Recent, Save, Duplicate, Print Cue Sheet, Export Cue Sheet as PDF, Remove Unused Media |
| Edit | Undo, Redo, Cut, Copy, Paste, plus Add Decryption Cue, Add Anagram Cue, Add Image Cue, Add Video Cue, Add Blank Cue, and Renumber All Cues |
| Show | Enter Show Mode, Enter Edit Mode, Open Projector (Close Projector while it is open), Choose Projector Display, Blackout |
| Window | Console, Projector, standard items |

### What must not get a shortcut

GO has no menu item and no key equivalent beyond the existing spacebar. A second way to fire a cue is a second way to fire it by accident.

Entering and leaving show mode has no shortcut either: a key that silently unlocks the cue sheet mid-performance is a liability. It is a Show / Edit switch in the console's header, where the mode is shown, and items in the Show menu, never a key. The switch never takes the keyboard, so Space can't flip it.

### Preferences

Almost nothing belongs here. Everything that varies by production belongs in the show document, so it travels with the show. The only genuine preferences are which display to prefer when a show names one that is absent, and whether to reopen the last show on launch.

Prospect › Settings… (⌘,) has both. Reopening the last show is on by default. When a show's projector display isn't connected, the projector opens in a window on the console's display, as above, unless the preference says to use another connected display; either way it moves to the show's own display as soon as that is connected, and the console says which display is standing in.

## Failure and recovery

The design assumption is that something will go wrong during a performance and nobody will have time to think. Every behaviour below is chosen so the operator's next action is still pressing GO.

| Failure | Behaviour |
| --- | --- |
| Projector display unplugged | Keep running, warn in the console only, restore automatically when it returns |
| Image or clip missing from the package | An image falls back to its label on black; a missing clip goes to black. Either way the console says so and the next cue still fires |
| Image fails to decode | Same as missing |
| A renderer throws mid-cue | Caught at the cue boundary: that surface goes to black, the console reports it, and the next cue still fires |
| App crashes | On relaunch, reopen the show and offer to resume at the last fired cue. Accepting puts that cue straight onto the projector in its settled state, with no hold and no reveal, and stands by the next. A video cue returns on its last frame, or black if it ends in black; a looping clip restarts its loop |
| Corrupt `show.json` | Refuse to open and keep the file untouched. No repair is attempted. The error lists the package's earlier versions (from `NSFileVersion`) and can restore one, since the standard version browser only works on a document that opened. Restoring keeps the damaged copy beside it, named "(damaged)" |

### Never on the projector

No dialog, alert, sheet, progress indicator, file picker or error message may appear on the projector display. Every message goes to the console window. If something is so wrong that the projector cannot show a cue, it shows black.

### The crash record

The app writes the fired cue's number and `id`, with the show's location, to a small file outside the document whenever a cue fires. It is removed on a clean quit, or when the show is closed, so finding it at launch means the app went down mid-show; resuming reopens the projector too. An untitled show has nowhere to be reopened from, so it has no record. It is the one piece of state worth recovering after a crash, and firing a cue is already the moment the model changes, so it costs nothing.

When the app goes down, its windows go with it and the projector shows the desktop. The booth checklist sets that display's wallpaper to solid black for that reason.

## Booth Mac setup

Some protections cannot be built into the app, so they are a checklist for the booth Mac: done once at the get-in, and checked before each performance.

- The console's display is the main display, the one with the menu bar. Notification banners appear there rather than on the projector, and the console warns if this changes.
- A Focus mode is on during performances. macOS gives apps no way to turn one on.
- The projector display's desktop wallpaper is solid black, so that if the app ever goes down the projector shows black rather than a picture.
- Automatic macOS updates are off.
- The show runs from the internal disk, not a thumb drive, because version history needs APFS.

## Build and distribution

Not going to the App Store. Sandbox restrictions on display control and power assertions make it a poor fit, and there is no reason to distribute it publicly.

- Xcode project, Swift, bundle identifier `com.andyaiken.prospect`, **AppKit rather than SwiftUI**. Window placement, display selection, `NSWindow` collection behaviour and printing are all precise in AppKit and fought for in SwiftUI.
- Core Animation and Core Text directly, not a drawing abstraction.
- The app icon is an Icon Composer document, `Prospect/AppIcon.icon`, so macOS draws it with Liquid Glass and in the dark, clear and tinted appearances. It shows a projection screen of tiles mid-way through an image cue's diagonal sweep, upstage of a perspective floor, in the console's bone, brass and slate.
- Signed with a Developer ID and notarised. Unsigned apps need a Gatekeeper override that a venue's IT may have disabled, and discovering that on a get-in day would be bad.
- Minimum target: macOS 26. The production's Mac runs macOS 27, and the rule is one major version below it.
- Debug builds accept `-ProspectSnapshot <folder>`, which renders the console offscreen to PNGs and quits, so layout can be checked without a second display or anyone at the keyboard.

### The cost being accepted

This should be stated plainly now rather than discovered in two years.

A Mac app runs only on a Mac. If the production's machine fails on a get-in, the fallback is another Mac, so keep a notarised copy of the app and the current show where a second machine can reach them.

Maintenance needs Xcode, a Mac and someone who writes Swift. For a revival in two years with a different team, that is a real barrier.

And some bugs are only found by running the show in front of someone. A stale image flash, a load race, a histogram collapse and a glyph-width shiver were all found that way, none of them predicted. Expect more, and expect them in tech week.

The mitigations are to keep the model tested against known outputs, so a regression is caught by a test rather than by an audience, and to book projector time early rather than at the end.

## Out of scope

Deliberately excluded, with what would bring each back.

| Excluded | Would be needed if |
| --- | --- |
| MIDI or OSC input from QLab | One operator ends up running sound and projection together, or the DSM wants projections to follow sound cues |
| Syphon or NDI video output | A projection designer joins and wants to composite this with other content |
| A synchronised backup machine | The production decides a projection failure would stop the show |
| Keystone and corner pinning | The projector cannot be hung close to square. Try lens shift and physical trim first; software keystone softens exactly the monospace detail this show depends on |
| Crossfade transitions | A fade through black reads as too slow between two pictures that belong together. See Transitions for how it would be added |
| Multiple projector surfaces | More than one surface is being projected onto |

### Worth noting

None of these is hard to add later, because cue types are renderers behind a protocol. A fourth is one class and one enum case. The architecture was built for this and should be left that way.

## How it was built

In seven phases, each leaving something demonstrable, with the risky work first so a wrong assumption would surface while there was time to act on it:

1. **The model**: the cipher, cues and shows, the travel plans, tile ordering, chi-squared, numbering, the playhead and the tick clock. Pure Swift, tested against recorded outputs, because a quiet error there would be invisible until it was twenty feet tall behind an actor.
2. **Decryption cues on screen**, early because they are the show's signature effect and Core Text layout was the likeliest place for a disappointment.
3. **The console and projector windows**, with display selection and the live preview as a second surface.
4. **Image and blank cues.**
5. **Video cues**, last of the cue types because they are the only one that changes generic machinery.
6. **Documents and the cue editor.**
7. **The printable cue sheet.**

## Projector time

Book it early and more than once. The things that will need it are the glyph legibility from the back of the house, the tile grid density, whether the cold slate ciphertext survives the projector's contrast, whether an anagram's dimmed letters, slate at 40%, can still be read, the reveal timings, and whether the shielding-level projector window also covers notification banners. None of those can be judged on a desk.
