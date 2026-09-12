// ComponentToolTips.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Canvas.getToolTipText,
// com.cburch.logisim.circuit.Splitter.getToolTip, com.cburch.logisim.instance.InstanceComponent
// .getToolTip, com.cburch.logisim.circuit.SubcircuitFactory.CircuitFeature.toString),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: the shipping 4.1.0 jar at
// /Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar, read with
// `javap -c`. Every citation below names the class file it came from. (D16: `src/main/java` in
// this repo is upstream *main*, not 4.1.0, and was not consulted.)
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// HOVER TEXT; the consumer `ComponentFeatureKey.toolTipMaker` never had.
//
// `Component.swift:57` has declared `.toolTipMaker` since the feature-key space was written, and
// `ToolFeatures.swift:283` has declared the `ToolTipMaker` protocol. Nothing asked, and nothing
// answered. This file is both halves.
//
// ── WHAT 4.1.0 ACTUALLY DOES (gui/main/Canvas.class, `getToolTipText(MouseEvent)`) ───────────
//
//   1. `AppPreferences.COMPONENT_TIPS.getBoolean()`; off means no tip, ever.
//   2. `Canvas.snapToGrid(event)`; THE POINT IS SNAPPED TO THE 10-UNIT GRID FIRST. Every
//      distance test downstream is therefore against a grid point, not the pixel under the
//      pointer.
//   3. `getCircuit().getAllContaining(loc)`; *every* component whose `contains(Location)` is
//      true, in `Circuit.getComponents()` order (a `LinkedHashSet`, so insertion order).
//   4. For each, `getFeature(ToolTipMaker.class)`, then `getToolTip(event)`. The FIRST NON-NULL
//      answer wins; a maker that answers null does not stop the loop.
//   5. No answer → null → Swing shows nothing.
//
// ── WHAT THE ANSWERS SAY, AND WHY MOST OF THEM CANNOT COME ACROSS ────────────────────────────
//
// Exactly three classes in the whole 4.1.0 jar implement `ToolTipMaker` (found by scanning every
// class file in the jar for the string, then confirming with `javap` on each hit): `Splitter`,
// `std/io/Video`, and `InstanceComponent`.
//
// `InstanceComponent.getToolTip` (instance/InstanceComponent.class) is:
//
//     for each end i: if end[i].location.manhattanDistanceTo(e.x, e.y) < 10
//                        return portList.get(i).getToolTip(); // may itself be null
//     return factory.getDefaultToolTip()?.toString(); // null if unset
//
// so a stock component's hover text is **its port's tool tip**, and nothing else, and:
//
//   * `Port.toolTip` HAS NO PORT HERE. `LogisimStd/Instance/Port.swift:20-23` dropped
//     `setToolTip` deliberately ("localisation above the model"), and with it every
//     `Port.setToolTip(...)` line in the 67 std classes that call it. That data does not exist in
//     this tree, so the port-proximity arm has nothing to return.
//   * `InstanceFactory.defaultToolTip` HAS NO PORT HERE either
//     (`LogisimStd/Instance/InstanceFactory.swift:68`), and it would buy almost nothing if it
//     did: `setDefaultToolTip` is called from exactly ONE class in the entire 4.1.0 jar:
//     `SubcircuitFactory`, whose `CircuitFeature.toString()` returns `source.getName()`.
//
// The consequence, stated as a sentence about observable output and then checked: **in 4.1.0,
// hovering the body of a 7408 shows nothing at all.** The chip is 14 pins wide; a grid-snapped
// point in the middle of it is more than 10 units from every end, so `getToolTip` falls through
// to `getDefaultToolTip()`, which `AbstractTtlGate` never sets, which is null, and the Canvas
// loop then finds nothing else containing that point. Hovering *near a pin* shows
// "Input 1" / "Output 3" / "VCC pin 14" / "Ground pin 7"
// (std/ttl/AbstractTtlGate.class sets `multiplexerInTip`/`demultiplexerOutTip`/`VCCPin`/`GNDPin`
// on its ports; the format strings are in resources/logisim/strings/std/std.properties, lines
// 867/873/941/942). And hovering a Pin shows **"Add an input pin"**; std/wiring/Pin.class puts
// `pinInputToolTip`/`pinOutputToolTip` on the port, and those are the *toolbar* strings
// (std.properties:1073,1077).
//
// So the owner's report, that hovering an element should say what it is because a TTL schematic
// is hard to read otherwise, is NOT satisfied by upstream's behaviour. On
// the exact circuit that produced the complaint, faithful hover text is empty on every chip body
// and actively wrong on every pin.
//
// ── THE SHAPE OF THIS FILE, THEREFORE ────────────────────────────────────────────────────────
//
// Two layers, kept apart so the divergence is visible rather than smeared into the parity code:
//
//   `upstreamText(...)` : step 2-5 above, verbatim, over whatever conformers exist. Today that
//                          is `Splitter` (ported below in full) and a subcircuit's circuit name.
//                          If `Port.toolTip` is ever ported, every stock component starts
//                          answering here with zero changes to this function.
//
//   `hoverText(...)`    : `upstreamText` first; if it declines, fall back to naming the
//                          component. THIS IS A DELIBERATE DIVERGENCE and it is the whole point
//                          of the request. It can only add information: the text is the
//                          factory's own display name, the same string the context menu header
//                          and the explorer already show, plus the component's label when it
//                          has one. It is drawn from the target the canvas's own hit test
//                          returns, so the tip always names the same component the hover
//                          highlight is drawing.
//
// Wires are excluded from the fallback. `Wire` implements no `ToolTipMaker` in 4.1.0 and a tip
// reading "Wire" over a wire is noise, not information.
//
// ── THE ONE FAITHFUL CONFORMER LEFT ON THE TABLE, NAMED RATHER THAN GLOSSED ──────────────────
//
// `std/io/Video` is the third and last `ToolTipMaker` in the jar, and unlike every other stock
// component it does NOT go through `Port.setToolTip`; `Video.getToolTip` is a `tableswitch` on
// the end index straight to six strings, so it *is* reachable in this tree. It is left out
// deliberately, not missed: the port's `RgbVideo` records `getToolTip` as dropped
// (`LogisimStd/Io/RgbVideo.swift:36`), the end ordering would have to be re-verified against
// `RgbVideo`'s own port list before the table could be transcribed safely, and no part of the
// report that prompted this work touches a video component. For whoever picks it up, the
// `tableswitch` on the matched end index reads: 0 → `rgbVideoRST` "Reset", 1 → `rgbVideoCLK`
// "Clock", 2 → `rgbVideoWE`, 3 → `rgbVideoX`, 4 → `rgbVideoY`, 5 → `rgbVideoData`
// "Data in %s format" formatted with `COLOR_OPTION`, and **default → null**, which is the arm
// the "no end within 10" sentinel of -1 takes, so hovering a video's body says nothing either
// (std/io/Video.class; strings at resources/logisim/strings/std/std.properties:613-624).
//
// **`AppPreferences.COMPONENT_TIPS` (step 1) has no port.** `EditorPreferences` has no such
// setting and that file is not this one's to change; the tip is therefore unconditional here.
// The *default* is unaffected: prefs/AppPreferences.class constructs it as
// `new PrefMonitorBoolean("componentTips", true)`, so a stock 4.1.0 shows tips too. What is
// missing is only the ability to turn them off. The exact line to add is in this task's report.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd

