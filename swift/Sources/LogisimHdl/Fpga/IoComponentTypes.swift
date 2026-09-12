// IoComponentTypes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/data/IoComponentTypes.java` (600
// lines), reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.
//
// What an "IO component" is: one physical thing on an FPGA development board that a circuit can
// be mapped onto: an LED, a push button, a DIP switch bank, a seven-segment digit, an LED
// matrix, a GPIO header. The board XML names one of these per `<IOComponents>` child element,
// and the number of FPGA pins it consumes is fixed per type (or, for `DIPSwitch` and `PortIo`,
// read from the file).
//
// ── What is ported and what is not ──────────────────────────────────────────────────────────
//
// PORTED: the enum, the pin-count requirements, the six membership sets, the rotation
// constants, `hasRotationAttribute`, and `getPartialMapInfo`; the last of which is pure integer
// and float arithmetic that answers "which pin of this component does board pixel (w, h) belong
// to". It is geometry, not drawing, so it belongs on this side of D9.
//
// NOT PORTED, deliberately:
//   * `paintPartialMap(Graphics2D, …)` (205 lines); takes an AWT `Graphics2D`, a `Color` and an
//     alpha and calls `fillRect`. D9 forbids drawing in this module. It computes exactly the
//     same rectangles `getPartialMapInfo` classifies, so a renderer can be written against the
//     ported half without re-deriving anything.
//   * `getInputLabel` / `getOutputLabel` / `getIoLabel` / `getRotationString`: these reach into
//     `com.cburch.logisim.std.io.{DipSwitch, SevenSegment, RgbLed}` and `ReptarLocalBus` for
//     per-pin names, and into the `S` resource bundle for the localised fallback
//     `S.get("FpgaIoPins", id)`. `LogisimHdl` does not depend on `LogisimStd` and must not: the
//     component HDL generators will point `LogisimStd -> LogisimHdl`, and adding the reverse
//     edge makes a cycle. See `Fpga/FpgaNotPorted.swift`; this is the first of two places the
//     board model needs a name from `std.io`, and it is why `MapComponent` cannot land here.

/// `com.cburch.logisim.fpga.data.IoComponentTypes`.
///
/// Case names follow the Java constants exactly, because `getEnumFromString` matches on
/// `name()` (case-insensitively) and `BoardInformation.getComponentType` returns `toString()`
/// into a board file. `DIPSwitch` and `PortIo` are upstream's capitalisation, not a typo.
public enum IoComponentTypes: String, CaseIterable, Sendable {
  case Led
  case Button
  case Pin
  case SevenSegment
  case SevenSegmentNoDp
  case SevenSegmentScanning
  case DIPSwitch
  case RgbLed
  case LedArray
  case PortIo
  case LocalBus
  case Bus
  case Open
  case Constant
  case Unknown

  /// `IoComponentTypes.ROTATION_ZERO` and friends. Note `CW_90` is **negative** ninety.
  public static let rotationZero = 0
  public static let rotationCw90 = -90
  public static let rotationCcw90 = 90

  /// `EnumSet.range(Led, LocalBus)`: everything from `Led` through `LocalBus` inclusive.
  /// `Bus`, `Open`, `Constant` and `Unknown` are deliberately outside: `Bus` is a placeholder
  /// for a multi-bit pin, and `Open`/`Constant` exist only inside the map dialog.
  public static let knownComponentSet: [IoComponentTypes] = [
    .Led, .Button, .Pin, .SevenSegment, .SevenSegmentNoDp, .SevenSegmentScanning,
    .DIPSwitch, .RgbLed, .LedArray, .PortIo, .LocalBus,
  ]

  /// `SIMPLE_INPUT_SET`. Upstream declares it as the *same* range as `KNOWN_COMPONENT_SET`; the
  /// name is historical and misleading, and it is reproduced rather than corrected because the
  /// board editor's "which types can I place" list is that set.
  public static let simpleInputSet: [IoComponentTypes] = knownComponentSet

  public static let inputComponentSet: Set<IoComponentTypes> = [.Button, .Pin, .DIPSwitch]

