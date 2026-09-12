// InstancePainter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.instance.InstancePainter and
// com.cburch.logisim.comp.ComponentDrawContext),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// The M6 paint seam. Upstream a component draws through a pair: `ComponentDrawContext` owns
// the `Graphics` and the canvas-wide flags (show state, print view, gate shape, highlighted
// wires), and `InstancePainter` is the per-component facade over it that also implements
// `InstanceState` so paint code can read ports and attributes. The two collapse here into one
// class, because D6 removes the only thing that made them separate: there is no `Graphics` to
// own and no `Graphics.create()` clone per component. What a component gets instead is a
// `SceneBuilder` (D6) and a `PaintContext` (the canvas-wide flags).
//
// D9: nothing here imports AppKit/CoreGraphics. `ComponentDrawContext` reaches into
// `AppPreferences` in five places: `COMPONENT_COLOR`, `GATE_SHAPE`, `PinAppearance`, the
// icon-size family and the look-and-feel label colour. Every one of those is a UI decision, so
// they are fields on `PaintContext` that `LogisimUI` fills in and that default to upstream's
// out-of-the-box values here.
//
// ── The ghost/icon distinction ──────────────────────────────────────────────────────────────
//
// Java signals "this is a ghost or a toolbar icon, not a placed component" by leaving
// `InstancePainter.comp` null and calling `setFactory(factory, attrs)`; paint code then tests
// `painter.getInstance() == null` (`PainterShaped.paintInputLines`, `PainterDin.paintOrLines`).
// That is reproduced exactly: `component` is optional and `isGhost` is `component == nil`.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

// MARK: - GateShape

/// `AppPreferences.GATE_SHAPE`'s value set.
///
/// **4.1.0 has exactly two live shapes.** `SHAPE_DIN40700` is commented out at
/// `AppPreferences.java:507` and is not in the `GATE_SHAPE` option array at `:512`, and
/// `AbstractGate.paintBase` has its dispatch arm commented out too. `PainterDin` is
/// nevertheless ported (each gate still declares `paintDinShape`), so re-enabling it is a
/// three-line change rather than a new port.
public enum GateShape: String, Hashable, Sendable, CaseIterable {
  /// `AppPreferences.SHAPE_SHAPED`: the curved MIL-STD/ANSI bodies. Upstream's default.
  case shaped = "shaped"
  /// `AppPreferences.SHAPE_RECTANGULAR`: the IEC boxes with a `&`/`≥1`/`=1` label.
  case rectangular = "rectangular"
  /// `AppPreferences.SHAPE_DIN40700`. Unreachable in 4.1.0; see the type doc.
  case din40700 = "din40700"
}

// MARK: - PinAppearance

/// `AppPreferences.PinAppearance`: the four port-marker sizes
/// (`ComponentDrawContext.drawPinMarker`).
public enum PinAppearance: String, Hashable, Sendable, CaseIterable {
  case dotSmall = "PinDotSmall"
  case dotMedium = "PinDotMedium"
  case dotBig = "PinDotBig"
  case dotBigger = "PinDotBigger"

  /// `(radius, offset)`: the two locals `drawPinMarker` switches on.
  public var marker: (radius: Int, offset: Int) {
    switch self {
    case .dotSmall: return (4, 2)
    case .dotMedium: return (6, 3)
    case .dotBig: return (8, 4)
    case .dotBigger: return (10, 5)
    }
  }
}

// MARK: - PaintContext

/// The canvas-wide half of `ComponentDrawContext`: everything a paint pass needs that is not
/// the component and not the emitter.
///
/// A protocol rather than a concrete type because the value lookups (`getValue(Location)`,
/// `Circuit.isConnected`) belong to `LogisimKernel`'s `CircuitState`/`Circuit`, and D9 keeps
/// `LogisimStd` from depending on the canvas that owns them. `StaticPaintContext` is the
/// no-simulation implementation used for ghosts, icons and headless scene diffs.
public protocol PaintContext: AnyObject {

  /// `ComponentDrawContext.getShowState()`, `!printView && showState`.
  var showState: Bool { get }

