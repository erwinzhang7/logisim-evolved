// BoardReader.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/file/BoardReaderClass.java` (273
// lines), reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.
//
// ══ Error handling: upstream returns null, this throws ══════════════════════════════════════
//
// `getBoardInformation()` is one big `try { … } catch (Exception e) { log; return null; }`, and
// six other paths inside it `return null` after popping a modal dialog. Every caller checks for
// null and reports "could not read the board". So the whole method is *already* a recoverable
// error path in the Java, which is precisely the D13 case: a Swift `throws` preserves the
// behaviour, whereas trapping would turn a bad board file into a dead process.
//
// `BoardReadError` names the six null-returning conditions individually, so a caller can say
// which part of the file was wrong instead of only "it failed". D17 applies to the dialogs:
// `DialogNotification.showDialogNotification(null, "Error", …)` is not ported; the message text
// it carried is preserved in the error's `description`.

import Foundation
import LogisimFile
import LogisimKernel

/// Why a board file could not be read. One case per `return null` in
/// `BoardReaderClass.getBoardInformation()`, plus the parse failure its blanket catch absorbed.
public struct BoardReadError: Error, CustomStringConvertible {
  public enum Reason: Equatable {
    /// The document did not parse at all, or had no root element.
    case malformedXml(String)
    /// `ImageList.getLength() != 1`.
    case missingPictureSection(found: Int)
    /// "The selected XML file does not contain a compression code table"
    case missingCodeTable
    /// "The selected XML file does not contain the picture dimensions"
    case missingPictureDimensions
    /// "The selected XML file does not contain the picture data"
    case missingPixelData
    /// `createImage` returned null, here, any `BoardImageDecodeError`.
    case undecodablePicture(String)
    /// `fpgaList.getLength() != 1`, or "does not contain the required FPGA parameters".
    case missingFpgaParameters
    /// `Long.parseLong` / `Integer.parseInt` on a clock frequency or chain position.
    case malformedNumber(String)
  }
  public let reason: Reason
  public init(_ reason: Reason) { self.reason = reason }

  public var description: String {
    switch reason {
    case let .malformedXml(detail): "board file is not well-formed XML: \(detail)"
    case let .missingPictureSection(found):
      "board file has \(found) <\(BoardWriter.imageInformationString)> sections, expected 1"
    case .missingCodeTable:
      "The selected XML file does not contain a compression code table"
    case .missingPictureDimensions:
      "The selected XML file does not contain the picture dimensions"
    case .missingPixelData: "The selected XML file does not contain the picture data"
    case let .undecodablePicture(detail): "board picture could not be decoded: \(detail)"
    case .missingFpgaParameters:
      "The selected xml file does not contain the required FPGA parameters"
    case let .malformedNumber(detail): "board file has a malformed number: \(detail)"
    }
  }
}

/// `com.cburch.logisim.fpga.file.BoardReaderClass`.
public enum BoardReader {

