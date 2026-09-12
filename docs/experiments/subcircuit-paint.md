# Subcircuit painting — the measurement, the fix, and what is still owed

Date: 2026-09-06. Branch `subcircuit-paint`. Reference tree `upstream-java-4.1.0` (D16).

## 1. The defect, reproduced before touching anything

A parent circuit holding exactly one subcircuit placement, rendered through
`CircuitSceneSource.build`:

```
PROBE parent components: 1
PROBE painted:           0
PROBE primitives:        0
PROBE texts:             0
PROBE contentBounds:     (230.0, 290.0, 70.0, 60.0)
PROBE bounds:            (230,290): 70x60
PROBE ends:              ["(230,300)", "(230,320)", "(300,300)"]
PROBE factory is InstancePaintable: false
PROBE comp is ComponentPaintable:   false
```

**The bounds were right and the ends were right and nothing drew.** `CircuitRenderer.render`
dispatches on exactly two casts: `component as? any ComponentPaintable`, then
`component.factory as? any InstancePaintable`, and `CircuitSubcircuitFactory` matched neither,
so every placement fell out of the walk in silence. Every hierarchical schematic showed blank
space where its blocks were.

The premise held exactly as briefed. `CircuitSubcircuitFactory.swift`'s own header already said
so: "*`SubcircuitFactory.java` is 515 lines and roughly 400 of them are painting … None of that
is ported here.*"

After:

```
PROBE painted:           1
PROBE primitives:        12
PROBE texts:             4
```

## 2. What was written, and where

Three new files, all under `swift/Sources/LogisimStd/Circuit/`, a new directory:

| file | what it is |
|---|---|
| `SubcircuitPainter.swift` | `extension CircuitSubcircuitFactory: InstancePaintable`: `paintInstance`, `paintGhost`, `paintBase`, `paintSubcircuit`, `drawCircuitLabel`, and `configureLabel` as an `InstanceLabelProvider`. |
| `DefaultAppearanceShapes.swift` | `DefaultEvolutionAppearance.build`'s **drawn** half, as `LogisimDraw` `CanvasObject`s. |
| `AppearanceShapePainter.swift` | `CanvasObject.paint` for every `<appear>` shape kind, emitted as `RenderScene` primitives. |

`CircuitSubcircuitFactory` lives in `LogisimFile`, **below** `LogisimStd`, so it cannot name
`InstancePaintable`. The conformance is retroactive from one module up; exactly the move
`TextPainter` makes for `Text`. **`swift/Sources/LogisimFile/` is unchanged.**

## 3. The differential check — shape for shape against the shipped jar

An inked-pixel count proves a canvas is not blank. It does not prove the box is *upstream's*
box. So a Java bridge was written against `/Applications/Logisim-evolution.app/.../
logisim-evolution-4.1.0-all.jar` that dumps
`circuit.getAppearance().getObjectsFromBottom()` with every location made relative to the
anchor: precisely the list and the frame `CircuitAppearance.paintSubcircuit` walks.

Run on a corpus circuit with four west ports (one of them a clock) and one east port. The circuit
is not named here and its labels are replaced below with the neutral ones the test fixture uses:
the corpus is coursework, and the recorded geometry depends on port count, width, order and
clock-ness rather than on what the labels say, so nothing in the measurement is lost by the
substitution. `SubcircuitPaintOracleTests` carries the same dump and the rebuilt fixture.

