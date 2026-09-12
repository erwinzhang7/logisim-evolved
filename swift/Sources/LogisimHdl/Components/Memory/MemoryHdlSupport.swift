// MemoryHdlSupport: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the shared pieces of `com/cburch/logisim/std/memory/*HdlGeneratorFactory.java`:
// `AbstractFlipFlopHdlGeneratorFactory.TRIGGER_MAP`, the `subDirectoryName` every memory
// generator infers from its package, and the `StdAttr` identities they all read. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// ── Where these generators live, and why here rather than in LogisimStd ─────────────────────
//
// Upstream keeps each generator next to its component in `std/memory/`. This port cannot: the
// generators subclass `AbstractHdlGeneratorFactory`, which lives in `LogisimHdl`, and
// `Package.swift` records that `LogisimStd` does not (yet) depend on `LogisimHdl`. So they live
// on the HDL side of the boundary and are attached to a factory name through
// `HdlGeneratorLookup`, exactly as that file's header prescribes.
//
// ── The attribute problem, and how it is solved ─────────────────────────────────────────────
//
// A memory generator reads two kinds of attribute:
//
//   * `StdAttr.WIDTH`/`TRIGGER`/`EDGE_TRIGGER`/`LABEL`/`APPEARANCE`: these live in
//     `LogisimFile`, which `LogisimHdl` already depends on, so they are referenced directly and
//     attribute identity (D4) is automatically the same object the component uses.
//
//   * component-specific ones, `Counter.ATTR_MAX`, `ShiftRegister.ATTR_LENGTH`, `Mem.DATA_ATTR`,
//     `RamAttributes.ATTR_ByteEnables`, …, which live in `LogisimStd` and are unreachable from
//     here. Those are resolved **by name off the component's own attribute set**
//     (`AttributeSet.attribute(named:)`). That returns the very object the set holds, so
//     `containsAttribute`'s reference comparison still succeeds; it is not a lookalike. The
//     names are the `.circ` serialisation tokens, which cannot change without breaking every
//     saved file, so they are as stable an identity as the Java field reference is.
//
// This is why every generator here is constructed *per component* from the registration closure
// (`HdlGeneratorLookup.Registration.generator`, which is handed the `AttributeSet`) rather than
// once as a shared singleton the way Java does it. That is also strictly safer: upstream shares
// one generator instance across every placement of a component and mutates its `myPorts`
// through `getGenerationTimeWiresPorts`.
//
// ── AttributeOption identity ────────────────────────────────────────────────────────────────
//
// `AttributeOption` is a Swift *struct* with value semantics (`Attributes.swift`), unlike Java's
// identity-compared object. So an option constant needed here can simply be rebuilt with the
// same name/payload and compares equal to the component's, which is what lets, for example,
// `Counter.ON_GOAL_WRAP` be named without importing `Counter`. Constructor choice matters:
// `AttributeOption(value:)` also sets a `.string` payload, `AttributeOption(name:)` does not,
// and the two do *not* compare equal. Each constant below mirrors the constructor its
// `LogisimStd` counterpart uses.

import LogisimFile
import LogisimKernel

/// Shared constants and attribute plumbing for the `std/memory` HDL generators.
public enum MemoryHdl {

  /// The `subDirectoryName` upstream's no-argument `AbstractHdlGeneratorFactory` constructor
  /// derives by splitting `getClass().toString()` on `.`/space and taking the second-to-last
  /// part: for every class in `com.cburch.logisim.std.memory` that is the literal `"memory"`.
  /// Swift modules do not mirror source directories at runtime, so it is written out (see
  /// `AbstractHdlGeneratorFactory.swift`'s header).
  public static let subdirectory = "memory"

  /// `AbstractFlipFlopHdlGeneratorFactory.TRIGGER_MAP`. Note it is keyed by *four* options while
  /// `StdAttr.EDGE_TRIGGER` only offers two: the same map serves both trigger attributes.
  public static let triggerMap: [AttributeOption: Int64] = [
    StdAttr.triggerHigh: 0,
    StdAttr.triggerLow: 1,
    StdAttr.triggerFalling: 1,
    StdAttr.triggerRising: 0,
  ]

  /// The `StdAttr` bundle `AbstractHdlGeneratorFactory.getPortMap` needs to classify a clock
  /// pin, and the same predicate `Netlist.isFlipFlop(AttributeSet)` applies
  /// (`Netlist.java:2471-2477`).
  public static let clockAttributes = HdlClockAttributes(
    edgeTrigger: StdAttr.edgeTrigger,
    trigger: StdAttr.trigger,
    risingOption: StdAttr.triggerRising,
    fallingOption: StdAttr.triggerFalling,
    lowOption: StdAttr.triggerLow)

  /// `Netlist.isFlipFlop(AttributeSet)`, spelled out here because several `getModuleFunctionality`
  /// bodies branch on it directly rather than through the port map.
  public static func isFlipFlop(_ attrs: any AttributeSet) -> Bool {
    clockAttributes.isFlipFlop(attrs)
  }

  // MARK: - Component attribute identities resolved by name

