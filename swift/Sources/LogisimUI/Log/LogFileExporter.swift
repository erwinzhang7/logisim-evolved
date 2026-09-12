// LogFileExporter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.log.LogThread),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The format is the contract ──────────────────────────────────────────────────────────────
//
// This file is consumed by scripts, not people, a TA's marking script reads it, so the layout
// is transcribed exactly rather than improved. One `writeSignals` pass emits:
//
//     # mode: step granularity: coarse         <- only when the mode has changed since last write
//     clk\tD[3..0]\tQ[3..0]                    <- only when the selection changed, and only if
//                                                 `fileHeader` is on
//     0\t0000\t0000\t# 5.0 µs                  <- one row per interval where nothing changed
//     1\t0000\t0000\t# 5.0 µs
//
// Fields are tab-separated; the trailing field is a comment marker, a space, and
// `LogDurationFormat.string(for:)`. Rows are `\n`-terminated: Java uses `PrintWriter.println`,
// whose separator is `System.lineSeparator()`, and this port is macOS-only (D0), so that is
// `\n`. Values come from a per-signal cursor, so a run that spans several rows repeats its
// formatted value on each; the file is a *sampled table*, not run-length encoded.
//
// ── What replaces the thread ────────────────────────────────────────────────────────────────
//
// Upstream runs a `LogThread`: a daemon that holds a lock, keeps a `PrintWriter` open, flushes
// every 500 ms and closes the file after 10 s of idleness. It exists because Swing has nowhere
// else to put periodic work. This port writes synchronously when a sample arrives and appends
// with a single `FileHandle`, so there is no lock, no wake-up timer, and no window in which the
// file is open but stale. The one behaviour worth keeping: never truncating, always appending,
// so that "append to existing log" works; is kept.
//
// ── One divergence, because Java's version hangs on its second flush ────────────────────────
//
// `LogThread.writeSignals` computes each row's duration as the minimum remaining duration across
// all cursors, advances by it, and caches the cursors in a `HashMap<Signal, Iterator>` between
// calls. Every pass ends having consumed the newest run exactly, `timeNextWrite` reaches
// `timeStop`, which is where that run ends, and `Iterator.advance()` responds to running off
// the end by setting `value = null; duration = 0`. So the cached cursor comes back into the
// *next* pass reporting duration 0, the minimum becomes 0, `timeNextWrite += 0` makes no
// progress, and `while (timeNextWrite < timeStop)` spins emitting identical `-\t-\t# 0 ns` rows
// until the disk fills.
//
// Two changes, both stated at the code that makes them:
//
//   * a cached cursor is reused only while it is still usable (`value != nil` and positioned at
//     `timeNextWrite`); otherwise it is rebuilt. That is what makes writing work at all past the
//     first flush, and it costs one walk of at most `historyLimit` runs.
//   * the pass still stops if a computed duration is somehow not positive, and says so through
//     `lastNonProgressingWrite`, rather than ever emitting an unbounded file.

import Foundation

/// Writes a `LogModel`'s samples to a file, in upstream's log format.
///
/// Attach it with `model.addListener(exporter)` and **keep the returned token**; see
/// `LogModelSubscription`. `LogLogging`'s `attach` does both.
public final class LogFileExporter: LogModelListener {

  /// Set when a write pass stopped early because a cursor had exhausted; see the file header.
  /// Purely diagnostic; the UI shows it so the condition is visible rather than silent.
  public private(set) var lastNonProgressingWrite: Int64?

  /// `timeNextWrite`: written up to this simulated time, exclusive.
  private var timeNextWrite: Int64 = 0
  /// `modeDirty`.
  private var modeDirty = true
  /// `headerDirty`.
  private var headerDirty = true
  /// `cursors`, keyed by row identity so a reorder does not invalidate them.
  private var cursors: [UUID: LogSignalCursor] = [:]

  /// The open append handle, or `nil` when nothing is being written.
  private var handle: FileHandle?
  private var openURL: URL?

  /// The most recent write error. Upstream silently calls `model.setFile(null)` on `IOException`
  /// and the user is never told; the error is surfaced here instead so the Log window can say so.
  public private(set) var lastError: Error?

  public init() {}

  deinit { closeFile() }

  // MARK: - Rendering (no file involved)

