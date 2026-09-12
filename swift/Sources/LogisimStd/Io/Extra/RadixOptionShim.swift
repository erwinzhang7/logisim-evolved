// RadixOptionShim.swift: part of logisim-evolved.
//
// **Temporary stand-in, not a full port.** `com.cburch.logisim.circuit.RadixOption` is a
// `circuit`-package type (display-radix selection: binary/octal/decimal/hex/float, each with its
// own `getMaxLength(BitWidth)` and `toString(Value)` used by the attribute-value renderer and the
// poke-tool text editor) that no slice of this port owns yet; it is not `std/io`, and a search of
// `LogisimFile`/`LogisimKernel`/`LogisimStd` at the time this file was written found no port of it.
//
// `Slider` and `ProgrammableGenerator` (both in this directory) only need the attribute *identity*
// and its default value: `Slider` stores the radix as an attribute purely for its (unported, M6)
// painter to read, and `ProgrammableGenerator.getOffsetBounds` passes `RADIX_2` through to
// `Probe.getOffsetBounds`, which does not yet exist either (`std/wiring`, a sibling slice).
//
// This shim carries only what `.circ` round-tripping needs: the six token strings upstream's
// `RadixOption` subclasses serialize as (`Attributes.forOption("radix", …)`): and nothing of the
// display-formatting API. **Replace every reference to `RadixOptionShim` with the real
// `com.cburch.logisim.circuit.RadixOption` port once one lands**, and delete this file; see the
// task's final report for the exact upstream shape (`getMaxLength`, `toString(Value)`,
// `getIndexChar()`) a real port needs to add.

import Foundation
import LogisimKernel

/// Stand-in for `RadixOption`. See the file header.
public enum RadixOptionShim: String, AttributeOptionValue, CaseIterable, Sendable {
  case radix2 = "2"
  case radix8 = "8"
  case radix10Signed = "10signed"
  case radix10Unsigned = "10unsigned"
  case radix16 = "16"
  case radixFloat = "float"

  public static var attributeOptions: [RadixOptionShim] { Array(allCases) }

  /// `RadixOption.toString(Value)`; the six subclass overrides.
  ///
  /// Added by the io paint slice, which needs it: `Slider.paintInstance` renders its live output
  /// through `GraphicsUtil.drawCenteredValue`, which is `radix.toString(value)` plus
  /// `radix.getIndexChar()`. Everything it needs already exists on `Value`, so this is a
  /// dispatch table rather than new behaviour, and it does not make this file any less of a
  /// stand-in: `getMaxLength(BitWidth)`, the localised display names and the poke-tool text
  /// editor are all still missing and still belong to a real `circuit.RadixOption` port.
  public func string(for value: Value) -> String {
    switch self {
    case .radix2: return value.toDisplayString(radix: 2)
    case .radix8: return value.toDisplayString(radix: 8)
    case .radix10Signed: return value.toDecimalString(signed: true)
    case .radix10Unsigned: return value.toDecimalString(signed: false)
    case .radix16: return value.toDisplayString(radix: 16)
    case .radixFloat: return value.toStringFromFloatValue()
    }
  }

  /// `RadixOption.getIndexChar()`: the small blue suffix letter drawn beside a value.
  public var indexChar: String {
    switch self {
    case .radix2: return "b"
    case .radix8: return "o"
    case .radix10Signed: return "s"
    case .radix10Unsigned: return "u"
    case .radix16: return "h"
    case .radixFloat: return "f"
    }
  }
}

/// Stand-in for `RadixOption.ATTRIBUTE` (`.circ` token `"radix"`).
public let radixOptionAttribute: Attribute<RadixOptionShim> = Attributes.forOption("radix")
