// LogTableView.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.{TablePanel, ValueTable}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The table ───────────────────────────────────────────────────────────────────────────────
//
// One row per interval in which nothing changed, one column per logged signal, plus the
// duration: the same rows the file writer emits, so what a student sees is what a marking
// script reads. That equivalence is deliberate and is enforced by construction: both go through
// `LogSampleTable.rows(of:)` below, so the table cannot drift from the file.
//
// Upstream's `ValueTable` is 490 lines of hand-drawn Swing: it measures every column with
// `FontMetrics`, paints cells itself in `paintComponent`, implements its own scrolling model,
// and reimplements selection. All of that is what a `Table` gives for free, along with column
// resizing, sorting affordances, keyboard navigation and copy; none of which upstream's has.

import SwiftUI

/// One sampled interval: the values of every signal, and how long they held.
public struct LogSample: Identifiable, Sendable {
  public let id: Int
  /// Simulated time this interval starts at.
  public let time: Int64
  /// How long it lasts.
  public let duration: Int64
  /// Formatted values, in row order.
  public let values: [String]
}

/// Turns a model into sampled rows.
///
/// The algorithm is `LogThread.writeSignals`': walk a cursor per signal, and at each step take
/// the shortest remaining run as the next interval. Extracted here so the table and the file
/// writer cannot disagree, and so it can be tested without a window.
public enum LogSampleTable {

  /// - Parameter limit: stop after this many rows. A long run at fine granularity produces tens
  ///   of thousands of intervals and only the newest are ever looked at; `nil` means all of them.
  public static func rows(of model: LogModel, limit: Int? = 2000) -> [LogSample] {
    var cursors = model.rows.map { $0.history.makeCursor(at: model.startTime, width: $0.info.width) }
    guard !cursors.isEmpty else { return [] }

    var samples: [LogSample] = []
    var t = model.startTime
    let stop = model.endTime
    var index = 0

    while t < stop {
      var duration = stop - t
      var values: [String] = []
      values.reserveCapacity(cursors.count)
      for (offset, cursor) in cursors.enumerated() {
        values.append(cursor.formattedValue(radix: model.rows[offset].info.radix))
        if cursor.duration < duration { duration = cursor.duration }
      }
      // Same guard as the exporter: a cursor that has run off the end reports 0 and Java's loop
      // would never terminate. See LogFileExporter's header.
      guard duration > 0 else { break }

      samples.append(LogSample(id: index, time: t, duration: duration, values: values))
      index += 1

      for offset in cursors.indices {
        var cursor = cursors[offset]
        model.rows[offset].history.advance(
          &cursor, by: duration, width: model.rows[offset].info.width)
        cursors[offset] = cursor
      }
      t += duration

      if let limit, samples.count >= limit { break }
    }
    return samples
  }
}

/// The tabular view of the log.
struct LogTableView: View {
  @Bindable var controller: LogController

  private var model: LogModel { controller.model }

  var body: some View {
    let samples = LogSampleTable.rows(of: model)
    if model.rows.isEmpty {
      ContentUnavailableView {
        Label("No signals logged", systemImage: "tablecells")
      } description: {
        Text("Add signals to see a sample table.")
      }
    } else if samples.isEmpty {
      ContentUnavailableView {
        Label("No samples yet", systemImage: "clock")
      } description: {
        Text("Run or step the simulation to record samples.")
      }
    } else {
      Table(samples) {
        TableColumn("Time") { sample in
          Text(LogDurationFormat.string(for: sample.time))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .width(min: 70, ideal: 90)

        TableColumn("Held for") { sample in
          Text(LogDurationFormat.string(for: sample.duration))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .width(min: 70, ideal: 90)

        TableColumnForEach(model.rows) { row in
          TableColumn(row.info.displayName) { sample in
            Text(sample.values.indices.contains(row.index) ? sample.values[row.index] : "-")
              .font(.system(size: 11, design: .monospaced))
          }
          .width(min: 48, ideal: 72)
        }
      }
      .id(controller.revision)
    }
  }
}
