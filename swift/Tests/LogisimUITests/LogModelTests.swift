// LogModelTests: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// The point of these tests is that they exist at all: upstream's `Model` calls a modal dialog
// from its own constructor, so there is no way to construct one without a screen and no way to
// test any of this. Here the model is driven entirely by `ManualProbe`s, a real conformer of
// `LogSignalProbe`, not a mock, with no circuit, no simulation and no window.

import Foundation
import LogisimKernel
import Testing

@testable import LogisimUI

private func makeModel(
  _ probes: [ManualProbe],
  clock: ManualProbe? = nil
) -> (LogModel, [LogSignalInfo]) {
  var infos = probes.map { LogSignalInfo(probe: $0) }
  var clockInfo: LogSignalInfo?
  if let clock {
    let info = LogSignalInfo(probe: clock)
    clockInfo = info
    infos.append(info)
  }
  let model = LogModel(signals: infos, clockSource: clockInfo)
  return (model, infos)
}

/// Counts the events a model fires. Also the test that the subscription token is load-bearing.
private final class Recorder: LogModelListener {
  var reset = 0
  var extended = 0
  var selection = 0
  var mode = 0
  var fileProperty = 0
  var historyLimit = 0

  func logSignalsReset(_ model: LogModel) { reset += 1 }
  func logSignalsExtended(_ model: LogModel) { extended += 1 }
  func logSelectionChanged(_ model: LogModel) { selection += 1 }
  func logModeChanged(_ model: LogModel) { mode += 1 }
  func logFilePropertyChanged(_ model: LogModel) { fileProperty += 1 }
  func logHistoryLimitChanged(_ model: LogModel) { historyLimit += 1 }
}

@Suite("Log model — Model.java without the dialogs")
struct LogModelTests {

