# Convert design

**Status:** approved by Gleb, 2026-11-24 ("Approved"). Not built yet. Project 3 of the notch hub (`2026-11-17-notch-hub-design.md`), after now playing (`2026-11-21-now-playing-design.md`). Labels: [Gleb Qn] is his answer to question n of the design interview (Q1 to Q4 on 2026-11-23, Q5 to Q12 on 2026-11-24); [my call] is mine, open to correction. Terms (target, original, fileless drop, result) are defined in `GLOSSARY.md`.

## 1. Problem statement

Gleb converts files to send them somewhere: an iPhone photo (HEIC) that a website or a Windows colleague can't open, a WebP saved from a browser, a screen recording that is a .mov and too big for a GitHub comment. macOS can already do this from Finder's right-click menu (Quick Actions › Convert Image, Services › Encode Selected Video Files), but only for files already in Finder, through several menus, and a converted photo still says where it was taken. A photo in Photos or an image on a web page has to be saved to disk first.

The hub plan's line for this project: "drag a file to the notch → pick a format; prefer macOS built-ins".

## 2. Solution

Drag photos or recordings from any app toward the notch. One glass target per format that fits drops down under it: "MP4" for a recording, "JPEG" and "PNG" side by side for an iPhone photo. Let go on one. A pill shows the progress, then the saved files: drag them on into another app, or click to see them in Finder. Results are saved next to their originals, or in Downloads when the drag came with no file on disk (Photos, a browser). On a screen without a notch, the critter takes the drop.

## 3. Goals, non-goals, anti-goals

- **Goals:**
  - one drag from any app (Finder, the Desktop, Photos, a browser, the screenshot thumbnail) to a converted file;
  - photos to JPEG or PNG, recordings to an MP4 that is easy to share;
  - several files in one drop;
  - the same on screens without a notch, through the critter.
- **Non-goals:** other formats (HEIC, AVIF, GIF, WebP, MP3, audio only, PDF, documents); resizing photos or choosing quality; trimming; a Convert tab, card or history in the hub; converting without a drag (a file picker, the clipboard); keyboard control; a bundled converter such as ffmpeg.
- **Anti-goals (failure even if everything "works"):**
  - targets appearing when Gleb didn't mean it: text, a link, a browser tab, a window or a .zip dragged across the top of the screen; text selected near the notch after a file drag; a file swept past the notch without stopping;
  - an original changed, moved or deleted, or any existing file overwritten;
  - a result still saying where the photo or video was taken;
  - the drop taking keyboard focus or bringing the app forward;
  - a Claude permission request held back for longer than the drag in progress;
  - a strange or damaged file crashing the app;
  - the names of Gleb's files in the app's logs.

## 4. User stories

1. As Gleb, I want to drag an iPhone photo from Finder onto the notch and get a JPEG next to it, so that I can send it to anyone.
2. As Gleb, I want to drag a WebP saved from the web onto the notch and get a PNG, so that every app opens it.
3. As Gleb, I want to drop a screen recording and get an MP4 small enough for GitHub or Slack, so that I can share a demo without hunting for a converter.
4. As Gleb, I want to choose JPEG or PNG by where I let go, so that picking the format costs no extra click.
5. As Gleb, I want to see only the formats that make sense for what I'm holding, so that I can't pick the format a file already is.
6. As Gleb, I want to drag twenty photos at once and get twenty JPEGs, so that a whole set converts in one move.
7. As Gleb, I want files already in the chosen format skipped, so that I don't get duplicates.
8. As Gleb, I want to drag a photo straight out of Photos and find the result in Downloads, so that I don't export it first.
9. As Gleb, I want to drag an image off a web page onto the notch, so that I don't save it first.
10. As Gleb, I want to drag the screenshot thumbnail onto the notch, so that a fresh screenshot converts in one move.
11. As Gleb, I want progress while a long recording converts, so that I know it is working.
12. As Gleb, I want to cancel a conversion with one click, so that a mistaken drop costs nothing.
13. As Gleb, I want to drag the finished result out of the pill into Slack, Mail or a GitHub comment, so that I never go looking for it.
14. As Gleb, I want to click the result to see it selected in Finder.
15. As Gleb, I want the pill to leave on its own, but never while I'm pointing at it.
16. As Gleb, I want converted photos and videos without their location, so that a photo taken at home doesn't show my address.
17. As Gleb, I want converted photos to keep their date, camera and colors, and to look upright in every app.
18. As Gleb, I want a transparent PNG turned into a JPEG to sit on white, not black.
19. As Gleb, I want a recording that is already small enough to convert instantly with no quality loss.
20. As Gleb, I want my originals never touched.
21. As Gleb, I want a result never to overwrite a file; I'd rather get "IMG_1234 2.jpg".
22. As Gleb, I want a file from a read-only disk image converted into Downloads.
23. As Gleb, I want a failure explained in plain words, with what to do about it.
24. As Gleb, I want the files that worked saved and shown when some files in a batch fail.
25. As Gleb, I want to drop files onto the critter on my external display.
26. As Gleb, I want the notch to ignore drags of text, links, tabs, windows and files it can't convert.
27. As Gleb, I want a file I drag past the top of the screen without stopping to open nothing.
28. As Gleb, I want no targets while a full-screen app is in front, so that dragging a file to its tab bar does what that app expects.
29. As Gleb, I want a permission request that arrives mid-drag to show the moment I let go.
30. As Gleb, I want an open hub to make way for the targets and come back afterwards.
31. As Gleb, I want the drop never to take keyboard focus from the app I'm in.
32. As Gleb, I want to turn the whole feature off in Settings.
33. As Gleb, I want files dropped while a batch runs to wait their turn.
34. As Gleb, I want quitting mid-conversion to leave no half-written file.
35. As Gleb, I want macOS to ask for folder access at most once per folder, and a clear message if I refuse.
36. As Gleb, I want nothing about my files to leave the Mac or reach the logs.
37. As the builder, I want a preview flag that shows the targets and each pill state with fake data, so that I can check them on screen without dragging.