```
CIRCUIT sample_block_2345678 default=true facing=east offsetBounds=(-220,-11,221,102) anchor=(270,60)
  Rectangle box=(-220,-2,10,4)     paint=fill   stroke=1 fill=Color[0,0,0]
  Text "data"   at=(-205,4)   halign=LEFT  valign=BASELINE fill=Color[64,64,64] font=Courier 10 Pitch plain 12
  Rectangle box=(-220,19,10,3)     paint=fill   stroke=1
  Text "sel1" at=(-205,24)  halign=LEFT
  Rectangle box=(-220,39,10,3)     paint=fill   stroke=1
  Text "sel0" at=(-205,44)  halign=LEFT
  Rectangle box=(-220,59,10,3)     paint=fill   stroke=1
  Poly polyline pts=(-209,56)(-202,60)(-209,64) paint=stroke stroke=2
  Text "clk"  at=(-197,64)  halign=LEFT
  Rectangle box=(-10,-1,10,3)      paint=fill   stroke=1
  Text "out" at=(-15,4)    halign=RIGHT
  Rectangle box=(-210,70,200,20)   paint=fill   stroke=1   <- title bar
  Rectangle box=(-211,-11,202,102) paint=stroke stroke=2   <- outline, STROKE-EXPANDED
  Text "sample_block_2345678" at=(-110,84) halign=CENTER fill=Color[255,255,255] font=... bold 14
```

That circuit is rebuilt pin for pin as a corpus-free fixture in
`swift/Tests/LogisimUITests/SubcircuitPaintOracleTests.swift`, and **all fourteen shapes now
match**, including the 4-bit `SW` stub being one pixel fatter than the others
(`Wire.WIDTH_BUS = 4` vs `Wire.WIDTH = 3`) and the `+8` shift that moves the `Clk` label clear
of its triangle.

### The bug the oracle caught, which reading did not

`Rectangular.paint` reads the **raw** `bounds` field, Java's own comment on it is
`// excluding the stroke's width`, while `getBounds()` inflates a stroke-2 shape by `wid / 2`
on every side. The first version of `AppearanceShapePainter` used `shape.bounds` and drew the
default box's outline at `(-211,-11,202,102)` instead of `(-210,-10,200,100)`: one pixel out
and two pixels too big in each dimension, on **every** subcircuit and every `<appear>`
rectangle, oval and round-rectangle. It rasterised to plenty of ink and looked correct in a
screenshot.

### Reading the two lines that do *not* copy across

* The outline's reported box is the stroke-expanded one, per above. The *drawn* rectangle is
  `new Rectangle(rx + 10, ry, width - 20, height)`.
* `getOffsetBounds()` reads `(-220,-11,221,102)` while the port's *build* box is
  `(-220,-10,220,100)`, because upstream's is the union of every object including that halo and
  the port elements. `CircuitSubcircuitFactory.swift`'s header already documents that ≤2 px
  difference. **It moves no shape**: every coordinate is derived from `rx`/`ry`/`width`/
  `height`, on which the two agree exactly.

### The bridge

Kept out of `tools/`; that directory was not this work's to add to. To reproduce, put this at
`tools/appearbridge/src/com/cburch/logisim/circuit/appear/AppearanceBridge.java`:

```java
package com.cburch.logisim.circuit.appear;
// ... imports: CanvasObject, DrawAttr, Poly, Text, Main, Loader, File

public class AppearanceBridge {
  public static void main(String[] args) throws Exception {
    Main.headless = true;
    final var file = new Loader(null).openLogisimFile(new File(args[0]));
    for (final var circuit : file.getCircuits()) {
      final var appear = circuit.getAppearance();
      final var anchor = findAnchor(appear);            // the AppearanceAnchor's location
      final var bds = appear.getOffsetBounds();
      System.out.printf("CIRCUIT %s default=%b facing=%s offsetBounds=(%d,%d,%d,%d)%n", ...);
      for (final var shape : appear.getObjectsFromBottom()) {
        if (shape instanceof AppearanceElement) continue;   // paintSubcircuit skips these
        System.out.println("  " + describe(shape, anchor)); // class, box/points, paint, stroke, colours
      }
    }
  }
}
```

It must live in `com.cburch.logisim.circuit.appear` because `getObjectsFromBottom()` and
`AppearanceElement` are package-private. Compile and run:

```
javac -cp <jar> -d out src/.../AppearanceBridge.java
java -Djava.awt.headless=true -cp out:<jar> \
     com.cburch.logisim.circuit.appear.AppearanceBridge foo.circ
```

