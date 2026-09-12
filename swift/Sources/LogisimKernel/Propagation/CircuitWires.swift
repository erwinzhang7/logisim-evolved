//
//  CircuitWires.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (com.cburch.logisim.circuit.CircuitWires and
//  com.cburch.logisim.circuit.CircuitPoints / WidthIncompatibilityData),
//  https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
//  developers. This translation is a derivative work and is therefore GPL-3.0-only.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port target is **4.1.0** (D16), read from
//  `upstream-java-4.1.0/src/main/java/com/cburch/logisim/circuit/CircuitWires.java`, NOT from
//  main. Line citations below are 4.1.0 line numbers.
//
//  ═══════════════════════════════════════════════════════════════════════════════════════════
//  WHAT THIS FILE IS
//
//  `CircuitWires` is the netlist: it decides what is connected to what. Two union-finds run over
//  the circuit, one over `WireBundle`s (buses, which traverse tunnels but not splitters) and one
//  over `WireThread`s (1-bit traces, which traverse splitters), and the result is a
//  `Connectivity` map that is static for as long as the circuit is not edited. Each simulated
//  instance of the circuit then gets its own `CircuitWires.State`, which is where the `Value`s
//  live.
//
//  ── THE INVARIANT THIS FILE EXISTS TO CARRY (D15, tracker task #14) ────────────────────────
//
//  `ValuedBus.recalculate()` must keep its `width <= 0` / degenerate / `width == 1` early returns
//  **before** the `Value.create_unsafe` call, in Java's order. All three are marked in place
//  below; do not "simplify" them.
//
//  Guards 1 and 2 are load-bearing *here*: a bus with an invalid width, and a degenerate bus, both
//  have `threads == nil`, so without their early return they reach the fold and throw
//  `staleConnectivity`: a value upstream computes becoming a simulation error. Pinned by
//  `LogisimKernelTests/NarrowWidthBusTests.swift`, which goes red when either is disabled.
//
//  Guard 3 (`width == 1`) is load-bearing **upstream and not here**, and the difference is
//  measured rather than argued; see the boxed comment at `recalculate()` and D15's corrections.
//  It stays because the port's job is to be 4.1.0, not because deleting it would change an output.
//  The often-repeated "344 false divergences" belongs to `tools/valuebridge/ValueBridge.java`,
//  where building test cases through `create_unsafe` defeated Java's identity branches; it was
//  never a `CircuitWires` measurement and should not be cited as one.
//
//  `Value.createUnsafe` itself validates nothing: width 65, width 100 and width −1 are all
//  accepted, exactly as Java's does (D15). Nothing here adds validation to it.
//
//  ── WHAT DID NOT COME ACROSS ───────────────────────────────────────────────────────────────
//
//  * `draw(ComponentDrawContext, Collection<Component>)` (`CircuitWires.java:850-985`); 135
//    lines of AWT. D9 forbids any of it in the kernel. Its *inputs* are all exposed
//    (`getWireBundle`, `getBusValue`, `pointStore.getComponentCount`, `WireBundle.isBus()`,
//    `WireBundle.isValid()`), so `LogisimRender` can reproduce it at M6 without this file
//    learning about graphics.
//  * `Value.getColor()` reachable from `draw`: D9; the kernel deals in palette indices.
//  * slf4j logging: replaced by the `onError` hook, which the CLI and the UI install
//    differently.
//
//  ── THREADING ────────────────────────────────────────────────────────────────────────────
//
//  Unlike Java CircuitWires.java:504-515, all mutable topology collections and PointStore
//  queries share topologyLock. A builder holds it through publication, so an edit cannot be
//  overwritten by a stale build and two inline-dispatcher callers cannot build concurrently.
//  Published connectivity is retained by each reader. The steady propagation path takes only
//  connectivityLock to fetch that generation; no topology lock is taken per dirty point.
//
//  Lock order is topologyLock -> connectivityLock. Dispatcher hops happen with neither held.
//  Components/attributes and per-instance State are outside this lock's ownership: callers must
//  still serialize component edits and reads of live values with the simulation model lock.
//  Dispatcher and error-handler configuration must be installed before sharing this object.
//  ═══════════════════════════════════════════════════════════════════════════════════════════
//

import Foundation

// MARK: - Errors (D13)

/// Errors raised by the wiring layer.
///
/// D13: a Java exception reachable from a malformed `.circ` becomes a Swift `throw`, never a
/// trap. Every case below corresponds to a Java exception that `getConnectivity()`'s
/// `catch (Exception t)` (`CircuitWires.java:1017`) or `Simulator`'s `catch (Exception err)`
/// already handles, so each one degrades to "the circuit is marked in error" rather than killing
/// the process.
public enum CircuitWiresError: Error, CustomStringConvertible {
  /// `throw new IllegalStateException("oops, two wires occupy same location")`
  /// (`CircuitWires.java:405`). Message reproduced verbatim; it is user-visible.
  case twoWiresAtSameLocation(Location)

  /// `throw new ArrayIndexOutOfBoundsException("from " + i + " of " + n)`
  /// (`CircuitWires.java:667`).
  case splitterSourceBitOutOfRange(bit: Int, count: Int)

  /// `throw new ArrayIndexOutOfBoundsException("to " + thr + " of " + n)`
  /// (`CircuitWires.java:670`).
  case splitterThreadOutOfRange(thread: Int, count: Int)

  /// Java: `NullPointerException` from `tempBundlePositions.add(...)` on an already-constructed
  /// thread: reachable when a splitter's stale `endBundle` entry unites a fresh bundle's thread
  /// into a thread from a previous connectivity generation.
  case threadAlreadyConstructed

  /// Java: `NullPointerException` from `comp.getEnd(loc)` returning `null` while building a
  /// `BusConnection` (`CircuitWires.java:238`): reachable when a component's port list and the
  /// point map disagree, which a half-applied `replace(comp, oldEnd, newEnd)` can produce.
  case noEndAtLocation(Location)

  /// Java: `NullPointerException` dereferencing a bundle or bus that a previous connectivity
  /// generation has released. Java sees a stale-but-live object; ARC does not keep one (D3).
  case staleConnectivity(String)

  /// `IllegalStateException("can't clean element that is not dirty")` /
  /// `("bad position for dirty element")` / `("bad position for clean element")`
  /// (`CircuitWires.java:463`, `:466`, `:482`). Messages verbatim.
  case dirtyBookkeeping(String)

  public var description: String {
    switch self {
    case let .twoWiresAtSameLocation(loc):
      return "oops, two wires occupy same location (\(loc))"
    case let .splitterSourceBitOutOfRange(bit, count):
      return "from \(bit) of \(count)"
    case let .splitterThreadOutOfRange(thread, count):
      return "to \(thread) of \(count)"
    case .threadAlreadyConstructed:
      return "wire thread has already finished constructing"
    case let .noEndAtLocation(loc):
      return "component has no port at \(loc)"
    case let .staleConnectivity(detail):
      return "stale connectivity: \(detail)"
    case let .dirtyBookkeeping(message):
      return message
    }
  }
}

// MARK: - Seam: component ports

/// `com.cburch.logisim.comp.EndData.INPUT_ONLY` / `OUTPUT_ONLY` / `INPUT_OUTPUT`.
///
/// **Seam.** `EndData` lives in `LogisimFile`, which depends on `LogisimKernel` and not the other
/// way round (D9). Raw values match `EndData`'s so a conformer's mapping is the identity.
public struct WireEndType: OptionSet, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let inputOnly = WireEndType(rawValue: 1)
  public static let outputOnly = WireEndType(rawValue: 2)
  public static let inputOutput: WireEndType = [.inputOnly, .outputOnly]
}

/// The four fields of `EndData` that the wiring layer reads.
///
/// **Seam.** A plain value type rather than a protocol: `EndData` is already a struct in
/// `LogisimFile`, the field list is identical, and an existential array here would box on a path
/// that runs once per component per connectivity rebuild.
public struct WireEndInfo: Hashable, Sendable {
  public let location: Location
  public let width: BitWidth
  public let type: WireEndType
  public let isExclusive: Bool

  public init(location: Location, width: BitWidth, type: WireEndType, isExclusive: Bool = false) {
    self.location = location
    self.width = width
    self.type = type
    self.isExclusive = isExclusive
  }
}

// MARK: - Seam: components

/// Which of the five buckets `CircuitWires.add` sorts a component into
/// (`CircuitWires.java:538-561`).
///
/// **Seam.** Java asks `comp instanceof Wire`, `comp instanceof Splitter`,
/// `comp.getFactory() instanceof Tunnel` and `... instanceof PullResistor`. `Wire`, `Splitter`,
/// `Tunnel` and `PullResistor` all live above this module, so the conformer answers the question
/// directly instead.
public enum WireComponentRole: Hashable, Sendable {
  case wire
  case splitter
  case tunnel
  case pullResistor
  /// Java's `else` branch: "all components except wires, splitters and pull resistors".
  case plain
}

/// What `CircuitWires` needs from a `com.cburch.logisim.comp.Component`.
///
/// **Seam.** `Component` is in `LogisimFile`. D9 keeps `LogisimKernel` below it, so the netlist
/// codes against this protocol; `LogisimFile.Component` conforms, and the mapping is mechanical.
///
/// **D3.** `CircuitWires` holds conformers **strongly**, exactly as Java's `HashSet<Component>`
/// fields do. That closes no cycle: `Circuit` owns both the components and the `CircuitWires`,
/// and no component holds a strong reference back into the netlist.
public protocol WireComponent: AnyObject {
  /// Which bucket `add`/`remove` sorts this component into.
  var wireRole: WireComponentRole { get }

  /// `Component.getLocation()`: used for tunnels, whose bundle is anchored at the component's
  /// own location rather than at a port.
  var wireLocation: Location { get }

  /// `Component.getEnds()`.
  var wireEnds: [WireEndInfo] { get }

  /// `comp.getFactory() instanceof Pin` (`CircuitWires.java:242`).
  ///
  /// A `Pin` is treated as a **sink even when it drives**, because it needs a notification on
  /// every input change to colour itself correctly. That special case is load-bearing for
  /// `State`'s driven-value carry-over and is preserved.
  var wireIsPinFactory: Bool { get }

  /// `comp.getAttributeSet()`, for the tunnel/pull-resistor attribute listener. `nil` opts the
  /// component out of listening, which is safe: it only means an edit to its label will not void
  /// the connectivity map by itself.
  var wireAttributeSet: (any AttributeSet)? { get }

  /// `comp.getAttributeSet().getValue(StdAttr.LABEL)`, untrimmed (`CircuitWires.java:760`
  /// trims it).
  var wireTunnelLabel: String { get }

