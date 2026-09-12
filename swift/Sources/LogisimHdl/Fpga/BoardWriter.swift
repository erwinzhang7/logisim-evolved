// BoardWriter.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/file/BoardWriterClass.java` (199
// lines), reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.
//
// ══ The board XML is a file format, so it is byte-sensitive ═════════════════════════════════
//
// Two facts about how upstream produces it, both confirmed against the 29 board files shipped
// inside `logisim-evolution-4.1.0-all.jar`:
//
//  1. **Attributes are serialised alphabetically, not in insertion order.** Java's
//     `Transformer` walks a Xerces `NamedNodeMap`, which is sorted. This project already
//     learned it once for the `<appear>` section, `LogisimDraw/Svg/SvgElement.swift` documents
//     it with corpus evidence, and the board files show exactly the same thing. Upstream sets
//     `Frequency` first and `FPGApin` second, yet every shipped file reads
//     `<ClockInformation FPGApin="…" Frequency="…" IOStandard="…" PullBehavior="…"/>`; the
//     `<FPGAInformation>` element is likewise `Family, FlashName, FlashPos, JTAGPos, Package,
//     Part, Speedgrade, USBTMC, Vendor` while the writer assigns `Vendor` first. So the answer
//     to "is the board reader subject to the same thing?" is **yes**, and `attributes(of:)`
//     below sorts, rather than trusting insertion order.
//
//     Ordinary ASCII byte order, not a locale collation: `FPGApin` < `Frequency` because `P`
//     (0x50) < `r` (0x72), which a case-insensitive comparison would reverse.
//
//  2. Indentation is three spaces (`tranFactory.setAttribute("indent-number", 3)`), the XML
//     declaration carries `standalone="no"`, and each of the three sections opens with a
//     comment whose text is misspelled upstream (`"This section decribes the FPGA and its
//     clock"`, `"This section hold the board picture"`). Those spellings are part of the bytes.
//
// ══ What is ported ══════════════════════════════════════════════════════════════════════════
//
// The **string constants** (which the reader needs, and which is why this file comes first in
// the dependency order) and the **element construction**, as a pure `BoardXmlElement` tree that
// a caller serialises.
//
// NOT PORTED: `printXml()` / `printXml(String)`, which are `javax.xml.transform` plumbing plus
// slf4j logging, and the **image half of the constructor**. `BoardWriterClass` takes a
// `java.awt.Image`, rasterises it into a 740×400 `BufferedImage` with `Graphics2D.fillRect` per
// pixel, and JPEG-encodes it with `ImageIO`. That is D9 territory three times over. The
// *encoding* step after the JPEG bytes exist, the frequency-sorted code table and the ASCII
// stream, IS ported, in `BoardImageCodec.swift`, and takes `[UInt8]` JPEG data. A UI layer that
// can produce JPEG bytes therefore has everything it needs; nothing in this module can produce
// them, and nothing in this module needs to.

/// `com.cburch.logisim.fpga.file.BoardWriterClass`, the board XML vocabulary.
public enum BoardWriter {

  public static let boardInformationSectionString = "BoardInformation"
  public static let clockInformationSectionString = "ClockInformation"
  public static let inputSetString = "InputPinSet"
  public static let outputSetString = "OutputPinSet"
  public static let ioSetString = "BiDirPinSet"
  public static let rectSetString = "Rect_x_y_w_h"
  public static let ledArrayInfoString = "LedArrayInfo"
  public static let scanningSevenSegmentInfoString = "ScanningSevenSegInfo"
  public static let mapRotation = "rotation"
  public static let clockSectionStrings = ["Frequency", "FPGApin", "PullBehavior", "IOStandard"]
  public static let fpgaInformationSectionString = "FPGAInformation"
  public static let fpgaSectionStrings = [
    "Vendor", "Part", "Family", "Package", "Speedgrade", "USBTMC", "JTAGPos", "FlashName",
    "FlashPos",
  ]
  public static let unusedPinsString = "UnusedPins"
  public static let componentsSectionString = "IOComponents"
  public static let locationXString = "LocationX"
  public static let locationYString = "LocationY"
  public static let widthString = "Width"
  public static let heightString = "Height"
  public static let pinLocationString = "FPGAPinName"
  public static let imageInformationString = "BoardPicture"
  public static let multiPinInformationString = "NrOfPins"
  public static let multiPinPrefixString = "FPGAPin_"
  public static let labelString = "Label"

