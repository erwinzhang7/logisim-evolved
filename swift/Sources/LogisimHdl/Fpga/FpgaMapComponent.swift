// FpgaMapComponent.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/data/MapComponent.java` (800 lines),
// reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.
//
// ══ WHAT THIS IS ═══════════════════════════════════════════════════════════════════════════
//
// One placed component's binding to physical FPGA pins. It is created from a `NetlistComponent`
// plus its hierarchy path, splits the component into *pins* (one per bubble, inputs then outputs
// then in-outs), and answers, for each pin: what it is called, which global bubble it drives, and
// what signal name the generated toplevel must use. `MappableResourcesContainer` holds one of
// these per mappable resource; `ToplevelHdlGeneratorFactory` reads their pin names.
//
// ══ WHY THE NAME IS NOT `MapComponent` ═════════════════════════════════════════════════════
//
// **`MapComponent` already exists, in `LogisimFile/XmlReaderSupport.swift`**, as an enum holding
// the four attribute tokens and `getMapInfo(Element)`. That is the *static* half of this Java
// class, and it lives there because the `.circ` reader needs it and `LogisimFile` sits below this
// module and cannot see it.
//
// So one Java class is two Swift types, in two modules. That is **forced by the layering, not a
// merge accident**, which is the difference between this and task #39, where two views of
// `LedArrayDriving` sit in the same module and could be collapsed. The reconciliation, for
// whoever owns `LogisimFile`: nothing to reconcile while the reader stays below this module.
// Keep the two cross-referenced and do not add a third.
//
// ══ THE `std.io` DEPENDENCY, INJECTED ══════════════════════════════════════════════════════
//
// Upstream imports `std.io.RgbLed` and `std.io.SevenSegment`. Both go through
// `FpgaStdIoFacts.shared`; see that file for the whole argument and the enumeration proving the
// surface is exactly four entries.
//
// ══ WHAT IS GATED, AND WHAT IS NOT; READ THIS BEFORE TRUSTING A LINE OF IT ════════════════
//
// `tools/hdlbridge/NetlistBridge.java` builds the real `MapComponent` inside the 4.1.0 jar for
// every mappable resource of every DRC-passing corpus circuit and dumps it;
// `MapComponentGateTests` diffs this against that. **890 components / 2,972 pins.**
//
// That covers the constructor, the pin split, `pinLabels`, the bubble indices,
// `getHdlString`, `getHdlSignalName` and `getDisplayString`; i.e. everything an *unmapped*
// component answers, which is everything the toplevel generator reads.
//
// It does **not** cover the mapping mutators (`tryMap` and its five overloads, `unmap`,
// `copyMapFrom`, `tryConstantMap`, `tryOpenMap`, `isCompleteMap`, `mapElementAttributes`).
// Reaching those needs a board XML *and* a saved pin map in the `.circ`, and no corpus file has
// one; the same reason the jar's `--test-fpga` path is unusable as an oracle at all. They are
// ported because `MappableResourcesContainer` and `ComponentMapParser` call them and a half
// class would block both, and they are transcribed line for line rather than re-derived. Treat
// them as unverified until a board-mapped fixture exists.

import LogisimFile
import LogisimKernel

/// The three `CircuitMapInfo` predicates the FPGA layer branches on.
///
/// **These belong on the type**, in `LogisimFile/XmlReaderSupport.swift`. They are here because
/// the port only ever *constructed* a `CircuitMapInfo` until now, the `.circ` reader builds them
/// and nothing read them back, so the predicates were never needed and never written. Adding
/// them as an extension keeps the change inside this task's ownership; fold them into the type
/// when `LogisimFile` is next opened, and delete this block. They are transcribed verbatim from
/// `com/cburch/logisim/circuit/CircuitMapInfo.java:75-101`, including the detail that `isOpen`
/// additionally requires `oldMapFormat` while `isConst` does not.
extension CircuitMapInfo {
  /// `CircuitMapInfo.isSinglePin()`.
  public var isSinglePin: Bool { pinId >= 0 }
  /// `CircuitMapInfo.isOpen()`.
  public var isOpen: Bool { rect == nil && constValue == nil && isOldMapFormat }
  /// `CircuitMapInfo.isConst()`.
  public var isConst: Bool { rect == nil && constValue != nil }
}

