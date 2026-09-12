// LogSignalHistory.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.Signal: the data half only),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this is ────────────────────────────────────────────────────────────────────────────
//
// The run-length-encoded value history behind one logged signal: a bounded ring of
// `(value, duration)` runs plus the simulated time the first run starts at. Everything the Log
// window and the chronogram draw comes out of this type, and it is *plain data*: no window, no
// AppKit, no simulation. That separation is the point (see the task brief): upstream's `Signal`
// is a `Transferable` for Swing drag-and-drop and carries an inner `Iterator` class that reaches
// back into its enclosing instance's private arrays. Neither is needed to hold values.
//
// ── Two deliberate divergences from Java, both stated rather than silent ────────────────────
//
// 1. **The 512-entry chunk array is gone.** `Signal` stores runs in `Value[][]` blocks of 512 so
//    that growth does not reallocate one large array. That is a JVM allocation strategy with no
//    observable behaviour: every access is `val[i / CHUNK][i % CHUNK]`, i.e. a flat index. A
//    Swift `Array` already grows geometrically, so the chunking would be pure ceremony; except
//    for `replaceRecent`'s "last chunk is now entirely empty, must be removed" branch, which
//    exists only to undo the chunking. Dropping it drops that branch with it.
//
// 2. **`resize` shrinking discards `curSize - newMax` runs, not `maxSize - newMax`.**
//    `Signal.resize` (Signal.java:191-200) computes `discard = maxSize - newMaxSize` and then
//    calls `retainOnly(discard, newMaxSize, newMaxSize)`, which reads `newMaxSize` runs starting
//    at `firstIndex + discard`. When the buffer is only *partly* full, `newMaxSize < curSize <
//    maxSize`, which is exactly what happens when a user lowers the history limit early in a run
//    , that walks past `curSize` and reads never-written `null` slots, and the modulo wraps it
//    back to the front, so the retained window is both short and out of order. It is a bug: the
//    intent, stated in its own comment, is "keep only most recent data". This port keeps the
//    most recent `newMaxSize` runs and advances `timeStart` past exactly the ones it dropped, so
//    the timeline stays continuous. Reproducing the Java would mean reproducing a null-pointer
//    read, which Swift has no way to express.
//
// ── D13 ─────────────────────────────────────────────────────────────────────────────────────
//
// `replaceRecent` is the one method that throws in Java (`IllegalStateException`, twice), and it
// is reachable from ordinary simulation: `Model.replaceWithNewValues` calls it on every coarse
// clocked update, with a duration derived from the clock component's `ATTR_HIGH`/`ATTR_LOW`
// attributes; i.e. from the `.circ` file. So it throws here too, and the model catches it
// rather than letting a malformed clock attribute kill the process.

import Foundation
import LogisimKernel

/// Errors from the signal history. D13: reachable from a `.circ`, therefore thrown.
public enum LogSignalHistoryError: Error, Equatable, CustomStringConvertible, Sendable {
  /// `replaceRecent` on a history with no runs at all.
  case noDataToReplace(requestedDuration: Int64)
  /// `replaceRecent` asked to back-date further than the history reaches.
  case insufficientHistory(requestedDuration: Int64, availableDuration: Int64)

  public var description: String {
    switch self {
    case .noDataToReplace(let d):
      "signal should have at least \(d) ns of data"
    case .insufficientHistory(let requested, let available):
      "signal data should be at least \(requested) ns in duration, but only \(available) in last signal"
    }
  }
}

/// One run of a constant value in a signal's history.
public struct LogSignalRun: Equatable, Sendable {
  public var value: Value
  /// Simulated nanoseconds this value held for. Always > 0 for a stored run.
  public var duration: Int64

  public init(value: Value, duration: Int64) {
    self.value = value
    self.duration = duration
  }
}

/// A cursor over a history, i.e. `Signal.Iterator`.
///
/// A `struct`, unlike Java's inner class, because it holds no reference back into the history;
/// it is a position plus the run it is sitting on. The log file writer keeps one of these per
/// signal across writes, and a value type makes that impossible to alias by accident.
public struct LogSignalCursor: Equatable, Sendable {
  /// Index of the run this cursor sits on, counted from the oldest retained run.
  public private(set) var position: Int
  /// Simulated time at the cursor.
  public private(set) var time: Int64
  /// Remaining duration of the current run from `time` onwards.
  public private(set) var duration: Int64
  /// `nil` once the cursor has run off the end, which is how Java signals exhaustion.
  public private(set) var value: Value?

