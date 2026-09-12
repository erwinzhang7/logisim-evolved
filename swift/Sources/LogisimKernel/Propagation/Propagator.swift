//
//  Propagator.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port of `com.cburch.logisim.circuit.Propagator`; read from the **4.1.0** tree (D16),
//  `upstream-java-4.1.0/src/main/java/com/cburch/logisim/circuit/Propagator.java`. Line
//  citations below are 4.1.0 line numbers and will not match `main` (4.2.0-dev).
//
//  ---------------------------------------------------------------------------------------
//  This is the event-driven core: a delay queue of (time, serial) ordered value emissions, a
//  clock that jumps to the next event time rather than advancing, and an iteration cap that
//  declares oscillation when a circuit refuses to settle.
//
//  D1; no Swift Concurrency. `propagate()` is **synchronous** and stays synchronous. Thread
//  confinement is enforced the way the Java enforces it, with an explicit identity check
//  against a stored `Thread`, not with an actor. Making this `async` would infect all 108
//  `propagate(InstanceState)` implementations and destroy the reusable `InstanceStateImpl`
//  scratch object, which is only safe because propagation is synchronous and non-reentrant
//  (D2).
//
//  D9; no drawing. `drawOscillatingPoints(ComponentDrawContext)` (`Propagator.java:152`) does
//  not come across; `oscillatingPoints` exposes the data instead and the halo is drawn above
//  this module at M6.
//
//  D13; every Java `RuntimeException` on this path is a Swift `throw`. `Simulator.java:515`,
//  `:538` and `:554` wrap propagation in `catch (Exception err)`, so upstream turns a
//  misbehaving component into a circuit error the user sees. Trapping here would turn that into
//  a crash with unsaved work lost.
//
//  Standing rule 4: the oscillation heuristic (`simLimit`, `simRandomShift`, the
//  three-quarters log threshold, the noise injection) is preserved **verbatim**, including the
//  parts that look arbitrary. The differential gate holds the port to it.
//  ---------------------------------------------------------------------------------------
//

import Foundation
import Synchronization

/// `com.cburch.logisim.circuit.Propagator`.
public final class Propagator {

  // MARK: - Options listener

  /// `Propagator.Listener` (`Propagator.java:31-54`).
  ///
  /// **D3.** Java's listener holds a `WeakReference<Propagator>` precisely so that the
  /// long-lived `<options>` attribute set does not keep a closed circuit's propagator alive;
  /// that intent ports directly to `weak`. Ownership runs `Propagator → OptionsListener` and
  /// `OptionsListener ⇢ Propagator` (weak), so the pair is collectable no matter whether the
  /// options source retains the observer (as Java's `AttributeSet` does) or holds it weakly (as
  /// D5's `AttributeSubscription` design does).
  ///
  /// The `source` back-edge is weak for the same reason: it exists only to reproduce the
  /// self-eviction at `Propagator.java:47`.
  private final class OptionsListener: PropagatorOptionsObserver {
    weak var propagator: Propagator?
    weak var source: (any PropagatorOptionsSource)?

    init(propagator: Propagator) {
      self.propagator = propagator
    }

    /// `attributeValueChanged(AttributeEvent)`. `attributeListChanged` is a documented no-op
    /// upstream and has no equivalent requirement here.
    func simulationOptionChanged(_ option: PropagatorSimulationOption) {
      guard let propagator else {
        // `e.getSource().removeAttributeListener(this)`; the propagator is gone, so unhook.
        source?.removeSimulationOptionsObserver(self)
        return
      }
      switch option {
      case .randomness: propagator.updateRandomness()
      case .limit: propagator.updateSimLimit()
      }
    }
  }

  // MARK: - java.util.Random

  /// `java.util.Random`, ported exactly, for `noiseSource`.
  ///
  /// Why port the generator rather than call `Int.random(in:)`: the noise path is behaviour the
  /// gate can be pointed at. `new Random()` seeds from `nanoTime`, so the *sequence* is not
  /// reproducible across runs in either implementation: but with a fixed seed, an exact port
  /// of the 48-bit LCG lets a test drive Java and Swift down byte-identical noise sequences and
  /// compare truth tables with `simrand` switched on. A different generator makes that test
  /// impossible to write, and `simrand` then never gets covered at all.
  ///
  /// This is a nested type deliberately: it is an implementation detail of `Propagator` and
  /// must not become a general-purpose `JavaRandom` that other slices start depending on.
  final class NoiseSource {
    private static let multiplier: UInt64 = 0x5DEECE66D
    private static let addend: UInt64 = 0xB
    private static let mask: UInt64 = (1 << 48) - 1

