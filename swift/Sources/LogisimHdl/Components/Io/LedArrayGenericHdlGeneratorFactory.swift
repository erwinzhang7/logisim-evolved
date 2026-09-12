// LedArrayGenericHdlGeneratorFactory: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/std/io/LedArrayGenericHdlGeneratorFactory.java`. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// licensed GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Not a component generator: no `ComponentFactory` names it, and nothing here should be
// registered in `HdlGeneratorLookup`. It is the *board-level* LED-array driver factory: an
// FPGA board XML declares a matrix of LEDs plus a drive mode, and the top-level generator
// instantiates one of the six drivers below to scan it. It lives in `std/io` upstream, which is
// why it lands in this task, but its consumer is the FPGA board model.
//
// ── HASH ITERATION ORDER IS LOAD-BEARING HERE ───────────────────────────────────────────────
//
// `getGenericPortMapAlligned` iterates a `java.util.HashMap`'s `keySet()` and writes one line
// per key, so the *order of the generic/port map lines in the generated VHDL is JVM HashMap
// order*, not insertion order and not sorted order. Measured from the jar for
// `LedArrayRowScanning.getGenericMap`:
//
//     inserted: nrOfLeds, nrOfRows, nrOfColumns, nrOfRowAddressBits,
//               nrOfScanningCounterBits, scanningCounterReloadValue,
//               maxNrLedsAddrColumns, activeLow
//     emitted: nrOfRowAddressBits, nrOfColumns, nrOfLeds, nrOfScanningCounterBits,
//               scanningCounterReloadValue, maxNrLedsAddrColumns, nrOfRows, activeLow
//
// `JavaHashSet.order` (already in this module, for `Netlist`'s net numbering) reproduces it
// exactly given `String.hashCode`, which is what `javaStringHashCode` below supplies. A Swift
// `Dictionary` would permute every generic and port map in every generated LED-array driver.
//
// ── NOT PORTED, deliberately ────────────────────────────────────────────────────────────────
//
//   * `getArrayConnections`, `getLedArrayConnections`, `getRGBArrayConnections` and their
//     `getColorMap` helper. All four take an `FpgaIoInformationContainer`: the FPGA *board and
//     pin-mapping* model (`com.cburch.logisim.fpga.data`, 22 files), which this port does not
//     carry and which another slice owns. They wire a board's physical pin map into the driver's
//     input vector and read `IoLibrary.ATTR_ON_COLOR`/`ATTR_OFF_COLOR` off mapped components;
//     nothing here can stand in for that. Reported as a requirement rather than invented.

import LogisimKernel
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// `String.hashCode()`: `s[0]*31^(n-1) + ... + s[n-1]` over UTF-16 code units, wrapping at 32
/// bits. Java's, not Swift's: `Hasher` is seed-randomised per process and its result would
/// reach a generated file.
func javaStringHashCode(_ text: String) -> Int {
  var hash: Int32 = 0
  for unit in text.utf16 {
    hash = hash &* 31 &+ Int32(unit)
  }
  return Int(hash)
}

// `LedArrayDrivingMode` used to be declared here, a second port of
// `com.cburch.logisim.fpga.data.LedArrayDriving` written in parallel with the board reader's.
// **The two are now one type**, declared in `Fpga/FpgaPinAttributes.swift` beside
// `LedArrayDriving`, which is where upstream puts it and where the board reader needs it. That
// file's header carries the whole account, including why `UNKNOWN = 255` living outside the enum
// is the resolution rather than the obstacle. Nothing here changed but the declaration site.

/// `com.cburch.logisim.std.io.LedArrayGenericHdlGeneratorFactory`.
public enum LedArrayGenericHdlGeneratorFactory {