  /// Produces the text a `writeSignals()` pass would append, advancing the exporter's state.
  ///
  /// Separated from the file so the format can be tested without touching the disk, and so the
  /// Log window can show a live preview of what is being written.
  public func nextChunk(for model: LogModel) -> String {
    var output = ""

    if modeDirty {
      output += "# mode: \(model.mode.fileKeyword) granularity: \(model.granularity.fileKeyword)\n"
      modeDirty = false
    }

    if headerDirty {
      // Note: upstream clears the flag whether or not the header is enabled.
      if model.writesFileHeader {
        output += model.rows.map(\.info.displayName).joined(separator: "\t") + "\n"
      }
      headerDirty = false
    }

    // `cur[i] = cursors.get(s)` else a fresh cursor positioned at `timeNextWrite`.
    //
    // The cached cursor is used only while it is still usable. Java caches unconditionally, and
    // that is what makes its second write hang: a pass always ends having consumed the last run
    // exactly, which leaves the cursor exhausted (`value == null`, `duration == 0`), and the
    // next pass then computes a zero-length row forever. Rebuilding an exhausted or misplaced
    // cursor costs one walk over at most `historyLimit` runs and makes the writer actually work
    // across flushes.
    var live: [(row: LogRow, cursor: LogSignalCursor)] = []
    for row in model.rows {
      let cached = cursors[row.id]
      let usable = cached.flatMap { $0.value != nil && $0.time == timeNextWrite ? $0 : nil }
      let cursor = usable ?? row.history.makeCursor(at: timeNextWrite, width: row.info.width)
      live.append((row, cursor))
    }

    let timeStop = model.endTime
    while timeNextWrite < timeStop {
      var duration = timeStop - timeNextWrite
      var fields: [String] = []
      fields.reserveCapacity(live.count)
      for entry in live {
        fields.append(entry.cursor.formattedValue(radix: entry.row.info.radix))
        if entry.cursor.duration < duration { duration = entry.cursor.duration }
      }

      guard duration > 0 else {
        // See the file header: Java loops forever here.
        lastNonProgressingWrite = timeNextWrite
        break
      }

      output += fields.joined(separator: "\t") + "\t# " + LogDurationFormat.string(for: duration)
      output += "\n"

      for index in live.indices {
        var cursor = live[index].cursor
        live[index].row.history.advance(&cursor, by: duration, width: live[index].row.info.width)
        live[index].cursor = cursor
      }
      timeNextWrite += duration
    }

    cursors = Dictionary(uniqueKeysWithValues: live.map { ($0.row.id, $0.cursor) })
    return output
  }

  // MARK: - File writing

  /// `writeSignals()`; render the pending samples and append them.
  ///
  /// Does nothing when the model is not currently writing, which is upstream's `writing()` gate.
  public func write(_ model: LogModel) {
    guard model.isWritingToFile, let url = model.fileURL else { return }
    let chunk = nextChunk(for: model)
    guard !chunk.isEmpty else { return }
    append(chunk, to: url)
  }

  private func append(_ text: String, to url: URL) {
    do {
      if handle == nil || openURL != url {
        closeFile()
        if !FileManager.default.fileExists(atPath: url.path) {
          FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        openURL = url
        try handle?.seekToEnd()
      }
      guard let data = text.data(using: .utf8) else { return }
      try handle?.write(contentsOf: data)
      lastError = nil
    } catch {
      // D13: a read-only path, a deleted directory or a full disk must not take the app down.
      lastError = error
      closeFile()
    }
  }

  /// Flush and release the file. Safe to call repeatedly.
  public func closeFile() {
    try? handle?.synchronize()
    try? handle?.close()
    handle = nil
    openURL = nil
  }

  /// Forget everything written so far, so the next pass re-emits the mode line and the header.
  /// `signalsReset` does this implicitly; a host changing files calls it directly.
  public func rewind() {
    timeNextWrite = 0
    cursors.removeAll()
    modeDirty = true
    headerDirty = true
    lastNonProgressingWrite = nil
  }

  // MARK: - LogModelListener

  public func logSignalsReset(_ model: LogModel) {
    guard model.isWritingToFile else { return }
    timeNextWrite = 0
    cursors.removeAll()
    write(model)
  }

  public func logSignalsExtended(_ model: LogModel) {
    write(model)
  }

  public func logFilePropertyChanged(_ model: LogModel) {
    if model.isWritingToFile {
      if handle == nil { write(model) }
    } else {
      closeFile()
    }
  }

  public func logSelectionChanged(_ model: LogModel) {
    // `cursors.keySet().retainAll(model.getSignals())`; drop cursors for removed rows.
    let live = Set(model.rows.map(\.id))
    cursors = cursors.filter { live.contains($0.key) }
    headerDirty = true
  }

  public func logModeChanged(_ model: LogModel) {
    modeDirty = true
  }
}
