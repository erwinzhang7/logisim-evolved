// CircuitStatisticsWindow.swift -- part of logisim-evolved.
// Derived from logisim-evolution
// (com.cburch.logisim.gui.main.StatisticsDialog and
// com.cburch.logisim.file.FileStatistics), GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Upstream's path is:
//
//   MainMenuListener$ProjectMenuListener.actionPerformed
//     -> StatisticsDialog.show(frame, project.getLogisimFile(), currentCircuit)
//     -> FileStatistics.compute(file, circuit)
//
// There is no model mutation, no `Project.doAction`, and no undo entry. This is therefore a shell
// command like Analyze Circuit: the document can compute the table, but the presenter is a
// process UI concern. Tests replace `EditorModel.circuitStatisticsPresenter` so the command can
// be proved without ordering a real window front.

import AppKit
import LogisimFile
import SwiftUI

public struct CircuitStatisticsRow: Identifiable, Equatable, Sendable {
  public enum Kind: Sendable, Equatable {
    case component
    case totalWithoutSubcircuits
    case totalWithSubcircuits
  }

  public var id: Int
  public var kind: Kind
  public var component: String
  public var library: String
  public var simpleCount: Int
  public var uniqueCount: Int
  public var recursiveCount: Int
}

public struct CircuitStatisticsReport: Equatable, Sendable {
  public static let totalWithoutSubcircuitsLabel =
    "TOTAL (without project\u{2019}s sub circuits)"
  public static let totalWithSubcircuitsLabel = "TOTAL (with sub circuits)"

  public var circuitName: String
  public var rows: [CircuitStatisticsRow]

  init(file: LogisimFile, circuit: Circuit) {
    let stats = FileStatistics.compute(file: file, circuit: circuit)
    var nextID = 0
    func row(
      kind: CircuitStatisticsRow.Kind, component: String, library: String,
      count: FileStatistics.Count
    ) -> CircuitStatisticsRow {
      defer { nextID += 1 }
      return CircuitStatisticsRow(
        id: nextID,
        kind: kind,
        component: component,
        library: library,
        simpleCount: count.simpleCount,
        uniqueCount: count.uniqueCount,
        recursiveCount: count.recursiveCount)
    }

    var rows = stats.counts.map { count in
      row(
        kind: .component,
        component: count.factory?.displayName ?? "",
        library: count.library?.displayName ?? "-",
        count: count)
    }
    rows.append(
      row(
        kind: .totalWithoutSubcircuits,
        component: Self.totalWithoutSubcircuitsLabel,
        library: "-",
        count: stats.totalWithoutSubcircuits))
    rows.append(
      row(
        kind: .totalWithSubcircuits,
        component: Self.totalWithSubcircuitsLabel,
        library: "-",
        count: stats.totalWithSubcircuits))
    self.circuitName = circuit.name
    self.rows = rows
  }
}

extension EditorModel {
  func circuitStatisticsReport() -> CircuitStatisticsReport? {
    guard let target = analyzableCircuit else { return nil }
    return CircuitStatisticsReport(file: target.file, circuit: target.circuit)
  }

  func presentCircuitStatistics() {
    guard let report = circuitStatisticsReport() else { return }
    circuitStatisticsPresenter(report)
  }
}

@MainActor
public final class CircuitStatisticsWindowController: NSObject, NSWindowDelegate {
  public static let shared = CircuitStatisticsWindowController()

  private var window: NSWindow?

  /// `StatisticsDialog.show(...)` followed by Swing's `setVisible(true)`.
  public func show(_ report: CircuitStatisticsReport) {
    let window = existingWindow()
    window.title = "\(report.circuitName) Statistics"
    window.contentViewController = NSHostingController(
      rootView: CircuitStatisticsWindowContent(report: report))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  /// The window without ordering it front. `show` calls `NSApp.activate()`, which tests must not
  /// do for the same reason the analyzer window exposes its own testing accessor.
  func windowForTesting(report: CircuitStatisticsReport) -> NSWindow {
    let window = existingWindow()
    window.contentViewController = NSHostingController(
      rootView: CircuitStatisticsWindowContent(report: report))
    return window
  }

  private func existingWindow() -> NSWindow {
    if let window { return window }
    let created = NSWindow()
    created.setContentSize(NSSize(width: 700, height: 420))
    created.styleMask.insert(.resizable)
    created.isReleasedWhenClosed = false
    created.center()
    created.delegate = self
    window = created
    return created
  }
}

public struct CircuitStatisticsWindowContent: View {
  public var report: CircuitStatisticsReport

  public init(report: CircuitStatisticsReport) {
    self.report = report
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("\(report.circuitName) Statistics")
          .font(.title3.weight(.semibold))
        Spacer()
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
      Divider()
      Table(report.rows) {
        TableColumn("Component") { row in
          Text(row.component)
            .fontWeight(row.kind == .component ? .regular : .semibold)
        }
        TableColumn("Library") { row in
          Text(row.library)
            .foregroundStyle(row.kind == .component ? .primary : .secondary)
        }
        TableColumn("Simple") { row in countText(row.simpleCount, kind: row.kind) }
          .width(min: 72, ideal: 82)
        TableColumn("Unique") { row in countText(row.uniqueCount, kind: row.kind) }
          .width(min: 72, ideal: 82)
        TableColumn("Recursive") { row in countText(row.recursiveCount, kind: row.kind) }
          .width(min: 88, ideal: 100)
      }
      .padding(12)
    }
    .frame(minWidth: 580, minHeight: 320)
  }

  private func countText(_ value: Int, kind: CircuitStatisticsRow.Kind) -> some View {
    Text(value, format: .number)
      .monospacedDigit()
      .fontWeight(kind == .component ? .regular : .semibold)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}
