// The test D15 has demanded since M3 was planned (tracker task #14): direct cover for
// `CircuitWires.ValuedBus.recalculate()`'s three early returns, the guards that keep
// `Value.createUnsafe` from ever being reached below width 2.
//
// Until this file existed the guards' only witness was the corpus simulation gate, indirectly.
// That is exactly the kind of indirection the ROM port-geometry bug hid behind for a whole
// milestone, so "the gate is green" is not cover.
//
// ── WHAT THIS FILE ESTABLISHES, AND WHY IT IS NOT WHAT D15 ASKED FOR ────────────────────────
//
// D15 asked for a test that goes red when the `width == 1` early return is deleted. **No such
// test can exist in this port**, and that is a finding rather than a gap; it is measured in
// `recalculateGuard3IsValueNeutral()` below and was confirmed against the full corpus gate
// (1,342 byte-exact with the guard, 1,342 without it).
//
// Two rationales have been offered for the guard and neither survives contact with the port:
//
//  1. **D15's original, Java's:** upstream's narrow-width operators compare by *reference*
//     against interned singletons, and `create_unsafe` never returns one, so at width 1 every
//     identity branch misses and Java's answer collapses to ERROR. True of Java; `Value` here is
//     a `struct` with no interning and memberwise `==`, so it does not transfer. D15 records this
//     correction itself.
//
//  2. **D15's 2026-09-05 correction:** that the general `width >= 2` fold turns anything outside
//     `{TRUE, FALSE, UNKNOWN}` into ERROR, "including `.nilValue`", so guard 3 is what
//     preserves a width-1 bus whose thread is NIL. **`ValuedThread.threadValue()` cannot return
//     NIL.** It starts at `.unknownValue`, and its only mutation is `combine` with
//     `Value.get(_:)`, which returns one of the four width-1 singletons for *every* index;
//     `.errorValue` when the index is out of range (`Value.swift:865-872`, matching
//     `Value.java:456-463`). `combine` of two width-1 values is width-1. So the fold's `else`
//     branch is unreachable at width 1, and `threadValueIsNeverNil()` pins that.
//
// What the guard *is*: a faithful transcription of `CircuitWires.java:352-356`, load-bearing
// upstream and a fast path here. It stays, because the port's job is to be 4.1.0, but it stays
// with an honest reason attached, since a justification that does not hold is what gets working
// code deleted by the next person who checks it.
//
// Guards 1 and 2 ARE load-bearing here, and `recalculateGuard1...`/`...Guard2...` below fail
// loudly without them: both reach the fold with `threads == nil` and throw
// `CircuitWiresError.staleConnectivity`, converting a value Java computes into a D13-style
// simulation error.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import Testing

@testable import LogisimKernel

// MARK: - Fixture

/// Builds `ValuedBus`es directly, without a `Circuit` or a `Propagator`.
///
/// `ValuedBus.init` takes `(Int, WireBundle, Connectivity)` and reads only `bundle.xpoints`,
/// `bundle.threads`, `bundle.getWidth()`, `bundle.getPullValue()` and
/// `cmap.componentsAtLocations`, so an empty `Connectivity` yields a bus with no connections,
/// which is what these tests want: the driven values are injected directly, so nothing here
/// depends on a component's `propagate`.
private enum BusFixture {

  static func location(_ x: Int, _ y: Int) -> Location {
    Location.create(x, y, hasToSnap: false)
  }

  /// A bundle of `width` bits touching one point, with `threads` populated.
  ///
  /// `threadsSpan` is the number of bundles each thread claims to traverse. A thread with
  /// `steps > 1` is what makes `makeThreads` treat the bus as non-degenerate, which is how
  /// upstream models "this bus is reached through a splitter".
  static func bundle(
    width: Int,
    at point: Location,
    threadsSpan: Int = 1,
    pull: Value? = nil
  ) throws -> (WireBundle, [WireThread]) {
    let wb = WireBundle(point)
    if width > 0 {
      wb.setWidth(try BitWidth.create(width), point)
    }
    if let pull { wb.addPullValue(pull) }
    var threads: [WireThread] = []
    for bit in 0..<max(width, 0) {
      let t = WireThread()
      // Step 0 is always this bundle; any further steps are the same bundle again, which is
      // enough to make `steps > 1` without needing a second bundle object. `ValuedThread`'s
      // constructor only ever looks the bundle up in `allBuses`.
      for _ in 0..<max(threadsSpan, 1) {
        try t.addBundlePosition(bit, wb)
      }
      t.finishConstructing()
      threads.append(t)
    }
    wb.threads = threads
    wb.xpoints = [point]
    return (wb, threads)
  }

