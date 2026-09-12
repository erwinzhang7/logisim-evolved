// MemoryHdlGenerators: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// `getHDLGenerator` / `getHDLName` / `isHDLSupportedComponent` answers the `std/memory`
// component factories give (`AbstractComponentFactory.java:102-137` plus the `getHDLName`
// overrides in `AbstractFlipFlop`, `Register`, `Counter`, `Random` and `Ram`). Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore licensed
// GPL-3.0-only. See LICENSE.md.
//
// ── What this file is ───────────────────────────────────────────────────────────────────────
//
// `HdlGeneratorLookup` takes the mapping from `ComponentFactory.name` to a generator as *data*,
// deliberately, so that a family's generators can land without editing the shared registry (see
// that file's header). This is the memory family's half of that contract: a dictionary of
// ready-made `Registration`s. It does **not** install itself; installation is one call,
// `HdlGeneratorLookup.shared.register(factoryName:_:)` per entry, made by whichever module owns
// wiring the standard library up.
//
// ── The two facts a registration has to get right ───────────────────────────────────────────
//
//  1. **`getHDLGenerator` returns `null` when the target is unsupported.**
//     `AbstractComponentFactory.getHDLGenerator` is `isHDLSupportedComponent(attrs) ?
//     myHDLGenerator : null`, and `isHDLSupportedComponent` is
//     `myHDLGenerator.isHdlSupportedTarget(attrs)`. So a RAM configured with a bidirectional
//     data bus, or a ROM with a multi-line layout, has *no* generator at all and drops out of
//     `Netlist.myComponents` entirely. Every closure below applies that filter; returning the
//     generator unconditionally would put unsynthesizable components into the netlist.
//
//  2. **`getHDLName` is overridden by five of these factories and the overrides are not
//     cosmetic**; the string becomes the VHDL entity name and the Verilog module name, and the
//     port has no other source for it. `Register` and the flip-flops even switch on the trigger
//     attribute (`…_FLIP_FLOP` vs `…_LATCH`), so the name is a function of the attribute set,
//     which is exactly why `Registration.hdlName` takes one.

import LogisimFile
import LogisimKernel

/// The `std/memory` family's `HdlGeneratorLookup` registrations, keyed by
/// `ComponentFactory.name`: the exact strings `.circ` files carry.
public enum MemoryHdlGenerators {

  /// `DFlipFlop._ID`, …; restated here because `LogisimStd` is not importable from this module
  /// and these strings are the registry's keys. They are `.circ` tokens and cannot change.
  public enum FactoryName {
    public static let dFlipFlop = "D Flip-Flop"
    public static let tFlipFlop = "T Flip-Flop"
    public static let jkFlipFlop = "J-K Flip-Flop"
    public static let srFlipFlop = "S-R Flip-Flop"
    public static let register = "Register"
    public static let counter = "Counter"
    public static let shiftRegister = "Shift Register"
    public static let random = "Random"
    public static let ram = "RAM"
    public static let rom = "ROM"
  }

  /// Every registration, ready to hand to `HdlGeneratorLookup.shared.register(factoryName:_:)`.
  ///
  /// - Parameter romContents: how to read one word out of a ROM's `contents` attribute. `Rom`'s
  ///   `MemContents` lives in `LogisimStd`, which this module cannot import, so the reader is
  ///   injected; the same technique `AbstractHdlGeneratorFactory` uses for `StdAttr` and
  ///   `HdlParameters` for `StdAttr.WIDTH`. Left `nil`, a ROM's inlined code is generated from an
  ///   all-zero image, which is wrong, so the caller must supply it; see
  ///   `MemoryRomHdlGeneratorFactory`.
  public static func registrations(
    romContents: MemoryHdlContentsReader? = nil
  ) -> [String: HdlGeneratorLookup.Registration] {
    var result: [String: HdlGeneratorLookup.Registration] = [:]

    result[FactoryName.dFlipFlop] = flipFlopRegistration(
      name: FactoryName.dFlipFlop, make: { MemoryDFlipFlopHdlGeneratorFactory() })
    result[FactoryName.tFlipFlop] = flipFlopRegistration(
      name: FactoryName.tFlipFlop, make: { MemoryTFlipFlopHdlGeneratorFactory() })
    result[FactoryName.jkFlipFlop] = flipFlopRegistration(
      name: FactoryName.jkFlipFlop, make: { MemoryJKFlipFlopHdlGeneratorFactory() })
    result[FactoryName.srFlipFlop] = flipFlopRegistration(
      name: FactoryName.srFlipFlop, make: { MemorySRFlipFlopHdlGeneratorFactory() })

    result[FactoryName.register] = HdlGeneratorLookup.Registration(
      generator: { attrs in gate(MemoryRegisterHdlGeneratorFactory(), attrs) },
      hdlName: { attrs in registerHdlName(attrs) })

    result[FactoryName.counter] = HdlGeneratorLookup.Registration(
      generator: { attrs in gate(MemoryCounterHdlGeneratorFactory(attrs: attrs), attrs) },
      hdlName: { _ in "LogisimCounter" })

    result[FactoryName.shiftRegister] = HdlGeneratorLookup.Registration(
      generator: { attrs in gate(MemoryShiftRegisterHdlGeneratorFactory(attrs: attrs), attrs) })

    result[FactoryName.random] = HdlGeneratorLookup.Registration(
      generator: { attrs in gate(MemoryRandomHdlGeneratorFactory(attrs: attrs), attrs) },
      hdlName: { _ in "LogisimRNG" })

    result[FactoryName.ram] = HdlGeneratorLookup.Registration(
      generator: { attrs in gate(MemoryRamHdlGeneratorFactory(), attrs) },
      hdlName: { attrs in ramHdlName(attrs) })

    result[FactoryName.rom] = HdlGeneratorLookup.Registration(
      generator: { attrs in gate(MemoryRomHdlGeneratorFactory(contents: romContents), attrs) })

    return result
  }