  /// `ComponentDrawContext.shouldDrawColor()`, `!printView && showColor`.
  var shouldDrawColor: Bool { get }

  /// `ComponentDrawContext.isPrintView()`.
  var isPrintView: Bool { get }

  /// `ComponentDrawContext.getGateShape()`, `AppPreferences.GATE_SHAPE.get()`.
  var gateShape: GateShape { get }

  /// `AppPreferences.PinAppearance.get()`, read by `drawPinMarker`.
  var pinAppearance: PinAppearance { get }

  /// `new Color(AppPreferences.COMPONENT_COLOR.get())`; the colour every component's outline
  /// is drawn in. Upstream's factory default is opaque black.
  var componentColor: SceneColor { get }

  /// **No upstream counterpart**; see `SceneBuilder.drawPinMarker` for why the port marker is
  /// a ring here and a filled disc in 4.1.0.
  ///
  /// The colour the ring's centre is knocked out with. It has to be the canvas ground, or near
  /// enough, or the "hole" stops reading as a hole; `markerHoleColorDefault` derives one from
  /// `componentColor` so a conformer that has a real background handy can override and one that
  /// does not still gets the right contrast on both a light and a dark canvas.
  var markerHoleColor: SceneColor { get }

  /// `CircuitState.getValue(Location)`. `.nilValue` when there is no live simulation.
  func value(at location: Location) -> Value

  /// `Circuit.isConnected(Location, Component)`.
  func isConnected(_ location: Location, excluding component: (any Component)?) -> Bool

  /// `CircuitState.getData(Component)`.
  func data(for component: any Component) -> (any InstanceData)?

  /// `CircuitState.setData(Component, Object)`.
  func setData(_ data: (any InstanceData)?, for component: any Component)

  /// `Propagator.getTickCount()`.
  var tickCount: Int { get }

  /// `!CircuitState.isSubstate()`.
  var isCircuitRoot: Bool { get }

  /// `getProject().getOptions().getAttributeSet()`.
  var projectOptions: any AttributeSet { get }
}

// MARK: - Port-marker ring

/// The one decision `LogisimStd` owns about the ring that replaced upstream's filled port dot:
/// what colour its hole is. The geometry lives with the emitter, in
/// `SceneBuilder.drawPinMarker`, which is also where the 4.1.0 citation for the disc it
/// replaced is written down.
///
/// A separate type rather than a private helper so the rule can be asserted directly. It is a
/// pure function of one colour, and a rule that is only reachable through a full paint is a
/// rule that gets asserted vacuously.
public enum PortMarkerRing {

  /// The ground a marker's hole is knocked out with, given the canvas's ink.
  ///
  /// `LogisimStd` deliberately cannot see `CircuitPalette` (D9), so it cannot ask for
  /// `.canvasBackground` and has to infer it. Ink and ground are always opposed, the light
  /// theme draws near-black components on a near-white canvas and the dark theme does the
  /// reverse, so the ink's own luminance is a sound proxy, and it tracks a re-themed canvas
  /// for free. A conformer that *does* have the real ground should override
  /// `PaintContext.markerHoleColor` and skip this entirely.
  ///
  /// Rec. 601 luma in integer arithmetic; the split is at mid-grey. `.palette` ink (a
  /// simulation-value colour) has no fixed luminance at build time, it is re-themed after the
  /// scene is sealed, so it falls back to white rather than guessing.
  public static func holeColor(ink: SceneColor) -> SceneColor {
    guard case .rgba(let c) = ink else { return .white }
    let luma = (299 * Int(c.r) + 587 * Int(c.g) + 114 * Int(c.b)) / 1000
    return luma < 128 ? .white : .black
  }
}

extension PaintContext {
  /// Default: inferred from `componentColor`. See `PortMarkerRing.holeColor(ink:)`.
  public var markerHoleColor: SceneColor { PortMarkerRing.holeColor(ink: componentColor) }
}

