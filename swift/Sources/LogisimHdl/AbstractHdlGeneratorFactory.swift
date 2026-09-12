// AbstractHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/hdlgenerator/AbstractHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// The working default implementation of `HdlGeneratorFactory` every per-component generator
// (~80 classes, `LogisimStd`'s responsibility) subclasses: given a `myPorts`/`myWires`/
// `myTypedWires`/`myParametersList` declaration, it emits the VHDL entity+architecture or
// Verilog module text and the instantiation/port-map text a parent module needs to wire one in.
//
// ── The two StdAttr-shaped seams ─────────────────────────────────────────────────────────────
//
// `getPortMap`'s clock handling needs to know a component's trigger-edge attribute(s)
// (`StdAttr.EDGE_TRIGGER`/`TRIGGER`, and which options mean falling/low) to decide active-low
// vs. active-high and flip-flop vs. combinational; `getInstanceIdentifier` needs
// `StdAttr.LABEL`. `StdAttr` belongs to a module this task does not touch, so both are
// injectable (`clockAttributes`, `labelAttribute`) rather than hardcoded: the same pattern
// `HdlParameters.swift`'s file header documents for `widthAttribute` and the gate-input-bubble
// case. Left `nil` (the default), clock ports are treated as always active-high and never a
// flip-flop's global tick, and instance identifiers always use the `SUBDIR_id` fallback name;
// both exactly Java's own fallback behaviour when the relevant attribute is simply absent from
// a component's attribute set.
//
// Also dropped: the no-argument constructor that infers `subDirectoryName` by parsing
// `getClass().toString()`: it exploits Java packages mirroring source directories one-to-one,
// which Swift modules do not do (SwiftPM directories are a build-time file layout, invisible at
// runtime). Every generator names its subdirectory explicitly instead, exactly as Java's own
// `AbstractHdlGeneratorFactory(String subDirectory)` overload already allows, and as this
// module's two concrete generators (`TickComponentHdlGeneratorFactory`,
// `SynthesizedClockHdlGeneratorFactory`) already do.

import LogisimKernel

/// The `StdAttr` clock-trigger attributes `getPortMap` needs to classify a component's clock
/// pin, injected for the reason given in this file's header.
public struct HdlClockAttributes {
  /// `StdAttr.EDGE_TRIGGER`; presence alone means "this is a flip-flop".
  public let edgeTrigger: AnyAttribute?
  /// `StdAttr.TRIGGER`; presence plus a rising/falling value also means "this is a flip-flop".
  public let trigger: AnyAttribute?
  public let risingOption: AttributeOption
  public let fallingOption: AttributeOption
  public let lowOption: AttributeOption

  public init(
    edgeTrigger: AnyAttribute?, trigger: AnyAttribute?, risingOption: AttributeOption,
    fallingOption: AttributeOption, lowOption: AttributeOption
  ) {
    self.edgeTrigger = edgeTrigger
    self.trigger = trigger
    self.risingOption = risingOption
    self.fallingOption = fallingOption
    self.lowOption = lowOption
  }

  /// `Netlist.isFlipFlop(AttributeSet)`.
  public func isFlipFlop(_ attrs: any AttributeSet) -> Bool {
    if let edgeTrigger, attrs.containsAttribute(edgeTrigger) { return true }
    if let trigger, attrs.containsAttribute(trigger),
      case .option(let option)? = attrs.rawValue(trigger)
    {
      return option == fallingOption || option == risingOption
    }
    return false
  }

  /// The `activeLow` computation inlined in `AbstractHdlGeneratorFactory.getPortMap`, using
  /// `EDGE_TRIGGER` if present, else `TRIGGER`, else defaulting to `TRIG_RISING`, exactly
  /// Java's fallback chain.
  fileprivate func isActiveLow(_ attrs: any AttributeSet) -> Bool {
    let selected: AttributeOption
    if let edgeTrigger, attrs.containsAttribute(edgeTrigger),
      case .option(let option)? = attrs.rawValue(edgeTrigger)
    {
      selected = option
    } else if let trigger, attrs.containsAttribute(trigger),
      case .option(let option)? = attrs.rawValue(trigger)
    {
      selected = option
    } else {
      selected = risingOption
    }
    return selected == lowOption || selected == fallingOption
  }
}

