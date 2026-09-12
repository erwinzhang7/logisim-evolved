// GateLogicHdlGenerators: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution): the
// eight private `…HdlGeneratorFactory` classes nested inside
// `com/cburch/logisim/std/gates/AndGate.java`, `OrGate.java`, `NandGate.java`, `NorGate.java`,
// `XorGate.java`, `XnorGate.java`, `OddParityGate.java` and `EvenParityGate.java`. Copyright by
// the Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Each is a few lines overriding `getLogicFunction` on `AbstractGateHdlGenerator`; upstream
// keeps them as private static inner classes next to the gate, which is why they have no files
// of their own to mirror. Gathered here rather than scattered across eight two-line files.
//
// Note XNOR and Even Parity share a class *name* upstream (`XNorGateHdlGeneratorFactory`) while
// having different bodies: Even Parity always emits parity, XNOR switches on the one-hot
// attribute. They are distinct types here, named for the gate rather than for the collision.

import LogisimKernel

/// `AndGate.AndGateHdlGeneratorFactory`.
public final class AndGateHdlGenerator: AbstractGateHdlGenerator {

  /// AND's unconnected input must read as the identity element, so the sense is inverted
  /// relative to the base class.
  public override func getFloatingValue(_ isInverted: Bool) -> Bool { isInverted }

  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    GateLogic.chain(operator: Hdl.andOperator(), nrOfInputs: nrOfInputs, inverted: false)
  }
}

/// `OrGate.OrGateHdlGeneratorFactory`.
public final class OrGateHdlGenerator: AbstractGateHdlGenerator {
  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    GateLogic.chain(operator: Hdl.orOperator(), nrOfInputs: nrOfInputs, inverted: false)
  }
}

/// `NandGate.NandGateHdlGeneratorFactory`.
public final class NandGateHdlGenerator: AbstractGateHdlGenerator {
  public override func getFloatingValue(_ isInverted: Bool) -> Bool { isInverted }

  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    GateLogic.chain(operator: Hdl.andOperator(), nrOfInputs: nrOfInputs, inverted: true)
  }
}

/// `NorGate.NorGateHdlGeneratorFactory`.
public final class NorGateHdlGenerator: AbstractGateHdlGenerator {
  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    GateLogic.chain(operator: Hdl.orOperator(), nrOfInputs: nrOfInputs, inverted: true)
  }
}

/// `XorGate.XorGateHdlGeneratorFactory`.
public final class XorGateHdlGenerator: AbstractGateHdlGenerator {
  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    // Upstream builds a *plain* buffer here, not an HDL one, and copies the sub-buffer into it.
    // The distinction is invisible in the output (the sub-buffer's pairs are already applied)
    // but is preserved so the two sides cannot drift on a future placeholder.
    LineBuffer.getBuffer().add(
      isOneHot
        ? getOneHot(inverted: false, nrOfInputs: nrOfInputs, isBus: bitWidth > 1)
        : Self.getParity(inverted: false, nrOfInputs: nrOfInputs, isBus: bitWidth > 1))
  }
}

/// `XnorGate.XNorGateHdlGeneratorFactory`.
public final class XnorGateHdlGenerator: AbstractGateHdlGenerator {
  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    LineBuffer.getBuffer().add(
      isOneHot
        ? getOneHot(inverted: true, nrOfInputs: nrOfInputs, isBus: bitWidth > 1)
        : Self.getParity(inverted: true, nrOfInputs: nrOfInputs, isBus: bitWidth > 1))
  }
}

/// `OddParityGate.XorGateHdlGeneratorFactory`. Always parity; an Odd Parity component has no
/// `xor` attribute, so the one-hot branch is unreachable for it upstream too.
public final class OddParityGateHdlGenerator: AbstractGateHdlGenerator {
  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    LineBuffer.getBuffer().add(
      Self.getParity(inverted: false, nrOfInputs: nrOfInputs, isBus: bitWidth > 1))
  }
}

/// `EvenParityGate.XNorGateHdlGeneratorFactory`.
public final class EvenParityGateHdlGenerator: AbstractGateHdlGenerator {
  public override func getLogicFunction(nrOfInputs: Int, bitWidth: Int, isOneHot: Bool)
    -> LineBuffer
  {
    LineBuffer.getBuffer().add(
      Self.getParity(inverted: true, nrOfInputs: nrOfInputs, isBus: bitWidth > 1))
  }
}

/// The AND/OR/NAND/NOR bodies, which upstream repeats four times with only the operator and the
/// surrounding `NOT( … )` differing. Folding them changes no emitted character: the alignment
/// column is `oneLine.length()` after the assignment preamble, which already accounts for the
/// `NOT(` when present.
enum GateLogic {
  static func chain(operator operatorText: String, nrOfInputs: Int, inverted: Bool) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    var oneLine = Hdl.assignPreamble() + "result" + Hdl.assignOperator()
    if inverted { oneLine += Hdl.notOperator() + "(" }
    let tabWidth = oneLine.count
    var first = true
    for index in 0..<nrOfInputs {
      if !first {
        oneLine += operatorText
        contents.add(oneLine, applyMap: false)
        oneLine = String(repeating: " ", count: tabWidth)
      } else {
        first = false
      }
      oneLine += "s_realInput\(index + 1)"
    }
    oneLine += inverted ? ");" : ";"
    contents.add(oneLine, applyMap: false)
    return contents
  }
}