  /// The `UnusedPins` element's one attribute; upstream spells it inline as a literal in both
  /// the reader and the writer rather than naming a constant.
  public static let unusedPinsPullAttribute = "PullBehavior"

  /// The three comments the writer emits, spelling errors included; they are bytes in every
  /// shipped board file.
  public static let boardInformationComment = "This section decribes the FPGA and its clock"
  public static let componentsComment = "This section describes all Components present on the boards"
  public static let boardPictureComment = "This section hold the board picture"
}

/// A minimal element tree, so the writer can be exercised without a DOM.
///
/// Foundation's `XMLElement` would do, but it is a class with document affinity and its
/// serialiser does not reproduce Xerces' alphabetical attribute order; the very thing this file
/// exists to get right. A value tree keeps `attributes(of:)` honest and testable.
public struct BoardXmlElement: Equatable {
  public var name: String
  /// Stored in *insertion* order, exactly as upstream's `setAttribute` calls arrive.
  /// `sortedAttributes` is what a serialiser must use.
  public var attributes: [(name: String, value: String)]
  public var comment: String?
  public var children: [BoardXmlElement]

  public init(
    name: String,
    attributes: [(name: String, value: String)] = [],
    comment: String? = nil,
    children: [BoardXmlElement] = []
  ) {
    self.name = name
    self.attributes = attributes
    self.comment = comment
    self.children = children
  }

  /// Attributes in the order a Xerces `Transformer` writes them: ascending by UTF-8 code unit.
  public var sortedAttributes: [(name: String, value: String)] {
    attributes.sorted { lhs, rhs in
      Array(lhs.name.utf8).lexicographicallyPrecedes(Array(rhs.name.utf8))
    }
  }

  public static func == (lhs: BoardXmlElement, rhs: BoardXmlElement) -> Bool {
    lhs.name == rhs.name
      && lhs.comment == rhs.comment
      && lhs.children == rhs.children
      && lhs.attributes.map { [$0.name, $0.value] } == rhs.attributes.map { [$0.name, $0.value] }
  }
}

extension FpgaIoInformationContainer {

