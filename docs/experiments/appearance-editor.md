# The custom-appearance editor

Branch `appearance-editor`. Replaces `EditorWindow.centre`'s last remaining placeholder arm
(`.appearance`) with a real pane. Written 2026-09-06.

---

## 0. The premise check, and the one place the brief was stale

The brief said `LogisimDraw` "is imported by the codec's appearance reader/writer and by NOTHING
ELSE" and that "no view has ever drawn it". Both were true when written and the second is now
false: `LogisimStd/Circuit/AppearanceShapePainter.swift` landed hours earlier and paints every
`<appear>` shape into a `SceneBuilder`. That is load-bearing for this work rather than a
correction; **the painter is why this pane could be built in an hour instead of a day**, and it
is used unchanged. Nothing in it was modified.

The brief also asked what `CircuitAppearance` does with an unrecognised `<appear>` child *today*.
Answer, read out of the source and then confirmed by test:

* `CircuitAppearanceSvgLoader.createShape` returns a `VerbatimAppearanceShape`, a detached copy
  of the original `XMLElement`, for any `visible-*` tag and for any tag it does not recognise.
* Those entries sit in the same `[AppearanceShape]` list as the modelled `CanvasObject`s, at
  their original index.
* `CircuitAppearanceSvgSaver.hasCustomAppearance` then checks `shapes.count ==
  childElementCount(of: <appear>)` and, if the model has lost anything, **writes the original
  verbatim element instead of the model**.

So D8 was already safe at the codec level, and the editor's job was to not break it. Section 3
records what happened when I deliberately broke it.

---

## 1. The specification

**I did not launch the jar's GUI.** The brief's step 1 asked for it; the standing instruction said
the owner is at the keyboard right now, and a Java GUI app on macOS steals focus and the menu bar
on launch. Every question step 1 asks is answerable exactly from the 4.1.0 tree (D16), which is
what I used instead. Recording that as a deviation rather than burying it; if the toolbar
inventory below is ever doubted, the check is `AppearanceToolbarModel.java:25-49`, not a
screenshot.

### The toolbar — `AppearanceToolbarModel`'s constructor, verbatim

```java
AbstractTool[] tools = {
  selectTool, new TextTool(attrs), new LineTool(attrs), new CurveTool(attrs),
  new PolyTool(false, attrs), new RectangleTool(attrs), new RoundRectangleTool(attrs),
  new OvalTool(attrs), new PolyTool(true, attrs),
};
… rawItems.add(new ResetAppearanceTool(canvas, true));
   rawItems.add(new ResetAppearanceTool(canvas, false));
   rawItems.add(showStateTool);
```

Twelve items: nine drawing tools, two "reset to default appearance" buttons, and `ShowStateTool`
(which inserts a `visible-*` dynamic shape bound to a component in the circuit). Plus a shared
`DrawingAttributeSet`, a `BasicZoomModel` over {100,150,200,300,400,600,800}%, and an
`AttrTableDrawManager` feeding the ordinary attribute table.

### The port anchors

