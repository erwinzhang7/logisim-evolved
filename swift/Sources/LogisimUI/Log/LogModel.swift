// LogModel.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.Model),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── This file is the whole log, minus the window ────────────────────────────────────────────
//
// Which signals are selected, what they have been worth over simulated time, when a sample is
// taken, and what gets written to a file. No AppKit, no SwiftUI, no `@MainActor`: everything
// here runs anywhere and is exercised by `LogisimUITests` with no window and no simulation.
// Upstream mixes this with Swing because `Model` is constructed by `LogFrame` and calls
// `ClockSource.doClockMultipleObserverDialog`, a *modal dialog*, from inside its own
// constructor and from `setClockMode`. That is the thing the task brief says not to reproduce:
// a model that cannot be constructed without a screen cannot be tested, and D17 shows what it
// costs (155 of 594 corpus files blocked on modal dialogs).
//
// The dialog is replaced by a `clockSourceChooser` closure. It defaults to "pick the first
// candidate", which is upstream's behaviour whenever exactly one clock exists: the common case
// , and a host with a window installs one that asks. That is the seam, and both ends of it are
// filled in: the default here, and `LogWindow`'s installation of a real picker.
//
// ── Ownership (D3) ──────────────────────────────────────────────────────────────────────────
//
// | edge                                | kind      | strength |
// |-------------------------------------|-----------|----------|
// | `LogModel` → rows (info + history)  | owning    | strong   |
// | `LogSignalInfo` → probe             | owning    | strong   |
// | `CircuitPointProbe` → CircuitState  | back edge | weak     |
// | `LogModel` → listeners              | via token | weak     |
//
// The listener list follows D5's subscription pattern: `addListener` hands back a token, the
// model holds it weakly, and dropping the token unsubscribes. An unstored token is a dead
// subscription; that is stated on the return value, because it is the mistake this pattern
// invites.

import Foundation
import LogisimKernel

// MARK: - Listener

/// `Model.Listener`. Every method defaults to a no-op, as upstream's interface does.
public protocol LogModelListener: AnyObject {
  /// `signalsReset`; the history was thrown away and restarted.
  func logSignalsReset(_ model: LogModel)
  /// `signalsExtended`; new samples were appended (or back-dated).
  func logSignalsExtended(_ model: LogModel)
  /// `filePropertyChanged`: the export file, its enabled flag, or its header flag changed.
  func logFilePropertyChanged(_ model: LogModel)
  /// `selectionChanged`: rows were added, removed, reordered, renamed or re-radixed.
  func logSelectionChanged(_ model: LogModel)
  /// `modeChanged`.
  func logModeChanged(_ model: LogModel)
  /// `historyLimitChanged`.
  func logHistoryLimitChanged(_ model: LogModel)
}

extension LogModelListener {
  public func logSignalsReset(_ model: LogModel) {}
  public func logSignalsExtended(_ model: LogModel) {}
  public func logFilePropertyChanged(_ model: LogModel) {}
  public func logSelectionChanged(_ model: LogModel) {}
  public func logModeChanged(_ model: LogModel) {}
  public func logHistoryLimitChanged(_ model: LogModel) {}
}

/// The token `LogModel.addListener` returns.
///
/// **Store it.** The model holds it weakly; a token that is not kept alive unsubscribes
/// immediately and the listener silently never fires. Mirrors `AttributeSubscription` (D5),
/// `ComponentSubscription` and `CircuitSubscription`.
public final class LogModelSubscription {
  fileprivate let listener: any LogModelListener
  private let onCancel: () -> Void
  private var cancelled = false

  fileprivate init(listener: any LogModelListener, onCancel: @escaping () -> Void) {
    self.listener = listener
    self.onCancel = onCancel
  }

  /// Unsubscribe now. Idempotent.
  public func cancel() {
    guard !cancelled else { return }
    cancelled = true
    onCancel()
  }

  deinit { cancel() }
}

// MARK: - Rows