  /// `getDocumentElement(Document)`; the element describing this component.
  ///
  /// Returns `nil` for an `Unknown` component, matching upstream. The attribute *set* is what
  /// matters (the order is imposed by the serialiser, see the file header), and the four
  /// "only when non-default" rules are reproduced exactly:
  ///
  ///   * drive strength is written unless it is `unknown` **or** `Default`
  ///   * pull behaviour unless `unknown` or `Float`
  ///   * IO standard unless `unknown` or `Default`
  ///   * activity level unless `unknown` or `Active high`
  ///
  /// which is why `TERASIC_DE0`'s active-high buttons carry no `ActivityLevel` attribute and its
  /// active-low ones do.
  public func documentElement() -> BoardXmlElement? {
    guard type != .Unknown, let rectangle else { return nil }
    var attributes: [(name: String, value: String)] = []
    attributes.append(
      (
        BoardWriter.rectSetString,
        "\(rectangle.xPosition),\(rectangle.yPosition),\(rectangle.width),\(rectangle.height)"
      ))
    if let label { attributes.append((BoardWriter.labelString, label)) }
    if type == .LedArray {
      attributes.append(
        (
          BoardWriter.ledArrayInfoString,
          "\(numberOfRows),\(numberOfColumns),\(ledArrayDrivingString)"
        ))
    }
    if type == .SevenSegmentScanning {
      attributes.append(
        (
          BoardWriter.scanningSevenSegmentInfoString,
          "\(numberOfRows),\(numberOfColumns),\(sevenSegmentScanningDrivingString)"
        ))
    }
    if IoComponentTypes.hasRotationAttribute(type),
      mapRotation == IoComponentTypes.rotationCw90
        || mapRotation == IoComponentTypes.rotationCcw90
    {
      attributes.append((BoardWriter.mapRotation, String(mapRotation)))
    }
    if let set = pinSetAttribute(BoardWriter.inputSetString, inputPins) { attributes.append(set) }
    if let set = pinSetAttribute(BoardWriter.outputSetString, outputPins) {
      attributes.append(set)
    }
    if let set = pinSetAttribute(BoardWriter.ioSetString, ioPins) { attributes.append(set) }

    if driveStrength != DriveStrength.unknown, driveStrength != DriveStrength.defaultStrength {
      attributes.append(
        (DriveStrength.driveAttributeString, DriveStrength.behaviorStrings[Int(driveStrength)]))
    }
    if pullBehavior != PullBehaviors.unknown, pullBehavior != PullBehaviors.float {
      attributes.append(
        (PullBehaviors.pullAttributeString, PullBehaviors.behaviorStrings[Int(pullBehavior)]))
    }
    if ioStandard != IoStandards.unknown, ioStandard != IoStandards.defaultStandard {
      attributes.append(
        (IoStandards.ioAttributeString, IoStandards.behaviorStrings[Int(ioStandard)]))
    }
    if activityLevel != PinActivity.unknown, activityLevel != PinActivity.activeHigh {
      attributes.append(
        (PinActivity.activityAttributeString, PinActivity.behaviorStrings[Int(activityLevel)]))
    }
    return BoardXmlElement(name: type.rawValue, attributes: attributes)
  }

  /// The `InputPinSet` / `OutputPinSet` / `BiDirPinSet` builder.
  ///
  /// The iteration bound is `nrOfExternalPins == 0 ? nrOfPins : nrOfExternalPins`, which is what
  /// makes an `LedArray` write back the eight driver pins it was read with rather than the
  /// rows×columns logical pins it expanded to.
  private func pinSetAttribute(_ name: String, _ pins: Set<Int>?)
    -> (name: String, value: String)?
  {
    guard let pins, !pins.isEmpty else { return nil }
    let bound = externalPinCount == 0 ? numberOfPins : externalPinCount
    var parts: [String] = []
    for index in 0..<bound where pins.contains(index) {
      // Upstream appends `myPinLocations.get(i)`, which is Java `null` for a missing pin and
      // stringifies as "null". `pinLocation` answers "" instead; a container that reaches the
      // writer with a hole in its pin table was rejected by the reader, so no board file can
      // tell the difference.
      parts.append(pinLocation(index))
    }
    return (name, parts.joined(separator: ","))
  }

  /// `LedArrayDriving.getStrings().get(driving)`: an unguarded list index upstream, so a
  /// `driving` of 255 throws. D13: clamp to the default instead.
  private var ledArrayDrivingString: String {
    Int(driving) < LedArrayDriving.strings.count
      ? LedArrayDriving.strings[Int(driving)] : LedArrayDriving.drivingStrings[0]
  }

  private var sevenSegmentScanningDrivingString: String {
    Int(driving) < SevenSegmentScanningDriving.strings.count
      ? SevenSegmentScanningDriving.strings[Int(driving)]
      : SevenSegmentScanningDriving.drivingStrings[0]
  }
}

extension BoardInformation {