  public static let outputComponentSet: Set<IoComponentTypes> = [
    .Led, .Pin, .RgbLed, .SevenSegment, .LedArray, .SevenSegmentNoDp, .SevenSegmentScanning,
  ]

  public static let inOutComponentSet: Set<IoComponentTypes> = [.Pin, .PortIo]

  /// `getEnumFromString(String)`: case-insensitive match over `KNOWN_COMPONENT_SET` only, so a
  /// board naming `<Bus …/>` or `<Open …/>` reads back as `Unknown` and is dropped.
  ///
  /// Real board files depend on the case-insensitivity: they spell the tags `<LED …/>` and
  /// `<PortIO …/>`, which do not match `Led`/`PortIo` exactly.
  public static func from(string: String) -> IoComponentTypes {
    for candidate in knownComponentSet
    where FpgaAttributeTable.equalsIgnoreCaseAscii(candidate.rawValue, string) {
      return candidate
    }
    return .Unknown
  }

  /// `getFpgaInOutRequirement(IoComponentTypes)`.
  public static func fpgaInOutRequirement(_ comp: IoComponentTypes) -> Int {
    switch comp {
    case .PortIo: 8
    case .LocalBus: 16
    case .Pin: 1
    default: 0
    }
  }

  /// `getFpgaInputRequirement(IoComponentTypes)`.
  public static func fpgaInputRequirement(_ comp: IoComponentTypes) -> Int {
    switch comp {
    case .Button: 1
    case .DIPSwitch: 8
    case .LocalBus: 13
    default: 0
    }
  }

  /// `getFpgaOutputRequirement(IoComponentTypes)`.
  public static func fpgaOutputRequirement(_ comp: IoComponentTypes) -> Int {
    switch comp {
    case .Led: 1
    case .SevenSegment: 8
    case .SevenSegmentNoDp: 7
    case .RgbLed: 3
    case .LocalBus: 2
    case .LedArray: 16
    case .SevenSegmentScanning: 9
    default: 0
    }
  }

  /// `getNrOfFPGAPins`; the three requirements summed. These are *defaults for the board
  /// editor*; the real counts come out of the XML and live in `FpgaIoInformationContainer`.
  public static func numberOfFpgaPins(_ comp: IoComponentTypes) -> Int {
    fpgaInOutRequirement(comp) + fpgaInputRequirement(comp) + fpgaOutputRequirement(comp)
  }

  public static func numberOfInputPinsConfigurable(_ comp: IoComponentTypes) -> Bool {
    comp == .DIPSwitch
  }

  /// Upstream returns a constant `false` and ignores its argument. Kept for shape.
  public static func numberOfOutputPinsConfigurable(_ comp: IoComponentTypes) -> Bool { false }

  public static func numberOfIoPinsConfigurable(_ comp: IoComponentTypes) -> Bool {
    comp == .PortIo
  }

  /// `hasRotationAttribute`, which types may carry `rotation="±90"` in the board XML.
  public static func hasRotationAttribute(_ comp: IoComponentTypes) -> Bool {
    switch comp {
    case .DIPSwitch, .SevenSegment, .LedArray, .SevenSegmentScanning: true
    default: false
    }
  }
}

// MARK: - Seven-segment geometry

extension IoComponentTypes {

  /// Segment indices, matching `com.cburch.logisim.std.io.SevenSegment`'s constants.
  ///
  /// **Transcribed rather than imported.** `getSevenSegmentDisplayArray` reads
  /// `SevenSegment.Segment_A … Segment_G` and `SevenSegment.DP` out of `LogisimStd`, which this
  /// module cannot depend on (see the header). The values below are those constants from
  /// `upstream-java-4.1.0/src/main/java/com/cburch/logisim/std/io/SevenSegment.java`, and
  /// `BoardModelTests.sevenSegmentIndicesMatchStdIo` pins them so the copy cannot rot silently.
  public enum SevenSegmentIndex {
    public static let segmentA = 0
    public static let segmentB = 1
    public static let segmentC = 2
    public static let segmentD = 3
    public static let segmentE = 4
    public static let segmentF = 5
    public static let segmentG = 6
    public static let decimalPoint = 7
  }

