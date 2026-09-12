// InlinedHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/InlinedHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// The base for components that never become their own entity/module: they splice code
// straight into the parent's architecture/module body (`getInlinedCode`) instead. Every other
// `HdlGeneratorFactory` method is meaningless for such a component, and Java enforces that with
// `IllegalAccessError`; the port traps the same way; those are genuine programmer errors (a
// caller invoking the wrong half of the interface), never something a `.circ` file can trigger
// (D13).

import LogisimKernel

/// `com.cburch.logisim.fpga.hdlgenerator.InlinedHdlGeneratorFactory`.
open class InlinedHdlGeneratorFactory: HdlGeneratorFactory {
  public init() {}

  open func generateAllHdlDescriptions(
    handledComponents: inout Set<String>, workingDirectory: String, hierarchy: [String]
  ) -> Bool {
    preconditionFailure("BUG: generateAllHDLDescriptions not supported")
  }

  open func getArchitecture(netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String)
    -> [String]?
  {
    preconditionFailure("BUG: getArchitecture not supported")
  }

  open func getComponentInstantiation(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> LineBuffer {
    preconditionFailure("BUG: getComponentInstantiation not supported")
  }

  open func getComponentMap(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: (any HdlNetlistComponent)?,
    name: String
  ) throws -> LineBuffer {
    preconditionFailure("BUG: getComponentMap not supported")
  }

  open func getEntity(netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String)
    -> [String]
  {
    preconditionFailure("BUG: getEntity not supported")
  }

  open func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    LineBuffer.getHdlBuffer()
  }

  open var relativeDirectory: String {
    preconditionFailure("BUG: getRelativeDirectory not supported")
  }

  open func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool { true }

  open var isOnlyInlined: Bool { true }
}