  fileprivate init(position: Int, time: Int64, duration: Int64, value: Value?) {
    self.position = position
    self.time = time
    self.duration = duration
    self.value = value
  }

  /// `Iterator.getFormattedValue()`: `"-"` past the end, as upstream prints.
  public func formattedValue(radix: LogRadix) -> String {
    guard let value else { return "-" }
    return radix.format(value)
  }
}

/// `com.cburch.logisim.gui.log.Signal`'s data half: a bounded run-length history.
///
/// Reference semantics, matching Java: the model hands the same object to the table, the
/// chronogram and the file writer, and all three must see one history. A struct would give each
/// of them a private copy and the file would silently stop growing.
public final class LogSignalHistory {

  /// `timeStart`; the simulated time the oldest retained run begins at. Advances when runs are
  /// evicted by the history limit.
  public private(set) var timeStart: Int64

  /// `maxSize`; the history limit in *runs*, or 0 for unlimited. Matches Java's units: the
  /// limit counts value changes, not nanoseconds.
  public private(set) var maxSize: Int

  /// The retained runs, oldest first. Java's `firstIndex`/`curSize` ring is an in-place eviction
  /// scheme; `removeFirst` on a Swift `Array` is the same operation with the arithmetic done by
  /// the standard library.
  private var runs: [LogSignalRun] = []

  /// `last`: the value most recently extended with, used to coalesce equal consecutive values.
  /// Distinct from `runs.last?.value` only in the moment after `reset` clears the history.
  private var last: Value?

  /// Java's constructor: seeds the history with `initialValue` held for `duration`.
  public init(initialValue: Value, duration: Int64, timeStart: Int64 = 0, maxSize: Int = 0) {
    self.timeStart = timeStart
    self.maxSize = max(maxSize, 0)
    extend(initialValue, duration)
  }

  // MARK: - Reading

  /// `getSignalCount()`-adjacent: how many runs are retained.
  public var runCount: Int { runs.count }

  /// Every retained run, oldest first. The chronogram draws straight from this.
  public var allRuns: [LogSignalRun] { runs }

  /// `omittedDataTime()`; nonzero once the limit has started evicting, which is the signal the
  /// table and the chronogram use to avoid drawing a partial leading run.
  public var omittedDataTime: Int64 {
    maxSize != 0 && runs.count == maxSize ? timeStart : 0
  }

  /// `getEndTime()`: the simulated time just past the newest run.
  public var endTime: Int64 {
    runs.reduce(timeStart) { $0 + $1.duration }
  }

  /// `getValue(long)`: the value in force at time `t`, widened to `width`, or `nil` outside the
  /// retained window.
  ///
  /// `width` is passed in rather than stored because upstream reads it from the live
  /// `SignalInfo` on every call: a pin whose width attribute changes mid-run must render its
  /// *old* samples at the *new* width, which is what `extendWidth(width, FALSE)` does.
  public func value(at t: Int64, width: Int) -> Value? {
    guard t >= timeStart else { return nil }
    var cursorTime = timeStart
    for run in runs {
      if t < cursorTime + run.duration {
        return run.value.extendWidth(width, .falseValue)
      }
      cursorTime += run.duration
    }
    return nil
  }

  /// `getFormattedValue(long)`.
  public func formattedValue(at t: Int64, width: Int, radix: LogRadix) -> String {
    guard let v = value(at: t, width: width) else { return "-" }
    return radix.format(v)
  }

  // MARK: - Cursors

  /// `new Signal.Iterator()`: a cursor on the oldest retained run.
  public func makeCursor(width: Int) -> LogSignalCursor {
    guard let first = runs.first else {
      return LogSignalCursor(position: 0, time: timeStart, duration: 0, value: nil)
    }
    return LogSignalCursor(
      position: 0,
      time: timeStart,
      duration: first.duration,
      value: first.value.extendWidth(width, .falseValue)
    )
  }

  /// `new Signal.Iterator(long t)`: a cursor advanced to time `t`.
  public func makeCursor(at t: Int64, width: Int) -> LogSignalCursor {
    var cursor = makeCursor(width: width)
    if t > cursor.time {
      _ = advance(&cursor, by: t - cursor.time, width: width)
    }
    return cursor
  }

