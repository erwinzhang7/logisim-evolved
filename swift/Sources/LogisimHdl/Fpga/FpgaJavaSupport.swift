// FpgaJavaSupport.swift; part of logisim-evolved.
//
// The Java-semantics helpers the board model needs and the kernel does not already provide.
// `javaParseInt32` (LogisimKernel) and `javaParseUnsignedInt32` / `javaParseInt64`
// (LogisimFile) are used directly; only these two have no existing equivalent.
//
// GPL-3.0-only with the rest of the port. See LICENSE.md.

import LogisimFile
import LogisimKernel

/// Java's `String.split(String regex)` with the default limit, for a single literal separator.
///
/// Three behaviours differ from `Swift.String.split` and all three are reachable from a board
/// file:
///
///   * **Trailing empty segments are discarded.** `"a,b,"` → `["a", "b"]`, and `",,"` → `[]`.
///   * **Leading and interior empties are kept.** `",a"` → `["", "a"]`.
///   * **No separator at all yields the whole input**, even when it is empty: `""` → `[""]`,
///     an array of length one. This is the case `LogisimFile`'s (internal) `javaSplitOnLiteral`
///     gets wrong, it returns `[]`, which matters here because `InputPinSet=""` must produce
///     one pin whose FPGA location is the empty string, exactly as upstream does, rather than a
///     component with no pins.
///
/// `separator` defaults to `,` because that is what every list-valued board attribute uses; the
/// picture's code table is the one space-separated exception.
func javaSplitBoardList(_ text: String, separator: Character = ",") -> [String] {
  guard text.contains(separator) else { return [text] }
  var parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
  while let last = parts.last, last.isEmpty { parts.removeLast() }
  return parts
}

/// `Integer.parseUnsignedInt`, widened to `Int`.
///
/// `LogisimFile` exports the 32-bit parser; the board model works in `Int` throughout (upstream's
/// rectangle fields are `int`, and `Int` is what every geometry call wants), so this is the
/// widening rather than a second parser. The wrap is deliberate and matches Java:
/// `"4294967295"` is `-1`, not an overflow, and a board claiming that as an X coordinate is
/// then rejected by the `x < 0` guard, exactly as upstream rejects it.
func boardParseUnsignedInt(_ s: some StringProtocol) -> Int? {
  guard let value = javaParseUnsignedInt32(s) else { return nil }
  return Int(value)
}
