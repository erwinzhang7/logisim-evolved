// Pla.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.Pla),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. That file is in turn adopted from the MIPS.jar library by Martin Dybdal
// <dybber@dybber.dk> and Anders Boesen Lindbo Larsen <abll@diku.dk>, developed for the computer
// architecture class at the Department of Computer Science, University of Copenhagen.
// This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why the table is stored as a live object ────────────────────────────────────────────────
//
// `ATTR_TABLE` is the one attribute in this family whose value is a mutable reference type:
// `Pla`'s attribute set hands out the *same* `PlaTable` the editor dialog mutates in place, and
// the two width attributes and the table are kept in sync by writing through each other. D5's
// `AttributeValue` has a case for exactly this (`.object`, the identity box), so the storage
// form keeps identity while `parse`/`toStandardString` still give the `.circ` codec the plain
// multi-line text it needs. Encoding it as `.string` instead would hand every reader a fresh
// copy and silently break the editor.
//
// The `.circ` writer compares both the stored value *and* its rendered text before deciding to
// emit an attribute, so the identity-based inequality of two `.object` boxes does not make an
// unmodified table write itself out; the texts match and it is skipped.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.gates.Pla.PLAAttributes`.
public final class PlaAttributes: AbstractAttributeSet {

  // MARK: Fields — upstream's, verbatim, with upstream's initial values

  public var label: String = ""
  public var facing: Direction = .east
  public var labelFont: FontSpec = StdAttr.defaultLabelFont
  /// Java's `Object labelLoc = Direction.NORTH`; `StdAttr.LABEL_LOC` is an `Attribute<Object>`
  /// mixing `LABEL_CENTER` with the four `Direction` singletons, which this port models as the
  /// five-case `LabelLocation` enum behind `StdAttr.labelLocation`.
  public var labelLocation: LabelLocation = .north
  public var widthIn: BitWidth = BitWidth.known(2)
  public var widthOut: BitWidth = BitWidth.known(2)
  public var table: PlaTable = PlaTable(2, 2, "PLA")

  /// `Pla.ATTRIBUTES`.
  fileprivate static let attributeList: [AnyAttribute] = [
    StdAttr.facing,
    Pla.inWidth,
    Pla.outWidth,
    Pla.table,
    StdAttr.label,
    StdAttr.labelLocation,
    StdAttr.labelFont,
  ]

  public override var attributes: [AnyAttribute] { PlaAttributes.attributeList }

  // MARK: Reading

  /// `getValue(Attribute<V>)`, in storage form (D5).
  public override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? {
    if attribute === StdAttr.facing { return StdAttr.facing.encode(facing) }
    if attribute === Pla.inWidth { return Pla.inWidth.encode(widthIn) }
    if attribute === Pla.outWidth { return Pla.outWidth.encode(widthOut) }
    if attribute === Pla.table { return Pla.table.encode(table) }
    if attribute === StdAttr.label { return StdAttr.label.encode(label) }
    if attribute === StdAttr.labelLocation {
      return StdAttr.labelLocation.encode(labelLocation)
    }
    if attribute === StdAttr.labelFont { return StdAttr.labelFont.encode(labelFont) }
    // Upstream returns `null` for anything else.
    return nil
  }

  // MARK: Writing

  /// `setValue(Attribute<V>, V)`.
  ///
  /// Two things to keep in mind while reading this:
  ///
  ///   * writing either width resizes the table, and writing the table writes *back* to whichever
  ///     width disagrees with it: a recursive call in Java, reproduced here, so a table pasted
  ///     in from the editor drags the port widths along with it;
  ///   * upstream has **no final `else`**. An attribute it does not recognise is silently
  ///     ignored and the change event still fires. That is unlike every other hand-written
  ///     attribute set in this port, which throws; transcribed as written rather than
  ///     normalised, because throwing here would turn a `.circ` carrying a stray `<a name=…>`
  ///     on a PLA into a load failure that upstream does not have.
  ///
  /// D13: `BitWidth.create` throws for a width outside `0…64`, and `tt.inSize()` comes from the
  /// *length of a parsed line*, so a malformed `.circ` reaches it. It throws rather than traps.
  public override func setRawValue(
    _ attribute: AnyAttribute, _ newValue: AttributeValue?
  ) throws {
    if attribute === StdAttr.labelLocation {
      guard let value = newValue.flatMap(StdAttr.labelLocation.decode) else {
        throw badValue(attribute)
      }
      labelLocation = value
    } else if attribute === StdAttr.facing {
      guard let value = newValue.flatMap(StdAttr.facing.decode) else { throw badValue(attribute) }
      facing = value
    } else if attribute === Pla.inWidth {
      guard let value = newValue.flatMap(Pla.inWidth.decode) else { throw badValue(attribute) }
      widthIn = value
      table.setInSize(widthIn.width)
    } else if attribute === Pla.outWidth {
      guard let value = newValue.flatMap(Pla.outWidth.decode) else { throw badValue(attribute) }
      widthOut = value
      table.setOutSize(widthOut.width)
    } else if attribute === Pla.table {
      guard let value = newValue.flatMap(Pla.table.decode) else { throw badValue(attribute) }
      table = value
      table.setLabel(label)
      if table.inSize != widthIn.width {
        try setValue(Pla.inWidth, try BitWidth.create(table.inSize))
      }
      if table.outSize != widthOut.width {
        try setValue(Pla.outWidth, try BitWidth.create(table.outSize))
      }
    } else if attribute === StdAttr.label {
      guard let value = newValue.flatMap(StdAttr.label.decode) else { throw badValue(attribute) }
      label = value
      table.setLabel(label)
    } else if attribute === StdAttr.labelFont {
      guard let value = newValue.flatMap(StdAttr.labelFont.decode) else {
        throw badValue(attribute)
      }
      labelFont = value
    }

    // `fireAttributeValueChanged(attr, value, null)`: unconditionally, even for the attribute
    // this set does not recognise.
    fireAttributeValueChanged(attribute, value: newValue, oldValue: nil)
  }

