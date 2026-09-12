// EditParityTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.tools.*, com.cburch.logisim.gui.main.*),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// M7's PASS CONDITION: A SCRIPTED SEQUENCE OF EDITS WHOSE SAVED .circ BYTE-MATCHES JAVA
//
// Every other subsystem here is gated against the 4.1.0 jar: the codec byte-exactly over the
// corpus, simulation byte-exactly over 1,347 truth tables, HDL and stats likewise. **Editing was
// the one subsystem with no parity gate at all.** It is tested piecemeal and well,
// `WireRepairComponentTests` drives real `.down`/`.dragged`/`.up` events and asserts the endpoints
// of the wire that lands in the `Circuit`, but nothing proved that a *sequence* of edits produces
// the file Java would produce. A GUI that looks right and writes subtly different .circ files is
// precisely what this catches.
//
// ── THE ORACLE ──────────────────────────────────────────────────────────────────────────────
//
// `tools/editbridge/EditBridge.java` applies the same script through 4.1.0's own tools, actions
// and writer, headlessly, and saves. Its header documents the three places headlessness had to be
// bought and exactly what each cost. The baselines it produced live in `tools/editbridge/golden`
// and are regenerated with `python3 tools/difftest/editparity.py --regenerate`.
//
// ── WHY THIS DRIVES THE HOST AND NOT THE MODEL ──────────────────────────────────────────────
//
// This is the single most important property of the file. Every gesture goes through
// `LogisimFileProjectHost`, `canvasHandlePointer`, `canvasHandleKey`, `perform(.undo)`,
// `perform(.selectTool:)`, `serialize()`, which is the object the AppKit shell talks to. Nothing
// here calls `circuit.mutatorAdd`, constructs a `Component`, or reaches past the editor. A test
// that did would pass against exactly the version worth rejecting: one whose model is right and
// whose editor is wrong.
//
// The one place a script does not go through a tool is `setattr`, and that is because upstream's
// own path for it is not a tool either; it is `AttrTableComponentModel.setValueRequested`, an
// attribute-table adapter that builds a `SetAttributeAction`. The Java side drives that real
// class through a same-package shim; this side runs `LogisimFileProjectHost.apply`'s own two
// lines, `beginMutation` + `doAction`, which is what the port's inspector does. Stated because it
// is the weakest link in the chain and should be read as such.
//
// ── THE ONE DELIBERATE CONFIGURATION DIFFERENCE ─────────────────────────────────────────────
//
// `AppPreferences.ADD_AFTER` defaults to `edit`: after placing, upstream switches to the Edit Tool
// and selects what it just placed. `Project.setTool` dereferences the frame, so a headless oracle
// cannot run that branch, and the bridge pins the preference to `unchanged`. This side pins the
// matching `CanvasAddTool.switchesToEditToolAfterAdding = false`. The consequence is part of the
// script language: **after `add`, nothing is selected**, on both sides, so a script that wants to
// move what it just placed selects it first.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AppKit
import CoreGraphics
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimRenderBackend
import LogisimStd
import Testing
import UniformTypeIdentifiers

@testable import LogisimUI

// MARK: - Where the fixtures live

