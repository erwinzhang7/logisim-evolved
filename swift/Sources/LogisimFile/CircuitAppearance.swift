// CircuitAppearance.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.appear.{CircuitAppearance,
// AppearancePort, AppearanceAnchor, AppearanceSvgReader, CircuitPins}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// ── Scope: the netlist half of `CircuitAppearance`, and only that ───────────────────────────
//
// Upstream's `CircuitAppearance extends Drawing` is 533 lines of canvas model: layer ordering,
// `paintSubcircuit`, handle gestures, the appearance editor's undo actions, dynamic (`visible-*`)
// shapes. None of that is needed to make a subcircuit *connect*, and none of it is portable
// without the draw model (which is `LogisimDraw`, a module `LogisimFile` sits below).
//
// What a subcircuit needs is one method:
//
//     SortedMap<Location, Instance> getPortOffsets(Direction facing)
//
// It filters the object list down to `AppearancePort` and `AppearanceAnchor`, the two
// `AppearanceElement` subclasses, which carry a location and nothing drawable, makes every port
// relative to the anchor, rotates for the instance's facing, and keys the result by location in a
// `TreeMap`. `SubcircuitFactory.computePorts` turns that map into the component's ends, in map
// order. **That order is the port numbering a parent circuit wires to.**
//
// So this file reproduces `getPortOffsets` exactly, over a port/anchor list that is either
//
//   * built by `CircuitAppearanceDefaults` (the `isDefaultAppearance()` case: three styles), or
//   * parsed out of the circuit's verbatim `<appear>` element (the `APPEAR_CUSTOM` case).
//
// ── Why the custom case reads the raw XML rather than a shape model ─────────────────────────
//
// `Circuit.rawAppearance` already holds the `<appear>` element verbatim: `XmlReader
// .loadAppearance` absorbs it unconditionally so that D8 round-tripping survives a milestone
// with no canvas model. The port-bearing children of that element are `circ-port` and
// `circ-anchor`/`circ-origin`, and `AppearanceSvgReader.createShape` turns each into an
// `AppearanceElement` using nothing but four integer attributes. Reading them here needs no
// `CanvasObject`, no `SvgReader`, and no dependency on `LogisimDraw`: the drawn shapes in the
// same element (`rect`, `path`, `text`, …) are skipped, because `getPortOffsets` skips them too.
//
// When `LogisimDraw`'s model is wired into `CircuitAppearanceReader.handler`, this parse becomes
// redundant rather than wrong: the same two element names, the same arithmetic. It is written so
// that the handler can take over by supplying the layout instead.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// A hand-edited `<appear>` is untrusted input and must not be able to trap. Upstream lets
// `Integer.parseInt`/`Double.parseDouble` throw out of `createShape`, and `XmlReader
// .loadAppearance` catches it per shape and reports `fileAppearanceError`, so a malformed
// element costs *that shape*, not the load. Every parse below returns `nil` on failure and the
// element is skipped, which is the same outcome by the same granularity. There is no array
// indexing, no force-unwrap and no precondition anywhere in the parse.

import Foundation
import LogisimKernel

/// `com.cburch.logisim.circuit.appear.CircuitAppearance`, reduced to the port geometry.
///
/// One per `Circuit`, owned by that circuit's `CircuitSubcircuitFactory`, which is the same
/// 1:1 relationship `Circuit.getAppearance()` expresses upstream, reached from the other side.
///
/// D3: `unowned` back-edge. The circuit owns the factory owns this; nothing here may keep a
/// circuit alive.
public final class CircuitAppearance {

  private unowned let circuit: Circuit

  /// The last computed layout. Invalidated rather than recomputed eagerly, because the circuit
  /// mutates heavily during load (every `<comp>` is a separate `mutatorAdd`) and rebuilding the
  /// layout per component would be quadratic in a circuit's pin count.
  private var cachedLayout: AppearanceLayout?

  public init(circuit: Circuit) {
    self.circuit = circuit
  }

  /// Drop the cached layout. Called whenever the circuit's components or its appearance-bearing
  /// static attributes change; see `CircuitSubcircuitFactory`'s listener.
  public func invalidate() {
    cachedLayout = nil
  }

  // MARK: - What `SubcircuitFactory` asks for

