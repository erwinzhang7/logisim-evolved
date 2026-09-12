// AbstractGate.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.AbstractGate),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The shape ───────────────────────────────────────────────────────────────────────────────
//
// This is the family base for all 14 gates (AND/OR/NAND/NOR/XOR/XNOR/ODD/EVEN parity, buffer,
// NOT, controlled buffer/inverter). A concrete gate supplies four things and nothing else:
//
//     override func computeOutput(_:_:_:) throws -> Value      // the logic
//     override var identity: Value                             // AND -> TRUE, OR -> FALSE
//     super.init(name, isXor:)                                 // and the setters below
//
// Everything geometric, bounds, port offsets, hit testing, lives here and is driven entirely
// by `GateAttributes`, so a new gate adds no geometry code at all.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * `paintIcon` / `paintIconANSI` / `paintIconIEC` / `paintIconPins` / `paintIconBufferAnsi`
//     ; the *toolbar* icons. They are drawn at `AppPreferences.getIconSize()` in a scaled
//     device space with no circuit behind them, which makes them a UI concern rather than a
//     component one (D9); the on-canvas painting below covers everything a schematic shows.
//     `paintBase` / `paintShape` / `paintDinShape` / `paintRectangular` / `paintGhost` /
//     `paintInstance` / `computeLabel` ARE ported: see the painting section at the bottom.
//   * `getHDLName`; D11.
//
// `shouldRepairWire` and the `WireRepair` feature used to be on that list and are now ported:
// see "The WireRepair feature" below. The four subclasses that *override* `shouldRepairWire`
// upstream (OrGate, NorGate, XorGate, XnorGate) still carry their own NOT-PORTED notes; this
// class supplies the overridable hook and upstream's `false` default, so those overrides are one
// line each and change nothing here.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.gates.AbstractGate`.
open class AbstractGate: InstanceFactoryBase {

  // Upstream's four configuration fields, with upstream's initial values.
  private var bonusWidth = 0
  private var negateOutput = false
  private let isXor: Bool
  private var rectLabel = ""
  private var paintInputLines = false

