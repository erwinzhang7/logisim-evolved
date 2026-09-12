# Canvas text: the annotation that drew nothing, and the #2661 colour decision

Follows `docs/experiments/upstream-issues.md` §#2661, which reopened this. That audit's headline
was that the port's claim to have fixed #2661 was mis-attributed, the `Value.java` static-colour
story is real but is a *different* defect, and that the issue's actual subject, per-instance
stored label colour, is untouched. It also recorded, in passing, something larger:

> Worse, and this is the part to chase first: **`Text` draws nothing.**

That turned out to be two independent defects stacked on top of each other, both GUI-visible.
Neither is about colour.

---

## 1. `Text` drew nothing — confirmed, then fixed

### The measurement, before any change

Not inferred from the Java. A probe built a one-component circuit and rendered it through
`CircuitRenderer.render`:

```
[PROBE] painted=0 prims=0 texts=0
[PROBE] instancePaintable=false
[PROBE] componentPaintable=false
```

Zero primitives, and, the diagnostic that matters, **zero `painted`**. `CircuitRenderer.render`
dispatches on exactly two casts and nothing else:

```swift
if let selfDrawing = component as? any ComponentPaintable { selfDrawing.draw(painter); painted += 1 }
else if let paintable = component.factory as? any InstancePaintable { paintable.paintInstance(painter); painted += 1 }
// Neither: an unported component. Draw nothing rather than a placeholder.
```

`Text` conformed to neither, so it matched neither arm and fell out of the loop in silence. Every
free-floating annotation a user placed on a schematic was invisible.

### Dropped hop #22

The shape is the one this port has now hit twenty-two times: **every piece existed except the
join.** `Text.estimateBounds` was ported, carefully, including upstream's deliberately crude
`size * widest * 2 / 3` width model. `TextAttributes` round-tripped all five attributes.
`BaseLibrary` special-cased the factory. `TextTool` was fully implemented. And `Text.swift` closed
with a comment headed `PAINT (M6):` that described in accurate detail what the painter should do:
sitting beside a factory that conformed to no paint protocol.

A doc comment describing a behaviour is not the behaviour. That is the whole lesson, again.

### The fix

`swift/Sources/LogisimStd/Base/TextPainter.swift`: `extension Text: InstancePaintable` with
`paintInstance` and `paintGhost`, transcribed from `Text.java:136-185`.

After: `painted=1 prims=1 texts=1`.

Three things in it are worth naming because each can go missing without a compile error:

1. **The translate.** `paintInstance` pushes `location` before delegating; `paintGhost` draws at
   `(0, 0)` unconditionally. Drop it and every annotation in a circuit stacks on the origin.
   Mutation-tested: replacing it with `pushTranslate(0, 0)` fails
   `annotationIsTranslatedToItsLocation` on both axes.
2. **The offset-bounds writeback.** Upstream re-measures with real metrics after drawing and
   corrects the bounds cache. `TextAttributes.setOffsetBoundsCache` was built for this and its own
   doc comment names `Text.paintGhost` as the one caller that reads its return value; a caller
   that did not exist. Without it, bounds stay on the crude estimate forever and hit-testing runs
   on a guess. Uses `textBoundsInUserSpace`, whose own doc names `Text.java:156` as its intended
   caller; the scene-space variant would bake the location in twice.
3. **The empty-string early return.** `Text.java:141-143` returns before drawing for empty text, so
   zero primitives there is *correct*. Pinned by `emptyTextDrawsNothing`, so the fix cannot
   degenerate into "always emit something".

One deliberate subtraction: Java follows the writeback with `instance.recomputeBounds()`. This port
has no such call and needs none, `InstanceComponent.bounds` is computed on demand from
`offsetBounds(attributes)`, the same reasoning `CircuitSubcircuitFactory.swift:245` records, so
correcting the cache suffices. This also avoids mutating the component list mid-render.

---

