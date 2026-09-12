// ArithHdlGeneratorTests: part of logisim-evolved.
//
// The differential gate for `Sources/LogisimHdl/Components/Arith`. Copyright by the
// Logisim-evolution developers where it derives from logisim-evolution
// (https://github.com/logisim-evolution/logisim-evolution). GPL-3.0-only. See LICENSE.md.
//
// This does not test the Swift generators against a hand-written expectation. It regenerates,
// line for line, the transcript `tools/hdlbridge/ArithBridge.java` produces by driving the real
// 4.1.0 `Adder/Subtractor/Multiplier/Divider/Negator/Comparator/Shifter HdlGeneratorFactory`
// objects inside the shipped jar, and asserts byte equality. HDL text is exactly diffable, so a
// weaker check would be a choice not to look.
//
// 308 cases: 11 widths (1, 2, 3, 4, 8, 16, 31, 32, 33, 63, 64) x every mode, x VHDL and Verilog.
// The wide widths are not decoration; D15 records that arithmetic above a machine word is real
// in this corpus, and 63/64 are exactly where a generator that assumed one would emit wrong
// text rather than crash.
//
// The transcript is checked in because the jar is not a build dependency; regenerate with
//
//     javac -cp <jar> -d out tools/hdlbridge/ArithBridge.java
//     java -Djava.awt.headless=true -cp <jar>:out \
//          com.cburch.logisim.fpga.hdlgenerator.ArithBridge > tools/hdlbridge/arith-4.1.0.oracle
//
// The transcript was generated with `AppPreferences.VhdlKeywordsUpperCase` at its default
// (true), which is also `HdlSettings.vhdlKeywordsUppercase`'s default; the suite pins both ends
// so a changed preference cannot quietly re-baseline the gate.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimStd
import Testing

@testable import LogisimHdl

/// `.serialized` because `HdlSettings` is process-wide mutable state, exactly as upstream's
/// `AppPreferences.HdlType` is.
@Suite("std/arith HDL generators — the 4.1.0 jar oracle", .serialized)
struct ArithHdlGeneratorTests {

  // MARK: - Locating the oracle

