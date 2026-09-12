// ProgrammableGenerator.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.ProgrammableGenerator),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Ported in full, registered nowhere, see `ExtraIoLibrary.swift` ─────────────────────────
//
// This factory is fully functional but upstream never adds it to `ExtraIoLibrary.tools()`
// (`/* TODO: Broken component, fix */`), and nothing in the Java codebase calls its package
// method `tick(CircuitState, int, Component)` either, there is no `Circuit`-level registry of
// "components that want a tick callback outside normal propagation" for a non-`Clock` component
// to enroll in. `ProgrammableGeneratorState.incrementTicks()`/`incrementCurrentState()` carry the
// actual state-duration bookkeeping and are ported in full (`ProgrammableGeneratorState.swift`);
// `tick(_:)` below reproduces `ProgrammableGenerator.tick`'s logic against that state directly,
// documented rather than wired to anything, exactly mirroring upstream's own dead code path.
//
// ── `RadixOption` / `Probe.getOffsetBounds` dependency, avoided rather than faked ────────────
//
// `getOffsetBounds` upstream is one call, `Probe.getOffsetBounds(facing, BitWidth.ONE,
// RadixOption.RADIX_2, false, false)`: always the same three trailing arguments. Rather than
// standing in for the general-purpose `Probe.getOffsetBounds` (a `std/wiring` type this task does
// not own), `offsetBounds` below hand-evaluates that specific call: with `width = 1` and
// `radix == RADIX_2`, `Probe`'s own arithmetic collapses to a fixed 20×20 box positioned by
// `facing` alone (worked out by hand against `Probe.java:85-127`, reproduced in the comment at
// the call site). **If `Probe.getOffsetBounds`'s constants ever change upstream, or if the real
// `Probe` port lands and diverges from this hand-evaluation, prefer calling the real function.**
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `Poker` / `ContentsAttribute.getCellEditor` / `ContentsCell` / `ProgrammableGeneratorMenu`
//     : UI/M6, same shape as every other poke-tool and menu-extender gap in this task.
//   (`paintInstance` IS ported; see the Paint section at the end of the factory.)

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.extra.ProgrammableGenerator`.
public final class ProgrammableGenerator: InstanceFactoryBase {

  public static let id = "ProgrammableGenerator"

  public static let attrStateCount: Attribute<Int32> = Attributes.forIntegerRange(
    "nState", start: 1, end: 32)
  /// `ProgrammableGenerator.CONTENTS_ATTR`. See `PlaRom.swift`'s identical note on
  /// `Attribute<String>` subclasses collapsing to `Attributes.forString` once `getCellEditor`
  /// (UI) is dropped.
  public static let attrContents: Attribute<String> = Attributes.forString("Contents")

  public init() {
    super.init(ProgrammableGenerator.id)
    setAttributes([
      StdAttr.facing.binding(.east),
      ProgrammableGenerator.attrStateCount.binding(4),
      StdAttr.label.binding(""),
      stdAttrLabelLocation.binding(.west),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      ProgrammableGenerator.attrContents.binding(""),
    ])
    setFacingAttribute(StdAttr.facing)
    // `configureNewInstance` always sets exactly this one port, regardless of facing: the wire
    // attaches at the component's own origin no matter which way the drawn box is rotated.
    setPorts([Port(0, 0, .output, 1)])
  }

  /// `Probe.getOffsetBounds(facing, BitWidth.ONE, RadixOption.RADIX_2, false, false)`,
  /// hand-evaluated, see the file header.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    switch facing {
    case .east: return Bounds.create(-20, -10, 20, 20)
    case .west: return Bounds.create(0, -10, 20, 20)
    case .south: return Bounds.create(-10, -20, 20, 20)
    case .north: return Bounds.create(-10, 0, 20, 20)
    }
  }

  /// `ProgrammableGenerator.getStateData(InstanceState)`. `throws` because `decodeSavedData` does
  /// (D13): see the identical note on `PlaRom.data(for:)`.
  private static func data(for state: any InstanceState) throws -> ProgrammableGeneratorState {
    let stateCount = Int(state.attributeValue(ProgrammableGenerator.attrStateCount, default: 4))
    if let existing = state.data as? ProgrammableGeneratorState {
      if existing.updateSize(stateCount) {
        try? state.attributeSet.setValue(
          ProgrammableGenerator.attrContents, existing.getSavedData())
      }
      return existing
    }
    let fresh = ProgrammableGeneratorState(stateCount: stateCount)
    try fresh.decodeSavedData(state.attributeValue(ProgrammableGenerator.attrContents))
    state.setData(fresh)
    return fresh
  }

  public override func propagate(_ state: any InstanceState) throws {
    let value = state.portValue(0)
    let generatorState = try ProgrammableGenerator.data(for: state)
    if value != generatorState.sending {
      state.setPort(0, generatorState.sending, 1)
    }
  }

  /// `ProgrammableGenerator.tick(CircuitState, int, Component)`; see the file header: reachable
  /// from nowhere upstream either. Returns whether `sending` changed, exactly as upstream's
  /// `boolean` result (which it uses to decide whether to call `fireInvalidated()`).
  public static func tick(_ generatorState: ProgrammableGeneratorState) -> Bool {
    generatorState.incrementTicks()
    let desired: Value = generatorState.stateTick() - 1 < generatorState.durationHighValue() ? .trueValue : .falseValue
    guard generatorState.sending != desired else { return false }
    generatorState.sending = desired
    return true
  }

  // MARK: - Paint (D6)

  /// The paint-path twin of `data(for:)`; see `PlaRom`'s for why the resize does not write the
  /// contents attribute back from here.
  private static func data(painting painter: any IoInstancePainter) -> ProgrammableGeneratorState {
    let stateCount = Int(painter.attributeValue(ProgrammableGenerator.attrStateCount, default: 4))
    if let existing = painter.data as? ProgrammableGeneratorState {
      _ = existing.updateSize(stateCount)
      return existing
    }
    let fresh = ProgrammableGeneratorState(stateCount: stateCount)
    try? fresh.decodeSavedData(painter.attributeValue(ProgrammableGenerator.attrContents))
    painter.setData(fresh)
    return fresh
  }

  /// `paintInstance(InstancePainter)`; `ProgrammableGenerator.java:361-394`.
  ///
  /// A clock-symbol box: the body is tinted with the **value colour of what it is currently
  /// sending**, and the little square wave inside starts high or low to match. That is the one
  /// place a value-palette colour is used as a *fill* rather than for a wire.
  ///
  /// `drawLabel()` comes first here, before the bounds, so a label that overlaps the body is
  /// painted under it, not over it. Everything else in this family draws its label last.
  ///
  /// Both polylines are drawn in **white** and the second is 2 units wide; the first is left at
  /// whatever width was in effect. Upstream never switches back to 1, so the pen is left at 2 on
  /// exit and `drawPorts` inherits it.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let g = painter.scene
    let bds = painter.bounds
    var x = bds.x
    var y = bds.y
    painter.drawLabel()
    g.color = .black
    let drawUp: Bool
    if painter.showState {
      let state = ProgrammableGenerator.data(painting: painter)
      painter.drawRoundBounds(bds, .palette(state.sending.paletteIndex))
      drawUp = state.sending == .trueValue
    } else {
      painter.drawBounds()
      drawUp = true
    }
    g.color = .white
    x += 10
    y += 10
    let xs = [x + 1, x + 1, x + 4, x + 4, x + 7, x + 7]
    let ys =
      drawUp
      ? [y + 5, y + 3, y + 3, y + 7, y + 7, y + 5]
      : [y + 5, y + 7, y + 7, y + 3, y + 3, y + 5]
    g.drawPolyline(xs, ys)
    g.strokeWidth = 2
    g.drawPolyline(
      [x - 5, x - 5, x + 1, x + 1, x - 4],
      [y + 5, y - 5, y - 5, y, y])
    painter.drawPorts()
  }
}

extension ProgrammableGenerator: IoPaintable {}

// MARK: - Label (board #78)

extension ProgrammableGenerator: InstanceLabelProvider {

  /// `Instance.computeLabelTextField(Instance.AVOID_LEFT)`: `ProgrammableGenerator.java:334`,
  /// re-run at `:354`/`:357`.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .left)
  }
}