## 2. A second, independent defect: the text tool cannot create anything

Found while testing the fix end-to-end through the real canvas, and **not** previously recorded.

`TextTool.createTextComponent` opens with:

```swift
guard let factory = textFactory, let prototype = prototypeAttributes else { return nil }
```

and `CanvasToolController.baseTools` constructs it as:

```swift
BaseToolIds.textTool: TextTool(),
```

, the no-argument initialiser, whose `textFactory` is `nil`. So in the shipped app the tool takes
that guard on every click, returns `nil`, no component is created, and the gesture is a silent
no-op.

This is downstream of the painter defect and independent of it: **fixing the painter alone still
leaves a user clicking on an empty sheet forever.** The injection point is deliberate, `TextTool`
takes the factory as a parameter precisely so the tool slice need not depend on `std.base.Text`
having landed, exactly as `AddTool` is constructed, but nothing ever passes it.

`CanvasToolController.swift` is outside this task's ownership, so the change is reported rather
than applied. It is one argument:

```swift
BaseToolIds.textTool: TextTool(textFactory: Text.factory),
```

Checked, so the report is actionable rather than a guess:

* **The import is already there.** `LogisimUI` imports `LogisimStd` in five files including
  `Tools/ToolSeams.swift`, `Tools/PokeTool.swift` and `Tools/ToolFeatures.swift`, so
  `CanvasToolController` needs no new dependency.
* **Identity is safe.** `Text.factory` is a singleton with a `private init`, and `Text.swift`'s
  header records why that is load-bearing under D4: `AddTool.sharesSource`, `Library.indexOf`
  and `BaseLibrary.contains` all compare factories with `===`. `BaseLibrary` builds its own
  `AddTool(factory: Text.factory)` from the same singleton, so passing it directly and resolving
  it through the loaded library give the identical object.

`CanvasTextToolTests` pins the current behaviour and its failure message says what to invert.

---

## 3. The colour — #2661 proper

### What the issue actually asks for

> Each text label stores its own `ATTR_COLOR` at creation time. The `TEXT_TOOL_COLOR` preference
> only affects newly created labels; existing labels are unaffected by `applyThemeColors()`.

The port inherited this verbatim: `TextAttributes.color` defaults to opaque black and serialises
per instance as `color="#000000"`. In dark mode, every annotation is black on black.

Upstream says explicitly this is **not** a simple fix, and lists three candidate designs. The
constraint that makes the naive fix wrong is that auto-inverting destroys a colour the user
deliberately picked.

### The three designs, judged against *this* tree

| design | verdict | why |
|---|---|---|
| 1. Adapt only labels still on the default colour | **chosen** | costs one comparison at paint time; stores nothing; changes no file byte |
| 2. A per-label "auto" option | **rejected; D16** | needs a new inhabitant in the `color` attribute's value domain, and that inhabitant gets written into `.circ` files. A file this port saved would carry a colour token 4.1.0 cannot parse; precisely the divergence class D16 exists to prevent, and the same shape as the open concern in task #52 |
| 3. A global preference that rewrites stored colours | **rejected; destructive** | this is upstream's own `applyThemeColors()` shape: it mutates the document, dirties it, and turns a deliberately-chosen red into black with no way back |

### Why design 1 is cheaper here than it would be upstream

Upstream would have to re-walk every component on a theme change, which is why the issue treats
this as expensive. This port does not have to. `CircuitCanvasSurface` already re-resolves its
palette from the live `NSAppearance` on every push, and `CircuitSceneSource.paintContext` threads
the result through as `PaintContext.componentColor`. So "follow the appearance" is:

```swift
if TextThemePolicy.adaptDefaultColoredText, stored == TextThemePolicy.defaultColor {
  return painter.context.componentColor   // live ink, re-resolved per frame
}
return .rgba(RGBA(r: stored.red, g: stored.green, b: stored.blue))  // the user's choice, verbatim
```