/// `<repo>/tools/editbridge`. Derived from `#filePath` rather than a working directory, because
/// `swift test` runs from `swift/` and `tools/ci.sh` does not.
private let bridgeDirectory: URL = {
  var url = URL(fileURLWithPath: #filePath)
  for _ in 0..<4 { url = url.deletingLastPathComponent() }  // LogisimUITests, Tests, swift, repo
  return url.appendingPathComponent("tools").appendingPathComponent("editbridge")
}()

private let scriptDirectory = bridgeDirectory.appendingPathComponent("scripts")
private let goldenDirectory = bridgeDirectory.appendingPathComponent("golden")
private let seedURL = bridgeDirectory.appendingPathComponent("fixtures/seed.circ")

/// Every script stem, in name order. Empty is a failure, not a green run, see `theGateHasCases`.
private let scriptStems: [String] = {
  let names = (try? FileManager.default.contentsOfDirectory(atPath: scriptDirectory.path)) ?? []
  return names.filter { $0.hasSuffix(".script") }.map { String($0.dropLast(7)) }.sorted()
}()

// MARK: - The interpreter

private enum EditScriptError: Error, CustomStringConvertible {
  case noTool(String)
  case noComponent(Int, Int)
  case noAttribute(String, String)
  case unknownOperation(String)
  case badArity(String)

  var description: String {
    switch self {
    case .noTool(let spec): "no tool matching '\(spec)' in the loaded file"
    case .noComponent(let x, let y): "no component anchored at (\(x),\(y))"
    case .noAttribute(let owner, let name): "\(owner) has no attribute '\(name)'"
    case .unknownOperation(let op): "unknown operation '\(op)'"
    case .badArity(let line): "wrong number of fields: '\(line)'"
    }
  }
}

/// One scripted editing session over the port's real editor.
@MainActor
private final class EditRig {

  let host: LogisimFileProjectHost
  var project: Project { host.project }

  init() throws {
    let data = try Data(contentsOf: seedURL)
    let made = try LogisimFileProjectHostFactory().openProject(
      data: data, url: nil, contentType: LogisimDocumentType.circuit)
    host = try #require(made as? LogisimFileProjectHost)
    // The shell's first act on a new document, and the line that builds `editorCanvas`. Without
    // it `canvasHandlePointer` forwards to nil and every gesture is a silent no-op, which looks
    // exactly like an empty script.
    _ = host.makeRenderSurface()
  }

  private var circuit: Circuit {
    get throws { try #require(host.currentCircuitObject) }
  }

  // ── Tool selection ────────────────────────────────────────────────────────────────────────

  /// Depth-first over the loaded library tree, so the tool found is the library's OWN instance;
  /// the same object the explorer publishes and `handles.tools` is keyed on.
  private func libraryTool(matching spec: String) -> Tool? {
    func search(_ library: Library) -> Tool? {
      for tool in library.tools {
        if spec.hasPrefix("add:") {
          if let add = tool as? AddTool, add.factory.name == String(spec.dropFirst(4)) {
            return tool
          }
        } else if tool.name == spec {
          return tool
        }
      }
      for sub in library.libraries {
        if let found = search(sub) { return found }
      }
      return nil
    }
    return search(host.file)
  }

  private static let baseToolNames: [String: String] = [
    // `select` is deliberately absent on both sides: `SelectTool` is not published by
    // `BaseLibrary.getTools()` and no user can pick it. The Edit Tool is the gesture.
    "wiring": BaseToolIds.wiring,
    "edit": BaseToolIds.edit,
    "poke": BaseToolIds.poke,
    "text": BaseToolIds.textTool,
    "menu": BaseToolIds.menu,
  ]

  /// The id of the last tool a `tool` op selected, for `toolattr`.
  private var activeToolID: ToolID?

  private func selectTool(_ spec: String) throws {
    let name = spec.hasPrefix("add:") ? spec : (EditRig.baseToolNames[spec] ?? spec)
    guard let tool = libraryTool(matching: name) else { throw EditScriptError.noTool(spec) }
    // The shipping command, addressed by the id the explorer would have sent. Identity match, so
    // there is no chance of picking a different tool with the same display name.
    guard let id = host.handles.tools.first(where: { $0.value === tool })?.key else {
      throw EditScriptError.noTool(spec)
    }
    activeToolID = id
    try host.perform(.selectTool(id))

    // See the header: pinned to match `AppPreferences.ADD_AFTER = unchanged` in the oracle.
    if let add = host.editorCanvas?.controller.activeTool as? CanvasAddTool {
      add.switchesToEditToolAfterAdding = false
    }
  }

  // ── Gestures ──────────────────────────────────────────────────────────────────────────────

  private func pointer(_ phase: CanvasPointerEvent.Phase, _ x: Int, _ y: Int) {
    host.canvasHandlePointer(
      CanvasPointerEvent(
        phase: phase,
        world: CGPoint(x: CGFloat(x), y: CGFloat(y)),
        modifiers: [],
        clickCount: 1,
        buttonNumber: 1,
        dragOriginWorld: nil))
  }

  private func click(_ x: Int, _ y: Int) {
    pointer(.down, x, y)
    pointer(.up, x, y)
  }

  private func drag(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
    pointer(.down, x0, y0)
    pointer(.dragged, x1, y1)
    pointer(.up, x1, y1)
  }

  /// `key <name>`: one key press, through the shell's own key entry point.
  ///
  /// **`return` carries `"\n"` as its character and that is load-bearing, not decoration.** This
  /// port commits a caret edit off `event.character?.isNewline`, not off a `VK_ENTER` raw code;
  /// `AwtKeyCodes.virtualKeyCode` has no Return entry at all, so a press with an empty
  /// `characters` string would arrive at `TextFieldCaret.normalKeyPressed` as `rawKeyCode == 0`
  /// and fall through its `default`. `TextFieldCaret.swift`'s header argues that divergence from
  /// AWT (which sees both `VK_ENTER` and a `'\n'` `keyTyped`); this is the driver honouring it.
  /// The oracle's `key return` sends AWT's `VK_ENTER` press and no `keyTyped`, because by the time
  /// AWT's would arrive `TextTool.caret` is null, so both sides deliver exactly one commit.
  ///
  /// `0x24` is Return's AppKit virtual key code. It is spelled as a literal because
  /// `AppleKeyCodes` has no entry for it: `CanvasToolController.command(for:)` maps nothing to
  /// Return, which is precisely why the character is what carries the signal.
  private func key(_ name: String) throws {
    let code: UInt16
    let characters: String
    switch name {
    case "delete":
      code = AppleKeyCodes.forwardDelete
      characters = ""
    case "backspace":
      code = AppleKeyCodes.delete
      characters = ""
    case "return":
      code = 0x24
      characters = "\n"
    default: throw EditScriptError.unknownOperation("key \(name)")
    }
    _ = host.canvasHandleKey(
      CanvasKeyEvent(
        phase: .down, characters: characters, keyCode: code, modifiers: [], isRepeat: false))
  }

  /// `type <text>`: the characters of `text`, one press each.
  ///
  /// One `canvasHandleKey(.down)` per character and no separate typed event, because
  /// `CanvasToolController.canvasHandleKey` already synthesises AWT's `keyTyped` from a printable
  /// `keyDown` and does it in AWT's order (pressed, then typed). Sending a second event here would
  /// insert every character twice. The oracle sends the pair explicitly for the same reason,
  /// `EditBridge.type`, so the two drivers deliver the same two events per character.
  ///
  /// `keyCode` is 0: `AwtKeyCodes.virtualKeyCode(for:)` derives the AWT `VK_` value from the
  /// character for letters and digits, which is the same value `KeyEvent.getExtendedKeyCodeForChar`
  /// gives the oracle, so the raw code the caret switches on agrees on both sides without this
  /// having to carry a Mac scan code it would only be inventing.
  private func type(_ text: String) {
    for character in text {
      _ = host.canvasHandleKey(
        CanvasKeyEvent(
          phase: .down, characters: String(character), keyCode: 0, modifiers: [],
          isRepeat: false))
    }
  }

  // ── Attributes ────────────────────────────────────────────────────────────────────────────

  private func componentAnchored(at x: Int, _ y: Int) throws -> any Component {
    let match = try circuit.nonWires.first { $0.location == Location.create(x, y, hasToSnap: false) }
    guard let match else { throw EditScriptError.noComponent(x, y) }
    return match
  }

  /// The inspector's own entry point, addressed the way the attribute pane addresses it.
  ///
  /// `.text` is not a lossy choice: `InspectorProjection.encode` falls back to the attribute's own
  /// `.circ` parser for any candidate the attribute declines, which is precisely
  /// `Attribute.parse(String)`; the same call the Java side makes. So both sides convert the
  /// script's string with the same parser, and this side still goes through the real pane code.
  private func setComponentAttribute(_ x: Int, _ y: Int, _ name: String, _ text: String) throws {
    let component = try componentAnchored(at: x, y)
    try host.apply(
      AttributeEdit(
        target: .components([CircuitSceneSource.identity(of: component)]),
        key: AttributeKey(name), newValue: .text(text)))
  }

  /// A tool's own attributes: the defaults for the *next* placement, not a property of any
  /// component. `AttrTableToolModel` upstream; `apply(_:)`'s `.tool` arm here.
  ///
  /// **This targets the LIBRARY tool, and the choice is load-bearing.** `apply(_:)`'s `.tool` arm
  /// writes `handles.tools[id].attributeSet`, i.e. the library's own instance, which is what a
  /// user editing the pane actually changes, so that is what the gate must drive. Targeting the
  /// canvas tool instead was tried and measured, and the two produce *different* wrong files:
  /// writing the canvas tool gets the attributes onto the placed components but writes no
  /// `<lib><tool>` block; writing the library tool writes the block and leaves the components
  /// bare. Both are the same defect seen from opposite ends: see `10-tool-attributes` in
  /// `knownDivergences`.
  private func setToolAttribute(_ name: String, _ text: String) throws {
    guard let id = activeToolID else {
      throw EditScriptError.noTool("no tool has been selected yet")
    }
    try host.apply(
      AttributeEdit(target: .tool(id), key: AttributeKey(name), newValue: .text(text)))
  }

  // ── Run ───────────────────────────────────────────────────────────────────────────────────

  func run(_ script: String) throws {
    for raw in script.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let f = line.components(separatedBy: "\t")
      func int(_ i: Int) throws -> Int {
        guard i < f.count, let v = Int(f[i]) else { throw EditScriptError.badArity(line) }
        return v
      }
      switch f[0] {
      case "tool":
        guard f.count == 2 else { throw EditScriptError.badArity(line) }
        try selectTool(f[1])
      case "toolattr":
        guard f.count == 3 else { throw EditScriptError.badArity(line) }
        try setToolAttribute(f[1], f[2])
      case "click":
        click(try int(1), try int(2))
      case "drag":
        drag(try int(1), try int(2), try int(3), try int(4))
      case "key":
        guard f.count == 2 else { throw EditScriptError.badArity(line) }
        try key(f[1])
      case "type":
        guard f.count == 2 else { throw EditScriptError.badArity(line) }
        type(f[1])
      case "setattr":
        guard f.count == 5 else { throw EditScriptError.badArity(line) }
        try setComponentAttribute(try int(1), try int(2), f[3], f[4])
      case "undo":
        try host.perform(.undo)
      case "redo":
        try host.perform(.redo)
      default:
        throw EditScriptError.unknownOperation(f[0])
      }
    }
  }

  func save() throws -> String {
    String(decoding: try host.serialize(), as: UTF8.self)
  }
}

// MARK: - Masking, identical to rig.py's two rules

/// `XmlReader.generateValidVHDLLabel`'s random 8-hex suffix, and `Font.getFamily()`'s
/// host-dependent resolution; the only two classes of 4.1.0 non-determinism this project has
/// measured. Neither can arise from these scripts, so `didFire` is asserted false rather than
/// folded silently into the pass count. **No new forgiveness**: any other difference is a failure.
///
/// The reason for the `font` half used to be "nothing placed carries a label"; scripts 11-14 place
/// labelled components, so it is now the narrower and still sufficient one: a label attribute is
/// not a `labelfont` attribute. Nothing in the seed or in any script sets `font`, `labelfont` or
/// `clabelfont`, so no font is ever serialized for `Font.getFamily()` to have resolved. If that
/// mask ever fires here, a script has started writing a font and the mask is hiding a real
/// divergence, which is exactly what the `fired.isEmpty` expectation below is for.
private func mask(_ text: String) -> (masked: String, didFire: [String]) {
  var fired: [String] = []
  var out = text
  let vhdl = try! NSRegularExpression(pattern: "_[0-9a-f]{8}(?![0-9a-zA-Z_])")
  let font = try! NSRegularExpression(
    pattern: "(<a name=\"(?:font|labelfont|clabelfont)\" val=\")([^\"]*?)( \\w+ \\d+\"/>)")
  let whole = NSRange(out.startIndex..., in: out)
  if vhdl.firstMatch(in: out, range: whole) != nil {
    fired.append("vhdl-label")
    out = vhdl.stringByReplacingMatches(
      in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "_HASH")
  }
  if font.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)) != nil {
    fired.append("font")
    out = font.stringByReplacingMatches(
      in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1FAMILY$3")
  }
  return (out, fired)
}

