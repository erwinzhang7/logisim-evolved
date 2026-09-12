// BitSelector.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.plexers.BitSelector),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// HDL generation (`BitSelectorHdlGeneratorFactory`) is stripped: D11 backlog.
//
// ── `SELECT_ATTR` / `EXTENDED_ATTR`, and a real gap versus upstream ─────────────────────────
//
// Java's `Attributes.forNoSave()` builds an `Attribute<Integer>` that is never constructed with
// a display-name getter at all (`NoSaveAttribute` skips the `Attribute(name, disp)` super call),
// so `getName()` is `null`. The Swift `Attributes.forNoSave()` needs *some* string (its default
// parameter supplies `"dummy"`), so both `SELECT_ATTR` and `EXTENDED_ATTR` carry that same name
// here: harmless, since `isToSave == false` means neither is ever looked up by name or written
// to a `.circ` file; a mechanism deviation, not a behavioural one. It is not read by `propagate`
// or by port placement, both recompute
// the select width locally, purely from `WIDTH`/`GROUP_ATTR`, so the only plausible consumer is
// the attribute table UI (out of scope here, D6/D9). What upstream's `updatePorts` *does* do,
// though, is write the freshly computed value into the instance's own attribute set every time
// `updatePorts` runs, via `instance.getAttributeSet().setValue(...)`.
//
// That call is ported below as `instanceAttributeChanged`'s body, matching Java's filter exactly
// (`FACING` / `WIDTH` / `GROUP_ATTR` / `SELECT_LOC`). **Known gap:** Java's `configureNewInstance`
// calls `updatePorts` once immediately on placement, so a freshly placed `BitSelector` already
// has correct `SELECT_ATTR`/`EXTENDED_ATTR` values. This chassis has no equivalent "run once at
// construction" hook for `instanceAttributeChanged`, only attribute *changes* fire it, so here
// those two attributes hold their static defaults (`3`, `9`) until the first subsequent edit to
// `WIDTH`, `GROUP_ATTR`, `SELECT_LOC` or `FACING`. Since neither attribute feeds propagation or
// port placement, this cannot affect simulation; it is a UI-attribute-table staleness gap only,
// and it is a property of the chassis (`Instance/StdInstanceComponent.swift`, not owned by this
// workflow), not something fixed per-component.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.plexers.BitSelector`.
public final class BitSelector: InstanceFactoryBase {

  /// `BitSelector._ID`. Do not change, `.circ` files reference it.
  public static let id = "BitSelector"

  /// `BitSelector.GROUP_ATTR`.
  public static let groupAttr: Attribute<BitWidth> = Attributes.forBitWidth("group")
  /// `BitSelector.SELECT_ATTR`: derived, never saved. See the file header.
  public static let selectAttr: Attribute<Int32> = Attributes.forNoSave()
  /// `BitSelector.EXTENDED_ATTR`: derived, never saved. See the file header.
  public static let extendedAttr: Attribute<Int32> = Attributes.forNoSave()