    private var seed: UInt64

    /// `new Random()`; seeded unpredictably. Java uses `seedUniquifier() ^ nanoTime()`; the
    /// uniquifier sequence is not observable, so a system random draw is equivalent.
    convenience init() {
      self.init(seed: Int64(bitPattern: UInt64.random(in: UInt64.min...UInt64.max)))
    }

    /// `new Random(long seed)`: `this.seed = (seed ^ multiplier) & mask`
    /// (Java's `initialScramble`).
    init(seed: Int64) {
      self.seed = (UInt64(bitPattern: seed) ^ NoiseSource.multiplier) & NoiseSource.mask
    }

    /// `protected int next(int bits)`:
    /// `seed = (seed * multiplier + addend) & mask; return (int)(seed >>> (48 - bits));`
    private func next(_ bits: Int) -> Int {
      seed = (seed &* NoiseSource.multiplier &+ NoiseSource.addend) & NoiseSource.mask
      return Int(Int32(truncatingIfNeeded: Int64(bitPattern: seed >> UInt64(48 - bits))))
    }

    /// `public int nextInt(int bound)`:
    ///
    /// ```java
    /// if (bound <= 0) throw new IllegalArgumentException("bound must be positive");
    /// int r = next(31);
    /// int m = bound - 1;
    /// if ((bound & m) == 0)          // bound is a power of 2
    ///     r = (int)((bound * (long)r) >> 31);
    /// else
    ///     for (int u = r; u - (r = u % bound) + m < 0; u = next(31));
    /// return r;
    /// ```
    ///
    /// The only caller passes `1 << simRandomShift`, so the power-of-two branch is the one that
    /// runs in practice; the rejection loop is ported anyway because it is cheap to be complete
    /// and expensive to discover a gap later.
    ///
    /// `bound <= 0` returns 0 instead of throwing. Java's `IllegalArgumentException` is
    /// **unreachable** from here: `updateRandomness` clamps `simRandomShift` to `0...30` (see
    /// its note), so the bound is always in `2...2^30`. Returning 0 rather than throwing keeps
    /// `setValueWithPropThread` non-throwing, matching its Java signature.
    func nextInt(_ bound: Int) -> Int {
      guard bound > 0 else { return 0 }
      var r = next(31)
      let m = wrap32(bound - 1)
      if (bound & m) == 0 {
        // `(int)((bound * (long)r) >> 31)`; the multiply is done in 64 bits, then narrowed.
        let wide = Int64(bound) &* Int64(r)
        return Int(Int32(truncatingIfNeeded: wide >> 31))
      }
      var u = r
      while true {
        r = u % bound
        if wrap32(wrap32(u - r) + m) >= 0 { break }
        u = next(31)
      }
      return r
    }
  }

  // MARK: - Stored state

  /// *"Root of state tree"*: `private final CircuitState root` (`Propagator.java:91`).
  ///
  /// **D3: `weak`, and this is the broken side of the `CircuitState ⇄ Propagator` cycle.**
  /// The state owns the propagator; see the ownership note on `PropagatorCircuitState` for the
  /// full argument, which is that `CircuitState.createRootState` and `cloneAsNewRootState`
  /// return a state and nothing else, so the propagator has no other possible owner at those
  /// call sites.
  ///
  /// `weak` rather than `unowned`: a *detached* substate retains its old propagator (upstream
  /// nulls `parentState` on removal but never `base`), so the propagator can outlive the root
  /// ; an undo action holding a removed subcircuit's data is enough. `unowned` would then trap
  /// the next time the `<options>` listener fired; `weak` reads `nil` and every entry point
  /// below degrades to a no-op, which is what a torn-down circuit means and what D13 requires
  /// of a condition ordinary use can reach.
  ///
  /// Nothing in Java can observe the `nil` case: there, a detached tree is simply collected.
  public private(set) weak var root: (any PropagatorCircuitState)?

