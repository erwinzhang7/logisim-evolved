// GatesHdlOracleTests: part of logisim-evolved.
//
// The differential gate for the gates / wiring / plexers HDL generators: regenerate the same
// 922-case matrix the shipped 4.1.0 jar produced through `tools/hdlbridge/GatesBridge.java` and
// require the two texts to be identical. GPL-3.0-only. See LICENSE.md.
//
// Run the oracle side with `tools/hdlbridge/run_gates_oracle.sh`; it writes
// `tools/hdlbridge/gates-4.1.0.oracle`, which is committed because it is generated from the
// published jar (no corpus, nothing private) and regenerating it needs a machine with the app
// installed.
//
// Set `LOGISIM_GATES_HDL_DUMP=/path` to write the Swift side out for eyeballing a diff.

import Foundation
import LogisimHdl
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

struct GatesHdlOracleTests {

  // MARK: - The emitter, matching GatesBridge.java tag for tag

  final class Emitter {
    var lines: [String] = []
    var caseCount = 0
    var blockCount = 0

    func line(_ text: String) { lines.append(text) }

    func block(_ tag: String, _ content: [String]?) {
      blockCount += 1
      guard let content else {
        line("  \(tag) null")
        return
      }
      if content.isEmpty {
        line("  \(tag) .")
        return
      }
      line("  \(tag) \(content.count)")
      for element in content {
        let escaped = element
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\n", with: "\\n")
          .replacingOccurrences(of: "\r", with: "\\r")
        line("    |\(escaped)")
      }
    }

    func dumpAttrs(_ attrs: any AttributeSet) {
      var entries: [String] = []
      var anonymous = 0
      for attribute in attrs.attributes {
        // `Attributes.forNoSave()` is *not* anonymous upstream after all: it passes no name to
        // `Attribute`, whose `getName()` then returns the string it was constructed with: and
        // both sides land on `dummy`, so BitSelector's SELECT_ATTR and EXTENDED_ATTR both report
        // as `dummy=`. Checked against the jar rather than assumed.
        let name = attribute.name
        _ = anonymous
        if name == "labelfont" {
          entries.append("\(name)=<font>")
          continue
        }
        // Escaped for the same reason the block bodies are: PLA's table stringifies to multi-line
        // text, and an unescaped newline here makes one *record* span several *lines*. That is
        // not cosmetic; it is what made an earlier run report 30,452 differences while a direct
        // file diff of the very same two artefacts reported zero.
        let text = GatesHdlOracleTests.javaToString(attrs, attribute)
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\n", with: "\\n")
          .replacingOccurrences(of: "\r", with: "\\r")
        entries.append("\(name)=\(text)")
      }
      entries.sort()
      line("  ATTRS " + entries.joined(separator: ","))
    }

    func emit(_ entry: GatesOracle.Entry, _ descr: String, _ attrs: any AttributeSet,
              _ netlist: any HdlNetlist) {
      caseCount += 1
      line("CASE \(Hdl.isVhdl() ? "VHDL" : "VERILOG") \(entry.name) \(descr)")
      dumpAttrs(attrs)
      // `AbstractComponentFactory.getHDLGenerator`: the generator only exists when the target is
      // supported. This is the whole reason the registry's `generator` is a closure over attrs.
      guard entry.generator.isHdlSupportedTarget(attrs: attrs) else {
        line("  GENERATOR null")
        return
      }
      let generator = entry.generator
      line("  GENERATOR \(GatesHdlOracleTests.javaClassName(of: generator, entry: entry))")
      line("  ONLYINLINED \(generator.isOnlyInlined)")
      line("  SUPPORTEDTARGET \(generator.isHdlSupportedTarget(attrs: attrs))")
      let compName = entry.hdlName(attrs)
      line("  HDLNAME \(compName)")
      if generator.isOnlyInlined { return }
      line("  RELDIR \(generator.relativeDirectory)")
      block("ENTITY", generator.getEntity(netlist: netlist, attrs: attrs, componentName: compName))
      block(
        "ARCH",
        generator.getArchitecture(netlist: netlist, attrs: attrs, componentName: compName))
      block(
        "INST",
        generator.getComponentInstantiation(
          netlist: netlist, attrs: attrs, componentName: compName).get())
      // getComponentMap is deliberately not exercised; see the matching note in GatesBridge.java.
      // Java throws NullPointerException for it with a null componentInfo; the port *traps*
      // instead (`HdlParameters.swift:293`), which is a D13 violation in a file this task does
      // not own and is reported rather than worked around.
    }
  }

