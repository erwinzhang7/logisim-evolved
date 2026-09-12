// FpgaIoInformationContainer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/data/FpgaIoInformationContainer.java`
// (1157 lines), reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.
//
// One IO component on a board: its type, the rectangle it occupies on the board photo, and the
// FPGA pin names its input/output/bidirectional pins are wired to.
//
// ── Scope ───────────────────────────────────────────────────────────────────────────────────
//
// PORTED (lines 41–857 of the Java, minus the dialog hooks): the `Node` constructor that reads
// one `<IOComponents>` child, the whole pin bookkeeping, `getDocumentElement` (as
// `documentAttributes`), and the map/unmap surface.
//
// NOT PORTED:
//   * lines 859–1157: `setSelectable`, `paint`, `getPartialMapInfo` painting, `mouseMoved`,
//     `mousePressed`, the `JPanel` popup. AWT/Swing, D9.
//   * `edit(Boolean, IoComponentsInformation)` and the two-argument constructor that opens
//     `FpgaIoInformationSettingsDialog`: the board *editor*. D9 and D17 (headless).
//   * `paintColor` / `setHighlighted` / `unsetHighlighted`: they only assign a
//     `BoardManipulator` colour id, which is a Swing concern.
//   * `getPinName(int)`; needs `IoComponentTypes.getInputLabel`/`getOutputLabel`, which reach
//     into `LogisimStd` (`DipSwitch`, `SevenSegment`, `RgbLed`, `ReptarLocalBus`) and the `S`
//     bundle. See `Fpga/FpgaNotPorted.swift`.
//
// ── The `mapType` inner class ───────────────────────────────────────────────────────────────
//
// Upstream's private `mapType` pairs a `MapComponent` with a pin index, and `pinIsMapped` is a
// list of them. The pairing is modelled by `PinMapping`, whose `owner` is the
// `MappableComponent` protocol below, and as of 2026-09-05 that protocol has its conformer,
// `Fpga/FpgaMapComponent.swift`. This note used to say `MapComponent` was not ported and that
// the missing conformer was deliberate; both halves of that are now out of date.

import Foundation
import LogisimKernel

/// The half of `MapComponent`'s surface that `FpgaIoInformationContainer` calls back into.
///
/// **Its conformer landed 2026-09-05: `Fpga/FpgaMapComponent.swift`.** This header used to say
/// the protocol was deliberately conformer-free because `MapComponent` was the only thing that
/// could implement it and was blocked; it is no longer either. Left as a protocol rather than
/// collapsed into a direct reference because the direction matters; the board container calls
/// *up* into whatever owns a pin, and inverting that would make the FPGA model depend on the
/// map instead of the other way round.
public protocol MappableComponent: AnyObject {
  /// `MapComponent.unmap(int)`.
  func unmap(pin: Int)
}

/// `FpgaIoInformationContainer.mapType`; a mapped pin's owner and which of *its* pins we are.
public final class PinMapping {
  public private(set) weak var owner: MappableComponent?
  public let pin: Int

  public init(owner: MappableComponent, pin: Int) {
    self.owner = owner
    self.pin = pin
  }

  /// `mapType.unmap()`.
  public func unmap() { owner?.unmap(pin: pin) }

  /// `mapType.update(MapComponent)`.
  public func update(owner newOwner: MappableComponent) { owner = newOwner }
}

/// `FpgaIoInformationContainer.MapResultClass`.
public struct MapResult {
  public var mapped: Bool
  public var pinId: Int
}

/// `com.cburch.logisim.fpga.data.FpgaIoInformationContainer`.
public final class FpgaIoInformationContainer {

  public private(set) var type: IoComponentTypes = .Unknown
  public internal(set) var rectangle: FpgaBoardRectangle?
  public private(set) var mapRotation: Int = IoComponentTypes.rotationZero

  /// `myPinLocations`: pin index to FPGA pin name. A dictionary, not an array, because the
  /// `FPGAPin_<n>` attribute form can arrive out of order and with gaps, and the "are all pins
  /// present" check below is written against exactly that.
  public private(set) var pinLocations: [Int: String] = [:]