  /// *"The number of clock cycles to let pass before deciding that the circuit is
  /// oscillating."*: `private volatile int simLimit` (`Propagator.java:94`).
  ///
  /// Written by whichever thread edits `<options>` (the UI thread), read by the propagation
  /// thread. Swift has no `volatile`, and this is the whole reason `Synchronization.Atomic`
  /// appears in this file: it is the direct equivalent: a single-word access with defined
  /// cross-thread visibility and no lock. Using an `NSLock` instead would be correct but would
  /// put a lock acquisition on the per-event hot path for `simRandomShift` below.
  ///
  /// Every access here and on `simRandomShift`/`nonPropThreadEventsAvailable` is
  /// `.sequentiallyConsistent`, because that, not `.relaxed`, not acquire/release, is what a
  /// Java `volatile` read and write actually mean. On arm64 that is one `ldar`/`stlr`, off the
  /// per-event path for `simLimit` and once per `setValue` for `simRandomShift`.
  private let simLimit = Atomic<Int>(1000)

  /// *"On average, one out of every 2**simRandomShift propagations through a component is
  /// delayed one step more than the component requests. This noise is intended to address some
  /// circuits that would otherwise oscillate within Logisim (though they wouldn't oscillate in
  /// practice)."*; `private volatile int simRandomShift` (`Propagator.java:101`).
  ///
  /// Preserved verbatim per standing rule 4. Do not "improve" the randomisation.
  private let simRandomShift = Atomic<Int>(0)

  /// `private final QNodeQueue<SimulatorEvent> toProcess` (`Propagator.java:111`).
  ///
  /// 4.1.0 picks one of five implementations from `AppPreferences.SIMULATION_QUEUE`; the
  /// default lands on the `java.util.PriorityQueue`-backed one, which is what `PropagationHeap`
  /// reproduces and what the oracle jar runs. See PropagationHeap.swift for why the other four
  /// are not ported.
  private let toProcess: any PropagationEventQueue

  /// *"Allows Propagator to verify correct thread usage. It is usually the simulation thread
  /// but it can be another thread if the simulator is not being used (e.g. command line
  /// testing)"*; `private final Thread propagatorThread` (`Propagator.java:115`).
  ///
  /// D1: this is the port's equivalent of the 62 `Thread.currentThread() != propagatorThread`
  /// sites, and it is why the kernel opts out of Swift Concurrency rather than expressing
  /// confinement with an actor.
  private let propagatorThread: Thread

  /// *"Used to handle events generated by threads other than the propagation thread."*
  /// (`Propagator.java:118`).
  private var nonPropThreadEvents: [PropagationEvent] = []

  /// Java's `synchronized (nonPropThreadEvents)` monitor. D1: an `NSLock` behaves exactly like
  /// the Java monitor here: the critical sections never nest, so no reentrancy is needed.
  private let nonPropThreadEventsLock = NSLock()

  /// `private volatile boolean nonPropThreadEventsAvailable` (`Propagator.java:119`).
  ///
  /// The point of the flag is to let `moveNonPropThreadEvents` skip the monitor on the common
  /// path; it is consulted once per propagation iteration. Kept atomic rather than
  /// lock-guarded so that fast path survives.
  private let nonPropThreadEventsAvailable = Atomic<Bool>(false)

  /// `private int clock = 0` (`Propagator.java:121`). Confined to the propagation thread.
  ///
  /// A Java `int`, and it is *meant* to wrap: `QNode.compareTo` subtracts with overflow
  /// specifically so a wrapped clock still orders correctly.
  private var clock = 0

  /// `private boolean isOscillating` (`Propagator.java:122`).
  private var oscillating = false

  /// `private boolean oscAdding` (`Propagator.java:123`).
  private var oscAdding = false

  /// `private PropagationPoints oscPoints` (`Propagator.java:124`).
  ///
  /// **Optional, and deliberately so.** `step(PropagationPoints)` assigns
  /// `oscPoints = changedPoints` at `Propagator.java:301` with a parameter its own callers pass
  /// `null` for (`TestVectorEvaluator.java:131` does exactly that), so the field is genuinely
  /// nullable in Java for the duration of a single step. Java gets away with it because
  /// `locationTouched` guards on `oscAdding`, which is `false` on that path. Modelling it as
  /// non-optional would require inventing a placeholder object and would change what
  /// `oscillatingPoints` reports mid-step.
  private var oscPoints: PropagationPoints? = PropagationPoints()

  /// `private int halfClockCycles` (`Propagator.java:125`).
  private var halfClockCycles = 0

  /// `private final Random noiseSource` (`Propagator.java:126`).
  private let noiseSource: NoiseSource

  /// `private int noiseCount` (`Propagator.java:127`).
  private var noiseCount = 0

  /// `private int eventSerialNumber` (`Propagator.java:129`); the tie-break that makes event
  /// order deterministic. See PropagationHeap.swift on why ties are unreachable.
  private var eventSerialNumber = 0

