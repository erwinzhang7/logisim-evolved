# Upstream issues this port closes — audited, 2026-09-05

`objectives.md` lists eight upstream issues under "Upstream issues this port closes as a side
effect", all unchecked, none verified. They are the stated argument for the project existing, so
an unverified claim here is worse than no claim: it is a claim that we fixed a stranger's
five-year-old bug, made without looking.

**Standard applied: a test or a measurement, not an argument.** Where a claim rests on reading
code, it is recorded as unverified even when the code looks right. Two entries below reverse the
brief's premise, and one of them (#2661) reverses a claim written into a source file.

All eight were confirmed **OPEN upstream** on 2026-09-05 via `gh issue view` against
`logisim-evolution/logisim-evolution`; titles and dates in the table are from that fetch, not from
memory.

## Verdicts

| # | upstream title | opened | port verdict | evidence |
|---|---|---|---|---|
| 2699 | macOS app fails Gatekeeper; Homebrew cask deprecated | 2026-06-25 | **open** | `spctl -a` rejects our binary; ad-hoc signature, not a bundle |
| 747 | Firewall warning when launching Logisim-evolution | 2021-07-01 | **closed by construction** | zero network fds measured at startup; the one socket is the Telnet terminal's, opened only when a circuit uses it |
| 786 | Redrawing of GUI-windows | 2021-07-11 | **partly closed** (mechanism closed, no oracle) | 2.03 ms/frame at 5,000 components vs upstream's ~20 fps cap |
| 2661 | Text labels on canvas don't adapt to dark/light theme | 2026-06-09 | **open**; premise was wrong; one half since fixed | `UpstreamIssue2661Tests`: labels still frozen. `Text` drew nothing: **fixed 2026-09-06**, see below |
| 1262 | better mouse controls (zoom and panning) | 2021-10-23 | **closed** | `UpstreamIssue1262Tests`, 6 tests |
| 2680 | Minor issues with the Preferences dialogue | 2026-06-18 | **closed** | measured window geometry + AX state on a dual-screen Mac |
| 1546 | Command-line verification cleanup | 2022-09-25 | **in flight** | owned by another agent today; not audited |
| 6 | Add an FSM editor | 2015-04-24 | **open** | greenfield; absent from the tree |

Net: **three closed with evidence, one closed by construction, one partly closed, two open, one in
flight.** The headline correction is #2661, which was being described in-tree as fixed and is not.

---

## Preliminary — the app product opens a window

Nobody had confirmed this; the app product landed the same day. It is worth more than several of
the entries below, because every `LogisimUITests` result until now was a library-level result and
not evidence that the shell runs.

`swift build --product logisim-evolved-app` (18.96 s), then run the bare binary:

* survives 18 s, RSS ~200 MB, registers with the window server;
* **one on-screen window, 1280×820, title "Untitled – main"**, `AXStandardWindow`;
* full menu bar: Apple, logisim-evolved-app, File, Edit, View, Arrange, Circuit, Simulate,
  Window, Help;
* the window contains the sidebar with all 12 builtin libraries (Wiring, Gates, Plexers,
  Arithmetic, FP Arithmetic, Memory, Input/Output, TTL, TCL, BFH mega functions,
  Input/Output-Extra, Soc), a toolbar, an attribute inspector bound to the `main` circuit, a zoom
  control reading 99%, and a status reading "Idle".

So the shell runs, the library registry is reached at startup, and the inspector is bound. This
does **not** show that editing works; `ToolCanvas` conformance is a separate question, and no
component was placed in this session.

Caveat worth recording: the product is a **bare Mach-O executable, not a `.app` bundle**
(`file` says "Mach-O 64-bit executable arm64"). It still gets a menu bar and a Dock presence, but
this is the reason #2699 cannot be closed by anything short of real packaging.

---

## #747 — firewall warning on launch → **CLOSED BY CONSTRUCTION**