/// A `PaintContext` with no circuit behind it: every port reads `Value.NIL`, nothing is
/// connected, and there is no instance data.
///
/// This is what a ghost drag, a toolbar icon and a headless scene comparison all paint
/// against, and it is the reason `PaintContext` is a protocol at all; none of those three has
/// a `CircuitState`.
public final class StaticPaintContext: PaintContext {
  public var showState: Bool
  public var showColor: Bool
  public var isPrintView: Bool
  public var gateShape: GateShape
  public var pinAppearance: PinAppearance
  public var componentColor: SceneColor
  public var tickCount: Int
  public var isCircuitRoot: Bool
  public var projectOptions: any AttributeSet

  /// Set this when the caller knows the real canvas ground; leave it `nil` to infer one from
  /// `componentColor`.
  ///
  /// Deliberately a settable property rather than a new `init` parameter, even a defaulted one.
  /// Adding a parameter to this initialiser, anywhere in the list, default or not, changes its
  /// mangled symbol, which forces every already-compiled caller in every other target to be
  /// rebuilt or the link fails with an undefined `__allocating_init`. That is a gratuitous cost
  /// to hand three other agents working in this tree today.
  public var markerHoleColorOverride: SceneColor?

  public var markerHoleColor: SceneColor {
    markerHoleColorOverride ?? PortMarkerRing.holeColor(ink: componentColor)
  }

  public init(
    showState: Bool = false,
    showColor: Bool = true,
    isPrintView: Bool = false,
    gateShape: GateShape = .shaped,
    pinAppearance: PinAppearance = .dotSmall,
    componentColor: SceneColor = .black,
    tickCount: Int = 0,
    isCircuitRoot: Bool = true,
    projectOptions: (any AttributeSet)? = nil
  ) {
    self.showState = showState
    self.showColor = showColor
    self.isPrintView = isPrintView
    self.gateShape = gateShape
    self.pinAppearance = pinAppearance
    self.componentColor = componentColor
    self.tickCount = tickCount
    self.isCircuitRoot = isCircuitRoot
    self.projectOptions = projectOptions ?? EmptyAttributeSet()
  }

  public var shouldDrawColor: Bool { !isPrintView && showColor }

  public func value(at location: Location) -> Value { .nilValue }

  public func isConnected(_ location: Location, excluding component: (any Component)?) -> Bool {
    false
  }

  public func data(for component: any Component) -> (any InstanceData)? { nil }

  public func setData(_ data: (any InstanceData)?, for component: any Component) {}
}

/// Stand-in for `Project.getOptions().getAttributeSet()` when there is no project. Only the
/// gate-undefined option is ever read during a paint, and it is read with a default.
private final class EmptyAttributeSet: AbstractAttributeSet {
  override var attributes: [AnyAttribute] { [] }
  override func rawValue(_ attribute: AnyAttribute) -> AttributeValue? { nil }
  override func setRawValue(
    _ attribute: AnyAttribute, _ value: AttributeValue?
  ) throws {}
  override func makeCopyInstance() -> AbstractAttributeSet { EmptyAttributeSet() }
}

// MARK: - LabelPlacement

/// Where a component's `StdAttr.LABEL` sits, in circuit coordinates.
///
/// Upstream stores this on the component: `Instance.setTextField(labelAttr, fontAttr, x, y,
/// halign, valign)` builds an `InstanceTextField`, and `InstanceComponent.drawLabel` draws it.
/// The Swift `StdInstanceComponent` has no text field (see its header), so the placement is
/// recomputed on demand instead, which is sound because every upstream `computeLabel` /
/// `configureLabel` is a pure function of the attribute set and the location, and is exactly
/// why upstream has to re-run them from `instanceAttributeChanged`.
public struct LabelPlacement: Hashable, Sendable {
  public var x: Int
  public var y: Int
  public var halign: HAlign
  public var valign: VAlign

  public init(x: Int, y: Int, halign: HAlign, valign: VAlign) {
    self.x = x
    self.y = y
    self.halign = halign
    self.valign = valign
  }
}

extension LabelPlacement {