/// One row of the log: a selected signal and its history.
///
/// Java keeps `ArrayList<SignalInfo> info` and `ArrayList<Signal> signals` in lockstep and
/// indexes both with the same integer, in eleven methods. Pairing them makes the two impossible
/// to desync; a class of bug `Model.addOrMove` is one `remove` away from at all times.
public final class LogRow: Identifiable {
  public let info: LogSignalInfo
  public let history: LogSignalHistory

  /// `Signal.idx`: the row's position, renumbered on every reorder. Kept because the chronogram
  /// colours rows by index and the file writer orders columns by it.
  public internal(set) var index: Int

  public var id: UUID { info.id }

  init(info: LogSignalInfo, history: LogSignalHistory, index: Int) {
    self.info = info
    self.history = history
    self.index = index
  }
}

// MARK: - The model

/// `com.cburch.logisim.gui.log.Model`.
public final class LogModel {

  // MARK: Stored state

  /// `signals` / `info`, fused. Ordered; the order is the table's column order and the
  /// chronogram's row order.
  public private(set) var rows: [LogRow] = []

  /// `timeEnd`: signals span `0 <= t < timeEnd` in simulated nanoseconds.
  public private(set) var endTime: Int64 = 0

  /// `mode`.
  public private(set) var mode: LogCaptureMode = .step

  /// `granularity`.
  public private(set) var granularity: LogGranularity = .coarse

  /// `timeScale`; simulated nanoseconds per tick. Upstream's default is 5000.
  public private(set) var timeScale: Int64 = 5000

  /// `gateDelay`; simulated nanoseconds per propagation step. Upstream's default is 200.
  public private(set) var gateDelay: Int64 = 200

  /// `historyLimit`; retained runs per signal, 0 for unlimited. Upstream's default is 400.
  public private(set) var historyLimit: Int = 400

  /// `clockSource`.
  public private(set) var clockSource: LogSignalInfo?

  /// `curClockVal`.
  private var currentClockValue: Value = .unknownValue

  /// `elapsedSinceTrigger`.
  private var elapsedSinceTrigger: Int64 = 0

  /// `lastRealtimeUpdate`, in nanoseconds since an arbitrary origin.
  private var lastRealtimeUpdate: UInt64 = 0

  /// `spotlight`; the row under the pointer in the chronogram. Upstream's own comment says this
  /// "maybe should be put elsewhere"; it stays here because the file writer's `selectionChanged`
  /// handler and the chronogram both read it, and a second owner would need a second listener.
  public var spotlight: LogRow?

  // MARK: File export state

  /// `file`.
  public private(set) var fileURL: URL?
  /// `fileEnabled`.
  public private(set) var isFileEnabled = false
  /// `fileHeader`.
  public private(set) var writesFileHeader = true
  /// `selected`; whether this model is the one the Log window is showing, which is what gates
  /// the writer in upstream (`LogThread.writing()`).
  public private(set) var isSelected = false

  // MARK: Seams

  /// `ClockSource.getCycleInfo(SignalInfo)`.
  ///
  /// A closure because reading a `Clock`'s `ATTR_HIGH`/`ATTR_LOW`/`ATTR_PHASE` needs LogisimStd,
  /// and this file deliberately imports only the kernel so the model stays testable in
  /// isolation. `LogClockSource.cycleProvider` is the real implementation and is what
  /// `LogSignalDiscovery` installs; the default below is upstream's `DEFAULT_CYCLE_INFO`, which
  /// is also what upstream falls back to for any non-`Clock` source.
  public var clockCycleProvider: (LogSignalInfo) -> LogClockCycle = { _ in .default }

  /// Replaces `ClockSource.doClockMultipleObserverDialog`. Given the candidates, return the one
  /// to use, or `nil` to stay in the current mode. The default takes the first, which is
  /// upstream's behaviour whenever there is exactly one candidate and a reasonable answer when
  /// there are several; `LogWindow` installs a picker.
  public var clockSourceChooser: ([LogSignalInfo]) -> LogSignalInfo? = { $0.first }