  /// `myInputPins` / `myOutputPins` / `myIoPins`. Genuinely nullable upstream; `null` and
  /// "empty set" are distinguished by the backward-compatibility branch in the constructor and
  /// by `getDocumentElement`, so `Set<Int>?` is the faithful shape, not `Set<Int>`.
  public private(set) var inputPins: Set<Int>?
  public private(set) var outputPins: Set<Int>?
  public private(set) var ioPins: Set<Int>?

  public private(set) var numberOfPins: Int = 0
  /// `nrOfExternalPins`: nonzero only for `LedArray` and `SevenSegmentScanning`, where the file
  /// lists the *driver* pins but the component presents rows×columns logical pins.
  public private(set) var externalPinCount: Int = 0
  public var arrayId: Int = -1

  public var pullBehavior: UInt8 = PullBehaviors.unknown
  public var activityLevel: UInt8 = PinActivity.unknown
  public var ioStandard: UInt8 = IoStandards.unknown
  public var driveStrength: UInt8 = DriveStrength.unknown
  public var label: String?

  public var isToBeDeleted = false
  public private(set) var numberOfRows = 4
  public private(set) var numberOfColumns = 4
  public private(set) var driving: UInt8 = LedArrayDriving.ledDefault

  /// `pinIsMapped`. Sized by `setNumberOfPins`.
  private var pinIsMapped: [PinMapping?] = []

  /// `mapMode`: upstream also flips `paintColor`, which is not ported.
  public private(set) var isMapMode = false

  // MARK: - Construction

  /// `FpgaIoInformationContainer()`.
  public init() {
    setNumberOfPins(0)
  }

  /// `FpgaIoInformationContainer(IoComponentTypes, BoardRectangle, String, String, String,
  /// String, String, String)` via `set(...)`.
  public init(
    type: IoComponentTypes,
    rectangle: FpgaBoardRectangle,
    location: String,
    pull: String,
    active: String,
    standard: String,
    drive: String,
    label: String?
  ) {
    set(
      type: type, rectangle: rectangle, location: location, pull: pull, active: active,
      standard: standard, drive: drive, label: label)
  }

  /// `set(...)`.
  ///
  /// Note the ordering quirk kept from upstream: `setNrOfPins(0)` runs *before* the single pin
  /// location is stored, so `nrOfPins` ends up 0 while `myPinLocations` holds one entry. Nothing
  /// downstream reads pin 0 of such a container without first calling `setNrOfPins(1)`, but the
  /// asymmetry is real and reproducing it keeps the board editor's behaviour intact.
  public func set(
    type compType: IoComponentTypes,
    rectangle rect: FpgaBoardRectangle,
    location: String,
    pull: String,
    active: String,
    standard: String,
    drive: String,
    label newLabel: String?
  ) {
    type = compType
    rectangle = rect
    rect.isActiveOnHigh = (active == PinActivity.behaviorStrings[Int(PinActivity.activeHigh)])
    setNumberOfPins(0)
    pinLocations[0] = location
    pullBehavior = PullBehaviors.id(of: pull)
    activityLevel = PinActivity.id(of: active)
    ioStandard = IoStandards.id(of: standard)
    driveStrength = DriveStrength.id(of: drive)
    label = newLabel
    rect.label = newLabel
  }