  /// `AbstractGate(String name, StringGetter desc[, boolean isXor], HdlGeneratorFactory)`.
  ///
  /// The description getter is localisation (D5's precedent) and the HDL generator is D11; both
  /// are dropped, so the two upstream constructors collapse into one.
  public init(_ name: String, isXor: Bool = false) {
    self.isXor = isXor
    super.init(name)
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator(...)` is the attribute-table key handler, UI (D9). Not ported.
  }

  // MARK: Configuration (upstream's protected setters)

  /// `setAdditionalWidth(int)`.
  public func setAdditionalWidth(_ value: Int) { bonusWidth = value }

  /// `setNegateOutput(boolean)`.
  public func setNegateOutput(_ value: Bool) { negateOutput = value }

  /// `setPaintInputLines(boolean)`: paint-only, retained so the M6 port has it.
  public func setPaintInputLines(_ value: Bool) { paintInputLines = value }

  /// `setRectangularLabel(String)`, paint-only, same reason.
  public func setRectangularLabel(_ value: String) { rectLabel = value }

  /// `getRectangularLabel(AttributeSet)`.
  open func rectangularLabel(_ attributes: any AttributeSet) -> String { rectLabel }

  // MARK: Subclass responsibilities

  /// `computeOutput(Value[] inputs, int numInputs, InstanceState state)`.
  ///
  /// D13: throws, because `XorGate`/`OddParityGate` route through
  /// `GateFunctions.computeExactlyOne`, which calls `Value.create([Value])`.
  open func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    fatalError("\(name): AbstractGate subclasses must override `computeOutput`")
  }

  /// `getIdentity()`. Consumed by the circuit-analysis path only, but declared here because the
  /// bulk port transcribes it and dropping it would silently change what a later milestone sees.
  open var identity: Value {
    fatalError("\(name): AbstractGate subclasses must override `identity`")
  }

  /// `protected abstract Expression computeExpression(Expression[] inputs, int numInputs)`
  /// (`AbstractGate.java:85`): the symbolic twin of `computeOutput`, used by the Analyze
  /// window's Expression tab.
  ///
  /// `inputs` holds only the **connected, negation-adjusted** inputs, in port order; Java passes
  /// a full-length array plus a `numInputs` prefix count and every implementation reads only the
  /// prefix, so a right-sized array says the same thing without the second parameter. It is
  /// never empty; the caller skips the port entirely when nothing is connected.
  ///
  /// D13: `throws`, because `XorGate` genuinely refuses three or more inputs
  /// (`XorGate.xorExpression` raises `UnsupportedOperationException`), which
  /// `Analyze.propagateComponents` catches and converts into `CannotHandle`.
  open func computeExpression(
    _ inputs: [ExpressionRef], _ algebra: any ExpressionAlgebra
  ) throws -> ExpressionRef {
    fatalError("\(name): AbstractGate subclasses must override `computeExpression`")
  }

  /// The left fold every symmetric gate's `computeExpression` opens with:
  ///
  /// ```java
  /// var ret = inputs[0];
  /// for (var i = 1; i < numInputs; i++) ret = Expressions.and(ret, inputs[i]);
  /// ```
  ///
  /// Six of the eight gates differ only in the operator and in whether the result is negated,
  /// so the fold is here rather than transcribed six times. Associativity is preserved
  /// left-to-right, which is observable: `Expression`'s printer parenthesises by structure, so
  /// folding right would change the string the Expression tab shows.
  public static func fold(
    _ inputs: [ExpressionRef], _ combine: (ExpressionRef, ExpressionRef) -> ExpressionRef
  ) -> ExpressionRef {
    var result = inputs[0]
    for index in 1..<inputs.count { result = combine(result, inputs[index]) }
    return result
  }

  // MARK: The ExpressionComputer feature

  /// `getInstanceFeature(Instance, ExpressionComputer.class)` (`AbstractGate.java:278-306`).
  ///
  /// Reproduced exactly, including the two behaviours that look like oversights and are not:
  ///
  ///   * an **unconnected** input contributes nothing (`if (e != null)`), so a 3-input AND with
  ///     one wire attached derives the expression of a 1-input AND: the same rule
  ///     `propagate` follows, and the reason `numInputs` exists;
  ///   * when **no** input has an expression yet (`numInputs > 0` fails) the output port is left
  ///     alone rather than written with a placeholder. That is what lets the fixpoint loop
  ///     converge: a gate downstream of a not-yet-derived gate simply does nothing this round
  ///     and is re-visited when its inputs arrive.
  ///
  /// The `.wireRepair` arm is upstream's first branch and is handled just above the guard.
  open override func instanceFeature(
    _ key: ComponentFeatureKey, _ component: StdInstanceComponent
  ) -> Any? {
    // `if (key == WireRepair.class) return (WireRepair) data -> shouldRepairWire(instance, data);`
    // (`AbstractGate.java:274-277`). The lambda closes over the *instance*, not the factory, and
    // that is the whole point: four subclasses answer `data.point != instance.location`, so the
    // answer is per-placement. A factory-level answer would be the same for every gate on the
    // canvas and would diverge the moment one of them moved.
    if key == .wireRepair {
      return ClosureWireRepair { [weak self] data in
        guard let self else { return false }
        return self.shouldRepairWire(component, data)
      }
    }
    guard key == .expressionComputer else {
      return super.instanceFeature(key, component)
    }
    guard let attrs = component.attributeSet as? GateAttributes else { return nil }
    let inputCount = Int(attrs.inputCount)
    let negated = attrs.negated
    let width = attrs.width.width
    let ends = component.ends
    return ClosureExpressionComputer { [weak self] map in
      guard let self else { return }
      let algebra = map.algebra
      for bit in 0..<width {
        var inputs: [ExpressionRef] = []
        inputs.reserveCapacity(inputCount)
        for port in 1...max(inputCount, 1) where inputCount >= 1 {
          guard ends.indices.contains(port) else { continue }
          guard var expression = map.expression(at: ends[port].location, bit: bit) else {
            continue
          }
          // `final var negatedBit = (int) (negated >> (i - 1)) & 1;`
          if javaLongBitAt(negated, port - 1) == 1 {
            expression = algebra.not(expression)
          }
          inputs.append(expression)
        }
        if !inputs.isEmpty, ends.indices.contains(0) {
          map.put(ends[0].location, bit: bit, try self.computeExpression(inputs, algebra))
        }
      }
    }
  }

  // MARK: The WireRepair feature

  /// `protected boolean shouldRepairWire(Instance instance, WireRepairData data)`
  /// (`AbstractGate.java:592-594`); the base answer is `false`.
  ///
  /// `false` here is not "unimplemented": most gates genuinely refuse. A wire dragged one grid
  /// step past an AND gate's input and into its body stays where the user released it, because
  /// the shaped AND has a flat back and there is nothing to snap to. The gates that say `true`
  /// are the ones with a *curved* back, OR, NOR, XOR, XNOR, where the drawn body stops short
  /// of the port and the extra step is what visually reaches it.
  ///
  /// `open` rather than `internal`/`final` because Java's `protected` is exactly an override
  /// point, and four subclasses use it. Swift needs the redeclaration to be `open` for a
  /// cross-module subclass to override at all.
  ///
  /// The parameter is a `StdInstanceComponent` because that is this port's `Instance`: the
  /// answer is per-placement, and `data.point != component.location` (the OR-family body) is
  /// meaningless without it.
  open func shouldRepairWire(_ component: StdInstanceComponent, _ data: WireRepairData) -> Bool {
    false
  }

  // MARK: Static helpers

  /// `pullOutput(Value, Object outType)`.
  ///
  /// **Deviation (mechanism).** Java compares `outType` against the `OUTPUT_*` singletons by
  /// reference; `AttributeOption` is a `Hashable` struct here, so this compares structurally.
  /// The three options have distinct names, so the two agree on every input.
  ///
  /// D13: `Value.create([Value])` throws (>64 bits), so this throws.
  public static func pullOutput(_ value: Value, _ outType: AttributeOption) throws -> Value {
    if outType == GateAttributes.output01 {
      return value
    }
    var v = value.getAll()
    if outType == GateAttributes.output0Z {
      for i in v.indices where v[i] == .trueValue { v[i] = .unknownValue }
    } else if outType == GateAttributes.outputZ1 {
      for i in v.indices where v[i] == .falseValue { v[i] = .unknownValue }
    }
    return try Value.create(v)
  }

  // MARK: Attribute set

  /// `createAttributeSet()`; every gate carries a `GateAttributes`, because its attribute
  /// *list* grows with the input count.
  open override func createAttributeSet() -> any AttributeSet {
    GateAttributes(isXor: isXor)
  }

  open override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is GateAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
  }

