// XmlReaderException.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// specifically `src/main/java/com/cburch/logisim/file/XmlReaderException.java`.
// logisim-evolution is free software released under the GNU GPLv3; this translation is
// therefore GPL-3.0-only. See LICENSE.md.

import Foundation

/// Java's `XmlReaderException`: a *checked* exception carrying one or more human-readable
/// messages, which `ReadContext.addErrors` fans out into the accumulated error list with a
/// context suffix. It never aborts a load on its own; the reader catches it per element and
/// keeps going, which is why a `.circ` with one broken component still opens.
///
/// Kept as a distinct error type rather than folded into a general file error precisely
/// because of that: `catch (XmlReaderException)` at ~10 upstream sites means "record and
/// continue", and it must stay distinguishable from the errors that mean "stop".
public struct XmlReaderException: Error, Equatable, CustomStringConvertible, Sendable {

  public let messages: [String]

  /// Java: `XmlReaderException(String)` → `Collections.singletonList(message)`.
  public init(_ message: String) {
    self.messages = [message]
  }

  /// Java: `XmlReaderException(List<String>)`.
  public init(_ messages: [String]) {
    self.messages = messages
  }

  /// Java: `getMessage()` returns `messages.get(0)`.
  ///
  /// Deviation: upstream throws `IndexOutOfBoundsException` for an empty list. Nothing
  /// constructs one, `initAttributeSet` only throws once it has appended at least one
  /// message, so returning `""` removes a crash without changing any reachable behaviour.
  public var message: String { messages.first ?? "" }

  public var description: String { message }
}