  /// `FpgaIoInformationContainer(Node)`; the board-file constructor.
  ///
  /// Returns a container whose `type` is `.Unknown` for every rejection upstream expresses as an
  /// early `return`; `BoardReader` then drops it via `isKnownComponent`. That is the only error
  /// signalling upstream has here and it is preserved rather than converted to a throw, because
  /// a board legitimately contains element names this version does not know (`<Bus>`, and any
  /// future type) and dropping them is correct behaviour, not an error.
  ///
  /// D13: every numeric field goes through `javaParseInt32` / `javaParseUnsignedInt32`, which
  /// return `nil` rather than trapping. Upstream's `Integer.parseInt` calls on `rotation`,
  /// `LocationX/Y`, `Width`, `Height`, `NrOfPins` and `FPGAPin_<n>` are **unguarded** and throw
  /// `NumberFormatException` out of the constructor, which `BoardReaderClass`'s blanket catch
  /// turns into "the whole board failed to load". Reproducing that exactly would mean throwing
  /// here; instead the field is left at its "absent" value, which for `LocationX/Y/Width/Height`
  /// still means the `(x < 0) || … ` guard rejects the component. The difference is confined to
  /// a malformed board and is strictly less destructive. `Rect_x_y_w_h`, `LedArrayInfo` and
  /// `ScanningSevenSegInfo` are *already* guarded upstream by an explicit catch, and those
  /// recovery values are reproduced exactly.
  public init(element: XMLElement) {
    setNumberOfPins(0)

    var inputLocations: [String] = []
    var outputLocations: [String] = []
    var ioLocations: [String] = []

    let setId = IoComponentTypes.from(string: element.name ?? "")
    guard IoComponentTypes.knownComponentSet.contains(setId) else {
      type = .Unknown
      return
    }
    type = setId

    var x = -1
    var y = -1
    var width = -1
    var height = -1

    // Document order, which for a Xerces-written board file is alphabetical by attribute name:
    // see `BoardWriter.swift`. Order matters only where two attributes both write `nrOfPins`
    // (`FPGAPinName` then `NrOfPins`), and alphabetical order is what upstream sees too.
    for attribute in element.attributes ?? [] {
      let name = attribute.name ?? ""
      let value = attribute.stringValue ?? ""

      switch name {
      case BoardWriter.mapRotation:
        if let parsed = javaParseInt32(value) { mapRotation = parsed }
      case BoardWriter.locationXString:
        if let parsed = javaParseInt32(value) { x = parsed }
      case BoardWriter.locationYString:
        if let parsed = javaParseInt32(value) { y = parsed }
      case BoardWriter.widthString:
        if let parsed = javaParseInt32(value) { width = parsed }
      case BoardWriter.heightString:
        if let parsed = javaParseInt32(value) { height = parsed }

      case BoardWriter.rectSetString:
        let values = javaSplitBoardList(value)
        if values.count == 4 {
          if let px = boardParseUnsignedInt(values[0]),
            let py = boardParseUnsignedInt(values[1]),
            let pw = boardParseUnsignedInt(values[2]),
            let ph = boardParseUnsignedInt(values[3])
          {
            x = px
            y = py
            width = pw
            height = ph
          } else {
            // Upstream's `catch (NumberFormatException)` sets all four to -1.
            x = -1
            y = -1
            width = -1
            height = -1
          }
        }

      case BoardWriter.ledArrayInfoString:
        let values = javaSplitBoardList(value)
        if values.count == 3 {
          if let rows = boardParseUnsignedInt(values[0]),
            let columns = boardParseUnsignedInt(values[1])
          {
            numberOfRows = rows
            numberOfColumns = columns
            driving = LedArrayDriving.id(of: values[2])
          } else {
            numberOfRows = 4
            numberOfColumns = 4
            driving = LedArrayDriving.ledDefault
          }
        }

      case BoardWriter.scanningSevenSegmentInfoString:
        let values = javaSplitBoardList(value)
        if values.count == 3 {
          // Upstream uses parseUnsignedInt for rows but plain parseInt for columns here. Kept.
          if let rows = boardParseUnsignedInt(values[0]),
            let columns = javaParseInt32(values[1])
          {
            numberOfRows = rows
            numberOfColumns = columns
            driving = SevenSegmentScanningDriving.id(of: values[2])
          } else {
            numberOfRows = 4
            numberOfColumns = 2
            driving = SevenSegmentScanningDriving.sevenSegDecoded
          }
        }

      case BoardWriter.pinLocationString:
        setNumberOfPins(1)
        pinLocations[0] = value

      case BoardWriter.multiPinInformationString:
        if let count = javaParseInt32(value) { setNumberOfPins(count) }

      case BoardWriter.labelString:
        label = value
      case DriveStrength.driveAttributeString:
        driveStrength = DriveStrength.id(of: value)
      case PullBehaviors.pullAttributeString:
        pullBehavior = PullBehaviors.id(of: value)
      case IoStandards.ioAttributeString:
        ioStandard = IoStandards.id(of: value)
      case PinActivity.activityAttributeString:
        activityLevel = PinActivity.id(of: value)

      case BoardWriter.inputSetString:
        inputLocations.append(contentsOf: javaSplitBoardList(value))
      case BoardWriter.outputSetString:
        outputLocations.append(contentsOf: javaSplitBoardList(value))
      case BoardWriter.ioSetString:
        ioLocations.append(contentsOf: javaSplitBoardList(value))

      default:
        // `startsWith("FPGAPin_")` is checked last, exactly as upstream does: note
        // `FPGAPinName`, `FPGAPinIOStandard`, `FPGAPinPullBehavior` and `FPGAPinDriveStrength`
        // all begin "FPGAPin" but none begins "FPGAPin_", so there is no collision.
        if name.hasPrefix(BoardWriter.multiPinPrefixString) {
          let idText = String(name.dropFirst(BoardWriter.multiPinPrefixString.count))
          if let id = javaParseInt32(idText) { pinLocations[id] = value }
        }
      }
    }

    if x < 0 || y < 0 || width < 1 || height < 1 {
      type = .Unknown
      return
    }

    var index = 0
    for location in inputLocations {
      pinLocations[index] = location
      if inputPins == nil { inputPins = [] }
      inputPins?.insert(index)
      index += 1
    }
    for location in outputLocations {
      pinLocations[index] = location
      if outputPins == nil { outputPins = [] }
      outputPins?.insert(index)
      index += 1
    }
    for location in ioLocations {
      pinLocations[index] = location
      if ioPins == nil { ioPins = [] }
      ioPins?.insert(index)
      index += 1
    }
    if index != 0 { setNumberOfPins(index) }

    for pin in 0..<numberOfPins where pinLocations[pin] == nil {
      // Upstream logs `"Bizar missing pin {} of component!"` and rejects the component.
      type = .Unknown
      return
    }

    // Backward compatibility: a pre-`InputPinSet` board listed pins positionally, so the counts
    // come from the type's requirements instead.
    if inputPins == nil && outputPins == nil && ioPins == nil {
      let inputCount = IoComponentTypes.fpgaInputRequirement(type)
      let outputCount = IoComponentTypes.fpgaOutputRequirement(type)
      for pin in 0..<numberOfPins {
        if pin < inputCount {
          if inputPins == nil { inputPins = [] }
          inputPins?.insert(pin)
        } else if pin < (inputCount + outputCount) {
          if outputPins == nil { outputPins = [] }
          outputPins?.insert(pin)
        } else {
          if ioPins == nil { ioPins = [] }
          ioPins?.insert(pin)
        }
      }
    }

    if type == .Pin { activityLevel = PinActivity.activeHigh }
    let rect = FpgaBoardRectangle(x: x, y: y, width: width, height: height)
    rectangle = rect
    if let label { rect.label = label }

    if type == .LedArray {
      externalPinCount = numberOfPins
      setNumberOfPins(numberOfRows * numberOfColumns)
      outputPins?.removeAll()
      // Upstream dereferences `myOutputPins` unguarded here; a `<LedArray>` with no
      // `OutputPinSet` and no positional pins would NPE out of the constructor and take the
      // whole board with it. D13 says a board file must not be able to do that, so the set is
      // created if absent, which produces the same result for every well-formed board.
      if outputPins == nil { outputPins = [] }
      for pin in 0..<numberOfPins { outputPins?.insert(pin) }
    }
    if type == .SevenSegmentScanning {
      externalPinCount = numberOfPins
      setNumberOfPins(numberOfRows * 8)
      outputPins?.removeAll()
      if outputPins == nil { outputPins = [] }
      for pin in 0..<numberOfPins { outputPins?.insert(pin) }
    }
  }