// MARK: - Conformers

/// `com.cburch.logisim.circuit.Splitter implements … ToolTipMaker` (circuit/Splitter.class).
///
/// Retroactive, for the same reason `extension Wire: CustomHandles` in `ToolFeatures.swift` is:
/// `Splitter` lives in `LogisimStd`, which sits below this module and cannot name `ToolTipMaker`.
/// `Splitter.feature(_:)` (`LogisimStd/Wiring/Splitter.swift:243`) still answers `nil` for
/// `.toolTipMaker`, it cannot do otherwise, so the arm in `Component.feature(_:key:)` is what
/// joins the two, exactly as the `.textEditable` arm there already does.
///
/// Both inputs are public API and neither needed a change in a file this task does not own:
/// `ends` (`Splitter.swift:192`) and `splitterBitEnd` (the `WireSplitterComponent` requirement at
/// `LogisimKernel/Propagation/CircuitWires.swift:256`).
extension Splitter: ToolTipMaker {

  /// `Splitter.getToolTip(ComponentUserEvent)`, from circuit/Splitter.class.
  ///
  /// The end scan runs **backwards** (`for (i = getEnds().size() - 1; i >= 0; i--)`) and stops at
  /// the first end within manhattan distance 10, so when two ends are equidistant the higher
  /// index wins. Kept, because on a spacing-0 splitter ends genuinely do coincide.
  ///
  /// The bit-range text is `appendBuf(buf, i - 1, beginString)`, high index first, which is
  /// why a three-bit run reads "3-1" and not "1-3". That is Logisim's MSB-first convention, not
  /// a transcription slip.
  @MainActor
  public func toolTip(_ event: ComponentUserEvent) -> String? {
    var end = -1
    for index in stride(from: ends.count - 1, through: 0, by: -1) {
      if ends[index].location.manhattanDistance(toX: event.x, y: event.y) < 10 {
        end = index
        break
      }
    }
    if end == 0 { return Strings.splitterCombinedTip }
    if end < 0 { return nil }

    var bits = 0
    var buffer = ""
    let bitEnd = splitterBitEnd
    var inString = false
    var beginString = 0
    for index in bitEnd.indices {
      if bitEnd[index] == end {
        bits += 1
        if !inString {
          inString = true
          beginString = index
        }
      } else if inString {
        Splitter.appendBuf(&buffer, index - 1, beginString)
        inString = false
      }
    }
    if inString { Splitter.appendBuf(&buffer, bitEnd.count - 1, beginString) }

    switch bits {
    case 0: return Strings.splitterSplit0Tip
    case 1: return Strings.splitterSplit1Tip(buffer)
    default: return Strings.splitterSplitManyTip(buffer)
    }
  }

