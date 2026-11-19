# Color themes and the New Year hat — design

**Status:** approved by Gleb, 2026-11-19 ("approved"). Short design: a small change on top of the notch hub (`2026-11-17-notch-hub-design.md`).

## 1. Intent

The widget's look came from Gleb's own design system: an indigo critter while Claude works, Claude orange when it needs you. Gleb wants the project to appeal to more people, so the look becomes a choice, and the default is the critter in its own Claude color, the one people know from Claude Code [Gleb: "claude colour by default"]. For this season the critter gets a New Year hat [Gleb].

## 2. Goals, non-goals, anti-goals

- **Goals:** a theme picker with presets and a custom color; "needs you" that reads the same in every theme; a winter hat that switches on by itself around New Year.
- **Non-goals:** per-state colors, themed glass tints, a themed app icon, other holidays (the hat mechanism can take more later, nothing is built for them now).
- **Anti-goals:** any theme in which "needs you" can be missed or confused with "working"; a color that disappears against the light or dark menu bar; a hat that turns the 18 pt critter into a smudge.

## 3. Decisions

### Needs you is no longer a color [Gleb chose B]
In every theme, "needs you" is the existing pulse plus a **red dot** on the critter's top-right corner: system red (`NSColor.systemRed`), ringed in the background color so it separates from the body. No state is told by color alone any more. Text and marks that mean "needs you" (Agents row status, the approval row mark now drawn in `Theme.claudeOrange`) use the same red. Asleep stays the faint gray (45 % opacity); ready/waiting stays the theme color at 70 %.

### Themes [Gleb approved the set; Amber dropped by Gleb]

| Theme | Light bar / light hub | Dark bar / dark hub | Note |
|---|---|---|---|
| **Claude** (default) | `#C36B4E` | `#D97757` | Claude orange; darkened on light bars to reach 3:1 |
| Lime | `#5E9425` | `#6FAE2C` | |
| Mint | `#1C9571` | `#1FA67E` | |
| Ocean | `#2C7FE0` | `#2C7FE0` | |
| Indigo | `#4B46F5` | `#8A86FF` | the original look, original values |
| Violet | `#9459E6` | `#9459E6` | |
| Rose | `#DB4F84` | `#DB4F84` | |
| System | `#1D1D1F` | `#F5F5F7` | matches the other menu bar icons; hub accent is the macOS accent color (`NSColor.controlAccentColor`) |
| Custom | fitted | fitted | any color from a color picker |

No red theme: red means "needs you".

**Contrast rule** (presets above were derived with it; Custom applies it at runtime): the color must reach **3:1** contrast (WCAG relative luminance) against the reference bar — `#ECECEE` for light, `#26262A` for dark. If it doesn't, mix it toward black (light) or white (dark) in 5 % steps until it does.

**What a theme colors:** the critter everywhere (menu bar, hub, pill, Agents rows), the Allow button fill, and the limit bars. The glass itself stays untinted. The light/dark value follows the surface it's drawn on (menu bar appearance for the status item, glass appearance in the hub). Text on the Allow fill is white or `#1D1D1F`, whichever contrasts more with that fill.

### New Year hat [Gleb chose the winter hat with the floppy tip]
A red winter hat (`#D93A3A`) with a white brim and a white pom: the cone sits centred on the body and its tip flops over, so the pom hangs slightly to the side (the second mockup). Drawn in code like the critter, so it stays sharp. The hub also shows a little snow. It switches on by itself from **Dec 15 to Jan 7** (inclusive, local calendar); a Settings switch turns it off.

### Settings
A new **Appearance** section in the Settings window: the theme swatches (System last, then Custom with a color well), and a toggle "New Year hat" (on by default; only visible in effect inside the date window). Stored in UserDefaults: theme id, custom color (hex), hat on/off. Changing a theme recolors everything immediately.

## 4. Approaches

1. **One palette in `Theme.swift`, pure color math and the date window in Core** (chosen). Every color already flows through `Theme.swift` (5 constants, ~10 call sites), so a theme is a palette value swapped in one place; the contrast fit and the date check are pure functions that can be unit-tested.
2. **Asset-catalog colors and a bitmap hat.** Doesn't fit: the app is SwiftPM without an Xcode asset pipeline, and the critter is vector code — a bitmap hat would blur at 18 pt and need @1x/@2x art.
3. **Let people set a color per state.** Rejected: more knobs, and it reopens the "needs you is a color" problem B just closed.

## 5. Constraints

- macOS 26, Swift 5 mode, SwiftPM, no new dependencies.
- The status item critter is drawn at 18 pt from a 24-unit canvas (`CritterGeometry`, `CritterRenderer`). The hat and the dot must fit the status item without clipping and without shrinking the critter so much it reads worse; verify with real-size screenshots on light and dark menu bars.
- Reduce Motion: no pulse (as today) — the red dot alone carries "needs you".
- The existing state logic (aggregate state, pills, approvals) does not change; only how states are drawn.
- README "States at a glance" and the Settings line are updated to match.

## 6. Left to the builder

- Exact hat and dot geometry in canvas units, and how the status item image makes room for them (taller canvas, or a smaller body while the hat is on) — judged by real-size screenshots.
- How the snow looks in the hub (a few flakes, static or slow; respects Reduce Motion).
- Swatch layout in the Settings form.
- Whether `DevTools` snapshot names change.