Open since 2021-07-01, 13 comments. Upstream title: *Firewall warning when launching
Logisim-evolution*. The reporter had assumed it was the auto-updater, which had already been
removed in PR #650, and observed the warning persisting afterwards. **The thread never identifies
the cause.**

### The brief's premise ("it is the JVM opening a socket") is wrong, and that is measurable

A minimal Swing app, `JFrame`, `setVisible(true)`, sleep, compiled and run on the same
`openjdk@21` that runs the oracle jar:

```
[MIN-SWING] ALL network fds (lsof -nP -a -p PID -i):
[MIN-SWING] count of network fds: 0
```

Zero. A JVM showing an AWT window opens no socket. So the warning is Logisim's own code.

*(Method note: `lsof` **ORs** `-p` and `-i` unless you also pass `-a`. The first run of this probe
without `-a` printed every socket on the machine and looked like a positive result. Anything
citing `lsof -p … -i` without `-a` should be re-run.)*

### The real cause, traced to one line

Running the actual 4.1.0 jar and filtering correctly:

```
java 39321 erwin 9u IPv6 … TCP *:57732 (LISTEN)
```

One listener, on the **IPv6 wildcard**: all interfaces, which is exactly the bind that makes the
macOS Application Firewall prompt. A loopback bind would not.

The chain, all in the 4.1.0 tree (D16):

```
ProjectActions.java:147   new Frame(newProject)                       // ordinary startup
  → Frame.java:208        project.getVhdlSimulator()                  // UNCONDITIONAL in the ctor
  → Project.java:418      if (vhdlSimulator == null) vhdlSimulator = new VhdlSimulatorTop(this)
  → VhdlSimulatorTop:47   private final SocketClient socketClient = new SocketClient();  // field init
  → SocketClient.java:45  server = new ServerSocket(0);               // wildcard bind
```

Isolated and confirmed by running that constructor alone against the shipped jar:

```
[BEFORE new SocketClient()] listeners:
  (none)
getServerPort() = 58172
[AFTER  new SocketClient()] listeners:
java 44530 erwin 6u IPv6 … TCP *:58172 (LISTEN)
```

So: **opening the main window binds a wildcard TCP port, on every launch, for a VHDL/TCL
co-simulation bridge that is never used unless you place a VHDL entity.** `Frame.java:208` only
wants to attach a state listener; forcing the lazy getter is an accident of ordering. Worth
reporting upstream; five years of thread and nobody has this.

### Why the port cannot reproduce it

Not "we didn't add one"; there is nothing in the tree that could:

* **Exactly one file imports a networking framework, and nothing reaches it at startup.**
  `LogisimUI/Io/TelnetNetworkTransport.swift` imports `Network` and owns the one `NWListener`
  in the tree. No `CFNetwork` and no `URLSession` anywhere.
  **UPDATED: this bullet read "no networking framework is imported anywhere" when it was
  written, and the transport landed after that.** The measurement it was supporting is
  unchanged, because what closes #747 is the binding being lazy, not the import being absent.
* The one component that legitimately needs a socket, `Telnet`, is split at a seam:
  `LogisimStd/Io/TelnetServer.swift` keeps the whole model (ring buffer, IAC filter,
  one-server-per-port holder) and pushes the transport out behind
  `TelnetServer.transportFactory`, which is **`nil` by default**. Its only call site is
  `TelnetServer.init`, reached only from `TelnetServerHolder.server(port:bufferSize:)`, reached
  only from `Telnet.propagate`. `TelnetServerHolder.shared` is a lazy singleton over an empty
  dictionary. With no factory installed there is no code in the module that could bind a port.
* Upstream's own scoping for `TelnetServer` was already lazy in the same way; what the port adds is
  that `SocketClient`'s eager field initialiser has **no counterpart at all**, because the VHDL/TCL
  simulator bridge is a D11 permanent gap on macOS.

### Measured on the port

The running app, probed identically to the jar:

```
=== network fds (lsof -nP -a -p PID -i) ===
network fd count: 0
=== LISTEN ===
(none)
```

**Zero sockets, zero listeners, no firewall prompt.** Structural, not incidental.

