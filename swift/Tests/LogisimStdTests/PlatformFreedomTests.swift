// PlatformFreedomTests.swift: part of logisim-evolved.
//
// D9 as a machine-checkable gate rather than a convention.
//
// `LogisimStd` must import nothing but `Foundation` and the port's own modules. That is what
// lets `logisim-cli` convert a `.circ` headless without linking a media or networking stack,
// and it is what keeps the differential harness honest; a harness that drags in an audio
// engine and a TCP listener is not measuring the same program the CLI ships.
//
// The rule was violated twice, in the same shape both times, by two different component slices:
// `Buzzer` imported `AVFoundation` to drive an `AVAudioEngine`, and `TelnetServer` imported
// `Network` to drive an `NWListener`. Both were defensible locally, the component really does
// make sound, the component really does open a socket, and both were wrong, because "this
// component needs a platform capability" is an argument for a seam, not for an import. Each was
// found by reading, months apart. This test is so the third one is found in CI instead.
//
// It is a source scan, deliberately, and not a check on the built binary: the failure it is
// guarding against is a single `import` line, and pointing at that line is far more useful than
// reporting that some framework ended up in the link map.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import Testing

/// Modules `LogisimStd` is allowed to import.
///
/// `Foundation` is the floor the whole port already stands on. The other four are the port's
/// own lower layers. Anything else, a platform framework, a package dependency, is a D9
/// violation and needs a seam instead, in the shape `Buzzer.audioSinkFactory` and
/// `TelnetServer.transportFactory` both now use.
///
/// **`LogisimDraw` was added 2026-09-06, and the addition was checked rather than assumed.**
/// `AppearanceShapePainter` is `CanvasObject.paint` for every `<appear>` shape kind; it has to
/// live in `LogisimStd` because `LogisimDraw` deliberately carries no paint method (that module
/// must never gain a renderer dependency; see the `LogisimFile -> LogisimDraw` note in
/// `Package.swift`). Admitting it here is only safe because it is itself platform-free:
///
///     $ grep -rh '^import ' swift/Sources/LogisimDraw/ | sort -u
///     import Foundation
///     import LogisimKernel
///
/// If `LogisimDraw` ever imports anything else, this entry must be revisited rather than kept;
/// it would launder that import straight into `LogisimStd` and past this gate.
private let allowedImports: Set<String> = [
  "Foundation",
  "LogisimKernel",
  "LogisimFile",
  "LogisimRender",
  "LogisimDraw",
]

@Suite("D9 — LogisimStd stays platform-free")
struct PlatformFreedomTests {

  /// `swift/Sources/LogisimStd`, located from this file rather than from the process's working
  /// directory, which `swift test` does not pin.
  static var moduleRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LogisimStdTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .appendingPathComponent("Sources/LogisimStd")
  }

  @Test("no source file imports a platform framework")
  func noPlatformImports() throws {
    let root = Self.moduleRoot
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: nil)
    var scanned = 0
    var offenders: [String] = []

    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let text = try String(contentsOf: url, encoding: .utf8)
      for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        // Only real import statements: a line starting with `import`. Prose in a comment that
        // merely names `AVFoundation`, and this module's headers name both offenders, on
        // purpose, to record why they are gone, must not trip the gate.
        guard line.hasPrefix("import ") else { continue }
        let module = line.dropFirst("import ".count)
          .split(separator: ".").first.map(String.init)?
          .trimmingCharacters(in: .whitespaces) ?? ""
        guard !module.isEmpty, !allowedImports.contains(module) else { continue }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        offenders.append("\(relative):\(index + 1): import \(module)")
      }
    }

    #expect(scanned > 200, "the scan found only \(scanned) files; the path is probably wrong")
    #expect(
      offenders.isEmpty,
      """
      LogisimStd must import only \(allowedImports.sorted().joined(separator: ", )")).
      Add a seam (see Buzzer.audioSinkFactory / TelnetServer.transportFactory), not an import:
      \(offenders.joined(separator: "\n"))
      """)
  }

  /// The allow-list above is only as strong as the modules on it, and `LogisimDraw` is the one
  /// entry whose platform-freedom is a *property* rather than a definition: `LogisimKernel`,
  /// `LogisimFile` and `LogisimRender` all carry their own D9 statements in `Package.swift`,
  /// while `LogisimDraw` was admitted here in 2026-09 purely because it happened to import
  /// nothing but `Foundation` and `LogisimKernel`.
  ///
  /// So the property is asserted rather than trusted. Without this, a later `import CoreGraphics`
  /// inside `LogisimDraw` would reach `LogisimStd` through a door this gate holds open, and the
  /// gate would report success; the exact laundering shape D9 exists to prevent.
  @Test("LogisimDraw, which LogisimStd is allowed to import, is itself platform-free")
  func drawModuleIsPlatformFree() throws {
    let root = Self.moduleRoot
      .deletingLastPathComponent()
      .appendingPathComponent("LogisimDraw")
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)

    /// `LogisimDraw` is geometry over the kernel and nothing else.
    let allowed: Set<String> = ["Foundation", "LogisimKernel"]
    var scanned = 0
    var offenders: [String] = []

    while let url = enumerator?.nextObject() as? URL {
      guard url.pathExtension == "swift" else { continue }
      scanned += 1
      let text = try String(contentsOf: url, encoding: .utf8)
      for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        guard line.hasPrefix("import ") else { continue }
        let module = line.dropFirst("import ".count)
          .split(separator: ".").first.map(String.init)?
          .trimmingCharacters(in: .whitespaces) ?? ""
        guard !module.isEmpty, !allowed.contains(module) else { continue }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        offenders.append("\(relative):\(index + 1): import \(module)")
      }
    }

    #expect(scanned > 20, "the scan found only \(scanned) files; the path is probably wrong")
    #expect(
      offenders.isEmpty,
      """
      LogisimDraw must import only Foundation and LogisimKernel, because LogisimStd is allowed
      to import it and would inherit anything it picks up:
      \(offenders.joined(separator: "\n"))
      """)
  }
}
