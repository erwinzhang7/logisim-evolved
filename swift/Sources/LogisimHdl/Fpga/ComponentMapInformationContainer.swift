// ComponentMapInformationContainer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution
// `com/cburch/logisim/fpga/data/ComponentMapInformationContainer.java` (112 lines), reference
// tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.

/// How many *bubbles* a component contributes, and what each is called.
///
/// A "bubble" is one board-facing signal of a component: one LED, one switch, one segment. The
/// toplevel generator wires `s_LOGISIM_INPUT_BUBBLES`/`_OUTPUT_`/`_INOUT_` buses to the FPGA's
/// physical pins, and this container is how a component declares its slice of them.
///
/// Every `InstanceFactory` upstream returns one from
/// `getInstanceFactory().getComponentMapInformation()`; `Netlist.constructHierarchyTree` sums
/// them into the global bubble tree that `MapComponent` then indexes. **Neither of those is
/// ported**, see `Fpga/FpgaNotPorted.swift`, so nothing in-tree constructs this yet. It is here
/// because it is 112 lines with no dependencies, it is what the two blocked layers above will be
/// written against, and having it makes the shape of the gap concrete instead of hypothetical.
public final class ComponentMapInformationContainer {

  public private(set) var numberOfInputBubbles: Int
  public private(set) var numberOfOutputBubbles: Int
  public private(set) var numberOfInOutBubbles: Int

  private var inputBubbleLabels: [String]?
  private var outputBubbleLabels: [String]?
  private var inOutBubbleLabels: [String]?

  /// `ComponentMapInformationContainer(int, int, int, List, List, List)`.
  public init(
    inputPorts: Int,
    outputPorts: Int,
    inOutPorts: Int,
    inputLabels: [String]?,
    outputLabels: [String]?,
    inOutLabels: [String]?
  ) {
    numberOfInputBubbles = inputPorts
    numberOfOutputBubbles = outputPorts
    numberOfInOutBubbles = inOutPorts
    inputBubbleLabels = inputLabels
    outputBubbleLabels = outputLabels
    inOutBubbleLabels = inOutLabels
  }

  /// `ComponentMapInformationContainer(int, int, int)`: counts without labels, which is what a
  /// component that names its bubbles positionally uses.
  public convenience init(inputPorts: Int, outputPorts: Int, inOutPorts: Int) {
    self.init(
      inputPorts: inputPorts, outputPorts: outputPorts, inOutPorts: inOutPorts,
      inputLabels: nil, outputLabels: nil, inOutLabels: nil)
  }

  /// `clone()`. Upstream copies the three lists so the clone can be relabelled independently;
  /// Swift arrays are values, so the assignment already is the copy.
  public func cloned() -> ComponentMapInformationContainer {
    ComponentMapInformationContainer(
      inputPorts: numberOfInputBubbles,
      outputPorts: numberOfOutputBubbles,
      inOutPorts: numberOfInOutBubbles,
      inputLabels: inputBubbleLabels,
      outputLabels: outputBubbleLabels,
      inOutLabels: inOutBubbleLabels)
  }

  /// `getInPortLabel(int)`. The fallback is the index as a decimal string: for a missing list
  /// *and* for an index past its end, which is how a component that grew a port keeps working.
  public func inputPortLabel(_ index: Int) -> String {
    label(from: inputBubbleLabels, index)
  }

  public func outputPortLabel(_ index: Int) -> String {
    label(from: outputBubbleLabels, index)
  }

  /// `getInOutportLabel(int)`; upstream's lowercase `p` is a typo, corrected in the Swift name.
  public func inOutPortLabel(_ index: Int) -> String {
    label(from: inOutBubbleLabels, index)
  }

  private func label(from labels: [String]?, _ index: Int) -> String {
    guard let labels, labels.count > index, index >= 0 else { return String(index) }
    return labels[index]
  }

  public func setNumberOfInputPorts(_ count: Int, labels: [String]?) {
    numberOfInputBubbles = count
    inputBubbleLabels = labels
  }

  public func setNumberOfOutputPorts(_ count: Int, labels: [String]?) {
    numberOfOutputBubbles = count
    outputBubbleLabels = labels
  }

  public func setNumberOfInOutPorts(_ count: Int, labels: [String]?) {
    numberOfInOutBubbles = count
    inOutBubbleLabels = labels
  }
}
