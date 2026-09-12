// BuiltinRegistrationTests.swift; part of logisim-evolved.
//
// `StdLibraries.registerAll()` is the one join between the ported component families and the
// `.circ` codec: `LogisimFile` declares a registry keyed by library id and `LogisimStd` fills
// it in. A library that is ported but not registered is invisible; `BuiltinToolProviders`
// answers `[]` for its id, and every `<comp lib="…" name="…">` naming it degrades to an
// `UnresolvedComponent` with `Bounds.empty` and no ends.
//
// That failed silently for `PlexersLibrary` and `ExtraIoLibrary`, which were both fully written
// and neither registered, costing 2,052 component placements across 225 corpus files. Nothing
// caught it because nothing asserted the join; the components had tests, the registrar had
// tests, and the line between them had none.
//
// So this suite asserts the join itself, per library, by id. It is deliberately not written as
// "registerAll registers eight things": a count would have passed just as happily with the
// wrong eight.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import Testing

@testable import LogisimStd

@Suite("the builtin-library join is actually wired", .serialized)
struct BuiltinRegistrationTests {

  /// Every library id `StdLibraries.registerAll()` claims to fill, with one factory name that
  /// must resolve through it. The factory name is the point: it proves the registry returns
  /// *this* library's tools and not merely something non-empty.
  ///
  /// `#Base` is absent from this table on purpose and is checked separately below: its `Text`
  /// factory is reachable only through the *named* channel, never through `tools`, exactly as
  /// upstream keeps `textAdder` out of `getTools()`. Asserting it here would demand a sixth
  /// tool where 4.1.0 publishes five.
  static let expected: [(id: String, factory: String)] = [
    (Builtin.gatesId, "AND Gate"),
    (Builtin.wiringId, "Pin"),
    (Builtin.arithmeticId, "Adder"),
    (Builtin.memoryId, "RAM"),
    (Builtin.ioId, "LED"),
    (Builtin.ttlId, "7400"),
    (Builtin.plexersId, "Multiplexer"),
    (Builtin.extraIoId, "Buzzer"),
  ]

  @Test("every registered library resolves a known component of its own")
  func everyLibraryResolves() {
    StdLibraries.registerAll()
    var missing: [String] = []
    for (id, factoryName) in Self.expected {
      let tools = BuiltinToolProviders.tools(forLibraryId: id)
      let names = tools.compactMap { ($0 as? AddTool)?.factory.name }
      if !names.contains(factoryName) {
        missing.append("\(id): expected a factory named \(factoryName), got \(names.count) tools")
      }
    }
    #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
  }

  /// `#Base`'s two channels, which are the reason `registerAll` cannot just map ids to tool
  /// lists. The toolbar publishes five tools and none of them is an `AddTool`; `<comp lib="0"
  /// name="Text">` resolves through `namedTools` instead. Both must be wired or a text
  /// annotation cannot be placed and a toolbar cannot round-trip.
  @Test("#Base publishes five toolbar tools and answers Text through the named channel")
  func baseHasBothChannels() {
    StdLibraries.registerAll()
    let tools = BuiltinToolProviders.tools(forLibraryId: Builtin.baseId)
    #expect(tools.count == 5, "4.1.0 publishes exactly five; got \(tools.map(\.name))")
    // A placeholder here is what made 42 corpus files re-emit a stale font attribute: the Text
    // Tool carries the attribute set an `<a name="font"/>` element is absorbed into.
    #expect(tools.contains { $0 is TextTool }, "the Text Tool must be real, not a placeholder")

    let named = BuiltinToolProviders.namedTools(forLibraryId: Builtin.baseId)
    let textAdder = named[BaseToolIds.textFactory] as? AddTool
    #expect(textAdder != nil, "getTool(\"Text\") must answer an AddTool; got \(named.keys.sorted())")
    #expect(textAdder?.factory.name == "Text")
    // Keeping textAdder out of getTools() is upstream's own arrangement: publishing it would
    // make XmlWriter.fromLibrary emit a <tool name="Text"> element the 4.1.0 oracle never writes.
    #expect(
      !tools.contains { ($0 as? AddTool)?.factory.name == "Text" },
      "textAdder must stay out of getTools()")
  }

  /// The specific regression: the plexers were ported and unregistered for long enough that a
  /// comment in `StdLibraries.swift` asserted the library did not exist.
  @Test("the plexers resolve — all five of them")
  func plexersResolve() {
    StdLibraries.registerAll()
    let names = Set(
      BuiltinToolProviders.tools(forLibraryId: Builtin.plexersId)
        .compactMap { ($0 as? AddTool)?.factory.name })
    for expected in [
      "Multiplexer", "Demultiplexer", "Decoder", "Priority Encoder", "BitSelector",
    ] {
      #expect(names.contains(expected), "Plexers is missing \(expected); got \(names.sorted())")
    }
  }

  /// A registered library's factories must also have real geometry, or resolving them buys
  /// nothing: `buildCircuit` keys its overlap detector on bounds.
  @Test("every registered factory has non-empty bounds")
  func registeredFactoriesHaveBounds() {
    StdLibraries.registerAll()
    var empty: [String] = []
    for (id, _) in Self.expected {
      for tool in BuiltinToolProviders.tools(forLibraryId: id) {
        guard let factory = (tool as? AddTool)?.factory else { continue }
        let bounds = factory.offsetBounds(factory.createAttributeSet())
        if bounds.width == 0 || bounds.height == 0 { empty.append("\(id)/\(factory.name)") }
      }
    }
    #expect(empty.isEmpty, "registered but geometry-less: \(empty.sorted())")
  }
}