  /// Candidate clock sources, re-evaluated whenever one is needed.
  /// `ComponentSelector.findClocks(Circuit)`.
  public var clockCandidateProvider: () -> [LogSignalInfo] = { [] }

  // MARK: Listeners

  private struct ListenerEntry {
    let identifier: UInt64
    weak var token: LogModelSubscription?
  }
  private var listenerEntries: [ListenerEntry] = []
  private var nextListenerIdentifier: UInt64 = 1

  // MARK: - Construction

  /// Builds an empty model. Signals are added with `addOrMove`; `LogSignalDiscovery` produces the
  /// default selection upstream's constructor builds inline.
  public init() {}

  /// Builds a model over an initial selection, mirroring what `Model(CircuitState)` ends up with
  /// once its component scan and sort have run.
  ///
  /// - Parameters:
  ///   - signals: the initial rows, already ordered (inputs first: see `LogSignalDiscovery`).
  ///   - clockSource: the clock to observe, if one was found. A non-`nil` value puts the model
  ///     into `CLOCK_DUAL` and moves the clock to the top of the list, exactly as upstream does.
  public convenience init(signals: [LogSignalInfo], clockSource: LogSignalInfo? = nil) {
    self.init()
    var ordered = signals
    if let clockSource {
      self.clockSource = clockSource
      if let existing = ordered.firstIndex(where: { $0 === clockSource }) {
        ordered.remove(at: existing)
      }
      ordered.insert(clockSource, at: 0)
      mode = .clockDual
      currentClockValue = clockSource.fetchValue()
    }

    // `final var duration = captureContinuous() ? gateDelay : timeScale;`
    let duration = captureContinuous ? gateDelay : timeScale
    for (index, info) in ordered.enumerated() {
      let history = LogSignalHistory(
        initialValue: info.fetchValue(),
        duration: duration,
        timeStart: 0,
        maxSize: historyLimit
      )
      rows.append(LogRow(info: info, history: history, index: index))
    }
    endTime = duration
  }

  // MARK: - Listener registration

  /// `addModelListener`. **Store the returned token**, see `LogModelSubscription`.
  @discardableResult
  public func addListener(_ listener: any LogModelListener) -> LogModelSubscription {
    let identifier = nextListenerIdentifier
    nextListenerIdentifier += 1
    let token = LogModelSubscription(listener: listener) { [weak self] in
      self?.listenerEntries.removeAll { $0.identifier == identifier }
    }
    listenerEntries.append(ListenerEntry(identifier: identifier, token: token))
    return token
  }

  private func liveListeners() -> [any LogModelListener] {
    listenerEntries.removeAll { $0.token == nil }
    return listenerEntries.compactMap { $0.token?.listener }
  }

  private func fireSignalsReset() { for l in liveListeners() { l.logSignalsReset(self) } }
  private func fireSignalsExtended() { for l in liveListeners() { l.logSignalsExtended(self) } }
  private func fireFilePropertyChanged() {
    for l in liveListeners() { l.logFilePropertyChanged(self) }
  }
  private func fireSelectionChanged() { for l in liveListeners() { l.logSelectionChanged(self) } }
  private func fireModeChanged() { for l in liveListeners() { l.logModeChanged(self) } }
  private func fireHistoryLimitChanged() {
    for l in liveListeners() { l.logHistoryLimitChanged(self) }
  }

  // MARK: - Reading

  /// `getSignalCount()`.
  public var signalCount: Int { rows.count }

  /// `getSignals()`.
  public var signals: [LogSignalInfo] { rows.map(\.info) }

  /// `getItem(int)` / `getSignal(int)`, bounds-checked. D13: a stale index from a view that has
  /// not yet redrawn must not trap.
  public func row(at index: Int) -> LogRow? {
    rows.indices.contains(index) ? rows[index] : nil
  }

  /// `indexOf(SignalInfo)`: identity, not equality (D4's reasoning: these are reference
  /// identities into the circuit).
  public func index(of info: LogSignalInfo) -> Int? {
    rows.firstIndex { $0.info === info }
  }

