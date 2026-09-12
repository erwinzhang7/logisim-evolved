// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// THE MISSING HALF OF A SAVE; board #89.
//
// A save has two halves: produce the bytes, and get them onto the disk. `ProjectHost` had
// only the first, so it cleared the document's dirty flag in `serialize()`: at the moment
// the bytes were *produced*, not the moment they were *stored*. A read-only volume, a full
// disk or a revoked sandbox grant therefore left the document reporting itself saved with
// nothing on disk to show for it. Anything drawn from that flag: an "Edited" dot, a title
// badge, a close-time "save changes?" prompt; would then be a confident lie, and a lie in
// exactly the direction that loses a circuit.
//
// UPSTREAM 4.1.0 DOES NOT HAVE THIS BUG, and the bytecode says so in one branch.
// `javap -c -p com.cburch.logisim.proj.ProjectActions` over
// `/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`,
// method `doSave(Project, File)`:
//
//     24: invokevirtual  Loader.save:(LLogisimFile;Ljava/io/File;)Z   ← returns boolean
//     27: istore   4
//     29: iload    4
//     31: ifeq     42                                                ← FALSE skips the block
//     35: invokestatic   AppPreferences.updateRecentFile:(Ljava/io/File;)V
//     39: invokevirtual  Project.setFileAsClean:()V                  ← only on TRUE
//     42: …
//     47: iload    4
//     49: ireturn
//
// `setFileAsClean()` sits at offset 39, inside the branch guarded by `ifeq 42`. Upstream
// clears the flag if and only if `Loader.save` returned true. This file restores that
// ordering.
//
// WHY A SEPARATE PROTOCOL RATHER THAN A MEMBER ON `ProjectHost`.
// Only because `Seams/ProjectSeam.swift` is not in this slice's ownership. A refinement is
// the smaller, reversible change: the shell asks for it with `as?`, the one conformer is
// `LogisimFileProjectHost`, and folding these two methods into `ProjectHost` later deletes
// this protocol and changes no call site's meaning. The integrator note in the report says
// so explicitly; that fold is the preferred end state, not this.
//
// WHY THE SHELL CANNOT SIMPLY BE TOLD.
// `SwiftUI.ReferenceFileDocument` has exactly three save-side members and all three run
// BEFORE the bytes reach the disk: checked against the SDK, not from memory:
//
//     func snapshot(contentType:) throws -> Snapshot
//     func fileWrapper(snapshot:configuration:) throws -> FileWrapper
//     typealias WriteConfiguration = FileDocumentWriteConfiguration
//
// (MacOSX26.5.sdk, SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface:7566-7575.)
// `ReferenceFileDocumentConfiguration` adds only `document`, `fileURL` and `isEditable`
// (ibid. :7594-7611). There is no `didSave`. So the confirmation has to be *evidence*, and
// the only evidence that does not require trusting the thing under test is the file itself.
// That is what `SaveVerification` is: it re-reads the bytes at the destination and compares.
// ============================================================================

import Foundation

// MARK: - The seam

/// The half of a save that `ReferenceFileDocument` does not model: the outcome.
///
/// A host that conforms is promising that `serialize()` is a **pure read**, that it leaves
/// the document's dirty state exactly as it found it, and that the flag moves only when one
/// of these two is called. A host that does not conform keeps whatever behaviour it had; the
/// shell degrades to "never confirm", which leaves a document looking dirty. That is the safe
/// direction, and it is deliberate: an indicator that under-reports "saved" is an annoyance,
/// while one that over-reports it is how work disappears.
@MainActor
public protocol SaveConfirming: AnyObject {
  /// True while bytes have been handed to the document machinery and their fate is unknown.
  var hasPendingSave: Bool { get }

  /// The bytes from the most recent `serialize()` are on disk. Clears the dirty flag;
  /// upstream's `Project.setFileAsClean()` at `doSave` offset 39.
  ///
  /// Ignored when there is no pending save, so a stray confirmation cannot fabricate a clean
  /// document out of one that was never serialized.
  func confirmSaveSucceeded()

  /// The bytes did not make it. Discards the pending save and leaves the document dirty:
  /// upstream's `ifeq 42`, the branch that skips `setFileAsClean()`.
  func confirmSaveFailed()
}

// MARK: - The evidence

/// Whether a specific set of bytes reached a specific place.
///
/// A free function over a URL and a digest, deliberately: it has to be assertable in a test
/// against a real file, a missing file, a truncated file and a file some other process wrote
/// in between, and none of those need a document, a host or a screen to set up.
public enum SaveVerification {

  /// Digest of the bytes a save is trying to place. `Hasher` rather than a cryptographic
  /// digest for the same reason `AutosaveController` uses it (`AutosaveController.swift:177`):
  /// this compares two byte strings inside one process in order to answer "did my own write
  /// land", not to defend against a forgery, and `Hasher` needs no extra dependency.
  ///
  /// Seeded per process, so a fingerprint must never be persisted or compared across launches.
  public static func fingerprint(_ data: Data) -> Int {
    var hasher = Hasher()
    hasher.combine(data)
    return hasher.finalize()
  }

  /// Did `url` end up holding bytes with this fingerprint?
  ///
  /// Answers `false` for every way a write can fail to happen; no URL yet (an untitled
  /// document that has never been saved), nothing at the path, unreadable, a partial write, or
  /// bytes some other writer put there. Only an exact match is a success, because "the file
  /// exists and is about the right size" is precisely the reasoning that produced the
  /// zero-length-file recovery dance in upstream's `Loader.save`.
  public static func bytesReached(_ url: URL?, fingerprint expected: Int) -> Bool {
    guard let url, let actual = try? Data(contentsOf: url) else { return false }
    return Self.fingerprint(actual) == expected
  }
}