  /// The `BoardWriterClass` constructor's document, minus the `<BoardPicture>` section.
  ///
  /// The caller supplies the picture element because building it needs JPEG bytes, which this
  /// module cannot produce (see the file header). Pass `nil` to omit it, which is what the
  /// round-trip test does when it only cares about the model.
  ///
  /// D13 note on the four `min(_, n)` clamps below: upstream writes
  /// `PullBehaviors.BEHAVIOR_STRINGS[fpga.getClockPull()]` unguarded, so a device whose pull is
  /// the `unknown` sentinel (255) throws `ArrayIndexOutOfBoundsException` out of the
  /// `BoardWriterClass` constructor, which its own blanket catch then swallows, leaving a
  /// half-built document. Clamping to the last legal entry keeps the writer total. A device read
  /// by `BoardReader` never reaches this: `getId` returns 255 only for a spelling not in the
  /// table, and the four sites here are the clock pull, the clock standard, the unused-pin pull
  /// and the vendor, all of which a hand-edited board file can indeed set to something unknown.
  public func documentTree(picture: BoardXmlElement?) -> BoardXmlElement {
    var fpgaSection = BoardXmlElement(
      name: BoardWriter.boardInformationSectionString,
      comment: BoardWriter.boardInformationComment)

    fpgaSection.children.append(
      BoardXmlElement(
        name: BoardWriter.clockInformationSectionString,
        attributes: [
          (BoardWriter.clockSectionStrings[0], String(fpga.clockFrequency)),
          // `.toUpperCase()` upstream: with the default locale, which is a latent Turkish-i
          // bug there. `uppercased()` here is Unicode-correct and locale-independent; every pin
          // name in every shipped board is ASCII.
          (BoardWriter.clockSectionStrings[1], (fpga.clockPinLocation ?? "").uppercased()),
          (
            BoardWriter.clockSectionStrings[2],
            PullBehaviors.behaviorStrings[Int(min(fpga.clockPullBehavior, 2))]
          ),
          (
            BoardWriter.clockSectionStrings[3],
            IoStandards.behaviorStrings[Int(min(fpga.clockIoStandard, 6))]
          ),
        ]))

    fpgaSection.children.append(
      BoardXmlElement(
        name: BoardWriter.fpgaInformationSectionString,
        attributes: [
          (
            BoardWriter.fpgaSectionStrings[0],
            FpgaVendor.vendors[Int(min(fpga.vendor, 3))].uppercased()
          ),
          (BoardWriter.fpgaSectionStrings[1], fpga.part ?? "null"),
          (BoardWriter.fpgaSectionStrings[2], fpga.technology ?? "null"),
          (BoardWriter.fpgaSectionStrings[3], fpga.packageName ?? "null"),
          (BoardWriter.fpgaSectionStrings[4], fpga.speedGrade ?? "null"),
          (BoardWriter.fpgaSectionStrings[5], String(fpga.isUsbTmcDownloadRequired)),
          (BoardWriter.fpgaSectionStrings[6], String(fpga.jtagChainPosition)),
          // `String.valueOf(getFlashName())` stringifies a Java null as "null", and that literal
          // is in TERASIC_DE0.xml today (`FlashName="null"`). Reproduced.
          (BoardWriter.fpgaSectionStrings[7], fpga.flashName ?? "null"),
          (BoardWriter.fpgaSectionStrings[8], String(fpga.flashChainPosition)),
        ]))

    fpgaSection.children.append(
      BoardXmlElement(
        name: BoardWriter.unusedPinsString,
        attributes: [
          (
            BoardWriter.unusedPinsPullAttribute,
            PullBehaviors.behaviorStrings[Int(min(fpga.unusedPinsBehavior, 2))]
          )
        ]))

    var components = BoardXmlElement(
      name: BoardWriter.componentsSectionString, comment: BoardWriter.componentsComment)
    for comp in allComponents {
      if let element = comp.documentElement() { components.children.append(element) }
    }

    var root = BoardXmlElement(name: boardName ?? "")
    root.children = [fpgaSection, components]
    if let picture { root.children.append(picture) }
    return root
  }
}
