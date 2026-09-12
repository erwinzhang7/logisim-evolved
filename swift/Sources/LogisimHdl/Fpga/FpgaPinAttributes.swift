// FpgaPinAttributes.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// reference tree `upstream-java-4.1.0` (D16):
//
//   com/cburch/logisim/fpga/data/PinActivity.java                (45 lines)
//   com/cburch/logisim/fpga/data/PullBehaviors.java              (63 lines)
//   com/cburch/logisim/fpga/data/IoStandards.java                (66 lines)
//   com/cburch/logisim/fpga/data/DriveStrength.java              (70 lines)
//   com/cburch/logisim/fpga/data/LedArrayDriving.java            (73 lines)
//   com/cburch/logisim/fpga/data/SevenSegmentScanningDriving.java (60 lines)
//   com/cburch/logisim/fpga/settings/VendorSoftware.java         (vendor table only)
//
// GPL-3.0-only, like the rest of the port. See LICENSE.md.
//
// ══ Why these are `UInt8` and not Swift enums ═══════════════════════════════════════════════
//
// Upstream stores each of these as a Java `char` whose value is *an index into a parallel
// `String[]`*, with the sentinel `255` meaning "unknown". Three behaviours depend on the
// numeric encoding and would be lost by a `case`-based enum:
//
//   * `getId(String)` returns the position of the first exact match, so the array order IS the
//     wire format; the board XML stores `PullBehavior="Pull Down"` and everything downstream
//     works with the `2`.
//   * The `id > PULL_DOWN`, `id <= LVTTL`, `id != DEFAULT_STENGTH` guards are ordinal
//     comparisons against the sentinel, not membership tests.
//   * `FpgaIoInformationContainer` writes an attribute only when the value is neither the
//     sentinel nor the default, and a board file round-trips through those two comparisons.
//
// `UInt8` holds every value these ever take (0…6, or 255) and keeps the comparisons literal.
// Java's `char` is 16-bit, so a hypothetical id above 255 would differ; no code path can
// produce one, because every value originates either from a `getId` lookup over a ≤7-element
// table or from one of the named constants.

/// `com.cburch.logisim.fpga.data.PinActivity`.
public enum PinActivity {
  public static let activityAttributeString = "ActivityLevel"
  public static let activeLow: UInt8 = 0
  public static let activeHigh: UInt8 = 1
  /// Java spells this `Unknown`, lowercase-`u` unlike its siblings' `UNKNOWN`. Kept as `unknown`
  /// here; the *value* is what the file format sees.
  public static let unknown: UInt8 = 255

  public static let behaviorStrings = ["Active low", "Active high"]

  /// `PinActivity.getStrings()`: the first two `BEHAVIOR_STRINGS`, which is all of them.
  public static var strings: [String] { behaviorStrings }

  /// `PinActivity.getId(String)`: index of the first exact match, else `unknown`.
  public static func id(of identifier: String) -> UInt8 {
    FpgaAttributeTable.id(of: identifier, in: strings, unknown: unknown)
  }
}

/// `com.cburch.logisim.fpga.data.PullBehaviors`.
public enum PullBehaviors {
  public static let pullAttributeString = "FPGAPinPullBehavior"
  public static let float: UInt8 = 0
  public static let pullUp: UInt8 = 1
  public static let pullDown: UInt8 = 2
  public static let unknown: UInt8 = 255

  public static let behaviorStrings = ["Float", "Pull Up", "Pull Down"]

  public static var strings: [String] { behaviorStrings }

  public static func id(of identifier: String) -> UInt8 {
    FpgaAttributeTable.id(of: identifier, in: strings, unknown: unknown)
  }

  /// `getConstrainedPullString(char)`; what a vendor constraints file wants. Note this one has
  /// no `null` case: anything that is not up/down is the empty string.
  public static func constrainedPullString(_ id: UInt8) -> String {
    switch id {
    case pullUp: "PULLUP"
    case pullDown: "PULLDOWN"
    default: ""
    }
  }

  /// `getPullString(char)`. Returns `nil` for `FLOAT` and for anything above `PULL_DOWN`,
  /// including the `unknown` sentinel; upstream returns Java `null` there and callers test for
  /// it, so `String?` is the faithful shape.
  public static func pullString(_ id: UInt8) -> String? {
    if id == float || id > pullDown { return nil }
    switch id {
    case pullUp: return "UP"
    case pullDown: return "DOWN"
    default: return "NONE"
    }
  }
}

