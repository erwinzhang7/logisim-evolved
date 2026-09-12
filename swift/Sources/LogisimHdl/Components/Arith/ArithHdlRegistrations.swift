// ArithHdlRegistrations: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// `getHDLGenerator`/`getHDLName` answers the `com/cburch/logisim/std/arith` component factories
// give, which upstream expresses by passing a generator to the `InstanceFactory` constructor and
// overriding `getHDLName`. Copyright by the Logisim-evolution developers. This translation is a
// derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `HdlGeneratorLookup` takes those answers as data keyed by `ComponentFactory.name` (its header
// explains why it is a registry and not three more `ComponentFactory` members). This file is the
// arith family's half of that data, ready to hand to `register(factoryName:_:)`. It does not
// register anything itself: `HdlGeneratorLookup.shared` is process-wide state that the
// integrator owns, and a library registering itself from a file-scope side effect is exactly the
// kind of ordering dependence that made `ToolPreservationTests` flake.
//
// Each factory function returns one generator instance and reuses it, matching upstream, where
// `InstanceFactory.myHDLGenerator` is a single object created in the component's constructor.
// That is safe even for the two generation-time generators: `AbstractHdlGeneratorFactory` clears
// `myPorts`/`myWires`/`myTypedWires` before every call that reads them.
//
// **There is no `divider()`, deliberately.** See `DividerHdlGeneratorFactory.swift`'s header;
// `tools/hdlbridge/arith-4.1.0.oracle` records `SYNTH 0` and `SUPP 0` for `Divider` at every
// width and mode, straight from the jar.

import LogisimFile
import LogisimKernel

/// The `(ComponentFactory.name, generator)` pairs the arith family contributes to
/// `HdlGeneratorLookup`.
public enum ArithHdlRegistrations {

  // `ComponentFactory.name`: the `_ID` constants, which `.circ` files carry verbatim and which
  // therefore cannot change.
  public static let adderName = "Adder"
  public static let subtractorName = "Subtractor"
  public static let negatorName = "Negator"
  public static let multiplierName = "Multiplier"
  public static let comparatorName = "Comparator"
  public static let shifterName = "Shifter"
  /// Present for completeness; **not** to be registered (see this file's header).
  public static let dividerName = "Divider"

  /// `Adder.getHDLName`: `FullAdder` at width 1, otherwise the corrected factory name.
  public static func adder() -> HdlGeneratorLookup.Registration {
    let generator = AdderHdlGeneratorFactory()
    return HdlGeneratorLookup.Registration(
      generator: { _ in generator },
      hdlName: { attrs in
        attrs.arithHdlWidth == 1 ? "FullAdder" : CorrectLabel.correctLabel(adderName)
      })
  }

  /// `Subtractor.getHDLName`: `FullSubtractor` at width 1.
  public static func subtractor() -> HdlGeneratorLookup.Registration {
    let generator = SubtractorHdlGeneratorFactory()
    return HdlGeneratorLookup.Registration(
      generator: { _ in generator },
      hdlName: { attrs in
        attrs.arithHdlWidth == 1 ? "FullSubtractor" : CorrectLabel.correctLabel(subtractorName)
      })
  }

  /// `Negator.getHDLName`: `BitNegator` at width 1.
  public static func negator() -> HdlGeneratorLookup.Registration {
    let generator = NegatorHdlGeneratorFactory()
    return HdlGeneratorLookup.Registration(
      generator: { _ in generator },
      hdlName: { attrs in
        attrs.arithHdlWidth == 1 ? "BitNegator" : CorrectLabel.correctLabel(negatorName)
      })
  }

  /// `Multiplier` does not override `getHDLName`, so the lookup's default applies and no
  /// override is supplied here.
  ///
  /// - Parameter modeAttribute: `Comparator.modeAttr` from `LogisimStd`; the *same object* the
  ///   component's attribute set holds (`AnyAttribute` compares by `===`, D4).
  public static func multiplier(modeAttribute: AnyAttribute) -> HdlGeneratorLookup.Registration {
    let generator = MultiplierHdlGeneratorFactory(modeAttribute: modeAttribute)
    return HdlGeneratorLookup.Registration(generator: { _ in generator })
  }

  /// `Comparator.getHDLName`: `BitComparator` at width 1.
  ///
  /// - Parameter modeAttribute: `Comparator.modeAttr` from `LogisimStd`.
  public static func comparator(modeAttribute: AnyAttribute) -> HdlGeneratorLookup.Registration {
    let generator = ComparatorHdlGeneratorFactory(modeAttribute: modeAttribute)
    return HdlGeneratorLookup.Registration(
      generator: { _ in generator },
      hdlName: { attrs in
        attrs.arithHdlWidth == 1 ? "BitComparator" : CorrectLabel.correctLabel(comparatorName)
      })
  }

  /// `Shifter.getHDLName`: `"Shifter_" + width + "_bit"`, unconditionally; note it is *not*
  /// passed through `CorrectLabel`, matching upstream.
  ///
  /// - Parameter shiftAttribute: `Shifter.attrShift` from `LogisimStd`.
  public static func shifter(shiftAttribute: AnyAttribute) -> HdlGeneratorLookup.Registration {
    let generator = ShifterHdlGeneratorFactory(shiftAttribute: shiftAttribute)
    return HdlGeneratorLookup.Registration(
      generator: { _ in generator },
      hdlName: { attrs in "Shifter_\(attrs.arithHdlWidth)_bit" })
  }
}