/// `MapComponent.mapType`: a mapped pin's board component and which of *its* pins we occupy.
private final class MapClass {
  let ioComponent: FpgaIoInformationContainer
  var ioPin: Int

  init(ioComponent: FpgaIoInformationContainer, pin: Int) {
    self.ioComponent = ioComponent
    self.ioPin = pin
  }

  func unmap() { ioComponent.unmap(pin: ioPin) }

  @discardableResult
  func update(_ comp: FpgaMapComponent) -> Bool {
    ioComponent.updateMap(pin: ioPin, owner: comp)
  }
}

/// `com.cburch.logisim.fpga.data.MapComponent`; the instance half. See the file header for why
/// the static half is `LogisimFile.MapComponent`.
public final class FpgaMapComponent {

  /// `MapComponent.MAP_KEY` and friends.
  ///
  /// **Five of the six are taken from `LogisimFile.MapComponent`, not restated here.** That enum
  /// is the same Java class's static half and the `.circ` *reader* already reads these tokens;
  /// two copies of a file-format constant is precisely the seam shape that produces a writer
  /// which cannot round-trip its own output. `MAP_KEY` is the sixth and is writer-only; the
  /// reader never looks at `key`, which is why it is not over there.
  public static let mapKey = "key"
  public static let completeMap = MapComponent.completeMap
  public static let openKey = MapComponent.openKey
  public static let constantKey = MapComponent.constantKey
  public static let pinMapKey = MapComponent.pinMap
  public static let noMap = MapComponent.noMap

  /// `MapComponent.ONLY_IO_MAP_NAME`.
  public static let onlyIoMapName = -2

  /// `S.get("MapOpen")`; `"Not connected"` in `fpga.properties`. Inlined rather than routed
  /// through a bundle: D5 records that localisation does not come across, and this string is
  /// *written into the saved `.circ`* by `getMapElement`, so it is data, not chrome.
  public static let mapOpenText = "Not connected"

  // The pin index -> global bubble id maps. Java uses three `HashMap<Integer, Integer>`; the
  // *keys* partition `0..<nrOfPins` contiguously by construction, so ordered dictionaries are
  // unnecessary; every read is a membership test or a keyed lookup, never an iteration whose
  // order reaches output. (`getIoBubblePinId` iterates, but returns the unique match.)
  private var inputBubbles: [Int: Int] = [:]
  private var outputBubbles: [Int: Int] = [:]
  private var ioBubbles: [Int: Int] = [:]

  /// `MapComponent.myFactory`.
  public let factory: any ComponentFactory
  /// `MapComponent.myAttributes`.
  public let attributes: any AttributeSet
  /// `MapComponent.myName`; `[boardName] + hierarchy path`. **Element 0 is the board name and
  /// every string method skips it**; that is not a bug, it is why `getHdlString` starts at 1.
  public let name: [String]

  private var maps: [MapClass?] = []
  private var opens: [Bool] = []
  private var constants: [Int] = []
  private var pinLabels: [String] = []

  /// `MapComponent.nrOfPins`.
  public private(set) var numberOfPins = 0