  /// `Iterator.advance()`: step to the next run. `false` once exhausted, which also nils the
  /// cursor's value exactly as Java does.
  @discardableResult
  public func advance(_ cursor: inout LogSignalCursor, width: Int) -> Bool {
    guard cursor.position < runs.count - 1 else {
      cursor = LogSignalCursor(
        position: cursor.position, time: cursor.time, duration: 0, value: nil)
      return false
    }
    let nextPosition = cursor.position + 1
    let nextTime = cursor.time + cursor.duration
    let run = runs[nextPosition]
    cursor = LogSignalCursor(
      position: nextPosition,
      time: nextTime,
      duration: run.duration,
      value: run.value.extendWidth(width, .falseValue)
    )
    return true
  }

  /// `Iterator.advance(long timeFwd)`: move forward by a simulated duration, consuming runs.
  @discardableResult
  public func advance(_ cursor: inout LogSignalCursor, by timeForward: Int64, width: Int) -> Bool {
    if cursor.value == nil { return false }
    if timeForward <= 0 { return true }
    let target = cursor.time + timeForward
    while target >= cursor.time + cursor.duration {
      if !advance(&cursor, width: width) { return false }
    }
    // Postcondition (Java's own comment): target - time < duration.
    cursor = LogSignalCursor(
      position: cursor.position,
      time: target,
      duration: cursor.duration - (target - cursor.time),
      value: cursor.value
    )
    return true
  }

  // MARK: - Writing

  /// `extend(long duration)`: hold the current value for longer without recording a change.
  public func extend(_ duration: Int64) {
    if last == nil || runs.isEmpty {
      timeStart += duration
    } else {
      runs[runs.count - 1].duration += duration
    }
  }

  /// `extend(Value v, long duration)`: record `v` as holding for `duration`.
  ///
  /// Equal consecutive values coalesce into one run, which is the whole reason the history is
  /// run-length encoded: a 1 Hz clock logged at fine granularity would otherwise store one run
  /// per gate delay.
  public func extend(_ value: Value, _ duration: Int64) {
    if let last, last == value, !runs.isEmpty {
      runs[runs.count - 1].duration += duration
      return
    }
    last = value
    if maxSize != 0 && runs.count >= maxSize {
      // Limit reached: drop the oldest run and pull `timeStart` forward past it, so the
      // retained window stays contiguous in simulated time.
      timeStart += runs[0].duration
      runs.removeFirst()
    }
    runs.append(LogSignalRun(value: value, duration: duration))
  }

  /// `replaceRecent(Value v, long duration)`; back-date the last `duration` of history to `v`.
  ///
  /// This is how coarse clocked capture works: transient values inside a clock period are
  /// discarded and the period is rewritten with whatever the circuit settled on.
  ///
  /// D13: throws rather than trapping. See the file header.
  public func replaceRecent(_ value: Value, _ duration: Int64) throws {
    guard last != nil, let lastRun = runs.last else {
      throw LogSignalHistoryError.noDataToReplace(requestedDuration: duration)
    }
    let lastIndex = runs.count - 1

    if lastRun.duration == duration {
      runs[lastIndex].value = value
      last = value
      // Coalesce with the run before it if that now carries the same value.
      if runs.count > 1, runs[lastIndex - 1].value == value {
        runs[lastIndex - 1].duration += duration
        runs.removeLast()
      }
    } else if lastRun.duration > duration {
      // Shorten the tail of the last run and append the replacement after it.
      runs[lastIndex].duration -= duration
      extend(value, duration)
    } else if runs.count == 1, lastRun.duration + timeStart >= duration {
      // Only one run, but there is enough elapsed time before it to absorb the shortfall.
      timeStart -= (duration - lastRun.duration)
      runs[lastIndex] = LogSignalRun(value: value, duration: duration)
      last = value
    } else {
      throw LogSignalHistoryError.insufficientHistory(
        requestedDuration: duration, availableDuration: lastRun.duration)
    }
  }

  /// `resize(int newMaxSize)`: change the history limit, keeping the most recent data.
  ///
  /// See divergence 2 in the file header for the shrink case.
  public func resize(_ newMaxSize: Int) {
    let normalised = max(newMaxSize, 0)
    if normalised == maxSize { return }
    if normalised != 0 && runs.count > normalised {
      let discard = runs.count - normalised
      for index in 0..<discard { timeStart += runs[index].duration }
      runs.removeFirst(discard)
    }
    maxSize = normalised
  }

  /// `reset(Value v, long duration)`; throw the history away and restart from `v`.
  ///
  /// Note `timeStart` is *not* reset here, matching Java: `Model.simulatorReset` sets
  /// `timeEnd = duration` separately, and the chronogram's origin comes from `getStartTime()`.
  public func reset(_ value: Value, _ duration: Int64) {
    runs.removeAll(keepingCapacity: true)
    last = nil
    extend(value, duration)
  }
}
