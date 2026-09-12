// PowerOnReset.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.wiring.PowerOnReset),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── SEAM (do not implement here): wall-clock timing is not the D7 simulation clock ──────────
//
// Unlike `Clock`, POR's timing is a real-time `javax.swing.Timer`: a one-shot wall-clock delay
// measured in milliseconds, started when the component first propagates and re-armed by
// `Poker.mouseReleased`, independent of the simulator's tick count entirely. When it elapses,
// Java's `PORState.actionPerformed` flips the output value and calls
// `component.fireInvalidated()` + `simulator.nudge()` to force a re-propagation.
//
// This cannot be scheduled from `LogisimStd`: `InstanceState` (a sibling `Instance/` file this
// task does not own) deliberately has **no** `getProject()`/`getSimulator()`: see that file's
// header, "Handing components a whole Project would pull the UI object graph into the
// propagation path, which D9 forbids." So `PORState` below carries every field and pure
// computation Java's does (`value`/`tstart`/`tend`/`duration`, the `reset()` transition), but
// owns no `Timer` and calls no `Simulator` API. **What the M3 Simulation workflow (or whichever
// module first has both a real timer facility and a `Simulator` handle) must add**, mirroring
// `PORState`'s constructor/`reset`/`actionPerformed`:
//
//   1. After constructing or resetting a `PORState`, schedule a one-shot wall-clock timer for
//      `porState.duration` milliseconds.
//   2. When it fires, call `porState.fire(invalidate: { component.fireInvalidated() },
//      nudge: { simulator.nudge() })`.
//   3. Re-propagate the circuit afterward so the flipped output is observed; Java gets this for
//      free because `fireInvalidated()` + `nudge()` together force it.
//
// Until that lands, a placed POR component reads `Value.createKnown(BitWidth.ONE, tstart)`
// forever (the pre-timer-fire level) and never completes its transition: a real behavioural
// gap, not a cosmetic one, and it should be listed as such rather than silently accepted.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `PowerOnReset.PORSIZE`'s three choices. Java's `AttributeOption`s carry an `Integer` payload
/// (`3`/`1`/`2`) that only feeds `.circ` serialisation (`AttributeOption.toString()`); nothing
/// in the propagation path reads the number, only the identity.
public enum PowerOnResetSize: AttributeOptionValue, CaseIterable, Sendable {
  case wide, medium, narrow

  /// Java's `new AttributeOption(Integer value, …)` serialises as `String.valueOf(value)`.
  /// **`SIZE_WIDE = 3`, `SIZE_MEDIUM = 1`, `SIZE_NARROW = 2`**: deliberately non-sequential
  /// with declaration order; transcribed exactly, not renumbered.
  public var attributeOptionName: String {
    switch self {
    case .wide: return "3"
    case .medium: return "1"
    case .narrow: return "2"
    }
  }
}

/// `PowerOnReset.PORTRANS`'s two choices.
public enum PowerOnResetTransition: AttributeOptionValue, CaseIterable, Sendable {
  case highToLow, lowToHigh

  /// `HTOL = 1`, `LTOH = 2`.
  public var attributeOptionName: String {
    switch self {
    case .highToLow: return "1"
    case .lowToHigh: return "2"
    }
  }
}

/// `com.cburch.logisim.std.wiring.PowerOnReset`.
public final class PowerOnReset: InstanceFactoryBase {

  /// `PowerOnReset._ID`. Do not change, `.circ` files reference it.
  public static let id = "POR"

  /// `PowerOnReset.PORSIZE`. **Default: `.wide`.**
  public static let attrSize: Attribute<PowerOnResetSize> = Attributes.forOption("porsize")

  /// `PowerOnReset.PORTRANS`. **Default: `.highToLow`.**
  public static let attrTransition: Attribute<PowerOnResetTransition> =
    Attributes.forOption("porTransition")

  /// The inline `new DurationAttribute("PorHighDuration", …, 1, 10, false)` from Java's
  /// constructor, hoisted to a `static let` since this port does not re-run the constructor body
  /// per instance the way `Attribute` objects are compared by identity (D5). **Default: `2`**
  /// (seconds; `PORState` multiplies by 1000 for the millisecond duration it actually uses).
  public static let attrHighDuration = DurationAttribute.make("PorHighDuration", min: 1, max: 10, isTicks: false)

  /// `public static final PowerOnReset FACTORY = new PowerOnReset()`.
  public static let factory = PowerOnReset()