  /// `getDefaultAttributeValue(Attribute<?>, LogisimVersion)`: every negation attribute defaults
  /// to false, whatever the cached default set says.
  open override func defaultAttributeValue(
    _ attribute: AnyAttribute, version: LogisimVersion
  ) -> AttributeValue? {
    if NegateAttributes.isNegateAttribute(attribute) { return .boolean(false) }
    return super.defaultAttributeValue(attribute, version: version)
  }

  /// `hasThreeStateDrivers(AttributeSet)`.
  open override func hasThreeStateDrivers(_ attributes: any AttributeSet) -> Bool {
    guard attributes.containsAttribute(GateAttributes.output) else { return false }
    return attributes[GateAttributes.output] != GateAttributes.output01
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  ///
  /// Non-throwing by protocol, so a foreign attribute set yields `Bounds.empty` rather than
  /// Java's `ClassCastException`. `validateAttributeSet` makes that unreachable in practice.
  open override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    guard let attrs = attributes as? GateAttributes else { return .empty }
    let facing = attrs.facing
    let size = attrs.sizeValue
    var inputs = Int(attrs.inputCount)
    if inputs % 2 == 0 { inputs += 1 }
    let negated = attrs.negated

    var width = size + bonusWidth + (negateOutput ? 10 : 0)
    if negated != 0 { width += 10 }
    let height = max(10 * inputs, size)

    switch facing {
    case .south: return Bounds.create(-height / 2, -width, height, width)
    case .north: return Bounds.create(-height / 2, 0, height, width)
    case .west: return Bounds.create(0, -height / 2, width, height)
    case .east: return Bounds.create(-width, -height / 2, width, height)
    }
  }