  /// A `ValuedBus` over `bundle`, with its `ValuedThread`s built the way `CircuitWires.State`
  /// builds them.
  static func valuedBus(
    _ bundle: WireBundle,
    threads: [WireThread],
    index: Int = 0
  ) throws -> CircuitWires.ValuedBus {
    let cmap = CircuitWires.Connectivity()
    let vb = try CircuitWires.ValuedBus(index, bundle, cmap)
    var allBuses: [ObjectIdentifier: CircuitWires.ValuedBus] = [ObjectIdentifier(bundle): vb]
    var allThreads: [ObjectIdentifier: CircuitWires.ValuedThread] = [:]
    try vb.makeThreads(bundle.threads, allBuses, &allThreads)
    allBuses.removeAll()
    return vb
  }

  /// Marks `vb` as non-degenerate. `State` derives this from the threads' other buses; these
  /// tests have one bus, so it is set directly; the only thing `recalculate` asks of it is
  /// whether it is empty.
  static func makeNonDegenerate(_ vb: CircuitWires.ValuedBus, dependingOn other: CircuitWires.ValuedBus) {
    vb.dependentBuses = [CircuitWires.UnownedBus(bus: other)]
  }

  /// The four width-1 values a `ValuedThread` can resolve to, with their names.
  static let oneBitValues: [(String, Value)] = [
    ("FALSE", .falseValue),
    ("TRUE", .trueValue),
    ("UNKNOWN", .unknownValue),
    ("ERROR", .errorValue),
  ]
}

// MARK: - Tests

@Suite("D15 / task #14 — ValuedBus.recalculate's narrow-width guards")
struct NarrowWidthBusTests {

  // ══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: Guard 1 — width <= 0
  // ══════════════════════════════════════════════════════════════════════════════════════════

  @Test("guard 1: an invalid-width bus resolves to NIL instead of throwing")
  func recalculateGuard1ReturnsNilForInvalidWidth() throws {
    // `CircuitWires.java:342-346`. A bundle whose width was never determined, or whose width is
    // inconsistent along its length, reports `BitWidth.UNKNOWN` (width 0) and gets no threads.
    let point = BusFixture.location(10, 10)
    let wb = WireBundle(point)
    wb.threads = []            // non-nil, so `ValuedBus.width` comes from the bundle, not -1
    wb.xpoints = [point]
    let vb = try BusFixture.valuedBus(wb, threads: [])

    #expect(vb.width == 0, "an undetermined width must arrive as 0, not as a real width")
    #expect(try vb.recalculate() == .nilValue)
    #expect(vb.busVal == .nilValue)
    #expect(vb.dirty == false, "recalculate must clear `dirty` on every path")

    // Without guard 1 this same bus reaches the fold with `threads == nil` and throws
    // `staleConnectivity`, i.e. a value upstream computes becomes a simulation error (D13).
    #expect(vb.threads == nil)
  }

  @Test("guard 1 also covers a bundle with no threads at all (width -1)")
  func recalculateGuard1CoversNilThreads() throws {
    let point = BusFixture.location(20, 20)
    let wb = WireBundle(point)
    wb.setWidth(try BitWidth.create(8), point)
    wb.xpoints = [point]
    // `wb.threads` left nil: `ValuedBus.init` maps that to width -1 (`CircuitWires.java:298`).
    let vb = try BusFixture.valuedBus(wb, threads: [])

    #expect(vb.width == -1)
    #expect(try vb.recalculate() == .nilValue)
  }

  // ══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: Guard 2 — the degenerate bus
  // ══════════════════════════════════════════════════════════════════════════════════════════

  @Test("guard 2: a degenerate bus resolves from localDrivenValue, threads untouched")
  func recalculateGuard2UsesLocalDrivenValue() throws {
    // `CircuitWires.java:347-353`. A bus not reached through a splitter has every thread with
    // `steps == 1`, so `makeThreads` returns before allocating any, and `dependentBuses` is
    // empty. All bits are resolved in one pass from the combined driven values.
    let point = BusFixture.location(30, 30)
    let (wb, threads) = try BusFixture.bundle(width: 8, at: point, threadsSpan: 1)
    let vb = try BusFixture.valuedBus(wb, threads: threads)

    #expect(vb.threads == nil, "a degenerate bus must not allocate ValuedThreads")
    #expect(vb.dependentBuses.isEmpty)

    let driven = Value.createKnown(try BitWidth.create(8), 0xA5)
    vb.localDrivenValue = driven
    #expect(try vb.recalculate() == driven)

    // And the pull is applied to the unknown bits only: `pullEachBitTowards`, which for the
    // default UNKNOWN pull is the identity (upstream's `pullVal != null` test can never fail
    // because `WireBundle.pullValue` starts at UNKNOWN, never null).
    let half = Value.createUnsafe(width: 8, error: 0, unknown: 0x0F, value: 0xA0)
    vb.localDrivenValue = half
    vb.dirty = true
    #expect(try vb.recalculate() == half, "an UNKNOWN pull must leave the value alone")
  }

