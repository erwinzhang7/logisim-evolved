// LogSignalHistoryTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Every expectation is the observed behaviour of `com.cburch.logisim.gui.log.Signal` (4.1.0),
// except the two divergences the ported file states in its header, which are pinned here so
// they cannot be "fixed" back into the Java bug by a later reader.

import LogisimKernel
import Testing

@testable import LogisimUI

private func known(_ width: Int, _ value: Int64) -> Value {
  Value.createKnown(BitWidth.known(width), value)
}

@Suite("Signal history — Signal.java's run-length store")
struct LogSignalHistoryTests {

  @Test("The constructor seeds one run, and endTime is timeStart + its duration")
  func seedsOneRun() {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 5000)
    #expect(h.runCount == 1)
    #expect(h.timeStart == 0)
    #expect(h.endTime == 5000)
    #expect(h.value(at: 0, width: 1) == .falseValue)
    #expect(h.value(at: 4999, width: 1) == .falseValue)
    #expect(h.value(at: 5000, width: 1) == nil)
  }

  @Test("Equal consecutive values coalesce into one run — extend(v, d)'s whole point")
  func coalescesEqualValues() {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 100)
    h.extend(.falseValue, 100)
    h.extend(.falseValue, 100)
    #expect(h.runCount == 1)
    #expect(h.endTime == 300)
    h.extend(.trueValue, 50)
    #expect(h.runCount == 2)
    #expect(h.endTime == 350)
  }

  @Test("extend(duration) with no value lengthens the last run, it does not add one")
  func extendWithoutValue() {
    let h = LogSignalHistory(initialValue: .trueValue, duration: 10)
    h.extend(40)
    #expect(h.runCount == 1)
    #expect(h.endTime == 50)
    #expect(h.value(at: 49, width: 1) == .trueValue)
  }

  @Test("The history limit evicts the oldest run and pulls timeStart forward")
  func historyLimitEvicts() {
    let h = LogSignalHistory(initialValue: known(2, 0), duration: 10, timeStart: 0, maxSize: 3)
    h.extend(known(2, 1), 10)
    h.extend(known(2, 2), 10)
    #expect(h.runCount == 3)
    #expect(h.timeStart == 0)
    #expect(h.omittedDataTime == 0 || h.omittedDataTime == h.timeStart)

    h.extend(known(2, 3), 10)
    #expect(h.runCount == 3)
    #expect(h.timeStart == 10)  // the first run's 10 ns is gone
    #expect(h.endTime == 40)
    #expect(h.omittedDataTime == 10)  // `curSize == maxSize ? timeStart : 0`
    #expect(h.value(at: 0, width: 2) == nil)  // before timeStart
    #expect(h.value(at: 10, width: 2) == known(2, 1))
  }

  @Test("Values are widened to the signal's current width, filling with FALSE")
  func widensStoredValues() {
    // `Iterator`/`getValue` both call `extendWidth(width, Value.FALSE)`: a pin whose width
    // attribute grows must render its old, narrower samples at the new width.
    let h = LogSignalHistory(initialValue: known(2, 0b11), duration: 10)
    #expect(h.value(at: 0, width: 4) == known(4, 0b0011))
    #expect(h.formattedValue(at: 0, width: 4, radix: .binary) == "0011")
  }

  // MARK: replaceRecent — the three branches, plus D13

  @Test("replaceRecent with an exactly matching duration rewrites the last run")
  func replaceRecentExact() throws {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 100)
    h.extend(.trueValue, 40)
    try h.replaceRecent(.unknownValue, 40)
    #expect(h.runCount == 2)
    #expect(h.value(at: 100, width: 1) == .unknownValue)
    #expect(h.endTime == 140)
  }

  @Test("replaceRecent coalesces when the rewritten run now matches the one before it")
  func replaceRecentCoalesces() throws {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 100)
    h.extend(.trueValue, 40)
    try h.replaceRecent(.falseValue, 40)
    #expect(h.runCount == 1)
    #expect(h.endTime == 140)
  }

  @Test("replaceRecent with a shorter duration splits the last run")
  func replaceRecentSplits() throws {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 100)
    try h.replaceRecent(.trueValue, 30)
    #expect(h.runCount == 2)
    #expect(h.endTime == 100)
    #expect(h.value(at: 0, width: 1) == .falseValue)
    #expect(h.value(at: 69, width: 1) == .falseValue)
    #expect(h.value(at: 70, width: 1) == .trueValue)
  }

  @Test("replaceRecent past the available history throws rather than trapping (D13)")
  func replaceRecentThrows() {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 10)
    h.extend(.trueValue, 5)
    #expect(throws: LogSignalHistoryError.self) {
      // 5 ns in the last run, 10 ns before it, and more than one run, Java's second
      // IllegalStateException.
      try h.replaceRecent(.unknownValue, 500)
    }
  }

  // MARK: resize — the stated divergence

  @Test("Shrinking the limit keeps the newest runs and advances timeStart past the dropped ones")
  func resizeShrinkKeepsNewest() {
    // Java's `resize` computes `discard = maxSize - newMaxSize` and reads past `curSize` when
    // the ring is only partly full, which walks into never-written slots. See the divergence
    // note in LogSignalHistory.swift.
    let h = LogSignalHistory(initialValue: known(4, 0), duration: 10, timeStart: 0, maxSize: 100)
    for v in 1...4 { h.extend(known(4, Int64(v)), 10) }
    #expect(h.runCount == 5)

    h.resize(2)
    #expect(h.runCount == 2)
    #expect(h.maxSize == 2)
    #expect(h.timeStart == 30)  // three 10 ns runs dropped
    #expect(h.endTime == 50)
    #expect(h.value(at: 30, width: 4) == known(4, 3))
    #expect(h.value(at: 40, width: 4) == known(4, 4))
  }

  @Test("Growing the limit keeps everything")
  func resizeGrowKeepsAll() {
    let h = LogSignalHistory(initialValue: known(4, 0), duration: 10, timeStart: 0, maxSize: 2)
    h.extend(known(4, 1), 10)
    h.extend(known(4, 2), 10)  // evicts run 0
    #expect(h.runCount == 2)
    h.resize(0)  // unlimited
    #expect(h.runCount == 2)
    h.extend(known(4, 3), 10)
    h.extend(known(4, 4), 10)
    #expect(h.runCount == 4)
  }

  @Test("reset clears the runs but leaves timeStart alone, as Signal.reset does")
  func resetKeepsTimeStart() {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 10, timeStart: 700)
    h.extend(.trueValue, 10)
    h.reset(.unknownValue, 25)
    #expect(h.runCount == 1)
    #expect(h.timeStart == 700)
    #expect(h.endTime == 725)
    #expect(h.value(at: 700, width: 1) == .unknownValue)
  }

  // MARK: cursors

  @Test("A cursor walks runs, then nils its value at the end — Iterator.advance()")
  func cursorWalksAndExhausts() {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 10)
    h.extend(.trueValue, 20)

    var c = h.makeCursor(width: 1)
    #expect(c.value == .falseValue)
    #expect(c.time == 0)
    #expect(c.duration == 10)

    #expect(h.advance(&c, width: 1) == true)
    #expect(c.value == .trueValue)
    #expect(c.time == 10)
    #expect(c.duration == 20)

    #expect(h.advance(&c, width: 1) == false)
    #expect(c.value == nil)
    #expect(c.duration == 0)
    #expect(c.formattedValue(radix: .binary) == "-")
  }

  @Test("advance(by:) consumes runs and leaves the remaining duration of the one it lands in")
  func cursorAdvanceByDuration() {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 10)
    h.extend(.trueValue, 20)
    var c = h.makeCursor(width: 1)
    #expect(h.advance(&c, by: 15, width: 1) == true)
    #expect(c.value == .trueValue)
    #expect(c.time == 15)
    #expect(c.duration == 15)  // 20 - (15 - 10)
  }

  @Test("A cursor created at a time lands in the run holding that time")
  func cursorAtTime() {
    let h = LogSignalHistory(initialValue: .falseValue, duration: 10)
    h.extend(.trueValue, 20)
    let c = h.makeCursor(at: 25, width: 1)
    #expect(c.value == .trueValue)
    #expect(c.time == 25)
  }
}