  /// `Instance.AVOID_*`, which edges of the body the label must not sit against.
  ///
  /// A bit set rather than an enum because upstream rotates it: the mask is written in the
  /// component's *unrotated* frame and `computeLabelTextField` shifts the low four bits by the
  /// facing, so `AVOID_LEFT` on an east-facing component becomes `AVOID_TOP` on a
  /// north-facing one.
  public struct Avoid: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let top = Avoid(rawValue: 1)
    public static let right = Avoid(rawValue: 2)
    public static let bottom = Avoid(rawValue: 4)
    public static let left = Avoid(rawValue: 8)
    public static let sides: Avoid = [.left, .right]
    public static let center = Avoid(rawValue: 16)
  }

  /// `Instance.computeLabelTextField(int avoid[, Object labelLoc])`.
  ///
  /// The generic label placement, used by every component that has a `LABEL_LOC` attribute
  /// rather than a hand-placed field. Lives here rather than on any one component because it
  /// is `Instance`'s, and roughly forty components call it.
  ///
  /// The rotation of the avoid mask is transcribed bit for bit:
  ///
  ///     NORTH: (avoid & 0x10) | ((avoid << 1) & 0xf) | ((avoid & 0xf) >> 3)
  ///     EAST:  (avoid & 0x10) | ((avoid << 2) & 0xf) | ((avoid & 0xf) >> 2)
  ///     SOUTH: (avoid & 0x10) | ((avoid << 3) & 0xf) | ((avoid & 0xf) >> 1)
  ///
  /// i.e. a rotate-left of the four edge bits by one, two or three positions, with the CENTER
  /// bit carried through untouched. WEST is the identity, which is why it has no arm.
  public static func computed(
    _ painter: InstancePainter, avoid: Avoid, labelLoc: StdAttr.LabelLocation? = nil
  ) -> LabelPlacement {
    var avoidBits = avoid.rawValue
    if avoidBits != 0 {
      switch painter.attributeValue(StdAttr.facing) {
      case .north:
        avoidBits = (avoidBits & 0x10) | ((avoidBits << 1) & 0xF) | ((avoidBits & 0xF) >> 3)
      case .east:
        avoidBits = (avoidBits & 0x10) | ((avoidBits << 2) & 0xF) | ((avoidBits & 0xF) >> 2)
      case .south:
        avoidBits = (avoidBits & 0x10) | ((avoidBits << 3) & 0xF) | ((avoidBits & 0xF) >> 1)
      case .west, nil:
        break
      }
    }
    let rotated = Avoid(rawValue: avoidBits)

    let bds = painter.bounds
    var x = bds.x + bds.width / 2
    var y = bds.y + bds.height / 2
    var halign = HAlign.center
    var valign = VAlign.center

    let loc = labelLoc ?? painter.attributeValue(StdAttr.labelLocation)
    switch loc {
    case .center:
      // Note this subtracts the offset from the *width and height* before halving, so the
      // label moves by half a pixel-pair, not by three.
      let offset = rotated.contains(.center) ? 3 : 0
      x = bds.x + (bds.width - offset) / 2
      y = bds.y + (bds.height - offset) / 2
    case .north:
      y = bds.y - 2
      valign = .bottom
      if rotated.contains(.top) {
        x += 2
        halign = .left
      }
    case .south:
      y = bds.y + bds.height + 2
      valign = .top
      if rotated.contains(.bottom) {
        x += 2
        halign = .left
      }
    case .east:
      x = bds.x + bds.width + 2
      halign = .left
      if rotated.contains(.right) {
        y -= 2
        valign = .bottom
      }
    case .west:
      x = bds.x - 2
      halign = .right
      if rotated.contains(.left) {
        y -= 2
        valign = .bottom
      }
    case nil:
      // Java falls through every `==` and keeps the centred defaults.
      break
    }
    return LabelPlacement(x: x, y: y, halign: halign, valign: valign)
  }
}

/// Implemented by a factory that wants `painter.drawLabel()` to do something:
/// upstream's `computeLabel(Instance)` / `NotGate.configureLabel(Instance, …)`.
///
/// A factory that does not conform draws no label, which matches an upstream factory that
/// never calls `setTextField`.
public protocol InstanceLabelProvider {
  func labelPlacement(_ painter: InstancePainter) -> LabelPlacement?
}

// MARK: - InstancePainter