---

## #2661 — canvas text and the dark/light switch → **OPEN.** The premise was wrong

This is the entry that most needed auditing, because the port asserts in two source comments that
it fixes this issue, and the assertion does not survive measurement.

### What the issue actually says

Title: *Text labels on canvas don't adapt to dark/light theme switch.* Body:

> When switching between light and dark themes, text labels placed on the canvas (via the text
> tool) keep their original color and don't adapt to the new theme.
> **Root cause:** Each text label stores its own `ATTR_COLOR` at creation time. The
> `TEXT_TOOL_COLOR` preference only affects newly created labels; existing labels are unaffected
> by `applyThemeColors()`.

The issue then notes this is *not* a simple fix, because auto-inverting user-chosen colours would
destroy deliberate choices, and lists three candidate designs (auto-invert only defaults; a
per-label "auto" option; a global preference).

**So #2661 is about per-instance stored label colour, not about `Value.java`'s static colour
fields.** The `Value.java:296-304` story, nine `public static Color` frozen at class-load,
reassigned only from the preferences dialogue at `SimOptions.java:453-486`, is real and the port
genuinely improves on it, but it is a *different* defect. Attributing it to #2661 is what let the
"fixed properly" claim stand.

### What the port actually does

Measured with `swift test --filter UpstreamIssue2661Tests` (new file,
`swift/Tests/LogisimUITests/UpstreamIssue2661Tests.swift`, 4 tests, all green):

| channel | mechanism | follows appearance? |
|---|---|---|
| 12 simulation value colours | reserved `PaletteIndex` resolved through `RenderOptions.theme` per frame | **yes**, free, no geometry touched |
| component body ink | `CircuitSceneSource.paintContext` passes `componentColor: palette[.componentStroke]`; `CircuitSceneGeometryKey` includes `ink`, so a flip rebuilds | **yes**, measured, >100 px move with the background held constant |
| **component labels** | `InstancePainter.drawLabel()` :665-666 → `attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor)` = `Color.BLUE` | **no** |
| **free `Text` annotations** | ~~`LogisimStd/Base/Text.swift` has no `paintInstance` at all~~ → `LogisimStd/Base/TextPainter.swift` adds `extension Text: InstancePaintable` | **FIXED 2026-09-06.** `painted=0 prims=0` → `painted=1 prims=1`. Colour still frozen, like component labels |

**UPDATED 2026-09-06 — the `Text` row above was true when measured and is not any more.** The
audit's own aside ("worse, and this is the part to chase first: `Text` draws nothing") was acted
on the same day: `Text` conformed to neither paint protocol, so `CircuitRenderer.render` matched
neither of its two casts and every free-floating annotation was invisible. A painter was added
and the probe moved from `painted=0 prims=0` to `painted=1 prims=1`.

Two further defects were found stacked underneath it, so #2661 stays **open** and the colour half
is untouched:

* the app's `TextTool` was constructed with no factory, so every click was a silent no-op; fixed;
* `TextEditable` has no conformer and **cannot** have one as declared, because it lives in
  `LogisimUI` and every component that could implement it lives in `LogisimStd` below it. Board
  #23. So a click still creates nothing.

Kept as a strikethrough rather than a rewrite: this table is the evidence for a claim about
someone else's five-year-old issue, and what it said when measured is part of the evidence.

The label result is the one that matters, and it is a direct measurement rather than a reading: an
AND gate with `StdAttr.label = "Q"` was rasterised twice with palettes differing in **exactly one
entry** (`ChromeRole.componentStroke`), background held identical, and the count of pixels exactly
equal to `defaultLabelColor` was **non-zero and identical** in both. The label draws, and it does
not move.

### Why the existing test did not catch this

`CanvasDrawsTests.darkModeChangesThePixels` flips `.light` → `.dark` and asserts
`lightRaster.bitmap.pixels != darkRaster.bitmap.pixels`. It is real, it passes, and it **cannot
fail for the right reason**:

