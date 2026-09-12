// LogisimUI tests: part of logisim-evolved.
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md at the repository root.
//
// ============================================================================
// M8: autosave, the sidecar, and its recovery.
//
// Autosave is data-loss-shaped, so it is tested as such rather than as a happy path: the
// suite spends more assertions on a read-only target, an empty serialization and a stale
// sidecar than it does on "it wrote the file". The three failures that actually cost a
// student a circuit are (a) a good recovery copy replaced by a bad one, (b) an older copy
// offered as if it were newer, and (c) a save path that reports success without writing,
// and each has a test below with the file left on disk afterwards to prove it.
//
// Every test drives `AutosaveController.tick()` directly. Nothing here sleeps: a suite that
// has to wait out a real 120-second interval to learn anything is a suite that gets deleted
// the first time CI is slow.
// ============================================================================

import Foundation
import LogisimFile
import Testing

@testable import LogisimUI

/// `.serialized` because `AutosaveRecovery.prompt` is process-global. `withPrompt` and
/// `withCleared` hold a lock across their bodies, but `seamRestoresExactly` has to assign the
/// bare property to prove the restore is exact, and that assignment is outside any window the
/// other tests hold. Serialising the suite is cheaper than the flake: see #74 and #83, both of
/// which were shared state restored less carefully than it was taken.
@MainActor
@Suite("M8 — the autosave sidecar and its recovery", .serialized)
struct DocumentLifecycleTests {

  // MARK: Scratch