/// `com.cburch.logisim.instance.InstancePainter`, fused with the per-component half of
/// `ComponentDrawContext`.
///
/// Deliberately does **not** conform to `InstanceState`: that protocol's `component` is
/// non-optional, and a ghost genuinely has none. Java conforms and throws from four of the
/// methods; here the four simply are not offered.
public final class InstancePainter {

  /// The emitter (D6). Named `g` so a ported call site reads like the Java it came from.
  public let g: SceneBuilder

  /// The canvas-wide flags and the circuit lookups.
  public let context: any PaintContext

  /// `InstancePainter.comp`. `nil` while painting a ghost or a toolbar icon.
  public private(set) var component: (any Component)?

  /// `InstancePainter.factory`; only consulted when `component` is `nil`.
  public private(set) var ghostFactory: (any InstanceFactory)?

  /// `InstancePainter.attrs`, likewise.
  private var ghostAttributes: (any AttributeSet)?

  /// Where a ghost is being drawn. Java rolls this into the `Graphics` translation before
  /// calling `paintGhost`; keeping it explicit lets `getLocation()` answer correctly, which
  /// several ghosts (`AbstractGate.paintBase`, `Buffer.paintBase`) depend on.
  private var ghostLocation: Location = Location.create(0, 0, hasToSnap: false)

  public init(g: SceneBuilder, context: any PaintContext, component: (any Component)? = nil) {
    self.g = g
    self.context = context
    self.component = component
  }

  // MARK: Target selection (Java's package-private setters)

  /// `setInstance(InstanceComponent)`.
  public func setComponent(_ value: (any Component)?) {
    component = value
  }

  /// `setFactory(InstanceFactory, AttributeSet)`: switches the painter into ghost mode.
  public func setFactory(
    _ factory: (any InstanceFactory)?, _ attributes: (any AttributeSet)?,
    at location: Location = Location.create(0, 0, hasToSnap: false)
  ) {
    component = nil
    ghostFactory = factory
    ghostAttributes = attributes
    ghostLocation = location
  }

  /// `getInstance() == null`: upstream's own test for "ghost or icon".
  public var isGhost: Bool { component == nil }

  // MARK: State queries (the InstanceState half)

  /// `getAttributeSet()`.
  public var attributeSet: any AttributeSet {
    component?.attributeSet ?? ghostAttributes ?? EmptyAttributeSet()
  }

  /// `getAttributeValue(Attribute<E>)`.
  public func attributeValue<V>(_ attribute: Attribute<V>) -> V? {
    attributeSet.getValue(attribute)
  }

  /// `getAttributeValue` for an attribute the factory guarantees is present.
  public func attributeValue<V>(
    _ attribute: Attribute<V>, default fallback: @autoclosure () -> V
  ) -> V {
    attributeSet.getValue(attribute) ?? fallback()
  }

  /// `getFactory()`.
  public var factory: (any InstanceFactory)? {
    (component?.factory as? any InstanceFactory) ?? ghostFactory
  }

  /// `getLocation()`.
  public var location: Location {
    component?.location ?? ghostLocation
  }

  /// `getBounds()`.
  public var bounds: Bounds {
    if let component { return component.bounds }
    guard let ghostFactory, let ghostAttributes else { return .empty }
    return ghostFactory.offsetBounds(ghostAttributes)
  }

  /// `getOffsetBounds()`.
  public var offsetBounds: Bounds {
    if let component {
      let loc = component.location
      return component.bounds.translate(-loc.x, -loc.y)
    }
    guard let ghostFactory, let ghostAttributes else { return .empty }
    return ghostFactory.offsetBounds(ghostAttributes)
  }

  /// `getPortValue(int)`; `Value.UNKNOWN` when there is no component or no state, exactly as
  /// upstream's ternary yields.
  public func portValue(_ index: Int) -> Value {
    guard let component, index >= 0, index < component.ends.count else { return .unknownValue }
    return context.value(at: component.end(at: index).location)
  }

  /// `isPortConnected(int)`.
  public func isPortConnected(_ index: Int) -> Bool {
    guard let component, index >= 0, index < component.ends.count else { return false }
    return context.isConnected(component.end(at: index).location, excluding: component)
  }