  /// `MapComponent(List<String>, netlistComponent)`.
  ///
  /// Returns `nil` where Java would throw: `mapInfo` is dereferenced unguarded upstream, and a
  /// component with no `ComponentMapInformationContainer` is never in `getMappableResources`'s
  /// output, so upstream cannot reach it. D13: a failable initialiser rather than a trap,
  /// because the caller is a file-driven path.
  public init?(name: [String], component: NetlistComponent) {
    guard let mapInfo = component.mapInformation else { return nil }
    self.factory = component.component.factory
    self.attributes = component.component.attributeSet
    self.name = name

    // `bName` drops the board name, which is what `constructHierarchyTree` keyed `globalIds` by.
    let bubbleName = Array(name.dropFirst())
    let bubbleInfo = component.globalBubbleId(hierarchyName: bubbleName)

    for index in 0..<mapInfo.numberOfInputBubbles {
      maps.append(nil)
      opens.append(false)
      constants.append(-1)
      let id = bubbleInfo.map { $0.inputStartIndex + index } ?? -1
      pinLabels.append(mapInfo.inputPortLabel(index))
      inputBubbles[numberOfPins] = id
      numberOfPins += 1
    }
    for index in 0..<mapInfo.numberOfOutputBubbles {
      maps.append(nil)
      opens.append(false)
      constants.append(-1)
      let id = bubbleInfo.map { $0.outputStartIndex + index } ?? -1
      pinLabels.append(mapInfo.outputPortLabel(index))
      outputBubbles[numberOfPins] = id
      numberOfPins += 1
    }
    for index in 0..<mapInfo.numberOfInOutBubbles {
      maps.append(nil)
      opens.append(false)
      constants.append(-1)
      let id = bubbleInfo.map { $0.inOutStartIndex + index } ?? -1
      pinLabels.append(mapInfo.inOutPortLabel(index))
      ioBubbles[numberOfPins] = id
      numberOfPins += 1
    }
  }

  // MARK: - Shape

  public var hasInputs: Bool { !inputBubbles.isEmpty }
  public var hasOutputs: Bool { !outputBubbles.isEmpty }
  public var hasIos: Bool { !ioBubbles.isEmpty }

  public func isInput(_ pin: Int) -> Bool { inputBubbles[pin] != nil }
  public func isOutput(_ pin: Int) -> Bool { outputBubbles[pin] != nil }
  public func isIo(_ pin: Int) -> Bool { ioBubbles[pin] != nil }

  public var numberOfInputs: Int { inputBubbles.count }
  public var numberOfOutputs: Int { outputBubbles.count }
  public var numberOfIos: Int { ioBubbles.count }

  /// `MapComponent.getPinLabel(int)`: not upstream API, but `pinLabels` is private there and
  /// every consumer reaches it through `getHdlString`/`getDisplayString`. Exposed because the
  /// gate compares labels directly.
  public func pinLabel(_ pin: Int) -> String {
    (pin >= 0 && pin < pinLabels.count) ? pinLabels[pin] : ""
  }

  /// `MapComponent.getIoBubblePinId(int)`.
  public func ioBubblePinId(_ id: Int) -> Int {
    for (key, value) in ioBubbles where value == id { return key }
    return -1
  }

  /// `MapComponent.equalsType(netlistComponent)`.
  ///
  /// Java compares `ComponentFactory` instances with `.equals`, which for every builtin factory
  /// is reference identity; the library holds one instance per component type. D4 says identity
  /// comparisons stay identity comparisons.
  public func equalsType(_ component: NetlistComponent) -> Bool {
    factory === component.component.factory
  }

  // MARK: - Map state

  public func isMapped(_ pin: Int) -> Bool {
    guard pin >= 0, pin < numberOfPins else { return false }
    if maps[pin] != nil { return true }
    if opens[pin] { return true }
    return constants[pin] >= 0
  }

  public func isBoardMapped(_ pin: Int) -> Bool {
    guard pin >= 0, pin < numberOfPins else { return false }
    return maps[pin] != nil
  }

  /// `MapComponent.isInternalMapped(int)`: mapped onto a component the toplevel drives through
  /// its own driver rather than through a raw pin.
  public func isInternalMapped(_ pin: Int) -> Bool {
    guard isBoardMapped(pin), let map = maps[pin] else { return false }
    return map.ioComponent.type == .LedArray || map.ioComponent.type == .SevenSegmentScanning
  }

  public func isExternalInverted(_ pin: Int) -> Bool {
    guard pin >= 0, pin < numberOfPins, let map = maps[pin] else { return false }
    return map.ioComponent.activityLevel == PinActivity.activeLow
  }

  public func requiresPullup(_ pin: Int) -> Bool {
    guard pin >= 0, pin < numberOfPins, let map = maps[pin] else { return false }
    return map.ioComponent.pullBehavior == PullBehaviors.pullUp
  }

  public func fpgaInfo(_ pin: Int) -> FpgaIoInformationContainer? {
    guard pin >= 0, pin < numberOfPins else { return nil }
    return maps[pin]?.ioComponent
  }

