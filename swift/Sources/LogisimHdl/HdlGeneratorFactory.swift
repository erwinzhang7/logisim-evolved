// HdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/HdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Every per-component HDL generator (~80 classes upstream, living in `std/` next to the
// component they describe: LogisimStd's responsibility, not this module's) implements this
// protocol. `AbstractHdlGeneratorFactory` supplies working defaults for all of it.

import LogisimKernel

/// Shared string/numeric constants every `HdlGeneratorFactory` conformer and its callers need.
/// Java declares these as interface constants on `HdlGeneratorFactory` itself (plus, for the
/// clock-tree indices, on `com.cburch.logisim.std.wiring.ClockHdlGeneratorFactory`); gathered
/// here because they describe the framework's shared wiring conventions, not any one
/// component, which is what lets `AbstractHdlGeneratorFactory.getPortMap` use the clock-tree
/// indices without depending on the concrete `Clock` component's generator (owned by
/// `LogisimStd`, which instead depends on this module).
public enum HdlGeneratorNames {
  public static let netName = Hdl.netName
  public static let busName = Hdl.busName
  public static let clockTreeName = "logisimClockTree"
  public static let localInputBubbleBusName = "logisimInputBubbles"
  public static let localOutputBubbleBusName = "logisimOutputBubbles"
  public static let localInOutBubbleBusName = "logisimInOutBubbles"
  public static let fpgaTopLevelName = "logisimTopLevelShell"

  /// `ClockHdlGeneratorFactory`'s global clock-tree tap indices, used by
  /// `AbstractHdlGeneratorFactory.getPortMap` for every component with a clock pin, not only
  /// the `Clock` component itself.
  public enum ClockTreeIndex {
    public static let derivedClock = 0
    public static let invertedDerivedClock = 1
    public static let positiveEdgeTick = 2
    public static let negativeEdgeTick = 3
    public static let globalClock = 4
  }
}

/// `com.cburch.logisim.fpga.hdlgenerator.HdlGeneratorFactory`.
public protocol HdlGeneratorFactory: AnyObject {
  /// `generateAllHDLDescriptions`. Upstream's default implementation just returns `true`
  /// (nothing to recurse into); only the vendor toolchain integrations override it, and those
  /// are out of scope (D11).
  func generateAllHdlDescriptions(
    handledComponents: inout Set<String>, workingDirectory: String, hierarchy: [String]
  ) -> Bool

  func getEntity(netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String) -> [String]

  /// `nil` where Java returns `null`: a Verilog signal-declaration bundle referencing an
  /// undeclared generic parameter, reported through `Reporter` before returning.
  func getArchitecture(netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String)
    -> [String]?

  func getComponentInstantiation(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> LineBuffer

  /// `throws` because a component whose attribute set does not satisfy the generator's declared
  /// parameter list raises a catchable `UnsupportedOperationException` upstream (D13).
  func getComponentMap(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: (any HdlNetlistComponent)?,
    name: String
  ) throws -> LineBuffer

  func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer

  var relativeDirectory: String { get }

  func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool

  var isOnlyInlined: Bool { get }
}