  /// `getSignal(SignalInfo)`.
  public func row(for info: LogSignalInfo) -> LogRow? {
    rows.first { $0.info === info }
  }

  /// `getStartTime()`; the earliest time any signal still holds data for. Nonzero once the
  /// history limit has begun evicting; the table and the chronogram start there so a partially
  /// evicted leading run is not drawn as if it were complete.
  public var startTime: Int64 {
    rows.reduce(Int64(0)) { max($0, $1.history.omittedDataTime) }
  }

  /// `isFine()` / `isCoarse()`.
  public var isFine: Bool { granularity == .fine }
  public var isCoarse: Bool { granularity != .fine }

  /// `captureContinuous()`; whether every propagation is worth its own run.
  private var captureContinuous: Bool {
    isFine
      || (mode == .clockHigh && currentClockValue == .trueValue)
      || (mode == .clockLow && currentClockValue == .falseValue)
  }

  // MARK: - Selection editing

  /// `addOrMove(List<SignalInfo>, int)`: insert new signals at `index`, or move existing ones
  /// there.
  ///
  /// `index` is clamped rather than trusted: it arrives from a drag-and-drop drop target, and
  /// D13 forbids trapping on a bad one.
  public func addOrMove(_ items: [LogSignalInfo], at index: Int) {
    var insertAt = min(max(index, 0), rows.count)
    var changed = 0

    for item in items {
      if let existing = self.index(of: item) {
        if existing > insertAt {
          let row = rows.remove(at: existing)
          rows.insert(row, at: insertAt)
          insertAt += 1
          changed += 1
        } else if existing < insertAt {
          let row = rows.remove(at: existing)
          rows.insert(row, at: insertAt - 1)
          changed += 1
        }
        // existing == insertAt: already in place, upstream counts it as unchanged.
      } else {
        // `new Signal(idx, item, item.fetchValue(...), 1, timeEnd - 1, historyLimit)`: a new row
        // starts one nanosecond before the current end, so it lines up with everything else.
        let history = LogSignalHistory(
          initialValue: item.fetchValue(),
          duration: 1,
          timeStart: max(endTime - 1, 0),
          maxSize: historyLimit
        )
        rows.insert(LogRow(info: item, history: history, index: insertAt), at: insertAt)
        insertAt += 1
        changed += 1
      }
    }

    if changed > 0 {
      renumber()
      fireSelectionChanged()
    }
  }

  /// `addOrMove` at the end: the ordinary "add this signal to the log" call.
  public func add(_ items: [LogSignalInfo]) {
    addOrMove(items, at: rows.count)
  }

  /// `remove(List<SignalInfo>)`; returns how many were actually removed.
  @discardableResult
  public func remove(_ items: [LogSignalInfo]) -> Int {
    var count = 0
    for item in items {
      guard let index = self.index(of: item) else { continue }
      if let spotlight, spotlight.info === item { self.spotlight = nil }
      rows.remove(at: index)
      count += 1
    }
    if count > 0 {
      renumber()
      fireSelectionChanged()
    }
    return count
  }

  /// `remove(int)`. Out-of-range is ignored, not trapped (D13).
  public func remove(at index: Int) {
    guard rows.indices.contains(index) else { return }
    if let spotlight, spotlight === rows[index] { self.spotlight = nil }
    rows.remove(at: index)
    renumber()
    fireSelectionChanged()
  }

  /// `move(int[] fromIndex, int toIndex)`: the multi-row drag in the selection list.
  public func move(from indices: [Int], to destination: Int) {
    let sorted = indices.sorted()
    guard let first = sorted.first, let last = sorted.last else { return }
    guard first >= 0, last < rows.count else { return }
    // Upstream's no-op test: a contiguous block already spanning the destination.
    if first <= destination, destination <= last, last - first + 1 == sorted.count { return }

    var target = destination
    var lifted: [LogRow] = []
    for index in sorted.reversed() {
      if index < target { target -= 1 }
      lifted.append(rows.remove(at: index))
    }
    for row in lifted.reversed() {
      rows.insert(row, at: min(target, rows.count))
      target += 1
    }
    renumber()
    fireSelectionChanged()
  }