  /// Walks up from this source file to `tools/hdlbridge/arith-4.1.0.oracle`.
  static func oracleURL() -> URL? {
    if let override = ProcessInfo.processInfo.environment["LOGISIM_ARITH_HDL_ORACLE"] {
      return URL(fileURLWithPath: override)
    }
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = directory.appendingPathComponent("tools/hdlbridge/arith-4.1.0.oracle")
      if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      directory = directory.deletingLastPathComponent()
    }
    return nil
  }

  // MARK: - The netlist stand-in

  /// The whole of what any `std/arith` generator asks a `Netlist` for is `projName()`, and the
  /// bridge builds `new Circuit("oracle", null, null)` whose `getProjName()` is `""` (it has no
  /// `LogisimFile`). Everything else here would be a bug to reach and is given a value that
  /// makes reaching it obvious.
  final class OracleNetlist: HdlNetlist {
    func netId(for net: any HdlNet) -> Int { -1 }
    func isContinuesBus(_ component: any HdlNetlistComponent, endIndex: Int) -> Bool { false }
    var currentHierarchyLevel: [String]? { nil }
    func clockSourceId(hierarchyLevel: [String], net: any HdlNet, bitIndex: Int) -> Int { -1 }
    var circuitName: String { "oracle" }
    var projName: String { "" }
    var requiresGlobalClockConnection: Bool { false }
  }

  // MARK: - Transcript generation, mirroring ArithBridge.runCase line for line

  static let widths = [1, 2, 3, 4, 8, 16, 31, 32, 33, 63, 64]

  static func emit(_ out: inout [String], _ tag: String, _ lines: [String]?) {
    guard let lines else {
      out.append("\(tag) <null>")
      return
    }
    for entry in lines {
      if entry.isEmpty {
        out.append("\(tag)|")
        continue
      }
      for line in entry.split(separator: "\n", omittingEmptySubsequences: false) {
        out.append("\(tag)|\(line)")
      }
    }
  }

  /// The `ComponentFactory` answers the bridge dumps alongside the generator's own output:
  /// `getHDLName`, `getHDLGenerator(attrs) != null`, and `isHDLSupportedComponent(attrs)`.
  ///
  /// The port's answers come from `HdlGeneratorLookup.Registration`, which is exactly the data
  /// the integrator installs, so comparing them here verifies the registration list itself and
  /// not only the generators. `registration` is `nil` for a factory this port must not register
  /// : `Divider`, whose oracle rows are `SYNTH 0` / `SUPP 0` at every width and mode.
  ///
  /// `SUPP` is derived rather than declared because `AbstractComponentFactory`'s default for
  /// `isHDLSupportedComponent` is `getHDLGenerator(attrs) != null` and no arith factory
  /// overrides it. The oracle proves that derivation right for all 308 cases.
  static func factoryAnswers(
    _ out: inout [String], registration: HdlGeneratorLookup.Registration?, factoryName: String,
    attrs: any AttributeSet
  ) {
    let hdlName =
      registration?.hdlName?(attrs) ?? CorrectLabel.correctLabel(factoryName)
    let hasGenerator = registration?.generator(attrs) != nil
    out.append("HDLNAME \(hdlName)")
    out.append("SYNTH \(hasGenerator ? 1 : 0)")
    out.append("SUPP \(hasGenerator ? 1 : 0)")
  }

  static func runCase(
    _ out: inout [String], caseName: String, generator: AbstractHdlGeneratorFactory,
    attrs: any AttributeSet, componentName: String,
    registration: HdlGeneratorLookup.Registration?, factoryName: String
  ) {
    let netlist = OracleNetlist()
    out.append("CASE \(caseName)")
    out.append("LANG \(HdlSettings.language.rawValue)")
    factoryAnswers(&out, registration: registration, factoryName: factoryName, attrs: attrs)
    out.append("DIR \(generator.relativeDirectory)")
    out.append("INLINED \(generator.isOnlyInlined ? 1 : 0)")
    out.append("SUPPORTED \(generator.isHdlSupportedTarget(attrs: attrs) ? 1 : 0)")
    out.append("GENTIME \(generator.getWiresPortsDuringHdlWriting ? 1 : 0)")

    if generator.getWiresPortsDuringHdlWriting {
      generator.myWires.removeWires()
      generator.myTypedWires.clear()
      generator.myPorts.removePorts()
      generator.getGenerationTimeWiresPorts(netlist: netlist, attrs: attrs)
    }

    for id in generator.myParametersList.keySet(attrs) {
      let name = generator.myParametersList.get(id, attrs: attrs) ?? "null"
      let isInt = generator.myParametersList.isPresentedByInteger(id, attrs: attrs) ? 1 : 0
      out.append("PARAMKEY \(id) name=\(name) int=\(isInt)")
    }
    // `getMaps` throws under D13 when a parameter declaration does not match the attribute set.
    // Every case here is built from a real factory's own attribute set, so a throw is a genuine
    // failure; emitted as a line no oracle can contain, which fails the gate loudly rather than
    // being swallowed into an empty map that would compare equal to a component with no generics.
    var maps: [String: String] = [:]
    do {
      maps = try generator.myParametersList.getMaps(attrs)
    } catch {
      out.append("PARAM <threw: \(error)>")
    }
    for key in maps.keys.sorted() { out.append("PARAM \(key) = \(maps[key]!)") }
    out.append("PARAMEMPTY \(generator.myParametersList.isEmpty(attrs) ? 1 : 0)")

    for name in generator.myPorts.keySet() {
      let pin =
        generator.myPorts.isFixedMapped(name)
        ? "fixed:\(generator.myPorts.getFixedMap(name))"
        : String(generator.myPorts.getComponentPortId(name))
      out.append(
        "PORT \(name) bits=\(generator.myPorts.get(name, attrs: attrs)) pin=\(pin)"
          + " clock=\(generator.myPorts.isClock(name) ? 1 : 0)"
          + " pulldown=\(generator.myPorts.doPullDownOnFloat(name) ? 1 : 0)")
    }
    for direction in [HdlPortDirection.input, .output, .inout_] {
      out.append(
        "PORTDIR \(direction.rawValue) \(generator.myPorts.keySet(direction).joined(separator: ","))"
      )
    }

    for name in generator.myWires.wireKeySet() {
      out.append("WIRE \(name) bits=\(generator.myWires.get(name))")
    }
    for name in generator.myWires.registerKeySet() {
      out.append("REG \(name) bits=\(generator.myWires.get(name))")
    }

    emit(&out, "FUNC", generator.getModuleFunctionality(netlist: netlist, attrs: attrs).get())
    emit(
      &out, "ENTITY",
      generator.getEntity(netlist: netlist, attrs: attrs, componentName: componentName))
    emit(
      &out, "ARCH",
      generator.getArchitecture(netlist: netlist, attrs: attrs, componentName: componentName))
    emit(
      &out, "INST",
      generator.getComponentInstantiation(
        netlist: netlist, attrs: attrs, componentName: componentName
      ).get())
    out.append("ENDCASE")
    out.append("")
  }

  static func widthOnlySet(_ width: Int) -> any AttributeSet {
    AttributeSets.fixedSet([StdAttr.width.binding(BitWidth.known(width))])
  }

  static func modeSet(_ width: Int, _ mode: AttributeOption) -> any AttributeSet {
    AttributeSets.fixedSet([
      StdAttr.width.binding(BitWidth.known(width)),
      Comparator.modeAttr.binding(mode),
    ])
  }

  static func shiftSet(_ width: Int, _ shift: AttributeOption) -> any AttributeSet {
    AttributeSets.fixedSet([
      StdAttr.width.binding(BitWidth.known(width)),
      Shifter.attrShift.binding(shift),
    ])
  }

  static func allCases(_ out: inout [String]) {
    let modes: [(String, AttributeOption)] = [
      ("twosComplement", Comparator.signedOption),
      ("unsigned", Comparator.unsignedOption),
    ]
    let shifts: [(String, AttributeOption)] = [
      ("ll", Shifter.shiftLogicalLeft),
      ("lr", Shifter.shiftLogicalRight),
      ("ar", Shifter.shiftArithmeticRight),
      ("rl", Shifter.shiftRollLeft),
      ("rr", Shifter.shiftRollRight),
    ]

    // The registration list, built exactly as the integrator will build it: from LogisimStd's
    // own `Attribute` objects, whose identity is what `HdlParameters` compares (D4).
    let adder = ArithHdlRegistrations.adder()
    let subtractor = ArithHdlRegistrations.subtractor()
    let negator = ArithHdlRegistrations.negator()
    let comparator = ArithHdlRegistrations.comparator(modeAttribute: Comparator.modeAttr)
    let multiplier = ArithHdlRegistrations.multiplier(modeAttribute: Comparator.modeAttr)
    let shifter = ArithHdlRegistrations.shifter(shiftAttribute: Shifter.attrShift)

    for width in widths {
      runCase(
        &out, caseName: "Adder w=\(width)", generator: AdderHdlGeneratorFactory(),
        attrs: widthOnlySet(width), componentName: "Adder_\(width)",
        registration: adder, factoryName: ArithHdlRegistrations.adderName)
      runCase(
        &out, caseName: "Subtractor w=\(width)", generator: SubtractorHdlGeneratorFactory(),
        attrs: widthOnlySet(width), componentName: "Subtractor_\(width)",
        registration: subtractor, factoryName: ArithHdlRegistrations.subtractorName)
      runCase(
        &out, caseName: "Negator w=\(width)", generator: NegatorHdlGeneratorFactory(),
        attrs: widthOnlySet(width), componentName: "Negator_\(width)",
        registration: negator, factoryName: ArithHdlRegistrations.negatorName)

      for (modeName, mode) in modes {
        runCase(
          &out, caseName: "Comparator w=\(width) mode=\(modeName)",
          generator: ComparatorHdlGeneratorFactory(modeAttribute: Comparator.modeAttr),
          attrs: modeSet(width, mode), componentName: "Comparator_\(width)",
          registration: comparator, factoryName: ArithHdlRegistrations.comparatorName)
        runCase(
          &out, caseName: "Multiplier w=\(width) mode=\(modeName)",
          generator: MultiplierHdlGeneratorFactory(modeAttribute: Comparator.modeAttr),
          attrs: modeSet(width, mode), componentName: "Multiplier_\(width)",
          registration: multiplier, factoryName: ArithHdlRegistrations.multiplierName)
        // No registration for Divider, on purpose; the oracle's own SYNTH/SUPP rows are 0.
        runCase(
          &out, caseName: "Divider w=\(width) mode=\(modeName)",
          generator: DividerHdlGeneratorFactory(modeAttribute: Comparator.modeAttr),
          attrs: modeSet(width, mode), componentName: "Divider_\(width)",
          registration: nil, factoryName: ArithHdlRegistrations.dividerName)
      }

      for (shiftName, shift) in shifts {
        runCase(
          &out, caseName: "Shifter w=\(width) shift=\(shiftName)",
          generator: ShifterHdlGeneratorFactory(shiftAttribute: Shifter.attrShift),
          attrs: shiftSet(width, shift), componentName: "Shifter_\(width)_bit",
          registration: shifter, factoryName: ArithHdlRegistrations.shifterName)
      }
    }
  }

  /// The whole transcript, both languages, in the bridge's order.
  static func transcript() -> [String] {
    let savedLanguage = HdlSettings.language
    let savedCase = HdlSettings.vhdlKeywordsUppercase
    let savedName = HdlBuildInfo.name
    let savedUrl = HdlBuildInfo.url
    defer {
      HdlSettings.language = savedLanguage
      HdlSettings.vhdlKeywordsUppercase = savedCase
      HdlBuildInfo.name = savedName
      HdlBuildInfo.url = savedUrl
    }
    HdlSettings.vhdlKeywordsUppercase = true
    // `HdlFileWriter.generateRemark` quotes `BuildInfo.name`/`.url`, which the port has
    // deliberately rebranded (`HdlBuildInfo`'s defaults are `logisim-evolved` and the repo URL).
    // That is a product decision, not generator behaviour, so the gate pins both ends to what
    // the 4.1.0 jar quotes and measures the generators. `HdlBuildInfo` is settable precisely so
    // this needs no edit to a file this suite does not own.
    HdlBuildInfo.name = "Logisim-evolution"
    HdlBuildInfo.url = "https://github.com/logisim-evolution/"

    var out: [String] = []
    for language in [HdlLanguage.vhdl, .verilog] {
      HdlSettings.language = language
      out.append("### LANGUAGE \(language.rawValue)")
      allCases(&out)
    }
    return out
  }

  // MARK: - Loading and slicing the two transcripts

  /// The Swift transcript, generated once. `.serialized` plus a `static let` keeps the 60 s of
  /// generation off every test.
  static let swiftTranscript: [String] = {
    // `transcript()` saves and restores the HDL globals itself, but saving is not enough: another
    // suite running in parallel can flip `language` *between* two of this transcript's cases.
    // The lock is what makes the save/restore meaningful. See `HdlGlobalStateLock.swift`.
    let lines = withHdlGlobals { transcript() }
    // Escape hatch for investigating a divergence with a real diff tool rather than the first
    // few lines a failure message can carry.
    if let dump = ProcessInfo.processInfo.environment["LOGISIM_ARITH_HDL_DUMP"] {
      try? (lines.joined(separator: "\n") + "\n").write(
        toFile: dump, atomically: true, encoding: .utf8)
    }
    return lines
  }()

  static func jarTranscript() -> [String]? {
    guard let url = oracleURL(), let text = try? String(contentsOf: url, encoding: .utf8) else {
      return nil
    }
    var lines = text.components(separatedBy: "\n")
    // A trailing newline in the file yields one trailing empty component the generated array
    // does not have.
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  /// A `LineBuffer.buildRemarkBlock` rule line: 80 columns of the language's remark character,
  /// with the block-open/close markers folded in (`---`…`---` in VHDL, `/**`…`**/` in Verilog).
  /// No line of real HDL is 80 columns drawn from those characters alone.
  static func isRemarkRule(_ payload: String) -> Bool {
    guard payload.count == LineBuffer.maxLineLength else { return false }
    return payload.allSatisfy { $0 == "-" } || payload.allSatisfy { $0 == "*" || $0 == "/" }
  }

  /// The `FUNC|` payloads of the transcript with whole remark blocks removed.
  ///
  /// `FUNC` is `getModuleFunctionality` verbatim, the part of the output the arith generators
  /// actually author, and the only comment text in it is `Shifter`'s two remark blocks, whose
  /// rendering belongs to `LineBuffer`, not here. Dropping rule-delimited regions therefore
  /// isolates exactly the arith-owned text.
  static func moduleFunctionality(_ transcript: [String]) -> (kept: [String], dropped: Int) {
    var kept: [String] = []
    var dropped = 0
    var inBlock = false
    for line in transcript where line.hasPrefix("FUNC|") || line.hasPrefix("CASE ") {
      if line.hasPrefix("CASE ") {
        // Case boundaries stay in, so a divergence names the case it belongs to and a dropped
        // line cannot shift one case's body onto another's.
        inBlock = false
        kept.append(line)
        continue
      }
      let payload = String(line.dropFirst("FUNC|".count))
      if isRemarkRule(payload) {
        inBlock.toggle()
        dropped += 1
        continue
      }
      if inBlock {
        dropped += 1
        continue
      }
      kept.append(payload)
    }
    return (kept, dropped)
  }

  /// Everything that is not generated HDL text: the case header, the declared generic
  /// parameters, ports and wires. Entirely authored by the arith generators.
  static func structure(_ transcript: [String]) -> [String] {
    let textTags = ["FUNC|", "ENTITY|", "ARCH|", "INST|", "ARCH <null>"]
    return transcript.filter { line in !textTags.contains { line.hasPrefix($0) } }
  }

  static func firstDivergences(_ expected: [String], _ actual: [String], limit: Int = 12)
    -> (count: Int, report: String)
  {
    var shown: [String] = []
    var count = 0
    for index in 0..<max(expected.count, actual.count) {
      let jar = index < expected.count ? expected[index] : "<past end>"
      let swift = index < actual.count ? actual[index] : "<past end>"
      guard jar != swift else { continue }
      count += 1
      if shown.count < limit {
        shown.append("line \(index + 1):\n    jar:   \(jar)\n    swift: \(swift)")
      }
    }
    return (count, shown.joined(separator: "\n"))
  }

  // MARK: - The gates

  @Test("the oracle transcript is present and the size it should be")
  func oracleIsUsable() throws {
    // A gate that compares nothing looks exactly like a gate that passes.
    let expected = try #require(
      Self.jarTranscript(),
      "tools/hdlbridge/arith-4.1.0.oracle is missing — no gate in this suite actually ran")
    #expect(expected.count == 42652, "oracle is \(expected.count) lines, expected 42652")
    #expect(expected.filter { $0.hasPrefix("CASE ") }.count == 308)
    #expect(Self.swiftTranscript.filter { $0.hasPrefix("CASE ") }.count == 308)
  }

  @Test("declared parameters, ports and wires match the jar exactly")
  func structureMatchesJar() throws {
    let expected = try #require(Self.jarTranscript())
    let jar = Self.structure(expected)
    let swift = Self.structure(Self.swiftTranscript)
    #expect(jar.count > 5_000, "structure slice looks empty: \(jar.count) lines")
    let (count, report) = Self.firstDivergences(jar, swift)
    #expect(count == 0, "\(count) of \(jar.count) structure lines differ:\n\(report)")
  }

  @Test("generated module bodies match the jar exactly")
  func moduleFunctionalityMatchesJar() throws {
    let expected = try #require(Self.jarTranscript())
    let (jar, jarDropped) = Self.moduleFunctionality(expected)
    let (swift, swiftDropped) = Self.moduleFunctionality(Self.swiftTranscript)
    // The filter must be doing something, and the same something on both sides, or "no
    // divergences" would mean "nothing was compared".
    #expect(jar.count == 7845, "body slice is \(jar.count) lines, expected 7845")
    #expect(jarDropped > 0 && swiftDropped > 0, "the remark-block filter matched nothing")
    let (count, report) = Self.firstDivergences(jar, swift)
    #expect(count == 0, "\(count) of \(jar.count) module-body lines differ:\n\(report)")
  }

  /// The whole transcript, byte for byte -- entity, architecture, component instantiation and
  /// module body, both languages, all 308 cases.
  ///
  /// This carried a `withKnownIssue` wrapper while three `LogisimHdl` framework defects were
  /// outstanding, with a note to delete it once they landed. They have, so it is gone:
  ///
  /// 1. `LineBuffer.getWithIndent` kept the trailing empty field Java's `String.split(String)`
  ///    discards, so every multi-line `add(...)` gained a blank line. It now goes through
  ///    `javaSplit`. NB the fix this comment used to propose -- `while lines.count > 1 && ...`
  ///    -- is the one that was tried and was WRONG: it mishandles input that is entirely
  ///    separators. See `JavaSplitSemanticsTests`.
  /// 2. `Hdl.getExtendedLibrary()`/`getStandardLibrary()` lost the newline a Java text block
  ///    appends after its last content line.
  /// 3. `LineBuffer.buildRemarkBlock` did not split the word-wrapped text on a newline, so
  ///    `Shifter`'s "ShifterMode represents when:" block rendered as one over-wide frame.
  ///
  /// `withKnownIssue(isIntermittent: true)` passes whether or not the issue occurs, so while it
  /// was here this test reported green either way and the suite's pass said nothing about the
  /// transcript. That is why it is removed rather than narrowed.
  @Test("the whole transcript matches the jar, byte for byte")
  func matchesJarTranscript() throws {
    let expected = try #require(Self.jarTranscript())
    // A silently empty transcript compares equal to nothing and passes. Assert both sides
    // produced work before comparing them.
    #expect(expected.count > 1000, "jar transcript has only \(expected.count) lines")
    #expect(
      Self.swiftTranscript.count > 1000,
      "Swift transcript has only \(Self.swiftTranscript.count) lines")
    let (count, report) = Self.firstDivergences(expected, Self.swiftTranscript)
    #expect(count == 0, "\(count) of \(expected.count) lines differ:\n\(report)")
  }

  /// `ArithPortIds` duplicates constants that live in `LogisimStd`, because `LogisimHdl` must
  /// not name that module. Duplication is only safe if a divergence is loud.
  @Test("component pin indices agree with LogisimStd")
  func portIdsMatchLogisimStd() {
    #expect(ArithPortIds.Adder.in0 == LogisimStd.Adder.in0)
    #expect(ArithPortIds.Adder.in1 == LogisimStd.Adder.in1)
    #expect(ArithPortIds.Adder.out == LogisimStd.Adder.out)
    #expect(ArithPortIds.Adder.carryIn == LogisimStd.Adder.cIn)
    #expect(ArithPortIds.Adder.carryOut == LogisimStd.Adder.cOut)

    #expect(ArithPortIds.Subtractor.in0 == LogisimStd.Subtractor.in0)
    #expect(ArithPortIds.Subtractor.in1 == LogisimStd.Subtractor.in1)
    #expect(ArithPortIds.Subtractor.out == LogisimStd.Subtractor.out)
    #expect(ArithPortIds.Subtractor.borrowIn == LogisimStd.Subtractor.bIn)
    #expect(ArithPortIds.Subtractor.borrowOut == LogisimStd.Subtractor.bOut)

    #expect(ArithPortIds.Multiplier.in0 == LogisimStd.Multiplier.in0)
    #expect(ArithPortIds.Multiplier.in1 == LogisimStd.Multiplier.in1)
    #expect(ArithPortIds.Multiplier.out == LogisimStd.Multiplier.out)
    #expect(ArithPortIds.Multiplier.carryIn == LogisimStd.Multiplier.cIn)
    #expect(ArithPortIds.Multiplier.carryOut == LogisimStd.Multiplier.cOut)

    #expect(ArithPortIds.Divider.in0 == LogisimStd.Divider.in0)
    #expect(ArithPortIds.Divider.in1 == LogisimStd.Divider.in1)
    #expect(ArithPortIds.Divider.out == LogisimStd.Divider.out)
    #expect(ArithPortIds.Divider.upper == LogisimStd.Divider.upper)
    #expect(ArithPortIds.Divider.rem == LogisimStd.Divider.rem)

    #expect(ArithPortIds.Negator.inPort == LogisimStd.Negator.inPort)
    #expect(ArithPortIds.Negator.outPort == LogisimStd.Negator.outPort)

    #expect(ArithPortIds.Comparator.in0 == Comparator.in0)
    #expect(ArithPortIds.Comparator.in1 == Comparator.in1)
    #expect(ArithPortIds.Comparator.greaterThan == Comparator.gt)
    #expect(ArithPortIds.Comparator.equal == Comparator.eq)
    #expect(ArithPortIds.Comparator.lessThan == Comparator.lt)

    #expect(ArithPortIds.Shifter.in0 == Shifter.in0)
    #expect(ArithPortIds.Shifter.in1 == Shifter.in1)
    #expect(ArithPortIds.Shifter.out == Shifter.out)
  }

  /// `ArithHdlOptions` respells `AttributeOption`s that live in `LogisimStd`. They are structs
  /// with value equality, so this is sound: but only while the names agree.
  @Test("attribute options agree with LogisimStd")
  func optionsMatchLogisimStd() {
    #expect(ArithHdlOptions.signed == Comparator.signedOption)
    #expect(ArithHdlOptions.unsigned == Comparator.unsignedOption)
    #expect(ArithHdlOptions.shiftLogicalLeft == Shifter.shiftLogicalLeft)
    #expect(ArithHdlOptions.shiftLogicalRight == Shifter.shiftLogicalRight)
    #expect(ArithHdlOptions.shiftArithmeticRight == Shifter.shiftArithmeticRight)
    #expect(ArithHdlOptions.shiftRollLeft == Shifter.shiftRollLeft)
    #expect(ArithHdlOptions.shiftRollRight == Shifter.shiftRollRight)
  }

  /// `Shifter.SHIFT_BITS_ATTR` is not ported, so the stage count is recomputed. This is the
  /// arithmetic upstream's `Shifter.configurePorts` performs, checked at every width the
  /// oracle covers plus the boundaries either side of each power of two.
  @Test("recomputed shift-bit count matches Shifter.configurePorts")
  func shiftBitsMatchesUpstream() {
    for width in 1...64 {
      var expected = 1
      while (1 << expected) < width { expected += 1 }
      #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: width) == expected)
    }
    // The values the oracle was generated with, spelled out so a change is visible.
    #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: 1) == 1)
    #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: 2) == 1)
    #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: 3) == 2)
    #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: 8) == 3)
    #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: 31) == 5)
    #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: 33) == 6)
    #expect(ShifterHdlGeneratorFactory.shiftBits(forWidth: 64) == 6)
  }
}
