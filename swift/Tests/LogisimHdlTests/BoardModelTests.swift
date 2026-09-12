// BoardModelTests.swift: part of logisim-evolved.
//
// The board model's unit tests. `BoardGateTests` covers everything the 29 shipped boards
// exercise; this suite covers what they do **not**, which is where a transcription error would
// otherwise sit undetected:
//
//   * the pre-JPEG uncompressed picture encoding; no shipped board uses it, every one carries
//     the `@` marker;
//   * every D13 rejection path, since every shipped board is well formed;
//   * `getId` table order for the six attribute tables, which the gate only samples;
//   * the writer, which the gate does not touch at all;
//   * `getPartialMapInfo`, which is geometry no board file can wrong-foot.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimHdl
import LogisimStd
import Testing

@Suite("FPGA board model")
struct BoardModelTests {

  // MARK: - Attribute tables

  @Test("the six getId tables map every spelling to upstream's index")
  func attributeTableIds() {
    #expect(PinActivity.id(of: "Active low") == 0)
    #expect(PinActivity.id(of: "Active high") == 1)
    #expect(PinActivity.id(of: "active high") == 255, "getId is case-SENSITIVE")

    #expect(PullBehaviors.id(of: "Float") == 0)
    #expect(PullBehaviors.id(of: "Pull Up") == 1)
    #expect(PullBehaviors.id(of: "Pull Down") == 2)
    #expect(PullBehaviors.id(of: "") == 255)

    #expect(IoStandards.id(of: "Default") == 0)
    #expect(IoStandards.id(of: "LVCMOS33") == 5)
    #expect(IoStandards.id(of: "LVTTL") == 6)

    #expect(DriveStrength.id(of: "Default") == 0)
    #expect(DriveStrength.id(of: "24 mA") == 5)

    #expect(LedArrayDriving.id(of: "LedDefault") == 0)
    #expect(LedArrayDriving.id(of: "RgbColScanning") == 5)

    #expect(SevenSegmentScanningDriving.id(of: "SevenSegDecoded") == 0)
    #expect(SevenSegmentScanningDriving.id(of: "SevenSegScanningActiveHi") == 2)

    // The vendor lookup is the one that ignores case, which is why every board file can write
    // `Vendor="ALTERA"` and `Vendor="VIVADO"`.
    #expect(FpgaVendor.id(of: "ALTERA") == 0)
    #expect(FpgaVendor.id(of: "Altera") == 0)
    #expect(FpgaVendor.id(of: "VIVADO") == 2)
    #expect(FpgaVendor.id(of: "openfpga") == 3)
    #expect(FpgaVendor.id(of: "Lattice") == 255)
  }

  @Test("the constraint-string helpers keep upstream's odd shapes")
  func constraintStrings() {
    // A trailing space, because `" mA"` is replaced by `" "`.
    #expect(DriveStrength.constrainedDriveStrength(DriveStrength.drive2) == "2 ")
    #expect(DriveStrength.constrainedDriveStrength(DriveStrength.defaultStrength) == "")
    #expect(DriveStrength.constrainedDriveStrength(DriveStrength.unknown) == "")
    #expect(DriveStrength.driveString(DriveStrength.drive16) == "16")
    #expect(DriveStrength.driveString(DriveStrength.defaultStrength) == nil)

    #expect(PullBehaviors.constrainedPullString(PullBehaviors.pullUp) == "PULLUP")
    #expect(PullBehaviors.constrainedPullString(PullBehaviors.float) == "")
    #expect(PullBehaviors.pullString(PullBehaviors.float) == nil)
    #expect(PullBehaviors.pullString(PullBehaviors.unknown) == nil)
    #expect(PullBehaviors.pullString(PullBehaviors.pullDown) == "DOWN")

    #expect(IoStandards.constrainedIoStandard(IoStandards.defaultStandard) == "")
    #expect(IoStandards.constrainedIoStandard(IoStandards.lvttl) == "LVTTL")
    #expect(IoStandards.ioString(IoStandards.defaultStandard) == nil)

    // This one answers a string rather than "" or nil.
    #expect(LedArrayDriving.constrainedDriveMode(LedArrayDriving.unknown) == "Unknown")
    #expect(LedArrayDriving.constrainedDriveMode(LedArrayDriving.rgbDefault) == "RgbDefault")
  }