  /// `getSevenSegmentDisplayArray(boolean hasDp)`: a 7-row × 5-column stencil naming which
  /// segment covers each cell of a digit, `-1` for background.
  public static func sevenSegmentDisplayArray(hasDecimalPoint: Bool) -> [[Int]] {
    let a = SevenSegmentIndex.segmentA
    let b = SevenSegmentIndex.segmentB
    let c = SevenSegmentIndex.segmentC
    let d = SevenSegmentIndex.segmentD
    let e = SevenSegmentIndex.segmentE
    let f = SevenSegmentIndex.segmentF
    let g = SevenSegmentIndex.segmentG
    var indexes = [
      [-1, a, a, -1, -1],
      [f, -1, -1, b, -1],
      [f, -1, -1, b, -1],
      [-1, g, g, -1, -1],
      [e, -1, -1, c, -1],
      [e, -1, -1, c, -1],
      [-1, d, d, -1, -1],
    ]
    if hasDecimalPoint { indexes[6][4] = SevenSegmentIndex.decimalPoint }
    return indexes
  }

  /// `getPartialMapInfo(Integer[][] partialMap, …)`, returned rather than written through an
  /// out-parameter.
  ///
  /// `result[w][h]` is the pin index that board pixel `(w, h)` of this component belongs to, or
  /// `-1` for none. The arithmetic is `float` upstream: deliberately `Float` here too, because
  /// `(int)((float) h / part)` truncates a *single-precision* quotient and a `Double` would
  /// round differently at the segment boundaries this is precisely computing.
  ///
  /// D13: returns an empty array rather than trapping when `width`/`height` are non-positive.
  /// Upstream would produce a zero-size array; a negative count is unreachable from a board file
  /// because `FpgaIoInformationContainer` rejects `width < 1 || height < 1` at parse time.
  public static func partialMapInfo(
    width: Int,
    height: Int,
    numberOfPins: Int,
    numberOfRows: Int,
    numberOfColumns: Int,
    mapRotation: Int,
    type: IoComponentTypes
  ) -> [[Int]] {
    guard width > 0, height > 0 else { return [] }
    var map = [[Int]](repeating: [Int](repeating: -1, count: height), count: width)
    let w32 = Float(width)
    let h32 = Float(height)

    switch type {
    case .DIPSwitch:
      guard numberOfPins > 0 else { return map }
      let part: Float =
        (mapRotation == rotationCcw90 || mapRotation == rotationCw90)
        ? h32 / Float(numberOfPins) : w32 / Float(numberOfPins)
      guard part != 0 else { return map }
      for widthIndex in 0..<width {
        for heightIndex in 0..<height {
          // Upstream's ROTATION_CW_90 branch reads `(int) (height / part)`: the *whole*
          // height, not `heightIndex`. That is almost certainly a typo for `heightIndex`, but
          // it is what 4.1.0 computes and the port reproduces it; changing it would silently
          // move every CW-90 DIP switch mapping relative to the jar.
          let pinIndex: Int =
            switch mapRotation {
            case rotationCcw90: Int(Float(height - heightIndex - 1) / part)
            case rotationCw90: Int(h32 / part)
            default: Int(Float(widthIndex) / part)
            }
          map[widthIndex][heightIndex] = pinIndex
        }
      }

    case .RgbLed:
      let part = h32 / 3
      guard part != 0 else { return map }
      for w in 0..<width {
        for h in 0..<height { map[w][h] = Int(Float(h) / part) }
      }

    case .SevenSegment, .SevenSegmentNoDp:
      // Upstream falls through from `case SevenSegment: hasDp = true;` into
      // `case SevenSegmentNoDp:`, so the two share one body and differ only in the stencil.
      let indexes = sevenSegmentDisplayArray(hasDecimalPoint: type == .SevenSegment)
      let partX: Float
      let partY: Float
      if mapRotation == rotationCcw90 || mapRotation == rotationCw90 {
        partX = w32 / 7
        partY = h32 / 5
      } else {
        partX = w32 / 5
        partY = h32 / 7
      }
      guard partX != 0, partY != 0 else { return map }
      for w in 0..<width {
        for h in 0..<height {
          let xIndex: Int
          let yIndex: Int
          switch mapRotation {
          case rotationCcw90:
            xIndex = Int(Float(height - h - 1) / partY)
            yIndex = Int(Float(w) / partX)
          case rotationCw90:
            xIndex = Int(Float(h) / partY)
            yIndex = Int(Float(width - w - 1) / partX)
          default:
            xIndex = Int(Float(w) / partX)
            yIndex = Int(Float(h) / partY)
          }
          // Upstream indexes `indexes[yIndex][xIndex]` unguarded and would throw
          // ArrayIndexOutOfBounds on a degenerate rectangle; D13 says a board file must not be
          // able to trap us, so out-of-range cells become -1 (background).
          guard yIndex >= 0, yIndex < 7, xIndex >= 0, xIndex < 5 else { continue }
          map[w][h] = indexes[yIndex][xIndex]
        }
      }

    case .SevenSegmentScanning:
      guard numberOfRows > 0 else { return map }
      let segments = sevenSegmentDisplayArray(hasDecimalPoint: true)
      let partX: Float
      let partY: Float
      let segmentWidth: Float
      if mapRotation == rotationCcw90 || mapRotation == rotationCw90 {
        partX = w32 / 7
        partY = h32 / Float(5 * numberOfRows)
        segmentWidth = h32 / Float(numberOfRows)
      } else {
        partX = w32 / Float(5 * numberOfRows)
        partY = h32 / 7
        segmentWidth = w32 / Float(numberOfRows)
      }
      guard partX != 0, partY != 0, segmentWidth != 0 else { return map }
      for w in 0..<width {
        for h in 0..<height {
          var xIndex = 0
          var yIndex = 0
          var selectedSegment = 0
          switch mapRotation {
          case rotationCcw90:
            selectedSegment = numberOfRows - 1 - Int(Float(h) / segmentWidth)
            let offset = Float(h).truncatingRemainder(dividingBy: segmentWidth)
            xIndex = Int((segmentWidth - offset) / partY)
            if xIndex < 0 { xIndex = 0 }
            yIndex = Int(Float(w) / partX)
          case rotationCw90:
            selectedSegment = Int(Float(h) / segmentWidth)
            let offset = Float(h).truncatingRemainder(dividingBy: segmentWidth)
            xIndex = Int(offset / partY)
            yIndex = Int(Float(w) / partX)
          default:
            selectedSegment = Int(Float(w) / segmentWidth)
            let offset = Float(w).truncatingRemainder(dividingBy: segmentWidth)
            xIndex = Int(offset / partX)
            yIndex = Int(Float(h) / partY)
          }
          if xIndex > 4 { xIndex = 4 }
          if yIndex > 7 { yIndex = 7 }
          // Upstream clamps yIndex to 7 but the stencil has only 7 rows (0…6), so `yIndex == 7`
          // throws. Same D13 treatment as above: treat it as background.
          guard yIndex >= 0, yIndex < 7, xIndex >= 0, xIndex < 5 else { continue }
          let segment = segments[yIndex][xIndex]
          map[w][h] = segment < 0 ? -1 : segment + (8 * selectedSegment)
        }
      }

    case .LedArray:
      guard numberOfRows > 0, numberOfColumns > 0 else { return map }
      let partX: Float
      let partY: Float
      if mapRotation == rotationCcw90 || mapRotation == rotationCw90 {
        partX = w32 / Float(numberOfRows)
        partY = h32 / Float(numberOfColumns)
      } else {
        partX = w32 / Float(numberOfColumns)
        partY = h32 / Float(numberOfRows)
      }
      guard partX != 0, partY != 0 else { return map }
      for w in 0..<width {
        for h in 0..<height {
          let realRow: Int
          let realColumn: Int
          switch mapRotation {
          case rotationCcw90:
            realRow = Int(Float(w) / partX)
            realColumn = Int(Float(height - h - 1) / partY)
          case rotationCw90:
            realRow = Int(Float(width - w - 1) / partX)
            realColumn = Int(Float(h) / partY)
          default:
            realRow = Int(Float(h) / partY)
            realColumn = Int(Float(w) / partX)
          }
          map[w][h] = (realRow * numberOfColumns) + realColumn
        }
      }

    default:
      break  // already filled with -1
    }
    return map
  }
}