  public static let ledArrayOutputs = "externalLeds"
  public static let ledArrayRedOutputs = "externalRedLeds"
  public static let ledArrayGreenOutputs = "externalGreenLeds"
  public static let ledArrayBlueOutputs = "externalBlueLeds"
  public static let ledArrayRowOutputs = "rowLeds"
  public static let ledArrayRowRedOutputs = "rowRedLeds"
  public static let ledArrayRowGreenOutputs = "rowGreenLeds"
  public static let ledArrayRowBlueOutputs = "rowBlueLeds"
  public static let ledArrayRowAddress = "rowAddress"
  public static let ledArrayColumnOutputs = "columnLeds"
  public static let ledArrayColumnRedOutputs = "columnRedLeds"
  public static let ledArrayColumnGreenOutputs = "columnGreenLeds"
  public static let ledArrayColumnBlueOutputs = "columnBlueLeds"
  public static let ledArrayColumnAddress = "columnAddress"
  public static let ledArrayInputs = "internalLeds"
  public static let ledArrayRedInputs = "internalRedLeds"
  public static let ledArrayGreenInputs = "internalGreenLeds"
  public static let ledArrayBlueInputs = "internalBlueLeds"

  /// `getSpecificHDLGenerator(String)`.
  public static func specificHdlGenerator(_ type: String) -> AbstractHdlGeneratorFactory? {
    guard let driving = LedArrayDrivingMode.from(token: type) else { return nil }
    return specificHdlGenerator(driving)
  }

  public static func specificHdlGenerator(_ driving: LedArrayDrivingMode)
    -> AbstractHdlGeneratorFactory
  {
    switch driving {
    case .ledDefault: return LedArrayLedDefaultHdlGeneratorFactory()
    case .ledRowScanning: return LedArrayRowScanningHdlGeneratorFactory()
    case .ledColumnScanning: return LedArrayColumnScanningHdlGeneratorFactory()
    case .rgbDefault: return RgbArrayLedDefaultHdlGeneratorFactory()
    case .rgbRowScanning: return RgbArrayRowScanningHdlGeneratorFactory()
    case .rgbColumnScanning: return RgbArrayColumnScanningHdlGeneratorFactory()
    }
  }

  /// `getSpecificHDLName(char)`.
  public static func specificHdlName(_ driving: LedArrayDrivingMode) -> String {
    switch driving {
    case .ledDefault: return LedArrayLedDefaultHdlGeneratorFactory.hdlIdentifier
    case .ledRowScanning: return LedArrayRowScanningHdlGeneratorFactory.hdlIdentifier
    case .ledColumnScanning: return LedArrayColumnScanningHdlGeneratorFactory.hdlIdentifier
    case .rgbDefault: return RgbArrayLedDefaultHdlGeneratorFactory.hdlIdentifier
    case .rgbRowScanning: return RgbArrayRowScanningHdlGeneratorFactory.hdlIdentifier
    case .rgbColumnScanning: return RgbArrayColumnScanningHdlGeneratorFactory.hdlIdentifier
    }
  }

  /// `getSpecificHDLName(String)`. `nil` where Java returns `null`.
  public static func specificHdlName(_ type: String) -> String? {
    guard let driving = LedArrayDrivingMode.from(token: type) else { return nil }
    return specificHdlName(driving)
  }

  /// `getNrOfBitsRequired(int)`: `(int) Math.ceil(Math.log(value) / Math.log(2.0))`.
  ///
  /// Transcribed with the floating-point route intact rather than replaced by an integer
  /// `bitWidth` computation, because the two do **not** agree: `log(8)/log(2)` is
  /// `2.9999999999999996` in IEEE-754 double, so `getNrOfBitsRequired(8)` is 3 where the exact
  /// answer is also 3, but `getNrOfBitsRequired(1)` is `ceil(0/0.693…) == 0` and
  /// `getNrOfBitsRequired(2)` is 1; an integer `ceil(log2)` implementation that special-cased
  /// 1 would still differ elsewhere. Pinned against the jar for 15 values in
  /// `tools/hdlbridge/io-4.1.0.oracle`.
  ///
  /// `Double` here is Java's `double`, not `float`, `Math.log` returns `double` and the
  /// division is in `double`, so this is one of the rare places the two languages agree
  /// bit-for-bit.
  public static func nrOfBitsRequired(_ value: Int) -> Int {
    let nrBitsDouble = log(Double(value)) / log(2.0)
    return Int(nrBitsDouble.rounded(.up))
  }

