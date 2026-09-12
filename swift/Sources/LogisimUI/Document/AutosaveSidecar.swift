// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// WHERE AN AUTOSAVE GOES, AND WHY THE RULE IS RESTATED HERE.
//
// `Loader.determineAutosaveName` (Sources/LogisimFile/Loader.swift:208) is the port of
// 4.1.0's `Loader.determineAutosaveName(File)` and it is **internal to `LogisimFile`**.
// `Loader.autosave(_:)` aims at it using the loader's `mainFileURL`, and `setMainFile` is
// internal too (`Loader.swift:179`); the only public path that sets it is
// `openLogisimFile(_ file: URL)`, which `LogisimUI` never calls: the shell opens documents
// from `Data` (`LogisimFileProjectHost.openProject(data:url:contentType:)`), because that is
// what `ReferenceFileDocument` hands it.
//
// So from inside `LogisimUI` today, `loader.mainFile` is nil for **every** open document and
// `loader.autosave(file)` would write `~/.logisim-unnamed-autosave_<timestamp>.circ.autosave`
// for a document that has a perfectly good home on disk. That is not a sidecar a user will
// ever find. The rule is therefore restated here, where the shell, the only object that
// knows the document's URL, can aim it.
//
// **The duplication is pinned, not trusted.** `Loader.findAutosaveFile(_:)` IS public and is
// the same rule read backwards, so `AutosaveSidecarTests` writes a file at the path this
// type computes and asserts `Loader.findAutosaveFile` finds exactly it. If either half is
// edited without the other, that test goes red. Delete the duplication the moment
// `LogisimFile` exposes either `setMainFile` or `determineAutosaveName` publicly: see the
// handoff note in the milestone report.
// ============================================================================

import Foundation
import LogisimFile

public enum AutosaveSidecar {

  /// Java `Loader.determineAutosaveName(File)`; Swift twin at `Loader.swift:208`.
  ///
  /// `foo.circ` → `.foo.circ.autosave`, and anything else → `.<name>.circ.autosave`, both
  /// beside the file. A nil base is the untitled case: a timestamped hidden file in the home
  /// directory, and nil if that name is already taken (upstream gives up rather than
  /// overwrite, and so does this).
  public static func path(besideFileAt base: URL?, now: Date = Date(), home: URL? = nil)
    -> URL?
  {
    guard let base else {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone.current
      formatter.dateFormat = "yyyyMMddHHmmss"
      let directory = home ?? URL(fileURLWithPath: NSHomeDirectory())
      let candidate = directory.appendingPathComponent(
        Loader.logisimUnnamedAutosavePrefix + formatter.string(from: now)
          + Loader.logisimUnnamedAutosaveSuffix)
      return FileManager.default.fileExists(atPath: candidate.path) ? nil : candidate
    }
    let name = base.lastPathComponent
    let ext = name.hasSuffix(Loader.logisimExtension) ? ".autosave" : ".circ.autosave"
    return base.deletingLastPathComponent().appendingPathComponent("." + name + ext)
  }

  /// Java `Loader.findAutosaveFile(File)`. Delegated rather than re-derived: this half of the
  /// rule *is* public, and delegating is what keeps the two halves honest.
  public static func existingPath(besideFileAt base: URL) -> URL? {
    Loader.findAutosaveFile(base)
  }

  // MARK: Writing

  public enum WriteFailure: Error, Equatable, CustomStringConvertible {
    /// The serializer produced nothing. Upstream would happily write the zero bytes over a
    /// perfectly good previous sidecar; see `write(_:to:)` for why this refuses instead.
    case emptyDocument
    case couldNotWrite(String)

    public var description: String {
      switch self {
      case .emptyDocument:
        return "the project serialized to zero bytes, so the previous autosave was kept"
      case .couldNotWrite(let detail):
        return detail
      }
    }
  }

  /// Write a sidecar.
  ///
  /// Two deliberate divergences from `Loader.autosave`, both in the safe direction and both
  /// invisible when nothing is going wrong:
  ///
  ///  1. **Zero bytes are refused.** Upstream's `autosave` is documented in its own port as
  ///     "deliberately without the failsafes `save` has": it opens a `FileOutputStream`, which
  ///     truncates, and only then asks the writer for content. A writer that fails after the
  ///     truncate leaves an empty sidecar where a recoverable one used to be. The bytes are in
  ///     hand before anything is opened here, so refusing an empty write costs nothing and can
  ///     only preserve a recovery copy.
  ///  2. **The write is atomic.** `Data.write(options: .atomic)` writes a temporary beside the
  ///     target and renames, so a kill mid-write leaves the *previous* sidecar intact rather
  ///     than a half-written one. Upstream streams straight onto the target. This is the same
  ///     option `Loader.save` and `Loader.autosave` already use on this side.
  public static func write(_ data: Data, to target: URL) throws {
    guard !data.isEmpty else { throw WriteFailure.emptyDocument }
    do {
      try data.write(to: target, options: .atomic)
    } catch {
      throw WriteFailure.couldNotWrite(String(describing: error))
    }
  }

  /// Java `Loader.deleteAutosave()`. Absent is success; the postcondition is "no sidecar
  /// here", and upstream's `File.delete()` returning false for a missing file is not a failure
  /// any caller acts on.
  @discardableResult
  public static func remove(at target: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: target.path) else { return true }
    return (try? FileManager.default.removeItem(at: target)) != nil
  }
}