  /// A directory that is removed when the returned handle is dropped is *not* what this does:
  /// the tests deliberately leave files behind inside a per-test temporary directory so a
  /// failure can be inspected. `FileManager` cleans `NSTemporaryDirectory()` itself.
  private func scratch(_ name: String = UUID().uuidString) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("m8-" + name, isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeController(
    base: @escaping () -> URL?,
    dirty: @escaping () -> Bool = { true },
    bytes: @escaping (URL) -> Data?,
    enabled: @escaping () -> Bool = { true },
    interval: @escaping () -> Double = { 120 }
  ) -> AutosaveController {
    AutosaveController(
      subject: .init(baseURL: base, isDirty: dirty, bytes: bytes),
      isEnabled: enabled,
      intervalSeconds: interval)
  }

  // MARK: - The path rule

  @Test("the sidecar lands beside the file, hidden, as `.<name>.circ.autosave`")
  func sidecarPath() throws {
    let dir = try scratch()
    let circ = dir.appendingPathComponent("adder.circ")
    #expect(
      AutosaveSidecar.path(besideFileAt: circ)
        == dir.appendingPathComponent(".adder.circ.autosave"))

    // Java appends `.circ.autosave`, not `.autosave`, when the name does not already end in
    // `.circ`, so the sidecar of an extensionless file is still recognisably a circuit.
    let bare = dir.appendingPathComponent("adder")
    #expect(
      AutosaveSidecar.path(besideFileAt: bare)
        == dir.appendingPathComponent(".adder.circ.autosave"))
  }

  /// The duplication guard. `AutosaveSidecar.path` restates a rule that lives, internal, in
  /// `Loader.determineAutosaveName`; `Loader.findAutosaveFile` is the same rule read backwards
  /// and IS public. If either half is edited without the other, this goes red.
  @Test("the shell's path rule and LogisimFile's finder agree on the same file")
  func sidecarPathAgreesWithLoader() throws {
    for name in ["adder.circ", "adder", "a.b.circ", "no-extension-at-all"] {
      // A directory each, because `adder.circ` and `adder` genuinely collide; see
      // `sidecarNamesCollide` below. Sharing one directory made this test fail on its own
      // fixture rather than on the rule it is checking.
      let dir = try scratch()
      let file = dir.appendingPathComponent(name)
      try Data("x".utf8).write(to: file)
      let mine = try #require(AutosaveSidecar.path(besideFileAt: file))
      #expect(Loader.findAutosaveFile(file) == nil, "no sidecar exists yet for \(name)")
      try Data("sidecar".utf8).write(to: mine)
      #expect(
        Loader.findAutosaveFile(file) == mine,
        "LogisimFile looks for a different sidecar than the shell writes, for \(name)")
      #expect(AutosaveSidecar.existingPath(besideFileAt: file) == mine)
    }
  }

  /// A recorded upstream quirk, not a defect introduced here.
  ///
  /// `determineAutosaveName` appends `.autosave` when the name already ends in `.circ` and
  /// `.circ.autosave` when it does not, so `adder.circ` and `adder` sitting in the same
  /// directory are given **the same sidecar**. 4.1.0 has exactly this collision
  /// (`Loader.java`, the `extension` variable), and the port reproduces it. It is left alone
  /// rather than "fixed" because changing it would make a sidecar written by 4.1.0
  /// unrecoverable by this app and vice versa, which is a worse outcome than two documents
  /// that are almost never opened together fighting over one file.
  @Test("`adder.circ` and `adder` share one sidecar, exactly as 4.1.0 has it")
  func sidecarNamesCollide() throws {
    let dir = try scratch()
    #expect(
      AutosaveSidecar.path(besideFileAt: dir.appendingPathComponent("adder.circ"))
        == AutosaveSidecar.path(besideFileAt: dir.appendingPathComponent("adder")))
  }

  @Test("an untitled document autosaves to a timestamped hidden file in the home directory")
  func untitledPath() throws {
    let home = try scratch("home")
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let path = try #require(AutosaveSidecar.path(besideFileAt: nil, now: at, home: home))
    #expect(path.deletingLastPathComponent().path == home.path)
    #expect(path.lastPathComponent.hasPrefix(Loader.logisimUnnamedAutosavePrefix))
    #expect(path.lastPathComponent.hasSuffix(Loader.logisimUnnamedAutosaveSuffix))

    // Upstream returns null rather than overwrite a name that is already taken, and the loop
    // treats that as "autosave failed" for this tick.
    try Data("occupied".utf8).write(to: path)
    #expect(AutosaveSidecar.path(besideFileAt: nil, now: at, home: home) == nil)
  }

  // MARK: - The loop body

  @Test("the preference is no longer a lie: off writes nothing, on writes the sidecar")
  func preferenceGate() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("p.circ")
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    let preferences = EditorPreferences.ephemeral()
    preferences.autosaveEnabled = false

    let controller = makeController(
      base: { file },
      bytes: { _ in Data("<project/>".utf8) },
      enabled: { preferences.autosaveEnabled },
      interval: { preferences.autosaveIntervalSeconds })

    #expect(controller.tick() == .disabled)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))

    // Re-read every tick, so the Settings toggle takes effect on the next interval rather than
    // on the next launch; upstream reads it once, in `LogisimFile`'s constructor.
    preferences.autosaveEnabled = true
    #expect(controller.tick() == .wrote(sidecar))
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
    #expect(try Data(contentsOf: sidecar) == Data("<project/>".utf8))
  }

  @Test("a clean document is not autosaved")
  func cleanDocumentIsSkipped() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("c.circ")
    let controller = makeController(
      base: { file }, dirty: { false }, bytes: { _ in Data("x".utf8) })
    #expect(controller.tick() == .notDirty)
    #expect(controller.writeCount == 0)
  }

  @Test("a dirty document whose bytes have not changed is not rewritten")
  func unchangedBytesAreNotRewritten() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("u.circ")
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    var payload = "one"
    // `LogisimFile.isAutosaveDirty` stays true until a real save and this module has no way to
    // clear it, so without the digest gate a document left dirty would rewrite the same bytes
    // every interval, forever.
    let controller = makeController(base: { file }, bytes: { _ in Data(payload.utf8) })

    #expect(controller.tick() == .wrote(sidecar))
    #expect(controller.tick() == .unchanged)
    #expect(controller.writeCount == 1)

    payload = "two"
    #expect(controller.tick() == .wrote(sidecar))
    #expect(controller.writeCount == 2)
    #expect(try Data(contentsOf: sidecar) == Data("two".utf8))

    // Deleting the sidecar behind the controller's back must not be masked by the digest:
    // the gate checks the file is still there before claiming "unchanged".
    try FileManager.default.removeItem(at: sidecar)
    #expect(controller.tick() == .wrote(sidecar))
  }

  @Test("Save As moves the sidecar and deletes the one it left behind")
  func saveAsMovesTheSidecar() throws {
    let dir = try scratch()
    var file = dir.appendingPathComponent("before.circ")
    let controller = makeController(base: { file }, bytes: { _ in Data("body".utf8) })

    let first = try #require(AutosaveSidecar.path(besideFileAt: file))
    #expect(controller.tick() == .wrote(first))

    file = dir.appendingPathComponent("after.circ")
    let second = try #require(AutosaveSidecar.path(besideFileAt: file))
    #expect(controller.tick() == .wrote(second))
    // Java: `if (oldAutosave != null && !oldAutosave.equals(autosaveFile)) oldAutosave.delete()`.
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
  }

  // MARK: - The failures that lose work

  @Test("an empty serialization never replaces a good sidecar")
  func emptySerializationKeepsThePreviousSidecar() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("e.circ")
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    var payload = Data("<project>real work</project>".utf8)
    let controller = makeController(base: { file }, bytes: { _ in payload })

    #expect(controller.tick() == .wrote(sidecar))

    // Upstream's `Loader.autosave` opens a `FileOutputStream`, which truncates, and only then
    // asks the writer for content, so a writer that fails here leaves an empty sidecar where a
    // recoverable one used to be. Refusing the write is the whole of the fix.
    payload = Data()
    let outcome = controller.tick()
    #expect(outcome == .failed(String(describing: AutosaveSidecar.WriteFailure.emptyDocument)))
    #expect(try Data(contentsOf: sidecar) == Data("<project>real work</project>".utf8))
  }

  @Test("a nil serialization is reported, not written")
  func nilSerializationIsReported() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("n.circ")
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    let controller = makeController(base: { file }, bytes: { _ in nil })
    #expect(controller.tick() == .couldNotSerialize)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
    // `LogisimFile.write` has already reported through `LoaderUI.showError`, and this is not a
    // disk failure, so the loop is NOT latched off: the next edit may well serialize fine.
    #expect(!controller.isStopped)
  }

  @Test("a target that cannot be written reports once and then stops for the session")
  func readOnlyTargetLatchesOff() throws {
    let dir = try scratch()
    let locked = dir.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    let file = locked.appendingPathComponent("r.circ")
    // 0o500: traversable and readable, not writable. This is the read-only-volume and
    // full-disk shape: the target is nameable and the write fails.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: locked.path)
    }

    var reported: [String] = []
    let controller = AutosaveController(
      subject: .init(baseURL: { file }, isDirty: { true }, bytes: { _ in Data("x".utf8) }),
      isEnabled: { true },
      intervalSeconds: { 120 },
      report: { reported.append($0) })

    guard case .failed = controller.tick() else {
      Issue.record("a write into a 0o500 directory was expected to fail")
      return
    }
    #expect(reported.count == 1)

    // Upstream sets `run = false` and the thread exits: one report, then silence. A permission
    // failure is not fixed by asking again in 30 seconds, and an alert every interval is how a
    // user learns to ignore alerts.
    #expect(controller.tick() == .stopped)
    #expect(controller.tick() == .stopped)
    #expect(reported.count == 1)
    #expect(controller.isStopped)

    // The one thing upstream cannot do: come back. Nothing restarts its thread, so an autosave
    // failure there is permanent until relaunch.
    controller.resume()
    #expect(!controller.isStopped)
  }

  @Test("stopping deletes the sidecar only when asked, and finds a stale one it never wrote")
  func stopDeletesOnlyWhenAsked() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("s.circ")
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))

    let keeping = makeController(base: { file }, bytes: { _ in Data("keep".utf8) })
    #expect(keeping.tick() == .wrote(sidecar))
    // Java `stopAutosaveThread(false)`; the app is going away with unsaved work, which is the
    // only case the sidecar exists for.
    keeping.stop(deleteSidecar: false)
    #expect(FileManager.default.fileExists(atPath: sidecar.path))

    let deleting = makeController(base: { file }, bytes: { _ in Data("go".utf8) })
    #expect(deleting.tick() == .wrote(sidecar))
    deleting.stop(deleteSidecar: true)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))

    // A sidecar left by a previous session, which this controller never wrote and so does not
    // hold in `currentSidecar`. Upstream's `deleteAutosave` only knows the path it last wrote,
    // so a stale sidecar there outlives the save that made it obsolete.
    try Data("stale".utf8).write(to: sidecar)
    let fresh = makeController(base: { file }, bytes: { _ in Data("x".utf8) })
    fresh.stop(deleteSidecar: true)
    #expect(!FileManager.default.fileExists(atPath: sidecar.path))
  }

  @Test("the interval has a floor, so a junk preference cannot turn the loop into a spin")
  func intervalFloor() {
    #expect(AutosaveController.minimumIntervalSeconds == 1)
    let controller = makeController(base: { nil }, bytes: { _ in nil }, interval: { 0 })
    #expect(!controller.isRunning)
    controller.start()
    #expect(controller.isRunning)
    controller.start()  // idempotent: a re-appearing view must not end up with two loops
    #expect(controller.isRunning)
    controller.stop(deleteSidecar: false)
    #expect(!controller.isRunning)
  }

  // MARK: - Recovery

  @Test("with no prompt installed nothing is recovered and nothing is deleted")
  func noPromptIsNonDestructive() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("q.circ")
    try Data("old".utf8).write(to: file)
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    try Data("newer".utf8).write(to: sidecar)

    AutosaveRecovery.withCleared {
      #expect(AutosaveRecovery.resolve(fileURL: file) == .original)
    }
    #expect(FileManager.default.fileExists(atPath: sidecar.path), "the sidecar must survive")
  }

  @Test("a newer sidecar is offered and, when accepted, is what gets opened")
  func recoverOffersTheSidecar() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("w.circ")
    try Data("on disk".utf8).write(to: file)
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    try Data("unsaved work".utf8).write(to: sidecar)
    try touch(sidecar, at: Date().addingTimeInterval(60))

    // A reference box, not a captured `var`: `AutosaveRecovery.Prompt` is `@Sendable`, so the
    // compiler refuses to let an escaping prompt mutate a local (`error: mutation of captured
    // var 'asked' in concurrently-executing code`, measured).
    let asked = PromptLog()
    let resolution = AutosaveRecovery.withPrompt({ _, autosave in
      asked.record(autosave)
      return .recover
    }) {
      AutosaveRecovery.resolve(fileURL: file)
    }
    #expect(asked.urls == [sidecar])
    #expect(resolution == .recovered(from: sidecar, bytes: Data("unsaved work".utf8)))
    // Accepting recovery must NOT delete the sidecar: the user has not saved yet, and until
    // they do, that file is still the only copy of the work.
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
  }

  @Test("a sidecar OLDER than the file is never offered, whatever the prompt would answer")
  func staleSidecarIsNotOffered() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("stale.circ")
    try Data("the newest work".utf8).write(to: file)
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    try Data("what the crash left".utf8).write(to: sidecar)
    try touch(sidecar, at: Date().addingTimeInterval(-3600))

    // This is the difference between an autosave and a trap. Upstream asks with no timestamp
    // comparison and no timestamps shown, so "recover" there can silently replace newer work
    // with older; and on this side NOTHING reaches `Loader.save`'s trailing `deleteAutosave()`,
    // so every saved document would otherwise be greeted by a recovery prompt it has already
    // superseded.
    let asked = PromptLog()
    let resolution = AutosaveRecovery.withPrompt({ _, autosave in
      asked.record(autosave)
      return .recover
    }) {
      AutosaveRecovery.resolve(fileURL: file)
    }
    #expect(asked.count == 0, "a superseded sidecar must not even raise the question")
    #expect(resolution == .original)
    #expect(FileManager.default.fileExists(atPath: sidecar.path))
  }

  @Test("discard deletes the sidecar and opens the file; open-saved and cancel touch nothing")
  func theOtherThreeAnswers() throws {
    for answer in [AutosaveRecovery.Answer.openSaved, .cancel, .discard] {
      let dir = try scratch()
      let file = dir.appendingPathComponent("a.circ")
      try Data("disk".utf8).write(to: file)
      let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
      try Data("sidecar".utf8).write(to: sidecar)
      try touch(sidecar, at: Date().addingTimeInterval(60))

      let resolution = AutosaveRecovery.withPrompt({ _, _ in answer }) {
        AutosaveRecovery.resolve(fileURL: file)
      }
      #expect(resolution == .original, "\(answer) must open the named file")
      #expect(
        FileManager.default.fileExists(atPath: sidecar.path) == (answer != .discard),
        "only discard may delete, and it must: \(answer)")
    }
  }

  @Test("an unreadable or empty sidecar cannot displace a readable document")
  func brokenSidecarIsRefused() throws {
    let dir = try scratch()
    let file = dir.appendingPathComponent("b.circ")
    try Data("good".utf8).write(to: file)
    let sidecar = try #require(AutosaveSidecar.path(besideFileAt: file))
    // Zero bytes is exactly what an interrupted upstream `autosave` leaves behind, which is the
    // crash this feature exists for.
    try Data().write(to: sidecar)
    try touch(sidecar, at: Date().addingTimeInterval(60))

    let resolution = AutosaveRecovery.withPrompt({ _, _ in .recover }) {
      AutosaveRecovery.resolve(fileURL: file)
    }
    #expect(resolution == .original)
  }

  @Test("an untitled document is never asked about recovery")
  func untitledIsNotAsked() {
    let asked = PromptLog()
    let resolution = AutosaveRecovery.withPrompt({ _, autosave in
      asked.record(autosave)
      return .recover
    }) {
      AutosaveRecovery.resolve(fileURL: nil)
    }
    #expect(asked.count == 0)
    #expect(resolution == .original)
  }

  @Test("withPrompt and withCleared restore exactly what was installed, not the default")
  func seamRestoresExactly() {
    let sentinel: AutosaveRecovery.Prompt = { _, _ in .discard }
    AutosaveRecovery.prompt = sentinel
    defer { AutosaveRecovery.prompt = nil }

    AutosaveRecovery.withPrompt({ _, _ in .recover }) {
      #expect(AutosaveRecovery.prompt != nil)
    }
    // Restoring to nil rather than to the previously installed value is the shape of four
    // separate incidents on this project (#74, #83): a test that ran after the app installed
    // its AppKit prompt would leave the app with no prompt at all.
    #expect(AutosaveRecovery.prompt != nil)

    AutosaveRecovery.withCleared {
      #expect(AutosaveRecovery.prompt == nil)
    }
    #expect(AutosaveRecovery.prompt != nil)
  }

  @Test("the shell's four answers map one for one onto LogisimFile's dispositions")
  func answersMapToDispositions() {
    #expect(AutosaveRecovery.Answer.recover.disposition == .load)
    #expect(AutosaveRecovery.Answer.openSaved.disposition == .ignore)
    #expect(AutosaveRecovery.Answer.discard.disposition == .discard)
    #expect(AutosaveRecovery.Answer.cancel.disposition == .cancel)
  }

  // MARK: - The document

  @Test("a document with no autosave running keeps its old behaviour")
  func documentDefaultsAreUnchanged() {
    let document = CircuitDocument()
    #expect(document.autosave == nil)
    #expect(document.currentURL == nil)
    #expect(document.recoveredFrom == nil)
    // `stopAutosaving` on a document that never started must be a no-op rather than a trap:
    // `onDisappear` runs for a window whose `task` never got as far as attaching a host.
    document.stopAutosaving(deleteSidecar: true)
    #expect(document.autosave == nil)
  }

  @Test("startAutosaving is idempotent and honours the preference it is handed")
  func startAutosavingIsIdempotent() {
    let preferences = EditorPreferences.ephemeral()
    preferences.autosaveEnabled = true
    preferences.autosaveIntervalSeconds = 30

    let document = CircuitDocument()
    document.startAutosaving(preferences: preferences)
    let first = document.autosave
    #expect(first != nil)
    document.startAutosaving(preferences: preferences)
    #expect(document.autosave === first, "a second call must not mint a second loop")

    // No host is attached, so the subject reports "not dirty" rather than serializing a
    // document that does not exist.
    #expect(document.autosave?.tick() == .notDirty)
    document.stopAutosaving(deleteSidecar: false)
    #expect(document.autosave == nil)
  }

  // MARK: Helpers

  private func touch(_ url: URL, at date: Date) throws {
    try FileManager.default.setAttributes(
      [.modificationDate: date], ofItemAtPath: url.path)
  }
}

/// What a prompt was asked, in a form an `@Sendable` closure may write to.
private final class PromptLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [URL] = []

  func record(_ url: URL) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(url)
  }

  var urls: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  var count: Int { urls.count }
}
