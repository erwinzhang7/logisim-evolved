// Clock.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.Clock),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This is one of the four builtin tools the M2 migration gate is blocked on ───────────────
//
// Clock's seven attribute defaults are byte-visible `.circ` output: `XmlWriter` omits an
// attribute's `<a>` element exactly when the stored value equals the value this file's
// `defaultAttributeValue` (or static template) returns. See `decisions.md`'s
// `WHY THIS FAMILY MATTERS` block. Every default below is transcribed from `Clock.java`'s
// constructor and `getDefaultAttributeValue` override; do not "improve" any of them.
//
// ── SEAM 1 (do not implement here): the phase-anchored tick engine, D7 ──────────────────────
//
// `Clock.tick(CircuitState, int, Component)` (`Clock.java:136-148`) is called once per
// simulator tick, for every component the circuit's clock list names, from
// `CircuitState.toggleClocks(int)` (`CircuitState.java:688-717`): **before** normal
// propagation, not through it. `CircuitState`/`Propagator` belong to the M3 Simulation
// workflow and do not exist in this module, so the real four-parameter static method cannot be
// written here. What CAN be written, and is: the pure state transition Java's `ClockState`
// performs, exposed as plain, storage-agnostic operations on `Clock.ClockState`. The call
// Simulation must make, mirroring `Clock.tick` exactly:
//
//     if let existing = circState.getData(comp) as? Clock.ClockState {
//       dirty = existing.updateTick(ticks, comp.attributeSet)
//     } else {
//       circState.setData(comp, Clock.ClockState(ticks: ticks, attrs: comp.attributeSet))
//       dirty = true
//     }
//
// `circState.getData`/`setData` are `CircuitState`'s own per-component scratch storage (a
// different, longer-lived map than the `InstanceState` handed to `propagate`, which is why this
// cannot simply be `state.data`). Also needed: `Circuit.getClocks()`'s Swift equivalent, the
// list of placed components whose `factory === Clock.factory`, maintained by `Circuit`, to
// know which components to call this on every tick.
//
// ── SEAM 2: `Value.getColor()` does not port (D9) ────────────────────────────────────────────
//
// Every `paintX` method is dropped per D6/M6, so this does not bite here, but note for the
// eventual painter: `paintIcon`'s fallback glyph and `paintInstance`'s state indicator both read
// `Value.getColor()` in Java, which is a `ValuePalette` index lookup in the port.
//
// ── Cross-slice dependency, discovered mid-task ──────────────────────────────────────────────
//
// A concurrent workflow landed `Wiring/Pin.swift`, `Probe.swift`, `ProbeAttributes.swift` and
// `RadixOption.swift` in this same directory while this file was being written (none are in
// this task's file list: see the final report). Rather than duplicate their work speculatively
// (an earlier draft of this file did exactly that, with a hand-transcribed
// `Clock.probeOffsetBounds` and a locally-scoped label-location enum), this file was revised to
// depend on them directly once they existed:
//
//   * `ProbeAttributes` below is `LogisimStd.ProbeAttributes` (that sibling file's class, itself
//     forwarding to `LogisimFile.ProbeAttributes` for the shared attribute identity): **not**
//     `LogisimFile.ProbeAttributes` written out explicitly, because `LogisimFile` is ambiguous
//     in this module: it names both the imported module and a type (`LogisimFile`, the root file
//     model class) declared inside it, and `LogisimFile.ProbeAttributes` resolves to "does the
//     *type* have a static member `ProbeAttributes`" (no) rather than "the module's top-level
//     `ProbeAttributes`". A real, general Swift gotcha this file's first draft tripped over.
//   * `Clock.offsetBounds` calls the sibling `Probe.getOffsetBounds(_:_:_:_:_:)` directly instead
//     of a local partial transcription.
//   * The label-location attribute uses the sibling `Io/IoLibrary.swift`'s already-landed
//     `LabelLocation` / `stdAttrLabelLocation` (the exact same shape this file would otherwise
//     have minted a second, competing copy of: see that file's own header, which anticipates
//     this).
//
// **If those files are absent when this one is built** (a differently-ordered merge, or their
// workflow not having landed yet), every reference below fails to resolve and needs the
// stand-ins this file used before discovering them: recoverable from this file's git history,
// or by re-deriving from `Probe.java`/`ProbeAttributes.java`/`StdAttr.java` directly.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.wiring.Clock`.
public final class Clock: InstanceFactoryBase {