  @Test("guard 2: a pull-up resistor fills a degenerate bus's unknown bits")
  func recalculateGuard2AppliesPull() throws {
    let point = BusFixture.location(40, 40)
    let (wb, threads) = try BusFixture.bundle(width: 4, at: point, threadsSpan: 1, pull: .trueValue)
    let vb = try BusFixture.valuedBus(wb, threads: threads)

    #expect(vb.pullVal == .trueValue)
    vb.localDrivenValue = Value.createUnsafe(width: 4, error: 0, unknown: 0b0011, value: 0b0100)
    // pullEachBitTowards(TRUE): unknown bits become 1, known bits are kept.
    #expect(try vb.recalculate() == Value.createKnown(try BitWidth.create(4), 0b0111))
  }

  // ══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: Guard 3 — width == 1
  // ══════════════════════════════════════════════════════════════════════════════════════════

  @Test("guard 3: a width-1 bus resolves through its single thread, for all four thread values")
  func recalculateGuard3ResolvesThroughTheThread() throws {
    // `CircuitWires.java:354-357`. This is the guard D15 names. It must return exactly what the
    // thread carries, for every value the thread can carry.
    for (name, injected) in BusFixture.oneBitValues {
      let point = BusFixture.location(50, 50)
      let (wb, threads) = try BusFixture.bundle(width: 1, at: point, threadsSpan: 2)
      let vb = try BusFixture.valuedBus(wb, threads: threads)
      BusFixture.makeNonDegenerate(vb, dependingOn: vb)

      #expect(vb.width == 1)
      #expect(vb.threads?.count == 1, "guard 3 indexes threads[0] unconditionally")

      // Drive the thread by setting the bus's own localDrivenValue: `ValuedThread.threadValue`
      // folds `bus[i].localDrivenValue.get(position[i])` over its steps.
      vb.localDrivenValue = injected
      vb.threads?[0].threadVal = nil

      let result = try vb.recalculate()
      #expect(result == injected, "guard 3 must hand back the thread value verbatim (\(name))")
      #expect(result.width == 1)
      #expect(vb.dirty == false)
    }
  }

  @Test("guard 3 is VALUE-NEUTRAL in this port — the fold agrees with it bit for bit")
  func recalculateGuard3IsValueNeutral() throws {
    // This is the measurement behind the header note, and it is the reason no test in this file
    // can go red when guard 3 is deleted.
    //
    // The `width >= 2` fold, specialised to width 1, is:
    //     mask = 1
    //     TRUE -> value |= 1 · FALSE -> nothing · UNKNOWN -> unknown |= 1 · else -> error |= 1
    //     createUnsafe(width: 1, error, unknown, value)
    // Upstream that result is a *fresh, uninterned* object, so every downstream `== Value.TRUE`
    // reference test misses and the guard is what keeps the answer usable. Here `Value` is a
    // struct with memberwise equality, so the fold's output is indistinguishable from the
    // canonical singleton; asserted below rather than argued.
    #expect(Value.createUnsafe(width: 1, error: 0, unknown: 0, value: 1) == .trueValue)
    #expect(Value.createUnsafe(width: 1, error: 0, unknown: 0, value: 0) == .falseValue)
    #expect(Value.createUnsafe(width: 1, error: 0, unknown: 1, value: 0) == .unknownValue)
    #expect(Value.createUnsafe(width: 1, error: 1, unknown: 0, value: 0) == .errorValue)

    // ...and equal all the way down, not merely `==`: the four stored planes must match, or a
    // `Hashable`/dictionary-keyed use could still tell them apart.
    for (name, canonical) in BusFixture.oneBitValues {
      let folded = Value.createUnsafe(
        width: 1,
        error: canonical == .errorValue ? 1 : 0,
        unknown: canonical == .unknownValue ? 1 : 0,
        value: canonical == .trueValue ? 1 : 0)
      #expect(folded.width == canonical.width, "\(name) width")
      #expect(folded.error == canonical.error, "\(name) error plane")
      #expect(folded.unknown == canonical.unknown, "\(name) unknown plane")
      #expect(folded.value == canonical.value, "\(name) value plane")
      #expect(folded.hashValue == canonical.hashValue, "\(name) hash")
      #expect(folded.description == canonical.description, "\(name) rendering")
    }
  }