/// `com.cburch.logisim.fpga.hdlgenerator.AbstractHdlGeneratorFactory`.
open class AbstractHdlGeneratorFactory: HdlGeneratorFactory {
  private let subDirectoryName: String
  public let myParametersList: HdlParameters
  public let myWires = HdlWires()
  public let myPorts = HdlPorts()
  public let myTypedWires = HdlTypes()
  public var getWiresPortsDuringHdlWriting = false

  /// See the file header. `nil` until a generator subclass supplies one.
  open var clockAttributes: HdlClockAttributes?
  /// `StdAttr.LABEL`. `nil` until a generator subclass supplies one.
  open var labelAttribute: AnyAttribute?

  public init(subDirectory: String, widthAttribute: Attribute<BitWidth>) {
    subDirectoryName = subDirectory
    myParametersList = HdlParameters(widthAttribute: widthAttribute)
  }

  /// `AbstractHdlGeneratorFactory.getGenerationTimeWiresPorts`.
  open func getGenerationTimeWiresPorts(netlist: any HdlNetlist, attrs: any AttributeSet) {}

  open func generateAllHdlDescriptions(
    handledComponents: inout Set<String>, workingDirectory: String, hierarchy: [String]
  ) -> Bool {
    true
  }

  // MARK: - Architecture / module body