  /// `getPortLocation(int)`: `Instance.getPortLocation`, i.e. the end's location.
  public func portLocation(_ index: Int) -> Location? {
    guard let component, index >= 0, index < component.ends.count else { return nil }
    return component.end(at: index).location
  }

  /// `getData()`.
  public var data: (any InstanceData)? {
    guard let component else { return nil }
    return context.data(for: component)
  }

  /// `setData(InstanceData)`.
  public func setData(_ value: (any InstanceData)?) {
    guard let component else { return }
    context.setData(value, for: component)
  }

  /// `getShowState()`.
  public var showState: Bool { context.showState }

  /// `isPrintView()`.
  public var isPrintView: Bool { context.isPrintView }

  /// `shouldDrawColor()`.
  public var shouldDrawColor: Bool { context.shouldDrawColor }

  /// `getGateShape()`.
  public var gateShape: GateShape { context.gateShape }

  /// `getTickCount()`.
  public var tickCount: Int { context.tickCount }

  /// `isCircuitRoot()`.
  public var isCircuitRoot: Bool { context.isCircuitRoot }

  /// The colour every component outline is stroked in.
  public var componentColor: SceneColor { context.componentColor }

  /// The palette colour a `Value` draws in: `Value.getColor()`, resolved through the
  /// kernel's UI-free `paletteIndex` (D9).
  public func color(of value: Value) -> SceneColor {
    .palette(value.paletteIndex)
  }

  // MARK: Drawing helpers (the ComponentDrawContext half)

  /// `ComponentDrawContext.drawBounds(comp)`.
  public func drawBounds() {
    g.drawBounds(bounds)
    g.strokeWidth = 1
  }

  /// `ComponentDrawContext.drawDongle(x, y)`.
  ///
  /// Note upstream leaves the stroke at 2 afterwards, `drawDongle` is the one helper with no
  /// `switchToWidth(g, 1)` epilogue, and callers rely on it (`PainterShaped.paintInputLines`
  /// re-sets width 3 after every bubble precisely because the bubble left it at 2).
  public func drawDongle(_ x: Int, _ y: Int) {
    g.withStrokeWidth(2) { g.drawOval(x - 4, y - 4, 9, 9) }
    g.strokeWidth = 2
  }

  /// `ComponentDrawContext.drawHandle(x, y)`.
  public func drawHandle(_ x: Int, _ y: Int) { g.drawHandle(x, y) }

  /// `ComponentDrawContext.drawHandles(comp)`.
  public func drawHandles() {
    let b = bounds
    let left = b.x
    let right = left + b.width
    let top = b.y
    let bot = top + b.height
    g.drawHandle(right, top)
    g.drawHandle(left, bot)
    g.drawHandle(right, bot)
    g.drawHandle(left, top)
  }

  /// `ComponentDrawContext.drawClockSymbol(comp, x, y)`.
  public func drawClockSymbol(_ x: Int, _ y: Int) {
    g.drawClockSymbol(x: x, y: y)
    g.strokeWidth = 1
  }

  /// `ComponentDrawContext.drawClock(comp, i, dir)`: the little triangle on a clock input.
  public func drawClock(_ index: Int, _ direction: Direction) {
    guard let pt = portLocation(index) else { return }
    let x = pt.x
    let y = pt.y
    let clkSz = 4
    let clkSzD = clkSz - 1
    g.withStrokeWidth(2) {
      switch direction {
      case .north:
        g.drawLine(x - clkSzD, y - 1, x, y - clkSz)
        g.drawLine(x + clkSzD, y - 1, x, y - clkSz)
      case .south:
        g.drawLine(x - clkSzD, y + 1, x, y + clkSz)
        g.drawLine(x + clkSzD, y + 1, x, y + clkSz)
      case .east:
        g.drawLine(x + 1, y - clkSzD, x + clkSz, y)
        g.drawLine(x + 1, y + clkSzD, x + clkSz, y)
      case .west:
        g.drawLine(x - 1, y - clkSzD, x - clkSz, y)
        g.drawLine(x - 1, y + clkSzD, x - clkSz, y)
      }
    }
    g.strokeWidth = 1
  }