1. its fixture `demoCircuit()` places three gates and four wires: **no text of any kind**; and
2. `.light` and `.dark` differ in `canvasBackground`, so whole-bitmap inequality is satisfied by
   the background alone.

Freeze every glyph in the program to black; i.e. reintroduce the exact upstream bug, and that
assertion still passes. This is the same shape as the `rig.py` simulation-mode defect and the
canonical column a literal `cp` satisfies: a gate whose green light is not evidence. The new suite
holds the background constant so the only remaining variable is ink.

### Four concrete gaps, none of which I own

1. `InstancePainter.drawLabel()` has no palette input. `LogisimFile/StdAttr.swift:89` already
   declares `darkDefaultLabelColor = 0x6CB6FF` and **nothing reads it**; the fix is stubbed, not
   wired.
2. `ChromeRole.label` and `ChromeRole.pinLabel` are defined in both palettes, `.label` at
   `Palette.swift:197` (light) and `:232` (dark), `.pinLabel` at `:198` and `:233`, and are read
   by **no drawing code anywhere**.
   Exhaustively: the only `palette[.…]` chrome lookups in `Sources` are `canvasBackground`,
   `gridDot`, `gridLine`, `componentStroke`, `componentFill`, `halo`, `selectionStroke`,
   `selectionFill`, `marqueeStroke`, `marqueeFill`. `label`, `pinLabel` and `tickMarker` are dead.
3. `Text` is a codec-only port with no painter, so the text tool's output is invisible. Its
   `attrColor` **already reproduces upstream's root cause**, per-instance stored colour, so
   whichever of the issue's three designs is chosen has to be chosen here too.
4. The `MemPaint.componentColor` family: `MemPainter.swift:299` is
   `public static let componentColor = SceneColor.rgb(0x00_0000)`, a frozen literal black used at
   **34 sites across 7 files** (`AbstractFlipFlop`, `Counter`, `DualRamAppearance`, `RamAppearance`,
   `RandomGenerator`, `Register`, `ShiftRegister`). Because it is a static rather than
   `painter.componentColor`, an ink rebuild cannot move it. This is upstream's own `static Color`
   shape, reproduced. Not separately pixel-tested here; flagged.

### One D16 slip found on the way

`LogisimFile/StdAttr.swift:88-89` cites `StdAttr.DARK_DEFAULT_LABEL_COLOR`. **That constant does
not exist in 4.1.0.** `grep -rn DARK_DEFAULT_LABEL_COLOR upstream-java-4.1.0` returns nothing; it
exists only on `main` (4.2.0-dev), at `StdAttr.java:49`, together with

```java
static Color getDefaultLabelColor() {
  return AppPreferences.isDarkTheme(AppPreferences.LookAndFeel.get())
      ? DARK_DEFAULT_LABEL_COLOR : DEFAULT_LABEL_COLOR;
}
```

consumed at `InstanceTextField.java:84`. So **upstream has begun fixing this after 4.1.0**, keyed
off the Swing look-and-feel preference rather than the system appearance. Two consequences: the
port's current behaviour is *correct for its target* and should not be "fixed" casually; and the
port already carries one main-branch constant, which is the D16 hazard that entry exists to
prevent.

### Verdict

**Open.** The colour *infrastructure* is genuinely better than upstream's and is now measured to
work for value colours and body ink. The thing the issue is actually about, text labels, is not
addressed, and the port has inherited the same root cause in its data model.

---

## #786 — GUI redraw → **PARTLY CLOSED** (mechanism closed and measured; no oracle)

Open since 2021-07-11, 21 comments. Upstream title: *Redrawing of GUI-windows.*

### Upstream, verified in the 4.1.0 tree

* **Hard frame cap.** `CanvasPaintCoordinator.java:36-39`:
  ```java
  // We use a variety of times around 50ms to avoid common factors
  // with the auto-tick frequencies.
  private static final int[] REPAINT_TIMESPANS = new int[] { 47, 53, 49, 51, 50, 47, 53, 50, 48, 52 };
  ```
  ~50 ms between repaints: **~20 fps, regardless of how cheap the frame is.** The rotation exists
  to avoid resonating with tick frequencies, which tells you the cap is a defence, not a tuning
  choice.
