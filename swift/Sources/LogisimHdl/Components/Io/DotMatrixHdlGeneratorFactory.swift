// DotMatrixHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/DotMatrixHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// The simulator addresses a dot matrix with row 0 at the *bottom*; the LED-matrix bubble vector
// has row 0 at the top. Upstream compensates by inverting rows in the column-driven and
// select-driven cases, and columns in the row-driven case; the two comment blocks in the Java
// are reproduced verbatim below because they are the only statement of that convention.
//
// Note the asymmetry, which is upstream's and is preserved: in the column and select cases the
// bubble index is computed from the *inverted* row (`ledMatrixRow`), while in the row case it is
// computed from the *un-inverted* column (`dotMatrixCol`). The three branches are therefore not
// mirror images of one another.

import LogisimKernel

/// `com.cburch.logisim.std.io.DotMatrixHdlGeneratorFactory`.
public final class DotMatrixHdlGeneratorFactory: InlinedHdlGeneratorFactory {
  private let attributes: IoHdlAttributes

  public init(attributes: IoHdlAttributes = IoHdlAttributes()) {
    self.attributes = attributes
    super.init()
  }

  public override func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    let attrs = componentInfo.attributeSet
    let inputType = attributes.dotMatrixInputType(attrs)
    let rows = attributes.dotMatrixRows(attrs)
    let cols = attributes.dotMatrixColumns(attrs)
    let outputStart = componentInfo.localBubbleOutputStart
    var wires: [String: String] = [:]

    func bubble(_ index: Int) -> String {
      LineBuffer.formatHdl(
        "{{1}}{{<}}{{2}}{{>}}", HdlGeneratorNames.localOutputBubbleBusName, index)
    }

    switch inputType {
    case .column:
      /* The simulator uses here following addressing scheme (2x2):
       *  r1,c0 r1,c1
       *  r0,c0 r0,c1
       *
       *  hence the rows are inverted to the definition of the LED-Matrix that uses:
       *  r0,c0 r0,c1
       *  r1,c0 r1,c1
       */
      for dotMatrixRow in 0..<max(0, rows) {
        let ledMatrixRow = rows - dotMatrixRow - 1
        for ledMatrixCol in 0..<max(0, cols) {
          let wire =
            rows == 1
            ? Hdl.getNetName(
              componentInfo, endIndex: ledMatrixCol, floatingNetTiedToGround: true,
              netlist: netlist)
            : Hdl.getBusEntryName(
              componentInfo, endIndex: ledMatrixCol, floatingNetTiedToGround: true,
              bitIndex: dotMatrixRow, netlist: netlist)
          wires[bubble((ledMatrixRow * cols) + ledMatrixCol + outputStart)] = wire
        }
      }

    case .row:
      /* The simulator uses here following addressing scheme (2x2):
       *  r1,c1 r1,c0
       *  r0,c1 r0,c0
       *
       *  hence the cols are inverted to the definition of the LED-Matrix that uses:
       *  r0,c0 r0,c1
       *  r1,c0 r1,c1
       */
      for ledMatrixRow in 0..<max(0, rows) {
        for dotMatrixCol in 0..<max(0, cols) {
          let ledMatrixCol = cols - dotMatrixCol - 1
          let wire =
            cols == 1
            ? Hdl.getNetName(
              componentInfo, endIndex: ledMatrixRow, floatingNetTiedToGround: true,
              netlist: netlist)
            : Hdl.getBusEntryName(
              componentInfo, endIndex: ledMatrixRow, floatingNetTiedToGround: true,
              bitIndex: ledMatrixCol, netlist: netlist)
          wires[bubble((ledMatrixRow * cols) + dotMatrixCol + outputStart)] = wire
        }
      }

    case .select:
      /* The simulator uses here following addressing scheme (2x2):
       *  r1,c0 r1,c1
       *  r0,c0 r0,c1
       *
       *  hence the rows are inverted to the definition of the LED-Matrix that uses:
       *  r0,c0 r0,c1
       *  r1,c0 r1,c1
       */
      for dotMatrixRow in 0..<max(0, rows) {
        let ledMatrixRow = rows - dotMatrixRow - 1
        for ledMatrixCol in 0..<max(0, cols) {
          let rowWire =
            rows == 1
            ? Hdl.getNetName(
              componentInfo, endIndex: 1, floatingNetTiedToGround: true, netlist: netlist)
            : Hdl.getBusEntryName(
              componentInfo, endIndex: 1, floatingNetTiedToGround: true, bitIndex: dotMatrixRow,
              netlist: netlist)
          let colWire =
            cols == 1
            ? Hdl.getNetName(
              componentInfo, endIndex: 0, floatingNetTiedToGround: true, netlist: netlist)
            : Hdl.getBusEntryName(
              componentInfo, endIndex: 0, floatingNetTiedToGround: true, bitIndex: ledMatrixCol,
              netlist: netlist)
          wires[bubble((ledMatrixRow * cols) + ledMatrixCol + outputStart)] =
            LineBuffer.formatHdl("{{1}}{{and}}{{2}}", rowWire, colWire)
        }
      }
    }

    Hdl.addAllWiresSorted(contents, wires: &wires)
    return contents
  }

  /// `DotMatrixHdlGeneratorFactory.isHdlSupportedTarget`: `attrs.getValue(DotMatrixBase.ATTR_PERSIST) == 0`.
  public override func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool {
    attributes.persistTicks(attrs) == 0
  }
}