  /// Reads a board from a file URL.
  ///
  /// Upstream's `myfilename` accepts three forms: `url:` for a classpath resource, `file:` for
  /// a path, and a bare path. The `url:` form loads out of the jar and has no meaning here; a
  /// caller that wants a bundled board resolves it to a URL itself.
  public static func read(contentsOf url: URL) throws -> BoardInformation {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw BoardReadError(.malformedXml("\(error)"))
    }
    return try read(data: data)
  }

  /// Reads a board from the bytes of a board XML file.
  public static func read(data: Data) throws -> BoardInformation {
    let document: XMLDocument
    do {
      // `XmlUtil.getHardenedBuilderFactory()` upstream: DTDs, doctype declarations and external
      // entities all disabled. `.nodeLoadExternalEntitiesNever` is the Foundation equivalent and
      // is what closes the XXE hole a board file could otherwise open; board files are shared
      // between users exactly like `.circ` files are.
      document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    } catch {
      throw BoardReadError(.malformedXml("\(error)"))
    }
    guard let root = document.rootElement() else {
      throw BoardReadError(.malformedXml("no root element"))
    }
    return try read(root: root)
  }

  /// The body of `getBoardInformation()`, given the parsed root.
  public static func read(root: XMLElement) throws -> BoardInformation {
    // ── the picture ─────────────────────────────────────────────────────────────────────────
    let imageSections = elements(named: BoardWriter.imageInformationString, in: root)
    guard imageSections.count == 1 else {
      throw BoardReadError(.missingPictureSection(found: imageSections.count))
    }

    var codeTable: [String]?
    var pixelData: String?
    var pictureWidth = 0
    var pictureHeight = 0

    for child in imageSections[0].children ?? [] {
      guard let element = child as? XMLElement else { continue }
      switch element.name {
      case "CompressionCodeTable":
        for attribute in element.attributes ?? []
        where attribute.name == "TableData" {
          codeTable = BoardImageCodec.codeTable(from: attribute.stringValue ?? "")
        }
      case "PictureDimension":
        for attribute in element.attributes ?? [] {
          // Upstream's `Integer.parseInt` here is unguarded; a non-numeric Width throws out of
          // the method and the blanket catch turns it into "board did not load". Same outcome,
          // spelled as a throw (D13).
          let text = attribute.stringValue ?? ""
          if attribute.name == "Width" {
            guard let value = javaParseInt32(text) else {
              throw BoardReadError(.malformedNumber("PictureDimension/@Width = \"\(text)\""))
            }
            pictureWidth = value
          }
          if attribute.name == "Height" {
            guard let value = javaParseInt32(text) else {
              throw BoardReadError(.malformedNumber("PictureDimension/@Height = \"\(text)\""))
            }
            pictureHeight = value
          }
        }
      case "PixelData":
        for attribute in element.attributes ?? [] where attribute.name == "PixelRGB" {
          pixelData = attribute.stringValue ?? ""
        }
      default:
        break
      }
    }

    guard let codeTable else { throw BoardReadError(.missingCodeTable) }
    guard pictureWidth != 0, pictureHeight != 0 else {
      throw BoardReadError(.missingPictureDimensions)
    }
    guard let pixelData else { throw BoardReadError(.missingPixelData) }

    let result = BoardInformation()
    // `getDocumentElement().getNodeName()`; the board's name is its root element's tag.
    result.setBoardName(root.name)

    let picture: BoardImage
    do {
      picture = try BoardImageCodec.decode(
        stream: pixelData, codeTable: codeTable,
        width: pictureWidth, height: pictureHeight)
    } catch let error as BoardImageDecodeError {
      throw BoardReadError(.undecodablePicture(error.description))
    }
    result.setImage(picture)

    // ── the FPGA ────────────────────────────────────────────────────────────────────────────
    result.fpga = try readFpga(root: root)

    // ── the IO components ───────────────────────────────────────────────────────────────────
    // Four passes, three of them for board files written before the sections were merged. A
    // file that has both an old section and the new one gets both, in this order, which is
    // upstream's behaviour and is why the order is preserved rather than collapsed to one query.
    for section in ["PinsInformation", "ButtonsInformation", "LEDsInformation"] {
      processComponentList(elements(named: section, in: root), into: result)
    }
    processComponentList(
      elements(named: BoardWriter.componentsSectionString, in: root), into: result)
    return result
  }

  /// `getFpgaInfo()`.
  private static func readFpga(root: XMLElement) throws -> FpgaDevice {
    let sections = elements(named: BoardWriter.boardInformationSectionString, in: root)
    guard sections.count == 1 else { throw BoardReadError(.missingFpgaParameters) }

    var frequency: Int64 = -1
    var clockPin: String?
    var clockPull: String?
    var clockStandard: String?
    var unusedPull: String?
    var vendor: String?
    var part: String?
    var family: String?
    var packageName: String?
    var speed: String?
    var usbTmc: String?
    var jtagPosition: String?
    var flashName: String?
    var flashPosition: String?

    for child in sections[0].children ?? [] {
      guard let element = child as? XMLElement else { continue }
      switch element.name {
      case BoardWriter.clockInformationSectionString:
        for attribute in element.attributes ?? [] {
          let text = attribute.stringValue ?? ""
          switch attribute.name {
          case BoardWriter.clockSectionStrings[0]:
            guard let value = javaParseInt64(text) else {
              throw BoardReadError(.malformedNumber("ClockInformation/@Frequency = \"\(text)\""))
            }
            frequency = value
          case BoardWriter.clockSectionStrings[1]: clockPin = text
          case BoardWriter.clockSectionStrings[2]: clockPull = text
          case BoardWriter.clockSectionStrings[3]: clockStandard = text
          default: break
          }
        }
      case BoardWriter.unusedPinsString:
        for attribute in element.attributes ?? []
        where attribute.name == BoardWriter.unusedPinsPullAttribute {
          unusedPull = attribute.stringValue ?? ""
        }
      case BoardWriter.fpgaInformationSectionString:
        for attribute in element.attributes ?? [] {
          let text = attribute.stringValue ?? ""
          switch attribute.name {
          case BoardWriter.fpgaSectionStrings[0]: vendor = text
          case BoardWriter.fpgaSectionStrings[1]: part = text
          case BoardWriter.fpgaSectionStrings[2]: family = text
          case BoardWriter.fpgaSectionStrings[3]: packageName = text
          case BoardWriter.fpgaSectionStrings[4]: speed = text
          case BoardWriter.fpgaSectionStrings[5]: usbTmc = text
          case BoardWriter.fpgaSectionStrings[6]: jtagPosition = text
          case BoardWriter.fpgaSectionStrings[7]: flashName = text
          case BoardWriter.fpgaSectionStrings[8]: flashPosition = text
          default: break
          }
        }
      default:
        break
      }
    }

    // Exactly upstream's ten-way null check. `usbTmc`, `jtagPos` and `flashPos` are explicitly
    // *not* in it, they get defaults below, and `flashName` is never checked at all.
    guard frequency >= 0,
      let clockPin, let clockPull, let clockStandard, let unusedPull,
      let vendor, let part, let family, let packageName, let speed
    else {
      throw BoardReadError(.missingFpgaParameters)
    }

    let device = FpgaDevice()
    do {
      try device.set(
        frequency: frequency,
        pin: clockPin,
        pull: clockPull,
        standard: clockStandard,
        technology: family,
        device: part,
        package: packageName,
        speed: speed,
        vendor: vendor,
        unused: unusedPull,
        // `usbTmc.equals(Boolean.toString(true))`: a strict `== "true"`, so `"TRUE"` and `"1"`
        // both read as false. Preserved.
        usbTmc: (usbTmc ?? "false") == "true",
        jtagPosition: jtagPosition ?? "1",
        flashName: flashName,
        flashPosition: flashPosition ?? "2")
    } catch let error as FpgaChainPositionError {
      throw BoardReadError(.malformedNumber(error.description))
    }
    return device
  }

  /// `processComponentList(NodeList, BoardInformation)`.
  ///
  /// The `compList.getLength() == 1` guard means a board with two `<IOComponents>` sections gets
  /// **neither**: not the first, not both. Reproduced.
  private static func processComponentList(
    _ sections: [XMLElement], into board: BoardInformation
  ) {
    guard sections.count == 1 else { return }
    for child in sections[0].children ?? [] {
      guard let element = child as? XMLElement else { continue }
      let comp = FpgaIoInformationContainer(element: element)
      if comp.isKnownComponent { board.addComponent(comp) }
    }
  }

  /// `Document.getElementsByTagName(String)`: every descendant with that tag, in document
  /// order, **including the root itself** if it matches.
  ///
  /// Foundation offers `elements(forName:)`, which is children-only, so the walk is written out.
  /// Boards nest only two levels deep, but the search must be a full descendant search to match
  /// upstream on a hand-edited file that indents differently.
  static func elements(named name: String, in root: XMLElement) -> [XMLElement] {
    var found: [XMLElement] = []
    var stack: [XMLElement] = [root]
    // Depth-first, children in order; the same traversal order Xerces reports.
    while let element = stack.popLast() {
      if element.name == name { found.append(element) }
      let children = (element.children ?? []).compactMap { $0 as? XMLElement }
      stack.append(contentsOf: children.reversed())
    }
    return found
  }
}