`AppearancePort` and `AppearanceAnchor` are `AppearanceElement`s. They carry a `Location` and are
**not drawn by the shape painter**; `CircuitAppearance.paintSubcircuit` skips them with
`if (!(shape instanceof AppearanceElement))`, because a placement's ports are drawn from its
*ends* by `InstancePainter.drawPorts()`. Inside the editor they are the opposite: they are what a
parent circuit wires to, so `AppearanceCanvasNSView.drawPortsAndAnchor` paints them as chrome,
never into the scene. `AppearanceCanvas` also keeps them pinned to the top layer
(`setObjectsForce`'s re-layering) and out of ordinary reordering (`AppearanceCanvas.getMaxIndex`).

### `<appear>` on save

`CanvasActionAdapter` wraps every draw-package `UndoAction` in a `proj.Action`, and branches:

```java
public void doIt(Project proj) {
  if (affectsPorts()) { new ActionTransaction(true).execute(); }   // ports moved
  else                { canvasAction.doIt(); }                     // shapes moved
}
```

`affectsPorts()` is "any affected object is an `AppearanceElement`", and the transaction's
`getAccessedCircuits()` lists the **parents** (`circuit.getCircuitsUsingThis()`), not the circuit
being edited; moving a port changes the ends of every placement, which live upstairs, and those
are the wires that may need repairing. Both halves are reproduced in
`AppearanceTranslateAction`.

---

## 2. What was built

`swift/Sources/LogisimUI/Appearance/`: five files, ~700 lines including headers.

| file | job |
|---|---|
| `AppearanceEditorModel.swift` | the live shape list; a `Drawing` for the modelled objects plus the D8 verbatim entries at their recorded indices; `commit()` splices and pushes back |
| `AppearanceSceneSource.swift` | pure `[AppearanceShape]` → `RenderScene` + bounds, via `AppearanceShapePainter`. No AppKit, callable headless |
| `AppearanceCanvasView.swift` | `NSView` over `CoreGraphicsSceneRenderer`; select, drag with grid snap, port/anchor chrome |
| `AppearanceTranslateAction.swift` | the **only** writer. `Project.doAction`, coalescing, `affectsPorts` transaction |
| `AppearancePane.swift` | the SwiftUI pane, the twelve-item toolbar with eleven items disabled and labelled |

`EditorWindow.swift`: the `.appearance` arm now returns `CircuitAppearancePane(model:)`.

### Reuse, and the one duplication

**Reused unchanged, no copy:** `RenderScene`, `SceneBuilder`, `CoreTextMeasurer`,
`CoreGraphicsSceneRenderer`, `RenderViewport`, `RenderOptions`, `CanvasViewport`,
`CanvasAppearance`, `CircuitSceneSource.theme(for:)`, and all of
`LogisimStd.AppearanceShapePainter`. Not one `paint` is re-implemented.

**Not reused, and why:**

* `CircuitCanvasSurface` / `CircuitSceneBuild` / `CircuitSceneSource.build` are typed on
  `Circuit`/`Component`/`ComponentID` end to end; `targets` is documented as "parallel to
  `Circuit.components`" and the scene tag contract *is* the component index. An `<appear>` has no
  components. Serving both would mean making the tag contract and `CanvasHitTarget.Kind`
  polymorphic, in a file another agent is live in.
* `CanvasToolController` dispatches `Tool`/`AddTool`/`PokeTool`: "place a component, poke a
  component, draw a wire". The appearance tools are `com.cburch.draw.tools.*`, a disjoint set
  that upstream keeps in a different *package* for the same reason.

**The genuine duplication, named:** `AppearanceCanvasNSView`'s `renderViewport` and `worldToView`
are ~35 lines identical to `CircuitSceneView`'s, including the `alignedToPixelGrid()` call and
the `backingScale` seam. The right cut is a `SceneHostingView` base class both subclass, flipped
coordinates, camera, grid, backing scale, which is a change to `Canvas/CircuitSceneView.swift`
and therefore not this work's to make. **Recommendation to whoever owns that file: that, not a
polymorphic `CircuitSceneBuild`.**

### What is not implemented, and is labelled as such on screen

Eight of the nine drawing tools, both `ResetAppearanceTool`s, and `ShowStateTool`. They appear in
the tool strip **disabled, with a "not yet ported" tooltip**, rather than omitted: omitting them
would misrepresent the feature as complete. `LogisimDraw` has the shape model and the SVG codec
and no `tools/` directory; that is a further ~1,100 Java lines.

Also not implemented: handle dragging (resize), attribute editing of the selected shape, and the
input/output distinction on the drawn port markers; `AppearanceElement.location` alone does not
carry it, so both kinds currently draw as the same circle.

---

## 3. Measurement

`swift/Tests/LogisimUITests/AppearanceRoundTripTests.swift`, 8 tests, all green. Every assertion
is on **saved bytes** or on **primitive counts out of `SceneBuilder`**.

```
appearance round-trip: 59 corpus files, 205 <appear> sections compared byte-for-byte
✔ a parsed <appear> produces scene primitives, not an empty scene
✔ building the editor model and committing it leaves the bytes identical
✔ every corpus file's <appear> survives the model byte-identically
✔ a move through Project.doAction lands in the saved bytes
✔ the edit is on the undo stack and undoes to the original bytes
✔ D8: an unmodelled <appear> child survives an edit and a save unchanged
✔ the real host satisfies AppearanceHosting, so the pane is not wired to nothing
✔ consecutive moves of the same shapes coalesce into one undo entry
```

Full suite after the change: **249 tests / 42 suites, all pass** (baseline 242/41, so +8/+1 with
zero regressions). `seamcheck` 663 files, 12 known, **0 new**. `graphcheck` 14 edges / 12 targets,
all present.

The reachability test is the one aimed squarely at this project's signature failure: the pane
reaches the circuit by casting `EditorModel.host` (an `any ProjectHost`) to `any AppearanceHosting`,
and a failed cast shows as an empty "No Custom Appearance" screen rather than as an error. Red
probe: making `appearanceCircuit` return `nil` turns exactly that test red and nothing else.

### Finding 1 — the first version of the gate measured the wrong thing

Comparing **whole files** across two loads reported 31 of 59 corpus files as failures, every one
of them the same length before and after. The control, two bare loads of the same file with no
editor model built at all, reproduced it:

```
PROBE 2.7.1__case-507.circ: two bare loads agree = false
  A   <main name="L_7474_df05ab63"/>
  B   <main name="L_7474_55be9d45"/>
PROBE 2.7.1__case-192.circ: two bare loads agree = false
  A   <a name="label" val="R0_1_03f15d07"/>
  B   <a name="label" val="R0_1_af2bb9a1"/>
```

Every difference is a **randomised name-collision suffix**, minted fresh per load by the reader's
uniquifier. Pre-existing, nothing to do with this work, and a whole-file comparison across two
loads can never pass on those files. Left as written it would have been 31 permanent red herrings
attached to the wrong feature. The comparison is now scoped to the `<appear>` sections, which is
also the claim actually under test.

*(Worth a separate look by someone who owns the reader: a per-load random suffix means the port's
output for these 31 files is not reproducible run to run. Whether that matches 4.1.0 is a
question this work did not answer.)*

### Finding 2 — the red probe contradicted its own prediction

Mutation A: `AppearanceEditorModel.reassembled()` drops the D8 verbatim splice.

* **Predicted:** `d8VerbatimShapesSurviveAnEdit` goes red.
* **Measured:** four *other* tests go red and that one **passes**.

`CircuitAppearanceSvgSaver.hasCustomAppearance` sees `4 shapes != 5 children`, refuses the model
and writes the original verbatim `<appear>`. The unmodelled element therefore survives, and the
user's **edit** is what is silently thrown away. That fidelity check is doing exactly the job its
own header claims, and this is the first observed evidence of it firing.

Consequence: `d8VerbatimShapesSurviveAnEdit` does not discriminate the splice. The byte tests do,
because the fallback produces a *different* `<appear>` from the modelled one (the model rewrites a
pre-4.0 `circ-port` into 4.1.0's `dir`/`pin`/`x`/`y` spelling and re-layers the anchor). Both the
prediction and the correction are written into the test file's header.

Mutation B: `undo` translating by `+dx`. Predicted and measured alike: two tests red, on a byte
comparison and on the model coordinate.

Mutation C: `appearanceCircuit` returning `nil`. One test red, the reachability one, and no other.

---

## 4. Files touched, and what was not

Touched: `swift/Sources/LogisimUI/Appearance/**` (new), `swift/Sources/LogisimUI/Editor/
EditorWindow.swift` (the one placeholder arm), `swift/Tests/LogisimUITests/
AppearanceRoundTripTests.swift` (new), this file.

**No manifest edge is needed.** `LogisimUI` already depends on `LogisimStd`, `LogisimFile`,
`LogisimRender` and `LogisimRenderBackend`, and `LogisimDraw` reaches it transitively through
`LogisimFile`: the same latent edge `AppearanceShapePainter.swift`'s header describes for
`LogisimStd`. `import LogisimDraw` from `LogisimUI` compiles today. It is nonetheless latent for
the same reason: if `LogisimFile -> LogisimDraw` were ever dropped, three files here would break
with an error pointing at the wrong place. Whoever next edits `Package.swift`, the honest edge is

```swift
.target(name: "LogisimUI", dependencies: [..., "LogisimDraw"]),
```

Not touched: `Package.swift`, `docs/decisions.md`, `docs/objectives.md`, `tools/**`, and every
file in `LogisimUI/{Canvas,Tools}/**` and `LogisimStd/{Analyze,Gates}/**` where other agents are
live. The `LogisimFileProjectHost` conformance is a **retroactive `extension` declared in
`Appearance/AppearanceEditorModel.swift`**, so neither `Project/LogisimFileProjectHost.swift` nor
`Seams/ProjectSeam.swift` is modified.

---

## 5. Next, in order of value

1. **`SelectTool`'s handle gestures**: resize a rectangle, move a poly vertex. `Drawing
   .moveHandle`, `insertHandle`, `deleteHandle` and `HandleGesture` are all already ported and
   have no caller; this is the cheapest large win left.
2. **The attribute table over the selected shape**; `DrawAttr` is ported in full and
   `InspectorForm` already renders attribute sets. Colour and stroke width for a selected shape
   is mostly plumbing.
3. **The drawing tools** (`com.cburch.draw.tools.*`). Real work, ~1,100 Java lines, and the point
   at which `ModelAddAction`/`ModelRemoveAction` are needed; which is also the point at which
   the D8 index splice stops being exact and needs a real ordering story.
4. **`SceneHostingView`**: collapse the duplicated camera code (section 2).