  @Test("component type names round-trip case-insensitively, as board files need")
  func componentTypeNames() {
    // The shipped files spell these `<LED>` and `<PortIO>`.
    #expect(IoComponentTypes.from(string: "LED") == .Led)
    #expect(IoComponentTypes.from(string: "PortIO") == .PortIo)
    #expect(IoComponentTypes.from(string: "dipswitch") == .DIPSwitch)
    // Outside KNOWN_COMPONENT_SET, so unknown even though the case name exists.
    #expect(IoComponentTypes.from(string: "Bus") == .Unknown)
    #expect(IoComponentTypes.from(string: "Open") == .Unknown)
    #expect(IoComponentTypes.from(string: "nonsense") == .Unknown)

    #expect(IoComponentTypes.numberOfFpgaPins(.LocalBus) == 31)  // 16 io + 13 in + 2 out
    #expect(IoComponentTypes.numberOfFpgaPins(.SevenSegment) == 8)
    #expect(IoComponentTypes.numberOfFpgaPins(.Pin) == 1)
    #expect(IoComponentTypes.hasRotationAttribute(.LedArray))
    #expect(!IoComponentTypes.hasRotationAttribute(.Led))
  }

  /// The segment indices are transcribed into `LogisimHdl` because that module must not depend
  /// on `LogisimStd` (see `IoComponentTypes.swift`). This is the pin that keeps the copy honest.
  @Test("the transcribed seven-segment indices still match LogisimStd's")
  func sevenSegmentIndicesMatchStdIo() {
    typealias Index = IoComponentTypes.SevenSegmentIndex
    #expect(Index.segmentA == SevenSegment.segmentA)
    #expect(Index.segmentB == SevenSegment.segmentB)
    #expect(Index.segmentC == SevenSegment.segmentC)
    #expect(Index.segmentD == SevenSegment.segmentD)
    #expect(Index.segmentE == SevenSegment.segmentE)
    #expect(Index.segmentF == SevenSegment.segmentF)
    #expect(Index.segmentG == SevenSegment.segmentG)
    #expect(Index.decimalPoint == SevenSegment.decimalPointIndex)
  }

  // MARK: - Rectangles

  @Test("a negative extent moves the origin, and equality ignores everything but geometry")
  func rectangleNormalisationAndEquality() {
    let normalised = FpgaBoardRectangle(x: 10, y: 10, width: -4, height: -6)
    #expect(normalised.xPosition == 6)
    #expect(normalised.yPosition == 4)
    #expect(normalised.width == 4)
    #expect(normalised.height == 6)

    let a = FpgaBoardRectangle(x: 1, y: 2, width: 3, height: 4)
    let b = FpgaBoardRectangle(x: 1, y: 2, width: 3, height: 4)
    a.label = "one"
    b.label = "two"
    a.isActiveOnHigh = false
    #expect(a == b, "equality is coordinates only — getComponent(rect) depends on it")
    #expect(a.hashValue == b.hashValue)

    // Inclusive bounds on all four sides, so touching counts as overlapping.
    let left = FpgaBoardRectangle(x: 0, y: 0, width: 10, height: 10)
    let touching = FpgaBoardRectangle(x: 10, y: 0, width: 10, height: 10)
    let apart = FpgaBoardRectangle(x: 11, y: 0, width: 10, height: 10)
    #expect(left.overlaps(touching))
    #expect(!left.overlaps(apart))
    #expect(left.isPointInside(x: 10, y: 10))
    #expect(!left.isPointInside(x: 11, y: 10))
  }

  // MARK: - Java string semantics

  @Test("the picture code table splits with Java's rules")
  func codeTableSplitting() {
    // Java's split discards trailing empties but keeps interior ones. A code table with a
    // double space therefore has an empty symbol in the middle, and a 256-entry table with a
    // trailing space loses its last entry, which the decoder then rejects.
    #expect(BoardImageCodec.codeTable(from: "a b c") == ["a", "b", "c"])
    #expect(BoardImageCodec.codeTable(from: "a  c") == ["a", "", "c"])
    #expect(BoardImageCodec.codeTable(from: "a b ") == ["a", "b"])
    // No separator at all yields the whole input, even when empty.
    #expect(BoardImageCodec.codeTable(from: "") == [""])
  }

