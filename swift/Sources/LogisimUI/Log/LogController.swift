// LogController.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.{LogFrame, LogPanel,
// LogMenuListener}: the coordination they perform, not their Swing structure),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The line between this file and LogModel ─────────────────────────────────────────────────
//
// `LogModel` is the log. This is the *window's* relationship to it: which tab is showing, which
// rows the user has selected in the list, where the chronogram cursor is, and, the load-bearing
// part, **the subscription tokens**.
//
// Three tokens have to be stored for the window to be alive at all:
//
//   1. `modelToken`  : this controller's own `LogModelListener` registration, which is what
//                       turns a new sample into a redraw.
//   2. `exporterToken`— the file exporter's registration. Upstream keeps its `LogThread` alive
//                       by starting it; here the token is the lifetime.
//   3. `circuitToken`: the `SimCircuit` subscription, so a component deleted from the circuit
//                       stops being logged instead of sampling a dangling location.
//
// An unstored token is a dead subscription and the compiler will not say so, which is the
// project's most-repeated defect. All three are stored here, and `attach` is the only way to
// create them.

import Foundation
import LogisimFile
import LogisimKernel
import Observation
import SwiftUI

/// Which pane of the Log window is showing. Upstream's four `LogPanel` tabs, minus "Options"
/// ; its contents are folded into the sidebar and the export pane, because a tab that only
/// holds two steppers is a tab a Mac app does not have.
public enum LogWindowTab: String, CaseIterable, Identifiable, Sendable {
  case chronogram = "Timing"
  case table = "Table"
  case export = "Export"

  public var id: Self { self }

  var symbolName: String {
    switch self {
    case .chronogram: "waveform.path"
    case .table: "tablecells"
    case .export: "square.and.arrow.down"
    }
  }
}

/// The Log window's state, and the owner of every subscription it needs.
@MainActor
@Observable
public final class LogController {

  /// The log itself.
  public let model: LogModel

  /// The file writer. Always present; it does nothing until the model has a file and is enabled,
  /// which is upstream's `writing()` gate.
  public let exporter = LogFileExporter()

  /// Bumped on every model event. Views read it so that SwiftUI re-renders when a plain,
  /// non-observable model changes; the model deliberately does not import Observation, because
  /// that would tie the headless layer to a UI framework (D9's spirit, if not its letter).
  public private(set) var revision: Int = 0

  /// Which pane is showing.
  public var tab: LogWindowTab = .chronogram

  /// Rows selected in the signal list, by `LogSignalInfo.id`.
  public var selection: Set<UUID> = []

  /// Horizontal zoom: display points per simulated nanosecond, as `RightPanel.tickWidth` is.
  /// Stored as points per *tick* so the slider is meaningful across time scales.
  public var pointsPerTick: Double = 24

  /// The chronogram cursor, in simulated nanoseconds. `nil` pins it to the right edge, which is
  /// what `RightPanel.curT == Long.MAX_VALUE` means.
  public var cursorTime: Int64?

  /// The last error a sample raised. D13: `propagationCompleted` throws when a coarse clocked
  /// update cannot back-date far enough, and the window says so rather than the process dying.
  public private(set) var lastSampleError: String?

  // MARK: Tokens — see the file header

  private var modelToken: LogModelSubscription?
  private var exporterToken: LogModelSubscription?
  private var circuitToken: CircuitSubscription?

  /// The forwarder that turns model events into `revision` bumps. A separate object because
  /// `LogModel` holds its listeners through a token that keeps them alive, and a controller
  /// listening to itself would be a strong self-reference.
  private final class Forwarder: LogModelListener {
    weak var controller: LogController?
    init(controller: LogController) { self.controller = controller }

    private func bump() {
      guard let controller else { return }
      LogController.onMain { controller.noteModelChanged() }
    }
    func logSignalsReset(_ model: LogModel) { bump() }
    func logSignalsExtended(_ model: LogModel) { bump() }
    func logFilePropertyChanged(_ model: LogModel) { bump() }
    func logSelectionChanged(_ model: LogModel) { bump() }
    func logModeChanged(_ model: LogModel) { bump() }
    func logHistoryLimitChanged(_ model: LogModel) { bump() }
  }

  /// The circuit observer. Removes rows whose component has gone, which upstream does per-row in
  /// `SignalInfo.circuitChanged`; one subscription for the whole model is fewer tokens to lose.
  private final class CircuitObserver: SimCircuitListener {
    weak var controller: LogController?
    init(controller: LogController) { self.controller = controller }