  /// `PullResistor.getPullValue(instance)` (`CircuitWires.java:752`).
  ///
  /// The `Instance` hop is gone by D3; `Instance` ⇄ `InstanceComponent` is a strong 2-cycle on
  /// every placed component, so the facade collapses and the value is read straight off the
  /// component.
  var wirePullValue: Value { get }
}

extension WireComponent {
  public var wireIsPinFactory: Bool { false }
  public var wireAttributeSet: (any AttributeSet)? { nil }
  public var wireTunnelLabel: String { "" }
  public var wirePullValue: Value { .unknownValue }

  /// `Component.getEnd(Location)`: the port at `loc`, or `nil`.
  public func wireEnd(at location: Location) -> WireEndInfo? {
    wireEnds.first { $0.location == location }
  }
}

/// `com.cburch.logisim.circuit.Wire`, as the netlist sees it.
public protocol WireSegmentComponent: WireComponent {
  /// `Wire.e0`.
  var wireEnd0: Location { get }
  /// `Wire.e1`.
  var wireEnd1: Location { get }
}

/// `com.cburch.logisim.circuit.Splitter`, as the netlist sees it.
///
/// **Seam.** `Splitter` and `SplitterAttributes` are `LogisimFile`/`LogisimStd` work.
public protocol WireSplitterComponent: WireComponent {
  /// `((SplitterAttributes) spl.getAttributeSet()).bitEnd`: for each bit of end 0, which end it
  /// is routed to (`0` = nowhere). Java's is a `byte[]`.
  var splitterBitEnd: [Int] { get }

  /// `Splitter.bitThread`: for each bit of end 0, its thread index within the end it is routed
  /// to. Java's is a `byte[]` and holds `-1` for bits routed nowhere.
  var splitterBitThread: [Int] { get }

  /// Stands in for Java's `synchronized (spl)` (`CircuitWires.java:651`).
  ///
  /// D1 forbids solving this with an actor. The Java monitor is re-entrant, so this must be an
  /// `NSRecursiveLock`, and it must be the *same* lock the editing thread takes when it mutates
  /// the splitter's attributes; the deadlock-avoidance argument in `getConnectivity`'s comment
  /// depends on there being exactly one lock per splitter.
  var splitterLock: NSRecursiveLock { get }

  /// `Splitter.wireData`, created by `Splitter.configureComponent` in Java
  /// (`Splitter.java:123`).
  var splitterWireData: CircuitWires.SplitterData? { get set }
}

// MARK: - Seam: the circuit state

/// What `CircuitWires.propagate` needs from a `CircuitState`.
///
/// **Seam.** `CircuitState` is another M3 slice and lives above this module. Deliberately *not*
/// declared as a refinement of `PropagatorCircuitState`: one class (`CircuitState`) will conform
/// to both, but keeping them independent means a change to either slice's seam cannot break the
/// other's file.
///
/// **D3.** `CircuitWires` stores **no** reference to a conformer; the state is a parameter on
/// every call, exactly as in Java. The only edge in the other direction is
/// `wireData`, which is an owning edge from the state down into a `State` object that references
/// nothing above it.
public protocol WireCircuitState: AnyObject {
  /// `CircuitState.getWireData()` / `setWireData(...)` (`CircuitState.java`).
  var wireData: CircuitWires.State? { get set }

  /// `CircuitState.clearValuesByWire()`.
  func clearValuesByWire()

  /// `CircuitState.markComponentsDirty(Collection<Component>)`.
  func markComponentsDirty(_ components: [any WireComponent])

  /// `CircuitState.setValueByWire(Value, Location[], BusConnection[])`.
  func setValueByWire(
    _ value: Value,
    locations: [Location],
    connections: [CircuitWires.BusConnection])
}

// MARK: - Seam: dirty points

/// One entry of the `ArrayList<Propagator.SimulatorEvent> dirtyPoints` that
/// `CircuitWires.propagate` consumes (`CircuitWires.java:1084`).
public protocol WireDirtyPoint {
  /// `SimulatorEvent.loc`.
  var wireLoc: Location { get }
  /// `SimulatorEvent.cause`: compared by identity, per D4.
  var wireCause: AnyObject? { get }
  /// `SimulatorEvent.val`.
  var wireVal: Value? { get }
}

/// The join between this slice and the `Propagator` slice.
///
/// `PropagationEvent` (`Propagation/PropagationEvent.swift`, owned by the propagation-core slice)
/// **is** `Propagator.SimulatorEvent`, so it is the real conformer. The conformance is declared
/// here rather than left for an integrator because "each half built correctly and nothing owned
/// the join" is the single largest defect class this project has hit; an unowned join is worse
/// than a small cross-file coupling. If that slice reshapes the event, this extension is the one
/// place that needs updating.
extension PropagationEvent: WireDirtyPoint {
  public var wireLoc: Location { loc }
  public var wireCause: AnyObject? { cause }
  public var wireVal: Value? { val }
}

// MARK: - Seam: which thread may build the connectivity map

/// Stands in for `SwingUtilities.isEventDispatchThread()` / `SwingUtilities.invokeAndWait(...)`
/// (`CircuitWires.java:1011`, `:1026`).
///
/// Owner-thread dispatch is optional; inline callers are serialized by the topology lock.
public protocol WireConnectivityDispatcher: AnyObject {
  /// `SwingUtilities.isEventDispatchThread()`.
  var isConnectivityOwnerThread: Bool { get }

  /// `SwingUtilities.invokeAndWait(runnable)`; must run `body` on the owner thread and **block**
  /// until it returns, as `invokeAndWait` does.
  func runOnConnectivityOwnerThread(_ body: () -> Void)
}

/// The headless dispatcher: every thread is the owner thread and nothing hops.
///
/// This is what `logisim-cli` and the differential harness use. It is behaviourally identical to
/// upstream for a single-threaded driver, because upstream's AWT path *also* computes the map on
/// the calling thread; the hop only exists to keep two real threads off each other.
public final class InlineConnectivityDispatcher: WireConnectivityDispatcher {
  public init() {}
  public var isConnectivityOwnerThread: Bool { true }
  public func runOnConnectivityOwnerThread(_ body: () -> Void) { body() }
}

// MARK: - Java `Component.equals`

/// Java's `Object.equals` as the `circuit` package sees it for a `Component`.
///
/// **D4 says component identity is reference identity, and `Wire` is the one documented
/// exception upstream actually relies on.** `Wire.equals` is structural on its endpoints
/// (`Wire.java:160-162`) with `hashCode = e0.hashCode() * 31 + e1.hashCode()` (`:269-270`), so
/// `HashSet<Wire>.remove(w)` and `ArrayList<Component>.indexOf(w)` both match *any* wire drawn
/// between the same two points, not only the identical object.
///
/// That matters on the removal path: `CircuitWires.remove` and `CircuitPoints.removeSub` are
/// reached from `ReplacementMap` and the wire-repair tools, which construct fresh `Wire` objects
/// for segments the circuit already holds. Matching by `===` there would remove the wire from the
/// key set and leave it in the ordered list; a silent desync that survives until the next
/// connectivity rebuild reads a wire the circuit no longer contains.
///
/// Every other `Component` subclass inherits `Object.equals`, so identity is correct for them.
func javaComponentEquals(_ lhs: any WireComponent, _ rhs: any WireComponent) -> Bool {
  if lhs === rhs { return true }
  guard
    lhs.wireRole == .wire, rhs.wireRole == .wire,
    let a = lhs as? any WireSegmentComponent,
    let b = rhs as? any WireSegmentComponent
  else { return false }
  return a.wireEnd0 == b.wireEnd0 && a.wireEnd1 == b.wireEnd1
}

// MARK: - CircuitWires

/// `com.cburch.logisim.circuit.CircuitWires`.
///
/// Stores and calculates the values propagating along every wire and bus in a circuit;
/// everything to do with netlist connectivity.
public final class CircuitWires {

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - WidthIncompatibilityData
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `com.cburch.logisim.circuit.WidthIncompatibilityData`.
  ///
  /// Nested rather than given its own file: the slice's file list does not include
  /// `WidthIncompatibilityData.swift`, and nesting it means a parallel port of that class cannot
  /// collide with this one at link time. Reported as a seam.
  public final class WidthIncompatibilityData: Equatable {
    private var points: [Location] = []
    private var widths: [BitWidth] = []

    public init() {}

    /// `boolean equals(Object other)` (`WidthIncompatibilityData.java:33-54`).
    ///
    /// Reproduced verbatim, **including the index confusion**: Java's outer loop runs `i` over
    /// `this.size()` but reads `o.getPoint(i)`, and its inner loop runs `j` over `o.size()` while
    /// reading `this.getPoint(j)`. The equal-size precondition makes both in-bounds, so the net
    /// effect is "every pair of `o` occurs somewhere in `this`"; a one-directional subset test
    /// that is only a true equality because `add` deduplicates and the sizes match. It is *not*
    /// rewritten into a set comparison here: `Connectivity.addWidthIncompatibilityData` is Java's
    /// `HashSet.add`, so this predicate decides which duplicate width-conflict reports collapse,
    /// and that is user-visible in the error list.
    ///
    /// Java's `hashCode()` is `size()` (`:81-84`). It is not modelled: the ported set is an
    /// insertion-ordered array scanned with this `==`, and since equal objects necessarily have
    /// equal sizes, the dedup outcome is identical to `HashSet`'s.
    public static func == (lhs: WidthIncompatibilityData, rhs: WidthIncompatibilityData) -> Bool {
      if lhs === rhs { return true }
      if lhs.size != rhs.size { return false }
      for i in 0..<lhs.size {
        let p = rhs.getPoint(i)
        let w = rhs.getBitWidth(i)
        var matched = false
        for j in 0..<rhs.size {
          let q = lhs.getPoint(j)
          let x = lhs.getBitWidth(j)
          if p == q && w == x {
            matched = true
            break
          }
        }
        if !matched { return false }
      }
      return true
    }

    /// `void add(Location p, BitWidth w)` (`WidthIncompatibilityData.java:25-31`): a linear
    /// scan, so the pair order is insertion order and duplicates are dropped.
    public func add(_ point: Location, _ width: BitWidth) {
      for i in 0..<points.count where points[i] == point && widths[i] == width {
        return
      }
      points.append(point)
      widths.append(width)
    }

    public func getBitWidth(_ i: Int) -> BitWidth { widths[i] }
    public func getPoint(_ i: Int) -> Location { points[i] }
    public var size: Int { points.count }