  @Test("A fresh model seeds one run per signal at the time scale")
  func seeds() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    #expect(model.signalCount == 1)
    #expect(model.mode == .step)
    #expect(model.endTime == model.timeScale)
    #expect(model.rows[0].history.runCount == 1)
  }

  @Test("A clock source is moved to the top and puts the model in CLOCK_DUAL")
  func clockSourceGoesFirst() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let clk = ManualProbe(name: "clk", width: 1, value: .falseValue)
    let (model, _) = makeModel([a], clock: clk)
    #expect(model.mode == .clockDual)
    #expect(model.rows.first?.info.shortName == "clk")
    #expect(model.clockSource?.shortName == "clk")
  }

  // MARK: step mode

  @Test("Step mode records a timeScale-long run when propagation settled")
  func stepModeSettled() throws {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let start = model.endTime

    a.currentValue = .trueValue
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    #expect(model.endTime == start + model.timeScale)
    #expect(model.rows[0].history.runCount == 2)
    #expect(model.rows[0].history.value(at: start, width: 1) == .trueValue)
  }

  @Test("Coarse capture ignores an unsettled propagation entirely")
  func coarseIgnoresTransient() throws {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let start = model.endTime

    a.currentValue = .trueValue
    try model.propagationCompleted(ticked: false, stepped: true, propagated: false)
    #expect(model.endTime == start)
    #expect(model.rows[0].history.runCount == 1)
  }

  @Test("Fine capture records an unsettled propagation as a gateDelay-long run")
  func fineRecordsTransient() throws {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    model.setStepMode(fine: true, timeScale: 5000, gateDelay: 200)
    let start = model.endTime

    a.currentValue = .trueValue
    try model.propagationCompleted(ticked: false, stepped: true, propagated: false)
    #expect(model.endTime == start + 200)
  }

  @Test("A nudge that changed nothing records nothing")
  func nudgeRecordsNothing() throws {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let start = model.endTime
    try model.propagationCompleted(ticked: false, stepped: false, propagated: false)
    #expect(model.endTime == start)
  }

  // MARK: clocked mode

  @Test("Coarse dual-edge capture back-dates the settled value over the whole clock period")
  func clockedCoarseBackDates() throws {
    let d = ManualProbe(name: "d", width: 1, value: .falseValue)
    let clk = ManualProbe(name: "clk", width: 1, value: .falseValue)
    let (model, _) = makeModel([d], clock: clk)
    // Default cycle is 1 high / 1 low, so one edge is worth one timeScale.
    let afterReset = model.endTime

    // Same clock level, coarse: this is a transient and is back-dated, not appended.
    d.currentValue = .trueValue
    try model.propagationCompleted(ticked: false, stepped: true, propagated: true)
    #expect(model.endTime == afterReset)
    #expect(model.rows.first(where: { $0.info.shortName == "d" })?.history.runCount == 1)

    // Clock edge: a new period starts and the values are appended.
    clk.currentValue = .trueValue
    try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    #expect(model.endTime > afterReset)
  }

  // MARK: selection editing

  @Test("add, remove and move keep row indices consistent")
  func selectionEditing() {
    let probes = (0..<4).map { ManualProbe(name: "p\($0)", width: 1, value: .falseValue) }
    let (model, infos) = makeModel(probes)
    #expect(model.rows.map(\.index) == [0, 1, 2, 3])

    model.move(from: [3], to: 0)
    #expect(model.rows.map(\.info.shortName) == ["p3", "p0", "p1", "p2"])
    #expect(model.rows.map(\.index) == [0, 1, 2, 3])

    model.remove([infos[0]])
    #expect(model.rows.map(\.info.shortName) == ["p3", "p1", "p2"])
    #expect(model.rows.map(\.index) == [0, 1, 2])

    let extra = LogSignalInfo(probe: ManualProbe(name: "new", width: 1, value: .falseValue))
    model.add([extra])
    #expect(model.rows.last?.info.shortName == "new")
    #expect(model.rows.last?.index == 3)
  }

  @Test("A new row starts one nanosecond before the current end, so it lines up")
  func newRowLinesUp() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let extra = LogSignalInfo(probe: ManualProbe(name: "b", width: 1, value: .trueValue))
    model.add([extra])
    let row = model.rows.last!
    #expect(row.history.timeStart == model.endTime - 1)
  }

  @Test("Out-of-range indices are ignored, never trapped (D13)")
  func outOfRangeIsSafe() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    model.remove(at: 99)
    model.remove(at: -1)
    model.move(from: [7], to: 0)
    model.addOrMove([], at: 500)
    #expect(model.signalCount == 1)
    #expect(model.row(at: 99) == nil)
  }

  // MARK: listeners

  @Test("A stored token receives events; dropping the token unsubscribes")
  func subscriptionTokenIsTheLifetime() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let recorder = Recorder()

    var token: LogModelSubscription? = model.addListener(recorder)
    model.setHistoryLimit(50)
    #expect(recorder.historyLimit == 1)

    token?.cancel()
    token = nil
    model.setHistoryLimit(60)
    #expect(recorder.historyLimit == 1, "cancelling the token must stop delivery")
  }

  @Test("An unstored token is a dead subscription — the failure mode, pinned")
  func unstoredTokenIsDead() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let recorder = Recorder()

    _ = model.addListener(recorder)  // token dropped immediately
    model.setHistoryLimit(50)
    #expect(
      recorder.historyLimit == 0,
      "the model must hold listeners weakly through the token, per D3/D5")
  }

  @Test("Mode changes reset the history and fire the right events")
  func modeChangeResets() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let recorder = Recorder()
    let token = model.addListener(recorder)

    a.currentValue = .trueValue
    model.setStepMode(fine: true, timeScale: 1000, gateDelay: 50)
    #expect(model.timeScale == 1000)
    #expect(model.gateDelay == 50)
    #expect(model.isFine)
    #expect(recorder.mode == 1)
    #expect(recorder.reset >= 1)
    // `Model.simulatorReset`'s STEP arm is `duration = timeScale` regardless of granularity;
    // only the *clocked* arms consult `isFine()`. Reseeding at `gateDelay` here would be a
    // divergence, so the new time scale is what the history restarts with.
    #expect(model.endTime == 1000)
    token.cancel()
  }

  @Test("setClockMode with no candidate stays where it was rather than half-entering a mode")
  func clockModeWithoutCandidate() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    #expect(model.mode == .step)
    model.setClockMode(fine: false, discipline: .clockRising, timeScale: 5000, gateDelay: 200)
    #expect(model.mode == .step)
    #expect(model.clockSource == nil)
  }

  @Test("setClockMode adopts the single candidate the provider offers, and adds it as a row")
  func clockModeAdoptsCandidate() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    let clk = LogSignalInfo(probe: ManualProbe(name: "clk", width: 1, value: .falseValue))
    model.clockCandidateProvider = { [clk] }

    model.setClockMode(fine: false, discipline: .clockRising, timeScale: 5000, gateDelay: 200)
    #expect(model.mode == .clockRising)
    #expect(model.clockSource === clk)
    #expect(model.rows.first?.info === clk, "the clock is added at the top as a courtesy")
  }

  @Test("The history limit resizes every signal")
  func historyLimitResizes() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    model.setHistoryLimit(3)
    #expect(model.rows[0].history.maxSize == 3)
    #expect(model.historyLimit == 3)
  }

  @Test("startTime follows the earliest data any signal still holds")
  func startTimeFollowsEviction() throws {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    model.setHistoryLimit(2)
    for step in 0..<5 {
      a.currentValue = step.isMultiple(of: 2) ? .trueValue : .falseValue
      try model.propagationCompleted(ticked: true, stepped: true, propagated: true)
    }
    #expect(model.startTime > 0)
    #expect(model.rows[0].history.runCount == 2)
  }

  // MARK: file properties

  @Test("isWritingToFile is the conjunction upstream's LogThread.writing() computes")
  func writingGate() {
    let a = ManualProbe(name: "a", width: 1, value: .falseValue)
    let (model, _) = makeModel([a])
    #expect(model.isWritingToFile == false)

    model.setSelected(true)
    #expect(model.isWritingToFile == false, "no file yet")

    model.setFileURL(URL(fileURLWithPath: "/tmp/does-not-need-to-exist.log"))
    #expect(model.isFileEnabled, "setFile enables recording, as setFile does upstream")
    #expect(model.isWritingToFile)

    model.setFileEnabled(false)
    #expect(model.isWritingToFile == false)

    model.setFileEnabled(true)
    model.setSelected(false)
    #expect(model.isFileEnabled == false, "deselecting disables the file")
    #expect(model.isWritingToFile == false)
  }
}