  /// `ComponentDrawContext.drawPinMarker(x, y)`, drawn as a ring rather than 4.1.0's filled
  /// disc: the divergence, and the jar citation for what it replaced, are on
  /// `SceneBuilder.drawPinMarker`.
  ///
  /// The colour the caller left on the builder still reaches the rim, so `drawPort`'s live
  /// `Value.getColor()` is preserved; only the interior is knocked out.
  public func drawPinMarker(_ x: Int, _ y: Int) {
    let (radius, offset) = context.pinAppearance.marker
    g.drawPinMarker(x, y, radius: radius, offset: offset, hole: context.markerHoleColor)
  }

  /// `ComponentDrawContext.drawPin(comp, i)`.
  public func drawPort(_ index: Int) {
    guard let component, index >= 0, index < component.ends.count else { return }
    let pt = component.end(at: index).location
    let saved = g.color
    g.color = showState ? color(of: context.value(at: pt)) : componentColor
    drawPinMarker(pt.x, pt.y)
    g.color = saved
  }

  /// `ComponentDrawContext.drawPin(comp, i, label, dir)`.
  public func drawPort(_ index: Int, _ label: String, _ direction: Direction) {
    guard let component, index >= 0, index < component.ends.count else { return }
    let pt = component.end(at: index).location
    let x = pt.x
    let y = pt.y
    let saved = g.color
    // Note the asymmetry with `drawPort(_:)`: the labelled overload falls back to BLACK, not
    // to COMPONENT_COLOR. Upstream, verbatim.
    g.color = showState ? color(of: context.value(at: pt)) : .black
    drawPinMarker(x, y)
    g.color = saved
    switch direction {
    case .east: g.drawText(label, x: x + 3, y: y, halign: .left, valign: .center)
    case .west: g.drawText(label, x: x - 3, y: y, halign: .right, valign: .center)
    case .south: g.drawText(label, x: x, y: y - 3, halign: .center, valign: .baseline)
    case .north: g.drawText(label, x: x, y: y + 3, halign: .center, valign: .top)
    }
  }

  /// `ComponentDrawContext.drawPins(comp)`.
  public func drawPorts() {
    guard let component else { return }
    let saved = g.color
    for end in component.ends {
      let pt = end.location
      g.color = showState ? color(of: context.value(at: pt)) : .black
      drawPinMarker(pt.x, pt.y)
    }
    g.color = saved
  }

  /// `ComponentDrawContext.drawRectangle(x, y, width, height, label)`.
  ///
  /// The label placement is upstream's arithmetic exactly, including that a box taller than 20
  /// puts the label at the top edge and a shorter one centres it with the `- 1` fudge.
  public func drawRectangle(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ label: String) {
    g.strokeWidth = 2
    g.drawRect(x, y, width, height)
    guard !label.isEmpty else { return }
    let fm = g.fontMetrics()
    let lwid = g.textBoundsInUserSpace(label, x: 0, y: 0).width
    if height > 20 {
      g.drawString(label, x: x + (width - lwid) / 2, y: y + 2 + fm.ascent)
    } else {
      g.drawString(label, x: x + (width - lwid) / 2, y: y + (height + fm.ascent) / 2 - 1)
    }
  }

  /// `InstancePainter.drawRectangle(Bounds, String)`.
  public func drawRectangle(_ bounds: Bounds, _ label: String) {
    drawRectangle(bounds.x, bounds.y, bounds.width, bounds.height, label)
  }

  /// `ComponentDrawContext.drawRoundBounds(comp, bds, color)`.
  public func drawRoundBounds(_ bounds: Bounds, _ fill: SceneColor?) {
    g.withStrokeWidth(2) {
      if let fill, fill != .white {
        g.withColor(fill) { g.fillRoundRect(bounds.x, bounds.y, bounds.width, bounds.height, 10, 10) }
      }
      g.withColor(componentColor) {
        g.drawRoundRect(bounds.x, bounds.y, bounds.width, bounds.height, 10, 10)
      }
    }
    g.strokeWidth = 1
  }