`Main.headless = true` is required (D17); without it `Loader` puts up a dialog and the process
hangs. The run takes ~40 s of JVM start-up per file.

## 4. The two appearance modes

`CircuitAppearance.getObjectsFromBottom()` chooses:

```java
public boolean isDefaultAppearance() {
  return (circuit == null) || !staticAttrs.getValue(APPEARANCE_ATTR).equals(APPEAR_CUSTOM);
}
return isDefaultAppearance() ? defaultCanvasObjects : super.getObjectsFromBottom();
```

Note the polarity: *anything other than* `custom` is a default appearance, so a `classic`
circuit's `<appear>` shapes are ignored for **drawing** exactly as they already are for ports.
Pinned by `classicStyleIsStillADefaultAppearance`.

**The custom half is done, not deferred.** It needed the draw model, and the module edge turned
out not to block it: see §5. The shapes come from `CircuitAppearanceSeam.shapes(for:)`, which
`CircuitAppearanceReader` has been populating since the `<appear>` seam landed; before this work
**nothing in the tree had ever drawn one of them**. `LogisimDraw` is 28 files and was imported
only by `LogisimFile`'s appearance reader and writer.

Verified end to end on a real corpus file, not just the synthetic fixture:
`2.7.0__case-468.circ` places 24 copies of a
`MUX` whose `<appear>` is a `path` plus a `rect`, and `main` renders 95 painted components /
787 primitives with every MUX drawing its authored trapezoid rather than a default box.

Corpus incidence, counted by parsing all 539 canonical files rather than grepping (the string
`<a name="appearance" val="classic"/>` also occurs on `Pin` and in `<tool>` blocks, which makes a
grep report 539/539):

| `APPEARANCE_ATTR` | circuits | files |
|---|---:|---:|
| `logisim_evolution` | 1,569 | 507 |
| `custom` | **280** | **88** |
| `evolution` | 56 | 14 |
| `classic` | 0 | 0 |
| `fpga` | 0 | 0 |

So the custom path is 16% of files, deferring it would have left a sixth of the corpus drawing
the wrong symbol, and the classic/FPGA gap in §6.2 is reachable by no file in the corpus.

Two known subtractions on the custom path, both stated rather than hidden:

* **`DynamicElement` (`visible-*`) shapes do not draw.** `LedShape`, `RegisterShape`,
  `SocVgaShape` and the rest bind to a component in the circuit tree and live above
  `LogisimFile`; the reader keeps those elements verbatim under D8 and never builds a
  `CanvasObject`, so `paintSubcircuit`'s `instanceof DynamicElement` arm has nothing to match. A
  custom appearance using them draws its static shapes and omits the live ones. Nine such
  elements exist across the 577 harvested corpus files.
* **Icons** (`paintIcon` and its three renderers) are not ported. They draw into the explorer's
  toolbar cell, not the canvas.

## 5. Package.swift — the recommended edge, and why nothing is blocked

`import LogisimDraw` from `LogisimStd` **resolves today with no manifest change**: the chain is
`LogisimStd -> LogisimFile -> LogisimDraw` and SwiftPM puts every transitively-built module on
the import search path. Verified by compiling, not assumed: the whole feature builds and all
gates pass without touching the manifest.

It is nonetheless a *latent* edge. Nothing in the manifest records that `LogisimStd` needs
`LogisimDraw`, so a future change that drops `LogisimFile -> LogisimDraw` would break three
`LogisimStd` files with an error pointing at the wrong module. **Recommended, not applied; the
manifest was not this work's file:**

```diff
     .target(
       name: "LogisimStd",
-      dependencies: ["LogisimKernel", "LogisimFile", "LogisimRender"],
+      // LogisimDraw is here because `<appear>` shapes are drawn from LogisimStd:
+      // `AppearanceShapePainter` is `CanvasObject.paint` for every shape kind, and the model
+      // deliberately carries no paint method of its own (LogisimDraw must not gain a renderer
+      // dependency: see the note on the LogisimFile -> LogisimDraw edge). The import already
+      // resolves transitively through LogisimFile; declaring it makes the requirement explicit
+      // rather than an accident of another target's dependency list.
+      dependencies: ["LogisimKernel", "LogisimFile", "LogisimRender", "LogisimDraw"],
       swiftSettings: kernelSettings
     ),
```