  /// `static int lastId` (`Propagator.java:130`).
  ///
  /// Unsynchronised in Java, and reproduced unsynchronised: `id` reaches nothing but
  /// `toString()`, so a racy duplicate is a cosmetic defect upstream already has. Marked
  /// `nonisolated(unsafe)` to say that out loud rather than to make it safe.
  nonisolated(unsafe) private static var lastId = 0

  /// `final int id = lastId++` (`Propagator.java:132`).
  public let id: Int

  /// Retains the options observer. Java's `AttributeSet` retains it; per D5 the port's
  /// attribute sets hold subscriptions weakly, so the propagator must hold it instead or the
  /// listener would be collected immediately and `simrand`/`simlimit` edits would stop
  /// arriving.
  private var optionsListener: OptionsListener?

  // MARK: - Construction

  /// `public Propagator(CircuitState root, Thread propagatorThread)` (`Propagator.java:134`).
  ///
  /// - Parameters:
  ///   - root: the root of the state tree. Held **weakly**; the state owns the propagator, not
  ///     the other way round. (This line used to say "strongly", contradicting the declaration
  ///     three fields up and `CircuitState`'s header; the declaration was right. See
  ///     `SimulationSeamJoin.swift` for why that direction is the only implementable one.)
  ///   - propagatorThread: the thread every mutating entry point must be called from.
  ///   - queue: the event queue. Defaults to `PropagationHeap`, which is what
  ///     `AppPreferences.SIMULATION_QUEUE`'s default resolves to. Injectable only so a
  ///     differential test can drive an instrumented queue.
  ///   - noiseSeed: when non-`nil`, seeds `noiseSource` deterministically. Java always uses
  ///     `new Random()`; passing `nil` reproduces that. Exists so the `simrand` path is
  ///     testable at all (see `NoiseSource`).
  public init(
    root: any PropagatorCircuitState,
    propagatorThread: Thread,
    queue: (any PropagationEventQueue)? = nil,
    noiseSeed: Int64? = nil
  ) {
    self.root = root
    self.propagatorThread = propagatorThread
    self.toProcess = queue ?? PropagationHeap()
    self.noiseSource = noiseSeed.map { NoiseSource(seed: $0) } ?? NoiseSource()
    self.id = Propagator.lastId
    Propagator.lastId += 1

    // `root.getProject().getOptions().getAttributeSet().addAttributeListener(l)`
    // (`Propagator.java:137-138`).
    let listener = OptionsListener(propagator: self)
    self.optionsListener = listener
    if let options = root.simulationOptions {
      listener.source = options
      options.addSimulationOptionsObserver(listener)
    }

    // `updateRandomness(); updateSimLimit();` (`Propagator.java:148-149`).
    updateRandomness()
    updateSimLimit()
  }

  deinit {
    if let listener = optionsListener {
      listener.source?.removeSimulationOptionsObserver(listener)
    }
  }

  // MARK: - Queries

  /// `CircuitState getRootState()` (`Propagator.java:156`).
  ///
  /// Optional because `root` is weak; `nil` means the state tree has been torn down.
  public var rootState: (any PropagatorCircuitState)? { root }

  /// `public int getTickCount()` (`Propagator.java:160`).
  public var tickCount: Int { halfClockCycles }

  /// `public boolean isOscillating()` (`Propagator.java:164`).
  public var isOscillating: Bool { oscillating }

  /// `boolean isPending()` (`Propagator.java:168`).
  public var isPending: Bool { !toProcess.isEmpty }

  /// The data behind `drawOscillatingPoints(ComponentDrawContext)` (`Propagator.java:152`).
  ///
  /// D9: the kernel does not draw. Upstream's body is
  /// `if (isOscillating) oscPoints.draw(context)`, so the renderer's condition is
  /// `isOscillating` and its input is this.
  public var oscillatingPoints: PropagationPoints? { oscPoints }

  /// `Propagator.clock`, for `SimulatorEvent.cloneFor`. Not part of the Java public surface;
  /// `cloneFor` reaches the field directly because it is in the same class.
  var clockValue: Int { clock }

  /// The `eventSerialNumber++` in `cloneFor` (`Propagator.java:81`).
  func takeEventSerialNumber() -> Int {
    let serial = eventSerialNumber
    eventSerialNumber = wrap32(eventSerialNumber + 1)
    return serial
  }

  // MARK: - Propagation