## 5. Implementation decisions

### 5.1 What converts [Gleb Q1, Q4]

| Kind | In | Out |
|---|---|---|
| Photo | still HEIC, HEIF, WebP, AVIF, PNG, JPEG, TIFF | JPEG or PNG |
| Recording | QuickTime movie (.mov, .m4v) with a video track | MP4 |

- The kind is the file's type as macOS reports it. The content is read only when converting, so a .zip renamed to .jpg gets targets and then fails cleanly (§7.2).
- Not photos [my call]: GIF, PDF, SVG, ICNS, PSD and RAW camera files get no targets. An image with more than one frame (animated WebP or AVIF, a HEIC sequence, a multi-page TIFF) fails when converted with "animated images aren't supported", rather than silently losing frames.
- `.mp4` is not an input: it is already the output. WebM, MKV and AVI can't be opened by macOS at all (verified 2026-11-23).
- Out: JPEG at quality 0.9 [my call]; PNG; MP4 with H.264 video and AAC audio [Gleb Q9].
- Impossible with built-ins (verified 2026-11-23 on macOS 26.4.1): writing WebP, JPEG XL or MP3.

### 5.2 Where results go [Gleb Q2, Q3]

- Next to the original: same folder, same name, the new extension in lower case: `IMG_1234.HEIC` becomes `IMG_1234.jpg` [my call on `.jpg`, `.png`, `.mp4`].
- **Name taken:** " 2", " 3" and so on before the extension, like Finder: `IMG_1234 2.jpg`. The check follows the disk, so on a case-insensitive disk an existing `IMG_1234.JPG` counts as taken.
- **Never overwrite**, even when another app takes the name mid-conversion: the result is written in full in the app's own temporary folder and moved into place only under a name that is still free, so Gleb's folder never holds a half-written file [my call].
- The original is opened read-only and never changed.
- **The folder can't take new files** (a read-only disk, a mounted disk image, no write permission): the result goes to Downloads, and the pill says "in Downloads".
- **macOS folder access.** macOS asks once before any app may write in Desktop, Documents or Downloads ("Claude Widget would like to access files in your Desktop folder"). Reading the dropped file needs no prompt; saving a new file next to it probably asks once per folder (to measure, §9). If Gleb refuses, that save fails with a pill telling him where to allow it, and the result does **not** go to Downloads instead [my call: after "Don't Allow", a file appearing somewhere else would be a surprise].
- **Fileless drop** (Photos, the screenshot thumbnail, a browser image): Downloads. The name is the one the source gives (the photo's file name, the last part of the image's web address without its query), else "Image" [my call].
- In a batch, each result goes next to its own original.

### 5.3 Targets: choosing the format by dropping [Gleb Q5, Q6, Q8]