  /// `MapComponent.getPinLocation(int)`: the physical FPGA pin name, e.g. `"W5"`.
  public func pinLocation(_ pin: Int) -> String? {
    guard pin >= 0, pin < numberOfPins, let map = maps[pin] else { return nil }
    return map.ioComponent.pinLocation(map.ioPin)
  }

  public var hasMap: Bool {
    for pin in 0..<numberOfPins {
      if opens[pin] || constants[pin] >= 0 || maps[pin] != nil { return true }
    }
    return false
  }

  /// `MapComponent.isNotMapped()`. Upstream keeps both; they are exact negations, and the pair
  /// is preserved so a later diff against the Java does not look like a missing method.
  public var isNotMapped: Bool { !hasMap }

  /// `MapComponent.isOpenMapped(int)`: **`true` out of range**, matching upstream.
  public func isOpenMapped(_ pin: Int) -> Bool {
    guard pin >= 0, pin < numberOfPins else { return true }
    return opens[pin]
  }

  public func isConstantMapped(_ pin: Int) -> Bool {
    guard pin >= 0, pin < numberOfPins else { return false }
    return constants[pin] >= 0
  }

  /// `MapComponent.isZeroConstantMap(int)`: **`true` out of range**, matching upstream.
  public func isZeroConstantMap(_ pin: Int) -> Bool {
    guard pin >= 0, pin < numberOfPins else { return true }
    return constants[pin] == 0
  }

  /// `MapComponent.isCompleteMap(boolean)`.
  public func isCompleteMap(bothSides: Bool) -> Bool {
    var io: FpgaIoInformationContainer?
    var nrConstants = 0
    var nrOpens = 0
    var nrMaps = 0
    for pin in 0..<numberOfPins {
      if opens[pin] {
        nrOpens += 1
      } else if constants[pin] >= 0 {
        nrConstants += 1
      } else if let map = maps[pin] {
        nrMaps += 1
        if io == nil { io = map.ioComponent } else if io !== map.ioComponent { return false }
      } else {
        return false
      }
    }
    if nrOpens != 0 && nrOpens == numberOfPins { return true }
    if nrConstants != 0 && nrConstants == numberOfPins { return true }
    if nrMaps != 0 && nrMaps == numberOfPins {
      return !bothSides || (io?.isCompletelyMapped(by: self) ?? false)
    }
    return false
  }

  // MARK: - Names the generated HDL uses

  /// `MapComponent.getHdlString(int)`: the *port* name in the generated toplevel entity.
  public func hdlString(_ pin: Int) -> String? {
    guard pin >= 0, pin < numberOfPins else { return nil }
    var text = ""
    // Element 0 is the board name, so start at 1.
    for index in 1..<max(name.count, 1) {
      text += (index == 1 ? "" : "_") + name[index]
    }
    text += (text.isEmpty ? "" : "_") + pinLabels[pin]
    return text
  }

  /// `MapComponent.getHdlSignalName(int)`: what the toplevel *assigns*, which for a bubbled
  /// component is a slice of `s_logisimInputBubbles` / `s_logisimOutputBubbles`.
  ///
  /// Note the asymmetry, which is upstream's: inputs and outputs get a bubble slice, in-outs
  /// never do: they fall through to the hierarchical name even when `ioBubbles[pin] >= 0`.
  public func hdlSignalName(_ pin: Int) -> String? {
    guard pin >= 0, pin < numberOfPins else { return nil }
    if let bubble = inputBubbles[pin], bubble >= 0 {
      return "s_\(HdlGeneratorNames.localInputBubbleBusName)"
        + "\(Hdl.bracketOpen())\(bubble)\(Hdl.bracketClose())"
    }
    if let bubble = outputBubbles[pin], bubble >= 0 {
      return "s_\(HdlGeneratorNames.localOutputBubbleBusName)"
        + "\(Hdl.bracketOpen())\(bubble)\(Hdl.bracketClose())"
    }
    var text = "s_"
    for index in 1..<max(name.count, 1) {
      text += (index == 1 ? "" : "_") + name[index]
    }
    if numberOfPins > 1 {
      text += "\(Hdl.bracketOpen())\(pin)\(Hdl.bracketClose())"
    }
    return text
  }

