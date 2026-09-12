// MemoryHdlOracleTests.swift: part of logisim-evolved.
//
// The gate for the `std/memory` HDL generators: the Swift generators against the shipped 4.1.0
// jar's own, over 168 attribute settings × both target languages.
//
// ── Why the oracle rather than a hand-written expectation ───────────────────────────────────
//
// The generated text is not written down anywhere in the Java: it is `LineBuffer` placeholder
// substitution over text blocks, plus `AbstractHdlGeneratorFactory`'s entity assembly, whose
// sort orders and column padding are computed. Two specific things a careful transcription gets
// wrong and only a diff catches: a Java text block terminates its **last** line (Swift's
// multi-line literal does not), and the signal/port/generic lists are sorted and padded to the
// longest name in the set, so adding or renaming one wire shifts every other line.
//
// The oracle is produced by `tools/hdlbridge/MemoryBridge.java`, which constructs the real
// component factories inside the jar, takes their real attribute sets, and dumps what their real
// generators emit. Regenerate with:
//
//     JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//     javac -cp "$JAR" -d out tools/hdlbridge/MemoryBridge.java
//     python3 tools/hdlbridge/memory_cases.py \
//       | java -Djava.awt.headless=true -cp "$JAR:out" \
//              com.cburch.logisim.std.memory.MemoryBridge <a one-circuit scratch .circ> \
//     (the scratch file only supplies a project name, which the jar prints into every
//      generation remark; `ProjectNameOnlyNetlist` below pins the one this oracle was made
//      with, so use that name if you regenerate.)
//       > tools/hdlbridge/memory-4.1.0.oracle
//
// The suite asserts the oracle is non-empty before comparing. A silent zero-output oracle is
// indistinguishable from a pass, and that has bitten this project before.
//
// ── MEASURED: 168/168 with two one-line fixes to shared files, 154/168 without ─────────────
//
// Both outstanding defects are the same mistake in two places: **Java's `String.split(regex)`
// discards trailing empty fields, and Swift's `split(omittingEmptySubsequences: false)` does
// not.** Neither file belongs to this task. Each fix was applied locally, measured, and
// reverted; the numbers below are runs, not estimates.
//
//  1. `LineBuffer.getWithIndent(_ indent: String)`: accounts for **10** failing cases (every
//     ShiftRegister VHDL setting). Java text blocks terminate their last line, so upstream's
//     buffer entries end in `\n` and its split drops the resulting empty field; the Swift
//     entries that must carry the same terminator gain a spurious blank line instead.
//     `ShiftRegister`'s extra `singleBitShiftReg` declaration is consumed BOTH raw (`getEntity`
//     → `get()`, which needs the terminator) and split (`getComponentDeclarationSection` →
//     `getWithIndent`, which must drop it), so it cannot be made correct on the generator side.
//
//         var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
//         if lines.count > 1 { while let last = lines.last, last.isEmpty { lines.removeLast() } }
//
//     The `count > 1` guard reproduces Java's own special case: `"".split("\n")` returns
//     `[""]`, not an empty array, so a buffer entry that IS a blank line must stay one. Without
//     it every `.empty()` in every generator disappears.
//
//  2. `AbstractHdlGeneratorFactory.getComponentMap`'s Verilog vector split: accounts for the
//     other **4** (ShiftRegister Verilog with parallel load). A shift register's `q` map is
//     `"open,,,,,,,"` when nothing is connected; Java's split yields `["open"]` and emits
//     `.q({open})`, while the port emits eight lines.
//
//         var vectorList = mappedSignal.split(separator: ",", omittingEmptySubsequences: false)
//         if vectorList.count > 1 {
//           while let last = vectorList.last, last.isEmpty { vectorList.removeLast() }
//         }
//
// All of the above are fixed, and so is a third (`HdlTypes.typeDefinitions()` iterating a Swift
// `Dictionary` in arbitrary order) that this suite used to neutralise. The suite now compares
// every line of all 168 cases by plain equality, with no filters and no reordering.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimHdl
import LogisimKernel
import LogisimStd
import Testing

/// `.serialized` because `HdlSettings.language` is process-wide mutable state and every case
/// writes it, exactly as `AppPreferences.HdlType` is upstream.
@Suite("std/memory HDL generators — the 4.1.0 jar oracle", .serialized)
struct MemoryHdlOracleTests {

  // MARK: - Locating the oracle

