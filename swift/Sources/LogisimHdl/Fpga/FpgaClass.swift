// FpgaClass.swift: part of logisim-evolved.
//
// Derived from logisim-evolution `com/cburch/logisim/fpga/data/FpgaClass.java` (184 lines),
// reference tree `upstream-java-4.1.0` (D16). GPL-3.0-only. See LICENSE.md.

import LogisimKernel

/// Thrown by `FpgaDevice.set(...)` when a board file's JTAG or flash chain position is not a
/// 32-bit integer.
///
/// D13: upstream calls `Integer.parseInt` unguarded here, so a board with `JTAGPos="x"` throws
/// `NumberFormatException`, which `BoardReaderClass.getBoardInformation()` swallows in its
/// blanket `catch (Exception e)` and turns into "this board did not load". A Swift trap would
/// end the process instead, so this throws and `BoardReader` catches it in the same place.
public struct FpgaChainPositionError: Error, CustomStringConvertible {
  public let field: String
  public let text: String
  public var description: String {
    "board FPGA section: \(field) is not an integer: \"\(text)\""
  }
}

/// `com.cburch.logisim.fpga.data.FpgaClass`; the FPGA device a board carries, plus its clock.
///
/// Renamed from `FpgaClass` because the `Class` suffix is a Java-ism that means nothing in
/// Swift (upstream has `BoardReaderClass` and `BoardWriterClass` in the same style). This is a
/// mutable reference type for the same reason upstream's is: `BoardInformation.fpga` is a public
/// field that the board editor writes through, and `clear()` resets it in place.
public final class FpgaDevice {

  public private(set) var clockFrequency: Int64 = 0
  public private(set) var clockPinLocation: String?
  public private(set) var clockPullBehavior: UInt8 = 0
  public private(set) var clockIoStandard: UInt8 = 0
  public private(set) var technology: String?
  public private(set) var part: String?
  /// Upstream names the field `Package`, capitalised, because `package` is not a Java keyword
  /// but the author wanted the noun. `packageName` here; `package` is a Swift keyword.
  public private(set) var packageName: String?
  public private(set) var speedGrade: String?
  public private(set) var vendor: UInt8 = 0
  public private(set) var unusedPinsBehavior: UInt8 = 0
  public private(set) var isFpgaInfoPresent = false
  public private(set) var isUsbTmcDownloadRequired = false
  public private(set) var jtagChainPosition = 1
  public private(set) var flashName: String?
  public private(set) var flashChainPosition = 2
  public private(set) var isFlashDefined = false

  public init() {}

  /// `clear()`. Identical to the constructor body upstream, and kept separate for the same
  /// reason: `BoardInformation.clear()` resets the device without replacing the object.
  public func clear() {
    clockFrequency = 0
    clockPinLocation = nil
    clockPullBehavior = 0
    clockIoStandard = 0
    technology = nil
    part = nil
    packageName = nil
    speedGrade = nil
    vendor = 0
    isFpgaInfoPresent = false
    unusedPinsBehavior = 0
    isUsbTmcDownloadRequired = false
    jtagChainPosition = 1
    flashName = nil
    flashChainPosition = 2
    isFlashDefined = false
  }

  /// `set(long, String, String, String, String, String, String, String, String, String, boolean,
  /// String, String, String)`: the one mutator, called only by `BoardReaderClass` and the board
  /// editor's dialog.
  ///
  /// Note the several string arguments that are *decoded* here rather than by the caller:
  /// `pull`, `standard` and `unused` go through `getId`, so an unrecognised spelling silently
  /// becomes the `unknown` sentinel (255) rather than failing the load. That is upstream's
  /// behaviour and several shipped boards depend on it: `IOStandard="Default"` maps to 0, but a
  /// vendor-specific standard would map to 255 and simply not be emitted into constraints.
  public func set(
    frequency: Int64,
    pin: String,
    pull: String,
    standard: String,
    technology tech: String,
    device: String,
    package box: String,
    speed: String,
    vendor vend: String,
    unused: String,
    usbTmc: Bool,
    jtagPosition: String,
    flashName: String?,
    flashPosition: String
  ) throws {
    guard let jtag = javaParseInt32(jtagPosition) else {
      throw FpgaChainPositionError(field: "JTAGPos", text: jtagPosition)
    }
    guard let flash = javaParseInt32(flashPosition) else {
      throw FpgaChainPositionError(field: "FlashPos", text: flashPosition)
    }
    clockFrequency = frequency
    clockPinLocation = pin
    clockPullBehavior = PullBehaviors.id(of: pull)
    clockIoStandard = IoStandards.id(of: standard)
    technology = tech
    part = device
    packageName = box
    speedGrade = speed
    vendor = FpgaVendor.id(of: vend)
    isFpgaInfoPresent = true
    unusedPinsBehavior = PullBehaviors.id(of: unused)
    isUsbTmcDownloadRequired = usbTmc
    jtagChainPosition = jtag
    self.flashName = flashName
    flashChainPosition = flash
    // `StringUtil.isNotEmpty(flashName) && (flashPos != 0)`. Note "not empty" is Java's
    // `s != null && !s.isEmpty()`, so a board writing FlashName="" is *not* flash-defined,
    // which is what ALCHITRY_AU_IO and most Xilinx boards do.
    isFlashDefined = !(flashName ?? "").isEmpty && flash != 0
  }
}