  /// `MapComponent.getDisplayString(int)`. `pin < 0` summarises the whole component;
  /// `pin == onlyIoMapName` stops after the path, which is what `getMapElement` writes as `key`.
  public func displayString(_ pin: Int) -> String {
    var text = ""
    for index in 1..<max(name.count, 1) { text += "/" + name[index] }
    guard pin < 0 else {
      guard pin < numberOfPins else {
        // **D13 divergence, deliberate.** Upstream appends `#unknown<pin>` and then indexes
        // `opens.get(pin)` with the same out-of-range value, so this branch throws
        // `IndexOutOfBoundsException` the instant it is reached; the defensive text it just
        // built is never returned. Nothing reaches it (every caller loops to `nrOfPins` or
        // passes `ONLY_IO_MAP_NAME`), and a Swift array subscript would *trap*, killing the
        // process rather than raising. So the port returns the string upstream meant to.
        return text + "#unknown\(pin)"
      }
      text += "#\(pinLabels[pin])"
      if opens[pin] { text += "->" + Self.mapOpenText }
      if constants[pin] >= 0 { text += "->\(constants[pin] & 1)" }
      return text
    }

    var outAllOpens = numberOfOutputs > 0
    var ioAllOpens = numberOfIos > 0
    var inpAllConst = numberOfInputs > 0
    var ioAllConst = ioAllOpens
    var inpConst: Int64 = 0
    var ioConst: Int64 = 0
    for index in stride(from: numberOfPins - 1, through: 0, by: -1) {
      if inputBubbles[index] != nil {
        inpAllConst = inpAllConst && constants[index] >= 0
        inpConst <<= 1
        inpConst |= Int64(constants[index] & 1)
      }
      if outputBubbles[index] != nil {
        outAllOpens = outAllOpens && opens[index]
      }
      if ioBubbles[index] != nil {
        ioAllOpens = ioAllOpens && opens[index]
        ioAllConst = ioAllConst && constants[index] >= 0
        ioConst <<= 1
        ioConst |= Int64(constants[index] & 1)
      }
    }
    if pin == Self.onlyIoMapName { return text }
    if outAllOpens || ioAllOpens || inpAllConst || ioAllConst { text += "->" }
    var addComma = false
    if inpAllConst {
      text += "0x" + String(inpConst, radix: 16)
      addComma = true
    }
    if outAllOpens {
      text += addComma ? "," : ""
      addComma = true
      text += Self.mapOpenText
    }
    if ioAllOpens {
      text += addComma ? "," : ""
      addComma = true
      text += Self.mapOpenText
    }
    if ioAllConst {
      text += addComma ? "," : ""
      text += "0x" + String(ioConst, radix: 16)
    }
    return text
  }

  // MARK: - Mutating the map
  //
  // Everything below this line is NOT covered by the jar oracle: see the file header. Ported
  // because `MappableResourcesContainer` and `ComponentMapParser` call it.

  /// `MapComponent.unmap(int)`.
  public func unmap(pin: Int) {
    guard pin >= 0, pin < maps.count else { return }
    if FpgaStdIoFacts.shared.isRgbLed(factory), maps.count >= 3 {
      // An RGB LED whose three colour pins all landed on the same board pin is one triple map,
      // and unmapping any of the three unmaps all three.
      if let map1 = maps[0], let map2 = maps[1], let map3 = maps[2],
        map1.ioComponent === map2.ioComponent, map2.ioComponent === map3.ioComponent,
        map1.ioPin == map2.ioPin, map2.ioPin == map3.ioPin
      {
        map1.unmap()
        map2.unmap()
        map3.unmap()
        for index in 0..<3 {
          maps[index] = nil
          opens[index] = false
          constants[index] = -1
        }
        return
      }
    }
    let map = maps[pin]
    maps[pin] = nil
    map?.unmap()
    opens[pin] = false
    constants[pin] = -1
  }