    func circuitChanged(_ event: SimCircuitEvent) {
      guard let controller else { return }
      switch event.action {
      case .remove, .clear, .transactionDone:
        LogController.onMain { controller.pruneStaleSignals() }
      case .add, .invalidate:
        LogController.onMain { controller.noteModelChanged() }
      }
    }
  }

  /// Runs `body` on the main actor.
  ///
  /// **Not `MainActor.assumeIsolated`.** Model events originate on whatever thread propagation
  /// ran on, D1 keeps the kernel on its own `Thread`, deliberately outside Swift Concurrency,
  /// so assuming isolation here would trap on every sample taken by a running simulation. D13
  /// forbids exactly that: this is reachable from an ordinary circuit, so it hops instead.
  nonisolated fileprivate static func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated(body)
    } else {
      Task { @MainActor in body() }
    }
  }

  public init(model: LogModel) {
    self.model = model
    let forwarder = Forwarder(controller: self)
    modelToken = model.addListener(forwarder)
    exporterToken = model.addListener(exporter)
    model.setSelected(true)
  }

  deinit {
    // Tokens release themselves, but the file handle is an OS resource and should not wait for
    // a deinit chain. `MainActor.assumeIsolated` is not available in a deinit, and the exporter's
    // own deinit closes it, so this is left to that; stated so the absence is not read as an
    // oversight.
  }

  /// Attaches the log to a live circuit: installs the clock seams, points every probe at the
  /// simulation state, and stores the circuit subscription.
  ///
  /// - Parameter simulated: the `SimCircuit` wrapper to observe. Optional because a log can be
  ///   driven entirely by `ManualProbe`s (tests, replays), in which case there is nothing to
  ///   subscribe to and no token to store.
  public func attach(
    to circuit: Circuit,
    state: CircuitState?,
    simulated: (any SimCircuit)?
  ) {
    LogSignalDiscovery.install(on: model, for: circuit, state: state)
    if let simulated {
      circuitToken = simulated.addCircuitListener(CircuitObserver(controller: self))
    }
    noteModelChanged()
  }

  /// Detach from the circuit. Idempotent; called when the document closes.
  public func detach() {
    circuitToken?.cancel()
    circuitToken = nil
    exporter.closeFile()
    model.setSelected(false)
  }

  // MARK: - Driving the log

  /// The one call a simulator makes. Mirrors `Model.propagationCompleted` and catches its throw
  /// (D13) into a message the window shows.
  public func propagationCompleted(ticked: Bool, stepped: Bool, propagated: Bool) {
    do {
      try model.propagationCompleted(ticked: ticked, stepped: stepped, propagated: propagated)
      lastSampleError = nil
    } catch {
      lastSampleError = String(describing: error)
    }
  }

  /// `Model.simulatorReset()`.
  public func reset() {
    model.simulatorReset()
    exporter.rewind()
  }

  fileprivate func noteModelChanged() {
    revision &+= 1
  }

  /// Drops rows whose probe has gone stale; the component was deleted from the circuit.
  ///
  /// `CircuitPointProbe.readValue()` returns `nil` once its `CircuitState` is gone, and
  /// `probeWidth` freezes at its last known value. A row that can never produce a value again is
  /// removed, which is `SignalInfo.remove()`'s effect.
  fileprivate func pruneStaleSignals() {
    let stale = model.rows.filter { $0.info.probe.readValue() == nil }.map(\.info)
    if !stale.isEmpty { model.remove(stale) }
    noteModelChanged()
  }

  // MARK: - Selection helpers for the views

  /// The rows the user has picked in the signal list, in model order.
  public var selectedRows: [LogRow] {
    model.rows.filter { selection.contains($0.id) }
  }

  /// Removes the selected rows. Bound to ⌫ in the signal list.
  public func removeSelected() {
    let doomed = selectedRows.map(\.info)
    guard !doomed.isEmpty else { return }
    model.remove(doomed)
    selection.removeAll()
  }

  /// Applies a radix to every selected row, or to all rows when nothing is selected, which is
  /// what a user means by picking a radix with no selection.
  public func setRadix(_ radix: LogRadix) {
    let targets = selection.isEmpty ? model.rows : selectedRows
    for row in targets { model.setRadix(radix, for: row.info) }
  }

  /// The time the chronogram cursor is reading, resolving "pinned to the right edge".
  public var effectiveCursorTime: Int64 {
    cursorTime ?? max(model.endTime - 1, model.startTime)
  }

  /// The value of a row at the cursor, formatted; what the signal list shows beside each name.
  public func formattedValueAtCursor(_ row: LogRow) -> String {
    row.history.formattedValue(
      at: effectiveCursorTime, width: row.info.width, radix: row.info.radix)
  }
}