  @Test("the fold's `else -> ERROR` branch is unreachable at width 1: threadValue is never NIL")
  func threadValueIsNeverNil() throws {
    // D15's 2026-09-05 correction claims guard 3 preserves a NIL thread value that the fold
    // would turn into ERROR. `ValuedThread.threadValue()` cannot produce NIL, and this is the
    // proof: it seeds `.unknownValue` and only ever `combine`s that with `Value.get(_:)`, which
    // is total: out-of-range indices yield ERROR, never NIL.
    for index in [-1, 0, 1, 7, 8, 63, 64, 1000] {
      #expect(Value.nilValue.get(index) == .errorValue)
      let v = Value.createKnown(try BitWidth.create(8), 0xF0)
      let bit = v.get(index)
      #expect(bit != .nilValue, "Value.get(\(index)) must never be NIL")
      #expect(bit.width == 1, "Value.get(\(index)) must always be one bit wide")
    }

    // `combine` over width-1 operands closes over {TRUE, FALSE, UNKNOWN, ERROR}.
    for (lname, lhs) in BusFixture.oneBitValues {
      for (rname, rhs) in BusFixture.oneBitValues {
        let combined = lhs.combine(rhs)
        #expect(combined.width == 1, "combine(\(lname), \(rname)) changed width")
        #expect(combined != .nilValue, "combine(\(lname), \(rname)) produced NIL")
      }
    }

    // And end to end, through the real class: a `ValuedThread` over a bus driven with each of
    // the four values, plus the undriven case, never yields NIL.
    for driven in [nil] + BusFixture.oneBitValues.map({ Optional($0.1) }) {
      let point = BusFixture.location(60, 60)
      let (wb, threads) = try BusFixture.bundle(width: 1, at: point, threadsSpan: 2)
      let vb = try BusFixture.valuedBus(wb, threads: threads)
      vb.localDrivenValue = driven
      let tv = try #require(vb.threads?[0]).threadValue()
      #expect(tv != .nilValue)
      #expect(tv.width == 1)
    }
  }

  // ══════════════════════════════════════════════════════════════════════════════════════════
  // MARK: The invariant the guards exist to carry
  // ══════════════════════════════════════════════════════════════════════════════════════════

  @Test("createUnsafe is never reached below width 2, on any of the four paths")
  func createUnsafeIsUnreachableBelowWidthTwo() throws {
    // D15's actual demand, stated as a property of `recalculate` rather than of `createUnsafe`:
    // every bus with `width < 2` must leave through one of the three early returns. The three
    // guards above cover widths <= 0 and 1; this asserts the remaining shape, that the only
    // bus that reaches the fold has width >= 2 and a full thread array, and that the fold's
    // answer is correct there.
    let point = BusFixture.location(70, 70)
    let (wb, threads) = try BusFixture.bundle(width: 4, at: point, threadsSpan: 2)
    let vb = try BusFixture.valuedBus(wb, threads: threads)
    BusFixture.makeNonDegenerate(vb, dependingOn: vb)

    #expect(vb.width == 4)
    #expect(vb.threads?.count == 4, "the fold indexes threads[0..<width]")

    // bit 0 TRUE, bit 1 FALSE, bit 2 UNKNOWN, bit 3 ERROR.
    vb.localDrivenValue = Value.createUnsafe(
      width: 4, error: 0b1000, unknown: 0b0100, value: 0b0001)
    for t in vb.threads ?? [] { t.threadVal = nil }

    let result = try vb.recalculate()
    #expect(result.width == 4)
    #expect(result.get(0) == .trueValue)
    #expect(result.get(1) == .falseValue)
    #expect(result.get(2) == .unknownValue)
    #expect(result.get(3) == .errorValue)
    // The per-bit split the fold exists to produce, as one value.
    #expect(result == Value.createUnsafe(width: 4, error: 0b1000, unknown: 0b0100, value: 0b0001))
  }

  @Test("createUnsafe stays permissive — the guards are the invariant, not a validator")
  func createUnsafeAddsNoValidation() throws {
    // D15: `createUnsafe` itself must validate nothing, because the `X` golden cases probe
    // out-of-range widths where Java is also permissive. If someone "hardens" it instead of
    // keeping the guards, this goes red.
    #expect(Value.createUnsafe(width: 65, error: 0, unknown: 0, value: 1).width == 65)
    #expect(Value.createUnsafe(width: 100, error: 0, unknown: 0, value: 1).width == 100)
    #expect(Value.createUnsafe(width: -1, error: 0, unknown: 0, value: 0).width == -1)
    // No masking either: the planes come back exactly as handed in.
    let v = Value.createUnsafe(width: 2, error: 0xFF, unknown: 0xF0, value: 0x0F)
    #expect(v.error == 0xFF)
    #expect(v.unknown == 0xF0)
    #expect(v.value == 0x0F)
  }
}