  /// The Java simple class name the bridge printed, which is a property of upstream's class
  /// layout rather than of behaviour; several of upstream's are private inner classes with
  /// names the port does not reproduce (`AndGate.AndGateHdlGeneratorFactory`). Mapped explicitly
  /// so the protocol lines up; a mismatch here would be pure noise in the diff.
  static func javaClassName(of generator: any HdlGeneratorFactory, entry: GatesOracle.Entry)
    -> String
  {
    switch entry.name {
    case "AND Gate": return "AndGateHdlGeneratorFactory"
    case "OR Gate": return "OrGateHdlGeneratorFactory"
    case "NAND Gate": return "NandGateHdlGeneratorFactory"
    case "NOR Gate": return "NorGateHdlGeneratorFactory"
    case "XOR Gate", "Odd Parity": return "XorGateHdlGeneratorFactory"
    case "XNOR Gate", "Even Parity": return "XNorGateHdlGeneratorFactory"
    case "Buffer", "NOT Gate": return "AbstractBufferHdlGenerator"
    case "Controlled Buffer", "Controlled Inverter": return "ControlledBufferHdlGenerator"
    case "Constant": return "ConstantHdlGeneratorFactory"
    case "Power": return "PowerHdlGeneratorFactory"
    case "Ground": return "AbstractConstantHdlGeneratorFactory"
    case "NoConnect": return "InlinedHdlGeneratorFactory"
    case "Bit Extender": return "BitExtenderHdlGeneratorFactory"
    case "Multiplexer": return "MultiplexerHdlGeneratorFactory"
    case "Demultiplexer": return "DemultiplexerHdlGeneratorFactory"
    case "Decoder": return "DecoderHdlGeneratorFactory"
    case "BitSelector": return "BitSelectorHdlGeneratorFactory"
    case "Priority Encoder": return "PriorityEncoderHdlGeneratorFactory"
    case "Clock": return "ClockHdlGeneratorFactory"
    case "PLA": return "PlaHdlGeneratorFactory"
    default: return "?"
    }
  }

  /// `String.valueOf(attrs.getValue(attr))` as the bridge printed it, per attribute type.
  static func javaToString(_ attrs: any AttributeSet, _ attribute: AnyAttribute) -> String {
    guard let raw = attrs.rawValue(attribute) else { return "null" }
    switch raw {
    case .boolean(let value): return value ? "true" : "false"
    case .integer(let value): return "\(value)"
    case .long(let value): return "\(value)"
    case .bitWidth(let value): return "\(value)"
    default: return attribute.standardString(for: raw) ?? "null"
    }
  }

  // MARK: - The case matrix, in the bridge's order

  static let gateNames = [
    "AND Gate", "OR Gate", "NAND Gate", "NOR Gate", "XOR Gate", "XNOR Gate",
    "Odd Parity", "Even Parity",
  ]
  static let inlineNames = [
    "Buffer", "NOT Gate", "Controlled Buffer", "Controlled Inverter",
    "Constant", "Power", "Ground", "NoConnect", "Bit Extender",
  ]
  static let plexerNames = [
    "Multiplexer", "Demultiplexer", "Decoder", "BitSelector", "Priority Encoder",
  ]