  /// `factory instanceof Clock` for `Circuit`'s dedicated clock-component list.
  public override var isClock: Bool { true }

  /// `Clock._ID`. Do not change, `.circ` files reference it.
  public static let id = "Clock"

  // MARK: Attributes

  /// `Clock.ATTR_HIGH`: `new DurationAttribute("highDuration", …, 1, Integer.MAX_VALUE, true)`.
  /// **Default: `1`.**
  public static let attrHigh = DurationAttribute.make("highDuration", min: 1, max: .max, isTicks: true)

  /// `Clock.ATTR_LOW`: same shape as `ATTR_HIGH`. **Default: `1`.**
  public static let attrLow = DurationAttribute.make("lowDuration", min: 1, max: .max, isTicks: true)

  /// `Clock.ATTR_PHASE`: `min = 0`, everything else identical. **Default: `0`.**
  public static let attrPhase = DurationAttribute.make("phaseOffset", min: 0, max: .max, isTicks: true)

  /// `StdAttr.LABEL_LOC`. Uses the sibling `Io/IoLibrary.swift`'s already-landed
  /// `LabelLocation` / `stdAttrLabelLocation`: see this file's "Cross-slice dependency" note
  /// above for why (that file's own header anticipated exactly this reuse). **Default: `.west`**
  /// (`Direction.WEST` in Clock's attribute array).
  ///
  /// `ProbeAttributes` below (used for `PROBEAPPEARANCE`) is the sibling `LogisimStd
  /// .ProbeAttributes` class, likewise reused rather than re-declared.