* **No culling anywhere.** `Circuit.draw` (`Circuit.java:466`) iterates `comps` unconditionally.
  `grep -n "getClipBounds\|clipBounds"` over `gui/main/Canvas.java` and `circuit/Circuit.java`
  returns **nothing**, so the visible rectangle never reduces the work.
* **A `Graphics2D` clone per component per frame**, at `Circuit.java:474` and `:484`.

**Correction to D6.** D6 says "two `Graphics2D` clones per component (`Circuit.java:540`, `:550`,
10,000 clones/frame at 5,000 components)". Both halves are off:

* the cited lines are `getAllWithin`, not the paint loop; the clones are at **`:474` and `:484`**
  in the 4.1.0 tree (the quoted numbers look like main-branch lines, the same D16 hazard as
  above);
* `:474` and `:484` are in **mutually exclusive branches** of `if (isNullOrEmpty(hidden))`, so it
  is **one clone per component**, plus one for the frame, ~5,001 clones/frame at 5,000
  components, not 10,000.

The conclusion D6 draws is unaffected, a per-component context clone with no culling under a
20 fps cap is still the defect, but the number and the citation should be fixed. I do not own
`docs/decisions.md`; exact change requested at the end.

### The port, measured

`swift test --filter TextCacheAndThroughputTests`, **debug build** (so these are pessimistic):

```
[throughput] 5,000-component schematic, 1280x800 viewport:
             2.031958 ms/frame, 117 groups drawn, 313 draw calls
[throughput] 2,000-component schematic, zoomed to fit (nothing culls):
             15.888208 ms/frame, 6000 draw calls
```

117 of 5,000 groups drawn is the culling working: the frame costs O(visible), not O(all). 2.03 ms
is ~490 fps against upstream's 20 fps ceiling, and even the deliberately uncullable case
(15.9 ms, ~63 fps) is three times upstream's cap. `CullingTests` passes 10/10, including exactness
at the boundary, negative coordinates, painter's-order preservation and oversized groups.

Supporting mechanisms, all tested: `aStringIsShapedOnceAndThenReused`,
`repaintingASceneReshapesNothing`, `aPerFrameColourUpdateTouchesNoGeometry`,
`theCacheKeyIsFontAndStringOnlyNotColour`.

### Why "partly", not "closed"

The performance mechanism is closed and measured. But #786's 21 comments are about *observed
redraw behaviour* in a running app, flicker, stale regions, windows not refreshing, and this
port has:

* no image-diff oracle for the canvas yet (M6's stated pass condition, perceptual diff against
  Java `ExportImage` at 3 zoom levels, is not in place);
* no test that the **invalidation rectangle** in `CircuitCanvasSurface.invalidate(worldRect:)` is
  correct rather than merely present; an under-invalidating rect produces exactly the stale-region
  artefacts the issue describes, and would not show up in a throughput number;
* no measurement under live simulation, which is when upstream's cap actually bites.

**What would settle it:** a test that dirties a known world rectangle, captures the set of pixels
that changed, and asserts it is contained in the invalidated view rectangle; plus the M6
perceptual diff. Until then the honest claim is "the frame is 8–250× cheaper and uncapped", which
is worth stating on its own and is not the same as "issue closed".

---

## #1262 — better mouse zoom and panning → **CLOSED**

Open since 2021-10-23. Upstream title: *Feature Request: better mouse controls (zoom and panning).*

Implemented before this audit; **untested** before it. Now covered by
`swift/Tests/LogisimUITests/UpstreamIssue1262Tests.swift`, 6 tests, all green.

Upstream, verified in the 4.1.0 tree:

* the canvas is a `JScrollPane` over a component whose preferred size is content × zoom, so zoom
  resizes a Swing component;