  /// `getInputOffset(GateAttributes, int index)`, where input `index` sits, relative to the
  /// component's location.
  ///
  /// Transcribed literally, including that the whole `skip*` table is integer division on
  /// `size`, and that a negated input is pushed out by a further 10 to make room for the bubble.
  public func inputOffset(_ attrs: GateAttributes, _ index: Int) -> Location {
    let inputs = Int(attrs.inputCount)
    let facing = attrs.facing
    let size = attrs.sizeValue
    let axisLength = size + bonusWidth + (negateOutput ? 10 : 0)
    let negated = attrs.negated

    let skipStart: Int
    let skipDist: Int
    let skipLowerEven: Int
    if inputs <= 3 {
      if size < 40 {
        skipStart = -5
        skipDist = 10
        skipLowerEven = 10
      } else if size < 60 || inputs <= 2 {
        skipStart = -10
        skipDist = 20
        skipLowerEven = 20
      } else {
        skipStart = -15
        skipDist = 30
        skipLowerEven = 30
      }
    } else if inputs == 4 && size >= 60 {
      skipStart = -5
      skipDist = 20
      skipLowerEven = 0
    } else {
      skipStart = -5
      skipDist = 10
      skipLowerEven = 10
    }

    var dy: Int
    if (inputs & 1) == 1 {
      dy = skipStart * (inputs - 1) + skipDist * index
    } else {
      dy = skipStart * inputs + skipDist * index
      if index >= inputs / 2 { dy += skipLowerEven }
      if inputs == 4 && size >= 60 { dy -= 10 }
    }

    var dx = axisLength
    // `(int) (negated >> index) & 1`: Java masks the shift distance by 63.
    if javaLongBitAt(negated, index) == 1 { dx += 10 }

    switch facing {
    case .north: return Location.create(dy, dx, hasToSnap: true)
    case .south: return Location.create(dy, -dx, hasToSnap: true)
    case .west: return Location.create(dx, dy, hasToSnap: true)
    case .east: return Location.create(-dx, dy, hasToSnap: true)
    }
  }

  /// `computePorts(Instance)`; port 0 is the output at the component's location, then one
  /// input per declared input, all at `StdAttr.WIDTH`.
  open override func ports(_ attributes: any AttributeSet) -> [Port] {
    guard let attrs = attributes as? GateAttributes else { return [] }
    let inputs = Int(attrs.inputCount)
    var result: [Port] = [Port(0, 0, .output, StdAttr.width)]
    result.reserveCapacity(inputs + 1)
    for i in 0..<max(inputs, 0) {
      let offset = inputOffset(attrs, i)
      result.append(Port(offset.x, offset.y, .input, StdAttr.width))
    }
    return result
  }