  /// `setRadix(SignalInfo, RadixOption)`.
  public func setRadix(_ radix: LogRadix, for info: LogSignalInfo) {
    if info.setRadix(radix) { fireSelectionChanged() }
  }

  private func renumber() {
    for (index, row) in rows.enumerated() { row.index = index }
  }

  // MARK: - Mode and limits

  /// `setHistoryLimit(int)`.
  public func setHistoryLimit(_ limit: Int) {
    let normalised = max(limit, 0)
    if historyLimit == normalised { return }
    historyLimit = normalised
    for row in rows { row.history.resize(normalised) }
    fireHistoryLimitChanged()
  }

  /// `setStepMode(boolean fine, long t, long d)`.
  public func setStepMode(fine: Bool, timeScale t: Int64, gateDelay d: Int64) {
    let g: LogGranularity = fine ? .fine : .coarse
    if mode == .step && granularity == g && timeScale == t && gateDelay == d { return }
    timeScale = t
    gateDelay = d
    setMode(.step, g)
  }

  /// `setRealMode(long t, boolean fine)`.
  public func setRealTimeMode(timeScale t: Int64, fine: Bool) {
    let g: LogGranularity = fine ? .fine : .coarse
    if mode == .realTime && granularity == g && timeScale == t { return }
    timeScale = t
    setMode(.realTime, g)
  }

  /// `setClockMode(boolean fine, int discipline, long t, long d)`.
  ///
  /// The modal-dialog branch is the `clockSourceChooser` seam; see the file header. If no source
  /// can be chosen, upstream returns to the previous mode, and so does this.
  public func setClockMode(
    fine: Bool, discipline: LogCaptureMode, timeScale t: Int64, gateDelay d: Int64
  ) {
    let g: LogGranularity = fine ? .fine : .coarse
    guard discipline.isClocked else {
      // Upstream cannot express this: `discipline` is an int and the caller passes a CLOCK_*
      // constant. Refusing is better than silently entering STEP under a clocked name.
      return
    }
    if clockSource != nil && mode == discipline && granularity == g && timeScale == t
      && gateDelay == d
    {
      return
    }

    if clockSource == nil {
      let candidates = clockCandidateProvider()
      let chosen = candidates.count == 1 ? candidates[0] : clockSourceChooser(candidates)
      guard let chosen else {
        setMode(mode, granularity)  // upstream: "go back to current mode"
        return
      }
      clockSource = chosen
      // "Add the clock as a courtesy, even though this is not required."
      if index(of: chosen) == nil {
        let history = LogSignalHistory(
          initialValue: chosen.fetchValue(),
          duration: 1,
          timeStart: max(endTime - 1, 0),
          maxSize: historyLimit
        )
        rows.insert(LogRow(info: chosen, history: history, index: 0), at: 0)
        renumber()
        fireSelectionChanged()
      }
    }

    timeScale = t
    gateDelay = d
    setMode(discipline, g)
  }

  /// `setClockSourceInfo(SignalInfo)`.
  public func setClockSource(_ info: LogSignalInfo?) {
    if clockSource === info { return }
    clockSource = info
    fireModeChanged()
  }

  private func setMode(_ m: LogCaptureMode, _ g: LogGranularity) {
    mode = m
    granularity = g
    simulatorReset()
    // Upstream's own comment: "reset, not extended, but works fine for now". Both are fired
    // here because the file writer distinguishes them: a reset rewinds its cursor.
    fireSignalsReset()
    fireSignalsExtended()
    fireModeChanged()
  }

  // MARK: - File export properties

  /// `setFile(File)`.
  public func setFileURL(_ value: URL?) {
    if fileURL == value { return }
    fileURL = value
    isFileEnabled = value != nil
    fireFilePropertyChanged()
  }

  /// `setFileEnabled(boolean)`.
  public func setFileEnabled(_ value: Bool) {
    if isFileEnabled == value { return }
    isFileEnabled = value
    fireFilePropertyChanged()
  }