  private func badValue(_ attribute: AnyAttribute) -> ComponentError {
    .unsupportedAttributeValue(factory: Pla.id, attribute: attribute.name)
  }

  // MARK: Copying

  public override func makeCopyInstance() -> AbstractAttributeSet {
    PlaAttributes()
  }

  /// `copyInto(AbstractAttributeSet)`.
  ///
  /// Unlike most of the family this one is not empty upstream, and the interesting line is
  /// `dest.tt = new PlaTable(this.tt)`: a **deep** copy, so two components never share a table.
  /// The label is then pushed into the copy, which is what keeps `PlaTable.label` in step.
  public override func copyInto(_ destination: AbstractAttributeSet) {
    guard let destination = destination as? PlaAttributes else { return }
    destination.label = label
    destination.facing = facing
    destination.labelFont = labelFont
    destination.labelLocation = labelLocation
    destination.widthIn = widthIn
    destination.widthOut = widthOut
    destination.table = PlaTable(table)
    destination.table.setLabel(destination.label)
  }
}

/// `com.cburch.logisim.std.gates.Pla`.
public final class Pla: InstanceFactoryBase {

  /// `Pla._ID`. Do NOT change: `.circ` files reference it by name.
  public static let id = "PLA"

  /// `Pla.IN_PORT` / `OUT_PORT`.
  public static let inPort = 0
  public static let outPort = 1

  // MARK: Attribute identities

  /// `Pla.ATTR_IN_WIDTH`.
  public static let inWidth: Attribute<BitWidth> = Attributes.forBitWidth("in_width")
  /// `Pla.ATTR_OUT_WIDTH`.
  public static let outWidth: Attribute<BitWidth> = Attributes.forBitWidth("out_width")

  /// `Pla.ATTR_TABLE`: upstream's `TruthTableAttribute`, an `Attribute<PlaTable>` subclass.
  ///
  /// D5 turns the subclass into a codec. `parse`/`toStandardString` are upstream's verbatim;
  /// the storage form is `.object`, for the identity reason in this file's header.
  /// `getCellEditor` (which opens `PlaTable.EditorDialog`) and `toDisplayString` (`"Click to
  /// edit"`) are UI and do not come across (D5/D9).
  public static let table: Attribute<PlaTable> = Attribute(
    name: "table",
    codec: AttributeCodec(
      parse: { PlaTable.parse($0) },
      toStandardString: { $0.standardString },
      encode: { .object(AttributeObjectBox($0)) },
      decode: {
        guard case .object(let box) = $0 else { return nil }
        return box.object as? PlaTable
      }))

  /// Java's `public static final InstanceFactory FACTORY = new Pla()`.
  public static let factory = Pla()

  public init() {
    // `super(_ID, S.getter("PLA"), new PlaHdlGeneratorFactory(), true)` binds the *four*-argument
    // `(name, displayName, generator, requiresGlobalClock)` overload, not the one whose third
    // parameter is `requiresLabel`. So this component declares `requiresGlobalClock`, which is
    // surprising for a purely combinational lookup table but is what 4.1.0 says.
    super.init(Pla.id, requiresLabel: false, requiresGlobalClock: true)
    setFacingAttribute(StdAttr.facing)
    // `setIconName("pla.gif")`, M6 (D6).
  }

  // MARK: Attribute set