  /// `getExternalSignalName(char, int, int, int, int)`.
  public static func externalSignalName(
    _ driving: LedArrayDrivingMode, nrOfRows: Int, nrOfColumns: Int, identifier: Int, pinNr: Int
  ) -> String {
    let nrRowAddressBits = nrOfBitsRequired(nrOfRows)
    let nrColumnAddressBits = nrOfBitsRequired(nrOfColumns)
    switch driving {
    case .ledDefault:
      return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayOutputs, identifier, pinNr)
    case .ledRowScanning:
      return pinNr < nrRowAddressBits
        ? LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayRowAddress, identifier, pinNr)
        : LineBuffer.format(
          "{{1}}{{2}}[{{3}}]", ledArrayColumnOutputs, identifier, pinNr - nrRowAddressBits)
    case .ledColumnScanning:
      return pinNr < nrColumnAddressBits
        ? LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayColumnAddress, identifier, pinNr)
        : LineBuffer.format(
          "{{1}}{{2}}[{{3}}]", ledArrayRowOutputs, identifier, pinNr - nrColumnAddressBits)
    case .rgbDefault:
      let index = pinNr % 3
      let col = pinNr / 3
      switch col {
      case 0: return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayRedOutputs, identifier, index)
      case 1:
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayGreenOutputs, identifier, index)
      case 2: return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayBlueOutputs, identifier, index)
      default: return ""
      }
    case .rgbRowScanning:
      if pinNr < nrRowAddressBits {
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayRowAddress, identifier, pinNr)
      }
      let index = javaFloorModPositive(pinNr - nrRowAddressBits, nrOfColumns)
      let col = javaDividePositive(pinNr - nrRowAddressBits, nrOfColumns)
      switch col {
      case 0:
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayColumnRedOutputs, identifier, index)
      case 1:
        return LineBuffer.format(
          "{{1}}{{2}}[{{3}}]", ledArrayColumnGreenOutputs, identifier, index)
      case 2:
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayColumnBlueOutputs, identifier, index)
      default: return ""
      }
    case .rgbColumnScanning:
      if pinNr < nrColumnAddressBits {
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayColumnAddress, identifier, pinNr)
      }
      let index = javaFloorModPositive(pinNr - nrColumnAddressBits, nrOfRows)
      let col = javaDividePositive(pinNr - nrColumnAddressBits, nrOfRows)
      switch col {
      case 0:
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayRowRedOutputs, identifier, index)
      case 1:
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayRowGreenOutputs, identifier, index)
      case 2:
        return LineBuffer.format("{{1}}{{2}}[{{3}}]", ledArrayRowBlueOutputs, identifier, index)
      default: return ""
      }
    }
  }

  /// `requiresClock(char)`.
  public static func requiresClock(_ driving: LedArrayDrivingMode) -> Bool {
    driving != .ledDefault && driving != .rgbDefault
  }

  /// `getExternalSignals(char, int, int, int)`. Java returns a `TreeMap`, i.e. key-sorted; the
  /// port returns the pairs already in that order so callers need not know.
  public static func externalSignals(
    _ driving: LedArrayDrivingMode, nrOfRows: Int, nrOfColumns: Int, identifier: Int
  ) -> [(name: String, bits: Int)] {
    let nrRowAddressBits = nrOfBitsRequired(nrOfRows)
    let nrColumnAddressBits = nrOfBitsRequired(nrOfColumns)
    var externals: [String: Int] = [:]
    switch driving {
    case .ledDefault:
      externals["\(ledArrayOutputs)\(identifier)"] = nrOfRows * nrOfColumns
    case .ledRowScanning:
      externals["\(ledArrayRowAddress)\(identifier)"] = nrRowAddressBits
      externals["\(ledArrayColumnOutputs)\(identifier)"] = nrOfColumns
    case .ledColumnScanning:
      externals["\(ledArrayColumnAddress)\(identifier)"] = nrColumnAddressBits
      externals["\(ledArrayRowOutputs)\(identifier)"] = nrOfRows
    case .rgbDefault:
      externals["\(ledArrayRedOutputs)\(identifier)"] = nrOfRows * nrOfColumns
      externals["\(ledArrayGreenOutputs)\(identifier)"] = nrOfRows * nrOfColumns
      externals["\(ledArrayBlueOutputs)\(identifier)"] = nrOfRows * nrOfColumns
    case .rgbRowScanning:
      externals["\(ledArrayRowAddress)\(identifier)"] = nrRowAddressBits
      externals["\(ledArrayColumnRedOutputs)\(identifier)"] = nrOfColumns
      externals["\(ledArrayColumnGreenOutputs)\(identifier)"] = nrOfColumns
      externals["\(ledArrayColumnBlueOutputs)\(identifier)"] = nrOfColumns
    case .rgbColumnScanning:
      externals["\(ledArrayColumnAddress)\(identifier)"] = nrColumnAddressBits
      externals["\(ledArrayRowRedOutputs)\(identifier)"] = nrOfRows
      externals["\(ledArrayRowGreenOutputs)\(identifier)"] = nrOfRows
      externals["\(ledArrayRowBlueOutputs)\(identifier)"] = nrOfRows
    }
    return externals.keys.sorted().map { (name: $0, bits: externals[$0]!) }
  }

  /// `getInternalSignals(char, int, int, int)`, likewise a `TreeMap` upstream.
  public static func internalSignals(
    _ driving: LedArrayDrivingMode, nrOfRows: Int, nrOfColumns: Int, identifier: Int
  ) -> [(name: String, bits: Int)] {
    var wires: [String: Int] = [:]
    switch driving {
    case .ledDefault, .ledRowScanning, .ledColumnScanning:
      wires["s_\(ledArrayInputs)\(identifier)"] = nrOfRows * nrOfColumns
    case .rgbDefault, .rgbRowScanning, .rgbColumnScanning:
      wires["s_\(ledArrayRedInputs)\(identifier)"] = nrOfRows * nrOfColumns
      wires["s_\(ledArrayGreenInputs)\(identifier)"] = nrOfRows * nrOfColumns
      wires["s_\(ledArrayBlueInputs)\(identifier)"] = nrOfRows * nrOfColumns
    }
    return wires.keys.sorted().map { (name: $0, bits: wires[$0]!) }
  }

  /// `getComponentMap(char, int, int, int, long, boolean)`.
  public static func componentMap(
    _ driving: LedArrayDrivingMode, nrOfRows: Int, nrOfColumns: Int, identifier: Int,
    fpgaClockFrequency: Int64, isActiveLow: Bool
  ) -> [String] {
    let componentMap = LineBuffer.getBuffer()
    componentMap.add(
      Hdl.isVhdl()
        ? LineBuffer.format("array{{1}} : {{2}}", identifier, specificHdlName(driving))
        : specificHdlName(driving))
    switch driving {
    case .rgbDefault, .ledDefault:
      componentMap.add(
        LedArrayLedDefaultHdlGeneratorFactory.genericMap(
          nrOfRows: nrOfRows, nrOfColumns: nrOfColumns, fpgaClockFrequency: fpgaClockFrequency,
          activeLow: isActiveLow
        ).getWithIndent())
    case .rgbColumnScanning, .ledColumnScanning:
      componentMap.add(
        LedArrayColumnScanningHdlGeneratorFactory.genericMap(
          nrOfRows: nrOfRows, nrOfColumns: nrOfColumns, fpgaClockFrequency: fpgaClockFrequency,
          activeLow: isActiveLow
        ).getWithIndent())
    case .rgbRowScanning, .ledRowScanning:
      componentMap.add(
        LedArrayRowScanningHdlGeneratorFactory.genericMap(
          nrOfRows: nrOfRows, nrOfColumns: nrOfColumns, fpgaClockFrequency: fpgaClockFrequency,
          activeLow: isActiveLow
        ).getWithIndent())
    }
    if Hdl.isVerilog() { componentMap.add("   array{{1}}", identifier) }
    switch driving {
    case .ledDefault:
      componentMap.add(LedArrayLedDefaultHdlGeneratorFactory.portMap(identifier: identifier))
    case .rgbDefault:
      componentMap.add(RgbArrayLedDefaultHdlGeneratorFactory.portMap(identifier: identifier))
    case .ledRowScanning:
      componentMap.add(
        LedArrayRowScanningHdlGeneratorFactory.portMap(identifier: identifier).getWithIndent())
    case .rgbRowScanning:
      componentMap.add(
        RgbArrayRowScanningHdlGeneratorFactory.portMap(identifier: identifier).getWithIndent())
    case .ledColumnScanning:
      componentMap.add(
        LedArrayColumnScanningHdlGeneratorFactory.portMap(identifier: identifier).getWithIndent())
    case .rgbColumnScanning:
      componentMap.add(
        RgbArrayColumnScanningHdlGeneratorFactory.portMap(identifier: identifier).getWithIndent())
    }
    return componentMap.empty().get()
  }

  /// `getGenericPortMapAlligned(Map<String, String>, boolean)`.
  ///
  /// `generics` is supplied as (key, value) pairs **in Java's insertion order**; this function
  /// re-orders them the way `HashMap.keySet()` would, which is what upstream's output records.
  /// See this file's header.
  public static func genericPortMapAlligned(
    _ generics: [(key: String, value: String)], isGeneric: Bool
  ) -> LineBuffer {
    var preamble = Hdl.isVhdl() ? LineBuffer.formatVhdl("{{port}} {{map}} ( ") : "( "
    if isGeneric {
      preamble = Hdl.isVhdl() ? LineBuffer.formatVhdl("{{generic}} {{map}} ( ") : "#( "
    }
    let contents = LineBuffer.getHdlBuffer()
    let ordered = JavaHashSet.order(generics) { javaStringHashCode($0.key) }
    var maxNameLength = 0
    var nrOfGenerics = 0
    for entry in ordered {
      maxNameLength = max(maxNameLength, entry.key.count)
      nrOfGenerics += 1
    }
    var first = true
    for entry in ordered {
      nrOfGenerics -= 1
      let intro = first ? preamble : String(repeating: " ", count: preamble.count)
      let map =
        Hdl.isVhdl()
        ? LineBuffer.formatHdl(
          "{{1}}{{2}} => {{3}}", entry.key,
          String(repeating: " ", count: max(0, maxNameLength - entry.key.count)), entry.value)
        : LineBuffer.formatHdl(".{{1}}({{2}})", entry.key, entry.value)
      let end = nrOfGenerics == 0 ? (isGeneric ? " )" : " );") : ","
      contents.add(LineBuffer.format("{{1}}{{2}}{{3}}", intro, map, end))
      first = false
    }
    return contents
  }
}

/// `a % b` for `a >= 0`, `b > 0`. Java's `%` truncates toward zero and so does Swift's, so the
/// two agree for non-negative operands; named so the assumption is visible rather than assumed.
/// `b == 0` would throw `ArithmeticException` in Java and trap in Swift, so it is guarded and
/// answers `0`: reachable only from a board XML declaring a zero-column array.
func javaFloorModPositive(_ a: Int, _ b: Int) -> Int { b == 0 ? 0 : a % b }

/// `a / b` under the same conditions and for the same reason.
func javaDividePositive(_ a: Int, _ b: Int) -> Int { b == 0 ? 0 : a / b }
