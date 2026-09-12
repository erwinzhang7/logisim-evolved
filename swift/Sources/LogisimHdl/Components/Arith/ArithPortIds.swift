// ArithPortIds: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// the `IN0`/`IN1`/`OUT`/`C_IN`/`C_OUT`/`B_IN`/`B_OUT`/`UPPER`/`REM` constants on
// `com/cburch/logisim/std/arith/{Adder,Subtractor,Multiplier,Divider,Negator,Comparator,
// Shifter}.java`. Copyright by the Logisim-evolution developers. This translation is a
// derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// These are the *component pin indices* an HDL port maps onto: the index into the placed
// component's end list, which the netlist resolves to a net. Upstream's generators read them
// off the component class (`Adder.IN0`); those classes live in `LogisimStd`, which this module
// must not name (see `ArithHdlSupport.swift`'s header and `HdlGeneratorLookup.swift`'s).
//
// Duplicating a constant is normally the wrong answer, so this is deliberate and bounded: the
// values are frozen by the on-disk port order of every component that has ever been placed in a
// `.circ` file, changing one would silently rewire saved circuits, and there are 26 of them.
// `ArithHdlGeneratorTests.testPortIdsMatchLogisimStd` asserts each one against the `LogisimStd`
// constant it mirrors, so a future divergence is a test failure rather than wrong HDL.

/// Component pin indices for the `std/arith` family.
public enum ArithPortIds {
  /// `com.cburch.logisim.std.arith.Adder`.
  public enum Adder {
    public static let in0 = 0
    public static let in1 = 1
    public static let out = 2
    public static let carryIn = 3
    public static let carryOut = 4
  }

  /// `com.cburch.logisim.std.arith.Subtractor`.
  public enum Subtractor {
    public static let in0 = 0
    public static let in1 = 1
    public static let out = 2
    public static let borrowIn = 3
    public static let borrowOut = 4
  }

  /// `com.cburch.logisim.std.arith.Multiplier`.
  public enum Multiplier {
    public static let in0 = 0
    public static let in1 = 1
    public static let out = 2
    public static let carryIn = 3
    public static let carryOut = 4
  }

  /// `com.cburch.logisim.std.arith.Divider`.
  public enum Divider {
    public static let in0 = 0
    public static let in1 = 1
    public static let out = 2
    public static let upper = 3
    public static let rem = 4
  }

  /// `com.cburch.logisim.std.arith.Negator`.
  public enum Negator {
    public static let inPort = 0
    public static let outPort = 1
  }

  /// `com.cburch.logisim.std.arith.Comparator`.
  public enum Comparator {
    public static let in0 = 0
    public static let in1 = 1
    public static let greaterThan = 2
    public static let equal = 3
    public static let lessThan = 4
  }

  /// `com.cburch.logisim.std.arith.Shifter`.
  public enum Shifter {
    public static let in0 = 0
    public static let in1 = 1
    public static let out = 2
  }
}