  /// `AbstractComponentFactory.getHDLGenerator`: the generator, or `nil` when it says it cannot
  /// synthesize this attribute set.
  private static func gate(_ generator: any HdlGeneratorFactory, _ attrs: any AttributeSet)
    -> (any HdlGeneratorFactory)?
  {
    generator.isHdlSupportedTarget(attrs: attrs) ? generator : nil
  }

  private static func flipFlopRegistration(
    name: String, make: @escaping () -> MemoryAbstractFlipFlopHdlGeneratorFactory
  ) -> HdlGeneratorLookup.Registration {
    HdlGeneratorLookup.Registration(
      generator: { attrs in gate(make(), attrs) },
      hdlName: { attrs in flipFlopHdlName(factoryName: name, attrs) })
  }

  // MARK: - getHDLName overrides

  /// `AbstractFlipFlop.getHDLName(AttributeSet)` (`AbstractFlipFlop.java:242-263`).
  ///
  /// Note the `else` arm of the innermost branch: when *neither* trigger attribute is present
  /// the answer is `FLIPFLOP`, not `LATCH`. That looks like an oversight and is preserved.
  public static func flipFlopHdlName(factoryName: String, _ attrs: any AttributeSet) -> String {
    // Java's `String.split(" ")` on "D Flip-Flop" / "S-R Flip-Flop"; only part 0 is used.
    let firstWord = factoryName.split(separator: " ", omittingEmptySubsequences: false).first
      .map(String.init) ?? factoryName
    var completeName = firstWord.replacingOccurrences(of: "-", with: "_").uppercased()
    completeName += "_"
    if attrs.containsAttribute(StdAttr.edgeTrigger) {
      completeName += "FlipFlop".uppercased()
    } else if attrs.containsAttribute(StdAttr.trigger) {
      let trigger = attrs.getValue(StdAttr.trigger)
      completeName +=
        (trigger == StdAttr.triggerFalling || trigger == StdAttr.triggerRising)
        ? "FlipFlop".uppercased() : "Latch".uppercased()
    } else {
      completeName += "FlipFlop".uppercased()
    }
    return completeName
  }

  /// `Register.getHDLName(AttributeSet)` (`Register.java:280-291`).
  public static func registerHdlName(_ attrs: any AttributeSet) -> String {
    var completeName = CorrectLabel.correctLabel(FactoryName.register).uppercased()
    let trigger = attrs.getValue(StdAttr.trigger)
    completeName +=
      (trigger == StdAttr.triggerFalling || trigger == StdAttr.triggerRising)
      ? "_FLIP_FLOP" : "_LATCH"
    return completeName
  }

  /// `Ram.getHDLName(AttributeSet)` (`Ram.java:121-128`).
  public static func ramHdlName(_ attrs: any AttributeSet) -> String {
    let label = CorrectLabel.correctLabel(attrs.getValue(StdAttr.label) ?? "")
    return label.isEmpty ? "RAM" : "RAMCONTENTS_\(label)"
  }
}