* the anchor is re-derived from ratios and then **rounded to integer scrollbar values after a
  `doLayout()` that has already clamped them**: `Canvas.java:699-708`:
  ```java
  viewport.doLayout();
  setHorizontalScrollBar((int) Math.round(newViewOffsetX));
  setVerticalScrollBar((int) Math.round(newViewOffsetY));
  ```
  rounding + clamping is why the anchor drifts;
* scroll range *is* content size, so you cannot scroll past the edge to place something left of the
  leftmost component;
* plain scroll is bound to integer wheel notches: `Canvas.java:917-921`,
  `scrollBar.setValue(scrollValue(bar, mwe.getWheelRotation()))`, so trackpad panning is steppy
  with no inertia;
* Swing has **no pinch event at all**: `grep -rn magnif` over `gui/main/` finds only
  `SimulationTreeRenderer`'s "magnifying glass" icon comment.

The port: `CanvasHostNSView` implements `magnify(with:)` (continuous pinch, anchored on the
centroid), `smartMagnify(with:)` (two-finger double tap toggling fit / 100%), and
`scrollWheel(with:)` honouring `hasPreciseScrollingDeltas` with ⌘/⌃ as the zoom modifier.
`CanvasViewport` is a continuous `(center, zoom)` camera.

Measured, not read:

| property | result |
|---|---|
| anchor held over **60 chained zoom steps** (drift is cumulative; one step proves nothing) | < 1e-6 view points |
| view-point and world-point anchoring agree | exactly equal viewports |
| pan is 1:1 in view points at zoom 0.05 / 0.25 / 1.0 / 3.5 / 10.0 | < 1e-9 |
| camera unbounded: 50 pans of 400 pt leave the content entirely, and return with no clamp error | `< 1e-9` on return |
| zoom clamps to `[0.05, 10]` and still holds the anchor at both limits | < 1e-6 |
| `visibleWorldRect` is the exact preimage of the view bounds (culling depends on this) | < 1e-9 |

**Not covered:** that AppKit actually delivers `magnify`/`smartMagnify` to this view in the running
app; that needs a real gesture and is not scriptable here. The camera maths under those handlers
is now pinned; the event plumbing is read, not measured.

---

## #2680 — preferences dialogue defects → **CLOSED**

Open since 2026-06-18. Upstream title: *Minor issues with the Preferences dialogue.* Body lists
exactly two things:

> - At least on macOS, the Preferences dialogue window isn't opening above the current main
>   window, but often even on a different screen in case of dual screen setups. Could it be that a
>   parent window needs to be set? It should however not block using the parent window.
> - "FPGA Commander Settings" -> "FPGA Commander"; "Hotkey settings" -> "Hotkeys"

### Root cause upstream, which the issue only guesses at

`PreferencesFrame.java:97-104`:

```java
public JFrame getJFrame(boolean create, java.awt.Component parent) {
  if (create) {
    if (window == null) {
      window = new PreferencesFrame();
      window.setLocationRelativeTo(parent);
      ...
```

Two compounding faults. The frame is cached in a **static** `WindowMenuManager`, so
`setLocationRelativeTo` runs **once ever**; every later open reuses a stale position. And the
public entry point passes `null`:

```java
public static void showPreferences() {
  final var frame = MENU_MANAGER.getJFrame(true, null);   // parent == null
```

`setLocationRelativeTo(null)` centres on the **default** screen, not the main window, so the
reporter's guess ("could it be that a parent window needs to be set?") is exactly right, and it is
never set even on the first call.

### Measured on the port, on a real dual-screen Mac

Launched the app, invoked *logisim-evolved-app ▸ Settings…* from the menu bar, then read window
geometry and the accessibility tree:

```
main window      "Untitled – main"  1280×820  at (-1184, -1115)   AXStandardWindow  focused: true
settings window  "General"           560×450  at ( -824,  -930)   AXStandardWindow  focused: false
```

* The negative coordinates confirm a genuine multi-display setup; this is the configuration the
  issue is about.
