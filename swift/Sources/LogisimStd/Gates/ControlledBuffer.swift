// ControlledBuffer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.ControlledBuffer),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── One class, two registered factories ─────────────────────────────────────────────────────
//
// Upstream has no `_ID` constant here (its own comment says so) because the name is chosen by
// the constructor argument: `"Controlled Buffer"` and `"Controlled Inverter"` are two separate
// singletons of the same class, and those two strings are what a `.circ` file names.
//
// ── The tri-state output, which is the whole point of the component ─────────────────────────
//
// `propagate` drives one of four things, and the distinction matters to every bus this feeds:
//
//   control TRUE            -> the input (inverted for the inverter form)
//   control ERROR           -> ERROR at the component's width
//   control UNKNOWN or NIL  -> ERROR if the project's `ATTR_GATE_UNDEFINED` is `error`,
//                              otherwise UNKNOWN: i.e. floating, contributing nothing
//   control FALSE           -> UNKNOWN
//
// Getting the UNKNOWN/ERROR split wrong corrupts the bus rather than the component: in Java
// `Value.combine(TRUE, UNKNOWN)` is **ERROR**, not TRUE, so a buffer that emits UNKNOWN where
// it should emit ERROR (or the reverse) changes the resolved value at every other driver on the
// same wire. The four branches below are transcribed exactly, including that the FALSE case and
// the UNKNOWN case reach the same `createUnknown` by different routes.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.gates.ControlledBuffer`.
public final class ControlledBuffer: InstanceFactoryBase {

  /// The constructor's name strings; upstream's stand-in for an `_ID`. Do NOT change: these
  /// are what `.circ` files reference.
  public static let bufferId = "Controlled Buffer"
  public static let inverterId = "Controlled Inverter"

  // MARK: Attribute identities

  /// `ControlledBuffer.RIGHT_HANDED` / `LEFT_HANDED`, which side the control line enters on.
  public static let rightHanded = AttributeOption(value: "right")
  public static let leftHanded = AttributeOption(value: "left")

  /// `ControlledBuffer.ATTR_CONTROL`. Port-visible: it decides whether port 2 sits 10 above or
  /// 10 below the axis.
  public static let control: Attribute<AttributeOption> = Attributes.forOption(
    "control", choices: [rightHanded, leftHanded])

  /// Java's `public static final ComponentFactory FACTORY_BUFFER = new ControlledBuffer(false)`.
  public static let factoryBuffer = ControlledBuffer(isInverter: false)
  /// Java's `FACTORY_INVERTER = new ControlledBuffer(true)`.
  public static let factoryInverter = ControlledBuffer(isInverter: true)

  /// `isInverter()`.
  public let isInverter: Bool

  public init(isInverter: Bool) {
    self.isInverter = isInverter
    super.init(isInverter ? ControlledBuffer.inverterId : ControlledBuffer.bufferId)
    if isInverter {
      // The inverter form borrows `NotGate.ATTR_SIZE`; the buffer form has no size attribute at
      // all, which is why the two templates are written out separately rather than shared.
      setAttributes([
        StdAttr.facing.binding(Direction.east),
        StdAttr.width.binding(BitWidth.one),
        NotGate.size.binding(NotGate.sizeWide),
        ControlledBuffer.control.binding(ControlledBuffer.rightHanded),
        StdAttr.label.binding(""),
        StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      ])
    } else {
      setAttributes([
        StdAttr.facing.binding(Direction.east),
        StdAttr.width.binding(BitWidth.one),
        ControlledBuffer.control.binding(ControlledBuffer.rightHanded),
        StdAttr.label.binding(""),
        StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      ])
    }
    setFacingAttribute(StdAttr.facing)
    // `setKeyConfigurator(new BitWidthConfigurator(StdAttr.WIDTH))`, UI (D9). Not ported.
  }

  // MARK: Geometry