    /// `BitWidth getCommonBitWidth()` (`WidthIncompatibilityData.java:64-79`): the width that
    /// occurs most often, or `nil` if there is a tie.
    ///
    /// The 65-entry histogram is Java's; a `BitWidth` cannot exceed 64. Preserved verbatim
    /// including the tie rule: reaching `maxcount` a second time clears the answer, and a *later*
    /// width that then exceeds it wins. That makes the result depend on insertion order, which is
    /// why `WireBundle.setWidth`'s two `add` calls are ordered as they are.
    public func getCommonBitWidth() -> BitWidth? {
      var histogram = [Int](repeating: 0, count: 65)
      var maxWidth: BitWidth?
      var maxCount = 0
      for bw in widths {
        let w = bw.width
        guard w >= 0 && w < histogram.count else { continue }
        histogram[w] += 1
        let n = histogram[w]
        if n > maxCount {
          maxCount = n
          maxWidth = bw
        } else if n == maxCount {
          maxWidth = nil
        }
      }
      return maxWidth
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - SplitterData
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `CircuitWires.SplitterData` (`CircuitWires.java:146-152`): the bundle sitting at each end
  /// of a splitter, indexed by end number, with end 0 being the combined side.
  ///
  /// **D3; strong.** A `Splitter` owns its `SplitterData`, which owns bundles; no bundle points
  /// back at a splitter, so nothing cycles. Note this edge is *why* `WireThread.bundle` is weak:
  /// a stale `endBundle` entry (upstream never clears one; see `CircuitWires.java:628`) keeps a
  /// previous generation's bundle alive after the map that owned it is gone.
  public final class SplitterData {
    /// `SplitterData.endBundle`, length `fanOut + 1`.
    public var endBundle: [WireBundle?]

    public init(fanOut: Int) {
      endBundle = [WireBundle?](repeating: nil, count: max(fanOut, 0) + 1)
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - Unowned bus reference
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// A non-owning reference to a `ValuedBus`.
  ///
  /// **D3.** `ValuedThread.bus` and `ValuedBus.dependentBuses` are two independent cycle sources:
  /// bus → thread → bus, and bus → bus for any pair of buses joined by a splitter. `State.buses`
  /// is the single owner of every `ValuedBus` and they are all created and destroyed together, so
  /// `unowned` is both safe and free, and this *is* the hot path, unlike the union-find, so the
  /// weak-reference side table is worth avoiding here.
  struct UnownedBus {
    unowned let bus: ValuedBus
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - ValuedThread
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `CircuitWires.ValuedThread` (`CircuitWires.java:158-217`); a `WireThread` plus the 1-bit
  /// value it is currently carrying.
  final class ValuedThread {
    /// Length of the thread (number of buses it traverses).
    let steps: Int

    /// Buses traversed by this thread. Unowned, see `UnownedBus`.
    let bus: [UnownedBus]

    /// Position of this thread within each of those buses.
    let position: [Int]

    /// Whether this thread is pulled up, down, to error, or not at all.
    private(set) var pullUp = false
    private(set) var pullDown = false
    private(set) var pullError = false

    /// Cached resolved value; `nil` when dirty.
    var threadVal: Value?

    /// `ValuedThread(WireThread t, HashMap<WireBundle, ValuedBus> allBuses)`
    /// (`CircuitWires.java:177-193`).
    init(_ thread: WireThread, _ allBuses: [ObjectIdentifier: ValuedBus]) throws {
      steps = thread.steps
      position = thread.position
      var buses: [UnownedBus] = []
      buses.reserveCapacity(steps)
      var up = false
      var down = false
      var err = false
      for i in 0..<steps {
        guard let bundle = thread.bundle(at: i) else {
          throw CircuitWiresError.staleConnectivity("thread step \(i) has no bundle")
        }
        guard let vb = allBuses[ObjectIdentifier(bundle)] else {
          throw CircuitWiresError.staleConnectivity("no bus for bundle at thread step \(i)")
        }
        buses.append(UnownedBus(bus: vb))
        let pullHere = bundle.getPullValue()
        up = up || (pullHere == .trueValue)
        down = down || (pullHere == .falseValue)
        err = err || (pullHere == .errorValue)
      }
      bus = buses
      if up && down {
        up = false
        down = false
        err = true
      }
      pullUp = up
      pullDown = down
      pullError = err
    }

    /// `Value threadValue()` (`CircuitWires.java:195-216`).
    ///
    /// The `!= Value.NIL` test is Java's reference comparison against the `NIL` singleton; the
    /// port's `Value` is a struct and `NIL` is the unique width-0 value, so `!= .nilValue` is the
    /// same predicate. `combine` is the one whose `(TRUE, UNKNOWN) -> ERROR` result must not be
    /// "fixed".
    func threadValue() -> Value {
      if let cached = threadVal { return cached }
      var result = Value.unknownValue
      for i in 0..<steps {
        let vb = bus[i].bus
        let pos = position[i]
        if let v = vb.localDrivenValue, v != .nilValue {
          result = result.combine(v.get(pos))
        }
      }
      if result == .unknownValue {
        if pullUp {
          result = .trueValue
        } else if pullDown {
          result = .falseValue
        } else if pullError {
          result = .errorValue
        }
      }
      threadVal = result
      return result
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - BusConnection
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `CircuitWires.BusConnection` (`CircuitWires.java:226-253`): a point at which a component
  /// connects to a `ValuedBus`.
  public final class BusConnection {
    /// **D3; strong.** `Circuit` owns components and nothing in a component points back into a
    /// `State`, so this closes no cycle. Strong rather than weak on purpose: a `State` that
    /// outlives a removed component must still compare equal against the driving component when
    /// the pending event for it is drained, and a nil-ed weak reference would silently drop the
    /// update: a simulation divergence, which is worse than briefly over-retaining a component
    /// that the next `voidConnectivity()` releases anyway.
    public let component: any WireComponent
    public let location: Location
    public let isSink: Bool
    public let isBidirectional: Bool

    /// Value this component is driving onto the bus (`nil` for sinks).
    public var drivenValue: Value?

    /// `BusConnection(Component comp, Location loc)` (`CircuitWires.java:235-245`).
    ///
    /// Throws where Java would raise `NullPointerException` on `comp.getEnd(loc)` returning null
    /// (D13).
    init(_ component: any WireComponent, _ location: Location) throws {
      self.component = component
      self.location = location
      guard let end = component.wireEnd(at: location) else {
        throw CircuitWiresError.noEndAtLocation(location)
      }
      // Special case: Pin is treated as a sink, because it needs notifications of any change to
      // its inputs in order to set the UI colour properly.
      isSink = (end.type == .inputOnly) || component.wireIsPinFactory
      isBidirectional = (end.type == .inputOutput)
      drivenValue = nil
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - ValuedBus
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `CircuitWires.ValuedBus` (`CircuitWires.java:264-377`); a `WireBundle` plus the n-bit value
  /// it is currently carrying.
  ///
  /// Degenerate case: a bus not joined to any other bus (i.e. not reached through a splitter) can
  /// have all its bits computed in one pass instead of thread by thread. It is detected by an
  /// empty `dependentBuses`.
  final class ValuedBus {
    /// `State.buses[idx]` holds this bus.
    var idx: Int

    /// Negative for an invalid width.
    let width: Int

    /// Threads passing through this bus. `nil` when degenerate or when the width is invalid.
    var threads: [ValuedThread]?

    /// Sink and source components connected to this bus.
    var connections: [BusConnection]

    /// The locations of those connections.
    var locations: [Location]

    /// Sum of `connections[i].drivenValue`.
    var localDrivenValue: Value?

    /// Cached resolved value carried by this bus.
    var busVal: Value?

    /// Whether `localDrivenValue` and `busVal` are valid.
    var dirty: Bool

    /// Other buses affected when this one's `localDrivenValue` changes. Unowned, see
    /// `UnownedBus`.
    var dependentBuses: [UnownedBus] = []

    /// Only used when `dependentBuses` is empty.
    let pullVal: Value?

    /// `ValuedBus(int i, WireBundle wb, Connectivity cmap)` (`CircuitWires.java:295-301`).
    init(_ index: Int, _ bundle: WireBundle, _ cmap: Connectivity) throws {
      idx = index
      // filterComponents initialises locations[] and connections[]
      let xpoints = bundle.xpoints ?? []
      var locs: [Location] = []
      var conns: [BusConnection] = []
      for point in xpoints {
        guard let allComponents = cmap.componentsAtLocations[point] else { continue }
        locs.append(point)
        for comp in allComponents {
          conns.append(try BusConnection(comp, point))
        }
      }
      locations = locs.count == xpoints.count ? xpoints : locs
      connections = conns
      width = bundle.threads == nil ? -1 : bundle.getWidth().width
      pullVal = bundle.getPullValue()
      dirty = true
    }

    /// `void makeThreads(...)` (`CircuitWires.java:319-339`).
    func makeThreads(
      _ wbthreads: [WireThread]?,
      _ allBuses: [ObjectIdentifier: ValuedBus],
      _ allThreads: inout [ObjectIdentifier: ValuedThread]
    ) throws {
      if width <= 0 { return }
      guard let wbthreads else {
        throw CircuitWiresError.staleConnectivity("bus of width \(width) has no wire threads")
      }
      var degenerate = true
      for t in wbthreads where t.steps > 1 {
        degenerate = false
        break
      }
      if degenerate { return }
      var made: [ValuedThread] = []
      made.reserveCapacity(width)
      for i in 0..<width {
        guard i < wbthreads.count else {
          throw CircuitWiresError.staleConnectivity("bundle has \(wbthreads.count) threads, need \(width)")
        }
        let t = wbthreads[i]
        let key = ObjectIdentifier(t)
        if let existing = allThreads[key] {
          made.append(existing)
        } else {
          let created = try ValuedThread(t, allBuses)
          allThreads[key] = created
          made.append(created)
        }
      }
      threads = made
    }

    /// `Value recalculate()` (`CircuitWires.java:341-376`).
    ///
    /// ┌──────────────────────────────────────────────────────────────────────────────────────┐
    /// │ D15 / tracker task #14; KEEP ALL THREE EARLY RETURNS, in Java's order. Two of them   │
    /// │ are load-bearing here; the third is load-bearing upstream. Every claim below is        │
    /// │ mutation-tested by `LogisimKernelTests/NarrowWidthBusTests.swift`, one guard at a time.│
    /// │                                                                                        │
    /// │ GUARDS 1 and 2 are load-bearing in THIS port. An invalid-width bus and a degenerate    │
    /// │ bus both have `threads == nil` (`makeThreads` returns before allocating), so without   │
    /// │ their early return they reach the fold and throw `staleConnectivity`: a value         │
    /// │ upstream computes turning into a simulation error. Disable either: 2 tests go red.     │
    /// │                                                                                        │
    /// │ GUARD 3 (`width == 1`) is VALUE-NEUTRAL here, and both published rationales for it     │
    /// │ are wrong about this port. Disable it: all 9 tests stay green, and so does the corpus  │
    /// │ simulation gate.                                                                       │
    /// │   · JAVA's reason (D15 original) does not transfer: upstream's narrow-width operators  │
    /// │     compare by *reference* against interned singletons, which a `create_unsafe` value  │
    /// │     never is. `Value` here is a STRUCT with memberwise `==`, so the fold's             │
    /// │     `createUnsafe(width: 1, …)` is indistinguishable from the canonical singleton; │
    /// │     asserted plane by plane, plus hash and rendering.                                  │
    /// │   · D15's 2026-09-05 correction is also wrong: it says the fold's `else` branch turns  │
    /// │     a NIL thread value into ERROR and that guard 3 preserves it. `threadValue()`       │
    /// │     CANNOT return NIL. It seeds `.unknownValue` and only ever `combine`s that with     │
    /// │     `Value.get(_:)`, which is total, out-of-range indices yield `.errorValue`, never  │
    /// │     NIL (`Value.swift:865-872` = `Value.java:456-463`), and `combine` over width-1    │
    /// │     operands is closed over {TRUE, FALSE, UNKNOWN, ERROR}. So the `else` branch is     │
    /// │     unreachable at width 1.                                                            │
    /// │                                                                                        │
    /// │ It stays anyway: the port's job is to be 4.1.0, where the guard IS the thing keeping   │
    /// │ an uninterned width-1 value out of every downstream identity comparison. Deleting it   │
    /// │ would be a silent divergence from the reference for no gain. What must not happen      │
    /// │ again is the guard being defended with a mechanism that does not exist; that is how   │
    /// │ a reviewer who checks the claim, finds it false, and deletes the code ends up right    │
    /// │ about the argument and wrong about the outcome.                                        │
    /// └──────────────────────────────────────────────────────────────────────────────────────┘
    func recalculate() throws -> Value {
      if width <= 0 {
        // ── guard 1 of 3 (D15): LOAD-BEARING HERE. `threads` is nil for an invalid width, so
        //    the fold below would throw instead of returning NIL. ──
        busVal = .nilValue
        dirty = false
        return .nilValue
      } else if dependentBuses.isEmpty {
        // ── guard 2 of 3 (D15): LOAD-BEARING HERE. Degenerate case; `makeThreads` returned
        //    before allocating any, so `threads` is nil and the fold below would throw. ──
        guard var result = localDrivenValue else {
          throw CircuitWiresError.staleConnectivity("degenerate bus has no local driven value")
        }
        // Java tests `pullVal != null`, but `WireBundle.getPullValue()` never returns null, it
        // starts at UNKNOWN, so the branch always runs and `pullEachBitTowards(UNKNOWN)` is the
        // identity. Preserved as written rather than folded away.
        if let pullVal {
          result = try result.pullEachBitTowards(pullVal)
        }
        busVal = result
        dirty = false
        return result
      } else if width == 1 {
        // ── guard 3 of 3 (D15): the one D15 names. Value-neutral in THIS port (the fold gives
        //    the identical width-1 value); kept because upstream needs it and the port is 4.1.0.
        //    See the box above before deleting it; the reasons on record for it are wrong, and
        //    the conclusion is still to keep it. ──
        guard let threads, !threads.isEmpty else {
          throw CircuitWiresError.staleConnectivity("width-1 bus has no threads")
        }
        let result = threads[0].threadValue()
        busVal = result
        dirty = false
        return result
      }
      guard let threads else {
        throw CircuitWiresError.staleConnectivity("bus of width \(width) has no threads")
      }
      var error: Int64 = 0
      var unknown: Int64 = 0
      var value: Int64 = 0
      for i in 0..<width {
        guard i < threads.count else {
          throw CircuitWiresError.staleConnectivity("bus of width \(width) has \(threads.count) threads")
        }
        // Java: `long mask = 1L << i`. `1L << 63` is negative in Java too; the unsigned shift
        // then bit-pattern conversion reproduces that exactly without trapping.
        let mask = Int64(bitPattern: UInt64(1) &<< UInt64(i & 63))
        let tv = threads[i].threadValue()
        if tv == .trueValue {
          value |= mask
        } else if tv == .falseValue {
          // nothing, Java's empty `;` branch
        } else if tv == .unknownValue {
          unknown |= mask
        } else {
          error |= mask
        }
      }
      // Reached only at width >= 2, by the three guards above. createUnsafe validates nothing,
      // and nothing is added here (D15).
      let result = Value.createUnsafe(width: width, error: error, unknown: unknown, value: value)
      busVal = result
      dirty = false
      return result
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - State
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `CircuitWires.State` (`CircuitWires.java:383-501`); the per-`CircuitState` mutable half.
  ///
  /// `buses` is partitioned in place: indices `0 ..< numDirty` are the dirty buses. `markDirty`
  /// and `markClean` swap across the boundary, which is why every bus knows its own `idx`.
  public final class State {
    /// Original source of connectivity info. **D3; strong**: one `Connectivity` backs many
    /// `State`s and holds no reference to any of them.
    let connectivity: Connectivity

    var busAt: [Location: ValuedBus] = [:]
    var buses: [ValuedBus]
    var numDirty: Int

    /// `State(Connectivity cm, State prev)` (`CircuitWires.java:392-448`).
    init(_ cmap: Connectivity, _ prev: State?) throws {
      connectivity = cmap
      var allBuses: [ObjectIdentifier: ValuedBus] = [:]
      var srcBuses: [ObjectIdentifier: WireBundle] = [:]

      // initialize buses[] and busAt<>
      var made: [ValuedBus] = []
      made.reserveCapacity(cmap.bundleCount)
      var idx = 0
      for wb in cmap.getBundles() {
        let vb = try ValuedBus(idx, wb, cmap)
        idx += 1
        made.append(vb)
        for loc in wb.xpoints ?? [] {
          if busAt.updateValue(vb, forKey: loc) != nil {
            throw CircuitWiresError.twoWiresAtSameLocation(loc)
          }
        }
        allBuses[ObjectIdentifier(wb)] = vb
        srcBuses[ObjectIdentifier(vb)] = wb
      }
      buses = made

      // create threads for all buses that need them
      var allThreads: [ObjectIdentifier: ValuedThread] = [:]
      for vb in buses {
        let wb = srcBuses[ObjectIdentifier(vb)]
        try vb.makeThreads(wb?.threads, allBuses, &allThreads)
      }

      // initialize BusConnection driven values from the previous State, if any, but only if they
      // are not sinks (or pins, which always count as sinks)
      if let prev {
        for vb in buses {
          for bc in vb.connections where !bc.isSink {
            bc.drivenValue = prev.getDrivenValue(bc.component, bc.location)
          }
        }
      }

      // compute bus dependencies
      for vb in buses {
        if vb.width <= 0 { continue }
        guard let threads = vb.threads else {
          // degenerate
          vb.dependentBuses = []
          continue
        }
        // Java collects into a HashSet and converts to an array, so the order is JVM hash order.
        // This keeps first-seen order, deduplicated by identity: deterministic, and the only
        // thing the order reaches is which dependent bus is marked dirty first, which the dirty
        // partition then reorders anyway.
        var seen: Set<ObjectIdentifier> = []
        var deps: [UnownedBus] = []
        for t in threads {
          for dep in t.bus where dep.bus !== vb {
            if seen.insert(ObjectIdentifier(dep.bus)).inserted {
              deps.append(dep)
            }
          }
        }
        vb.dependentBuses = deps
      }

      // mark all dirty: recomputes values and triggers component propagation
      numDirty = buses.count
    }

    /// `Value getDrivenValue(Component c, Location loc)` (`CircuitWires.java:450-459`).
    ///
    /// D4: `bc.component.equals(c)` is reference identity for every `Component` subclass, so this
    /// is `===`.
    func getDrivenValue(_ component: any WireComponent, _ loc: Location) -> Value? {
      guard let vb = busAt[loc] else { return nil }
      for bc in vb.connections where bc.component === component && bc.location == loc {
        return bc.drivenValue
      }
      return nil
    }

    /// `void markClean(ValuedBus vb)` (`CircuitWires.java:461-477`). Messages verbatim (D13).
    func markClean(_ vb: ValuedBus) throws {
      if !vb.dirty {
        throw CircuitWiresError.dirtyBookkeeping("can't clean element that is not dirty")
      }
      if vb.idx > numDirty - 1 {
        throw CircuitWiresError.dirtyBookkeeping("bad position for dirty element")
      }
      if vb.idx < numDirty - 1 {  // swap toward the end of the dirty section of the array
        let other = buses[numDirty - 1]
        other.idx = vb.idx
        buses[other.idx] = other
        vb.idx = numDirty - 1
        buses[vb.idx] = vb
      }
      vb.dirty = false
      numDirty -= 1
    }

    /// `void markDirty(ValuedBus vb)` (`CircuitWires.java:479-500`).
    func markDirty(_ vb: ValuedBus) throws {
      if vb.dirty { return }
      if vb.idx < numDirty {
        throw CircuitWiresError.dirtyBookkeeping("bad position for clean element")
      }
      vb.localDrivenValue = nil  // needs recomputing from connections[i].drivenValue
      vb.busVal = nil  // needs recomputing from threads[i].threadValue
      if vb.idx > numDirty {  // swap toward the dirty section of the array
        let other = buses[numDirty]
        other.idx = vb.idx
        buses[other.idx] = other
        vb.idx = numDirty
        buses[vb.idx] = vb
      }
      if let threads = vb.threads {  // invalidate threads
        for vt in threads {
          vt.threadVal = nil
        }
      }
      vb.dirty = true
      numDirty += 1
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - PointStore (CircuitPoints)
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `com.cburch.logisim.circuit.CircuitPoints`.
  ///
  /// Nested for the same reason as `WidthIncompatibilityData`: `CircuitPoints.swift` is not in
  /// this slice's file list, and nesting removes any chance of colliding with a parallel port of
  /// it. `CircuitWires` holds exactly one (`final CircuitPoints points`, `CircuitWires.java:512`)
  /// and it is reachable as `wires.pointStore`, so `Circuit`'s uses of it, `getExclusive`,
  /// `hasConflict`, `getNonWires`, `getSplitCauses`, are all available. Reported as a seam.
  public final class PointStore {

    private final class LocationData {
      var width: BitWidth = .unknown
      var components: [any WireComponent] = []
      /// Parallel to `components`; `nil` for wires, as upstream.
      var ends: [WireEndInfo?] = []
    }

    private var map: [Location: LocationData] = [:]
    /// Insertion order of `map`'s keys. Java iterates `map.keySet()` in `getAllLocations()`,
    /// which becomes `Connectivity.allLocations` and hence the order components are collected in.
    private var order: [Location] = []
    private var incompatibilityData: [Location: WidthIncompatibilityData] = [:]
    private var incompatibilityOrder: [Location] = []

    private let topologyLock: NSRecursiveLock

    init(lock: NSRecursiveLock = NSRecursiveLock()) { topologyLock = lock }

    // MARK: update

    /// `void add(Component comp)` (`CircuitPoints.java:41-52`).
    func add(_ comp: any WireComponent) {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      if let wire = comp as? any WireSegmentComponent, comp.wireRole == .wire {
        addSub(wire.wireEnd0, comp, nil)
        addSub(wire.wireEnd1, comp, nil)
      } else {
        for end in comp.wireEnds {
          addSub(end.location, comp, end)
        }
      }
    }

    /// `void add(Component comp, EndData endData)` (`CircuitPoints.java:54-56`).
    func add(_ comp: any WireComponent, _ end: WireEndInfo?) {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      if let end { addSub(end.location, comp, end) }
    }

    private func addSub(_ loc: Location, _ comp: any WireComponent, _ end: WireEndInfo?) {
      let locData: LocationData
      if let existing = map[loc] {
        locData = existing
      } else {
        locData = LocationData()
        map[loc] = locData
        order.append(loc)
      }
      locData.components.append(comp)
      locData.ends.append(end)
      computeIncompatibilityData(loc, locData)
    }

    /// `void computeIncompatibilityData(Location, LocationData)` (`CircuitPoints.java:69-95`).
    ///
    /// Note the Java compares `width != endWidth` on `BitWidth` *references*; `BitWidth.create`
    /// interns, so that is value equality in practice and the struct port matches.
    private func computeIncompatibilityData(_ loc: Location, _ locData: LocationData?) {
      var error: WidthIncompatibilityData?
      if let locData {
        var width = BitWidth.unknown
        for case let end? in locData.ends {
          let endWidth = end.width
          if width == .unknown {
            width = endWidth
          } else if width != endWidth && endWidth != .unknown {
            if error == nil {
              error = WidthIncompatibilityData()
              error!.add(loc, width)
            }
            error!.add(loc, endWidth)
          }
        }
        locData.width = width
      }

      if let error {
        if incompatibilityData.updateValue(error, forKey: loc) == nil {
          incompatibilityOrder.append(loc)
        }
      } else {
        if incompatibilityData.removeValue(forKey: loc) != nil {
          incompatibilityOrder.removeAll { $0 == loc }
        }
      }
    }

    /// `void remove(Component comp)` (`CircuitPoints.java:192-203`).
    func remove(_ comp: any WireComponent) {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      if let wire = comp as? any WireSegmentComponent, comp.wireRole == .wire {
        removeSub(wire.wireEnd0, comp)
        removeSub(wire.wireEnd1, comp)
      } else {
        for end in comp.wireEnds {
          removeSub(end.location, comp)
        }
      }
    }

    /// `void remove(Component comp, EndData endData)` (`CircuitPoints.java:205-207`).
    func remove(_ comp: any WireComponent, _ end: WireEndInfo?) {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      if let end { removeSub(end.location, comp) }
    }

    private func removeSub(_ loc: Location, _ comp: any WireComponent) {
      guard let locData = map[loc] else { return }
      // `locData.components.indexOf(comp)` (`CircuitPoints.java:213`): Java's `equals`, which is
      // structural for `Wire` and identity for everything else. See `javaComponentEquals`.
      guard let index = locData.components.firstIndex(where: { javaComponentEquals($0, comp) })
      else { return }

      if locData.components.count == 1 {
        map.removeValue(forKey: loc)
        order.removeAll { $0 == loc }
        if incompatibilityData.removeValue(forKey: loc) != nil {
          incompatibilityOrder.removeAll { $0 == loc }
        }
      } else {
        locData.components.remove(at: index)
        locData.ends.remove(at: index)
        computeIncompatibilityData(loc, locData)
      }
    }

    // MARK: query

    /// `Collection<? extends Component> find(Location, boolean isWire)`
    /// (`CircuitPoints.java:97-126`). The Java's three fast paths are pure allocation avoidance
    /// and are folded into one filter here; the *contents and order* are identical.
    private func find(_ loc: Location, isWire: Bool) -> [any WireComponent] {
      guard let locData = map[loc] else { return [] }
      return locData.components.filter { ($0.wireRole == .wire) == isWire }
    }

    /// `int getComponentCount(Location loc)` (`CircuitPoints.java:128-131`).
    public func getComponentCount(_ loc: Location) -> Int {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return map[loc]?.components.count ?? 0
    }

    /// `Collection<? extends Component> getComponents(Location loc)` (`CircuitPoints.java:133`).
    public func getComponents(_ loc: Location) -> [any WireComponent] {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return map[loc]?.components ?? []
    }

    /// `Component getExclusive(Location loc)` (`CircuitPoints.java:139-150`).
    public func getExclusive(_ loc: Location) -> (any WireComponent)? {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      guard let locData = map[loc] else { return nil }
      var i = -1
      for end in locData.ends {
        i += 1
        if let end, end.isExclusive {
          return locData.components[i]
        }
      }
      return nil
    }

    /// `Collection<? extends Component> getNonWires(Location loc)` (`CircuitPoints.java:152`).
    public func getNonWires(_ loc: Location) -> [any WireComponent] {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return find(loc, isWire: false)
    }

    /// `Collection<? extends Component> getSplitCauses(Location loc)` (`CircuitPoints.java:156`).
    public func getSplitCauses(_ loc: Location) -> [any WireComponent] {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return getComponents(loc)
    }

    /// `Set<Location> getAllLocations()` (`CircuitPoints.java:160-162`), in insertion order.
    public func getAllLocations() -> [Location] {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return order
    }

    /// `BitWidth getWidth(Location loc)` (`CircuitPoints.java:164-167`).
    public func getWidth(_ loc: Location) -> BitWidth {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return map[loc]?.width ?? .unknown
    }

    /// `Collection<WidthIncompatibilityData> getWidthIncompatibilityData()`
    /// (`CircuitPoints.java:169-171`).
    public func getWidthIncompatibilityData() -> [WidthIncompatibilityData] {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return incompatibilityOrder.compactMap { incompatibilityData[$0] }
    }

    /// `Collection<Wire> getWires(Location loc)` (`CircuitPoints.java:173-177`).
    public func getWires(_ loc: Location) -> [any WireSegmentComponent] {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      return find(loc, isWire: true).compactMap { $0 as? any WireSegmentComponent }
    }

    /// `boolean hasConflict(Component comp)` (`CircuitPoints.java:179-190`).
    public func hasConflict(_ comp: any WireComponent) -> Bool {
      topologyLock.lock()
      defer { topologyLock.unlock() }
      if comp.wireRole != .wire {
        for end in comp.wireEnds where end.isExclusive {
          if getExclusive(end.location) != nil { return true }
        }
      }
      return false
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - Storage
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  // Elements of the circuit, organized by type (`CircuitWires.java:504-508`). Java uses
  // `HashSet`; `Wire` hashes structurally by endpoints, everything else by identity. Each is an
  // insertion-ordered array plus the matching index, which reproduces the membership rule and
  // additionally makes iteration deterministic.
  //
  // D3: all strong, matching Java. `Circuit` owns both these components and this object; nothing
  // points back.

  private struct WireKey: Hashable {
    let end0: Location
    let end1: Location
  }

  private var wireOrder: [any WireSegmentComponent] = []
  private var wireKeys: Set<WireKey> = []

  private var splitterOrder: [any WireSplitterComponent] = []
  private var splitterIdentities: Set<ObjectIdentifier> = []

  private var tunnelOrder: [any WireComponent] = []
  private var tunnelIdentities: Set<ObjectIdentifier> = []

  private var pullOrder: [any WireComponent] = []
  private var pullIdentities: Set<ObjectIdentifier> = []

  private var componentOrder: [any WireComponent] = []
  private var componentIdentities: Set<ObjectIdentifier> = []

  /// `final CircuitPoints points` (`CircuitWires.java:512`).
  public let pointStore: PointStore

  /// Serializes topology edits, point queries and connectivity construction.
  /// Order: topologyLock -> connectivityLock. Never held across a dispatcher hop.
  /// Recursive because PointStore exposes queries using the same lock as its owner.
  private let topologyLock = NSRecursiveLock()

  /// `private Bounds bounds = Bounds.EMPTY_BOUNDS` (`CircuitWires.java:513`).
  ///
  /// `nil` stands for Java's `EMPTY_BOUNDS`-as-"cache invalid" sentinel, which is a *reference*
  /// comparison Swift's value-typed `Bounds` cannot express. No behaviour rides on the
  /// difference: `recomputeBounds` adds 1 to both dimensions, so it can never produce a
  /// zero-sized box that would be mistaken for "invalid".
  private var boundsCache: Bounds?

  /// `private volatile Connectivity masterConnectivity` (`CircuitWires.java:515`).
  ///
  /// Java's `volatile` gives atomicity plus a happens-before edge between the editing thread that
  /// writes it and the simulation thread that reads it. Swift has no `volatile`; `NSLock` gives
  /// both. D1 forbids reaching for an actor.
  private let connectivityLock = NSLock()
  private var masterConnectivity: Connectivity?

  /// Replaces `SwingUtilities` (see the file header). Defaults to the headless dispatcher so the
  /// CLI and the differential harness work with no wiring. An owner-thread dispatcher may
  /// be installed before sharing the map; the current UI also uses the inline dispatcher.
  ///
  /// **D3; strong.** A dispatcher is either a stateless singleton or a UI-layer object that
  /// holds no reference back into the circuit.
  public var connectivityDispatcher: any WireConnectivityDispatcher = InlineConnectivityDispatcher()

  /// Replaces `logger.error(t.getLocalizedMessage())` (`CircuitWires.java:1019`, `:1029`).
  /// D9 keeps logging frameworks out of the kernel; the host installs a sink.
  public var onError: ((Error) -> Void)?

  /// The attribute names `TunnelListener` reacts to: `StdAttr.LABEL` (`"label"`,
  /// `StdAttr.java:43`) and `PullResistor.ATTR_PULL_TYPE` (`"pull"`,
  /// `PullResistor.java:55-56`).
  ///
  /// Compared by name rather than by `Attribute` identity because both constants live above this
  /// module (`LogisimStd`/`LogisimFile`); the names are part of the `.circ` format and are
  /// therefore stable.
  public static var tunnelSensitiveAttributeNames: Set<String> = ["label", "pull"]

  /// `CircuitWires.TunnelListener` (`CircuitWires.java:519-532`).
  private final class TunnelListener: AttributeListener {
    /// **D3; `unowned`.** `CircuitWires` holds the subscriptions, a subscription holds this
    /// listener strongly (D5), so a strong edge back would close a three-object cycle on every
    /// circuit containing a tunnel or a pull resistor.
    private unowned let owner: CircuitWires

    init(owner: CircuitWires) { self.owner = owner }

    func attributeListChanged(_ event: AttributeEvent) {
      // do nothing.
    }

    func attributeValueChanged(_ event: AttributeEvent) {
      guard let name = event.attribute?.name else { return }
      if CircuitWires.tunnelSensitiveAttributeNames.contains(name) {
        owner.voidConnectivity()
      }
    }
  }

  private var tunnelListener: TunnelListener!

  /// The `AttributeSubscription` tokens for the tunnel listener, keyed by component identity.
  ///
  /// **D3; this is the "explicit eviction owner" the decision demands.** D5's subscription model
  /// holds the token weakly from the set and the listener strongly from the token, so dropping a
  /// token unsubscribes. `remove(_:)` drops the matching token, which is the exact analogue of
  /// Java's `removeAttributeListener`.
  private var attributeSubscriptions: [ObjectIdentifier: AttributeSubscription] = [:]

  /// `CircuitWires()` (`CircuitWires.java:534`).
  public init() {
    pointStore = PointStore(lock: topologyLock)
    tunnelListener = TunnelListener(owner: self)
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - Mutation
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `boolean add(Component comp)` (`CircuitWires.java:538-561`).
  ///
  /// Upstream's own note: this could be made far more efficient in most cases by avoiding the
  /// wholesale voiding of the connectivity map. Preserved as-is.
  @discardableResult
  public func add(_ comp: any WireComponent) -> Bool {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    var added = true
    switch comp.wireRole {
    case .wire:
      if let wire = comp as? any WireSegmentComponent {
        added = addWire(wire)
      } else {
        added = false
      }
    case .splitter:
      if let splitter = comp as? any WireSplitterComponent {
        if splitterIdentities.insert(ObjectIdentifier(splitter)).inserted {
          splitterOrder.append(splitter)
        }
      }
    case .tunnel:
      if tunnelIdentities.insert(ObjectIdentifier(comp)).inserted {
        tunnelOrder.append(comp)
      }
      subscribeToAttributes(of: comp)
    case .pullResistor:
      if pullIdentities.insert(ObjectIdentifier(comp)).inserted {
        pullOrder.append(comp)
      }
      subscribeToAttributes(of: comp)
    case .plain:
      if componentIdentities.insert(ObjectIdentifier(comp)).inserted {
        componentOrder.append(comp)
      }
    }
    if added {
      pointStore.add(comp)
      voidConnectivity()
    }
    return added
  }

  /// `void add(Component comp, EndData end)` (`CircuitWires.java:563-566`).
  public func add(_ comp: any WireComponent, _ end: WireEndInfo?) {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    pointStore.add(comp, end)
    voidConnectivity()
  }

  /// `private boolean addWire(Wire w)` (`CircuitWires.java:568-576`).
  private func addWire(_ wire: any WireSegmentComponent) -> Bool {
    let key = WireKey(end0: wire.wireEnd0, end1: wire.wireEnd1)
    guard wireKeys.insert(key).inserted else { return false }
    wireOrder.append(wire)

    if let cached = boundsCache {  // update bounds
      boundsCache = cached.add(wire.wireEnd0).add(wire.wireEnd1)
    }
    return true
  }

  /// `void remove(Component comp)` (`CircuitWires.java:1190-1209`).
  public func remove(_ comp: any WireComponent) {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    switch comp.wireRole {
    case .wire:
      if let wire = comp as? any WireSegmentComponent { removeWire(wire) }
    case .splitter:
      if splitterIdentities.remove(ObjectIdentifier(comp)) != nil {
        splitterOrder.removeAll { $0 === comp }
      }
    case .tunnel:
      if tunnelIdentities.remove(ObjectIdentifier(comp)) != nil {
        tunnelOrder.removeAll { $0 === comp }
      }
      unsubscribeFromAttributes(of: comp)
    case .pullResistor:
      if pullIdentities.remove(ObjectIdentifier(comp)) != nil {
        pullOrder.removeAll { $0 === comp }
      }
      unsubscribeFromAttributes(of: comp)
    case .plain:
      if componentIdentities.remove(ObjectIdentifier(comp)) != nil {
        componentOrder.removeAll { $0 === comp }
      }
    }
    pointStore.remove(comp)
    voidConnectivity()
  }

  /// `void remove(Component comp, EndData end)` (`CircuitWires.java:1211-1214`).
  public func remove(_ comp: any WireComponent, _ end: WireEndInfo?) {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    pointStore.remove(comp, end)
    voidConnectivity()
  }

  /// `private void removeWire(Wire w)` (`CircuitWires.java:1216-1226`).
  ///
  /// The cache is invalidated only when an endpoint sat on the border: upstream shrinks the box
  /// by 2 and tests containment, so removing an interior wire leaves a box that is merely too
  /// large. Preserved; recomputing eagerly would change `Circuit.getBounds()` across a sequence
  /// of removals.
  private func removeWire(_ wire: any WireSegmentComponent) {
    let key = WireKey(end0: wire.wireEnd0, end1: wire.wireEnd1)
    guard wireKeys.remove(key) != nil else { return }
    // `wires.remove(w)` on a `HashSet<Wire>`: structural, so it drops the *stored* wire with
    // these endpoints even when the caller hands in a freshly-built equal object. Matching by
    // `===` here would leave `wireOrder` and `wireKeys` disagreeing (see `javaComponentEquals`).
    if let index = wireOrder.firstIndex(where: {
      $0.wireEnd0 == wire.wireEnd0 && $0.wireEnd1 == wire.wireEnd1
    }) {
      wireOrder.remove(at: index)
    }

    if let cached = boundsCache {
      let smaller = cached.expand(-2)
      if !smaller.contains(wire.wireEnd0) || !smaller.contains(wire.wireEnd1) {
        boundsCache = nil
      }
    }
  }

  /// `void replace(Component comp, EndData oldEnd, EndData newEnd)` (`CircuitWires.java:1228`).
  public func replace(_ comp: any WireComponent, _ oldEnd: WireEndInfo?, _ newEnd: WireEndInfo?) {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    pointStore.remove(comp, oldEnd)
    pointStore.add(comp, newEnd)
    voidConnectivity()
  }

  /// `private void voidConnectivity()` (`CircuitWires.java:1234-1239`).
  ///
  /// Upstream's comment: this should only be called by the AWT thread, though `main()` also calls
  /// it during startup; the simulation thread must not.
  ///
  /// **This is where the planned eager-connectivity fix goes**: recompute here instead of
  /// nulling, and `getConnectivity()` can never find `nil`, which deletes the only sim→UI
  /// blocking call in the simulator. Deliberately not done now (4.1.0 behaviour first).
  public func voidConnectivity() {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    connectivityLock.lock()
    masterConnectivity = nil
    connectivityLock.unlock()
  }

  private func subscribeToAttributes(of comp: any WireComponent) {
    guard let attrs = comp.wireAttributeSet else { return }
    let key = ObjectIdentifier(comp)
    guard attributeSubscriptions[key] == nil else { return }
    attributeSubscriptions[key] = attrs.addAttributeListener(tunnelListener)
  }

  private func unsubscribeFromAttributes(of comp: any WireComponent) {
    attributeSubscriptions.removeValue(forKey: ObjectIdentifier(comp))?.cancel()
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - Connectivity
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `private void computeConnectivity(Connectivity ret)` (`CircuitWires.java:579-740`).
  ///
  /// To be called by `getConnectivity()` only.
  ///
  /// **The bundle merging order is reproduced exactly.** `connectComponents` runs first, then
  /// `connectWires`, then `connectTunnels`, then `connectPullResistors`; each of them decides
  /// which of two bundles is united *into* which, and that decides which bundle survives the
  /// merge loop, which decides which `Location` is named first when a width conflict is reported.
  private func computeConnectivity(_ ret: Connectivity) throws {
    // create bundles corresponding to wires and tunnels
    connectComponents(ret)
    connectWires(ret)
    connectTunnels(ret)
    connectPullResistors(ret)

    // merge any WireBundle objects united by previous steps.
    //
    // D3: `getBundles()` hands back a strong snapshot, and it is held for the whole loop. That is
    // load-bearing; Java's iterator removal leaves not-yet-visited bundles pointing at removed
    // ones through their (weak) `parent`, and the GC keeps those alive. This snapshot does the
    // same job under ARC, so `WireBundle.find()`'s `?? self` fallback never fires here.
    for b in ret.getBundles() {
      let bpar = b.find()
      if bpar !== b {  // b isn't the group's representative
        let points = b.tempPoints
        for pt in points {
          ret.setBundleAt(pt, bpar)
        }
        bpar.addTempPoints(points)
        bpar.addPullValue(b.getPullValue())
        ret.removeBundle(b)
      }
    }

    // make a WireBundle object for each end of a splitter
    for spl in splitterOrder {
      let ends = spl.wireEnds
      for end in ends {
        let p = end.location
        let pb = ret.createBundleAt(p)
        pb.setWidth(end.width, p)
      }
    }

    // set the width for each bundle whose size is known, based on components
    for p in ret.getBundlePoints() {
      guard let pb = ret.getBundleAt(p) else { continue }
      let width = pointStore.getWidth(p)
      if width != .unknown {
        pb.setWidth(width, p)
      }
    }

    // determine the bundles at the end of each splitter
    for spl in splitterOrder {
      let ends = spl.wireEnds
      if spl.splitterWireData == nil {
        // Java's `Splitter.configureComponent` always creates this (`Splitter.java:123`); a seam
        // conformer that has not may still be configured lazily. `fanOut` is `ends.count - 1`,
        // matching `SplitterData(int fanOut)`'s `fanOut + 1` array.
        spl.splitterWireData = SplitterData(fanOut: max(ends.count - 1, 0))
      }
      var index = -1
      for end in ends {
        index += 1
        let p = end.location
        if let pb = ret.getBundleAt(p) {
          pb.setWidth(end.width, p)
          if let data = spl.splitterWireData, index < data.endBundle.count {
            data.endBundle[index] = pb
          }
        }
        // JAVA QUIRK, preserved: when there is no bundle at this end, the *previous* generation's
        // entry is left in place rather than cleared. That is what keeps stale bundles reachable
        // and is the reason `WireThread.bundle` is weak (D3).
      }
    }

    // finish constructing the bundles, start constructing the threads.
    //
    // `createdThreads` is a strong snapshot for the same reason as the bundle snapshot above:
    // the rewrite loop below overwrites `b.threads[i]` with the group representative, which drops
    // the last owning reference to every non-representative thread while other threads may still
    // reach them through their (weak) `representative`.
    var createdThreads: [WireThread] = []
    for b in ret.getBundles() {
      b.xpoints = b.tempPoints
      b.clearTempPoints()
      let width = b.getWidth()
      if width != .unknown {
        let n = width.width
        var threads: [WireThread] = []
        threads.reserveCapacity(n)
        for _ in 0..<n {
          let t = WireThread()
          threads.append(t)
          createdThreads.append(t)
        }
        b.threads = threads
      }
    }

    // unite threads going through splitters
    for spl in splitterOrder {
      spl.splitterLock.lock()
      defer { spl.splitterLock.unlock() }

      let bitEnd = spl.splitterBitEnd
      guard let splData = spl.splitterWireData else { continue }
      guard let fromBundle = splData.endBundle.first ?? nil, fromBundle.isValid() else { continue }

      let bitThread = spl.splitterBitThread
      for i in 0..<bitEnd.count {
        let j = bitEnd[i]
        if j > 0 {
          guard i < bitThread.count else {
            throw CircuitWiresError.splitterSourceBitOutOfRange(bit: i, count: bitThread.count)
          }
          let thr = bitThread[i]
          guard j < splData.endBundle.count, let toBundle = splData.endBundle[j] else { continue }
          if let toThreads = toBundle.threads, toBundle.isValid() {
            guard let fromThreads = fromBundle.threads else {
              throw CircuitWiresError.staleConnectivity("splitter source bundle has no threads")
            }
            if i >= fromThreads.count {
              throw CircuitWiresError.splitterSourceBitOutOfRange(bit: i, count: fromThreads.count)
            }
            if thr < 0 || thr >= toThreads.count {
              // Java indexes with a `byte` and lets `ArrayIndexOutOfBoundsException` fly for the
              // negative case too.
              throw CircuitWiresError.splitterThreadOutOfRange(thread: thr, count: toThreads.count)
            }
            fromThreads[i].unite(toThreads[thr])
          }
        }
      }
    }

    // merge any threads united by the previous step
    for wireBundle in ret.getBundles() {
      if var threads = wireBundle.threads {
        for i in 0..<threads.count {
          let thr = threads[i].getRepresentative()
          threads[i] = thr
          try thr.addBundlePosition(i, wireBundle)
        }
        wireBundle.threads = threads
      }
    }

    // finish constructing the threads
    for b in ret.getBundles() {
      if let threads = b.threads {
        for t in threads {
          t.finishConstructing()
        }
      }
    }

    // All bundles are made, all threads are now sewn together.

    // Record all interesting components so they can be marked dirty when this map is used to
    // initialise a new State.
    ret.allComponents.append(contentsOf: componentOrder)

    // Record all component locations for the same reason.
    ret.allLocations.append(contentsOf: pointStore.getAllLocations())

    // Record all interesting (non-wire, non-splitter) component locations so they can be used to
    // filter out uninteresting points, together with which components are at them.
    for p in ret.allLocations {
      var a: [any WireComponent]?
      for comp in pointStore.getComponents(p) {
        if comp.wireRole == .wire || comp.wireRole == .splitter { continue }
        if a == nil { a = [] }
        a?.append(comp)
      }
      if let a {
        ret.componentsAtLocations[p] = a
      }
    }

    // Compute the exception set before leaving.
    let exceptions = pointStore.getWidthIncompatibilityData()
    if !exceptions.isEmpty {
      for wid in exceptions {
        ret.addWidthIncompatibilityData(wid)
      }
    }
    for wireBundle in ret.getBundles() {
      if let e = wireBundle.getWidthIncompatibilityData() {
        ret.addWidthIncompatibilityData(e)
      }
    }

    // `createdThreads` is deliberately still in scope here; see its declaration.
    withExtendedLifetime(createdThreads) {}
  }

  /// `private void connectPullResistors(Connectivity ret)` (`CircuitWires.java:742-754`).
  private func connectPullResistors(_ ret: Connectivity) {
    for comp in pullOrder {
      guard let end0 = comp.wireEnds.first else { continue }
      let loc = end0.location
      var b = ret.getBundleAt(loc)
      if b == nil {
        let created = ret.createBundleAt(loc)
        created.addTempPoint(loc)
        ret.setBundleAt(loc, created)
        b = created
      }
      b?.addPullValue(comp.wirePullValue)
    }
  }

  /// `private void connectTunnels(Connectivity ret)` (`CircuitWires.java:756-795`).
  ///
  /// **Merge direction preserved**: within a tunnel set the *first* label-matching location that
  /// already has a bundle becomes `foundBundle`, and every other bundle is united *into* it
  /// (`bundle.unite(foundBundle)`), so `foundBundle`'s group wins.
  private func connectTunnels(_ ret: Connectivity) {
    // determine the sets of tunnels
    var tunnelSets: [String: [Location]] = [:]
    var tunnelSetOrder: [String] = []
    for comp in tunnelOrder {
      let label = javaTrim(comp.wireTunnelLabel)
      if label != "" {
        if tunnelSets[label] == nil {
          tunnelSets[label] = []
          tunnelSetOrder.append(label)
        }
        tunnelSets[label]?.append(comp.wireLocation)
      }
    }

    // now connect the bundles that are tunnelled together
    for label in tunnelSetOrder {
      guard let tunnelSet = tunnelSets[label], !tunnelSet.isEmpty else { continue }
      var foundBundle: WireBundle?
      var foundLocation: Location?
      for loc in tunnelSet {
        if let bundle = ret.getBundleAt(loc) {
          foundBundle = bundle
          foundLocation = loc
          break
        }
      }
      if foundBundle == nil {
        foundLocation = tunnelSet[0]
        foundBundle = ret.createBundleAt(tunnelSet[0])
      }
      guard let found = foundBundle else { continue }
      for loc in tunnelSet where loc != foundLocation {
        if let bundle = ret.getBundleAt(loc) {
          bundle.unite(found)
        } else {
          found.addTempPoint(loc)
          ret.setBundleAt(loc, found)
        }
      }
    }
  }

  /// `private void connectComponents(Connectivity ret)` (`CircuitWires.java:797-812`).
  private func connectComponents(_ ret: Connectivity) {
    // make a WireBundle object for each output or bidirectional port of a component
    for comp in componentOrder {
      for e in comp.wireEnds {
        if e.type == .inputOnly { continue }
        let loc = e.location
        if ret.getBundleAt(loc) == nil {
          let b = ret.createBundleAt(loc)
          b.addTempPoint(loc)
          ret.setBundleAt(loc, b)
        }
      }
    }
  }

  /// `private void connectWires(Connectivity ret)` (`CircuitWires.java:814-832`).
  ///
  /// **Merge direction preserved**: `bundleB.unite(bundleA)`, so end 1's group is attached under
  /// end 0's group and end 0's bundle survives.
  private func connectWires(_ ret: Connectivity) {
    // make a WireBundle object for each tree of connected wires
    for wire in wireOrder {
      let bundleA = ret.getBundleAt(wire.wireEnd0)
      if bundleA == nil {
        let bundleB = ret.createBundleAt(wire.wireEnd1)
        bundleB.addTempPoint(wire.wireEnd0)
        ret.setBundleAt(wire.wireEnd0, bundleB)
      } else {
        let bundleB = ret.getBundleAt(wire.wireEnd1)
        if bundleB == nil {  // e1 doesn't exist
          bundleA?.addTempPoint(wire.wireEnd1)
          ret.setBundleAt(wire.wireEnd1, bundleA!)
        } else {
          bundleB?.unite(bundleA!)  // unite bundles
        }
      }
    }
  }

  /// `private Connectivity getConnectivity()` (`CircuitWires.java:1008-1035`).
  ///
  /// Upstream's reasoning, preserved verbatim in structure: only two threads use the map: the
  /// AWT event thread and the simulation worker. AWT edits components and wires, voids the map,
  /// and eventually recomputes it during painting; AWT sometimes locks a splitter and *then*
  /// touches components. Building a map requires locking splitters **and** touching components,
  /// so to avoid deadlock only the owner thread may build one. The simulation thread never does;
  /// it blocks on the owner and copies what it gets into a per-instance `State`.
  ///
  /// Inline callers build under topologyLock. Owner-thread dispatch runs outside that lock.
  func getConnectivity() -> Connectivity {
    connectivityLock.lock()
    let map = masterConnectivity
    connectivityLock.unlock()
    if let map { return map }

    if connectivityDispatcher.isConnectivityOwnerThread {
      // A second reader may have built the map while we waited. Recheck under the
      // topology lock, and publish before releasing it so an edit cannot be lost.
      topologyLock.lock()
      connectivityLock.lock()
      let existing = masterConnectivity
      connectivityLock.unlock()
      if let existing {
        topologyLock.unlock()
        return existing
      }
      let ret = Connectivity()
      var failure: Error?
      do {
        try computeConnectivity(ret)
        connectivityLock.lock()
        masterConnectivity = ret
        connectivityLock.unlock()
      } catch {
        ret.invalidate()
        failure = error
      }
      topologyLock.unlock()
      if let failure { onError?(failure) }
      return ret
    } else {
      // Simulation thread. This is the blocking sim→UI call.
      var result: Connectivity?
      connectivityDispatcher.runOnConnectivityOwnerThread {
        result = self.getConnectivity()
      }
      if let result { return result }
      let ret = Connectivity()
      ret.invalidate()
      return ret
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - Queries
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `Iterator<? extends Component> getComponents()` (`CircuitWires.java:1037-1039`): splitters
  /// first, then wires, matching `IteratorUtil.createJoinedIterator`.
  public func getComponents() -> [any WireComponent] {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    var result: [any WireComponent] = []
    result.append(contentsOf: splitterOrder.map { $0 as any WireComponent })
    result.append(contentsOf: wireOrder.map { $0 as any WireComponent })
    return result
  }

  /// `BitWidth getWidth(Location q)` (`CircuitWires.java:1041-1051`).
  public func getWidth(_ q: Location) -> BitWidth {
    let det = pointStore.getWidth(q)
    if det != .unknown { return det }

    let cmap = getConnectivity()
    if !cmap.isValid() { return .unknown }
    if let qb = cmap.getBundleAt(q), qb.isValid() { return qb.getWidth() }

    return .unknown
  }

  /// `Set<WidthIncompatibilityData> getWidthIncompatibilityData()` (`CircuitWires.java:1053`).
  public func getWidthIncompatibilityData() -> [WidthIncompatibilityData]? {
    getConnectivity().getWidthIncompatibilityData()
  }

  /// `Bounds getWireBounds()` (`CircuitWires.java:1057-1063`).
  public func getWireBounds() -> Bounds {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    if let cached = boundsCache { return cached }
    return recomputeBounds()
  }

  /// `WireBundle getWireBundle(Location query)` (`CircuitWires.java:1065-1068`).
  func getWireBundle(_ query: Location) -> WireBundle? {
    getConnectivity().getBundleAt(query)
  }

  // MARK: - Thread-level connectivity, for `Analyze.propagateWires`

  /// What `Analyze.propagateWires` (`Analyze.java:341-370`) learns about one `(point, bit)`.
  ///
  /// Upstream reaches straight into `bundle.threads[bit]`, then walks `t.bundle[i].xpoints` for
  /// `i < t.steps`, pairing each point with `t.position[i]`. Everything on that path,
  /// `getWireBundle`, `WireBundle.threads`, `WireBundle.xpoints`, `WireThread.bundle(at:)`, is
  /// deliberately `internal` here, because `WireBundle` and `WireThread` are union-find nodes
  /// held on `weak` edges under D3 and handing them out would let a caller resurrect a stale
  /// connectivity generation. So the *walk* is done here and only its result crosses the module
  /// boundary: a list of `(location, bit)` pairs, which is all the analyze path ever wanted.
  ///
  /// The three cases are upstream's three branches, not an invention:
  ///   * `.notWired`: `bundle == null`, or invalid, or `threads == null`. Upstream's
  ///     `if (e != null && bundle != null && bundle.isValid() && bundle.threads != null)` simply
  ///     skips the point; nothing propagates and nothing is reported.
  ///   * `.incompatibleWidths`: `bundle.threads.length <= locationBit.bit`, which upstream
  ///     turns into `AnalyzeException.CannotHandle("incompatible widths")`. Reported rather than
  ///     thrown from here so that this file stays free of analyze-layer error types.
  ///   * `.points`; the pairs to write the expression onto. The query point itself is **not**
  ///     filtered out; upstream's `if (p2.equals(locationBit.loc)) continue;` lives in the
  ///     caller, where it belongs, and is reproduced there.
  public enum ThreadPoints {
    case notWired
    case incompatibleWidths
    case points([(location: Location, bit: Int)])
  }

  /// The `(location, bit)` pairs electrically identical to `(query, bit)`: i.e. everything on
  /// the same `WireThread`, which means the walk passes *through* splitters exactly as
  /// propagation does.
  public func threadPoints(at query: Location, bit: Int) -> ThreadPoints {
    let map = getConnectivity()
    defer { withExtendedLifetime(map) {} }
    guard let bundle = map.getBundleAt(query), bundle.isValid(), let threads = bundle.threads else {
      return .notWired
    }
    guard bit >= 0, threads.count > bit else { return .incompatibleWidths }
    let thread = threads[bit]
    var result: [(location: Location, bit: Int)] = []
    for step in 0..<thread.steps {
      guard let stepBundle = thread.bundle(at: step) else { continue }
      let position = thread.position[step]
      for point in stepBundle.xpoints ?? [] {
        result.append((location: point, bit: position))
      }
    }
    return .points(result)
  }

  /// `Set<Wire> getWires()` (`CircuitWires.java:1070-1072`).
  public func getWires() -> [any WireSegmentComponent] {
    topologyLock.lock()
    defer { topologyLock.unlock() }
    return wireOrder
  }

  /// `WireSet getWireSet(Wire start)` (`CircuitWires.java:1074-1082`).
  public func getWireSet(_ start: any WireSegmentComponent) -> WireSet {
    let map = getConnectivity()
    defer { withExtendedLifetime(map) {} }
    guard let wireBundle = map.getBundleAt(start.wireEnd0) else { return WireSet.empty }
    topologyLock.lock()
    defer { topologyLock.unlock() }
    var collected: [any WireSegmentComponent] = []
    // Java accumulates into a `HashSet<Wire>`, which deduplicates **structurally**; see
    // `javaComponentEquals`. Every wire is reached twice here (once per endpoint), so the dedup is
    // not optional, and keying it on identity instead of endpoints would let two equal-but-distinct
    // wire objects both survive where Java keeps one.
    var seen: Set<WireKey> = []
    for loc in wireBundle.xpoints ?? [] {
      for wire in pointStore.getWires(loc) {
        let key = WireKey(end0: wire.wireEnd0, end1: wire.wireEnd1)
        if seen.insert(key).inserted {
          collected.append(wire)
        }
      }
    }
    return WireSet(collected)
  }

  /// `private Bounds recomputeBounds()` (`CircuitWires.java:1163-1188`).
  @discardableResult
  private func recomputeBounds() -> Bounds {
    guard let first = wireOrder.first else {
      boundsCache = nil  // Java: `bounds = Bounds.EMPTY_BOUNDS`, i.e. still "invalid"
      return Bounds.empty
    }

    var xmin = first.wireEnd0.x
    var ymin = first.wireEnd0.y
    var xmax = first.wireEnd1.x
    var ymax = first.wireEnd1.y
    for w in wireOrder.dropFirst() {
      let x0 = w.wireEnd0.x
      if x0 < xmin { xmin = x0 }
      let x1 = w.wireEnd1.x
      if x1 > xmax { xmax = x1 }
      let y0 = w.wireEnd0.y
      if y0 < ymin { ymin = y0 }
      let y1 = w.wireEnd1.y
      if y1 > ymax { ymax = y1 }
    }
    let result = Bounds.create(xmin, ymin, xmax - xmin + 1, ymax - ymin + 1)
    boundsCache = result
    return result
  }

  /// `static Value getBusValue(CircuitState state, Location loc)` (`CircuitWires.java:834-848`).
  ///
  /// Upstream's three fallbacks all return `NIL` with the comment *"probably wrong, who cares"*.
  /// Preserved.
  public static func getBusValue(_ state: any WireCircuitState, _ loc: Location) -> Value {
    guard let s = state.wireData else { return .nilValue }
    guard let vb = s.busAt[loc] else { return .nilValue }
    guard let v = vb.busVal else { return .nilValue }
    return v
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: - Simulation
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// `State newState(CircuitState circState)` (`CircuitWires.java:379-381`); used when cloning a
  /// `CircuitState`.
  public func newState(_ circState: any WireCircuitState) throws -> State {
    try State(getConnectivity(), circState.wireData)
  }

  /// `void propagate(CircuitState circState, ArrayList<SimulatorEvent> dirtyPoints)`
  /// (`CircuitWires.java:1084-1161`).
  ///
  /// Throws by D13: every failure path below corresponds to a Java exception that `Simulator`'s
  /// `catch (Exception err) -> recordException(err)` already turns into a visible circuit error.
  ///
  /// Note `dirtyThreads` in the Java (`:1086`) is allocated and never used; it is not ported.
  public func propagate<E: WireDirtyPoint>(
    _ circState: any WireCircuitState,
    dirtyPoints: [E]
  ) throws {
    let map = getConnectivity()

    // get state, or create a new one if the current state is outdated
    var s = circState.wireData
    if s == nil || s!.connectivity !== map {
      // if it is outdated, we need to compute for all threads
      let fresh = try State(map, s)
      circState.wireData = fresh
      s = fresh
      // Note: all buses are already marked dirty. But some component ports that were previously
      // connected to buses might no longer be connected to those same buses (or to any bus), and
      // vice versa. So all components must be marked dirty too.
      circState.clearValuesByWire()
      circState.markComponentsDirty(map.allComponents)
    }
    guard let state = s else { return }

    // make note of updates from the simulator
    for ev in dirtyPoints {  // for each point of interest
      let p = ev.wireLoc
      let cause = ev.wireCause
      let val = ev.wireVal

      guard let vb = state.busAt[p] else {
        // todo (upstream): we could keep track of the affected components here
        continue
      }
      if vb.width <= 0 {
        // point is wired to a bus with an invalid width: ignore the new value and propagate NIL
        // across the entire bundle
        continue
      }
      // common case: it is wired to a normal bus. Update the stored value of this point on the
      // bus, mark the bus dirty, and (if not degenerate) mark any related buses dirty.
      // fixme (upstream): sort the connections list: sources first, then bidir, then sinks
      for bc in vb.connections {
        if bc.location == p && (bc.component as AnyObject) === cause {
          let old = bc.drivenValue
          if Value.equal(old, val) { continue }
          bc.drivenValue = val
          try state.markDirty(vb)
          for dep in vb.dependentBuses {
            try state.markDirty(dep.bus)
          }
          break
        }
      }
    }

    if state.numDirty <= 0 { return }

    // recompute localDrivenValue for each dirty bus
    for i in 0..<state.numDirty {
      let vb = state.buses[i]
      if vb.width <= 0 {
        // this bundle has inconsistent widths, or no width, hence no localDrivenValue
        vb.localDrivenValue = .nilValue
      } else {
        // SEAM/PERF: `Value.combineLikeWidths` takes `[Value?]`, so the driven values have to be
        // projected out of the connections. Java passes the `BusConnection[]` straight in and
        // reads `.drivenValue` inside the fold. `Value.swift` is owned elsewhere; an overload
        // there taking a projection closure would remove this per-dirty-bus allocation.
        vb.localDrivenValue = try Value.combineLikeWidths(
          width: vb.width,
          drivenValues: vb.connections.map(\.drivenValue))
      }
    }

    // recompute threadVal for all threads passing through dirty buses (if not degenerate),
    // recompute the aggregate busVal for all dirty buses, and post those results to the state
    for i in 0..<state.numDirty {
      let vb = state.buses[i]
      let old = vb.busVal
      let val = try vb.recalculate()
      if Value.equal(old, val) { continue }
      circState.setValueByWire(val, locations: vb.locations, connections: vb.connections)
    }
    state.numDirty = 0
  }
}