  // MARK: - Pin bookkeeping

  /// `setNrOfPins(int)`. Growing appends `nil`s; shrinking unmaps what it drops.
  public func setNumberOfPins(_ count: Int) {
    let clamped = max(count, 0)
    numberOfPins = clamped
    if clamped > pinIsMapped.count {
      pinIsMapped.append(
        contentsOf: [PinMapping?](repeating: nil, count: clamped - pinIsMapped.count))
    } else if clamped < pinIsMapped.count {
      for index in stride(from: pinIsMapped.count - 1, through: clamped, by: -1) {
        pinIsMapped[index]?.unmap()
        pinIsMapped.remove(at: index)
      }
    }
  }

  /// `getPinLocation(int)`, `getOrDefault(index, "")`.
  public func pinLocation(_ index: Int) -> String { pinLocations[index] ?? "" }

  public func setInputPinLocation(_ index: Int, _ value: String) {
    outputPins?.remove(index)
    ioPins?.remove(index)
    if inputPins == nil { inputPins = [] }
    inputPins?.insert(index)
    pinLocations[index] = value
  }

  public func setOutputPinLocation(_ index: Int, _ value: String) {
    inputPins?.remove(index)
    ioPins?.remove(index)
    if outputPins == nil { outputPins = [] }
    outputPins?.insert(index)
    pinLocations[index] = value
  }