  static func generateSwiftSide() -> Emitter {
    let emitter = Emitter()
    let netlist = EmptyHdlNetlist()

    for language in [HdlLanguage.vhdl, HdlLanguage.verilog] {
      HdlSettings.language = language
      emitter.line("LANGUAGE \(language.rawValue)")

      for name in gateNames {
        guard let entry = GatesOracle.entry(named: name) else { continue }
        for width in [1, 4, 32] {
          for inputs in [2, 3, 5] {
            for negated in [Int64(0), 1, 0b10101, 0b11111] {
              for xor in [nil, "1", "odd"] as [String?] {
                let attrs = entry.factory().createAttributeSet()
                if !attrs.hdlOracleHas("xor") && xor != nil { continue }
                if attrs.hdlOracleHas("xor") && xor == nil { continue }
                attrs.hdlOracleSet("width", "\(width)")
                if attrs.hdlOracleHas("inputs") { attrs.hdlOracleSet("inputs", "\(inputs)") }
                if let xor { attrs.hdlOracleSet("xor", xor) }
                for index in 0..<inputs where ((negated >> Int64(index)) & 1) == 1 {
                  attrs.hdlOracleSetNegated(index)
                }
                emitter.emit(
                  entry,
                  "w=\(width),in=\(inputs),neg=\(negated),xor=\(xor ?? "null")", attrs, netlist)
              }
            }
          }
        }
        for outMode in ["01", "0Z", "Z1"] {
          let attrs = entry.factory().createAttributeSet()
          if !attrs.hdlOracleHas("out") { break }
          if attrs.hdlOracleHas("xor") { attrs.hdlOracleSet("xor", "1") }
          attrs.hdlOracleSet("out", outMode)
          emitter.emit(entry, "out=\(outMode)", attrs, netlist)
        }
      }

      for name in inlineNames {
        guard let entry = GatesOracle.entry(named: name) else { continue }
        for width in [1, 8] {
          let attrs = entry.factory().createAttributeSet()
          if attrs.hdlOracleHas("width") {
            attrs.hdlOracleSet("width", "\(width)")
          } else if width != 1 {
            continue
          }
          if attrs.hdlOracleHas("value") { attrs.hdlOracleSet("value", "0x2a") }
          emitter.emit(entry, "w=\(width)", attrs, netlist)
        }
      }

      for name in plexerNames {
        guard let entry = GatesOracle.entry(named: name) else { continue }
        for select in [1, 2, 3] {
          for width in [1, 4] {
            for enable in ["true", "false"] {
              let attrs = entry.factory().createAttributeSet()
              if attrs.hdlOracleHas("select") { attrs.hdlOracleSet("select", "\(select)") }
              if attrs.hdlOracleHas("width") { attrs.hdlOracleSet("width", "\(width)") }
              if attrs.hdlOracleHas("enable") {
                attrs.hdlOracleSet("enable", enable)
              } else if enable == "false" {
                continue
              }
              if attrs.hdlOracleHas("group") {
                for group in [1, 2, 4] {
                  let bs = entry.factory().createAttributeSet()
                  bs.hdlOracleSet("width", "\(width)")
                  bs.hdlOracleSet("group", "\(group)")
                  emitter.emit(entry, "w=\(width),group=\(group)", bs, netlist)
                }
                break
              }
              emitter.emit(
                entry, "sel=\(select),w=\(width),en=\(enable)", attrs, netlist)
            }
          }
        }
      }

      // Clock and PLA, matching GatesBridge.miscCases.
      if let clock = GatesOracle.entry(named: "Clock") {
        for high in [1, 3, 8] {
          for low in [1, 5] {
            for phase in [0, 2] {
              let attrs = clock.factory().createAttributeSet()
              attrs.hdlOracleSet("highDuration", "\(high)")
              attrs.hdlOracleSet("lowDuration", "\(low)")
              attrs.hdlOracleSet("phaseOffset", "\(phase)")
              emitter.emit(clock, "hi=\(high),lo=\(low),ph=\(phase)", attrs, netlist)
            }
          }
        }
      }
      if let pla = GatesOracle.entry(named: "PLA") {
        let tables = ["", "01 10\n", "0x1 10\n1x0 01\nxxx 00\n"]
        for (index, table) in tables.enumerated() {
          let attrs = pla.factory().createAttributeSet()
          attrs.hdlOracleSet("table", table)
          emitter.emit(pla, "table=\(index)", attrs, netlist)
        }
      }
    }
    HdlSettings.language = .vhdl
    emitter.line("TOTALS cases=\(emitter.caseCount) blocks=\(emitter.blockCount)")
    return emitter
  }