  open func getArchitecture(netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String)
    -> [String]?
  {
    let contents = LineBuffer.getHdlBuffer()
    if getWiresPortsDuringHdlWriting {
      myWires.removeWires()
      myTypedWires.clear()
      myPorts.removePorts()
      getGenerationTimeWiresPorts(netlist: netlist, attrs: attrs)
    }
    contents.add(HdlFileWriter.generateRemark(componentName: componentName, projName: netlist.projName))

    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add(
        "{{architecture}} platformIndependent {{of}} {{1}} {{is}} ", componentName
      ).empty()
      if myTypedWires.nrOfTypes > 0 {
        contents.addRemarkBlock("Here all private types are defined")
          .add(myTypedWires.typeDefinitions())
          .empty()
      }

      let components = getComponentDeclarationSection(netlist: netlist, attrs: attrs)
      if !components.isEmpty {
        contents.addRemarkBlock("Here all used components are defined", 3)
          .add(components.getWithIndent()).empty()
      }

      let typedWires = myTypedWires.getTypedWires()
      var mySignals: [String: String] = [:]
      var maxNameLength = 0
      for wire in myWires.wireKeySet() {
        maxNameLength = max(maxNameLength, wire.count)
        mySignals[wire] = getTypeIdentifier(nrOfBits: myWires.get(wire), attrs: attrs)
      }
      for reg in myWires.registerKeySet() {
        maxNameLength = max(maxNameLength, reg.count)
        mySignals[reg] = getTypeIdentifier(nrOfBits: myWires.get(reg), attrs: attrs)
      }
      for (wire, typeName) in typedWires {
        maxNameLength = max(maxNameLength, wire.count)
        mySignals[wire] = typeName
      }
      if maxNameLength > 0 { contents.addRemarkBlock("All used signals are defined here") }
      for signal in mySignals.keys.sorted() {
        contents.add(
          "   {{signal}} {{1}}{{2}} : {{3}};", signal,
          String(repeating: " ", count: maxNameLength - signal.count), mySignals[signal] ?? "")
      }
      if maxNameLength > 0 { contents.empty() }
      contents.add("{{begin}}")
        .add(getModuleFunctionality(netlist: netlist, attrs: attrs).getWithIndent())
        .add("{{end}} platformIndependent;")
    } else {
      let preamble = "module \(componentName)( "
      let indenting = String(repeating: " ", count: preamble.count)
      let body = LineBuffer.getHdlBuffer()
      if myPorts.isEmpty {
        contents.add(preamble + " );")
      } else {
        var ports = Set(myPorts.keySet())
        for port in myPorts.keySet() where myPorts.isClock(port) {
          ports.insert(myPorts.getTickName(port))
        }
        let sortedPorts = ports.sorted()
        var remaining = sortedPorts.count
        for (index, port) in sortedPorts.enumerated() {
          remaining -= 1
          let end = remaining == 0 ? " );" : ","
          contents.add("{{1}}{{2}}{{3}}", index == 0 ? preamble : indenting, port, end)
        }
      }
      if !myParametersList.isEmpty(attrs) {
        body.empty().addRemarkBlock("Here all module parameters are defined with a dummy value")
        var parameters = Set<String>()
        for paramId in myParametersList.keySet(attrs) {
          let name = myParametersList.get(paramId, attrs: attrs) ?? ""
          let paramName =
            myParametersList.isPresentedByInteger(paramId, attrs: attrs)
            ? name : "[64:0] \(name)"
          parameters.insert(paramName)
        }
        for parameter in parameters.sorted() { body.add("parameter \(parameter) = 1;") }
      }
      if myTypedWires.nrOfTypes > 0 {
        body.empty().addRemarkBlock("Here all private types are defined")
          .add(myTypedWires.typeDefinitions())
      }
      var inputs = myPorts.keySet(.input)
      for input in myPorts.keySet(.input) where myPorts.isClock(input) {
        inputs.append(myPorts.getTickName(input))
      }
      if !inputs.isEmpty {
        body.empty().addRemarkBlock("The inputs are defined here")
        guard getVerilogSignalSet("input", inputs, attrs, isPort: true, body) else { return nil }
      }
      let outputs = myPorts.keySet(.output)
      if !outputs.isEmpty {
        body.empty().addRemarkBlock("The outputs are defined here")
        guard getVerilogSignalSet("output", outputs, attrs, isPort: true, body) else { return nil }
      }
      let inouts = myPorts.keySet(.inout_)
      if !inouts.isEmpty {
        body.empty().addRemarkBlock("The inouts are defined here")
        guard getVerilogSignalSet("inout", inouts, attrs, isPort: true, body) else { return nil }
      }
      let wires = myWires.wireKeySet()
      if !wires.isEmpty {
        body.empty().addRemarkBlock("The wires are defined here")
        guard getVerilogSignalSet("wire", wires, attrs, isPort: false, body) else { return nil }
      }
      let regs = myWires.registerKeySet()
      if !regs.isEmpty {
        body.empty().addRemarkBlock("The registers are defined here")
        guard getVerilogSignalSet("reg", regs, attrs, isPort: false, body) else { return nil }
      }
      let typedWires = myTypedWires.getTypedWires()
      if !typedWires.isEmpty {
        body.empty().addRemarkBlock("The type defined signals are defined here")
        let sortedWires = typedWires.keys.sorted()
        var maxNameLength = 0
        for wire in sortedWires { maxNameLength = max(maxNameLength, typedWires[wire]!.count) }
        for wire in sortedWires {
          let typeName = typedWires[wire]!
          body.add(
            LineBuffer.format(
              "{{1}}{{2}} {{3}};", typeName,
              String(repeating: " ", count: maxNameLength - typeName.count), wire))
        }
      }
      body.empty()
        .addRemarkBlock("The module functionality is described here")
        .add(getModuleFunctionality(netlist: netlist, attrs: attrs).get())
      contents.add(body.getWithIndent()).add("endmodule")
    }
    return contents.get()
  }

  /// `AbstractHdlGeneratorFactory.getComponentDeclarationSection`. Only meaningful for VHDL.
  open func getComponentDeclarationSection(netlist: any HdlNetlist, attrs: any AttributeSet)
    -> LineBuffer
  {
    LineBuffer.getHdlBuffer()
  }

  open func getComponentInstantiation(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String
  ) -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    if Hdl.isVhdl() {
      contents.add(getVhdlBlackBox(netlist: netlist, attrs: attrs, componentName: componentName, isEntity: false))
    }
    return contents
  }

  /// `AbstractHdlGeneratorFactory.getComponentMap`.
  ///
  /// `throws` because `HdlParameters.getMaps` does (D13; Java raises a catchable
  /// `UnsupportedOperationException`). The `componentInfo == nil` branch below is precisely the
  /// path that used to kill the process: it hands `getMaps` an **empty** attribute set, in which
  /// every attribute-reading parameter kind fails `containsAttribute`.
  open func getComponentMap(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: (any HdlNetlistComponent)?,
    name: String
  ) throws -> LineBuffer {
    let contents = LineBuffer.getHdlBuffer()
    var parameterMap: [String: String] = [:]
    let portMap = getPortMap(netlist: netlist, componentInfo: componentInfo)
    let componentHdlName = componentInfo?.hdlName ?? name
    let compName = !name.isEmpty ? name : componentHdlName
    let thisInstanceIdentifier = getInstanceIdentifier(componentInfo: componentInfo, componentId: componentId)

    if let componentInfo {
      for (key, value) in try myParametersList.getMaps(componentInfo.attributeSet) {
        parameterMap[key] = value
      }
    } else {
      for (key, value) in try myParametersList.getMaps(AttributeSets.empty) {
        parameterMap[key] = value
      }
    }

    var oneLine = ""
    if Hdl.isVhdl() {
      contents.addVhdlKeywords().add("{{1}} : {{2}}", thisInstanceIdentifier, compName)
      if !parameterMap.isEmpty {
        var maxNameLength = 0
        for generic in parameterMap.keys { maxNameLength = max(maxNameLength, generic.count) }
        let genericNames = parameterMap.keys.sorted()
        let nrOfGenerics = genericNames.count
        for (currentGeneric, generic) in genericNames.enumerated() {
          let preamble = currentGeneric == 0 ? "{{generic}} {{map}} (" : String(repeating: " ", count: 13)
          contents.add(
            "   {{1}} {{2}}{{3}} => {{4}}{{5}}", preamble, generic,
            String(repeating: " ", count: max(0, maxNameLength - generic.count)),
            parameterMap[generic] ?? "", currentGeneric == nrOfGenerics - 1 ? " )" : ",")
        }
      }
      if !portMap.isEmpty {
        var maxNameLength = 0
        for port in portMap.keys { maxNameLength = max(maxNameLength, port.count) }
        let portNames = portMap.keys.sorted()
        let nrOfPorts = portNames.count
        for (currentPort, port) in portNames.enumerated() {
          let preamble = currentPort == 0 ? "{{port}} {{map}} (" : String(repeating: " ", count: 10)
          contents.add(
            "   {{1}} {{2}}{{3}} => {{4}}{{5}}", preamble, port,
            String(repeating: " ", count: max(0, maxNameLength - port.count)), portMap[port] ?? "",
            currentPort == nrOfPorts - 1 ? " );" : ",")
        }
      }
    } else {
      oneLine += compName
      var tabLength = 0
      if !parameterMap.isEmpty {
        oneLine += " #("
        tabLength = oneLine.count
        var first = true
        for parameter in parameterMap.keys.sorted() {
          if !first {
            oneLine += ","
            contents.add(oneLine)
            oneLine = String(repeating: " ", count: tabLength)
          } else {
            first = false
          }
          oneLine += ".\(parameter)(\(parameterMap[parameter] ?? ""))"
        }
        oneLine += ")"
        contents.add(oneLine)
        oneLine = ""
      }
      oneLine += "   \(thisInstanceIdentifier) ("
      if !portMap.isEmpty {
        tabLength = oneLine.count
        var first = true
        for port in portMap.keys.sorted() {
          if !first {
            oneLine += ","
            contents.add(oneLine)
            oneLine = String(repeating: " ", count: tabLength)
          } else {
            first = false
          }
          oneLine += ".\(port)("
          let mappedSignal = portMap[port] ?? ""
          if !mappedSignal.contains(",") {
            oneLine += mappedSignal
          } else {
            // Java's `split(",")` drops trailing empty fields; Swift's
            // `omittingEmptySubsequences: false` keeps them. Third site of the same divergence
            // (see `LineBuffer.getWithIndent` and `Hdl.getExtendedLibrary`), and the same one
            // the codec has in `javaSplitOnLiteral`: task #37.
            //
            // Measured: an unconnected shift register maps `q` to `"open,,,,,,,"`. The jar emits
            // `.q({open})`; without this the port emits eight lines. The `count > 1` guard
            // matches Java, whose `"".split(",")` is `[""]` rather than `[]`.
            let vectorList = javaSplit(mappedSignal, on: ",")
            oneLine += "{"
            let tabSize = oneLine.count
            for (index, entry) in vectorList.enumerated() {
              oneLine += entry.replacingOccurrences(of: "}", with: "")
                .replacingOccurrences(of: "{", with: "")
              if index < vectorList.count - 1 {
                contents.add(oneLine + ",")
                oneLine = String(repeating: " ", count: tabSize)
              } else {
                oneLine += "}"
              }
            }
          }
          oneLine += ")"
        }
      }
      oneLine += ");"
      contents.add(oneLine)
    }
    return contents
  }

  open func getEntity(netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String)
    -> [String]
  {
    let contents = LineBuffer.getHdlBuffer()
    if Hdl.isVhdl() {
      contents.add(HdlFileWriter.generateRemark(componentName: componentName, projName: netlist.projName))
        .add(Hdl.getExtendedLibrary())
        .add(getVhdlBlackBox(netlist: netlist, attrs: attrs, componentName: componentName, isEntity: true))
    }
    return contents.get()
  }

  /// `AbstractHdlGeneratorFactory.getInstanceIdentifier`.
  private func getInstanceIdentifier(
    componentInfo: (any HdlNetlistComponent)?, componentId: Int64
  ) -> String {
    if let componentInfo, let labelAttribute {
      let attrs = componentInfo.attributeSet
      if attrs.containsAttribute(labelAttribute), case .string(let label)? = attrs.rawValue(labelAttribute),
        !label.isEmpty
      {
        return CorrectLabel.correctLabel(label)
      }
    }
    return LineBuffer.format("{{1}}_{{2}}", subDirectoryName.uppercased(), componentId)
  }

  open func getInlinedCode(
    netlist: any HdlNetlist, componentId: Int64, componentInfo: any HdlNetlistComponent,
    circuitName: String
  ) -> LineBuffer {
    preconditionFailure("BUG: Inline code not supported")
  }

  open func getModuleFunctionality(netlist: any HdlNetlist, attrs: any AttributeSet) -> LineBuffer
  {
    LineBuffer.getHdlBuffer()
  }

  /// `AbstractHdlGeneratorFactory.getPortMap`. Not part of the `HdlGeneratorFactory` protocol
  /// (Java declares it directly on this class, and `TickComponentHdlGeneratorFactory`/
  /// `SynthesizedClockHdlGeneratorFactory` override it without implementing a separate
  /// interface method: mirrored here the same way).
  open func getPortMap(netlist: any HdlNetlist, componentInfo: (any HdlNetlistComponent)?)
    -> [String: String]
  {
    var result: [String: String] = [:]
    guard let componentInfo, !myPorts.isEmpty else { return result }
    let attrs = componentInfo.attributeSet
    if getWiresPortsDuringHdlWriting {
      myWires.removeWires()
      myTypedWires.clear()
      myPorts.removePorts()
      getGenerationTimeWiresPorts(netlist: netlist, attrs: attrs)
    }
    for port in myPorts.keySet() {
      if myPorts.isClock(port) {
        var gatedClock = false
        var hasClock = true
        let compPinId = myPorts.getComponentPortId(port)
        let activeLow = clockAttributes?.isActiveLow(attrs) ?? false
        if !componentInfo.isEndConnected(compPinId) {
          Reporter.shared.addSevereWarning(
            "Component \"\(componentInfo.displayName)\" in circuit \"\(netlist.circuitName)\" has no clock connection!")
          hasClock = false
        }
        let clockNetName = Hdl.getClockNetName(componentInfo, endIndex: compPinId, netlist: netlist)
        if clockNetName.isEmpty {
          Reporter.shared.addSevereWarning(
            "Component \"\(componentInfo.displayName)\" in circuit \"\(netlist.circuitName)\" has a gated clock connection!")
          gatedClock = true
        }
        let isFlipFlop = clockAttributes?.isFlipFlop(attrs) ?? false
        if hasClock && !gatedClock && isFlipFlop {
          if netlist.requiresGlobalClockConnection {
            result[myPorts.getTickName(port)] = LineBuffer.formatHdl(
              "{{1}}{{<}}{{2}}{{>}}", clockNetName, HdlGeneratorNames.ClockTreeIndex.globalClock)
          } else {
            let clockIndex =
              activeLow
              ? HdlGeneratorNames.ClockTreeIndex.negativeEdgeTick
              : HdlGeneratorNames.ClockTreeIndex.positiveEdgeTick
            result[myPorts.getTickName(port)] = LineBuffer.formatHdl(
              "{{1}}{{<}}{{2}}{{>}}", clockNetName, clockIndex)
          }
          result[HdlPorts.clock] = LineBuffer.formatHdl(
            "{{1}}{{<}}{{2}}{{>}}", clockNetName, HdlGeneratorNames.ClockTreeIndex.globalClock)
        } else if !hasClock {
          result[myPorts.getTickName(port)] = Hdl.zeroBit()
          result[HdlPorts.clock] = Hdl.zeroBit()
        } else {
          result[myPorts.getTickName(port)] = Hdl.oneBit()
          if !gatedClock {
            let clockIndex =
              activeLow
              ? HdlGeneratorNames.ClockTreeIndex.invertedDerivedClock
              : HdlGeneratorNames.ClockTreeIndex.derivedClock
            result[HdlPorts.clock] = LineBuffer.formatHdl(
              "{{1}}{{<}}{{2}}{{>}}", clockNetName, clockIndex)
          } else {
            result[HdlPorts.clock] = Hdl.getNetName(
              componentInfo, endIndex: compPinId, floatingNetTiedToGround: true, netlist: netlist)
          }
        }
      } else if myPorts.isFixedMapped(port) {
        let fixedMap = myPorts.getFixedMap(port)
        if fixedMap == HdlPorts.pullDown {
          result[port] = Hdl.getConstantVector(0, nrOfBits: myPorts.get(port, attrs: attrs))
        } else if fixedMap == HdlPorts.pullUp {
          result[port] = Hdl.getConstantVector(-1, nrOfBits: myPorts.get(port, attrs: attrs))
        } else {
          result[port] = fixedMap
        }
      } else {
        let netMap = Hdl.getNetMap(
          sourceName: port, floatingPinTiedToGround: myPorts.doPullDownOnFloat(port),
          comp: componentInfo, endIndex: myPorts.getComponentPortId(port), netlist: netlist)
        for (key, value) in netMap { result[key] = value }
      }
    }
    return result
  }

  open var relativeDirectory: String {
    var directoryName = HdlSettings.language.rawValue.lowercased()
    if !directoryName.hasSuffix("/") { directoryName += "/" }
    if !subDirectoryName.isEmpty {
      directoryName += subDirectoryName
      if !subDirectoryName.hasSuffix("/") { directoryName += "/" }
    }
    return directoryName
  }

  /// `AbstractHdlGeneratorFactory.getVHDLBlackBox`.
  private func getVhdlBlackBox(
    netlist: any HdlNetlist, attrs: any AttributeSet, componentName: String, isEntity: Bool
  ) -> [String] {
    let contents = LineBuffer.getHdlBuffer().addVhdlKeywords()
    var maxNameLength = 0
    if getWiresPortsDuringHdlWriting {
      myWires.removeWires()
      myTypedWires.clear()
      myPorts.removePorts()
      getGenerationTimeWiresPorts(netlist: netlist, attrs: attrs)
    }
    contents.add(isEntity ? "{{entity}} {{1}} {{is}}" : "{{component}} {{1}}", componentName)
    if !myParametersList.isEmpty(attrs) {
      var myParameters: [String: Bool] = [:]
      for generic in myParametersList.keySet(attrs) {
        let parameterName = myParametersList.get(generic, attrs: attrs) ?? ""
        maxNameLength = max(maxNameLength, parameterName.count)
        myParameters[parameterName] = myParametersList.isPresentedByInteger(generic, attrs: attrs)
      }
      maxNameLength += 1
      let myGenerics = myParameters.keys.sorted()
      for (currentGenericId, thisGeneric) in myGenerics.enumerated() {
        let preamble = currentGenericId == 0 ? "   {{generic}} ( " : "             "
        contents.add(
          "{{1}}{{2}}{{3}}: {{4}}{{5}};", preamble, thisGeneric,
          String(repeating: " ", count: max(0, maxNameLength - thisGeneric.count)),
          myParameters[thisGeneric] == true ? "{{integer}}" : "std_logic_vector",
          currentGenericId == myGenerics.count - 1 ? " )" : "")
      }
    }
    if !myPorts.isEmpty {
      maxNameLength = 0
      var nrOfEntries = myPorts.keySet().count
      var tickers = Set<String>()
      for portName in myPorts.keySet() {
        maxNameLength = max(maxNameLength, portName.count)
        if myPorts.isClock(portName) {
          let tickerName = myPorts.getTickName(portName)
          maxNameLength = max(maxNameLength, tickerName.count)
          tickers.insert(tickerName)
          nrOfEntries += 1
        }
      }
      maxNameLength += 1
      var currentEntry = 0

      var direction = !myPorts.keySet(.inout_).isEmpty ? Vhdl.vhdlKeyword("IN   ") : Vhdl.vhdlKeyword("IN ")
      var myInputs = Set(myPorts.keySet(.input))
      myInputs.formUnion(tickers)
      for input in myInputs.sorted() {
        let nrOfPortBits = myPorts.contains(input) ? myPorts.get(input, attrs: attrs) : 1
        let type = getTypeIdentifier(nrOfBits: nrOfPortBits, attrs: attrs)
        addPortEntry(
          contents, isFirstEntry: currentEntry == 0, nrOfEntries: nrOfEntries,
          currentEntry: currentEntry, name: input, direction: direction, type: type,
          maxLength: maxNameLength)
        currentEntry += 1
      }
      direction = Vhdl.vhdlKeyword("INOUT")
      for inout_ in myPorts.keySet(.inout_).sorted() {
        let nrOfPortBits = myPorts.get(inout_, attrs: attrs)
        let type = getTypeIdentifier(nrOfBits: nrOfPortBits, attrs: attrs)
        addPortEntry(
          contents, isFirstEntry: currentEntry == 0, nrOfEntries: nrOfEntries,
          currentEntry: currentEntry, name: inout_, direction: direction, type: type,
          maxLength: maxNameLength)
        currentEntry += 1
      }
      direction = !myPorts.keySet(.inout_).isEmpty ? Vhdl.vhdlKeyword("OUT  ") : Vhdl.vhdlKeyword("OUT")
      for output in myPorts.keySet(.output).sorted() {
        let nrOfPortBits = myPorts.get(output, attrs: attrs)
        let type = getTypeIdentifier(nrOfBits: nrOfPortBits, attrs: attrs)
        addPortEntry(
          contents, isFirstEntry: currentEntry == 0, nrOfEntries: nrOfEntries,
          currentEntry: currentEntry, name: output, direction: direction, type: type,
          maxLength: maxNameLength)
        currentEntry += 1
      }
    }
    if isEntity {
      contents.add("{{end}} {{entity}} {{1}};", componentName)
    } else {
      contents.add("{{end}} {{component}};")
    }
    return contents.getWithIndent(isEntity ? 0 : 1)
  }

  @discardableResult
  private func addPortEntry(
    _ contents: LineBuffer, isFirstEntry: Bool, nrOfEntries: Int, currentEntry: Int, name: String,
    direction: String, type: String, maxLength: Int
  ) -> Bool {
    let fmt =
      isFirstEntry
      ? "   {{port}} ( {{1}}{{2}}: {{3}} {{4}}{{5}};"
      : "          {{1}}{{2}}: {{3}} {{4}}{{5}};"
    contents.add(
      fmt, name, String(repeating: " ", count: maxLength - name.count), direction, type,
      currentEntry == nrOfEntries - 1 ? " )" : "")
    return false
  }

  /// `AbstractHdlGeneratorFactory.getTypeIdentifier`. A negative `nrOfBits` not registered as a
  /// generic parameter is a generator-construction bug, not something a `.circ` file reaches:
  /// traps (D13).
  private func getTypeIdentifier(nrOfBits: Int, attrs: any AttributeSet) -> String {
    let contents = LineBuffer.getHdlBuffer().addVhdlKeywords()
    if nrOfBits < 0 {
      guard myParametersList.containsKey(nrOfBits, attrs: attrs) else {
        preconditionFailure("Generic parameter not specified in the parameters list")
      }
      contents.add(
        "std_logic_vector( ({{1}} - 1) {{downto}} 0 )", myParametersList.get(nrOfBits, attrs: attrs) ?? "")
    } else if nrOfBits == 0 {
      contents.add("std_logic_vector( 0 {{downto}} 0 )")
    } else if nrOfBits > 1 {
      contents.add("std_logic_vector( {{1}} {{downto}} 0 )", nrOfBits - 1)
    } else {
      contents.add("std_logic")
    }
    return contents.get(0)
  }

  /// `AbstractHdlGeneratorFactory.getVerilogSignalSet`. Reports through `Reporter` and returns
  /// `false`, exactly as upstream, when a negative width is not a registered generic parameter
  /// ; that path *is* something a generator's own construction can hit at runtime.
  private func getVerilogSignalSet(
    _ preamble: String, _ signals: [String], _ attrs: any AttributeSet, isPort: Bool,
    _ contents: LineBuffer
  ) -> Bool {
    guard !signals.isEmpty else { return true }
    var signalSet: [String: String] = [:]
    for input in signals {
      let nrOfBits =
        isPort ? (myPorts.contains(input) ? myPorts.get(input, attrs: attrs) : 1) : myWires.get(input)
      if nrOfBits < 0 {
        guard myParametersList.containsKey(nrOfBits, attrs: attrs) else {
          Reporter.shared.addFatalError(
            "Internal Error, Parameter not present in HDL generation, your HDL code will not work!")
          return false
        }
        signalSet[input] = "\(preamble) [\(myParametersList.get(nrOfBits, attrs: attrs) ?? "")-1:0]"
      } else if nrOfBits == 0 {
        signalSet[input] = "\(preamble) [0:0]"
      } else if nrOfBits > 1 {
        signalSet[input] = "\(preamble) [\(nrOfBits - 1):0]"
      } else {
        signalSet[input] = preamble
      }
    }
    let sortedSignals = signalSet.keys.sorted()
    var maxNameLength = 0
    for signal in sortedSignals { maxNameLength = max(maxNameLength, signalSet[signal]!.count) }
    for signal in sortedSignals {
      let type = signalSet[signal]!
      contents.add(
        LineBuffer.format(
          "{{1}}{{2}} {{3}};", type, String(repeating: " ", count: maxNameLength - type.count), signal))
    }
    return true
  }

  open func isHdlSupportedTarget(attrs: any AttributeSet) -> Bool { true }

  open var isOnlyInlined: Bool { false }
}