  /// `getOffsetBounds(AttributeSet)`.
  ///
  /// Only the inverter grows to 30, and only when its size attribute is not narrow. Note Java
  /// writes this as `!NotGate.SIZE_NARROW.equals(attrs.getValue(...))`, which is *true* when the
  /// attribute is absent, so a set without `ATTR_SIZE` takes the wide branch. The Swift
  /// optional comparison reproduces that: `attributes[NotGate.size]` is nil, which is `!=`
  /// `sizeNarrow`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    var w = 20
    if isInverter && attributes[NotGate.size] != NotGate.sizeNarrow {
      w = 30
    }
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    switch facing {
    case .north: return Bounds.create(-10, 0, 20, w)
    case .south: return Bounds.create(-10, -w, 20, w)
    case .west: return Bounds.create(0, -10, w, 20)
    case .east: return Bounds.create(-w, -10, w, 20)
    }
  }

  /// `configurePorts(Instance)` as a pure function (PATTERNS.md §0).
  ///
  /// `d` is the amount by which the body exceeds the base 20, so the input port stays flush with
  /// the back edge whatever the size attribute says. Port 2 is the control line and is **always
  /// one bit wide**, regardless of `StdAttr.WIDTH`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes.getValue(StdAttr.facing) ?? .east
    let bds = offsetBounds(attributes)
    let d = max(bds.width, bds.height) - 20
    let loc0 = Location.create(0, 0, hasToSnap: true)
    let loc1 = loc0.translate(facing.reverse(), 20 + d)
    let loc2: Location
    if attributes[ControlledBuffer.control] == ControlledBuffer.leftHanded {
      loc2 = loc0.translate(facing.reverse(), 10 + d, 10)
    } else {
      loc2 = loc0.translate(facing.reverse(), 10 + d, -10)
    }
    return [
      Port(0, 0, .output, StdAttr.width),
      Port(loc1.x, loc1.y, .input, StdAttr.width),
      Port(loc2.x, loc2.y, .input, 1),
    ]
  }

  // MARK: Propagation

  /// `propagate(InstanceState)`; see the file header for why the UNKNOWN/ERROR split is
  /// load-bearing.
  public override func propagate(_ state: any InstanceState) throws {
    let control = state.portValue(2)
    let width = state.attributeValue(StdAttr.width, default: .one)
    if control == Value.trueValue {
      let input = state.portValue(1)
      state.setPort(0, isInverter ? input.not() : input, GateAttributes.delay)
    } else if control == Value.errorValue {
      state.setPort(0, Value.createError(width), GateAttributes.delay)
    } else {
      let out: Value
      if control == Value.unknownValue || control == Value.nilValue {
        let opts = state.projectOptions
        if opts[Options.gateUndefined] == Options.gateUndefinedError {
          out = Value.createError(width)
        } else {
          out = Value.createUnknown(width)
        }
      } else {
        // control == FALSE, or a multi-bit control value, which cannot arise: port 2 is
        // declared one bit wide.
        out = Value.createUnknown(width)
      }
      state.setPort(0, out, GateAttributes.delay)
    }
  }

  // NOT PORTED: paintIcon: the toolbar icon (see AbstractGate's header).

  // MARK: The WireRepair feature

  /// `getInstanceFeature(Instance, Object)` (`ControlledBuffer.java:130-140`).
  ///
  /// **The one selective answer in the family, and the selectivity is the behaviour.** A
  /// controlled buffer accepts a repaired endpoint at its *control* port, port 2, the enable
  /// line on the flank, and refuses one anywhere else, including at its own input and output.
  /// Answering `true` unconditionally would look identical in a test that only asks "does a
  /// conformer exist", and would silently pull the data-path wire a grid step off the pin it
  /// was drawn to.
  ///
  /// Note this is a `ControlledBuffer` override rather than an `AbstractGate.shouldRepairWire`
  /// one, exactly as upstream has it: `ControlledBuffer` is a plain `InstanceFactory`, not an
  /// `AbstractGate` subclass, so it has its own `getInstanceFeature` and its own lambda. Since
  /// this port's `ControlledBuffer` also descends from `InstanceFactoryBase` and not
  /// `AbstractGate`, the shape carries over unchanged.
  ///
  /// `getPortLocation(2)` is `getEnd(2).getLocation()`; port 2 is always present because
  /// `ports(_:)` above always emits three.
  public override func instanceFeature(
    _ key: ComponentFeatureKey, _ component: StdInstanceComponent
  ) -> Any? {
    guard key == .wireRepair else {
      return super.instanceFeature(key, component)
    }
    return ClosureWireRepair { data in
      guard component.ends.indices.contains(2) else { return false }
      return data.point == component.ends[2].location
    }
  }

  // MARK: Painting (ControlledBuffer.java:169-244)

  /// `paintShape(InstancePainter)`.
  ///
  /// The inverter form reuses `PainterShaped.paintNot`, which reads `NotGate.ATTR_SIZE`; an
  /// attribute a controlled inverter does not have. `attributeValue` returns `nil` there, so
  /// the comparison against `SIZE_NARROW` fails and the wide triangle is drawn, which is
  /// exactly what Java's `getAttributeValue` returning `null` does.
  ///
  /// The non-inverter branch keeps upstream's dead `d`: `isInverter ? 10 : 0` is evaluated
  /// inside a branch that only runs when `isInverter` is false, so it is always 0.
  private func paintShape(_ painter: InstancePainter) {
    let facing = painter.attributeValue(StdAttr.facing, default: .east)
    let loc = painter.location
    let g = painter.g
    g.pushTranslate(loc.x, loc.y)
    let rotate = facing != .east
    if rotate { g.pushRotate(-facing.toRadians()) }

    if isInverter {
      PainterShaped.paintNot(painter)
    } else {
      g.strokeWidth = 2
      let d = isInverter ? 10 : 0
      g.drawPolyline([-d, -19 - d, -19 - d, -d], [0, -7, 7, 0])
    }

    if rotate { g.popTransform() }
    g.popTransform()
  }

  /// `NotGate.configureLabel(instance, false, instance.getPortLocation(2))`;
  /// ControlledBuffer.java:107. The control port is what makes this component's label
  /// placement differ from a plain buffer's.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    NotGate.labelPlacement(
      painter, isRectangular: false, control: painter.portLocation(2))
  }

  /// `paintGhost(InstancePainter)`.
  public func paintGhost(_ painter: InstancePainter) {
    paintShape(painter)
  }

  /// `paintInstance(InstancePainter)`.
  ///
  /// The control stub is drawn *first*, at width 3 and in the control port's own value colour,
  /// then the body over it in the component colour. Note the stub's direction:
  /// `pt0.translate(face, 0, ±6)` is the two-argument-plus-right form, zero along the facing,
  /// six to the side, so the stub runs perpendicular to the buffer, not along it.
  public func paintInstance(_ painter: InstancePainter) {
    let face = painter.attributeValue(StdAttr.facing, default: .east)
    let g = painter.g

    // draw control wire
    g.strokeWidth = 3
    if let pt0 = painter.portLocation(2) {
      let pt1: Location
      if painter.attributeValue(ControlledBuffer.control) == ControlledBuffer.leftHanded {
        pt1 = pt0.translate(face, 0, 6)
      } else {
        pt1 = pt0.translate(face, 0, -6)
      }
      if painter.showState {
        g.color = painter.color(of: painter.portValue(2))
      }
      g.drawLine(pt0.x, pt0.y, pt1.x, pt1.y)
    }

    // draw triangle
    g.color = painter.componentColor
    paintShape(painter)

    // draw input and output pins
    if !painter.isPrintView {
      painter.drawPort(0)
      painter.drawPort(1)
    }
    painter.drawLabel()
  }
}

extension ControlledBuffer: InstancePaintable {}
extension ControlledBuffer: InstanceLabelProvider {}