/// A diff of the two documents.
///
/// **Deliberately a longest-common-subsequence diff and not a set difference.** The first version
/// of this reported `Set(java).subtracting(swift)`, and it lied on the very first divergence it
/// found: `10-tool-attributes` writes `<a name="facing" val="north"/>` in two places: once on
/// each placed component and once inside the `<lib><tool>` block, so a line that was missing from
/// one place was still present in the other and the set difference hid it. The reader was left
/// looking at a `<lib>` open tag with no explanation of what was inside it. A multiset-blind diff
/// is not a diff.
private func report(want: String, got: String) -> String {
  let a = want.components(separatedBy: "\n")
  let b = got.components(separatedBy: "\n")

  // Classic LCS table. These documents are tens of lines; O(n·m) is free and exact.
  var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
  for i in stride(from: a.count - 1, through: 0, by: -1) {
    for j in stride(from: b.count - 1, through: 0, by: -1) {
      lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
    }
  }

  var lines: [String] = []
  var i = 0
  var j = 0
  while i < a.count && j < b.count {
    if a[i] == b[j] {
      i += 1
      j += 1
    } else if lcs[i + 1][j] >= lcs[i][j + 1] {
      lines.append("- java  \(a[i])")
      i += 1
    } else {
      lines.append("+ swift \(b[j])")
      j += 1
    }
  }
  while i < a.count {
    lines.append("- java  \(a[i])")
    i += 1
  }
  while j < b.count {
    lines.append("+ swift \(b[j])")
    j += 1
  }
  if lines.isEmpty {
    lines.append("the lines are identical but the bytes are not — trailing whitespace differs")
  }
  return lines.joined(separator: "\n")
}

