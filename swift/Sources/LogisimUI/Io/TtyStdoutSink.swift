// TtyStdoutSink.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.gui.start.TtyInterface.sendFromTty and
// ensureLineTerminated), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// A `Tty` COMPONENT'S CHARACTERS, ON THEIR WAY OUT OF THE PROCESS.
//
// Upstream:
//
// ```java
// // TtyState.add(char c)
// if (sendStdout) TtyInterface.sendFromTty(c);
//
// // TtyInterface
// public static void sendFromTty(char c) { lastIsNewline = (c == '\n'); System.out.print(c); }
// private static void ensureLineTerminated() {
//   if (!lastIsNewline) { lastIsNewline = true; System.out.print('\n'); }
// }
// ```
//
// `sendFromTty` is a plain `static` in Java, so it is ALWAYS available and the per-`CircuitState`
// `sendStdout` flag alone decides whether anything is written. This port made it
// `Tty.sendFromTtyHook`, defaulting to `nil`: the right default for `LogisimStd`, which must not
// touch process I/O in a component test, and the reason it stayed unassigned. The effect was that
// a TTY set to write stdout emitted NOTHING, whatever the flag said.
//
// ── WHAT IS AND IS NOT REACHABLE TODAY, MEASURED, NOT ASSUMED ───────────────────────────────
//
// `sendStdout` is set in exactly one place upstream: `TtyInterface.prepareForTty` walks the
// circuit and calls `ttyFactory.sendToStdout(state)` for every `Tty`, and `prepareForTty` is
// reached only from `TtyInterface.runSimulation`, the `-tty halt`/`-tty speed` path.
//
//     $ grep -rn "sendToStdout\|sendFromTty" src/main/java
//     std/io/TtyState.java:36: TtyInterface.sendFromTty(c);
//     std/io/Tty.java:235: public void sendToStdout(InstanceState state) {
//     gui/start/TtyInterface.java:277: ttyFactory.sendToStdout(ttyState);
//     gui/start/TtyInterface.java:574: public static void sendFromTty(char c) {
//
// So: in the GUI upstream, nothing ever sets the flag, and installing this sink is inert but
// faithful; it restores Java's "the static is always there" property. **`runSimulation` is not
// ported** (`logisim-cli/main.swift` records the omission and its exit codes), so `Tty.
// sendToStdout` has no caller in Sources yet either. When that path lands, the CLI must install
// this too; a registration living in one executable's startup is one the other silently lacks,
// which is the same note `#Soc` and the HDL bindings both carry.
//
// That is why this type exists rather than a closure written inline at the install site: the
// `lastIsNewline` bookkeeping is not decoration, it is what `ensureLineTerminated` needs, and
// the `-tty` path that will consume it should find it already written and already tested.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation

/// The process's stdout, as `Tty.sendFromTtyHook` wants it.
///
/// Not `@MainActor`: `Tty.State.add` runs on the propagation thread (D1), so this is reached off
/// any actor. `@unchecked Sendable` with an `NSLock` over every field, the same discipline the
/// rest of the D1 boundary uses.
public final class TtyStdoutSink: @unchecked Sendable {

  /// The one instance the host installs. A single shared sink because `lastIsNewline` is a
  /// property of the *output stream*, not of any one TTY component; upstream's is a static
  /// field for exactly that reason, and two TTYs in one circuit share it.
  public static let shared = TtyStdoutSink()

  private let lock = NSLock()
  private var lastIsNewline = true
  private var sink: @Sendable (String) -> Void

  /// The default writer is `System.out.print`. `FileHandle.standardOutput.write` rather than
  /// Swift's `print`, because `print` appends a terminator and buffers differently, and this
  /// path's whole contract is that the bytes match `java -jar … -tty` character for character.
  public init(
    writer: @escaping @Sendable (String) -> Void = { text in
      FileHandle.standardOutput.write(Data(text.utf8))
    }
  ) {
    self.sink = writer
  }

  /// Redirect the output, for tests. Also resets `lastIsNewline` to its initial `true`, so a
  /// test starts from the same state a fresh process does.
  ///
  /// Returns the writer that was in place, so a caller can restore it.
  @discardableResult
  public func redirect(to writer: @escaping @Sendable (String) -> Void) -> @Sendable (String) ->
    Void
  {
    lock.lock()
    defer { lock.unlock() }
    let previous = sink
    sink = writer
    lastIsNewline = true
    return previous
  }

  /// `TtyInterface.sendFromTty(char)`.
  ///
  /// The flag is written *before* the character goes out, matching upstream's statement order,
  /// which matters only if the writer itself re-enters, and is kept because a reader should not
  /// have to decide whether it matters.
  public func write(_ character: Character) {
    lock.lock()
    lastIsNewline = character == "\n"
    let writer = sink
    lock.unlock()
    writer(String(character))
  }

  /// `TtyInterface.lastIsNewline`, read back by `ensureLineTerminated`.
  public var isAtLineStart: Bool { lock.withLock { lastIsNewline } }

  /// `TtyInterface.ensureLineTerminated()`; the newline printed after a `-tty` run so the shell
  /// prompt does not land mid-line. Not called from anywhere yet; see the file header for the
  /// `runSimulation` path that will.
  public func ensureLineTerminated() {
    lock.lock()
    guard !lastIsNewline else {
      lock.unlock()
      return
    }
    lastIsNewline = true
    let writer = sink
    lock.unlock()
    writer("\n")
  }
}
