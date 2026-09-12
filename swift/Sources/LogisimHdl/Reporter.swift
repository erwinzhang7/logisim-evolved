// Reporter: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/gui/Reporter.java`. Copyright by the Logisim-evolution developers.
// This translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// Upstream's `Reporter` is a singleton that either forwards to a Swing `FpgaReportTabbedPane`
// (`myCommander`) or, when none is attached, falls back to an slf4j logger. The GUI half is out
// of scope here (UI is out of scope for this task, and `FpgaReportTabbedPane`/
// `SimpleDrcContainer` belong to a module this task does not own); the fallback-logging half is
// exactly what a headless HDL-generation run needs, matching the project's existing D17
// headless-by-default philosophy (`Main.headless`/`OptionPane`).
//
// `HdlReportSink` is the seam a future GUI module plugs into, playing the role `myCommander`
// does upstream: attach one with `Reporter.shared.sink = ...` and every message routes there
// instead of the console.

/// The GUI attachment point `Reporter` forwards to when present; upstream's
/// `FpgaReportTabbedPane`. Left unset, `Reporter` logs to the console instead.
public protocol HdlReportSink: AnyObject {
  func addErrorIncrement(_ message: String)
  func addError(_ message: String)
  func addFatalError(_ message: String)
  func addSevereError(_ message: String)
  func addInfo(_ message: String)
  func addSevereWarning(_ message: String)
  func addWarningIncrement(_ message: String)
  func addWarning(_ message: String)
  func clearConsole()
  func print(_ message: String)
}

/// `com.cburch.logisim.fpga.gui.Reporter`.
public final class Reporter {
  /// `Reporter.report`.
  public static let shared = Reporter()

  /// `Reporter.myCommander`, renamed for clarity now that it is a protocol, not a concrete
  /// Swing widget.
  public var sink: (any HdlReportSink)?

  private init() {}

  public func addErrorIncrement(_ message: String) {
    if let sink { sink.addErrorIncrement(message) } else { Self.log("ERROR", message) }
  }

  public func addError(_ message: String) {
    if let sink { sink.addError(message) } else { Self.log("ERROR", message) }
  }

  public func addFatalErrorFmt(_ fmt: String, _ args: CustomStringConvertible...) {
    addFatalError(Self.printfLite(fmt, args))
  }

  public func addFatalError(_ message: String) {
    if let sink { sink.addFatalError(message) } else { Self.log("ERROR", message) }
  }

  public func addSevereError(_ message: String) {
    if let sink { sink.addSevereError(message) } else { Self.log("ERROR", message) }
  }

  public func addInfo(_ message: String) {
    if let sink { sink.addInfo(message) } else { Self.log("INFO", message) }
  }

  public func addSevereWarning(_ message: String) {
    if let sink { sink.addSevereWarning(message) } else { Self.log("WARN", message) }
  }

  public func addWarningIncrement(_ message: String) {
    if let sink { sink.addWarningIncrement(message) } else { Self.log("WARN", message) }
  }

  public func addWarning(_ message: String) {
    if let sink { sink.addWarning(message) } else { Self.log("WARN", message) }
  }

  public func clearConsole() {
    sink?.clearConsole()
  }

  public func print(_ message: String) {
    if let sink { sink.print(message) } else { Self.log("INFO", message) }
  }

  private static func log(_ level: String, _ message: String) {
    Swift.print("[\(level)] \(message)")
  }

  /// A minimal stand-in for `String.format`'s `%s`/`%d` (the only conversions the ported call
  /// sites use), kept dependency-free rather than pulling in Foundation for one method.
  fileprivate static func printfLite(_ fmt: String, _ args: [CustomStringConvertible]) -> String {
    var result = ""
    var argIndex = 0
    var characters = Substring(fmt)
    while let percent = characters.firstIndex(of: "%") {
      result += characters[characters.startIndex..<percent]
      let afterPercent = characters.index(after: percent)
      guard afterPercent < characters.endIndex else {
        result += "%"
        characters = characters[afterPercent...]
        break
      }
      let conversion = characters[afterPercent]
      let afterConversion = characters.index(after: afterPercent)
      if (conversion == "s" || conversion == "d"), argIndex < args.count {
        result += args[argIndex].description
        argIndex += 1
      } else {
        result += "%\(conversion)"
      }
      characters = characters[afterConversion...]
    }
    result += characters
    return result
  }
}