/// Where a run can leave its output for `tools/difftest/editparity.py --swift-out`.
///
/// Off unless the variable is set, so a normal `swift test` writes nothing. The comparison in this
/// file is the gate; this exists so a failing script can be inspected with real diff tools and so
/// the Python driver can run the same comparison outside the test process.
private let dumpDirectory: URL? = ProcessInfo.processInfo
  .environment["LOGISIM_EDIT_PARITY_OUT"].map { URL(fileURLWithPath: $0) }

// MARK: - The gate

@Suite("EditParity", .serialized)
@MainActor
struct EditParityTests {

  /// A gate with no cases is green and proves nothing, which is the failure mode
  /// `tools/gateaudit.py` exists to find. This is the guard against it.
  @Test("the gate has scripts and baselines to run")
  func theGateHasCases() throws {
    #expect(!scriptStems.isEmpty, "no scripts found in \(scriptDirectory.path)")
    #expect(FileManager.default.fileExists(atPath: seedURL.path), "the seed is missing")
    for stem in scriptStems {
      let golden = goldenDirectory.appendingPathComponent("\(stem).circ")
      #expect(
        FileManager.default.fileExists(atPath: golden.path),
        "\(stem) has no 4.1.0 baseline. Run: python3 tools/difftest/editparity.py --regenerate")
    }
  }

  /// **The seed must round-trip before any edit is measured.**
  ///
  /// The seed is upstream's `default.templ` after one pass through 4.1.0's own load/save, so it is
  /// a codec fixed point *for Java*. If it is not also one for this port, then every script below
  /// would fail for a codec reason and be misread as an editing defect. Making that a separate,
  /// named test is the difference between "editing is broken" and "editing is fine and M2
  /// regressed".
  @Test("the seed is a load/save fixed point on this side too")
  func seedRoundTrips() throws {
    let rig = try EditRig()
    let saved = try rig.save()
    let seed = try String(contentsOf: seedURL, encoding: .utf8)
    if saved != seed {
      Issue.record(
        Comment(rawValue: "the seed does not round-trip; every script result below is "
          + "unattributable until this passes.\n" + report(want: seed, got: saved)))
    }
    #expect(saved == seed)
  }

  /// Divergences this gate has FOUND and that are not this task's to fix, each with the exact
  /// defect and where it lives.
  ///
  /// `withKnownIssue` and not a deleted script, and not a doctored baseline: the script still
  /// runs, the diff is still printed, and the day the defect is fixed Swift Testing fails this
  /// test with "known issue was not recorded", so the entry cannot rot into silent forgiveness.
  /// Nothing here is a *class* of forgiveness like the two non-determinism masks; each is one
  /// named script and one named defect, and the table must shrink to nothing.
  /// It was empty, and it got there the intended way: `10-tool-attributes` was the first entry,
  /// the fix landed in `CanvasAddTool`, and this test failed with "known issue was not recorded"
  /// until the entry was deleted. That is the whole point of the mechanism; the marker is
  /// retired by the gate turning green, never by hand-waving it away.
  ///
  /// It has been empty twice more since. `14-caret-retype-detached-label`, "the port cannot find
  /// a component by clicking its label", the first defect the gate found once it could drive the
  /// Text Tool, was retired the same way on 2026-09-06 (board #84): the two-argument `contains`
  /// landed in `StdInstanceComponent`/`Circuit`/`TextTool`, this test failed with "known issue
  /// was not recorded", and the entry came out. The script and its golden are untouched and it
  /// now byte-matches.
  static let knownDivergences: [String: String] = [:]

  @Test("scripted edits byte-match 4.1.0", arguments: scriptStems)
  func scriptMatchesJava(stem: String) throws {
    guard let reason = EditParityTests.knownDivergences[stem] else {
      try compare(stem)
      return
    }
    withKnownIssue(Comment(rawValue: reason)) { try compare(stem) }
  }

  private func compare(_ stem: String) throws {
    let script = try String(
      contentsOf: scriptDirectory.appendingPathComponent("\(stem).script"), encoding: .utf8)
    let want = try String(
      contentsOf: goldenDirectory.appendingPathComponent("\(stem).circ"), encoding: .utf8)

    let rig = try EditRig()
    try rig.run(script)
    let got = try rig.save()

    if let dump = dumpDirectory {
      try? FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
      try? got.write(
        to: dump.appendingPathComponent("\(stem).circ"), atomically: true, encoding: .utf8)
    }

    if got == want { return }

    let (maskedWant, firedWant) = mask(want)
    let (maskedGot, firedGot) = mask(got)
    let fired = Array(Set(firedWant).union(firedGot)).sorted()
    #expect(
      fired.isEmpty,
      Comment(
        rawValue: "\(stem): a non-determinism mask fired (\(fired.joined(separator: ", "))). "
          + "These scripts cannot legitimately trigger one — investigate the script, not the "
          + "port."))
    if maskedWant == maskedGot { return }

    Issue.record(
      Comment(rawValue: "\(stem): the saved file differs from 4.1.0.\n"
        + report(want: want, got: got)))
    #expect(Bool(false), "\(stem) does not byte-match 4.1.0")
  }
}