  /// `setFileHeader(boolean)`.
  public func setFileHeader(_ value: Bool) {
    if writesFileHeader == value { return }
    writesFileHeader = value
    fireFilePropertyChanged()
  }

  /// `setSelected(boolean)`.
  ///
  /// Upstream starts and stops a `LogThread` here. This port has no thread: `LogFileExporter`
  /// writes synchronously on whatever thread the sample arrives on and flushes on a schedule the
  /// host owns, which removes both the shared-mutable-state lock and the "file is still open ten
  /// seconds after the window closed" behaviour. Deselecting still disables the file, exactly as
  /// upstream does.
  public func setSelected(_ value: Bool) {
    if isSelected == value { return }
    isSelected = value
    if !isSelected { isFileEnabled = false }
    fireFilePropertyChanged()
  }

  /// `LogThread.writing()`; whether a sample should be appended to the file right now.
  public var isWritingToFile: Bool {
    isSelected && isFileEnabled && fileURL != nil
  }

  // MARK: - Sampling

  /// `propagationCompleted(boolean ticked, boolean stepped, boolean propagated)`.
  ///
  /// The one entry point the simulator drives. D13: `throws`, because the coarse clocked path
  /// calls `replaceRecent`, whose duration comes from a `Clock` component's attributes and can
  /// therefore be shorter than the recorded history for a malformed file. Upstream throws
  /// `IllegalStateException` there and `Simulator` catches it into a circuit error; a trap would
  /// take the process down with the user's unsaved circuit.
  public func propagationCompleted(ticked: Bool, stepped: Bool, propagated: Bool) throws {
    if !stepped && !propagated {
      // A nudge that changed nothing, or a tick that has not propagated yet.
      return
    }
    if isCoarse && !propagated {
      // A transient fluctuation coarse capture ignores entirely.
      return
    }
    switch mode {
    case .step:
      extendWithNewValues(propagated ? timeScale : gateDelay)
    case .realTime:
      updateRealTime()
    default:
      try updateClocked()
    }
  }

  /// `simulatorReset()`: throw the history away and restart at the current values.
  public func simulatorReset() {
    let duration: Int64
    if mode.isClocked {
      currentClockValue = clockSource?.fetchValue() ?? .unknownValue
      let cycle = clockSource.map { clockCycleProvider($0) } ?? .default
      if captureContinuous {
        duration = gateDelay
      } else if mode.isLevelSensitive {
        let stable = Int64(mode == .clockHigh ? cycle.low : cycle.high) * timeScale
        duration = isFine ? gateDelay : stable
      } else {
        let ticks =
          mode == .clockDual
          ? (currentClockValue == .falseValue ? cycle.low : cycle.high)
          : cycle.ticks
        duration = isFine ? gateDelay : Int64(ticks) * timeScale
      }
    } else if mode == .step {
      duration = timeScale
    } else {
      duration = gateDelay
    }

    if mode == .realTime { lastRealtimeUpdate = LogModel.monotonicNanoseconds() }
    elapsedSinceTrigger = 0
    for row in rows {
      row.history.reset(row.info.fetchValue(), duration)
    }
    elapsedSinceTrigger += duration
    endTime = duration
    fireSignalsReset()
  }

  /// `checkForClocks()`; the user picked a temporary clock after the model had given up on
  /// finding one, so re-enter clocked mode with it.
  public func adoptClockSource(_ info: LogSignalInfo) {
    if clockSource === info { return }
    clockSource = nil
    setStepMode(fine: isFine, timeScale: timeScale, gateDelay: gateDelay)
    clockSource = info
    setClockMode(fine: isFine, discipline: .clockDual, timeScale: timeScale, gateDelay: gateDelay)
  }

  // MARK: Sampling internals

  /// `extendWithOldValues(long)`. Note upstream fetches each value and then discards it; the
  /// fetch is dead code there and is not reproduced.
  private func extendWithOldValues(_ duration: Int64) {
    for row in rows { row.history.extend(duration) }
    elapsedSinceTrigger += duration
    endTime += duration
    fireSignalsExtended()
  }