  /// `void locationTouched(CircuitState state, Location loc)` (`Propagator.java:172`).
  ///
  /// Called by `CircuitState` while it resolves dirty points, to record what the oscillation
  /// halo should highlight.
  public func locationTouched(state: any PropagatorCircuitState, location: Location) {
    if oscAdding { oscPoints?.add(state: state, location: location) }
  }

  /// `public boolean propagate()` (`Propagator.java:177`); *"Must be called from propagation
  /// thread"*.
  @discardableResult
  public func propagate() throws -> Bool {
    try propagate(listener: nil, event: nil)
  }

  /// `public boolean propagate(Simulator.ProgressListener, Simulator.Event)`
  /// (`Propagator.java:182-216`); *"Must be called from propagation thread"*.
  ///
  /// **The oscillation heuristic lives here and is preserved verbatim** (standing rule 4):
  ///
  /// ```java
  /// final var oscThreshold = simLimit;
  /// final var logThreshold = 3 * oscThreshold / 4;
  /// ...
  /// if (iters < logThreshold)        stepInternal(null);
  /// else if (iters < oscThreshold) { oscAdding = true; stepInternal(oscPoints); }
  /// else { isOscillating = true; oscAdding = false; return true; }
  /// ```
  ///
  /// The three-quarters point is where it starts *recording* which points keep changing, so the
  /// UI can highlight them once the cap is hit. Do not fold the two branches together, do not
  /// change the cap, and note that the `iters < oscThreshold` arm returns `true`; an
  /// oscillating circuit reports that it propagated.
  ///
  /// D13: `throws` rather than trapping. Everything reachable from `processDirtyComponents` can
  /// raise, and `Simulator.java:538` catches it.
  @discardableResult
  public func propagate(
    listener: (any PropagationProgressListener)?,
    event: AnyObject?
  ) throws -> Bool {
    guard Thread.current === propagatorThread else {
      throw PropagationError.wrongThread("Propagate called with incorrect thread")
    }
    // `root` is weak (D3). `nil` means the state tree was torn down under a still-referenced
    // propagator; there is nothing to propagate and Java cannot reach this state at all.
    guard let root else { return false }
    oscPoints?.clear()
    try root.processDirtyPoints()
    try root.processDirtyComponents()

    let oscThreshold = simLimit.load(ordering: .sequentiallyConsistent)
    // Java `int` arithmetic: `3 * oscThreshold` can overflow for a large `simlimit` and the
    // division truncates toward zero, exactly as Swift's `/` does.
    let logThreshold = wrap32(3 * oscThreshold) / 4
    var iters = 0
    moveNonPropThreadEvents()
    while !toProcess.isEmpty {
      if iters > 0, let listener {
        listener.propagationInProgress(event)
      }
      iters = wrap32(iters + 1)

      if iters < logThreshold {
        try stepInternal(nil)
      } else if iters < oscThreshold {
        oscAdding = true
        try stepInternal(oscPoints)
      } else {
        oscillating = true
        oscAdding = false
        Propagator.reportPropStats(iters: iters, limit: oscThreshold, oscillating: true)
        return true
      }
      moveNonPropThreadEvents()
    }
    oscillating = false
    oscAdding = false
    oscPoints?.clear()
    Propagator.reportPropStats(iters: iters, limit: oscThreshold, oscillating: false)
    return iters > 0
  }

  // MARK: - Oscillation diagnostics

  /// Whether `LOGISIM_PROPSTATS` is set, read **once** per process.
  ///
  /// Reading `ProcessInfo.environment` builds a whole dictionary on every access, and this sits
  /// on a path that runs once per truth-table row, 262,145 times for the widest corpus oracle.
  /// A `static let` makes it one `Bool` load.
  private static let propStatsEnabled =
    ProcessInfo.processInfo.environment["LOGISIM_PROPSTATS"] != nil