  public init() {
    super.init(PowerOnReset.id)
    setAttributes([
      StdAttr.facing.binding(.east),
      PowerOnReset.attrSize.binding(.wide),
      PowerOnReset.attrTransition.binding(.highToLow),
      PowerOnReset.attrHighDuration.binding(2),
    ])
    setFacingAttribute(StdAttr.facing)
    setPorts([Port(0, 0, .output, BitWidth.one)])
  }

  // NOT PORTED: `setIconName("por.png")`, icon, M6.

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    let size = attributes[PowerOnReset.attrSize, default: .wide]
    switch size {
    case .medium:
      return Bounds.create(0, -20, 40, 40).rotate(from: .west, to: facing, xc: 0, yc: 0)
    case .narrow:
      return Bounds.create(0, -10, 20, 20).rotate(from: .west, to: facing, xc: 0, yc: 0)
    case .wide:
      return Bounds.create(0, -20, 200, 40).rotate(from: .west, to: facing, xc: 0, yc: 0)
    }
  }

  // NOT PORTED: `instanceAttributeChanged`: `FACING`/`PORSIZE` only trigger automatic bounds
  // recomputation. See `InstanceFactory.swift`'s file header.

  // MARK: Per-`InstanceState` power-on-reset data

  /// `PowerOnReset.PORState`, minus the `Timer`/`Simulator` fields; see the file-header SEAM
  /// note for exactly what the eventual scheduling layer must supply instead.
  public final class PORState: InstanceData {
    /// `PORState.value`; `true` while waiting for the timer to fire (output reads `tstart`),
    /// `false` once it has (output reads `tend`).
    public private(set) var value: Bool = true
    /// Java's `int tstart`/`int tend`, widened to `Int64` because `Value.createKnown` takes its
    /// value as `Int64` (the `createKnown` overload-ambiguity fix, task #11 in `objectives.md`
    /// ; a bare `Int` literal does not resolve against it).
    public private(set) var tstart: Int64
    public private(set) var tend: Int64
    /// Milliseconds, Java's `state.getAttributeValue(attr) * 1000`.
    public private(set) var duration: Int

    /// `new PORState(InstanceState state)`. Also performs the constructor's
    /// `state.setPort(0, Value.createKnown(BitWidth.ONE, tstart), 0)`; the one piece of the
    /// Java constructor that needs no `Simulator` and is fully portable.
    public init(_ state: any InstanceState) {
      if state.attributeValue(PowerOnReset.attrTransition, default: .highToLow) == .lowToHigh {
        tstart = 0
        tend = 1
      } else {
        tstart = 1
        tend = 0
      }
      duration = Int(state.attributeValue(PowerOnReset.attrHighDuration, default: 2)) * 1000
      state.setPort(0, Value.createKnown(BitWidth.one, tstart), 0)
      // SEAM: Java starts `tim = new Timer(duration, this); tim.start();` here. See the
      // file-header note; this port cannot schedule it without a `Simulator` handle.
    }

    private init(rawValue: Bool, tstart: Int64, tend: Int64, duration: Int) {
      self.value = rawValue
      self.tstart = tstart
      self.tend = tend
      self.duration = duration
    }

    /// `PORState.reset(InstanceState)`; re-arms the transition (called by the mouse poker in
    /// Java; see the `NOT PORTED` note on `Poker` below).
    public func reset(_ state: any InstanceState) {
      value = true
      if state.attributeValue(PowerOnReset.attrTransition, default: .highToLow) == .lowToHigh {
        tstart = 0
        tend = 1
      } else {
        tstart = 1
        tend = 0
      }
      duration = Int(state.attributeValue(PowerOnReset.attrHighDuration, default: 2)) * 1000
      state.setPort(0, Value.createKnown(BitWidth.one, tstart), 0)
      // SEAM: Java re-arms `tim` here (`tim.setInitialDelay(duration); tim.start();`).
    }

    /// `PORState.actionPerformed(ActionEvent)`, minus reading the event source (there is only
    /// one possible source here); called once the externally-scheduled wall-clock timer
    /// elapses. `invalidate`/`nudge` are Java's `component.fireInvalidated()` /
    /// `simulator.nudge()`, supplied by the caller because this type holds neither reference
    /// (see the file-header SEAM note).
    public func fire(invalidate: () -> Void, nudge: () -> Void) {
      guard value else { return }
      value = false
      invalidate()
      nudge()
    }

    public func cloneData() -> any InstanceData {
      PORState(rawValue: value, tstart: tstart, tend: tend, duration: duration)
    }
  }

  // NOT PORTED: `Poker` (`InstancePoker`); `mouseReleased` calls `PORState.reset(state)`.
  // `setInstancePoker` is not ported yet anywhere in this module (`InstanceFactory.swift`:
  // "will be closures or protocol witnesses, decided at M6"); when it is, the click handler is
  // exactly `(state.data as? PORState)?.reset(state)`.

  /// `PowerOnReset.propagate(InstanceState)`. Fully portable; only *scheduling* the timer needs
  /// the missing seam, not reading the component's current level.
  public override func propagate(_ state: any InstanceState) throws {
    let porState: PORState
    if let existing = state.data as? PORState {
      porState = existing
    } else {
      porState = PORState(state)
      state.setData(porState)
    }
    let bit = porState.value ? porState.tstart : porState.tend
    state.setPort(0, Value.createKnown(BitWidth.one, bit), 0)
  }

  // MARK: Painting (PowerOnReset.java:220-314)

  /// `paintInstance(InstancePainter)`.
  ///
  /// Two quite different drawings share one method. The wide form is a rotated word; the two
  /// smaller forms are a miniature timing diagram; a blue L-shaped bracket marking the held
  /// level, and a red trace stepping between `y1` and `y2`, with the two swapped for a
  /// low-to-high transition.
  ///
  /// The localised strings are inlined at their English values (D5's precedent):
  /// `porLongName = Power-On Reset`, `PowerOnResetComponent = POR`.
  public func paintInstance(_ painter: InstancePainter) {
    let g = painter.g
    let bds = painter.bounds
    let x = bds.x
    let y = bds.y
    let width = bds.width
    let height = bds.height
    g.strokeWidth = 2
    g.color = .white
    g.fillRect(x, y, width, height)
    g.color = painter.componentColor
    g.drawRect(x, y, width, height)

    let psize = painter.attributeValue(PowerOnReset.attrSize, default: .medium)
    let savedFont = g.font

    if psize == .wide {
      g.font = SceneFont(family: savedFont.family, size: 16, bold: true, italic: false)
      let txt = "Power-On Reset"

      let fm = g.fontMetrics()
      let wide = max(width, height)
      let offset = (wide - g.textBoundsInUserSpace(txt, x: 0, y: 0).width) / 2
      let facing = painter.attributeValue(StdAttr.facing, default: .east)

      if facing == .north || facing == .south {
        let xpos = facing == .north ? x + 20 - fm.descent : x + 20 + fm.descent
        let ypos = facing == .north ? y + offset : y + height - offset
        g.pushTranslate(xpos, ypos)
        g.pushRotate(facing.toRadians())
        g.drawString(txt, x: 0, y: 0)
        g.popTransform()
        g.popTransform()
      } else {
        g.drawString(txt, x: x + offset, y: y + fm.descent + 20)
      }
    } else {
      var x1: Int
      var x2: Int
      let x3: Int
      var y1: Int
      var y2: Int
      let offset: Int

      if psize == .narrow {
        g.font = SceneFont(family: savedFont.family, size: 6, bold: true, italic: false)
        offset = 7
      } else {
        g.font = SceneFont(family: savedFont.family, size: 14, bold: true, italic: false)
        offset = 13
      }

      y1 = y + height - 4
      y2 = y + offset
      x1 = x + 3
      x2 = x + width - 4

      // Upstream drops to a plain width-1 stroke for the bracket, then never restores the old
      // one; the rest of the method draws at width 1 anyway.
      g.strokeWidth = 1
      g.color = .rgba(.blue)
      g.drawLine(x1, y1, x2, y1)
      x1 += 1
      y1 += 1
      g.drawLine(x1, y2, x1, y1)

      x1 = x + 4
      x2 = x + width / 2
      x3 = x + width - 4
      y1 = y + offset + 2
      y2 = y + height - 5

      let pstat = painter.attributeValue(
        PowerOnReset.attrTransition, default: .highToLow)
      if pstat == .lowToHigh {
        swap(&y1, &y2)
      }

      g.color = .rgba(.red)
      g.drawLine(x1, y1, x2, y1)
      g.drawLine(x2, y1, x2, y2)
      g.drawLine(x2, y2, x3, y2)

      g.color = .black
      g.drawString("POR", x: x + 2, y: y + offset - 1)
    }

    g.font = savedFont
    painter.drawPorts()
  }
}

extension PowerOnReset: InstancePaintable {}