/// `com.cburch.logisim.fpga.data.IoStandards`.
public enum IoStandards {
  public static let ioAttributeString = "FPGAPinIOStandard"
  public static let defaultStandard: UInt8 = 0
  public static let lvcmos12: UInt8 = 1
  public static let lvcmos15: UInt8 = 2
  public static let lvcmos18: UInt8 = 3
  public static let lvcmos25: UInt8 = 4
  public static let lvcmos33: UInt8 = 5
  public static let lvttl: UInt8 = 6
  public static let unknown: UInt8 = 255

  public static let behaviorStrings = [
    "Default", "LVCMOS12", "LVCMOS15", "LVCMOS18", "LVCMOS25", "LVCMOS33", "LVTTL",
  ]

  public static var strings: [String] { behaviorStrings }

  public static func id(of identifier: String) -> UInt8 {
    FpgaAttributeTable.id(of: identifier, in: strings, unknown: unknown)
  }

  /// `getConstraintedIoStandard(char)`, upstream's spelling, typo included.
  public static func constrainedIoStandard(_ id: UInt8) -> String {
    (id > defaultStandard && id <= lvttl) ? behaviorStrings[Int(id)] : ""
  }

  /// `getIoString(char)`; `nil` for the default standard and for anything past `LVTTL`.
  public static func ioString(_ id: UInt8) -> String? {
    if id == defaultStandard || id > lvttl { return nil }
    return behaviorStrings[Int(id)]
  }
}

/// `com.cburch.logisim.fpga.data.DriveStrength`.
public enum DriveStrength {
  public static let driveAttributeString = "FPGAPinDriveStrength"
  /// Upstream spells the constant `DEFAULT_STENGTH`. The typo is load-bearing only in that a
  /// reader of the Java will look for it.
  public static let defaultStrength: UInt8 = 0
  public static let drive2: UInt8 = 1
  public static let drive4: UInt8 = 2
  public static let drive8: UInt8 = 3
  public static let drive16: UInt8 = 4
  public static let drive24: UInt8 = 5
  public static let unknown: UInt8 = 255

  public static let behaviorStrings = ["Default", "2 mA", "4 mA", "8 mA", "16 mA", "24 mA"]
  public static let simpleStrings = ["0", "2", "4", "8", "16", "24"]

  public static var strings: [String] { behaviorStrings }

  public static func id(of identifier: String) -> UInt8 {
    FpgaAttributeTable.id(of: identifier, in: strings, unknown: unknown)
  }

  /// `getConstrainedDriveStrength(char)`.
  ///
  /// The `" mA"` → `" "` substitution leaves a **trailing space** (`"2 mA"` becomes `"2 "`).
  /// That is upstream's behaviour and it reaches a vendor constraints file verbatim, so it is
  /// reproduced rather than tidied.
  public static func constrainedDriveStrength(_ id: UInt8) -> String {
    if id > defaultStrength && id <= drive24 {
      return behaviorStrings[Int(id)].replacingOccurrences(of: " mA", with: " ")
    }
    return ""
  }

  /// `getDriveString(char)`; `nil` for the default and past `DRIVE_24`.
  public static func driveString(_ id: UInt8) -> String? {
    if id == defaultStrength || id > drive24 { return nil }
    return simpleStrings[Int(id)]
  }
}

// ══ `LedArrayDriving`, collapsed; task #39 ═════════════════════════════════════════════════
//
// This one Java class was ported TWICE, by two agents on branches cut from the same commit:
// here as raw `UInt8` constants for the board reader, and in
// `Components/Io/LedArrayGenericHdlGeneratorFactory.swift` as a typed `CaseIterable` enum for the
// generators. Neither could see the other, and the duplicate surfaced only at link time as
// "invalid redeclaration": the FILES differ, it is the TYPE that collides, which is why the
// pre-merge basename check missed it. It was renamed apart to unblock the build, and each half
// was then proven by a *different* gate: 29 of 29 shipped boards here, 570 byte-exact LED-array
// cases there.
//
// ── Why one type can serve both, and what the trick is ──────────────────────────────────────
//
// The apparent obstacle is that the board file's vocabulary includes `UNKNOWN = 255` as a real
// stored value, while a Swift `switch` over the six driving modes must be exhaustive and has no
// case for it. **That is not a conflict, it is the answer**: `UNKNOWN` is not a driving mode, it
// is the *absence* of one. So the enum has exactly the six real modes and the sentinel lives in
// the raw-value namespace below, where the file format needs it; `Optional<LedArrayDrivingMode>`
// is the type that spans both, and `nil` and `255` are the same fact in two encodings.
//
// What is collapsed is the thing duplication actually endangers: **there is now one list of the
// six tokens and one statement of their order**, on the enum. The order is the wire format,
// `getId(String)` returns a position and the board XML stores the token, so two copies of it
// were two chances to disagree, silently, in a file both gates would still pass.
//
// `LedArrayDrivingMode` is declared here rather than beside the generators because
// `fpga.data.LedArrayDriving` is where upstream puts it, and because the board reader is the
// thing that must not be disturbed.