  /// `Splitter.appendBuf(StringBuilder, int, int)`: a private static in 4.1.0, same shape here.
  fileprivate static func appendBuf(_ buffer: inout String, _ start: Int, _ end: Int) {
    if !buffer.isEmpty { buffer += "," }
    if start == end {
      buffer += String(start)
    } else {
      buffer += "\(start)-\(end)"
    }
  }
}

/// `SubcircuitFactory.CircuitFeature.toString()` → `source.getName()`
/// (circuit/SubcircuitFactory$CircuitFeature.class), reached in 4.1.0 through
/// `InstanceComponent.getFeature(ToolTipMaker.class)` → `factory.getDefaultToolTip()`.
///
/// A wrapper rather than a retroactive conformance on a component type, because the component
/// class that would carry it (`InstanceComponent`, `StdInstanceComponent`) is shared by all 200-odd
/// stock factories and only the subcircuit ones have an answer. This is the same construction the
/// `.textEditable` arm uses for `InstanceTextField`.
/// The conformance is declared in the extension below, **not** on this line. A global-actor
/// protocol infers its isolation onto a type that adopts it in the primary declaration, and that
/// would make the initialiser `@MainActor`: but the one caller,
/// `Component.feature(_:key:)`, is nonisolated (its `.textEditable` sibling is too). Splitting
/// them isolates the witness without isolating the type.
final class SubcircuitToolTip {
  private let circuitName: String

  init?(_ component: any Component) {
    guard let factory = component.factory as? any SubcircuitFactory else { return nil }
    circuitName = factory.subcircuit.name
  }
}

extension SubcircuitToolTip: ToolTipMaker {
  /// Upstream reaches the default tool tip only *after* the port-proximity scan declines, and the
  /// port scan cannot run here (no `Port.toolTip` in this tree: see the file header), so this is
  /// unconditional. On a subcircuit whose pins carry no tool tip, which, in 4.1.0, is every
  /// subcircuit, because `SubcircuitFactory` never calls `Port.setToolTip`, the two agree
  /// exactly.
  func toolTip(_ event: ComponentUserEvent) -> String? { circuitName }
}

// MARK: - The strings

/// The four `circuit.properties` entries `Splitter.getToolTip` formats, verbatim from the 4.1.0
/// jar (`resources/logisim/strings/circuit/circuit.properties:71-74`). English only: D9 keeps
/// `LocaleManager` out of the port, and every other user-facing string in `LogisimUI` is likewise
/// an English literal.
private enum Strings {
  static let splitterCombinedTip = "Combined end of splitter"
  /// `splitterSplit0Tip` takes no argument in 4.1.0 either; `String.format` is still called with
  /// the buffer, but the format string has no `%s`, so the buffer is discarded.
  static let splitterSplit0Tip = "No bits from combined end"
  static func splitterSplit1Tip(_ bits: String) -> String { "Bit \(bits) from combined end" }
  static func splitterSplitManyTip(_ bits: String) -> String { "Bits \(bits) from combined end" }
}

// MARK: - The canvas-side resolver

/// `com.cburch.logisim.gui.main.Canvas.getToolTipText(MouseEvent)`, as a pure function of a
/// component list and a world point.
///
/// Pure on purpose: the question "what does hovering *here* say" is then answerable in a test
/// with no window, no tracking area and no run loop, which is the only part of a tool tip that
/// can be asserted at all. See `ComponentToolTipTests`.
public enum ComponentToolTips {