D9 holds either way: `LogisimDraw` imports `LogisimKernel` and nothing platform-shaped, so
naming it from `LogisimStd` drags no AppKit or CoreGraphics anywhere. `graphcheck` asserts
required edges rather than forbidding new ones, and passes unchanged (10 edges, 12 targets); the
edge above could be added to its `REQUIRED` list at the same time.

## 6. Findings handed back — not fixed here

### 6.1 The stale comments the ticket asked about: CONFIRMED stale

`swift/Sources/LogisimFile/CircuitAppearance.swift` exists and has since the `<appear>` seam
landed. Two comments still say otherwise:

* `swift/Sources/LogisimUI/Project/CircuitTransaction.swift:86-90`
  > SEAM (M6): `Circuit.getAppearance().getCircuitPins().transactionCompleted(repl)` needs
  > `CircuitAppearance`, **which does not exist yet**; the `<appear>` element is round-tripped
  > verbatim at M2 rather than parsed.

  Both halves are now false. `CircuitAppearance` exists, the element **is** parsed
  (`CircuitAppearanceSvgLoader`), and the handler this seam wants is already written and public:
  `CircuitSubcircuitFactory.refreshPortsAfterSourceChanged()`, whose own doc comment quotes the
  exact Java line the comment says is unreachable.

* `swift/Sources/LogisimUI/Project/CircuitMutator.swift:189-199`
  > SEAM: `CircuitAppearance` is M6 … there is nothing to recompute yet and skipping it changes
  > no output. Wire this to the appearance model when M6 lands, or a renamed circuit will keep
  > drawing its old default box.

  The last clause is now a live user-visible bug rather than a hypothetical: a renamed circuit
  **does** keep drawing its old box, because `appearanceRecomputeRequests` is appended to and
  `grep -rn` finds no reader anywhere in `Sources/` or `Tests/`. `CircuitSubcircuitFactory`
  already observes `.setName` and calls `appearance.invalidate()`, so the *ports* update; the
  drawn title does too, since it is rebuilt per frame from `source.name`. What does not update
  is anything that went through `CircuitMutator` without firing a circuit event.

`CircuitTransaction.appearanceHook` is likewise **declared and never assigned**; `grep` finds
no writer. That is open task #56 ("Seam #22: all three CircuitTransaction seams are called and
never assigned"), and this work confirms both ends of it now exist, so it is a one-line
assignment rather than a port.

These are in `LogisimUI/Project/`, not this work's slice. Recommended edits: replace both
"does not exist yet" comments with a pointer to `CircuitSubcircuitFactory
.refreshPortsAfterSourceChanged()` and assign `appearanceHook` to it.

### 6.2 `offsetBounds` is evolution-only for every appearance style — `LogisimFile`

`CircuitSubcircuitFactory.offsetBounds` calls `DefaultEvolutionAppearanceGeometry.offsetBounds`
unconditionally, whatever `APPEARANCE_ATTR` says, while `CircuitAppearance.portOffsets`
correctly dispatches to the classic and HolyCross layouts. So for a `classic` or `fpga` circuit
the **box and the ports are computed by different builders today**, and have been since M2.

That is why `DefaultAppearanceShapes` draws the evolution box for every default style: drawing
the *true* classic box would put ink outside the rectangle the canvas hit-tests and selects
with, which is worse than the current mismatch, not better. Painting cannot be made right here
until the bounds are.

**Zero corpus files reach it** (see the table in §4: 0 classic, 0 fpga circuits out of 1,905),
which is why it has gone unnoticed and why it is a finding rather than a blocker.

