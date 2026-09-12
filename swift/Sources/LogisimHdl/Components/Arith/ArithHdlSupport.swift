// ArithHdlSupport: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the shared shape of `com/cburch/logisim/std/arith/*HdlGeneratorFactory.java`. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Why the arith generators take injected attributes ────────────────────────────────────────
//
// Upstream's generators name `StdAttr.WIDTH`, `Comparator.MODE_ATTR` and `Shifter.ATTR_SHIFT`
// directly, because in Java everything lives in one artefact. Here `StdAttr` is in
// `LogisimFile` (which this module already depends on) but `Comparator` and `Shifter` are in
// `LogisimStd`, and `LogisimStd -> LogisimHdl` is the edge the whole `HdlGeneratorLookup`
// design exists to protect (see that file's header). Naming `LogisimStd` from here would
// invert it.
//
// So the two bespoke attributes are constructor parameters, exactly as `HdlParameters`'
// `widthAttribute` and `AbstractHdlGeneratorFactory`'s `clockAttributes`/`labelAttribute`
// already are, and for the same reason. **They must be the very objects the component's own
// `AttributeSet` holds**: `AnyAttribute` compares by `===` (D4), so a look-alike built here
// would make every `containsAttribute` miss.
//
// `AttributeOption`, by contrast, is a `Hashable` *struct* in this port, so the option values
// (`twosComplement`/`unsigned`, `ll`/`lr`/`ar`/`rl`/`rr`) compare structurally and can be spelled
// out locally without a dependency. That is what `ArithHdlOptions` does; the names are exactly
// the strings `.circ` stores, so they cannot drift without breaking every saved file.

import LogisimFile
import LogisimKernel

/// The subdirectory every `std/arith` generator writes into.
///
/// Java derives it by parsing `getClass().toString()` in the no-argument
/// `AbstractHdlGeneratorFactory` constructor: `com.cburch.logisim.std.arith.Adder…` yields
/// `"arith"`, which works only because Java packages mirror source directories. The port
/// names it explicitly (see `AbstractHdlGeneratorFactory.swift`'s header). Verified against the
/// jar: `getRelativeDirectory()` is `vhdl/arith/` for every one of these seven classes.
public enum ArithHdlSubdirectory {
  public static let name = "arith"
}

/// The `AttributeOption` values the arith generators map to generic-parameter integers.
///
/// Spelled out here rather than imported from `LogisimStd`; see this file's header. Each name
/// is the option's `.circ` token, taken from `Comparator.java:44-47` and `Shifter.java:43-53`
/// in the 4.1.0 tree.
public enum ArithHdlOptions {
  /// `Comparator.SIGNED_OPTION`.
  public static let signed = AttributeOption(name: "twosComplement")
  /// `Comparator.UNSIGNED_OPTION`.
  public static let unsigned = AttributeOption(name: "unsigned")

  /// `ComparatorHdlGeneratorFactory.SIGNED_MAP`: shared verbatim by `Multiplier` and
  /// `Divider`, which is why upstream declares it `public static` on the comparator's
  /// generator rather than on the comparator.
  public static let signedMap: [AttributeOption: Int64] = [
    unsigned: 0,
    signed: 1,
  ]

  /// `Shifter.SHIFT_LOGICAL_LEFT` and friends.
  public static let shiftLogicalLeft = AttributeOption(name: "ll")
  public static let shiftLogicalRight = AttributeOption(name: "lr")
  public static let shiftArithmeticRight = AttributeOption(name: "ar")
  public static let shiftRollLeft = AttributeOption(name: "rl")
  public static let shiftRollRight = AttributeOption(name: "rr")

  /// The anonymous `HashMap` `ShifterHdlGeneratorFactory`'s constructor builds inline.
  public static let shiftModeMap: [AttributeOption: Int64] = [
    shiftLogicalLeft: 0,
    shiftRollLeft: 1,
    shiftLogicalRight: 2,
    shiftArithmeticRight: 3,
    shiftRollRight: 4,
  ]
}

extension AttributeSet {
  /// `attrs.getValue(StdAttr.WIDTH).getWidth()`.
  ///
  /// Java dereferences the result unguarded, so an attribute set without a width is an
  /// immediate `NullPointerException` there. It is not reachable from a `.circ` file, the
  /// loader builds every arith component's attribute set from its own factory, which always
  /// declares `WIDTH`, so this is the "genuine programmer error" branch of D13 and traps.
  var arithHdlWidth: Int {
    guard let width = getValue(StdAttr.width) else {
      preconditionFailure("arith HDL generator used with an attribute set that has no width")
    }
    return width.width
  }
}