  /// `getFacing()`: the anchor's facing, or `EAST` when there is no anchor.
  public var facing: Direction {
    layout().anchorFacing
  }

  /// `isDefaultAppearance()`:
  ///
  /// ```java
  /// return (circuit == null)
  ///     || !circuit.getStaticAttributes().getValue(APPEARANCE_ATTR).equals(APPEAR_CUSTOM);
  /// ```
  ///
  /// Note the polarity: *anything other than* `custom` is a default appearance, including a value
  /// the option list does not recognise. The `<appear>` element of a `classic` circuit is
  /// therefore ignored for ports; upstream reads `defaultCanvasObjects`, not the loaded shapes.
  public var isDefaultAppearance: Bool {
    circuit.staticAttributes[CircuitAttributes.appearance] != CircuitAttributes.appearCustom
  }

  /// `getPortOffsets(Direction facing)`.
  ///
  /// ```java
  /// final var ret = new TreeMap<Location, Instance>();
  /// for (final var port : ports) {
  ///   var loc = port.getLocation();
  ///   if (anchor != null) loc = loc.translate(-anchor.getX(), -anchor.getY());
  ///   if (facing != defaultFacing) loc = loc.rotate(defaultFacing, facing, 0, 0);
  ///   ret.put(loc, port.getPin());
  /// }
  /// ```
  ///
  /// Two properties of that `TreeMap` are load-bearing and are reproduced deliberately:
  ///
  ///   * **The iteration order is `Location.compareTo`**, i.e. ascending x, then ascending y:
  ///     *not* the order the ports appear in the shape list, and not the order the pins were
  ///     sorted into. For a default evolution appearance that happens to mean "every west port
  ///     top-to-bottom, then every east port top-to-bottom", because the west column sits a whole
  ///     box-width to the left of the east one; but the map, not that reasoning, is the rule.
  ///   * **`put` on a duplicate key overwrites**, so two ports resolving to the same offset
  ///     collapse to one entry holding the *last* pin. A hand-drawn appearance can do this. The
  ///     port count then genuinely differs from the pin count, and upstream lets it.
  public func portOffsets(facing: Direction) -> [(location: Location, pin: any Component)] {
    let layout = layout()
    let defaultFacing = layout.anchorFacing

    var byLocation: [Location: any Component] = [:]
    for port in layout.ports {
      var location = port.location
      if let anchor = layout.anchor {
        location = location.translate(-anchor.x, -anchor.y)
      }
      if facing != defaultFacing {
        location = location.rotate(from: defaultFacing, to: facing, xc: 0, yc: 0)
      }
      byLocation[location] = port.pin
    }

    return byLocation.keys.sorted().compactMap { key in
      byLocation[key].map { (location: key, pin: $0) }
    }
  }

  // MARK: - Building the layout

  /// The `AppearancePort`/`AppearanceAnchor` content of `getObjectsFromBottom()`.
  private func layout() -> AppearanceLayout {
    if let cachedLayout { return cachedLayout }
    let built = buildLayout()
    cachedLayout = built
    return built
  }

  private func buildLayout() -> AppearanceLayout {
    let pins = circuitPins()

    guard !isDefaultAppearance else {
      // `recomputeDefaultAppearance()`: `DefaultAppearance.build(pins, style, isFixed, name)`.
      return CircuitAppearanceDefaults.build(
        style: circuit.staticAttributes[CircuitAttributes.appearance],
        pins: pins,
        circuitName: circuit.name,
        isFixedSize: isNamedBoxShapedFixedSize)
    }

    // `APPEAR_CUSTOM`: the object list is whatever `setObjectsForce(circData.appearance)`
    // installed, i.e. the shapes parsed out of `<appear>`.
    if let element = circuit.rawAppearance,
      let parsed = CircuitAppearance.parseCustomLayout(element, pins: pins),
      !parsed.ports.isEmpty
    {
      return parsed
    }

    // `CircuitAppearance`'s constructor seeds the custom list with
    // `DefaultCustomAppearance.build(circuitPins.getPins())`, and `XmlCircuitReader` only
    // replaces it `if (CollectionUtil.isNotEmpty(circData.appearance))`. So a circuit marked
    // `custom` whose `<appear>` declared no usable `circ-port` keeps the default custom shape;
    // it is not portless.
    return CircuitAppearanceDefaults.customFallback(pins: pins)
  }