No stored state, no writeback, no file change, no theme-change walk.

### Two things the implementation is careful about

**It keys off the stored default, not a colour match.** Asking "does this colour equal the current
ink?" would make a deliberately-chosen colour adaptive the moment the palette happened to agree
with it: the same destruction by a slower route. `policyKeysOffTheStoredDefault` pins this: black
adapts, `#010101` does not.

**It is mutation-tested against the naive fix.** Collapsing the condition to `if true`: i.e. "just
make text follow the ink", the obvious wrong fix: fails three tests, including
`deliberateColourSurvivesBothAppearances`, which watches a red label turn `#E0E0E0`.

### The honest limitation

A user who *deliberately* picks black is indistinguishable from one who never picked anything, and
adapts along with the defaults. This is not an oversight better code would fix: the `.circ` format
stores the RGB triple and nothing else, so the provenance that would separate the two cases does
not survive a save/reload. It is undecidable across a round trip. Solving it means inventing a
file-format extension: design 2, already rejected on D16. Stated rather than hidden.

### Seen, not just asserted

`CanvasTextVisualTests` rasterises a wire plus two annotations, one default-black, one
deliberately red, and writes PNGs when `LOGISIM_CANVAS_DUMP` is set (the convention
`CanvasDrawsTests` established). Run it with:

```
LOGISIM_CANVAS_DUMP=/tmp/canvastext swift test --filter CanvasTextVisualTests
```

Measured: **404** inked pixels for the bare wire, **7,250** once the annotations are added.

The two dark frames are the whole decision, in pictures:

* `text-dark.png`: the policy off, i.e. today's shipped behaviour and upstream's. "DEFAULT
  BLACK" is *invisible* on the dark ground, while the wire beside it has correctly re-inked to
  light grey. That contrast in one frame is #2661 exactly: the ink channel works, the stored
  per-instance colour does not travel on it.
* `text-dark-adaptive.png`; the policy on. The default-coloured annotation becomes legible; the
  deliberately-red one is pixel-identical to the frozen frame.

### It ships OFF, and that is the owner's call to reverse

`TextThemePolicy.adaptDefaultColoredText` defaults to `false`, which is **exactly 4.1.0's
behaviour**, because D16 makes 4.1.0 the target and this is a change a user would see. The
mechanism is implemented and tested in both positions; turning it on is one assignment.

Worth knowing before deciding: **upstream has begun fixing this after 4.1.0.** `main` (4.2.0-dev)
adds `StdAttr.DARK_DEFAULT_LABEL_COLOR = 0x6CB6FF` and `getDefaultLabelColor()`, keyed off
`AppPreferences.isDarkTheme(...)`: the Swing look-and-feel preference, not the system appearance.
So the direction of travel agrees with design 1; upstream keys it off a preference where this port
can key it off the live appearance. Neither constant nor accessor exists at the v4.1.0 tag.

---

## What remains open

* **The label channel is still frozen, and it is the bigger user-facing half.** This work covers
  free-floating `Text` annotations. *Component labels*, `StdAttr.label` drawn by
  `InstancePainter.drawLabel()`, resolve through
  `attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor)` with no palette input
  anywhere on the path, and remain `Color.BLUE` in both appearances. `UpstreamIssue2661Tests`
  measures this and stays red-by-design as the tripwire. Fixing it is the same decision as above
  applied to a different attribute, in a file this task does not own.
* `ChromeRole.label` and `ChromeRole.pinLabel` are defined in both palettes and read by no drawing
  code. They are the natural destination for the label fix.
* `MemPainter.componentColor` is a frozen literal black used at 34 sites across 7 files: upstream's
  own `static Color` shape, reproduced. Unaffected by an ink rebuild.

## Status

`Text` draws; the annotation colour mechanism exists and is off by default; the text tool still
cannot create an annotation in the app until `CanvasToolController` passes it a factory. **#2661
remains open**: its subject, component labels, is untouched.