  /// `MapComponent.unmap()`.
  public func unmapAll() {
    for pin in 0..<numberOfPins {
      maps[pin]?.unmap()
      opens[pin] = false
      constants[pin] = -1
    }
  }

  /// `MapComponent.copyMapFrom(MapComponent)`.
  ///
  /// Bug-for-bug: upstream unmaps the **source** and returns when the shapes disagree, leaving
  /// `this` untouched, and on the matching path it *shares* the three lists rather than copying
  /// them. Both preserved; the sharing is what makes `map.update(this)` below re-point the board
  /// side at the new owner.
  public func copyMap(from comp: FpgaMapComponent) {
    if comp.numberOfPins != numberOfPins || comp.factory !== factory {
      comp.unmapAll()
      return
    }
    maps = comp.maps
    opens = comp.opens
    constants = comp.constants
    for pin in 0..<numberOfPins {
      guard let map = maps[pin] else { continue }
      if !map.update(self) { unmap(pin: pin) }
    }
  }

  /// `MapComponent.tryMap(int, FpgaIoInformationContainer, int)`.
  @discardableResult
  public func tryMap(
    pin: Int, ioComponent: FpgaIoInformationContainer, ioPin: Int
  ) -> Bool {
    guard pin >= 0, pin < numberOfPins else { return false }
    let map = MapClass(ioComponent: ioComponent, pin: ioPin)
    if !ioComponent.tryMap(self, componentPin: pin, myPin: ioPin) { return false }
    maps[pin] = map
    opens[pin] = false
    constants[pin] = -1
    return true
  }

  /// `MapComponent.tryCompleteMap(FpgaIoInformationContainer, int)`.
  @discardableResult
  public func tryCompleteMap(ioComponent: FpgaIoInformationContainer, ioPin: Int) -> Bool {
    let map = MapClass(ioComponent: ioComponent, pin: ioPin)
    if !ioComponent.tryMap(self, componentPin: 0, myPin: ioPin) { return false }
    for pin in 0..<numberOfPins {
      maps[pin] = map
      opens[pin] = false
      constants[pin] = -1
    }
    return true
  }

  /// `MapComponent.tryMap(FpgaIoInformationContainer)`: map every pin of this component onto
  /// one board component, restoring the previous map wholesale if any pin fails.
  @discardableResult
  public func tryMap(ioComponent: FpgaIoInformationContainer) -> Bool {
    var oldMaps: [MapClass?] = []
    var oldOpens: [Bool] = []
    var oldConstants: [Int] = []
    for pin in 0..<numberOfPins {
      oldMaps.append(maps[pin])
      oldOpens.append(opens[pin])
      oldConstants.append(constants[pin])
    }
    var success = true
    for pin in 0..<numberOfPins {
      let newMap = MapClass(ioComponent: ioComponent, pin: -1)
      maps[pin]?.unmap()
      if inputBubbles[pin] != nil {
        let result = ioComponent.tryInputMap(self, componentPin: pin, inputPin: pin)
        success = success && result.mapped
        newMap.ioPin = result.pinId
      } else if outputBubbles[pin] != nil {
        let outputId = pin - inputBubbles.count
        let result = ioComponent.tryOutputMap(self, componentPin: pin, outputPin: outputId)
        success = success && result.mapped
        newMap.ioPin = result.pinId
      } else if ioBubbles[pin] != nil {
        let ioId = pin - inputBubbles.count - outputBubbles.count
        let result = ioComponent.tryIoMap(self, componentPin: pin, ioPin: ioId)
        success = success && result.mapped
        newMap.ioPin = result.pinId
      } else {
        success = false
        break
      }
      if success {
        maps[pin] = newMap
        opens[pin] = false
        constants[pin] = -1
      }
    }
    if !success {
      for pin in 0..<numberOfPins {
        maps[pin]?.unmap()
        if let map = oldMaps[pin] {
          if tryMap(pin: pin, ioComponent: map.ioComponent, ioPin: map.ioPin) { maps[pin] = map }
        }
        opens[pin] = oldOpens[pin]
        constants[pin] = oldConstants[pin]
      }
    }
    return success
  }