  /// `isNamedBoxShapedFixedSize()`.
  ///
  /// ```java
  /// return staticAttrs.containsAttribute(NAMED_CIRCUIT_BOX_FIXED_SIZE)
  ///     ? staticAttrs.getValue(NAMED_CIRCUIT_BOX_FIXED_SIZE)
  ///     : true;
  /// ```
  ///
  /// The `true` default matters: it is *not* the attribute's own default (`false`). A circuit
  /// whose static set somehow lacks the attribute gets fixed-size boxes.
  private var isNamedBoxShapedFixedSize: Bool {
    circuit.staticAttributes[CircuitAttributes.namedCircuitBoxFixedSize] ?? true
  }

  /// `CircuitPins.getPins()`.
  ///
  /// Upstream maintains this as a `HashSet<Instance>` kept current by a component listener, and
  /// hands out `new ArrayList<>(pins)`; an arbitrary order. Deriving it from `getNonWires()`
  /// instead gives *insertion* order, which is a strict improvement and cannot change a result:
  /// every builder sorts each edge list by location before placing anything, and the sort's only
  /// order-sensitive step is the tiebreak between two pins at identical coordinates, which a
  /// loaded circuit cannot contain.
  private func circuitPins() -> [any Component] {
    circuit.nonWires.filter(\.factory.isPin)
  }
}

// MARK: - The `<appear>` parse

extension CircuitAppearance {

  /// `AppearanceSvgReader.createShape` for the two `AppearanceElement` tags, run over every
  /// child of an `<appear>` element.
  ///
  /// Returns `nil` only when the element yields neither a port nor an anchor *and* there was
  /// nothing to find: the caller treats an empty result the same way, so the distinction is
  /// cosmetic; it exists so the intent of "found nothing" is not confused with "found an
  /// appearance with no ports".
  static func parseCustomLayout(
    _ appearElement: XMLElement, pins: [any Component]
  ) -> AppearanceLayout? {
    var layout = AppearanceLayout()
    /// `PinInfo.pinIsAlreadyUsed`; one `circ-port` may claim a given pin, and only one.
    var claimed = Set<ObjectIdentifier>()
    var sawAnything = false

    for element in XmlIterator.forChildElements(appearElement) {
      switch element.tagName {
      case "circ-anchor", "circ-origin":
        guard let location = svgLocation(element) else { continue }
        sawAnything = true
        layout.anchor = location
        // `if (elt.hasAttribute("facing")) ret.setValue(FACING, Direction.parse(...))`.
        // `Direction.parse` throws on an unrecognised token; upstream lets that escape and the
        // reader drops the shape. Here the anchor keeps its constructor default of EAST, which
        // is what a dropped anchor shape would have left behind anyway.
        if element.hasAttribute("facing"),
          let parsed = try? Direction.parse(element.getAttribute("facing"))
        {
          layout.anchorFacing = parsed
        }

      case "circ-port":
        guard let location = svgLocation(element),
          let pinLocation = svgPinReference(element),
          let wantsInput = svgIsInputPinReference(element)
        else { continue }
        sawAnything = true
        // The matching loop, verbatim: first unclaimed pin at that location whose direction
        // agrees. A `circ-port` naming a pin that no longer exists, or whose type was flipped
        // since the appearance was drawn, matches nothing and the shape is dropped, exactly as
        // `createShape` returning null does.
        for pin in pins {
          if claimed.contains(ObjectIdentifier(pin)) { continue }
          guard pin.location == pinLocation else { continue }
          guard !AppearancePinReader.isOutput(pin) == wantsInput else { continue }
          claimed.insert(ObjectIdentifier(pin))
          layout.ports.append(AppearancePortShape(location: location, pin: pin))
          break
        }

      default:
        // Every drawn shape. `getPortOffsets` ignores anything that is not an
        // `AppearanceElement`, so there is nothing to do with them here either.
        continue
      }
    }

    return sawAnything ? layout : nil
  }