  public func setIoPinLocation(_ index: Int, _ value: String) {
    inputPins?.remove(index)
    outputPins?.remove(index)
    if ioPins == nil { ioPins = [] }
    ioPins?.insert(index)
    pinLocations[index] = value
  }

  public func setNumberOfRows(_ value: Int) { numberOfRows = value }
  public func setNumberOfColumns(_ value: Int) { numberOfColumns = value }
  public func setArrayDriveMode(_ value: UInt8) { driving = value }

  /// `setMapRotation(int)`; silently ignores anything that is not one of the three legal values.
  public func setMapRotation(_ value: Int) {
    if value == IoComponentTypes.rotationCw90 || value == IoComponentTypes.rotationCcw90
      || value == IoComponentTypes.rotationZero
    {
      mapRotation = value
    }
  }

  public func setMapMode() { isMapMode = true }

  // MARK: - Queries

  public var isInput: Bool { IoComponentTypes.inputComponentSet.contains(type) }
  public var isOutput: Bool { IoComponentTypes.outputComponentSet.contains(type) }
  public var isInputOutput: Bool { IoComponentTypes.inOutComponentSet.contains(type) }
  public var isKnownComponent: Bool { IoComponentTypes.knownComponentSet.contains(type) }

  public var numberOfInputPins: Int { inputPins?.count ?? 0 }
  public var numberOfOutputPins: Int { outputPins?.count ?? 0 }
  public var numberOfIoPins: Int { ioPins?.count ?? 0 }
  public var hasInputs: Bool { !(inputPins?.isEmpty ?? true) }
  public var hasOutputs: Bool { !(outputPins?.isEmpty ?? true) }
  public var hasIoPins: Bool { !(ioPins?.isEmpty ?? true) }

  /// `getDisplayString()`.
  public var displayString: String { label ?? type.rawValue }

  /// `isPinMapped(int)`. Note the **out-of-range answer is `true`**, not `false`; upstream
  /// treats a nonexistent pin as "nothing left to map", which is what makes `hasMap()` and
  /// `isCompletelyMappedBy` terminate sensibly on a resized container.
  public func isPinMapped(_ index: Int) -> Bool {
    if index < 0 || index >= numberOfPins { return true }
    return pinIsMapped[index] != nil
  }

  /// `hasMap()`.
  public var hasMap: Bool {
    (0..<numberOfPins).contains { isPinMapped($0) }
  }

  /// `getPinMap(int)`.
  public func pinMap(_ index: Int) -> MappableComponent? {
    guard index >= 0, index < numberOfPins else { return nil }
    return pinIsMapped[index]?.owner
  }

  /// `getMapPin(int)`.
  public func mapPin(_ index: Int) -> Int {
    guard index >= 0, index < numberOfPins else { return -1 }
    return pinIsMapped[index]?.pin ?? -1
  }

  // MARK: - Mapping

  /// `unmap(int)`.
  public func unmap(pin: Int) {
    guard pin >= 0, pin < pinIsMapped.count else { return }
    let map = pinIsMapped[pin]
    pinIsMapped[pin] = nil
    map?.unmap()
  }

  /// `tryInputMap(MapComponent, int, int)`. Falls through to `tryIoMap` when this pin is not an
  /// input, which is how a `Pin` component (both input and bidirectional) maps either way.
  @discardableResult
  public func tryInputMap(_ comp: MappableComponent, componentPin: Int, inputPin: Int)
    -> MapResult
  {
    var result = MapResult(mapped: false, pinId: inputPin)
    guard let inputPins, inputPins.contains(result.pinId) else {
      return tryIoMap(comp, componentPin: componentPin, ioPin: inputPin)
    }
    unmap(pin: result.pinId)
    pinIsMapped[result.pinId] = PinMapping(owner: comp, pin: componentPin)
    result.mapped = true
    return result
  }