  // MARK: - The gate

  static var oraclePath: String {
    if let override = ProcessInfo.processInfo.environment["LOGISIM_GATES_ORACLE"] {
      return override
    }
    // swift/Tests/LogisimHdlTests/<this file> -> repo root -> tools/hdlbridge
    let here = URL(fileURLWithPath: #filePath)
    return here
      .deletingLastPathComponent()  // LogisimHdlTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // swift
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("tools/hdlbridge/gates-4.1.0.oracle")
      .path
  }

  @Test func swiftGeneratorsMatchTheShipped410Jar() throws {
    // `generateSwiftSide()` drives `HdlSettings.language`, which is process-wide. Swift Testing
    // parallelises *suites*, so `.serialized` on this suite does not stop the io/arith/memory
    // suites from flipping the same global mid-generation. See `HdlGlobalStateLock.swift`.
    let emitter = withHdlGlobals { Self.generateSwiftSide() }

    if let dump = ProcessInfo.processInfo.environment["LOGISIM_GATES_HDL_DUMP"] {
      try? (emitter.lines.joined(separator: "\n") + "\n")
        .write(toFile: dump, atomically: true, encoding: .utf8)
    }

    // A gate that silently evaluates nothing is the failure this project has already paid for.
    // Assert the Swift side produced a real matrix before comparing anything.
    #expect(emitter.caseCount >= 900, "Swift side produced only \(emitter.caseCount) cases")

    let path = Self.oraclePath
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      Issue.record(
        "gates oracle missing at \(path) — regenerate with tools/hdlbridge/run_gates_oracle.sh")
      return
    }
    var expected = text.components(separatedBy: "\n")
    if expected.last == "" { expected.removeLast() }

    let actual = emitter.lines
    #expect(!expected.isEmpty, "gates oracle at \(path) is empty")

    var mismatches: [String] = []
    var differing = 0
    var known = 0
    let shared = min(expected.count, actual.count)
    for index in 0..<shared where expected[index] != actual[index] {
      if Self.isKnownFrameworkDivergence(java: expected[index], swift: actual[index]) {
        known += 1
        continue
      }
      differing += 1
      if mismatches.count < 40 {
        mismatches.append(
          "line \(index + 1):\n  java : \(expected[index])\n  swift: \(actual[index])")
      }
    }

    #expect(
      expected.count == actual.count,
      "line count differs — java \(expected.count), swift \(actual.count)")
    let report =
      "\(differing) unexplained differences of \(shared) lines "
      + "(\(known) known framework divergences excluded).\n"
      + mismatches.joined(separator: "\n")
    #expect(differing == 0, "\(report)")
  }

  /// The two places the port deliberately or knowably differs from the jar in text this task does
  /// not own. Both are *narrow* string tests, not a wildcard: anything else still fails.
  ///
  ///  1. **Product name and URL in the generated file header.** `FileWriter.getGenerateRemark`
  ///     prints `BuildInfo.name` and `BuildInfo.url`; the port is a separately-named derivative
  ///     (D10 requires a distinct app name), so `logisim-evolved` there is correct, not a bug.
  ///
  ///  2. **`Hdl.getExtendedLibrary()` is missing one trailing newline.** Java's text block ends
  ///     `numeric_std.all;\n\n`; the Swift multi-line literal in `Hdl.swift` produces a single
  ///     `\n`, because a Swift literal has no terminator after its last line where a Java text
  ///     block does. This is a real one-character defect in a file this task does not own, and is
  ///     written up as a change request rather than patched here.
  static func isKnownFrameworkDivergence(java: String, swift: String) -> Bool {
    if java.contains("goes FPGA automatic generated") && swift.contains("goes FPGA automatic generated") {
      return true
    }
    if java.contains("https://github.com/logisim-evolution/")
      && swift.contains("https://github.com/logisim-evolution/")
    {
      return true
    }
    if java.hasSuffix("USE ieee.numeric_std.all;\\n\\n") && swift.hasSuffix("USE ieee.numeric_std.all;\\n") {
      return true
    }
    return false
  }
}