  /// `AppearanceSvgReader.getLocation(Element, true)`.
  ///
  /// ```java
  /// if (elt.hasAttribute("width") && elt.hasAttribute("height")) {
  ///   px = (int) Math.round(x + w / 2);  py = (int) Math.round(y + h / 2);
  /// } else {
  ///   px = Integer.parseInt(elt.getAttribute("x"));  py = ...;
  /// }
  /// return Location.create(px, py, true);
  /// ```
  ///
  /// The first arm is the pre-4.0 spelling, where a port was written as the `<rect>`/`<circle>`
  /// box that drew it; the second is what `AppearancePort.toSvgElement` writes today. Both are
  /// live in the corpus, so both are read.
  private static func svgLocation(_ element: XMLElement) -> Location? {
    if element.hasAttribute("width") && element.hasAttribute("height") {
      guard let x = javaParseDouble(element.getAttribute("x")),
        let y = javaParseDouble(element.getAttribute("y")),
        let w = javaParseDouble(element.getAttribute("width")),
        let h = javaParseDouble(element.getAttribute("height"))
      else { return nil }
      guard let px = javaMathRoundToInt(x + w / 2), let py = javaMathRoundToInt(y + h / 2)
      else { return nil }
      return Location.create(px, py, hasToSnap: true)
    }
    guard let px = javaParseInt32(element.getAttribute("x")),
      let py = javaParseInt32(element.getAttribute("y"))
    else { return nil }
    return Location.create(px, py, hasToSnap: true)
  }

  /// `Location.create(parseInt(pinStr[0].trim()), parseInt(pinStr[1].trim()), true)`: the
  /// `pin="x,y"` attribute naming the `Pin` component this port stands for.
  ///
  /// Java splits on `,` and indexes `[0]` and `[1]`, so a malformed value throws either
  /// `ArrayIndexOutOfBoundsException` or `NumberFormatException`; both are caught one level up
  /// and drop the shape. `nil` here is that same outcome without the trap.
  private static func svgPinReference(_ element: XMLElement) -> Location? {
    let parts = javaSplitOnLiteral(element.getAttribute("pin"), separator: ",")
    guard parts.count >= 2,
      let x = javaParseInt32(javaTrim(parts[0])),
      let y = javaParseInt32(javaTrim(parts[1]))
    else { return nil }
    return Location.create(x, y, hasToSnap: true)
  }

  /// `AppearanceSvgReader.isInputPinReference(Element)`.
  ///
  /// ```java
  /// if (elt.hasAttribute("dir")) return elt.getAttribute("dir").equals("in");
  /// final var width = Double.parseDouble(elt.getAttribute("width"));
  /// return AppearancePort.isInputAppearance((int) Math.round(width / 2.0));
  /// ```
  ///
  /// `isInputAppearance(r)` is `r == INPUT_RADIUS`, i.e. `r == 4`; an input port was drawn as a
  /// square of side 8, an output as a circle of diameter 10. The backward-compatibility arm needs
  /// `width`, and its absence throws upstream; `nil` drops the shape instead.
  private static func svgIsInputPinReference(_ element: XMLElement) -> Bool? {
    if element.hasAttribute("dir") {
      return element.getAttribute("dir") == "in"
    }
    guard let width = javaParseDouble(element.getAttribute("width")),
      let radius = javaMathRoundToInt(width / 2.0)
    else { return nil }
    return radius == 4
  }
}

// MARK: - Java numeric parsing helpers

/// `Double.parseDouble(String)`, restricted to what an SVG attribute can hold.
///
/// Java trims leading/trailing whitespace and accepts a trailing `f`/`d` suffix; Swift's
/// `Double.init(String)` accepts neither but does accept hex-float and `inf`/`nan` spellings that
/// Java also accepts. The suffixes cannot appear in a file logisim itself wrote (`Double
/// .toString` never emits one), so trimming is the only adjustment made.
func javaParseDouble(_ text: String) -> Double? {
  let trimmed = javaTrim(text)
  if trimmed.isEmpty { return nil }
  return Double(trimmed)
}

/// `(int) Math.round(double)`.
///
/// `Math.round` is `floor(x + 0.5)`: **not** round-half-away-from-zero, so `-2.5` rounds to
/// `-2`, and Swift's `.rounded()` would give `-3`. The `(int)` cast then saturates at
/// `Int32.min`/`Int32.max` rather than wrapping. A non-finite input (reachable from `"NaN"` or
/// `"Infinity"`, both of which `Double.parseDouble` accepts) makes `Math.round` return 0 for NaN
/// and the saturated bound for an infinity; returning `nil` drops the shape instead, which is
/// the safer reading of a nonsensical coordinate and cannot trap.
func javaMathRoundToInt(_ value: Double) -> Int? {
  guard value.isFinite else { return nil }
  let rounded = (value + 0.5).rounded(.down)
  if rounded >= Double(Int32.max) { return Int(Int32.max) }
  if rounded <= Double(Int32.min) { return Int(Int32.min) }
  return Int(rounded)
}