  // MARK: - The picture codec

  /// The pre-`@` encoding: three symbols per pixel, straight lookup indices as R, G and B.
  /// **No shipped board uses this path**, so the gate never runs it.
  @Test("the uncompressed picture encoding decodes to RGB triples")
  func uncompressedPictureDecodes() throws {
    // Identity code table: symbol i is `initialCodeTable[i]`, so the lookup index is i.
    let table = BoardImageCodec.initialCodeTable
    // One 2×1 image: (0, 1, 2) then (255, 254, 253).
    let stream =
      table[0] + table[1] + table[2] + table[255] + table[254] + table[253]
    let image = try BoardImageCodec.decode(
      stream: stream, codeTable: table, width: 2, height: 1)
    guard case let .rgb(bytes, width, height) = image else {
      Issue.record("expected the uncompressed form, got \(image)")
      return
    }
    #expect(width == 2 && height == 1)
    #expect(bytes == [0, 1, 2, 255, 254, 253])
  }

  @Test("the JPEG encoding subtracts 128, and the code table is frequency-ordered")
  func jpegPictureRoundTrips() throws {
    // A byte string whose frequencies are deliberately unequal, so the sort matters.
    let payload: [UInt8] = Array(repeating: 0x00, count: 5) + Array(repeating: 0xFF, count: 3)
      + [0x42, 0x42, 0x7F]
    let (tableText, stream) = BoardImageCodec.encodeJpeg(payload)
    #expect(stream.first == "@")

    let table = BoardImageCodec.codeTable(from: tableText)
    #expect(table.count == 256)
    // 0x00 is the commonest byte; `0x00 ^ 0x80` is slot 128, which must have the shortest code.
    #expect(table[128] == "a")
    // 0xFF is next: slot 127.
    #expect(table[127] == "b")

    let image = try BoardImageCodec.decode(
      stream: stream, codeTable: table, width: 7, height: 11)
    guard case let .jpeg(bytes, declaredWidth, declaredHeight) = image else {
      Issue.record("expected the JPEG form, got \(image)")
      return
    }
    #expect(bytes == payload)
    #expect(declaredWidth == 7 && declaredHeight == 11)
  }