The fix is in `swift/Sources/LogisimFile/CircuitSubcircuitFactory.swift`, which was not this
work's file. Sketch: give `CircuitAppearanceDefaults` a `bounds` alongside its layout (all three
builders already compute `width`/`height` internally and throw them away), and have
`offsetBounds` read it instead of the evolution-only helper. `DefaultAppearanceShapes` then
gains a classic and a HolyCross builder and the `if` disappears.

### 6.3 The drag preview cannot reach the ghost that now exists — `LogisimUI`

`paintGhost` is ported and tested (`SubcircuitGhostTests`), and **the canvas cannot call it**.
`ToolOverlayScene.drawFactoryGhost` and `drawComponentGhost` both guard on

```swift
guard let instanceFactory = factory as? any InstanceFactory else {
  strokeOffsetBounds(box, ink: ink, into: builder)      // a bare outline
  return GhostOutcome(painted: false, fellBack: true)
}
```

and `CircuitSubcircuitFactory` descends from `AbstractComponentFactory` in `LogisimFile`, so the
cast fails. Dragging a subcircuit, from the explorer or across the canvas, shows an empty
rectangle where upstream shows the symbol, because upstream's `SubcircuitFactory extends
InstanceFactory` and takes the real path.

Pinned as a measurement by `ghostPathCannotReachASubcircuit`, which asserts both halves: the
`InstancePaintable` conformance exists, and the `InstanceFactory` cast fails. When the guard is
widened that test starts failing, which is the signal to delete it.

The fix is one line in each of the two guards: widen to `factory as? any InstancePaintable`,
which is all `paintFactoryGhost.paint` actually needs, and pass the factory through as the
optional `InstanceFactory?` that `InstancePainter.setFactory` already accepts. `LogisimUI/Canvas`
was not this work's slice.

**This is also why the ghost's own translate had to be fixed blind.** `InstanceFactory.drawGhost`
translates by `(x, y)` before calling `paintGhost`, and upstream's `paintBase` translate is a
no-op there because `InstancePainter.getLocation()` returns `(0, 0)` when `comp == null`
(`InstancePainter.java:169-171`). This port's `InstancePainter.location` deliberately returns the
ghost's real location instead (`setFactory(_:_:at:)`), so a literal transcription of `paintBase`
would have drawn every drag preview a full component away from the cursor: and, because the
path above is unreachable, nobody would have seen it until the guard was widened months later.
`paintBase` now reproduces Java's `getLocation()` explicitly and `SubcircuitGhostTests` asserts
the x span stays in the offset frame; a primitive-count test passes either way.

### 6.4 `namedCircuitBoxFixedSize` has two different defaults inside `LogisimFile`

* `CircuitAppearance.isNamedBoxShapedFixedSize` → `?? true` (upstream's
  `containsAttribute(...) ? getValue(...) : true`, correct).
* `DefaultEvolutionAppearanceGeometry.offsetBounds` → `?? false` (the attribute's own default).

They disagree only for a circuit whose static set lacks the attribute entirely, and then by 50
pixels of box width; the box and its ports would land in different places. Not reachable from a
file the port itself writes, since the writer always emits the attribute; reachable from a
hand-edited one. `SubcircuitPainter.defaultShapes` uses the `?? true` reading, matching
`CircuitAppearance`. Also `LogisimFile`; also not fixed here.

## 7. Deliberate trades

* **The default shape list is rebuilt on every paint, not cached.** Upstream caches
  (`defaultCanvasObjects`, refreshed by `recomputeDefaultAppearance`), but its invalidation chain
  runs through `CircuitAppearance.invalidate()` in `LogisimFile`, which this module cannot hook.
  The cost is a handful of small objects per placement per frame, against the two `Graphics2D`
  clones upstream makes **per component** per frame (D6's note on `Circuit.java:540`). If it ever
  shows up in a profile the fix is a cache keyed on the circuit with the factory invalidating it,
  which needs the `LogisimFile` side.
* **`painter.drawLabel()` is not used; the body is inlined.** `painter.factory` is
  `component.factory as? any InstanceFactory`, which is `nil` for a subcircuit;
  `CircuitSubcircuitFactory` descends from `AbstractComponentFactory` in `LogisimFile` and does
  not conform to the `LogisimStd` protocol. Calling `painter.drawLabel()` compiles, runs, and
  draws nothing: the same failure class as the ticket itself, one layer down. The factory still
  conforms to `InstanceLabelProvider`, so if it ever becomes an `InstanceFactory` the generic
  path takes over and the inlined copy becomes redundant rather than wrong.
* **The ghost's `AlphaComposite(SRC_OVER, 0.5)` becomes a `SceneBuilder` group opacity.** That is
  the retained-scene equivalent; `RenderScene` groups carry an opacity the backend applies to
  the whole group. Upstream's `v > 50` guard (do not fade an already-dark pen) is kept.
* **"Courier 10 Pitch" is transcribed verbatim.** `DrawAttr.DEFAULT_NAME_FONT` and
  `DEFAULT_FIXED_PICH_FONT` name a URW/Linux face that is not installed on macOS, so it resolves
  through the platform fallback; the same treatment every unresolvable family gets, and the
  reason the migration gate carries a `font-unresolved` bucket. Substituting a lookalike would
  hide the substitution rather than record it.
* **One Java bug is not reproduced.** `DefaultEvolutionAppearance`'s fixed-size label truncation
  is `substring(0, maxLength - 3)` on UTF-16 code units, so it can cut a surrogate pair in half.
  Swift `String` cannot hold a lone surrogate; the cut is taken at the nearest `Character`
  boundary at or before the same index. Everything else, the counts, the `...`, the 11-vs-12
  clock/non-clock limits, is upstream's.

## 8. One gate edited outside the owned slice — `PlatformFreedomTests`

`swift/Tests/LogisimStdTests/PlatformFreedomTests.swift` is D9 as a machine-checkable gate: it
scans `Sources/LogisimStd` and fails on any `import` outside
`{Foundation, LogisimKernel, LogisimFile, LogisimRender}`. The three new files import
`LogisimDraw`, so it went red: correctly, since the gate had never been asked about that module.

`LogisimDraw` was **added to the allow-list, and the addition was checked rather than assumed**:

```
$ grep -rh '^import ' swift/Sources/LogisimDraw/ | sort -u
import Foundation
import LogisimKernel
```

It is geometry over the kernel with nothing platform-shaped, which is exactly why
`Package.swift` already lets `LogisimFile` depend on it without dragging CoreGraphics into the
headless CLI.

Admitting a module to that set is a real widening, so it does not rest on the grep above staying
true. A **second test** was added in the same suite,
`drawModuleIsPlatformFree`, that scans `Sources/LogisimDraw` and fails if it ever imports
anything but those two. Without it, a later `import CoreGraphics` inside `LogisimDraw` would
reach `LogisimStd` through the door this change opens and the gate would still report success:
the laundering shape D9 exists to prevent.

This file was outside the owned slice. It is flagged here explicitly because "the gate went red
so the gate was edited" is a move that deserves review even when it is right.

## 9. Files

Owned and changed:

```
swift/Sources/LogisimStd/Circuit/SubcircuitPainter.swift          (new)
swift/Sources/LogisimStd/Circuit/DefaultAppearanceShapes.swift    (new)
swift/Sources/LogisimStd/Circuit/AppearanceShapePainter.swift     (new)
swift/Tests/LogisimUITests/SubcircuitPaintTests.swift             (new)
swift/Tests/LogisimUITests/SubcircuitPaintOracleTests.swift       (new)
swift/Tests/LogisimUITests/SubcircuitPaintDump.swift              (new)
docs/experiments/subcircuit-paint.md                              (this file)
```

Outside the owned slice, one file, see §8:

```
swift/Tests/LogisimStdTests/PlatformFreedomTests.swift            (+1 allow-list entry, +1 test)
```

Nothing else in the tree is touched. `swift/Package.swift`, `swift/Sources/LogisimFile/**`,
`docs/decisions.md`, `docs/objectives.md` and every `tools/` script are unchanged.