/// `com.cburch.logisim.fpga.data.LedArrayDriving`: the six driving modes, typed.
///
/// The raw values ARE Java's `char` constants and the board XML's stored indices, so a token
/// crosses between this and `LedArrayDriving` below unchanged.
public enum LedArrayDrivingMode: Int, CaseIterable, Sendable {
  case ledDefault = 0
  case ledRowScanning = 1
  case ledColumnScanning = 2
  case rgbDefault = 3
  case rgbRowScanning = 4
  case rgbColumnScanning = 5

  /// One entry of `LedArrayDriving.DRIVING_STRINGS`. **This is the single definition of the
  /// token vocabulary and its order**; everything else derives from it.
  ///
  /// Upstream these double as localisation keys (`S.get(DRIVING_STRINGS[i])` builds the *display*
  /// list). The raw strings are what the board XML stores, and that is the only use here; the
  /// display list is `getDisplayStrings()`, which is GUI and NOT PORTED.
  public var token: String {
    switch self {
    case .ledDefault: return "LedDefault"
    case .ledRowScanning: return "LedRowScanning"
    case .ledColumnScanning: return "LedColumnScanning"
    case .rgbDefault: return "RgbDefault"
    case .rgbRowScanning: return "RgbRowScanning"
    case .rgbColumnScanning: return "RgbColScanning"
    }
  }

  /// `LedArrayDriving.getId(String)`, in the typed vocabulary. Java answers `UNKNOWN` (255) for
  /// an unrecognised token; `nil` is the same fact, and `LedArrayDriving.id(of:)` re-encodes it
  /// as 255 for the file format.
  public static func from(token: String) -> LedArrayDrivingMode? {
    allCases.first { $0.token == token }
  }
}

/// `com.cburch.logisim.fpga.data.LedArrayDriving`'s **board-file vocabulary**: the same six
/// values as raw `UInt8`, plus the `UNKNOWN = 255` sentinel the XML can carry and the enum
/// deliberately cannot.
///
/// Every member here is derived from `LedArrayDrivingMode`. Nothing in this enum states a token,
/// an index, or an ordering of its own; that is the whole point of the collapse.
public enum LedArrayDriving {
  public static let ledArrayDriveString = "LedArrayDriveMode"

  public static let ledDefault = raw(.ledDefault)
  public static let ledRowScanning = raw(.ledRowScanning)
  public static let ledColumnScanning = raw(.ledColumnScanning)
  public static let rgbDefault = raw(.rgbDefault)
  public static let rgbRowScanning = raw(.rgbRowScanning)
  public static let rgbColumnScanning = raw(.rgbColumnScanning)

  /// `LedArrayDriving.UNKNOWN`. Not a mode: see the section header above.
  public static let unknown: UInt8 = 255

  /// `LedArrayDriving.DRIVING_STRINGS`, in `allCases` order, which is raw-value order.
  public static let drivingStrings = LedArrayDrivingMode.allCases.map(\.token)

  public static var strings: [String] { drivingStrings }

  /// The typed view of a stored id, or `nil` for `unknown` and anything else out of range.
  public static func mode(_ id: UInt8) -> LedArrayDrivingMode? {
    LedArrayDrivingMode(rawValue: Int(id))
  }

  /// `LedArrayDriving.getId(String)`.
  public static func id(of identifier: String) -> UInt8 {
    LedArrayDrivingMode.from(token: identifier).map(raw) ?? unknown
  }