// MARK: - Reading a pin's attributes

/// The four `Pin` attributes the appearance builders read, reached without depending on
/// `LogisimStd`.
///
/// `com.cburch.logisim.std.wiring.Pin` lives in the component library, which sits *above*
/// `LogisimFile`, so `Pin.ATTR_TYPE` and `PinAttributes` are not nameable here, exactly as
/// `Text.ATTR_TEXT` is not nameable in `XmlCircuitReader.isEmptyTextBox`. The same escape hatch
/// is used: reach the attribute by its `.circ` name.
///
/// Each reader tries identity first (`set[StdAttr.facing]`), because for a real `PinAttributes`
/// that is a direct field read and the exact value Java sees. The name-based path exists for a
/// `Pin` that is still an `UnresolvedComponent` or an `OpaqueAttributeSet` (D8), whose attributes
/// are synthesised from the XML and are therefore *not* the same objects as `StdAttr.facing`.
enum AppearancePinReader {

  /// `com.cburch.logisim.std.wiring.Pin.ATTR_TYPE`'s `.circ` name.
  static let typeAttributeName = "type"
  /// `Pin.OUTPUT`'s token. `XmlReader`'s pre-4.0 repair rewrites the old
  /// `<a name="output" val="true"/>` form into this one (`XmlReader.java:1090`) before any
  /// component is built, so only the modern spelling has to be recognised.
  static let outputTypeToken = "output"

  /// `Pin.FACTORY.isInputPin(instance)` negated: `attrs.type == EndData.OUTPUT_ONLY`.
  ///
  /// `PinAttributes.type` defaults to `Pin.INPUT`, so an absent or unrecognised value is an
  /// input. That is upstream's `else` branch in all three builders, not a fallback invented here.
  static func isOutput(_ component: any Component) -> Bool {
    string(component.attributeSet, named: typeAttributeName) == outputTypeToken
  }

  /// `pin.getAttributeValue(StdAttr.LABEL)`.
  ///
  /// Java measures `new Text(0, 0, label).getText().length()`; a null label would throw there,
  /// which it cannot, because `StdAttr.LABEL` defaults to `""`.
  static func label(_ component: any Component) -> String {
    let set = component.attributeSet
    if let direct = set[StdAttr.label] { return direct }
    return string(set, named: StdAttr.label.name) ?? ""
  }

  /// `pin.getAttributeValue(StdAttr.FACING)`.
  ///
  /// Only `DefaultClassicAppearance` reads this, to pick the pin's edge. `PinAttributes.facing`
  /// defaults to `Direction.EAST`.
  static func facing(_ component: any Component) -> Direction {
    let set = component.attributeSet
    if let direct = set[StdAttr.facing] { return direct }
    if let text = string(set, named: StdAttr.facing.name), let parsed = try? Direction.parse(text) {
      return parsed
    }
    return .east
  }

  /// `pin.getAttributeValue(StdAttr.WIDTH)`; the width `computePorts` gives the port, and
  /// therefore the width of the subcircuit's end.
  ///
  /// `BitWidth.create` rejects anything outside 1…64 (`BitWidth.java`), and a `.circ` can name
  /// such a value; the fallback is one bit, which is `StdAttr.WIDTH`'s own default.
  static func width(_ component: any Component) -> BitWidth {
    let set = component.attributeSet
    if let direct = set[StdAttr.width] { return direct }
    if let text = string(set, named: StdAttr.width.name),
      let bits = javaParseInt32(javaTrim(text)),
      let created = try? BitWidth.create(bits)
    {
      return created
    }
    return (try? BitWidth.create(1)) ?? BitWidth.unknown
  }

  /// One attribute, read as the string the `.circ` file spelled it with.
  private static func string(_ set: any AttributeSet, named name: String) -> String? {
    guard let attribute = set.attribute(named: name), let raw = set.rawValue(attribute)
    else { return nil }
    return attribute.standardString(for: raw)
  }
}