  public override func createAttributeSet() -> any AttributeSet {
    PlaAttributes()
  }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is PlaAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Pla.id)
    }
  }

  /// `configureNewInstance(Instance)`'s one non-paint statement, hoisted to component creation,
  /// which is when upstream runs it.
  ///
  /// It deep-copies the table so a newly placed component does not share the tool's table, then
  /// pushes the component's label into the copy. Without it, editing one PLA's program would
  /// edit every PLA placed from the same tool.
  public override func createComponent(
    location: Location, attributes: any AttributeSet
  ) throws -> any Component {
    let component = try super.createComponent(location: location, attributes: attributes)
    if let attrs = attributes as? PlaAttributes {
      attrs.table = PlaTable(attrs.table)
      attrs.table.setLabel(attrs.label)
    }
    return component
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`: a 50×50 body, rotated out of the east-facing form.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let dir = attributes.getValue(StdAttr.facing) ?? .east
    return Bounds.create(0, -25, 50, 50).rotate(from: .east, to: dir, xc: 0, yc: 0)
  }

  /// `updatePorts(Instance)` as a pure function (PATTERNS.md §0).
  ///
  /// Note the input is at the component's own location and the output is 50 away: the reverse
  /// of every gate in this family, where port 0 is the output. `propagate` writes port 1.
  ///
  /// Java's chain tests WEST, NORTH and SOUTH and falls through to east; the Swift `switch` is
  /// exhaustive and says so.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let dir = attributes.getValue(StdAttr.facing) ?? .east
    var dx = 0
    var dy = 0
    switch dir {
    case .west: dx = -50
    case .north: dy = -50
    case .south: dy = 50
    case .east: dx = 50
    }
    return [
      Port(0, 0, .input, Pla.inWidth),
      Port(dx, dy, .output, Pla.outWidth),
    ]
    // `ps[IN_PORT].setToolTip(...)` / `ps[OUT_PORT].setToolTip(...)`: localisation, not ported
    // (see `Port.swift`'s header).
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`.
  ///
  /// The delay is the literal `1`, not `GateAttributes.DELAY`: they happen to be the same
  /// number, but this component is not part of that family and does not read its constant.
  public override func propagate(_ state: any InstanceState) throws {
    let outWidth = state.attributeValue(Pla.outWidth, default: BitWidth.known(2))
    let table = state.attributeValue(Pla.table, default: PlaTable(2, 2, "PLA"))
    let input = state.portValue(Pla.inPort)
    let val = table.valueFor(input.toLongValue())
    // Java writes the literal `1` here rather than `OUT_PORT`; same index.
    state.setPort(1, Value.createKnown(outWidth, val), 1)
  }

  // NOT PORTED: instanceAttributeChanged; every branch is `recomputeBounds` /
  //             `computeLabelTextField` / `updatePorts` / `fireInvalidated`, all of which the
  //             chassis or M6 owns. See `Instance/InstanceFactory.swift`'s header.
  // NOT PORTED: getInstanceFeature(MenuExtender) → PLAMenu: a `JPopupMenu` that opens the
  //             editor dialog (D9/M6). See Pla.java:283-333.
  // NOT PORTED: getHDLName, D11.

  // MARK: Painting (Pla.java:245-281)

  /// `Instance.computeLabelTextField(AVOID_LEFT | AVOID_RIGHT)`, Pla.java:197.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    LabelPlacement.computed(painter, avoid: .sides)
  }

  public func paintGhost(_ painter: InstancePainter) {
    paintInstance(painter, ghost: true)
  }

  public func paintInstance(_ painter: InstancePainter) {
    paintInstance(painter, ghost: false)
  }

  /// `paintInstance(InstancePainter, boolean ghost)`.
  ///
  /// The caption sits at `h / 3` and the matched row's comment at `2h / 3`: thirds of the
  /// body, not halves, so the two never collide. The comment is truncated at the first `#`
  /// (upstream's "don't display secondary comment") and then trimmed.
  ///
  /// Note the ghost keeps whatever colour the caller left in the pen: only the non-ghost path
  /// sets `COMPONENT_COLOR`, which is what makes a dragged PLA render grey.
  private func paintInstance(_ painter: InstancePainter, ghost: Bool) {
    let g = painter.g
    let bds = painter.bounds
    let x = bds.x
    let y = bds.y
    let w = bds.width
    let h = bds.height

    if !ghost { g.color = painter.componentColor }
    g.strokeWidth = 2
    g.drawRect(x, y, bds.width, bds.height)

    let savedFont = g.font
    g.font = InstancePainter.sceneFont(
      painter.attributeValue(StdAttr.labelFont, default: StdAttr.defaultLabelFont))
    g.drawCenteredText("PLA", x: x + w / 2, y: y + h / 3)
    if !ghost {
      if painter.showState, let tt = painter.attributeValue(Pla.table) {
        let input = painter.portValue(Pla.inPort)
        var comment = tt.commentFor(input.toLongValue())
        if let hash = comment.firstIndex(of: "#") {
          comment = String(comment[comment.startIndex..<hash]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        }
        g.drawCenteredText(comment, x: x + w / 2, y: y + 2 * h / 3)
      }
      painter.drawLabel()
      painter.drawPorts()
    }
    g.font = savedFont
  }
}

extension Pla: InstancePaintable {}
extension Pla: InstanceLabelProvider {}
