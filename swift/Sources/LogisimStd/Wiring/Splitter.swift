// Splitter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.circuit.Splitter),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16). See `SplitterParameters.swift`'s header for why
// this file lives under `LogisimStd/Wiring/` rather than mirroring Java's `circuit` package.
//
// ══ WHY THIS IS NOT AN `InstanceFactory` COMPONENT ══════════════════════════════════════════
//
// Every other file in this directory follows `PATTERNS.md`'s chassis: an `InstanceFactoryBase`
// producing `StdInstanceComponent`s whose ports are `func ports(_:) -> [Port]`. `Splitter` does
// not, because Java's does not either: `Splitter extends ManagedComponent` directly, with its
// own hand-rolled `EndData` array (`configureComponent()`), not `InstanceFactory`'s `Port`
// abstraction. Forcing it into the shared chassis would mean inventing behaviour Java does not
// have; instead this file conforms directly to the same three protocols `Wire` does
// (`Component`, plus the `WireComponent`/`WireSplitterComponent` seam `CircuitWires.swift`
// declares for exactly this purpose: see that file's header, "`Wire`, `Splitter`, `Tunnel` and
// `PullResistor` all live above this module").
//
// ── The 32-bit-wrap / D13 surface here is narrower than it looks ────────────────────────────
//
// Every quantity `configureComponent()` derives: `bitEnd.count`, `fanout`, per-end widths;
// is already range-checked at the attribute layer: `SplitterAttributes.attrWidth` enforces
// 1...64 and `attrFanout` enforces 1...64, and an end's width can never exceed the incoming
// width. So `BitWidth.known` (the non-throwing, "already proven in range" constructor; see
// `Port.swift`'s header) is correct here, not `BitWidth.create`; there is no `.circ` value that
// can drive this computation out of range, unlike (say) `Value.createUnsafe` at the netlist
// layer, which by design validates nothing.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   (`draw` and `SplitterPainter` ARE ported; see this file's `draw(_:)` and
//   `SplitterPainter.swift`. The DRC `isMarked` ring inside `draw` is not; it is FPGA-only.)
//
//   * `configureMenu` / `SplitterDistributeItem`; the "Distribute Ends: Ascending/Descending"
//     context-menu action. Editing-tool surface (M7); `SplitterAttributes.computeDistribution`'s
//     `order < 0` branch it drives is kept (cheap, already shared code) even though the menu
//     item that calls it is not.
//   * `getToolTip(ComponentUserEvent)`: hover text, UI (D9).
//   * `ToolTipMaker`/`MenuExtender` conformance; neither protocol exists yet in this port (both
//     are M7 editing-tool contracts); Java answers `this` for both (the tooltip logic above and
//     the two `SplitterDistributeItem`s). Documented here for when the protocols land;
//     `feature(_:)` below returns `nil` for those two keys in the meantime.
//     `WireRepair` is NO LONGER in this list: it is ported (`LogisimStd/Instance/WireRepair.swift`),
//     this class conforms to it directly as Java's does, and `feature(_:)` answers `self`.
//   * `getFactory()`'s Java identity (`SplitterFactory.instance`) is exposed as `factory` per the
//     `Component` protocol, but there is no `setFactory` override; Java's is an empty stub, and
//     the protocol extension already supplies a no-op default.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.circuit.Splitter`.
///
/// `final class`, deliberately not `Equatable`/`Hashable`; D4. A splitter is keyed by
/// `ObjectIdentifier`/`ComponentRef` like every other component.
public final class Splitter: Component, WireComponent, WireSplitterComponent, WireRepair,
  AttributeListener
{

  /// `Splitter._ID`. Do not change, `.circ` files reference it.
  public static let id = "Splitter"

  // MARK: - DRC marking

  /// `Splitter.isMarked` / `setMarked(boolean)` / `isMarked()`; set by the design-rule checker
  /// to draw the highlight ring. The ring itself is M6; the flag is model state (same treatment
  /// as `Wire.isDrcHighlighted`).
  public private(set) var isMarked = false

  public func setMarked(_ value: Bool) { isMarked = value }

  // MARK: - WireSplitterComponent storage

  /// `Splitter.bitThread`: for each bit of end 0, its thread index within the end it is routed
  /// to (`-1` when routed nowhere). Java: `byte[]`.
  private var bitThreadStorage: [Int] = []

  /// `Splitter.wireData` (`CircuitWires.SplitterData`), (re)created by `configureComponent()`.
  public var splitterWireData: CircuitWires.SplitterData?

  /// Stands in for Java's `synchronized (spl)` around `configureComponent()`
  /// (`CircuitWires.java:651`); see `WireSplitterComponent.splitterLock`'s doc comment for why
  /// this must be the exact lock both the editing thread and `CircuitWires` take (D1).
  public let splitterLock = NSRecursiveLock()

  // MARK: - Component storage

  /// `getLocation()`.
  public let location: Location

  /// `getAttributeSet()`. Owned: the splitter is the only thing keeping it alive.
  public let attributeSet: any AttributeSet

  private var endArray: [EndData] = []
  private let listeners = ComponentListenerRegistry()

  /// D3: owned by the component; the token holds `self` strongly as the listener, so `self` must
  /// not be captured a second time anywhere else that could form a cycle. There is no closure
  /// here (unlike `StdInstanceComponent`) because `Splitter` conforms to `AttributeListener`
  /// directly, exactly as Java's `Splitter implements AttributeListener` does.
  private var attributeSubscription: AttributeSubscription?

  /// `Splitter(Location, AttributeSet)` (`Splitter.java:72-76`).
  public init(location: Location, attributes: SplitterAttributes) {
    self.location = location
    self.attributeSet = attributes
    configureComponent()
    attributeSubscription = attributes.addAttributeListener(self)
  }

  // MARK: - AttributeListener

  public func attributeListChanged(_ event: AttributeEvent) {}

  public func attributeValueChanged(_ event: AttributeEvent) {
    configureComponent()
  }

  // MARK: - configureComponent

  /// `Splitter.configureComponent()` (`Splitter.java:89-127`), `synchronized` in Java:
  /// reproduced with `splitterLock` per D1 (see the field's doc comment).
  private func configureComponent() {
    splitterLock.lock()
    defer { splitterLock.unlock() }

    guard let attrs = attributeSet as? SplitterAttributes else { return }
    let parms = attrs.parameters()
    let fanout = Int(attrs.fanout)
    let bitEnd = attrs.bitEnd

    // compute width of each end
    var bitThread = [Int](repeating: -1, count: bitEnd.count)
    var endWidth = [Int](repeating: 0, count: fanout + 1)
    endWidth[0] = bitEnd.count
    for i in bitEnd.indices {
      let thr = Int(bitEnd[i])
      if thr > 0 {
        bitThread[i] = endWidth[thr]
        endWidth[thr] += 1
      } else {
        bitThread[i] = -1
      }
    }
    bitThreadStorage = bitThread

    // compute end positions
    let origin = location
    var x = origin.x + parms.end0X
    var y = origin.y + parms.end0Y
    let dx = parms.endToEndDeltaX
    let dy = parms.endToEndDeltaY

    var ends: [EndData] = []
    ends.reserveCapacity(fanout + 1)
    // `BitWidth.known`, not `.create`; see the file header for why this can never be out of
    // range given `bitEnd.count` and `fanout` are already attribute-layer validated.
    ends.append(
      EndData(location: origin, width: BitWidth.known(bitEnd.count), type: .inputOutput))
    for i in 0..<fanout {
      ends.append(
        EndData(
          location: Location.create(x, y, hasToSnap: true),
          width: BitWidth.known(endWidth[i + 1]),
          type: .inputOutput))
      x += dx
      y += dy
    }
    endArray = ends
    splitterWireData = CircuitWires.SplitterData(fanOut: fanout)
    // `recomputeBounds()`; not ported as a separate step: `bounds` below is always derived
    // fresh from `SplitterFactory.offsetBounds`, so there is no cache to refresh (see
    // `StdInstanceComponent.bounds`'s identical reasoning).
    listeners.fireComponentInvalidated(ComponentEvent(source: self))
  }

  // MARK: - Component

  public var factory: any ComponentFactory { SplitterFactory.instance }

  /// `getBounds()`: derived, not cached; see `configureComponent()`'s note above.
  public var bounds: Bounds {
    SplitterFactory.instance.offsetBounds(attributeSet).translate(location.x, location.y)
  }

  /// `getEnds()`.
  public var ends: [EndData] { endArray }

  /// `getEnd(int)`. Out-of-range is a transcription defect, not user input reachable from a
  /// `.circ` file (every caller loops over `ends.indices` or a port number this class itself
  /// produced): D13's programmer-error carve-out, so this traps rather than throws.
  public func end(at index: Int) -> EndData {
    precondition(endArray.indices.contains(index), "end index \(index) out of range for Splitter")
    return endArray[index]
  }

  /// `endsAt(Location)`.
  public func endsAt(_ point: Location) -> Bool {
    endArray.contains { $0.location == point }
  }

  /// `Splitter.contains(Location)` (`Splitter.java:136-149`).
  ///
  /// **`super.contains(loc)` is now resolved, and it is NOT the plain box test.** Java's chain is
  /// `Splitter extends ManagedComponent extends AbstractComponent`, and `ManagedComponent`
  /// declares no `contains` of its own: verified against the shipping 4.1.0 jar's bytecode
  /// rather than a source tree (`ManagedComponent.class`'s method table has no `contains`; see
  /// `SplitterContainsToleranceTests.swift`'s header for the full listing). So the super call
  /// binds to `AbstractComponent.java:19-23`, which is `bds.contains(pt, 1)`; an **allowed
  /// error of 1**, not 0.
  ///
  /// This file previously guessed `bounds.contains(point)` (`allowedError` defaults to 0) and
  /// flagged the guess in this very comment. The consequence was a one-pixel-wide ring around
  /// every splitter where a click selected in 4.1.0 and missed here. Hit-test tolerance is not
  /// serialised, so no canonical/migration/edit-parity gate could see it; the dedicated unit
  /// test named above is the only cover.
  public func contains(_ point: Location) -> Bool {
    guard bounds.contains(point, 1) else { return false }
    let myLoc = location
    let facing = (attributeSet as? SplitterAttributes)?.facing ?? .east
    // `Location.manhattanDistanceTo` has no Swift port yet (not in this slice's files); inlined
    // directly since it is one line of arithmetic.
    let manhattan = abs(point.x - myLoc.x) + abs(point.y - myLoc.y)
    if facing == .east || facing == .west {
      return abs(point.x - myLoc.x) > 5 || manhattan <= 5
    } else {
      return abs(point.y - myLoc.y) > 5 || manhattan <= 5
    }
  }

  /// `getFeature(Object)` (`Splitter.java:189-195`).
  ///
  /// Java's three arms are `WireRepair`, `ToolTipMaker` and `MenuExtender`, each answered with
  /// `this`. The first is ported and is answered below; the other two have no Swift protocol yet
  /// (the tooltip is hover text and the menu extender is the "Distribute Ends" context item:
  /// both editing-UI surface, both recorded in this file's header), so they still answer `nil`
  /// rather than returning `self` against a contract that does not exist.
  public func feature(_ key: ComponentFeatureKey) -> Any? {
    key == .wireRepair ? self : nil
  }

  @discardableResult
  public func addComponentListener(_ listener: ComponentListener) -> ComponentSubscription? {
    listeners.add(listener)
  }

  // MARK: - WireComponent

  public var wireRole: WireComponentRole { .splitter }

  /// `Component.getLocation()`; a splitter's bundle at end 0 is anchored here, same as a tunnel.
  public var wireLocation: Location { location }

  /// `Component.getEnds()`, bridged from `EndData` (`LogisimFile`) to `WireEndInfo`
  /// (`LogisimKernel`): see `CircuitWires.swift`'s "Seam: component ports" header for why the
  /// two types exist separately and why the raw values line up 1:1.
  public var wireEnds: [WireEndInfo] {
    endArray.map {
      WireEndInfo(
        location: $0.location,
        width: $0.width,
        type: WireEndType(rawValue: $0.type.rawValue),
        isExclusive: $0.isExclusive)
    }
  }

  public var wireAttributeSet: (any AttributeSet)? { attributeSet }

  // `wireIsPinFactory`, `wireTunnelLabel`, `wirePullValue` all keep their protocol defaults
  // (`false`, `""`, `.unknownValue`): none apply to a splitter.

  // MARK: - WireSplitterComponent

  /// `((SplitterAttributes) spl.getAttributeSet()).bitEnd`.
  public var splitterBitEnd: [Int] {
    (attributeSet as? SplitterAttributes)?.bitEnd.map { Int($0) } ?? []
  }

  /// `Splitter.bitThread`.
  public var splitterBitThread: [Int] { bitThreadStorage }

  // MARK: - Misc accessors

  /// `Splitter.getEndpoints()`: the same array as `splitterBitEnd`, exposed under Java's own
  /// name too since other model code may reach for either.
  public var endpoints: [Int] { splitterBitEnd }

  // MARK: - WireRepair

  /// `shouldRepairWire(WireRepairData)` (`Splitter.java:242-245`): unconditionally `true`.
  ///
  /// Transcribed, not reasoned about, because the one-liner is easy to mistake for a stub. It is
  /// the real body: a splitter accepts any loose end that `WiringTool.checkForRepairs` has
  /// already narrowed to "one grid step past one of my ends and inside my bounds", and it does
  /// not care which end or which bit range. `Splitter` is also the only implementor upstream that
  /// conforms *directly* rather than vending a per-instance lambda; it has no `Instance` to
  /// close over, since it is a `ManagedComponent` rather than an `InstanceFactory` product.
  public func shouldRepairWire(_ data: WireRepairData) -> Bool { true }
}

extension Splitter: CustomStringConvertible {
  public var description: String { "Splitter[\(location)]" }
}

// MARK: - Painting (Splitter.java:154-172)

extension Splitter: ComponentPaintable {

  /// `draw(ComponentDrawContext)`.
  ///
  /// The DRC "marked instance" round-rect (`isMarked`) is not drawn: `setMarked` is set only by
  /// the FPGA netlist checker, which is D11 territory. The flag itself is kept as model state.
  public func draw(_ painter: InstancePainter) {
    guard let attrs = attributeSet as? SplitterAttributes else { return }
    if attrs.appear == .legacy {
      SplitterPainter.drawLegacy(painter, attrs, location)
    } else {
      SplitterPainter.drawLines(painter, attrs, location)
      SplitterPainter.drawLabels(painter, attrs, location)
      painter.drawPorts()
    }
  }
}
