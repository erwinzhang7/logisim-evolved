// NegateAttribute.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.gates.NegateAttribute),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The deviation, and why it is exact ──────────────────────────────────────────────────────
//
// Upstream `NegateAttribute extends Attribute<Boolean>` and overrides `equals`/`hashCode` on
// `(index, side)`. `GateAttributeList.get(i)` then hands out a **freshly allocated**
// `NegateAttribute` on every call, and everything downstream works because two of them compare
// equal.
//
// This port cannot subclass: `Attribute<V>` is `final` (D5 makes it a generic value-key with a
// codec, not a class hierarchy), and `AnyAttribute`'s `==` is identity, declared in an
// extension and therefore not overridable.
//
// So the value-equality is reproduced by **interning**: `NegateAttributes.attribute(index:side:)`
// returns the same object for the same `(index, side)`, forever and program-wide. Identity
// comparison then answers exactly what upstream's `equals` answers, including across two
// different gates, which is upstream's semantics, since `equals` ignores the owning set.
// `attr instanceof NegateAttribute` becomes `NegateAttributes.info(of:) != nil`.
//
// `getDisplayName()` (`"Negate input N (north)"`) is localisation and does not come across;
// `getCellEditor`/`toDisplayString` are UI (D5, D9).

import Foundation
import LogisimKernel

/// The interning table behind upstream's `new NegateAttribute(index, side)`.
public enum NegateAttributes {

  /// `(index, side)`; the pair upstream's `equals`/`hashCode` are written on.
  public struct Info: Hashable, Sendable {
    public let index: Int
    /// `null` for every input that is neither first nor last.
    public let side: Direction?
  }

  private static let lock = NSLock()
  private static var byInfo: [Info: Attribute<Bool>] = [:]
  private static var infoByAttribute: [ObjectIdentifier: Info] = [:]

  /// `new NegateAttribute(index, side)`; interned.
  ///
  /// The `.circ` token is `"negate" + index`, exactly as upstream, and the codec is
  /// `Attributes.forBoolean`'s (upstream delegates `parse` to a shared `BOOLEAN_ATTR`).
  public static func attribute(index: Int, side: Direction?) -> Attribute<Bool> {
    let info = Info(index: index, side: side)
    lock.lock()
    defer { lock.unlock() }
    if let existing = byInfo[info] { return existing }
    let created: Attribute<Bool> = Attributes.forBoolean("negate\(index)")
    byInfo[info] = created
    infoByAttribute[ObjectIdentifier(created)] = info
    return created
  }

  /// The port's `attr instanceof NegateAttribute`, and its `((NegateAttribute) attr).index`.
  public static func info(of attribute: AnyAttribute) -> Info? {
    lock.lock()
    defer { lock.unlock() }
    return infoByAttribute[ObjectIdentifier(attribute)]
  }

  /// `attr instanceof NegateAttribute`.
  public static func isNegateAttribute(_ attribute: AnyAttribute) -> Bool {
    info(of: attribute) != nil
  }
}