  /// `MapComponent.tryConstantMap(int, long)`.
  @discardableResult
  public func tryConstantMap(pin: Int, value: Int64) -> Bool {
    if pin < 0 {
      var mask: Int64 = 1
      var changed = false
      for index in 0..<numberOfPins where inputBubbles[index] != nil {
        maps[index]?.unmap()
        maps[index] = nil
        constants[index] = (value & mask) == 0 ? 0 : 1
        opens[index] = false
        mask <<= 1
        changed = true
      }
      return changed
    }
    guard inputBubbles[pin] != nil else { return false }
    maps[pin]?.unmap()
    maps[pin] = nil
    constants[pin] = Int(value & 1)
    opens[pin] = false
    return true
  }

  /// `MapComponent.tryOpenMap(int)`.
  @discardableResult
  public func tryOpenMap(pin: Int) -> Bool {
    if pin < 0 {
      for index in 0..<numberOfPins
      where outputBubbles[index] != nil || ioBubbles[index] != nil {
        maps[index]?.unmap()
        maps[index] = nil
        constants[index] = -1
        opens[index] = true
      }
      return true
    }
    guard outputBubbles[pin] != nil || ioBubbles[pin] != nil else { return false }
    maps[pin]?.unmap()
    maps[pin] = nil
    constants[pin] = -1
    opens[pin] = true
    return true
  }

  /// `MapComponent.tryMap(CircuitMapInfo, List<FpgaIoInformationContainer>)`; apply a map read
  /// out of a `.circ`.
  public func tryMap(_ cmap: CircuitMapInfo, ioComponents: [FpgaIoInformationContainer]) {
    if cmap.isOpen {
      if cmap.isSinglePin {
        let pin = Int(cmap.pinId)
        guard pin >= 0, pin < numberOfPins else { return }
        unmap(pin: pin)
        constants[pin] = -1
        opens[pin] = true
      } else {
        for pin in 0..<numberOfPins {
          unmap(pin: pin)
          constants[pin] = -1
          opens[pin] = true
        }
      }
    } else if cmap.isConst {
      if cmap.isSinglePin {
        let pin = Int(cmap.pinId)
        guard pin >= 0, pin < numberOfPins else { return }
        unmap(pin: pin)
        opens[pin] = false
        constants[pin] = Int((cmap.constValue ?? 0) & 1)
      } else {
        var mask: Int64 = 1
        let value = cmap.constValue ?? 0
        for pin in 0..<numberOfPins {
          unmap(pin: pin)
          opens[pin] = false
          constants[pin] = (value & mask) == 0 ? 0 : 1
          mask <<= 1
        }
      }
    }

    guard let pinMaps = cmap.pinMaps else {
      guard let rect = cmap.rect else { return }
      for comp in ioComponents
      where comp.rectangle?.isPointInside(x: Int(rect.x), y: Int(rect.y)) == true {
        if cmap.isSinglePin {
          tryMap(pin: Int(cmap.pinId), ioComponent: comp, ioPin: Int(cmap.ioId))
        } else {
          tryMap(ioComponent: comp)
        }
        break
      }
      return
    }

    if pinMaps.count != numberOfPins { return }
    if FpgaStdIoFacts.shared.isRgbLed(factory) {
      // Three single-pin maps onto the same rectangle and the same io id is a triple map onto one
      // LED-array element, and is applied as a complete map instead.
      var isPinMapped = true
      for pin in 0..<numberOfPins { isPinMapped = isPinMapped && (pinMaps[pin]?.isSinglePin ?? false) }
      if isPinMapped, let rect1 = pinMaps[0]?.rect, let rect2 = pinMaps[1]?.rect,
        let rect3 = pinMaps[2]?.rect, rect1 == rect2, rect2 == rect3,
        let ioMap1 = pinMaps[0]?.ioId, let ioMap2 = pinMaps[1]?.ioId,
        let ioMap3 = pinMaps[2]?.ioId, ioMap1 == ioMap2, ioMap2 == ioMap3
      {
        for comp in ioComponents
        where comp.rectangle?.isPointInside(x: Int(rect1.x), y: Int(rect1.y)) == true {
          tryCompleteMap(ioComponent: comp, ioPin: Int(ioMap1))
          return
        }
      }
    }
    for pin in 0..<numberOfPins {
      opens[pin] = false
      constants[pin] = -1
      maps[pin]?.unmap()
      guard let entry = pinMaps[pin] else { continue }
      if entry.isOpen {
        opens[pin] = true
        continue
      }
      if entry.isConst {
        constants[pin] = Int(entry.constValue ?? 0)
        continue
      }
      if entry.isSinglePin {
        tryMap(entry, ioComponents: ioComponents)
      }
    }
  }