  /// The `.circ` serialisation name of every `LogisimStd` attribute a memory generator reads.
  /// Kept in one place so a rename on either side is a single-file change and so the mapping
  /// back to the Java field is written down.
  public enum AttributeName {
    /// `Counter.ATTR_MAX`.
    public static let counterMax = "max"
    /// `Counter.ATTR_ON_GOAL`.
    public static let counterOnGoal = "ongoal"
    /// `ShiftRegister.ATTR_LENGTH`.
    public static let shiftRegisterLength = "length"
    /// `ShiftRegister.ATTR_LOAD`.
    public static let shiftRegisterLoad = "parallel"
    /// `Random.ATTR_SEED`.
    public static let randomSeed = "seed"
    /// `Mem.ADDR_ATTR`.
    public static let memAddress = "addrWidth"
    /// `Mem.DATA_ATTR`.
    public static let memData = "dataWidth"
    /// `Mem.LINE_ATTR`.
    public static let memLine = "line"
    /// `Mem.ENABLES_ATTR`.
    public static let memEnables = "enables"
    /// `Mem.ASYNC_READ`.
    public static let memAsyncRead = "asyncread"
    /// `Mem.READ_ATTR`.
    public static let memReadBehavior = "readbehav"
    /// `RamAttributes.ATTR_DBUS`.
    public static let ramDataBus = "databus"
    /// `RamAttributes.ATTR_ByteEnables`.
    public static let ramByteEnables = "byteenables"
    /// `RamAttributes.CLEAR_PIN`.
    public static let ramClearPin = "clearpin"
  }

  /// Option constants owned by `LogisimStd`, rebuilt by value. See this file's header on why
  /// that is sound and why the constructor choice is load-bearing.
  public enum Option {
    /// `Counter.ON_GOAL_WRAP`: `new AttributeOption("wrap", …)`, so `.string` payload.
    public static let counterWrap = AttributeOption(value: "wrap")
    /// `Counter.ON_GOAL_STAY`.
    public static let counterStay = AttributeOption(value: "stay")
    /// `Counter.ON_GOAL_CONT`.
    public static let counterContinue = AttributeOption(value: "continue")
    /// `Counter.ON_GOAL_LOAD`.
    public static let counterLoad = AttributeOption(value: "load")
    /// `Mem.SINGLE`.
    public static let memSingle = AttributeOption(name: "single")
    /// `Mem.USELINEENABLES`.
    public static let memUseLineEnables = AttributeOption(name: "line")
    /// `Mem.READAFTERWRITE`.
    public static let memReadAfterWrite = AttributeOption(name: "raw")
    /// `RamAttributes.BUS_SEP`.
    public static let ramBusSeparate = AttributeOption(name: "bibus")
    /// `RamAttributes.BUS_WITH_BYTEENABLES`.
    public static let ramWithByteEnables = AttributeOption(name: "byteEnables")
  }

  // MARK: - Reading a `LogisimStd` attribute off a component's set

  /// The attribute named `name` in `attrs`, or `nil`. This is `AttributeSet.attribute(named:)`
  /// with the intent spelled out: it exists so `LogisimHdl` can name a `LogisimStd` attribute
  /// it cannot import, and it returns the set's *own* object, preserving D4 identity.
  public static func attribute(_ attrs: any AttributeSet, named name: String) -> AnyAttribute? {
    attrs.attribute(named: name)
  }

  /// `attrs.getValue(<BitWidth attribute named `name`>).getWidth()`, or `fallback` when the
  /// attribute is absent: mirroring Java, where an absent attribute yields `null` and every
  /// caller here has a documented default.
  public static func widthValue(_ attrs: any AttributeSet, named name: String, default fallback: Int)
    -> Int
  {
    guard let attribute = attrs.attribute(named: name),
      case .bitWidth(let width)? = attrs.rawValue(attribute)
    else { return fallback }
    return Int(width)
  }

  /// `attrs.getValue(<Integer/Long attribute named `name`>)`, or `fallback`.
  public static func integerValue(
    _ attrs: any AttributeSet, named name: String, default fallback: Int64
  ) -> Int64 {
    guard let attribute = attrs.attribute(named: name) else { return fallback }
    switch attrs.rawValue(attribute) {
    case .integer(let value): return Int64(value)
    case .long(let value): return value
    case .bitWidth(let width): return Int64(width)
    default: return fallback
    }
  }

  /// `attrs.getValue(<Boolean attribute named `name`>)`, or `fallback`.
  public static func booleanValue(
    _ attrs: any AttributeSet, named name: String, default fallback: Bool
  ) -> Bool {
    guard let attribute = attrs.attribute(named: name),
      case .boolean(let value)? = attrs.rawValue(attribute)
    else { return fallback }
    return value
  }

  /// `attrs.getValue(<AttributeOption attribute named `name`>)`. `nil` where Java's
  /// `getValue` returns `null`, because several RAM branches test `value != null` explicitly
  /// and treat "absent" differently from "present but not the option we want".
  public static func optionValue(_ attrs: any AttributeSet, named name: String) -> AttributeOption?
  {
    guard let attribute = attrs.attribute(named: name),
      case .option(let option)? = attrs.rawValue(attribute)
    else { return nil }
    return option
  }
}