  /// `extendWithNewValues(long)`.
  private func extendWithNewValues(_ duration: Int64) {
    for row in rows { row.history.extend(row.info.fetchValue(), duration) }
    elapsedSinceTrigger += duration
    endTime += duration
    fireSignalsExtended()
  }

  /// `replaceWithNewValues(long)`.
  private func replaceWithNewValues(_ duration: Int64) throws {
    for row in rows {
      try row.history.replaceRecent(row.info.fetchValue(), duration)
    }
    fireSignalsExtended()
  }

  /// `updateSignalsRealMode()`.
  private func updateRealTime() {
    let now = LogModel.monotonicNanoseconds()
    let elapsed = now >= lastRealtimeUpdate ? now - lastRealtimeUpdate : 0
    let scaled = Double(elapsed) * Double(timeScale) / 1_000_000_000.0
    extendWithNewValues(max(Int64(scaled), 1))
    lastRealtimeUpdate = now
  }

  /// `updateSignalsClockMode()`.
  ///
  /// Transcribed branch for branch, because the arithmetic here is what makes a chronogram line
  /// up with the clock rather than drifting a gate delay per cycle.
  private func updateClocked() throws {
    guard let clockSource else { return }
    let v = clockSource.fetchValue()
    let cycle = clockCycleProvider(clockSource)

    let activeHigh = mode == .clockHigh
    if (mode == .clockHigh && v == .trueValue) || (mode == .clockLow && v == .falseValue) {
      // Active level-sensitive clock.
      let activeDuration = Int64(activeHigh ? cycle.high : cycle.low) * timeScale
      let stableDuration = Int64(activeHigh ? cycle.low : cycle.high) * timeScale
      if v != currentClockValue {
        if elapsedSinceTrigger < activeDuration {
          extendWithOldValues(stableDuration - elapsedSinceTrigger)
        }
        elapsedSinceTrigger = 0
        currentClockValue = v
      }
      extendWithNewValues(gateDelay)
    } else if mode.isLevelSensitive {
      // Inactive level-sensitive clock.
      let activeDuration = Int64(activeHigh ? cycle.high : cycle.low) * timeScale
      let stableDuration = Int64(activeHigh ? cycle.low : cycle.high) * timeScale
      if v != currentClockValue {
        if elapsedSinceTrigger < activeDuration {
          extendWithOldValues(activeDuration - elapsedSinceTrigger)
        }
        elapsedSinceTrigger = 0
        currentClockValue = v
        extendWithNewValues(isFine ? gateDelay : stableDuration)
      } else if isCoarse {
        try replaceWithNewValues(stableDuration)
      } else {
        extendWithNewValues(gateDelay)
      }
    } else {
      // Edge-triggered.
      let ticks =
        mode == .clockDual ? (v == .falseValue ? cycle.low : cycle.high) : cycle.ticks
      let previousTicks =
        mode == .clockDual ? (v == .falseValue ? cycle.high : cycle.low) : cycle.ticks
      let stableDuration = timeScale * Int64(ticks)
      let previousDuration = timeScale * Int64(previousTicks)
      let duration = isFine ? gateDelay : stableDuration
      let triggered =
        (mode == .clockDual && v != currentClockValue)
        || (mode == .clockRising && v == .trueValue && currentClockValue != .trueValue)
        || (mode == .clockFalling && v == .falseValue && currentClockValue != .falseValue)
      currentClockValue = v
      if triggered {
        if isFine && elapsedSinceTrigger < previousDuration {
          extendWithOldValues(previousDuration - elapsedSinceTrigger)
        }
        elapsedSinceTrigger = 0
        extendWithNewValues(duration)
      } else if isCoarse {
        try replaceWithNewValues(stableDuration)
      } else {
        extendWithNewValues(duration)
      }
    }
  }

  /// `System.nanoTime()`: a monotonic clock, not a wall clock. `Date` is wall time and steps
  /// backwards when the system clock is adjusted, which would produce a negative duration and a
  /// corrupt timeline.
  static func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  }
}