  public init() {
    super.init(BitSelector.id, displayName: "Bit Selector")
    setAttributes([
      StdAttr.facing.binding(Direction.east),
      StdAttr.selectLocation.binding(StdAttr.selectBottomLeft),
      StdAttr.width.binding(BitWidth.known(8)),
      BitSelector.groupAttr.binding(BitWidth.one),
      BitSelector.selectAttr.binding(Int32(3)),
      BitSelector.extendedAttr.binding(Int32(9)),
    ])
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator` / `setIcon`, UI (D9) and M6.
  }

  // Note: unlike its four siblings, `BitSelector` does not override `contains`; upstream leaves
  // it on the plain bounds hit test (`InstanceFactory.contains`), not
  // `PlexersLibrary.contains`'s trapezoid cut. Preserved.

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes[StdAttr.facing, default: .east]
    let base = Bounds.create(-30, -15, 30, 30)
    return base.rotate(from: .east, to: facing, xc: 0, yc: 0)
  }

  /// Shared by `ports(_:)` and `instanceAttributeChanged`: the derived select-bit width, a pure
  /// function of the data and group widths. `updatePorts`'s local `groups`/`selectBits` loop in
  /// Java.
  private static func selectBitWidth(data: BitWidth, group: BitWidth) -> Int {
    var groups = (data.width + group.width - 1) / group.width - 1
    var selectBits = 1
    if groups > 0 {
      while groups != 1 {
        groups >>= 1
        selectBits += 1
      }
    }
    return selectBits
  }

  /// `updatePorts(Instance)`'s port half. Port order: output (group width), data input, select
  /// input: fixed indices 0/1/2, read that way by `propagate`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes[StdAttr.facing, default: .east]
    let selectLoc = attributes[StdAttr.selectLocation]
    let data = attributes[StdAttr.width, default: .one]
    let group = attributes[BitSelector.groupAttr, default: .one]
    // D13: the computed width is always in `1...` a handful of bits, see the file header on
    // `selectBitWidth`, so `BitWidth.known` (not the throwing `BitWidth.create`) is correct,
    // the same carve-out `Port`'s int-width initialiser uses.
    let select = BitWidth.known(BitSelector.selectBitWidth(data: data, group: group))

    let inPt: Location
    let selPt: Location
    switch facing {
    case .west:
      inPt = Location.create(30, 0, hasToSnap: true)
      selPt =
        selectLoc == StdAttr.selectBottomLeft
        ? Location.create(10, -10, hasToSnap: true) : Location.create(10, 10, hasToSnap: true)
    case .north:
      inPt = Location.create(0, 30, hasToSnap: true)
      selPt =
        selectLoc == StdAttr.selectBottomLeft
        ? Location.create(-10, 10, hasToSnap: true) : Location.create(10, 10, hasToSnap: true)
    case .south:
      inPt = Location.create(0, -30, hasToSnap: true)
      selPt =
        selectLoc == StdAttr.selectBottomLeft
        ? Location.create(-10, -10, hasToSnap: true) : Location.create(10, -10, hasToSnap: true)
    case .east:
      inPt = Location.create(-30, 0, hasToSnap: true)
      selPt =
        selectLoc == StdAttr.selectBottomLeft
        ? Location.create(-10, 10, hasToSnap: true) : Location.create(-10, -10, hasToSnap: true)
    }

    return [
      Port(0, 0, .output, group.width),
      Port(inPt.x, inPt.y, .input, data.width),
      Port(selPt.x, selPt.y, .input, select.width),
    ]
  }

  /// `instanceAttributeChanged(Instance, Attribute<?>)`. See the file header for what this does
  /// and the one behavioural gap versus upstream's `configureNewInstance`.
  public override func instanceAttributeChanged(
    _ component: StdInstanceComponent, _ attribute: AnyAttribute
  ) {
    guard
      attribute === StdAttr.width || attribute === BitSelector.groupAttr
        || attribute === StdAttr.selectLocation || attribute === StdAttr.facing
    else { return }

    let attrs = component.attributeSet
    let data = attrs[StdAttr.width, default: .one]
    let group = attrs[BitSelector.groupAttr, default: .one]
    let selectBits = BitSelector.selectBitWidth(data: data, group: group)
    // Java: `Math.pow(2d, select.getWidth())`. `selectBits` is always a handful of bits (bounded
    // well under `BitWidth.MAXWIDTH`), so the integer shift is exact, an unobservable mechanism
    // deviation.
    let maxGroups = 1 << selectBits
    // Writing to the factory's own attribute set from inside this hook is exactly the recovery
    // path `StdInstanceComponent.attributeValueChanged` expects: it re-notifies for `SELECT_ATTR`
    // / `EXTENDED_ATTR`, which do not match the guard above, so this terminates after one level:
    // matching Java's `AttributeSet.setValue` re-entrant notification, which stops for the same
    // reason.
    try? attrs.setValue(BitSelector.selectAttr, Int32(selectBits))
    try? attrs.setValue(BitSelector.extendedAttr, Int32(maxGroups * group.width + 1))
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let data = state.portValue(1)
    let select = state.portValue(2)
    let groupBits = state.attributeValue(BitSelector.groupAttr, default: .one)

    let group: Value
    if !select.isFullyDefined() {
      group = Value.createUnknown(groupBits)
    } else {
      let shift = Int(select.toLongValue()) * groupBits.width
      if shift >= data.width {
        group = Value.createKnown(groupBits, 0)
      } else if groupBits.width == 1 {
        group = data.get(shift)
      } else {
        var bits = [Value](repeating: .falseValue, count: groupBits.width)
        for i in 0..<bits.count {
          bits[i] = (shift + i >= data.width) ? .falseValue : data.get(shift + i)
        }
        // D13: `Value.create([Value])` throws (empty array, or a mismatched-width element).
        group = try Value.create(bits)
      }
    }
    state.setPort(0, group, PlexersLibraryAttributes.delay)
  }

  // PAINT (M6): paintGhost / paintInstance: the (9-pixel-lean) trapezoid and "Sel" text. See
  // BitSelector.java:100-116.
}