  /// `Clock.ATTRIBUTES` / `Clock.DEFAULTS`, transcribed field-for-field from the Java
  /// constructor. **Default for `PROBEAPPEARANCE` here is the static template value
  /// `APPEAR_EVOLUTION_NEW`**; this is distinct from (and takes priority, for a freshly placed
  /// instance, over) the version-dependent `getDefaultAttributeValue` override below, exactly as
  /// upstream separates "value a new instance starts with" from "value the `.circ` writer
  /// compares a loaded value against".
  public init() {
    super.init(Clock.id)
    setAttributes([
      StdAttr.facing.binding(.east),
      Clock.attrHigh.binding(1),
      Clock.attrLow.binding(1),
      Clock.attrPhase.binding(0),
      StdAttr.label.binding(""),
      stdAttrLabelLocation.binding(.west),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      ProbeAttributes.probeAppearance.binding(ProbeAttributes.appearEvolutionNew),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .output, BitWidth.one)])
  }

  /// Java's `public static final Clock FACTORY = new Clock()`.
  public static let factory = Clock()

  // MARK: getDefaultAttributeValue — gated, see the file header

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`.
  ///
  /// For every attribute except `PROBEAPPEARANCE`, falls through to
  /// `InstanceFactoryBase`'s template scan (all seven of Clock's other attributes are in the
  /// template, so their defaults come from there; see `InstanceFactory.swift`'s
  /// "bug-for-bug" note on that fallback).
  ///
  /// **`PROBEAPPEARANCE` is special**, and this is the risk worth flagging loudly: Java's
  /// `ProbeAttributes.getDefaultProbeAppearance()` reads a *live user preference*
  /// (`AppPreferences.NEW_INPUT_OUTPUT_SHAPES`, backing key `"oldIO"`, declared default `true`)
  /// and returns `APPEAR_EVOLUTION_NEW` when it is true, `APPEAR_CLASSIC` otherwise. D9 forbids
  /// `LogisimStd` reaching into a preferences store, so `ProbeAttributes.defaultProbeAppearance`
  /// is an **injectable `var`** (forwarding to `LogisimFile.ProbeAttributes.defaultProbeAppearance`)
  /// carrying upstream's shipped default (`appearEvolutionNew`) rather than a live read; see
  /// that declaration's own comment.
  ///
  /// **This is only correct if the JVM that generated the M2 golden oracle had a virgin
  /// preference store for this key.** If the machine running `CircBridge` ever had the real
  /// Logisim-evolution GUI opened and its "old/new I/O shapes" setting touched, the oracle's
  /// default diverges from this hardcoded one, and Clock/Probe/PullResistor's migration
  /// baseline would need re-generating on a clean preference store, not another code fix here.
  /// Whoever chases the migration gate after this task should verify that before assuming a
  /// mismatch here is a Swift bug.
  public override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if attribute === ProbeAttributes.probeAppearance {
      return .option(ProbeAttributes.defaultProbeAppearance)
    }
    return super.defaultAttributeValue(attribute, version: version)
  }

  // NOT PORTED: `getHDLName` / the `ClockHdlGeneratorFactory` constructor argument: HDL
  // generation backlog (D11). Deleted per the binding rule that HDL generators (here a sibling
  // file, `ClockHdlGeneratorFactory.java`) do not come across.

  // NOT PORTED: `setKeyConfigurator(new DirectionConfigurator(...))`: the attribute-table key
  // handler, UI (see `InstanceFactory.swift`'s "Not ported" list).

  // NOT PORTED: `ClockLogger` (`InstanceLogger`); the chronogram/log-window value source. Not
  // reachable from simulation or `.circ` fidelity; belongs to the log-window feature (parity
  // backlog). `ClockLogger.getLogValue` reads exactly `ClockState.sending`, which is `sending`
  // below, so wiring it back in later is a small, self-contained addition.

  // NOT PORTED: `ClockPoker` (`InstancePoker`): mouse click ticks every clock in the project
  // (`state.getProject().getSimulator().tick(1)`). `setInstancePoker` itself is not ported yet
  // (`InstanceFactory.swift`: "will be closures or protocol witnesses, decided at M6"). Note for
  // whoever wires it: the real behaviour is NOT "toggle this clock" but "advance the whole
  // simulator by one tick", exactly the D7 phase-anchored engine's job.

  // NOT PORTED: `instanceAttributeChanged`; every branch (`LABEL_LOC` ->
  // `computeLabelTextField`; `FACING`/`PROBEAPPEARANCE` -> `recomputeBounds()` +
  // `computeLabelTextField`) is either automatic (bounds, handled by `StdInstanceComponent`) or
  // a label-text-field placement computation belonging to M6's painter. See
  // `InstanceFactory.swift`'s file header and `PATTERNS.md` section 0.

  /// `getOffsetBounds(AttributeSet)`. Delegates to the sibling `Probe.getOffsetBounds`
  /// (`Probe.java:85-130`'s port) with the exact arguments `Clock.java:212-214` always passes:
  /// `width = BitWidth.ONE`, `radix = RadixOption.RADIX_2`, and `NewLayout == IsPin ==
  /// newAppearance` (Clock passes the same flag for both of the trailing booleans).
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    let appearance = attributes[
      ProbeAttributes.probeAppearance, default: ProbeAttributes.appearEvolutionNew]
    let newAppearance = appearance == ProbeAttributes.appearEvolutionNew
    return Probe.getOffsetBounds(facing, BitWidth.one, .radix2, newAppearance, newAppearance)
  }

  // MARK: Per-`CircuitState` clock data

  /// `Clock.ClockState`. A `class` (not a struct) because `InstanceData` is reference-typed
  /// (D3-era `Cloneable` stand-in) and because `CircuitState`'s per-component storage, SEAM 1
  /// above, needs a stable object to mutate in place across ticks, exactly as Java's does.
  public final class ClockState: InstanceData {
    /// `ClockState.sending`. **Default: `Value.UNKNOWN`** until the first `updateTick`/
    /// `propagate` runs, matching Java's field initialiser.
    public private(set) var sending: Value = .unknownValue

    /// `new ClockState(int curTick, AttributeSet attrs)`; the constructor unconditionally calls
    /// `updateTick`, whose return value it discards; `sending` starts at `UNKNOWN` so the first
    /// `updateTick` always finds a change (`UNKNOWN != TRUE` and `UNKNOWN != FALSE`) and assigns.
    public init(ticks: Int, attrs: any AttributeSet) {
      _ = updateTick(ticks, attrs)
    }

    /// Raw constructor used only by `cloneData()`, which must copy the current `sending`
    /// without re-deriving it from a tick count and an attribute set it does not have handy:
    /// Java's `super.clone()` (`Object.clone()`) copies the field directly, with no equivalent
    /// re-computation.
    private init(rawSending: Value) {
      sending = rawSending
    }

    /// `ClockState.updateTick(int, AttributeSet)`.
    ///
    /// All three `int` operations below wrap per Java `int` semantics (`wrap32`, binding rules).
    /// **`cycle` cannot legitimately be zero**: `ATTR_HIGH`/`ATTR_LOW` both carry `min = 1` at
    /// the `DurationAttribute.parse` level, so any value that reached this attribute set through
    /// a `.circ` file (or the UI) is `>= 1`; the maximum possible sum, `2 * Int32.max`, is still
    /// less than `2^32`, so `wrap32` of the sum can never land on exactly `0`. This mirrors an
    /// invariant Java relies on implicitly (an `int %` by zero would throw
    /// `ArithmeticException`, uncaught here) rather than something the port adds.
    @discardableResult
    public func updateTick(_ ticks: Int, _ attrs: any AttributeSet) -> Bool {
      let durationHigh = Int(attrs.getValue(Clock.attrHigh) ?? 1)
      let durationLow = Int(attrs.getValue(Clock.attrLow) ?? 1)
      let phaseRaw = Int(attrs.getValue(Clock.attrPhase) ?? 0)

      // `int cycle = durationHigh + durationLow;`
      let cycle = wrap32(durationHigh + durationLow)
      // `int phase = ((attrs.getValue(ATTR_PHASE) % cycle) + cycle) % cycle;`
      let phase = wrap32(phaseRaw % cycle + cycle) % cycle
      // `boolean isLow = ((ticks + phase) % cycle) < durationLow;`
      let isLow = wrap32(ticks + phase) % cycle < durationLow

      let desired: Value = isLow ? .falseValue : .trueValue
      // Equality below is a width-1 `Value` compare. Java compares by reference against interned
      // `TRUE`/`FALSE`/`UNKNOWN` singletons; the port compares structurally, which agrees at
      // width <= 1 because Java interns those three (`PATTERNS.md`, "Equality"). Noted once for
      // this file.
      if sending == desired { return false }
      sending = desired
      return true
    }

    public func cloneData() -> any InstanceData {
      ClockState(rawSending: sending)
    }
  }

  private static func state(for instState: any InstanceState) -> ClockState {
    if let existing = instState.data as? ClockState { return existing }
    let created = ClockState(ticks: instState.tickCount, attrs: instState.attributeSet)
    instState.setData(created)
    return created
  }

  /// Raised by `getValue(_:)`, see that method.
  public enum ClockError: Error, Equatable, CustomStringConvertible, Sendable {
    /// Java: `(ClockState) inst.getData()` force-cast, `NullPointerException` if the clock has
    /// never propagated. Reachable (e.g. `TestVectorEvaluator` reading a clock pin before the
    /// first propagation), so it throws rather than traps (D13).
    case notYetPropagated
    public var description: String {
      "Clock.getValue: no ClockState yet — this clock has never propagated"
    }
  }

  /// `Clock.getValue(InstanceState)`; used by `TestVectorEvaluator`
  /// (`Clock.FACTORY.getValue(pinState)`), not by `propagate` itself (which calls the private
  /// `state(for:)` above, matching `Clock.getState`). Kept as a public throwing function rather
  /// than a force-unwrap, per D13: Java's force cast is a catchable `NullPointerException`.
  public func getValue(_ instState: any InstanceState) throws -> Value {
    guard let data = instState.data as? ClockState else {
      throw ClockError.notYetPropagated
    }
    return data.sending
  }

  // MARK: propagate

  /// `Clock.propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let current = state.portValue(0)
    let clockState = Clock.state(for: state)
    if current != clockState.sending {
      state.setPort(0, clockState.sending, 1)
    }
  }

  // NOT PORTED: `paintIcon`: the toolbar icon (see `Gates/AbstractGate.swift`'s header).

  // MARK: Painting (Clock.java:258-368)

  /// `Instance.computeLabelTextField(AVOID_LEFT)`, Clock.java:195.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }

  /// `paintNewShape(InstancePainter, int x, int y, int width, int height, Direction, boolean ghost)`.
  ///
  /// The same five-point arrow `Pin.drawInputShape` draws, in the same rotated frame; a clock
  /// is an input pin that drives itself. The only difference is the stub, which a ghost omits.
  private func paintNewShape(
    _ painter: InstancePainter, _ x: Int, _ y: Int, _ width: Int, _ height: Int,
    _ dir: Direction, _ ghost: Bool
  ) {
    let g = painter.g
    var xpos = x + width
    var ypos = y + height / 2
    var rwidth = width
    var rheight = height
    var rotation = 0.0
    if dir == .north {
      rotation = -Double.pi / 2
      xpos = x + width / 2
      ypos = y
      rwidth = height
      rheight = width
    } else if dir == .south {
      rotation = Double.pi / 2
      xpos = x + width / 2
      ypos = y + height
      rwidth = height
      rheight = width
    } else if dir == .west {
      rotation = Double.pi
      xpos = x
      ypos = y + height / 2
    }
    g.pushTranslate(xpos, ypos)
    g.pushRotate(rotation)
    g.strokeWidth = WiringPaint.wireWidth
    if !ghost { g.drawLine(-5, 0, 0, 0) }
    g.strokeWidth = 2
    let yBottom = rheight / 2
    let yTop = -yBottom
    g.drawPolygon(
      [-rwidth, -15, -5, -15, -rwidth],
      [yTop, yTop, 0, yBottom, yBottom])
    g.popTransform()
    g.popTransform()
  }

  /// `paintGhost(InstancePainter)`.
  ///
  /// Note it sets grey and then, on the classic appearance, draws only the bounding rectangle:
  /// no waveform. The `switchToWidth(g, 2)` before the branch applies to both.
  public func paintGhost(_ painter: InstancePainter) {
    let bds = painter.bounds
    let x = bds.x
    let y = bds.y
    let width = bds.width
    let height = bds.height
    let newAppear =
      painter.attributeValue(ProbeAttributes.probeAppearance)
      == ProbeAttributes.appearEvolutionNew
    let dir = painter.attributeValue(StdAttr.facing, default: .east)
    let g = painter.g
    g.strokeWidth = 2
    g.color = .rgba(.gray)
    if newAppear {
      paintNewShape(painter, x, y, width, height, dir, true)
    } else {
      g.drawRect(x, y, width, height)
    }
  }

  /// `paintInstance(InstancePainter)`.
  ///
  /// The waveform glyph is a six-point polyline, a single square pulse, drawn *up* when the
  /// clock is currently sending TRUE and *down* otherwise, in the sent value's colour. When
  /// state is not shown it is drawn up, in the component colour, so a printed schematic still
  /// shows the symbol.
  ///
  /// The two `+= 30 : 10` offsets are asymmetric on purpose: only the west-facing new
  /// appearance shifts x, and only the north-facing one shifts y, because those are the two
  /// orientations whose arrow puts the body on the far side of the origin.
  public func paintInstance(_ painter: InstancePainter) {
    let g = painter.g
    let bds = painter.bounds  // intentionally without the label
    var x = bds.x
    var y = bds.y
    let width = bds.width
    let height = bds.height
    let newAppear =
      painter.attributeValue(ProbeAttributes.probeAppearance)
      == ProbeAttributes.appearEvolutionNew
    let dir = painter.attributeValue(StdAttr.facing, default: .east)
    g.strokeWidth = 2
    g.color = painter.componentColor
    if newAppear {
      paintNewShape(painter, x, y, width, height, dir, false)
    } else {
      g.drawRect(x, y, width, height)
    }

    painter.drawLabel()

    let drawUp: Bool
    if painter.showState {
      // `getState(painter)`; creates the state if it is missing, exactly as Java's does, so a
      // clock painted before its first tick shows UNKNOWN rather than falling back to the
      // no-state branch.
      let state: ClockState
      if let existing = painter.data as? ClockState {
        state = existing
      } else {
        state = ClockState(ticks: painter.tickCount, attrs: painter.attributeSet)
        painter.setData(state)
      }
      g.color = painter.color(of: state.sending)
      drawUp = state.sending == .trueValue
    } else {
      g.color = painter.componentColor
      drawUp = true
    }
    x += (dir == .west && newAppear) ? 30 : 10
    y += (dir == .north && newAppear) ? 30 : 10
    let xs = [x - 6, x - 6, x, x, x + 6, x + 6]
    let ys: [Int]
    if drawUp {
      ys = [y, y - 4, y - 4, y + 4, y + 4, y]
    } else {
      ys = [y, y + 4, y + 4, y - 4, y - 4, y]
    }
    g.drawPolyline(xs, ys)

    painter.drawPorts()
  }
}

extension Clock: InstancePaintable {}
extension Clock: InstanceLabelProvider {}