* Settings spans x ∈ [-824, -264], y ∈ [-930, -480]; main spans x ∈ [-1184, 96], y ∈ [-1115, -295].
  Settings is entirely inside the main window's rect, and **exactly centred on it**; both centres
  are (-544, -705) to the point. Same screen, over the parent. First bullet satisfied.
* **It does not block the parent.** Both are `AXStandardWindow`, neither is `AXSheet` or `AXDialog`
  and neither reports modal; the **main window still holds `focused: true`** while Settings is
  open, and its toolbar controls (Hide Sidebar, Pause Simulation, Step, Start Clock, Inspector) all
  report `enabled: true`. Second half of the first bullet satisfied.
* The second bullet is **moot**: the tabs are General / Appearance / Canvas / Simulation /
  Advanced. Upstream's ten tabs (including "Hotkey settings", `gui.properties:666`, and the FPGA
  Commander pane) collapse to five, and the FPGA/Softwares panes configure vendor toolchains that
  have never shipped for macOS (D11), so they are absent rather than renamed.

Structurally this is closed because it is a SwiftUI `Settings` scene: ⌘, is standard, the system
restores position per-tab, and a scene cannot be stranded on a display that no longer exists. There
is no cached static frame to go stale.

**Caveat:** measured on one machine, one display arrangement, one open. Position restoration
across relaunches and display reconfiguration was not exercised.

---

## #2699 — Gatekeeper and the Homebrew cask → **OPEN**

Open since 2026-06-25. Upstream title: *macOS app fails Gatekeeper; Homebrew cask deprecated and
scheduled for disablement.* D10 records that upstream **cannot** fix this, the maintainers stated
in the issue that they have no paid Apple Developer account, and that this port is meant to,
because it will have one. That remains a plan, not a fact.

Measured:

```
$ codesign -dvvv .build/arm64-apple-macosx/debug/logisim-evolved-app
CodeDirectory ... flags=0x2(adhoc)
Signature=adhoc

$ spctl -a -vvv .build/arm64-apple-macosx/debug/logisim-evolved-app
rejected

$ file .build/arm64-apple-macosx/debug/logisim-evolved-app
Mach-O 64-bit executable arm64          # not a bundle
```

The only `codesign` in the whole repository is SwiftPM's own ad-hoc `codesign --force --sign -`,
emitted into `.build/debug.yaml`. There is no `.app` bundle, no `Info.plist` of ours, no
entitlements file, no `notarytool` invocation, no DMG step, no Homebrew cask, and no bundle
identifier or document UTI (all of which D10 requires, including a UTI distinct from upstream's).

An instructive control: the installed `/Applications/Logisim-evolution.app` on this machine has
already been re-signed locally with `Developer ID Application: <Your Organisation> (<TEAMID>)`, and
`spctl` **still** reports `rejected; source=Unnotarized Developer ID`. A Developer ID signature
alone does not clear Gatekeeper; notarisation is the load-bearing half, which is precisely what
makes #2699 an M8 task rather than a build-flag one.

**Verdict: open, as expected.** Nothing here is a defect; M8 has not started. Do not tick this
box until `spctl -a -vvv` on a distributed DMG returns `accepted`.

---

## #1546 — command-line verification → **IN FLIGHT, NOT AUDITED**

Open since 2022-09-25, 17 comments. Upstream title: *Command-line verification cleanup.* This is
the entry with the most direct bearing on the CSC258 use case; a TA autograding path that works
on macOS.

Another agent owns `logisim-cli` today. Per the brief I did not read into it, did not run it, and
have no verdict. `swift/Sources/logisim-cli/` contains `main.swift`. Re-audit once that lands.

Note for whoever does: upstream's `-n` route is **not headless-safe** (D17: it constructs an AWT
`Window` via `ProjectActions.doOpen` and blocks on modal dialogs for 155 of 594 corpus files), which
is a substantial part of why #1546 exists. Any claim to close it should be measured against
`Main.headless = true` behaviour, not against `-n`.

---