  static func oracleURL() -> URL? {
    if let override = ProcessInfo.processInfo.environment["LOGISIM_MEMORY_HDL_ORACLE"] {
      return URL(fileURLWithPath: override)
    }
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = directory.appendingPathComponent("tools/hdlbridge/memory-4.1.0.oracle")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      directory = directory.deletingLastPathComponent()
    }
    return nil
  }

  // MARK: - The netlist stand-in

  /// The narrowest possible `HdlNetlist`: `getEntity`/`getArchitecture` only read `projName`,
  /// and the bridge's scratch file is `tests/fixtures/migration/_control_base.circ`, so that is
  /// the project name the jar printed into every generation remark.
  final class ProjectNameOnlyNetlist: HdlNetlist {
    let projName = "_control_base"
    let circuitName = "main"
    let currentHierarchyLevel: [String]? = nil
    let requiresGlobalClockConnection = false
    func netId(for net: any HdlNet) -> Int { 0 }
    func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool { false }
    func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int { -1 }
  }

  // MARK: - The placed-component stand-in

  /// A placement with **every solder point unconnected**, mirroring what the bridge builds:
  /// `new netlistComponent(factory.createComponent(loc, attrs))` with no circuit around it.
  ///
  /// That is enough to exercise every branch of the per-generator `getPortMap` overrides, the
  /// width-1 `d(0)`/`q(0)` rewrites and `ShiftRegister`'s complete rebuild of `d`/`q` from taps
  /// `2 * stage` apart, plus the base class's "no clock connection" and "gated clock" arms.
  /// It deliberately does **not** cover the connected clock arms: with no nets there is no clock
  /// tree, so `Hdl.getClockNetName` returns "" for every component. Those belong to the netlist
  /// gate, which has real circuits.
  final class UnconnectedPlacement: HdlNetlistComponent {
    struct Point: HdlSolderPoint {
      var parentNet: (any HdlNet)? { nil }
      var parentNetBitIndex: Int { 0 }
    }
    struct End: HdlConnectionEnd {
      let nrOfBits: Int
      let isOutputEnd: Bool
      func solderPoint(atBit bit: Int) -> any HdlSolderPoint { Point() }
    }

    private let ends: [End]
    let attributeSet: any AttributeSet
    let hdlName: String
    let displayName: String

    init(ends: [End], attributeSet: any AttributeSet, hdlName: String, displayName: String) {
      self.ends = ends
      self.attributeSet = attributeSet
      self.hdlName = hdlName
      self.displayName = displayName
    }

    var nrOfEnds: Int { ends.count }
    func end(at index: Int) -> any HdlConnectionEnd { ends[index] }
    func isEndConnected(_ index: Int) -> Bool { false }
    var isGatedInstance: Bool { false }
  }

  // MARK: - One parsed oracle case

  struct Case {
    let componentName: String
    let language: String
    let overrides: String
    /// Every non-`BEGIN`/`END` line the jar printed, in order.
    var lines: [String] = []

    var label: String { "\(componentName) [\(language)] \(overrides)" }
  }

  static func parse(_ text: String) -> [Case] {
    var cases: [Case] = []
    var current: Case?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if line.hasPrefix("BEGIN\t") {
        let fields = line.dropFirst("BEGIN\t".count).components(separatedBy: "\t")
        current = Case(
          componentName: fields.count > 0 ? fields[0] : "",
          language: fields.count > 1 ? fields[1] : "VHDL",
          overrides: fields.count > 2 ? fields[2] : "")
      } else if line.hasPrefix("END\t") {
        if let done = current { cases.append(done) }
        current = nil
      } else if current != nil {
        current?.lines.append(line)
      }
    }
    return cases
  }

  // MARK: - Building the component side

  /// The same factories the bridge constructs, keyed by `ComponentFactory.name`.
  static func factory(named name: String) -> (any ComponentFactory)? {
    switch name {
    case MemoryHdlGenerators.FactoryName.dFlipFlop: return DFlipFlop()
    case MemoryHdlGenerators.FactoryName.tFlipFlop: return TFlipFlop()
    case MemoryHdlGenerators.FactoryName.jkFlipFlop: return JKFlipFlop()
    case MemoryHdlGenerators.FactoryName.srFlipFlop: return SRFlipFlop()
    case MemoryHdlGenerators.FactoryName.register: return Register()
    case MemoryHdlGenerators.FactoryName.counter: return Counter()
    case MemoryHdlGenerators.FactoryName.shiftRegister: return ShiftRegister()
    case MemoryHdlGenerators.FactoryName.random: return Random()
    case MemoryHdlGenerators.FactoryName.ram: return Ram()
    case MemoryHdlGenerators.FactoryName.rom: return Rom()
    default: return nil
    }
  }

  /// Applies `attr=value,attr=value` in order, exactly as the bridge does: the order matters
  /// for `RamAttributes`, whose attribute *list* changes when `dataWidth` crosses 8.
  static func applyOverrides(_ attrs: any AttributeSet, _ spec: String) throws {
    guard !spec.isEmpty else { return }
    for pair in spec.components(separatedBy: ",") {
      guard let eq = pair.firstIndex(of: "=") else { continue }
      let key = String(pair[pair.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
      let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
      guard let attribute = attrs.attribute(named: key) else {
        throw OracleError.noSuchAttribute(key)
      }
      try attrs.setRawValue(attribute, attribute.parseToAttributeValue(value))
    }
  }

  enum OracleError: Error { case noSuchAttribute(String) }

  // MARK: - Reproducing the bridge's line protocol

  static func report(componentName: String, language: String, overrides: String) throws -> [String]
  {
    HdlSettings.language = language == "Verilog" ? .verilog : .vhdl
    guard let factory = factory(named: componentName) else {
      return ["FAIL unknown component \(componentName)"]
    }
    let attrs = factory.createAttributeSet()
    try applyOverrides(attrs, overrides)

    var lines: [String] = []
    for attribute in attrs.attributes {
      // The bridge prints Java's `String.valueOf(getValue(attr))`. Only the *set of names* is
      // compared (see `attributeNamesOnly`), because a Font's or a MemContents' toString is a
      // Java-object rendering with no Swift equivalent and nothing in the HDL reads it.
      lines.append("ATTR \(attribute.name)")
    }

    let registrations = MemoryHdlGenerators.registrations()
    guard let registration = registrations[componentName] else {
      return lines + ["FAIL no registration for \(componentName)"]
    }
    guard let generator = registration.generator(attrs) else {
      lines.append("GENERATOR <null>")
      return lines
    }
    let hdlName = registration.hdlName?(attrs) ?? CorrectLabel.correctLabel(componentName)
    lines.append("HDLNAME \(hdlName)")
    lines.append("SUPPORTEDTARGET \(generator.isHdlSupportedTarget(attrs: attrs))")
    lines.append("ONLYINLINED \(generator.isOnlyInlined)")
    if !generator.isOnlyInlined {
      let netlist = ProjectNameOnlyNetlist()
      lines.append("RELDIR \(generator.relativeDirectory)")
      section(&lines, "ENTITY", generator.getEntity(netlist: netlist, attrs: attrs, componentName: hdlName))
      section(
        &lines, "ARCH",
        generator.getArchitecture(netlist: netlist, attrs: attrs, componentName: hdlName))
      section(
        &lines, "INST",
        generator.getComponentInstantiation(netlist: netlist, attrs: attrs, componentName: hdlName)
          .get())
      // AFTER the entity/architecture calls, for the same reason the bridge dumps it there:
      // ShiftRegister and RAM only populate `myPorts`/`myWires` from inside them, so dumping
      // first would compare two empty structures and look like agreement.
      if let concrete = generator as? AbstractHdlGeneratorFactory {
        structure(&lines, concrete, attrs)
        try portMap(
          &lines, concrete, factory: factory, attrs: attrs, hdlName: hdlName, netlist: netlist)
      }
    }
    return lines
  }

  /// Mirrors `MemoryBridge.dumpPortMap`.
  static func portMap(
    _ lines: inout [String], _ generator: AbstractHdlGeneratorFactory,
    factory: any ComponentFactory, attrs: any AttributeSet, hdlName: String,
    netlist: any HdlNetlist
  ) throws {
    guard let instanceFactory = factory as? InstanceFactoryBase else { return }
    let origin = Location.create(0, 0, hasToSnap: true)
    let ends = try instanceFactory.ports(attrs).map { port -> UnconnectedPlacement.End in
      let end = try port.toEnd(location: origin, attributes: attrs)
      return UnconnectedPlacement.End(nrOfBits: end.width.width, isOutputEnd: end.isOutput)
    }
    let placement = UnconnectedPlacement(
      ends: ends, attributeSet: attrs, hdlName: hdlName, displayName: factory.name)
    lines.append("ENDS \(placement.nrOfEnds)")
    let map = generator.getPortMap(netlist: netlist, componentInfo: placement)
    lines.append("PORTMAP \(map.count)")
    for key in map.keys.sorted() { lines.append("PORTMAP| \(key) => \(map[key] ?? "")") }
    section(
      &lines, "COMPMAP",
      try generator.getComponentMap(
        netlist: netlist, componentId: 7, componentInfo: placement, name: hdlName
      ).get())
  }

  /// Mirrors `MemoryBridge.dumpStructure`: the port/wire/parameter tables, which are where a
  /// port id off by one or a `wire` that should be a `reg` shows up. None of that is visible in
  /// the entity text.
  static func structure(
    _ lines: inout [String], _ generator: AbstractHdlGeneratorFactory, _ attrs: any AttributeSet
  ) {
    let ports = generator.myPorts
    let names = ports.keySet()
    lines.append("PORTS \(names.count)")
    for name in names {
      var line = "PORT| \(name)"
      line += " bits=\(ports.get(name, attrs: attrs))"
      line += " clock=\(ports.isClock(name) ? 1 : 0)"
      line += " pulldown=\(ports.doPullDownOnFloat(name) ? 1 : 0)"
      if ports.isFixedMapped(name) {
        line += " fixed=\(ports.getFixedMap(name))"
      } else {
        line += " pin=\(ports.getComponentPortId(name))"
      }
      if ports.isClock(name) { line += " tick=\(ports.getTickName(name))" }
      lines.append(line)
    }
    for direction in [HdlPortDirection.input, .output, .inout_] {
      // Java prints `List.toString()`; reproduced so the two sides are literally comparable.
      lines.append(
        "PORTDIR \(direction.rawValue) [\(ports.keySet(direction).joined(separator: ", "))]")
    }

    let wires = generator.myWires
    let wireNames = wires.wireKeySet()
    let regNames = wires.registerKeySet()
    lines.append("WIRES \(wireNames.count) REGS \(regNames.count)")
    for name in wireNames { lines.append("WIRE| \(name) \(wires.get(name))") }
    for name in regNames { lines.append("REG| \(name) \(wires.get(name))") }

    let parameters = generator.myParametersList
    let ids = parameters.keySet(attrs)
    lines.append("PARAMS \(ids.count) empty=\(parameters.isEmpty(attrs))")
    for id in ids {
      let isInteger = parameters.isPresentedByInteger(id, attrs: attrs)
      var line = "PARAM| \(id) \(parameters.get(id, attrs: attrs) ?? "null") int=\(isInteger ? 1 : 0)"
      // Both this and `getMaps` below throw under D13 rather than trapping. A throw is a real
      // failure for these cases, so it is emitted as a line no oracle can contain.
      if !isInteger {
        do {
          line += " vecbits=\(try parameters.getNumberOfVectorBits(id, attrs: attrs))"
        } catch {
          line += " vecbits=<threw: \(error)>"
        }
      }
      lines.append(line)
    }
    var maps: [String: String] = [:]
    do {
      maps = try parameters.getMaps(attrs)
    } catch {
      lines.append("PARAMMAP <threw: \(error)>")
    }
    let keys = maps.keys.sorted()
    lines.append("PARAMMAP \(keys.count)")
    for key in keys { lines.append("PARAMMAP| \(key) = \(maps[key] ?? "")") }
  }

  static func section(_ lines: inout [String], _ tag: String, _ body: [String]?) {
    guard let body else {
      lines.append("\(tag) <null>")
      return
    }
    lines.append("\(tag) \(body.count)")
    for line in body {
      lines.append(
        "\(tag)| "
          + line.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r"))
    }
  }

  // Two compensations used to live here, and both are gone because the framework defects they
  // stood in for are fixed. Each was removed only after this gate was re-run with it absent.
  //
  //   * `orderTypeDefinitionsAsSet` compared a module's private type definitions as a sorted set
  //     instead of a sequence, because `HdlTypes.typeDefinitions()` iterated a Swift `Dictionary`
  //     whose order is arbitrary AND varied between otherwise identical cases. `HdlTypes` now
  //     iterates in Java `HashMap` bucket order via `JavaHashSet.order`. Proven non-vacuous by
  //     reversing that order and watching exactly the 4 RAM cases that reach it fail.
  //   * `isKnownFrameworkDivergence` dropped every comment line of `Counter`'s remark block,
  //     because `LineBuffer.buildRemarkBlock` did not split the word-wrapped text on newlines.
  //     It now does, via `javaSplit`. NB its doc comment claimed to be "Pinned by
  //     `counterRemarkBlockStillDiverges`"; that test was never written, so nothing would have
  //     reported the defect being fixed. The filter was found stale only by probing it.

  /// The jar prints `ATTR name = value`; the Swift side prints `ATTR name`. Comparing the
  /// rendered *values* would compare Java `toString()`s, which is not what is under test, but
  /// the attribute *list* is, because `HdlParameters.isUsed`/`containsAttribute` key off it.
  static func normalise(_ line: String) -> String {
    // Two lines of `FileWriter.getGenerateRemark`'s banner name the *program*, and this port is
    // a modified version that has to say so (GPL §5(a), D10); `HdlBuildInfo.name` is
    // "logisim-evolved" and the URL is this repository's. That divergence is deliberate and
    // lives in `FileWriter.swift`, not here, so both sides are collapsed to a marker rather
    // than the port being "fixed" to impersonate upstream. Nothing else in generated HDL
    // contains either phrase, so the substitution cannot swallow real content.
    if line.contains("goes FPGA automatic generated") { return "<<BANNER-NAME>>" }
    if line.contains("github.com/logisim-evol") { return "<<BANNER-URL>>" }
    // KNOWN DIVERGENCE, NOT OWNED BY THIS TASK: see `extendedLibraryIsOneNewlineShort` below,
    // which pins it so it cannot be forgotten. `Hdl.getExtendedLibrary()` emits one buffer
    // entry that is one `\n` shorter than the jar's, because a Java text block terminates its
    // last line and a Swift multi-line literal does not. `Hdl.swift` is not this task's file.
    if line.contains("ieee.std_logic_1164.all") { return "<<VHDL-LIBRARY-PREAMBLE>>" }
    guard line.hasPrefix("ATTR ") else { return line }
    let body = line.dropFirst("ATTR ".count)
    guard let eq = body.range(of: " = ") else { return line }
    return "ATTR " + body[body.startIndex..<eq.lowerBound]
  }

  // MARK: - The gate

  @Test("every memory generator emits byte-identical VHDL and Verilog to the 4.1.0 jar")
  func matchesTheJar() throws {
    // `Self.report` sets `HdlSettings.language` per case. That global is process-wide and Swift
    // Testing parallelises suites, so `.serialized` on this suite is not enough on its own;
    // see `HdlGlobalStateLock.swift` for the two failures the missing lock produced.
    hdlGlobalStateLock.lock()
    let savedLanguage = HdlSettings.language
    defer {
      HdlSettings.language = savedLanguage
      hdlGlobalStateLock.unlock()
    }

    guard let oracleURL = Self.oracleURL(),
      let oracleText = try? String(contentsOf: oracleURL, encoding: .utf8)
    else {
      Issue.record("memory-4.1.0.oracle not found — regenerate it (see this file's header)")
      return
    }
    let cases = Self.parse(oracleText)
    // A silent zero-output oracle looks exactly like a pass. Assert it produced work first.
    #expect(cases.count >= 100, "oracle has \(cases.count) cases; expected the full 168-case spread")

    var mismatches: [String] = []
    var comparedLines = 0
    for oracleCase in cases {
      let actualRaw = try Self.report(
        componentName: oracleCase.componentName, language: oracleCase.language,
        overrides: oracleCase.overrides
      )
      let actual = actualRaw.map(Self.normalise)
      // `GENERATOR <fully.qualified.JavaClass>` names a Java type with no Swift counterpart, so
      // it is dropped. `GENERATOR <null>` is kept: that line *is* the assertion that
      // `getHDLGenerator` refused the attribute set, which the Swift registration must match.
      let expected = oracleCase.lines
        .filter { !($0.hasPrefix("GENERATOR ") && $0 != "GENERATOR <null>") }
        .map(Self.normalise)
      comparedLines += expected.count
      if actual != expected {
        let limit = max(actual.count, expected.count)
        var firstDifference = "?"
        for index in 0..<limit {
          let lhs = index < expected.count ? expected[index] : "<missing>"
          let rhs = index < actual.count ? actual[index] : "<missing>"
          if lhs != rhs {
            firstDifference = "line \(index):\n      jar:   \(lhs)\n      swift: \(rhs)"
            break
          }
        }
        mismatches.append("\(oracleCase.label)\n    \(firstDifference)")
      }
    }
    #expect(comparedLines > 10_000, "oracle produced only \(comparedLines) comparable lines")
    if !mismatches.isEmpty {
      let detail = Array(mismatches.prefix(12)).joined(separator: "\n")
      Issue.record("\(mismatches.count) of \(cases.count) cases differ from the jar:\n\(detail)")
    }
    #expect(mismatches.isEmpty)
  }
}