  /// Reports how a propagation ended, on stderr, when `LOGISIM_PROPSTATS` is set.
  ///
  /// **Why this is worth a permanent hook.** `TtyInterface.doTableAnalysis` (4.1.0,
  /// `TtyInterface.java:435-441`) replaces every output pin's value with
  /// `Value.createError(width)` when `isOscillating()` is true. So "the golden table says `E`
  /// and the port says `U`" has two completely different causes: a genuinely erroring net, or
  /// a propagation that hit `simLimit`, and **the table cannot tell them apart**. One of them
  /// is a component bug; the other is a divergence in how many steps the event queue takes to
  /// drain, which no component-level investigation will ever find.
  ///
  /// That distinction cost real time on `2.7.1__case-514.circ::main`, where the jar oscillates on both
  /// rows and the port settles. `tools/valuebridge/BusBridge.java` is the matching oracle on
  /// the Java side; this is the port's half, so the two can be compared directly.
  private static func reportPropStats(iters: Int, limit: Int, oscillating: Bool) {
    guard propStatsEnabled else { return }
    let line = "[propstats] iters=\(iters) limit=\(limit) osc=\(oscillating)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }

  /// `void reset()` (`Propagator.java:219-230`); *"Must be called by the propagation thread"*.
  ///
  /// Note what upstream does **not** do: it clears `nonPropThreadEvents` but leaves
  /// `nonPropThreadEventsAvailable` set. That is harmless, the next
  /// `moveNonPropThreadEvents` takes the monitor, walks an empty list and clears the flag, and
  /// it is reproduced rather than tidied, because tidying it changes one lock acquisition's
  /// worth of timing on the propagation thread for no behavioural gain.
  public func reset() throws {
    guard Thread.current === propagatorThread else {
      throw PropagationError.wrongThread("Reset called with incorrect thread")
    }
    halfClockCycles = 0
    toProcess.clear()
    nonPropThreadEventsLock.lock()
    nonPropThreadEvents.removeAll(keepingCapacity: true)
    nonPropThreadEventsLock.unlock()
    try root?.resetStateTree()
    oscillating = false
  }

  /// *"Moves the simulation events from the nonPropThreadEvents array to the event queue. Must
  /// be called from the propagation thread."* (`Propagator.java:239-249`).
  private func moveNonPropThreadEvents() {
    if nonPropThreadEventsAvailable.load(ordering: .sequentiallyConsistent) {
      nonPropThreadEventsLock.lock()
      for ev in nonPropThreadEvents {
        // `ev.state` is weak (D3); a state that went away between the off-thread `setValue` and
        // this drain has left the tree, so re-submitting its event is unobservable. See the
        // note on `PropagationEvent.state`.
        guard let state = ev.state else { continue }
        // Note the argument order in Java: `(ev.state, ev.loc, ev.val, ev.cause, ev.timeKey)`.
        // The deferred event stores the *delay* in `timeKey`, not an absolute time, see
        // `setValue` below.
        setValueWithPropThread(
          state: state, location: ev.loc, value: ev.val, cause: ev.cause, delay: ev.timeKey)
      }
      nonPropThreadEvents.removeAll(keepingCapacity: true)
      nonPropThreadEventsAvailable.store(false, ordering: .sequentiallyConsistent)
      nonPropThreadEventsLock.unlock()
    }
  }

  /// `void setValue(CircuitState, Location, Value, Component, int delay)`
  /// (`Propagator.java:252-265`); *"May be called by any thread."*
  ///
  /// The off-thread branch parks a `PropagationEvent` whose `timeKey` field holds the **delay**
  /// and whose serial number is a placeholder `0`; `moveNonPropThreadEvents` re-submits it
  /// through the propagation-thread path, which is where it gets a real serial number. That is
  /// why serial-number ties never reach the queue.
  public func setValue(
    state: any PropagatorCircuitState,
    location: Location,
    value: Value,
    cause: any PropagatorComponent,
    delay: Int
  ) {
    // Wires and splitters are resolved by CircuitWires during processDirtyPoints; they never
    // schedule a delayed event.
    if cause.isWireOrSplitter { return }
    var delay = delay
    if delay <= 0 {
      delay = 1
    }
    if Thread.current === propagatorThread {
      setValueWithPropThread(
        state: state, location: location, value: value, cause: cause, delay: delay)
    } else {
      nonPropThreadEventsLock.lock()
      nonPropThreadEvents.append(
        PropagationEvent(
          timeKey: delay, serialNumber: 0, state: state, loc: location, cause: cause, val: value))
      nonPropThreadEventsAvailable.store(true, ordering: .sequentiallyConsistent)
      nonPropThreadEventsLock.unlock()
    }
  }

  /// `private void setValueWithPropThread(...)` (`Propagator.java:268-285`); *"Must be called
  /// from the propagation thread."*
  ///
  /// **The noise injection, preserved verbatim** (standing rule 4), comment included:
  ///
  /// ```java
  /// final var randomShift = simRandomShift;
  /// if (randomShift > 0) { // random noise is turned on
  ///   // multiply the delay by 32 so that the random noise
  ///   // only changes the delay by 3%.
  ///   delay <<= randomShift;
  ///   if (!(cause.getFactory() instanceof SubcircuitFactory)) {
  ///     if (noiseCount > 0) {
  ///       noiseCount--;
  ///     } else {
  ///       delay++;
  ///       noiseCount = noiseSource.nextInt(1 << randomShift);
  ///     }
  ///   }
  /// }
  /// ```
  ///
  /// The stale comment ("multiply by 32") describes the default `simrand` of 32, i.e. a shift
  /// of 5; the code shifts by whatever `simRandomShift` holds. Left as-is.
  ///
  /// All arithmetic is Java `int`: the shift distance is masked to 5 bits, and `clock + delay`
  /// wraps. `wrap32` is applied at each step so an oversized `simlimit`/`simrand` or a very
  /// long-running simulation produces Java's wrapped values instead of trapping.
  private func setValueWithPropThread(
    state: any PropagatorCircuitState,
    location: Location,
    value: Value,
    cause: any PropagatorComponent,
    delay: Int
  ) {
    var delay = delay
    let randomShift = simRandomShift.load(ordering: .sequentiallyConsistent)
    if randomShift > 0 {  // random noise is turned on
      // multiply the delay by 32 so that the random noise
      // only changes the delay by 3%.
      delay = Propagator.javaShiftLeft(delay, randomShift)
      if !cause.isSubcircuitComponent {
        if noiseCount > 0 {
          noiseCount = wrap32(noiseCount - 1)
        } else {
          delay = wrap32(delay + 1)
          noiseCount = noiseSource.nextInt(Propagator.javaShiftLeft(1, randomShift))
        }
      }
    }
    toProcess.add(
      PropagationEvent(
        timeKey: wrap32(clock + delay),
        serialNumber: eventSerialNumber,
        state: state,
        loc: location,
        cause: cause,
        val: value))
    eventSerialNumber = wrap32(eventSerialNumber + 1)
  }

  /// `boolean step(PropagationPoints changedPoints)` (`Propagator.java:288-306`); *"Must be
  /// called from propagation thread"*.
  ///
  /// `changedPoints` is genuinely nullable upstream (`TestVectorEvaluator.java:131` passes
  /// `null` to let the clock signal reach the wires before setting pins), and the swap through
  /// `oscPoints` is reproduced including that.
  ///
  /// One faithful-but-latent Java behaviour worth naming: there is **no `try`/`finally`** around
  /// `stepInternal` here, so if it throws, upstream leaves `oscAdding == true` and `oscPoints`
  /// pointing at the caller's object (or `null`). The Swift is a literal translation and
  /// inherits that; it is not tidied, because the restore order is observable to
  /// `oscillatingPoints` and the differential gate compares behaviour, not intent.
  @discardableResult
  public func step(_ changedPoints: PropagationPoints?) throws -> Bool {
    guard Thread.current === propagatorThread else {
      throw PropagationError.wrongThread("Step called with incorrect thread")
    }
    guard let root else { return false }
    oscPoints?.clear()
    try root.processDirtyPoints()
    try root.processDirtyComponents()
    moveNonPropThreadEvents()

    if toProcess.isEmpty { return false }

    let oldOsc = oscPoints
    oscAdding = changedPoints != nil
    oscPoints = changedPoints
    try stepInternal(changedPoints)
    oscAdding = false
    oscPoints = oldOsc
    return true
  }

  /// `private void stepInternal(PropagationPoints changedPoints)` (`Propagator.java:309-330`);
  /// *"Must be called from propagation thread"*.
  ///
  /// This is the whole event loop in fourteen lines, and every one of them matters:
  ///
  ///  * the clock **jumps** to the next event's `timeKey` rather than advancing by one, so
  ///    empty time costs nothing;
  ///  * every event sharing that instant is drained in one pass, which is what makes
  ///    simultaneous arrivals simultaneous;
  ///  * `ev.timeKey != clock` is an **equality** test, not `>`. With a wrapping clock that is
  ///    the only test that is correct, and it is also why an event can never be skipped by a
  ///    clock that overshot it;
  ///  * the dirty points are resolved *after* the whole instant is drained, not per event.
  private func stepInternal(_ changedPoints: PropagationPoints?) throws {
    if toProcess.isEmpty { return }

    // update clock
    clock = toProcess.peek()!.timeKey

    // propagate all values for this clock tick
    while true {
      guard let ev = toProcess.peek(), ev.timeKey == clock else { break }
      toProcess.remove()
      // `ev.state` is weak (D3). A `nil` state is one that left the tree while its event was
      // still queued; delivering to it is unobservable, because a state unreachable from `root`
      // is never visited by `processDirtyPoints` either. The event is still *drained*, so the
      // loop and the oscillation counters behave exactly as Java's.
      guard let state = ev.state else { continue }

      if let changedPoints { changedPoints.add(state: state, location: ev.loc) }

      // if the value at point has changed, propagate it
      state.markPointAsDirty(ev)
    }

    try root?.processDirtyPoints()
    try root?.processDirtyComponents()
  }

  /// `public boolean toggleClocks()` (`Propagator.java:332-335`).
  ///
  /// `halfClockCycles` is a Java `int` and is reproduced as one; at the default 1 kHz it takes
  /// about 25 days of continuous simulation to wrap, and when it does, upstream wraps too.
  @discardableResult
  public func toggleClocks() throws -> Bool {
    halfClockCycles = wrap32(halfClockCycles + 1)
    guard let root else { return false }
    return try root.toggleClocks(halfClockCycles)
  }

  // MARK: - Options

  /// `private void updateRandomness()` (`Propagator.java:342-351`):
  ///
  /// ```java
  /// final var val = opts.getAttributeSet().getValue(Options.ATTR_SIM_RAND);
  /// var logVal = 0;
  /// while ((1 << logVal) < val) logVal++;
  /// simRandomShift = logVal;
  /// ```
  ///
  /// ### One documented divergence, and why it is not optional
  ///
  /// **Upstream hangs here for `simrand > 2^30`.** Java's `<<` masks the shift distance to five
  /// bits, so once `logVal` reaches 32 the sequence `1 << logVal` repeats the same 32 values
  /// forever and the loop can never terminate. Concretely, `<a name="simrand" val="2147483647"/>`
  /// in a `.circ` makes 4.1.0 spin at 100% of a core inside a constructor, with no exception, no
  /// dialog and no way back.
  ///
  /// That is reachable from an ordinary malformed file, `Options.ATTR_SIM_RAND` is a plain
  /// integer attribute and the reader does not range-check it, and an unrecoverable hang is
  /// strictly worse than the crash D13 exists to prevent. So the loop exits once `logVal`
  /// reaches 32, at which point non-termination is *proved* (no value in `0...31` satisfied the
  /// test, and every subsequent value repeats one of those), and randomness is left **off**:
  /// `simRandomShift = 0`, the shipped default.
  ///
  /// Nothing upstream's own UI can produce reaches the guard: the preferences dialog writes 0 or
  /// 32, and every `simrand` in `1...2^30` terminates with an identical result. The guard also
  /// pins `simRandomShift` to `0...30`, which is what lets `nextInt`'s bound be positive by
  /// construction.
  ///
  /// This should be recorded in `decisions.md`; it is flagged rather than assumed settled.
  private func updateRandomness() {
    let val = root?.simulationOptions?.simulationRandomnessOption ?? Propagator.defaultSimRand
    var logVal = 0
    while Propagator.javaShiftLeft(1, logVal) < val {
      logVal += 1
      if logVal >= 32 {
        // Provably non-terminating in Java; see the note above.
        logVal = 0
        break
      }
    }
    simRandomShift.store(logVal, ordering: .sequentiallyConsistent)
  }

  /// `private void updateSimLimit()` (`Propagator.java:353-357`).
  private func updateSimLimit() {
    let lim = root?.simulationOptions?.simulationLimitOption ?? Propagator.defaultSimLimit
    simLimit.store(wrap32(lim), ordering: .sequentiallyConsistent)
  }

  /// `Options`' own defaults, used when a state tree has no project (the headless CLI path).
  /// Matching the values a freshly constructed `Options` carries is what makes the fallback
  /// unable to diverge from upstream.
  private static let defaultSimLimit = 1000
  private static let defaultSimRand = 0

  // MARK: - Java int helpers

  /// Java's `int << int`: the shift distance is masked to its low 5 bits and the result wraps.
  ///
  /// Both halves are load-bearing here. The masking is what makes `updateRandomness` cycle
  /// rather than terminate, and the wrap is what `setValueWithPropThread` relies on when a
  /// large `simrand` pushes a delay past `Int32.max`.
  @inline(__always)
  private static func javaShiftLeft(_ value: Int, _ distance: Int) -> Int {
    wrap32(wrap32(value) << (distance & 31))
  }
}

extension Propagator: CustomStringConvertible {
  /// `toString()` (`Propagator.java:338`): `"Prop" + id`.
  public var description: String { "Prop\(id)" }
}