- Only the targets drop down, not the hub [Gleb Q6]: glass tiles under the notch, one per format, side by side, each about the size of the alert pill. Each names its format in large type, with a short line under it such as "smaller, for sharing", "lossless, keeps transparency", "1080p, plays everywhere" [my call; wording left to the builder].
- If the hub is open when a file drag arrives, the targets replace its content until the drag ends. Then the hub comes back if the pointer is still over it, and otherwise closes as usual.
- **Which targets fit:**
  - every file a photo: JPEG and PNG, minus a format every one of them already is (all JPEG: PNG only; all PNG: JPEG only; JPEGs and PNGs together: both);
  - every file a recording: MP4;
  - anything else (a photo with a recording [Gleb Q8], a photo with a .zip or a folder [my call]): no targets, and the notch doesn't react. A drop never leaves files behind silently.
  - Fileless items count by the type their source announces (Photos announces the promised file types; a browser the image data's type).
- **Skips** [Gleb Q8]: an original already in the chosen format is skipped and counted ("2 already PNG"). A fileless item is never skipped: it is converted, which also removes its location, and saved to Downloads [my call: there is no original on disk to fall back on].
- Letting go on a target starts the conversion. Letting go anywhere else, including the notch between the tiles, does nothing and macOS slides the files back [my call].
- The target under the pointer lights in the theme accent [my call].
- No limit on files per drop; they queue [my call].

### 5.4 When targets appear [my call]

- A drag carrying files that fit (§5.3) enters the notch zone (the area whose hover opens the hub: the notch plus 16 pt each side, widened by the strip while it shows) and stays 150 ms, the hub's hover dwell. A file swept through faster shows nothing.
- They stay while the pointer is in the notch zone or within 30 pt of the targets (the hub's close margin), leave 300 ms after it moves away, and leave at once when the drag ends anywhere else.
- **Never while:**
  - the setting is off;
  - the front app is full screen on that screen: its own tabs and toolbar sit where the menu bar was, so a file dragged to a browser's tab bar would hit the notch (the same rule as hover);
  - the drag started in this app (dragging a result out of the pill passes the notch).
- "Open on hover" doesn't apply: it protects against the pointer brushing past, and a file held still over the notch is deliberate.

### 5.5 Catching the drag [my call; measured first, §9]

What is known (2026-11-23):
- While a mouse button is held, macOS sends "mouse dragged" events instead of "mouse moved", so the hub's hover tracking goes quiet during a drag [expected; to measure].
- Watching another app's mouse events needs no permission; only key events do [SDK headers].
- The drag pasteboard (where the dragging app puts what is being dragged) can be read by this app [verified]. It keeps the last drag's contents after that drag ends [verified: a leftover was read].

The design:
- A global "mouse dragged" watcher, running only while the setting is on. It does nothing until the pointer reaches the notch zone or the critter.
- **A drag counts only if it is new:** the drag pasteboard's change count went up since the last mouse-down. Selecting text, moving a window or drawing a selection rectangle in Finder doesn't change it, so a pasteboard still holding files from an earlier drag never shows targets. This rule lives in Core and is unit-tested (§7.1).
- The pasteboard's types are read once per drag, when the pointer first reaches the zone, never for drags that stay away from it. Only the types and the files' types are read, never contents, until the drop.
- A "mouse up" watcher ends the drag state.
- The hub panel's mouse gate opens over the targets while they show, so the drop lands in the panel (assumed: a panel that ignores mouse events receives no drops). The panel stays never-key and non-activating; the drop must not bring the app forward.
- The drop accepts file URLs, file promises (written by the source app into the app's private temporary folder) and image data. That folder is emptied after each batch and at launch.

### 5.6 Photos

- **Location removed** [Gleb Q10]: no GPS in the EXIF or XMP metadata. ImageIO's "exclude GPS" option does this, and its header says it can't clean a camera's maker note or custom XMP, so the test checks the result itself (§7.2).
- **Kept** [Gleb Q10]: date, camera and lens, color profile (Display P3 stays P3).
- **Upright in every app:** the rotation is applied to the pixels and the orientation tag reset to normal, because some apps ignore the tag, mostly for PNG [my call].
- **Transparency to JPEG:** flattened onto white [my call]. PNG keeps it.
- HDR (the iPhone's extra brightness layer) is not kept; results are standard range [my call].
- Raw image data from a browser follows the same rules for whatever metadata it carries.

### 5.7 Recordings [Gleb Q9]

- MP4 with H.264 video and AAC audio, scaled to fit within 1920 × 1080, keeping its shape and never enlarged. A 3024 × 1964 Retina recording becomes about 1663 × 1080.
- **Already H.264 and within 1920 × 1080:** only the container changes, with no re-encode: near instant, same quality, same size. If the container change alone can't make an MP4 (the audio isn't AAC, say), it is re-encoded [my call]. Anything else (larger, HEVC like iPhone videos, ProRes) is re-encoded.
- **Location removed** [my call, extending Gleb Q10]: screen recordings carry none, but iPhone videos dragged from Photos do. AVFoundation's sharing filter removes it, on both paths.
- A movie without a video track fails with "has no video" [my call].
- **Crash guard:** the export starts only after AVFoundation confirms that the preset and MP4 fit the file. Asking it for an output it can't make raises an Objective-C exception that kills the app, not a Swift error (verified 2026-11-23, contrary to Apple's docs).
- Progress comes from AVFoundation's export states (macOS 15 and later).

### 5.8 The convert pill [Gleb Q7, Q8]

- It uses the pill slot under the notch, or under the critter. One pill covers the whole queue.
- **Fetching:** "Getting 3 photos…" while Photos or a browser delivers fileless items. A photo kept only in iCloud downloads first, which can take a while [my call].
- **Converting:** "Converting IMG_1234…" or "Converting 3 of 7", a progress bar in the theme accent, and × to cancel [my call]. Cancel stops the current file, removes its partial file, and drops the rest of the queue; results already saved stay.
- **Done:** the result's thumbnail with "IMG_1234.jpg saved" or "7 files saved", plus "· 2 already PNG" or "· in Downloads" when they apply. Dragging the thumbnail drags all of the batch's results into any app. Clicking shows them selected in Finder. The pill hides after 5 s, like the finished pill, and never while the pointer is on it.
- **Failed:** "Couldn't convert IMG_1234.heic" with the reason in plain words: "the file is damaged or isn't a photo", "animated images aren't supported", "not enough disk space", "macOS blocked saving to Desktop: allow Claude Widget in System Settings › Privacy & Security › Files & Folders". A mixed batch reads "5 saved · 2 couldn't convert" with the first reason; a click shows the 5. The pill hides after 8 s, never under the pointer. No retry button. No red or orange, since those mean Claude needs you: a plain warning symbol [my call].
- Files dropped while a batch runs join the queue, and the pill counts them all.
- Quitting during a conversion cancels it and removes the partial file.
- The convert pill shows even with "Show alerts proactively" off: it answers something Gleb just did, so it is not an alert [my call].

### 5.9 Alerts, the hub and the strip [my call, from Gleb's "alerts win"]

- The pill slot's order: needs-you (with or without a permission request), then convert, then finished.
- A needs-you pill arriving while targets show waits until the drag ends, so a target never moves out from under the pointer. A permission request waits up to 30 s for an answer; a drag lasts a second or two.
- A needs-you pill takes the slot from the convert pill. The conversion carries on, and the convert pill returns when the slot is free again, unless its 5 s (or 8 s) ran out meanwhile.
- The now-playing strip stays while targets show (it counts as the notch) and hides under the convert pill, as it does under any pill.

### 5.10 No notch: the critter [Gleb Q11]

- Dragging files that fit onto the critter and holding 150 ms shows the same targets under it, placed where a critter-opened hub would be. This works on any screen whose menu bar shows the critter, the notched one included [my call].
- The pill shows under the critter too, as alerts already do there.

### 5.11 Settings, logs, preview [my call]

- Settings, Notch section: **Convert files dropped on the notch**, on by default. Off: no drag watching and no pasteboard reads. UserDefaults key `convertEnabled`.
- Logs hold state changes in fixed words only (targets shown, drop accepted with a count, done with counts, the failure kind), never file names, paths or contents. Nothing leaves the Mac.
- An argument-domain flag, `-convertPreview <state>` (photo targets, recording targets, fetching, converting, done, failed), shows that state with fake data and no files, for live checks and screenshots. It never reaches users.

### 5.12 Shape of the code

- **Core (`ClaudeWidgetCore`, unit-tested, no AppKit):**
  - convert rules: the kind of each dragged item (from its type and whether it is fileless); the targets for a drag; whether a drag is new (change counts); the plan for a batch (convert or skip, the result's folder, a free name); the pill text for each state;
  - a converter: photo and recording conversion with ImageIO and AVFoundation, from an input file to a finished result in the temporary folder, including location removal, the container-only path and the crash guard;
  - a queue: runs batches in order with the converter passed in, reports progress, cancels, removes partial files, and counts saved, skipped and failed.
- **App:**
  - a `ConvertController`: the drag and mouse-up watchers, the dwell, the drop (file URLs, promises, image data), moving results into place, and the convert state on `HubModel`;
  - `HubController`: a fourth state, targets, beside hidden, pill and expanded, placed under the notch or the critter, with the mouse gate covering the targets. `Pill` gains a convert case with the order of §5.9;
  - `HubView`: the targets and the convert pill;
  - the Settings toggle, and a README section "Convert".
- `NotchStripController` is unchanged: it already hides under any pill.

## 6. Approaches considered

- **The converter:** macOS built-ins, ImageIO and AVFoundation (chosen): all three outputs, no dependency, under a second for photos and short clips (measured 2026-11-23). A bundled ffmpeg would add WebP, MP3, GIF and WebM, at the cost of a large binary with GPL or LGPL duties to sign and ship, for formats Gleb didn't ask for. Running `sips` or `avconvert` uses the same engines with worse progress and errors.
- **Choosing the format** [Q5]: drop onto it (chosen); drop, then click; no choice.
- **While dragging** [Q6]: targets only (chosen); the whole hub with a Convert row.
- **After the drop** [Q7]: a pill (chosen); nothing but a haptic tap; a Convert card with history.
- **MP4 size** [Q9]: a 1080p copy (chosen); the same size; both, as two targets.
- **Not building it:** Finder's Quick Actions already convert. This feature exists for the one drag from any app (Q3).

## 7. Testing decisions

A good test checks what Gleb would see (the targets offered, the files written, the metadata in a result) through the highest seam, with no stand-ins for ImageIO or AVFoundation. Tests work in temporary folders only and never write in Desktop, Documents or Downloads: the Downloads folder is passed in. Prior art: `NowPlayingTests` (pure rules from fixed inputs), `SignInRenewerTests` (a sequence with fakes and a real file in a temporary folder), `HookProcessTests` (a real process). Three levels [Gleb Q12]:

### 7.1 Rules (Core, no files)

Should happen:
- Targets: HEIC, HEIF, WebP, AVIF or TIFF gives JPEG and PNG; all JPEG gives PNG; all PNG gives JPEG; JPEG with PNG gives both; .mov or .m4v gives MP4; a Photos promise of HEIC gives both; a browser's PNG data gives JPEG.
- Names: `IMG_1234.HEIC` → `IMG_1234.jpg`; taken → `IMG_1234 2.jpg`; that also taken → `IMG_1234 3.jpg`; `my.photo.v2.heic` → `my.photo.v2.jpg`; a web image `photo.webp?size=large` → `photo.png`; no name → `Image.png`.
- Skips: two JPEGs and a HEIC onto PNG convert 3; onto JPEG, 1 converts and 2 are skipped; a fileless JPEG onto PNG goes to Downloads.
- Folders: a writable folder keeps the result; a read-only folder or one without write permission sends it to Downloads; a fileless drop goes to Downloads.
- A drag whose change count went up since the mouse-down is new.
- Pill text: one file and many, skips, "in Downloads", failures.

Must not happen (principle 6: what else could this match?):
- **No targets for:** a photo with a recording; a photo with a .zip; a photo with a folder; GIF, PDF, SVG, ICNS, PSD, a RAW camera file, .mp4 or WebM; a drag with no files (text, a link, a browser tab); an empty drag.
- **Stale pasteboard:** after a file drag ends, selecting text, moving a window or drawing a Finder selection rectangle near the notch (no change-count bump, old files still on the pasteboard) is not a drag.
- A drag that began in this app shows no targets.
- A drag through the zone in under 150 ms, a drag while the front app is full screen, and a drag with the setting off show nothing.
- Names: never a name that exists; never touches the original's name; keeps a " 2" already in it (`IMG 2.heic` → `IMG 2.jpg`, then `IMG 2 2.jpg`); pill text never contains a folder path.
- A folder macOS refused ("Operation not permitted") is a failure, never Downloads.
- Order: a needs-you pill arriving mid-drag waits until the drag ends and no longer; a finished pill never replaces a running convert pill.

### 7.2 Converter (Core, tiny real files in a temporary folder)

Committed fixtures, each a few KB: an iPhone-style HEIC with GPS, orientation 6 and Display P3; a PNG with transparency; a WebP; a 2 s 2560 × 1600 H.264 .mov with AAC; a 2 s 1280 × 720 H.264 .mov with a location item; a 2 s 1080p HEVC .mov with a location item; a .zip renamed .jpg; a truncated .mov; an audio-only .mov; an animated WebP.

Should happen:
- HEIC → JPEG: no GPS in EXIF or XMP; date and camera kept; P3 kept; upright pixels (width and height swapped, orientation normal).
- PNG with transparency → JPEG: the transparent corner comes out white. → PNG keeps the transparency.
- WebP → PNG at the same size.
- 2560 × 1600 .mov → MP4 at 1728 × 1080, H.264 and AAC, duration within 0.1 s (the expected behaviour of the 1920 × 1080 preset for a shape that isn't 16:9; this test proves it).
- 1280 × 720 H.264 .mov → MP4 at 1280 × 720 with the video samples unchanged (not re-encoded), and no location.
- 1080p HEVC .mov → H.264 MP4 with no location.

Must not happen:
- The original changes: it is byte-for-byte the same after every conversion (checksum before and after).
- An existing file is overwritten: the file at the result's name keeps its checksum and the result takes " 2"; an existing `IMG.JPG` sends the result to `IMG 2.jpg`.
- The .zip renamed .jpg, the truncated .mov, the audio-only .mov and the animated WebP each end as a failure: no file at the result's name, nothing left in the temporary folder, no crash.
- An output AVFoundation can't make is refused before the export starts, with no Objective-C exception.
- Cancel mid-export leaves nothing at the result's name and an empty temporary folder.

### 7.3 Queue (Core, a fake converter)

Batches run in order; a drop mid-batch joins the queue; cancel drops the rest and keeps saved results; one failure doesn't stop the others; the counts are right.

### 7.4 By hand [Gleb Q12]

The bundled app, one copy, launched with `-limitsEnabled NO -pushEnabled NO`:
- with the preview flag, every state;
- a HEIC from Finder to JPEG and to PNG; ten photos at once; a recording to MP4; a photo from Photos; an image from a Chrome page; the screenshot thumbnail; the critter on an external display;
- nothing happens for: text, a Chrome tab, a .zip, a window moved along the top, a file swept fast past the notch, a file dragged to a full-screen app's tab bar, text selected right after a file drag;
- a permission request (`scripts/simulate.sh approve`) mid-drag shows once the drag ends; the hub open when a drag arrives; Reduce Motion.

### 7.5 Encoders in tests

Claude Code's Bash sandbox blocks the hardware encoders (HEIC, video), so `swift test` runs with the sandbox off, as builds already do. GitHub's macOS runner is a virtual machine, and whether it can encode H.264 is unknown (§9). If it can't, the encode tests skip there only after a check finds no encoder, with the reason printed, and the builder tells Gleb before merging. They never skip on his Mac.

## 8. Out of scope

- Formats beyond JPEG, PNG and MP4, in or out (see §3).
- Resizing photos, quality settings, trimming, GIFs from recordings.
- A Convert tab or history in the hub. The hub spec planned a Convert tab next to Agents; Gleb chose the pill instead [Q7].
- Converting from the clipboard or a file picker.
- A stable signing identity so macOS stops asking for folder access after each install (a separate follow-up if §9 shows it does).

## 9. Further notes

**First build tasks: measure before relying on it**, as the hub spec did:
1. **Drag probe, with Gleb at the keyboard.** A throwaway panel with the hub's window recipe (a probe script was written in the session scratchpad on 2026-11-23; rewrite it if gone). Check: (a) hover tracking goes quiet during a drag; (b) the global "mouse dragged" watcher fires; (c) a panel ignoring mouse events gets no drops; (d) a never-key, non-activating panel takes the drop without bringing the app forward; (e) the change count goes up once per drag and the file types can be read mid-drag. Repeat with Photos, the screenshot thumbnail and a Chrome image. If (b) or (d) fails, stop and bring it to Gleb.
2. **Folder access prompt.** With the bundled app, the first save into Desktop: does macOS ask, once per folder, and again after a rebuild (the app is ad hoc signed)? Gleb resets it with `tccutil reset SystemPolicyDesktopFolder com.glebstarchikov.claude-widget`. Record the results in this spec.
3. **CI encoders.** Can the macOS runner encode H.264 and decode HEIC?

**Risks:**
- Ad hoc signing may make macOS ask for folder access again after every install.
- A source app may announce a type it doesn't deliver: the drop then fails in the pill, nothing worse.
- A photo kept only in iCloud can take a while to arrive; × cancels.

**Left to the builder:** tile and pill sizes and layout, the tiles' short lines, the highlight, the thumbnail, the wording that maps each error to plain words, and motion (static first, motion last).