  /// `MapComponent.tryMap(String, CircuitMapInfo, List<FpgaIoInformationContainer>)`: the
  /// backward-compatible path for a pre-4.0 `<mc>` key like `"main#Pin3"` or `"DS1#Segment_C"`.
  ///
  /// The seven-segment branch matches the key against `SevenSegment.getLabels()` **by index**,
  /// which is why `FpgaStdIoFacts.sevenSegmentLabels` must preserve upstream's order.
  @discardableResult
  public func tryMap(
    pinKey: String, cmap: CircuitMapInfo, ioComponents: [FpgaIoInformationContainer]
  ) -> Bool {
    // D15a: Java's one-argument `String.split` drops trailing empty fields.
    let parts = javaSplit(pinKey, on: "#")
    guard parts.count == 2 else { return false }
    var number: String?
    if parts[1].contains("Pin") {
      number = String(parts[1].dropFirst(3))
    } else if parts[1].contains("Button") {
      number = String(parts[1].dropFirst(6))
    } else {
      for (id, key) in FpgaStdIoFacts.shared.sevenSegmentLabels().enumerated()
      where parts[1] == key {
        number = String(id)
      }
    }
    guard let number, let pinId = javaParseUnsignedInt32(number).map(Int.init), let rect = cmap.rect else {
      return false
    }
    for comp in ioComponents
    where comp.rectangle?.isPointInside(x: Int(rect.x), y: Int(rect.y)) == true {
      return tryMap(pin: pinId, ioComponent: comp, ioPin: 0)
    }
    return false
  }

  /// `MapComponent.getMapElement(Element)`, as attributes rather than as a DOM mutation.
  ///
  /// Upstream writes straight into an `org.w3c.dom.Element`. The `.circ` writer lives in
  /// `LogisimFile`, below this module, so handing back the attribute pairs is the only shape that
  /// does not invert the dependency. Empty when `hasMap` is false, which is upstream's early
  /// return.
  public var mapElementAttributes: [(name: String, value: String)] {
    guard hasMap else { return [] }
    var result: [(name: String, value: String)] = [
      (Self.mapKey, displayString(Self.onlyIoMapName))
    ]
    if isCompleteMap(bothSides: true) {
      if opens[0] {
        result.append((Self.openKey, Self.openKey))
      } else if constants[0] >= 0 {
        var value: Int64 = 0
        for pin in stride(from: numberOfPins - 1, through: 0, by: -1) {
          value <<= 1
          value += Int64(constants[pin])
        }
        result.append((Self.constantKey, String(value)))
      } else if let rect = maps[0]?.ioComponent.rectangle {
        result.append((Self.completeMap, "\(rect.xPosition),\(rect.yPosition)"))
      }
    } else {
      var text = ""
      var first = true
      for pin in 0..<numberOfPins {
        if first { first = false } else { text += "," }
        if opens[pin] {
          text += Self.openKey
        } else if constants[pin] >= 0 {
          text += String(constants[pin])
        } else if let map = maps[pin], let rect = map.ioComponent.rectangle {
          text += "\(rect.xPosition)_\(rect.yPosition)_\(map.ioPin)"
        } else {
          text += Self.noMap
        }
      }
      result.append((Self.pinMapKey, text))
    }
    return result
  }
}

extension FpgaMapComponent: MappableComponent {}

// NOT PORTED:
//
//   * `MapComponent.getComplexMap(Element, CircuitMapInfo)` and `getMapInfo(Element)`: the
//     static half, already in `LogisimFile/XmlReaderSupport.swift` as `MapComponent`. See the
//     file header for why one Java class is two Swift types here.
