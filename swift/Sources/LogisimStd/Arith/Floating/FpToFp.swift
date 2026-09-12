// FpToFp.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.arith.floating.FpToFp),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The two width attributes are INSTANCE fields upstream, and that is transcribed ───────────
//
// `FP_WIDTH_IN` and `FP_WIDTH_OUT` are declared without `static` in the Java; the only
// attributes in the whole `std.arith` tree that are not class constants. Almost certainly an
// oversight, but it is transcribed rather than corrected, because "fix the obvious slip" is how
// a port acquires divergences nobody can later account for, and the fix is free to apply later
// if it is ever wanted.
//
// **What it means in practice.** Every `FpToFp()` gets its own pair of attribute objects, and
// attributes compare by reference. So two separately-constructed `FpToFp` factories have
// mutually unrecognisable attributes: a component built by one and asked about the other's
// `fpwidthin` answers `nil`. Nothing reaches that today: `FpArithmeticLibrary` constructs
// exactly one, and every component resolves its factory through the library's cached tool list,
// so there is only ever one instance in a running program. If a second is ever constructed (a
// test, a palette rebuild that does not go through the cache), that is the failure to look for,
// and promoting both to `static` is the one-line fix.
//
// ── Ports are fixed, even though their widths are not ────────────────────────────────────────
//
// Upstream routes this through `configurePorts(Instance)` and re-runs it whenever either width
// attribute changes. That is not needed here: a `Port` built from an `Attribute<BitWidth>` in
// this port resolves its width from the attribute set at use, so the *list* never changes shape
// ; only the widths it reports. PATTERNS.md's rule applies: an attribute that does not change
// the port array produces an identical array and fires nothing, so `setPorts` in `init` is the
// correct spelling and `ports(_:)` is not overridden.
//
// ── FP_WIDTH_IN is not read by `propagate` at all ────────────────────────────────────────────
//
// The conversion is `toDoubleValueFromAnyFloat()`, which dispatches on the *value's* own width,
// so the input format is whatever the wire carries. `FP_WIDTH_IN` therefore only sets the input
// pin's width (and the icon letter); if a narrower bus is attached the widths conflict and the
// value arrives in error, decoding to NaN. Upstream is identical.

import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.arith.floating.FpToFp`.
public final class FpToFp: InstanceFactoryBase {

  /// `FpToFp._ID`. Do not change, `.circ` files reference it.
  public static let id = "FPToFP"

  /// `PER_DELAY`.
  static let perDelay = 1

  public static let inPort = 0
  public static let out = 1
  public static let err = 2

  /// `FpToFp.FP_WIDTH_IN`: an instance field upstream; see the header.
  public let fpWidthIn: Attribute<BitWidth> = FpArithmeticAttributes.forBitWidthOption(
    "fpwidthin",
    choices: [BitWidth.known(8), BitWidth.known(16), BitWidth.known(32), BitWidth.known(64)])

  /// `FpToFp.FP_WIDTH_OUT`.
  public let fpWidthOut: Attribute<BitWidth> = FpArithmeticAttributes.forBitWidthOption(
    "fpwidthout",
    choices: [BitWidth.known(8), BitWidth.known(16), BitWidth.known(32), BitWidth.known(64)])

  public init() {
    super.init(FpToFp.id, displayName: "Floating Point Converter")
    setAttributes([
      fpWidthIn.binding(FpArithmeticAttributes.defaultFpWidth),
      fpWidthOut.binding(FpArithmeticAttributes.defaultFpWidth),
    ])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([
      Port(-40, 0, .input, fpWidthIn),  // IN
      Port(0, 0, .output, fpWidthOut),  // OUT
      Port(-20, 20, .output, 1),  // ERR
    ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidthOut = state.attributeValue(
      fpWidthOut, default: FpArithmeticAttributes.defaultFpWidth)

    let aValue = state.portValue(FpToFp.inPort).toDoubleValueFromAnyFloat()

    let delay = (dataWidthOut.width + 2) * FpToFp.perDelay
    state.setPort(FpToFp.out, Value.createKnownFloat(dataWidthOut, aValue), delay)
    state.setPort(FpToFp.err, Value.createKnown(BitWidth.known(1), aValue.isNaN ? 1 : 0), delay)
  }

  // PAINT (M6): the bounds box, a 20pt "→" centred at (x-20, y), ERR, and IN/OUT labelled with
  //             the format letter for their width, M/H/F/D for 8/16/32/64, "E" otherwise,
  //             IN's to the east and OUT's to the west. See FpToFp.java:92-127.
}