  /// `getConstrainedDriveMode(char)`; note this one answers `"Unknown"`, a string, rather than
  /// `""` or `nil` like its neighbours.
  public static func constrainedDriveMode(_ id: UInt8) -> String {
    mode(id)?.token ?? "Unknown"
  }

  private static func raw(_ mode: LedArrayDrivingMode) -> UInt8 { UInt8(mode.rawValue) }
}

/// `com.cburch.logisim.fpga.data.SevenSegmentScanningDriving`.
public enum SevenSegmentScanningDriving {
  public static let sevenSegScanningMode = "SevenSegScanningMode"
  public static let sevenSegDecoded: UInt8 = 0
  public static let sevenSegScanningActiveLow: UInt8 = 1
  public static let sevenSegScanningActiveHigh: UInt8 = 2
  public static let unknown: UInt8 = 255

  public static let drivingStrings = [
    "SevenSegDecoded", "SevenSegScanningActiveLow", "SevenSegScanningActiveHi",
  ]

  public static var strings: [String] { drivingStrings }

  public static func id(of identifier: String) -> UInt8 {
    FpgaAttributeTable.id(of: identifier, in: strings, unknown: unknown)
  }

  public static func constrainedDriveMode(_ id: UInt8) -> String {
    (id >= sevenSegDecoded && id <= sevenSegScanningActiveHigh)
      ? drivingStrings[Int(id)] : "Unknown"
  }
}

/// `com.cburch.logisim.fpga.settings.VendorSoftware`, reduced to the vendor *table*.
///
/// The rest of that class resolves a vendor's toolchain binaries out of `AppPreferences`
/// (Quartus, ISE, Vivado, openFPGA paths) and is a D11 exclusion for the three proprietary
/// ones; see `Fpga/FpgaNotPorted.swift`. Only `getId`/`VENDORS` are needed to read a board.
public enum FpgaVendor {
  public static let altera: UInt8 = 0
  public static let xilinx: UInt8 = 1
  public static let vivado: UInt8 = 2
  public static let openFpga: UInt8 = 3
  public static let unknown: UInt8 = 255

  public static let vendors = ["Altera", "Xilinx", "Vivado", "openFPGA"]

  public static var strings: [String] { vendors }

  /// `FpgaClass.getId(String)`, which delegates to `VendorSoftware.getVendorStrings()` and
  /// compares with **`equalsIgnoreCase`**: unlike every other `getId` in this file, which uses
  /// `equals`. Board files in the wild rely on it: they store `Vendor="ALTERA"` and
  /// `Vendor="VIVADO"` in upper case.
  public static func id(of identifier: String) -> UInt8 {
    for (index, candidate) in strings.enumerated()
    where FpgaAttributeTable.equalsIgnoreCaseAscii(candidate, identifier) {
      return UInt8(index)
    }
    return unknown
  }
}

/// Shared implementation of the six near-identical `getId(String)` loops above.
enum FpgaAttributeTable {

  /// `for (String s : list) { if (s.equals(id)) return i; i++; } return UNKNOWN;`
  static func id(of identifier: String, in table: [String], unknown: UInt8) -> UInt8 {
    for (index, candidate) in table.enumerated() where candidate == identifier {
      return UInt8(index)
    }
    return unknown
  }

  /// Java's `String.equalsIgnoreCase`, restricted to what these tables contain.
  ///
  /// Java compares char by char after `toUpperCase` *and* `toLowerCase` on each pair, which for
  /// ASCII is exactly an ASCII-case-insensitive comparison. Swift's `caseInsensitiveCompare` is
  /// Unicode-aware and locale-independent but performs full case folding (so "ß" == "SS"), which
  /// is *not* what Java does. The vendor table is ASCII-only, but the identifier comes out of a
  /// board file and is arbitrary, so the ASCII rule is spelled out rather than approximated.
  static func equalsIgnoreCaseAscii(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.unicodeScalars)
    let right = Array(rhs.unicodeScalars)
    guard left.count == right.count else { return false }
    for index in left.indices {
      if left[index] == right[index] { continue }
      guard asciiFolded(left[index]) == asciiFolded(right[index]) else { return false }
    }
    return true
  }

  private static func asciiFolded(_ scalar: Unicode.Scalar) -> UInt32 {
    (scalar.value >= 0x41 && scalar.value <= 0x5A) ? scalar.value + 32 : scalar.value
  }
}