  /// `ComponentDrawContext.drawRoundBounds(comp, color)`.
  public func drawRoundBounds(_ fill: SceneColor?) {
    drawRoundBounds(bounds, fill)
  }

  /// `InstanceComponent.drawLabel(ComponentDrawContext)` -> `InstanceTextField.draw` ->
  /// `TextField.draw`.
  ///
  /// The DRC "marked label" round-rect is not drawn: `doMarkLabel` is set only by the FPGA
  /// design-rule checker, which is D11 territory.
  ///
  /// **One deliberate difference.** `InstanceTextField` caches its colour and visibility in
  /// fields that are only written from `attributeValueChanged`, so upstream misses a
  /// `LABEL_COLOR` that was loaded from a file and never subsequently changed. This reads both
  /// attributes directly, which agrees with upstream everywhere the cache is warm and is right
  /// where upstream's is stale.
  public func drawLabel() {
    guard let provider = factory as? InstanceLabelProvider,
      let placement = provider.labelPlacement(self)
    else { return }
    guard attributeValue(StdAttr.labelVisibility, default: true) else { return }
    let text = attributeValue(StdAttr.label, default: "")
    guard !text.isEmpty else { return }

    let font = attributeValue(StdAttr.labelFont, default: StdAttr.defaultLabelFont)
    let saved = (color: g.color, font: g.font)
    g.font = InstancePainter.sceneFont(font)
    if !isPrintView {
      let spec = attributeValue(StdAttr.labelColor, default: StdAttr.defaultLabelColor)
      g.color = .rgba(RGBA(r: spec.red, g: spec.green, b: spec.blue))
    }
    // `TextField.draw` resolves its own alignment and then calls `g.drawString`; `drawText`
    // does the identical arithmetic (`TextLayout.textBox`), so the two agree pixel for pixel.
    g.drawText(text, x: placement.x, y: placement.y, halign: placement.halign, valign: placement.valign)
    g.color = saved.color
    g.font = saved.font
  }

  /// `java.awt.Font` from a `FontSpec`.
  public static func sceneFont(_ spec: FontSpec) -> SceneFont {
    let family: SceneFont.Family
    switch spec.family {
    case "SansSerif": family = .sansSerif
    case "Serif": family = .serif
    case "Monospaced": family = .monospaced
    default: family = .named(spec.family)
    }
    return SceneFont(
      family: family,
      size: Double(spec.size),
      bold: spec.style.contains(.bold),
      italic: spec.style.contains(.italic))
  }
}

// MARK: - InstancePaintable

/// The M6 counterpart of `InstanceFactory.paintInstance` / `paintGhost` / `paintIcon`.
///
/// Kept as a separate protocol rather than as members on `InstanceFactory` so that a factory
/// which has not been given a paint implementation yet simply does not conform, and the
/// canvas draws nothing for it instead of drawing a placeholder box.
public protocol InstancePaintable: AnyObject {
  /// `paintInstance(InstancePainter)`.
  func paintInstance(_ painter: InstancePainter)
  /// `paintGhost(InstancePainter)`.
  func paintGhost(_ painter: InstancePainter)
}

/// `Component.draw(ComponentDrawContext)` for the components that are **not**
/// instance-backed.
///
/// `Splitter` is the only one in this module: it is a hand-written `Component` (the propagator
/// owns its bit-thread bookkeeping directly), so it draws itself rather than delegating to a
/// factory. The painter is handed the component through `setComponent(_:)` first, exactly as
/// `ComponentDrawContext` does.
public protocol ComponentPaintable: AnyObject {
  func draw(_ painter: InstancePainter)
}

extension InstancePaintable {
  /// `InstanceFactory.paintGhost`'s default is a **no-op**; its whole body is
  /// `painter.setFactory(null, null)`, which clears the painter rather than drawing anything
  /// (`InstanceFactory.java:269-271`).
  ///
  /// It is emphatically *not* `paintInstance`. A factory that draws no ghost of its own falls
  /// back to `AbstractComponentFactory.drawGhost`, which strokes the plain offset-bounds
  /// rectangle at width 2: a canvas-level fallback, not something a component draws for
  /// itself.
  public func paintGhost(_ painter: InstancePainter) {}
}