  /// `contains(Location, AttributeSet)`.
  ///
  /// Two upstream bugs are preserved verbatim; see the inline notes. Both are *hit-testing*
  /// bugs, so they are user-visible (a click near a bubble lands or does not), which is why the
  /// port keeps them rather than quietly correcting them.
  open override func contains(_ point: Location, _ attributes: any AttributeSet) -> Bool {
    guard let attrs = attributes as? GateAttributes else { return false }
    guard offsetBounds(attrs).contains(point, 1) else { return false }
    if attrs.negated == 0 { return true }

    let facing = attrs.facing
    let bds = offsetBounds(attributes)
    let delt: Int
    switch facing {
    case .north: delt = point.y - (bds.y + bds.height)
    case .south: delt = point.y - bds.y
    // ── UPSTREAM BUG, PRESERVED ────────────────────────────────────────────────────────────
    // WEST measures along x but subtracts `bds.getHeight()`, not `getWidth()`. For a gate
    // whose bounds are not square (the common case; a 5-input gate is 50x50 but a 2-input
    // one is 50x30) this picks the wrong edge.
    case .west: delt = point.x - (bds.x + bds.height)
    case .east: delt = point.x - bds.x
    }
    if abs(delt) > 5 { return true }

    // ── UPSTREAM BUG, PRESERVED ──────────────────────────────────────────────────────────────
    // `computePorts` numbers inputs 0…inputs-1, but this loop asks for offsets 1…inputs. So
    // the first input's bubble is never hit-tested and one offset past the last is. Keeping it
    // matters: "fixing" it changes which clicks select a gate with a negated first input.
    let inputs = Int(attrs.inputCount)
    for i in 1...max(inputs, 1) where inputs >= 1 {
      let offset = inputOffset(attrs, i)
      if point.manhattanDistance(to: offset) <= 5 { return true }
    }
    return false
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`.
  ///
  /// Note the two upstream subtleties this reproduces:
  ///   * an *unconnected* input is skipped entirely rather than read as floating, so a 3-input
  ///     AND with one wire attached behaves as a 1-input AND; unless the project's
  ///     `ATTR_GATE_UNDEFINED` is `error`, in which case the whole output goes to error;
  ///   * `numInputs == 0` (nothing connected at all) is an error output, not the identity.
  open override func propagate(_ state: any InstanceState) throws {
    guard let attrs = state.attributeSet as? GateAttributes else {
      throw ComponentError.wrongAttributeSet(factory: name)
    }
    let inputCount = Int(attrs.inputCount)
    let negated = attrs.negated
    let options = state.projectOptions
    let errorIfUndefined =
      options[Options.gateUndefined] == Options.gateUndefinedError

    // Java allocates `new Value[inputCount]` and fills only the connected prefix; the tail stays
    // null and is never read, because `computeOutput` is passed `numInputs`. `.nilValue` is the
    // inert stand-in for that null.
    var inputs = [Value](repeating: .nilValue, count: max(inputCount, 0))
    var numInputs = 0
    var error = false
    for i in 1...max(inputCount, 1) where inputCount >= 1 {
      if state.isPortConnected(i) {
        // `(int) (negated >> (i - 1)) & 1`
        if javaLongBitAt(negated, i - 1) == 1 {
          inputs[numInputs] = state.portValue(i).not()
        } else {
          inputs[numInputs] = state.portValue(i)
        }
        numInputs += 1
      } else if errorIfUndefined {
        error = true
      }
    }

    let out: Value
    if numInputs == 0 || error {
      out = Value.createError(attrs.width)
    } else {
      out = try AbstractGate.pullOutput(
        try computeOutput(inputs, numInputs, state), attrs.outputBehaviour)
    }
    state.setPort(0, out, GateAttributes.delay)
  }

  // MARK: Painting (AbstractGate.java:362-541)
  //
  // The family's shared drawing lives here, exactly as upstream puts it here: the body's
  // placement and rotation, the negation bubbles, the input leads, the rectangular/IEC box,
  // the output bubble and the label. A concrete gate contributes only `paintShape` (and, for
  // the shape that 4.1.0 cannot select, `paintDinShape`), which is why AND and NAND differ by
  // one `setNegateOutput(true)` call and nothing drawing-related at all.

  /// `paintShape(InstancePainter, int width, int height)`: the gate's distinctive silhouette,
  /// drawn at the origin, facing east, with any rotation and translation already in effect.
  open func paintShape(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    fatalError("\(name): AbstractGate subclasses must override `paintShape`")
  }

  /// `paintDinShape(InstancePainter, int width, int height, int inputs)`.
  ///
  /// Unreachable in 4.1.0: see `PainterDin`'s header. Declared with a default rather than as
  /// a hard requirement so that a gate which genuinely has no DIN form is not forced to invent
  /// one; upstream declares it abstract and every gate overrides it, and so does every gate
  /// here.
  open func paintDinShape(
    _ painter: InstancePainter, _ width: Int, _ height: Int, _ inputs: Int
  ) {
    paintRectangular(painter, width, height)
  }

  /// `paintRectangular(InstancePainter, int width, int height)`; the IEC box.
  ///
  /// The box is ten narrower when the output is negated, to leave room for the bubble that
  /// `drawDongle(-5, 0)` then puts in the gap.
  public func paintRectangular(_ painter: InstancePainter, _ width: Int, _ height: Int) {
    let don = negateOutput ? 10 : 0
    let attrs = painter.attributeSet
    painter.drawRectangle(-width, -height / 2, width - don, height, rectangularLabel(attrs))
    if negateOutput {
      painter.drawDongle(-5, 0)
    }
  }

  /// `paintBase(InstancePainter)`.
  ///
  /// Three things about the geometry are easy to get subtly wrong and are called out here
  /// because the M6 image diff catches them and nothing else does:
  ///
  ///   * `width`/`height` come from the **offset** bounds and are swapped for NORTH/SOUTH, so
  ///     the body is always drawn in an east-facing frame and rotated afterwards.
  ///   * `width -= 10` when any input is negated: the bounds include the bubble row, the body
  ///     must not.
  ///   * the negate-output case translates by -10, draws the body ten narrower, puts the
  ///     bubble at +5, and translates back; the bubble sits *inside* the reclaimed strip.
  private func paintBase(_ painter: InstancePainter) {
    guard let attrs = painter.attributeSet as? GateAttributes else { return }
    let facing = attrs.facing
    let inputs = Int(attrs.inputCount)
    let negated = attrs.negated

    let shape = painter.gateShape
    let loc = painter.location
    let bds = painter.offsetBounds
    var width = bds.width
    var height = bds.height
    if facing == .north || facing == .south {
      swap(&width, &height)
    }
    if negated != 0 {
      width -= 10
    }

    let g = painter.g
    let baseColor = painter.componentColor
    if shape == .shaped && paintInputLines {
      PainterShaped.paintInputLines(painter, self)
    } else if negated != 0 {
      for i in 0..<max(inputs, 0) where javaLongBitAt(negated, i) == 1 {
        let input = inputOffset(attrs, i)
        let cen = input.translate(facing, 5)
        painter.drawDongle(loc.x + cen.x, loc.y + cen.y)
      }
    }

    g.color = baseColor
    g.pushTranslate(loc.x, loc.y)
    let rotate = facing != .east
    if rotate {
      g.pushRotate(-facing.toRadians())
    }

    if shape == .rectangular {
      paintRectangular(painter, width, height)
      // } else if shape == .din40700 {
      //   paintDinShape(painter, width, height, inputs)
      //
      // Commented out in upstream 4.1.0 at AbstractGate.java:404-406, and left commented here.
      // Uncommenting it and adding `.din40700` back to the shape picker is the whole change.
    } else {  // .shaped
      if negateOutput {
        g.withTranslate(-10, 0) {
          paintShape(painter, width - 10, height)
          painter.drawDongle(5, 0)
        }
      } else {
        paintShape(painter, width, height)
      }
    }

    if rotate { g.popTransform() }
    g.popTransform()

    painter.drawLabel()
  }

  /// `computeLabel(Instance)`, re-expressed as the on-demand placement `InstancePainter`
  /// asks for. Pure in the attributes and the location, which is why it can be recomputed
  /// rather than cached on the component.
  ///
  /// `perp += 6` under the rectangular shape is upstream's: the IEC box is drawn from the
  /// centreline, so the label has to step clear of it.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    guard let attrs = painter.attributeSet as? GateAttributes else { return nil }
    let facing = attrs.facing
    let baseWidth = attrs.sizeValue

    let axis = baseWidth / 2 + (negateOutput ? 10 : 0)
    var perp = 0
    if painter.gateShape == .rectangular { perp += 6 }
    let loc = painter.location
    let cx: Int
    let cy: Int
    switch facing {
    case .north:
      cx = loc.x + perp
      cy = loc.y + axis
    case .south:
      cx = loc.x - perp
      cy = loc.y - axis
    case .west:
      cx = loc.x + axis
      cy = loc.y - perp
    case .east:
      cx = loc.x - axis
      cy = loc.y + perp
    }
    return LabelPlacement(x: cx, y: cy, halign: .center, valign: .center)
  }

  /// `paintGhost(InstancePainter)`.
  public func paintGhost(_ painter: InstancePainter) {
    paintBase(painter)
  }

  /// `paintInstance(InstancePainter)`.
  ///
  /// The port markers are suppressed in print view *unless* the rectangular shape is in use;
  /// an IEC box has no lead lines of its own, so without the markers its inputs would be
  /// invisible on paper.
  public func paintInstance(_ painter: InstancePainter) {
    paintBase(painter)
    if !painter.isPrintView || painter.gateShape == .rectangular {
      painter.drawPorts()
    }
  }
}

extension AbstractGate: InstancePaintable {}
extension AbstractGate: InstanceLabelProvider {}