## #6 — FSM editor → **OPEN**

Open since **2015-04-24**; the oldest issue in the set, 12 comments. Upstream title: *Add an FSM
editor.*

Greenfield feature, absent from the tree. `grep -rniE "\bFSM\b|finite state machine|state machine
editor"` over `swift/` returns two hits, both unrelated: `addRemarkBlock("The FSM's are defined
here")` inside `MemoryRamHdlGeneratorFactory.swift`, which is generated VHDL commentary.

It is also absent from upstream, so this is not a port gap. It is a feature the port could add and
has not. Note it would land downstream of `analyze` (truth tables, Quine-McCluskey), which is
itself still in the parity backlog and carries its own hazard: Java `HashMap` iteration order
affects final cover selection.

---

## Changes requested in files I do not own

Reported rather than made, per the brief.

1. **`docs/decisions.md`, D6**: two corrections in one sentence. Current text: "two `Graphics2D`
   clones per component (`Circuit.java:540`, `:550`, 10,000 clones/frame at 5,000 components)".
   Suggested: "one `Graphics2D` clone per component (`Circuit.java:474` / `:484`, mutually
   exclusive branches, ~5,001 clones/frame at 5,000 components)". The line numbers as written point
   at `getAllWithin` in the 4.1.0 tree and look like main-branch numbers.

2. **`docs/objectives.md`**, the "Upstream issues" list; the verdicts table at the top of this
   file. Specifically **do not tick #2661**; it reads as closed in-tree and is not.

3. **`swift/Sources/LogisimUI/Canvas/CircuitCanvasSurface.swift:128-130`**; "which is #2661 fixed
   properly" overstates what is true. The value-colour and body-ink claims hold and are now
   measured; the label claim does not. Suggested: "…which is what makes value re-theming free. Note
   this does **not** close #2661: component labels resolve through `StdAttr.labelColor` and follow
   no palette: see `docs/experiments/upstream-issues.md`."

4. **`swift/Sources/LogisimUI/Canvas/CanvasHostNSView.swift:25-28`**; same correction for the
   `#2661` paragraph. The `viewDidChangeEffectiveAppearance` → `CircuitPalette.resolved(for:)` push
   is real and correct; it just does not reach labels.

5. **`swift/Sources/LogisimFile/StdAttr.swift:88-89`**; the citation `StdAttr.DARK_DEFAULT_LABEL_COLOR`
   is a main-branch (4.2.0-dev) constant with no counterpart at v4.1.0. Either mark it explicitly as
   a forward port from `main` with that caveat, or drop it until #2661 is actually wired. D16 exists
   for exactly this.

6. **`swift/Sources/LogisimUI/Support/Palette.swift`**: `ChromeRole.label`, `.pinLabel` and
   `.tickMarker` have entries in both palettes and no reader. Either wire them (they are the
   natural home for a #2661 fix) or note them as reserved, so the next person does not read their
   presence as evidence the path exists.

7. **Upstream, if anyone is inclined**; issue #747 has run five years without a diagnosis. The
   chain in the #747 section above (`Frame.java:208` → `Project.java:418` → `VhdlSimulatorTop.java:47`
   → `SocketClient.java:45`) plus the before/after `lsof` transcript would close it, and the fix is
   small: make the `Frame` constructor not force the lazy `getVhdlSimulator()`, or make
   `SocketClient` bind lazily / to loopback.

## Reproducing

Probe scripts used for the runtime measurements were scratch files in `/tmp` and are not committed;
each is small enough that the transcripts above are the record. The two committed artefacts are:

* `swift/Tests/LogisimUITests/UpstreamIssue2661Tests.swift`, 4 tests
* `swift/Tests/LogisimUITests/UpstreamIssue1262Tests.swift`, 6 tests

```sh
swift test --filter UpstreamIssue2661Tests     # type name, not display name
swift test --filter UpstreamIssue1262Tests
swift test --filter TextCacheAndThroughputTests # prints the two [throughput] lines
swift test --filter CullingTests
```