  @Test("a malformed picture throws instead of trapping (D13)")
  func malformedPictureThrows() {
    let table = BoardImageCodec.initialCodeTable

    // A symbol not in the table. Upstream unboxes a null Integer here and NPEs.
    #expect(throws: BoardImageDecodeError.self) {
      _ = try BoardImageCodec.decode(stream: "@!", codeTable: table, width: 1, height: 1)
    }
    // A two-character symbol cut off by the end of the attribute. Upstream throws
    // StringIndexOutOfBounds.
    #expect(throws: BoardImageDecodeError.self) {
      _ = try BoardImageCodec.decode(stream: "@+", codeTable: table, width: 1, height: 1)
    }
    // A code table of the wrong length. Upstream returns null.
    #expect(throws: BoardImageDecodeError.self) {
      _ = try BoardImageCodec.decode(
        stream: "@a", codeTable: ["a", "b"], width: 1, height: 1)
    }
    // The uncompressed path running out of pixels.
    #expect(throws: BoardImageDecodeError.self) {
      _ = try BoardImageCodec.decode(
        stream: table[0] + table[1], codeTable: table, width: 4, height: 4)
    }
    // An empty stream: `charAt(0)` upstream.
    #expect(throws: BoardImageDecodeError.self) {
      _ = try BoardImageCodec.decode(stream: "", codeTable: table, width: 1, height: 1)
    }
  }

  @Test("the JPEG frame-size walk finds the dimensions without decoding")
  func jpegFrameSizeWalk() {
    // SOI, an APP0 segment to be skipped, then a baseline SOF0 declaring 3 × 5.
    let bytes: [UInt8] = [
      0xFF, 0xD8,
      0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00,  // APP0, length 4, two payload bytes
      0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x05, 0x00, 0x03, 0x01, 0x00, 0x00, 0x00,
    ]
    let image = BoardImage.jpeg(bytes: bytes, declaredWidth: 0, declaredHeight: 0)
    let size = image.jpegFrameSize
    #expect(size?.width == 3)
    #expect(size?.height == 5)
    #expect(BoardImageCodec.jpegFrameSize([0x00, 0x01]) == nil)
  }

  // MARK: - The reader

  /// A minimal, synthetic board: a 1×1 uncompressed picture and one LED. Small enough to read,
  /// and it exercises the paths the shipped boards do not.
  static func syntheticBoard(
    components: String = #"<LED OutputPinSet="P1" Rect_x_y_w_h="1,2,3,4"/>"#,
    pixelData: String? = nil,
    dimensions: String = #"<PictureDimension Height="1" Width="1"/>"#
  ) -> Data {
    let table = BoardImageCodec.initialCodeTable
    let pixels = pixelData ?? (table[10] + table[20] + table[30])
    let xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="no"?>
      <SYNTHETIC>
         <BoardInformation>
            <ClockInformation FPGApin="A1" Frequency="50000000" IOStandard="LVCMOS33" \
      PullBehavior="Float"/>
            <FPGAInformation Family="Fam" FlashName="" FlashPos="2" JTAGPos="1" Package="Pkg" \
      Part="Part" Speedgrade="-1" USBTMC="false" Vendor="ALTERA"/>
            <UnusedPins PullBehavior="Pull Up"/>
         </BoardInformation>
         <IOComponents>
      \(components)
         </IOComponents>
         <BoardPicture>
            \(dimensions)
            <CompressionCodeTable TableData="\(table.joined(separator: " "))"/>
            <PixelData PixelRGB="\(pixels)"/>
         </BoardPicture>
      </SYNTHETIC>
      """
    return Data(xml.utf8)
  }

  @Test("a synthetic board reads back field for field")
  func syntheticBoardReads() throws {
    let board = try BoardReader.read(data: Self.syntheticBoard())
    #expect(board.boardName == "SYNTHETIC")
    #expect(board.fpga.isFpgaInfoPresent)
    #expect(board.fpga.clockFrequency == 50_000_000)
    #expect(board.fpga.clockPinLocation == "A1")
    #expect(board.fpga.clockIoStandard == IoStandards.lvcmos33)
    #expect(board.fpga.clockPullBehavior == PullBehaviors.float)
    #expect(board.fpga.unusedPinsBehavior == PullBehaviors.pullUp)
    #expect(board.fpga.vendor == FpgaVendor.altera)
    #expect(board.fpga.jtagChainPosition == 1)
    #expect(board.fpga.flashChainPosition == 2)
    #expect(!board.fpga.isFlashDefined, #"FlashName="" is not a defined flash"#)

    #expect(board.numberOfDefinedComponents == 1)
    let led = try #require(board.allComponents.first)
    #expect(led.type == .Led)
    #expect(led.numberOfPins == 1)
    #expect(led.pinLocation(0) == "P1")
    #expect(led.outputPins == [0])
    #expect(led.inputPins == nil, "an absent set stays nil, it does not become empty")
    let rect = try #require(led.rectangle)
    #expect(rect.xPosition == 1 && rect.yPosition == 2)
    #expect(rect.width == 3 && rect.height == 4)

    // The picture: the V1 path, since the stream has no `@`.
    guard case let .rgb(bytes, width, height) = try #require(board.image) else {
      Issue.record("expected the uncompressed form")
      return
    }
    #expect(width == 1 && height == 1)
    #expect(bytes == [10, 20, 30])
  }

  @Test("malformed boards throw rather than trap (D13)")
  func malformedBoardsThrow() {
    // No <BoardPicture>.
    #expect(throws: BoardReadError.self) {
      _ = try BoardReader.read(data: Data("<SYNTHETIC/>".utf8))
    }
    // Not XML at all.
    #expect(throws: BoardReadError.self) {
      _ = try BoardReader.read(data: Data("not xml".utf8))
    }
    // Zero picture dimensions; upstream's "does not contain the picture dimensions".
    #expect(throws: BoardReadError.self) {
      _ = try BoardReader.read(
        data: Self.syntheticBoard(dimensions: #"<PictureDimension Height="0" Width="0"/>"#))
    }
    // A picture dimension that is not a number: upstream's unguarded Integer.parseInt.
    #expect(throws: BoardReadError.self) {
      _ = try BoardReader.read(
        data: Self.syntheticBoard(dimensions: #"<PictureDimension Height="x" Width="1"/>"#))
    }
    // Unknown symbols in the pixel data.
    #expect(throws: BoardReadError.self) {
      _ = try BoardReader.read(data: Self.syntheticBoard(pixelData: "!!!"))
    }
  }

  @Test("a component with a bad rectangle is dropped, not fatal")
  func badComponentsAreDropped() throws {
    // Rect with a negative width parses as unsigned and wraps to a huge value; the reader's
    // `x < 0` guard then rejects it. An element with no rectangle at all is likewise dropped.
    // Neither may take the board down with it.
    let board = try BoardReader.read(
      data: Self.syntheticBoard(
        components: """
          <LED OutputPinSet="P1" Rect_x_y_w_h="4294967295,0,1,1"/>
          <LED OutputPinSet="P2"/>
          <Bus OutputPinSet="P3" Rect_x_y_w_h="0,0,1,1"/>
          <LED OutputPinSet="P4" Rect_x_y_w_h="5,6,7,8"/>
          """))
    #expect(board.numberOfDefinedComponents == 1)
    #expect(board.allComponents.first?.pinLocation(0) == "P4")
  }

  @Test("the positional backward-compatibility partition still works")
  func backwardCompatiblePinPartition() throws {
    // No InputPinSet/OutputPinSet: an old board lists pins with NrOfPins + FPGAPin_<n>, and the
    // partition into in/out/io comes from the type's requirements. A SevenSegment is 0 in, 8
    // out, 0 io.
    var pins = #"NrOfPins="8""#
    for index in 0..<8 { pins += #" FPGAPin_\#(index)="P\#(index)""# }
    let board = try BoardReader.read(
      data: Self.syntheticBoard(
        components: #"<SevenSegment \#(pins) Rect_x_y_w_h="0,0,10,10"/>"#))
    let segment = try #require(board.allComponents.first)
    #expect(segment.type == .SevenSegment)
    #expect(segment.numberOfPins == 8)
    #expect(segment.inputPins == nil)
    #expect(segment.outputPins == Set(0..<8))
    #expect(segment.ioPins == nil)
    #expect(segment.pinLocation(7) == "P7")
  }

  @Test("a Pin is forced active-high, whatever the file says")
  func pinIsForcedActiveHigh() throws {
    let board = try BoardReader.read(
      data: Self.syntheticBoard(
        components: #"<Pin ActivityLevel="Active low" BiDirPinSet="P9" Rect_x_y_w_h="0,0,1,1"/>"#
      ))
    #expect(board.allComponents.first?.activityLevel == PinActivity.activeHigh)
  }

  @Test("an LedArray expands to rows x columns logical pins")
  func ledArrayExpands() throws {
    let board = try BoardReader.read(
      data: Self.syntheticBoard(
        components: """
          <LedArray LedArrayInfo="2,3,LedRowScanning" OutputPinSet="A,B,C,D,E" \
          Rect_x_y_w_h="0,0,20,20"/>
          """))
    let array = try #require(board.allComponents.first)
    #expect(array.type == .LedArray)
    #expect(array.numberOfRows == 2)
    #expect(array.numberOfColumns == 3)
    #expect(array.driving == LedArrayDriving.ledRowScanning)
    #expect(array.externalPinCount == 5, "the five driver pins the file listed")
    #expect(array.numberOfPins == 6, "2 rows x 3 columns of logical pins")
    #expect(array.outputPins == Set(0..<6))
  }

  /// The case that justifies `javaSplitBoardList` existing at all. `LogisimFile`'s
  /// `javaSplitOnLiteral("")` answers `[]`; Java's `"".split(",")` answers `[""]`, so the
  /// component gets **one** pin whose FPGA location is the empty string. Confirmed against the
  /// jar by `tools/hdlbridge/synthcheck.py`, which reports
  /// `npins=1 … out=[0] … locs=[]`: one entry, and that entry empty.
  @Test("an empty pin set is one nameless pin, not zero pins")
  func emptyPinSetIsOnePin() throws {
    let board = try BoardReader.read(
      data: Self.syntheticBoard(components: #"<LED OutputPinSet="" Rect_x_y_w_h="1,1,1,1"/>"#))
    let led = try #require(board.allComponents.first)
    #expect(led.numberOfPins == 1)
    #expect(led.outputPins == [0])
    #expect(led.pinLocation(0) == "")
  }

  /// Confirmed against the jar by `synthcheck.py`:
  /// `npins=24 ext=3 rot=-90 rows=3 cols=2 driving=1`.
  @Test("a scanning seven-segment expands to rows x 8 and keeps its rotation")
  func scanningSevenSegmentExpands() throws {
    let board = try BoardReader.read(
      data: Self.syntheticBoard(
        components: """
          <SevenSegmentScanning ScanningSevenSegInfo="3,2,SevenSegScanningActiveLow" \
          OutputPinSet="A,B,C" rotation="-90" Rect_x_y_w_h="0,0,20,20"/>
          """))
    let display = try #require(board.allComponents.first)
    #expect(display.type == .SevenSegmentScanning)
    #expect(display.numberOfRows == 3)
    #expect(display.numberOfColumns == 2)
    #expect(display.driving == SevenSegmentScanningDriving.sevenSegScanningActiveLow)
    #expect(display.mapRotation == IoComponentTypes.rotationCw90)
    #expect(display.externalPinCount == 3)
    #expect(display.numberOfPins == 24, "rows x 8, not rows x columns")
    #expect(display.outputPins == Set(0..<24))
    #expect(display.pinLocation(2) == "C")
    #expect(display.pinLocation(3) == "", "the expanded pins have no FPGA location")
  }

  // MARK: - The writer

  @Test("attributes serialise alphabetically, as Xerces does")
  func attributesSortAlphabetically() throws {
    let board = try BoardReader.read(data: Self.syntheticBoard())
    let tree = board.documentTree(picture: nil)
    let clock = try #require(tree.children.first?.children.first)
    #expect(clock.name == "ClockInformation")
    // Insertion order is Frequency, FPGApin, PullBehavior, IOStandard.
    #expect(clock.attributes.map(\.name) == ["Frequency", "FPGApin", "PullBehavior", "IOStandard"])
    // Serialised order is byte order, which puts FPGApin first: exactly what every shipped
    // board file contains.
    #expect(
      clock.sortedAttributes.map(\.name) == ["FPGApin", "Frequency", "IOStandard", "PullBehavior"]
    )

    let fpga = try #require(tree.children.first?.children.dropFirst().first)
    #expect(
      fpga.sortedAttributes.map(\.name) == [
        "Family", "FlashName", "FlashPos", "JTAGPos", "Package", "Part", "Speedgrade", "USBTMC",
        "Vendor",
      ])
  }

  @Test("a component's element carries only the non-default attributes")
  func componentElementOmitsDefaults() throws {
    let board = try BoardReader.read(
      data: Self.syntheticBoard(
        components: """
          <Button ActivityLevel="Active low" FPGAPinIOStandard="LVCMOS33" \
          FPGAPinPullBehavior="Pull Down" InputPinSet="C6" Label="sw" Rect_x_y_w_h="1,2,3,4"/>
          <Button InputPinSet="C7" Rect_x_y_w_h="5,6,7,8"/>
          """))
    let decorated = try #require(board.allComponents.first?.documentElement())
    #expect(decorated.name == "Button")
    let byName = Dictionary(uniqueKeysWithValues: decorated.attributes.map { ($0.name, $0.value) })
    #expect(byName["Rect_x_y_w_h"] == "1,2,3,4")
    #expect(byName["Label"] == "sw")
    #expect(byName["InputPinSet"] == "C6")
    #expect(byName["ActivityLevel"] == "Active low")
    #expect(byName["FPGAPinPullBehavior"] == "Pull Down")
    #expect(byName["FPGAPinIOStandard"] == "LVCMOS33")
    #expect(byName["FPGAPinDriveStrength"] == nil, "unknown drive strength is not written")

    // The plain button: no attribute is written for an unknown pull, standard or drive, and
    // none for an unknown activity level either.
    let plain = try #require(board.allComponents.dropFirst().first?.documentElement())
    #expect(plain.attributes.map(\.name) == ["Rect_x_y_w_h", "InputPinSet"])
  }

  @Test("an LedArray writes back its driver pins, not its expanded ones")
  func ledArrayWritesExternalPins() throws {
    let board = try BoardReader.read(
      data: Self.syntheticBoard(
        components: """
          <LedArray LedArrayInfo="2,3,LedRowScanning" OutputPinSet="A,B,C,D,E" \
          Rect_x_y_w_h="0,0,20,20"/>
          """))
    let element = try #require(board.allComponents.first?.documentElement())
    let byName = Dictionary(uniqueKeysWithValues: element.attributes.map { ($0.name, $0.value) })
    #expect(byName["OutputPinSet"] == "A,B,C,D,E")
    #expect(byName["LedArrayInfo"] == "2,3,LedRowScanning")
  }

  // MARK: - Partial map geometry

  @Test("getPartialMapInfo classifies pixels the way the mapping editor needs")
  func partialMapGeometry() {
    // Four DIP switch pins across an 8-pixel-wide region: two pixels each.
    let dip = IoComponentTypes.partialMapInfo(
      width: 8, height: 2, numberOfPins: 4, numberOfRows: 4, numberOfColumns: 4,
      mapRotation: IoComponentTypes.rotationZero, type: .DIPSwitch)
    #expect(dip.count == 8 && dip[0].count == 2)
    #expect(dip.map { $0[0] } == [0, 0, 1, 1, 2, 2, 3, 3])

    // An RGB LED splits its height into three.
    let rgb = IoComponentTypes.partialMapInfo(
      width: 1, height: 6, numberOfPins: 3, numberOfRows: 4, numberOfColumns: 4,
      mapRotation: IoComponentTypes.rotationZero, type: .RgbLed)
    #expect(rgb[0] == [0, 0, 1, 1, 2, 2])

    // A 2x3 LED array, unrotated: pin = row * columns + column.
    let array = IoComponentTypes.partialMapInfo(
      width: 3, height: 2, numberOfPins: 6, numberOfRows: 2, numberOfColumns: 3,
      mapRotation: IoComponentTypes.rotationZero, type: .LedArray)
    #expect(array.map { $0[0] } == [0, 1, 2])
    #expect(array.map { $0[1] } == [3, 4, 5])

    // A seven-segment digit: the stencil's top row is segment A, and the decimal point only
    // exists on the with-dot variant.
    let withDot = IoComponentTypes.partialMapInfo(
      width: 5, height: 7, numberOfPins: 8, numberOfRows: 4, numberOfColumns: 4,
      mapRotation: IoComponentTypes.rotationZero, type: .SevenSegment)
    #expect(withDot[1][0] == IoComponentTypes.SevenSegmentIndex.segmentA)
    #expect(withDot[4][6] == IoComponentTypes.SevenSegmentIndex.decimalPoint)
    let withoutDot = IoComponentTypes.partialMapInfo(
      width: 5, height: 7, numberOfPins: 7, numberOfRows: 4, numberOfColumns: 4,
      mapRotation: IoComponentTypes.rotationZero, type: .SevenSegmentNoDp)
    #expect(withoutDot[4][6] == -1)

    // Anything else is entirely background.
    let led = IoComponentTypes.partialMapInfo(
      width: 2, height: 2, numberOfPins: 1, numberOfRows: 4, numberOfColumns: 4,
      mapRotation: IoComponentTypes.rotationZero, type: .Led)
    #expect(led == [[-1, -1], [-1, -1]])

    // D13: a degenerate rectangle answers an empty map instead of trapping.
    #expect(
      IoComponentTypes.partialMapInfo(
        width: 0, height: 0, numberOfPins: 4, numberOfRows: 4, numberOfColumns: 4,
        mapRotation: 0, type: .DIPSwitch
      ).isEmpty)
  }

  // MARK: - Bubble counts

  @Test("ComponentMapInformationContainer falls back to the index as a label")
  func bubbleLabels() {
    let counted = ComponentMapInformationContainer(inputPorts: 2, outputPorts: 1, inOutPorts: 0)
    #expect(counted.numberOfInputBubbles == 2)
    #expect(counted.inputPortLabel(0) == "0", "no label list means the index, as a string")
    #expect(counted.outputPortLabel(9) == "9")

    let labelled = ComponentMapInformationContainer(
      inputPorts: 2, outputPorts: 0, inOutPorts: 0,
      inputLabels: ["A", "B"], outputLabels: nil, inOutLabels: nil)
    #expect(labelled.inputPortLabel(1) == "B")
    #expect(labelled.inputPortLabel(2) == "2", "past the end falls back too")
  }
}