  /// `tryOutputMap(MapComponent, int, int)`; the output pin index is offset past the inputs.
  @discardableResult
  public func tryOutputMap(_ comp: MappableComponent, componentPin: Int, outputPin: Int)
    -> MapResult
  {
    var result = MapResult(mapped: false, pinId: outputPin + (inputPins?.count ?? 0))
    guard let outputPins, outputPins.contains(result.pinId) else {
      // Upstream passes the *unoffset* `outpPin` on, not `result.pinId`. Kept.
      return tryIoMap(comp, componentPin: componentPin, ioPin: outputPin)
    }
    unmap(pin: result.pinId)
    pinIsMapped[result.pinId] = PinMapping(owner: comp, pin: componentPin)
    result.mapped = true
    return result
  }

  /// `tryIOMap(MapComponent, int, int)`.
  @discardableResult
  public func tryIoMap(_ comp: MappableComponent, componentPin: Int, ioPin: Int) -> MapResult {
    var result = MapResult(
      mapped: false,
      pinId: ioPin + (inputPins?.count ?? 0) + (outputPins?.count ?? 0))
    guard let ioPins, ioPins.contains(result.pinId) else { return result }
    unmap(pin: result.pinId)
    pinIsMapped[result.pinId] = PinMapping(owner: comp, pin: componentPin)
    result.mapped = true
    return result
  }

  /// `tryMap(MapComponent, int, int)`.
  @discardableResult
  public func tryMap(_ comp: MappableComponent, componentPin: Int, myPin: Int) -> Bool {
    guard myPin >= 0, myPin < numberOfPins else { return false }
    unmap(pin: myPin)
    pinIsMapped[myPin] = PinMapping(owner: comp, pin: componentPin)
    return true
  }

  /// `updateMap(int, MapComponent)`.
  @discardableResult
  public func updateMap(pin: Int, owner: MappableComponent) -> Bool {
    guard pin >= 0, pin < pinIsMapped.count, let map = pinIsMapped[pin] else { return false }
    map.update(owner: owner)
    return true
  }

  /// `isCompletelyMappedBy(MapComponent)`.
  public func isCompletelyMapped(by comp: MappableComponent) -> Bool {
    for index in 0..<numberOfPins {
      guard let map = pinIsMapped[index], map.owner === comp else { return false }
    }
    return true
  }

  /// `clone()`.
  ///
  /// Upstream's is a **shallow** copy that shares `myPinLocations` and the three pin sets with
  /// the original, and rebuilds `pinIsMapped` as `nrOfPins` nulls, which is a live NPE there,
  /// because `new FpgaIoInformationContainer()` leaves `pinIsMapped` null until `setNrOfPins`
  /// runs, and the no-argument constructor does call `setNrOfPins(0)`, so the list exists but is
  /// empty and `add` grows it. The sharing is intentional: `MappableResourcesContainer` clones
  /// every board component and only ever changes the clone's *mapping*.
  ///
  /// Swift value semantics make the dictionary and sets copies rather than shared references.
  /// That is a divergence and it is safe in one direction only: the clone never writes them
  /// back. Recorded here so a future `MappableResourcesContainer` does not assume aliasing.
  public func cloned() -> FpgaIoInformationContainer {
    let clone = FpgaIoInformationContainer()
    clone.type = type
    clone.rectangle = rectangle
    clone.mapRotation = mapRotation
    clone.pinLocations = pinLocations
    clone.inputPins = inputPins
    clone.outputPins = outputPins
    clone.ioPins = ioPins
    clone.externalPinCount = externalPinCount
    clone.arrayId = arrayId
    clone.pullBehavior = pullBehavior
    clone.activityLevel = activityLevel
    clone.ioStandard = ioStandard
    clone.driveStrength = driveStrength
    clone.label = label
    clone.driving = driving
    clone.numberOfRows = numberOfRows
    clone.numberOfColumns = numberOfColumns
    clone.setNumberOfPins(numberOfPins)
    return clone
  }
}