  /// The hit tolerance the fallback uses when the caller does not supply one.
  ///
  /// Deliberately *not* `CanvasHostNSView.hitTolerance`'s floor of 3: the view always passes its
  /// own zoom-dependent value, so this is only for direct callers and tests, and a tight default
  /// is the honest one there. The fallback is barely sensitive to it either way; a component
  /// worth naming is far wider than any of these numbers.
  public static let defaultTolerance: Double = 2

  /// Step 2 of `getToolTipText`: `Canvas.snapToGrid(event)` then `Location.create(x, y, false)`.
  ///
  /// The `false` matters; it is `Location.create`'s *own* 5-unit rounding, which upstream turns
  /// OFF here because `snapToGrid` has already rounded to 10. Rounding twice would move points
  /// that are exactly halfway between grid lines.
  static func snapped(_ point: CGPoint) -> Location {
    Location.create(
      CanvasGrid.snapXToGrid(Int(point.x.rounded())),
      CanvasGrid.snapYToGrid(Int(point.y.rounded())),
      hasToSnap: false)
  }

  /// Steps 3-5, verbatim: every component containing the snapped point, in circuit order, first
  /// non-nil `ToolTipMaker` answer wins.
  ///
  /// `components` is the caller's stand-in for `Circuit.getAllContaining`'s input,
  /// `Circuit.getComponents()`. The canvas passes `CircuitSceneBuild.components`, which is
  /// documented as "parallel to `Circuit.components`": the same order, so the tie-break between
  /// two overlapping makers is upstream's.
  @MainActor
  public static func upstreamText(
    over components: [any Component], atWorld point: CGPoint,
    state: (any ToolCircuitState)? = nil
  ) -> String? {
    let location = snapped(point)
    let event = ComponentUserEvent(x: location.x, y: location.y, state: state)
    for component in components where component.contains(location) {
      guard let maker = component.feature((any ToolTipMaker).self, key: .toolTipMaker) else {
        continue
      }
      // Upstream keeps going when a maker answers null; `Splitter` does exactly that for a
      // point inside its box but not near any end.
      if let text = maker.toolTip(event) { return text }
    }
    return nil
  }

  /// The divergence, and the reason this task exists. See the file header for why upstream's
  /// answer does not serve the request that prompted it.
  ///
  /// `target` is the canvas's own topmost hit, the same one the hover highlight uses, so the
  /// tip cannot name a component other than the one being highlighted. `component` is that
  /// target resolved back to a model object when the surface can do it, and is used only to read
  /// the label.
  @MainActor
  static func fallbackText(target: CanvasHitTarget, component: (any Component)?) -> String? {
    // A wire is self-evident and answers no `ToolTipMaker` in 4.1.0. Naming it would put a tip
    // under the pointer everywhere in a wired-up circuit.
    guard target.kind != .wire else { return nil }
    guard let component else { return target.displayName }
    let name = CircuitSceneSource.displayName(
      of: component, kind: CircuitSceneSource.classify(component))
    let label = component.attributeSet[StdAttr.label] ?? ""
    return label.isEmpty ? name : "\(name) — \(label)"
  }

  /// What the view asks. Upstream parity first, the naming fallback second.
  ///
  /// The `as?` is the price of `CircuitRenderSurface` (`Seams/RenderSeam.swift`) deliberately not
  /// carrying model types: it vends `CanvasHitTarget`s, never `Component`s, so the faithful arm,
  /// which must call `contains(Location)` and `getFeature` on real components, cannot be
  /// expressed through the protocol. Neither that file nor `CircuitCanvasSurface` is this task's
  /// to change; the protocol member that would remove the cast is in the report. A surface that
  /// is not circuit-backed (the appearance editor's) still gets the fallback, which is all it has
  /// components for anyway.
  @MainActor
  public static func hoverText(
    over surface: any CircuitRenderSurface, atWorld point: CGPoint,
    tolerance: Double = ComponentToolTips.defaultTolerance
  ) -> String? {
    let build = (surface as? CircuitCanvasSurface)?.build
    if let build, let text = upstreamText(over: build.components, atWorld: point) {
      return text
    }
    guard let target = surface.hitTest(worldPoint: point, tolerance: tolerance) else { return nil }
    let component = build.flatMap { build -> (any Component)? in
      guard let index = build.indexByID[target.id], index < build.components.count else {
        return nil
      }
      return build.components[index]
    }
    return fallbackText(target: target, component: component)
  }
}
