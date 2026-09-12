// swift-tools-version: 6.0
//
// logisim-evolved — a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is therefore also GPL-3.0-only.

import PackageDescription
import Foundation

// D1 (see docs/decisions.md): the simulation kernel deliberately opts OUT of Swift
// Concurrency. It uses Thread/NSLock/NSCondition and thread-identity assertions, exactly
// as the Java does, which keeps `propagate()` synchronous. Making it async would infect
// all 108 propagate implementations and destroy the reusable InstanceStateImpl fast path.
let kernelSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v5),
]

// Everything above the kernel is modern Swift 6 with full actor isolation.
let uiSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
]

let package = Package(
  name: "logisim-evolved",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "LogisimKernel", targets: ["LogisimKernel"]),
    .library(name: "LogisimFile", targets: ["LogisimFile"]),
    .library(name: "LogisimRender", targets: ["LogisimRender"]),
    .library(name: "LogisimStd", targets: ["LogisimStd"]),
    .library(name: "LogisimAnalyze", targets: ["LogisimAnalyze"]),
    .library(name: "LogisimSoc", targets: ["LogisimSoc"]),
    .executable(name: "logisim-cli", targets: ["logisim-cli"]),
    // The app itself. Absent until 2026-09-05, which meant the whole UI half had never been
    // built as a runnable thing — see Sources/logisim-evolved-app/main.swift.
    .executable(name: "logisim-evolved-app", targets: ["logisim-evolved-app"]),
  ],
  targets: [
    // The event-driven simulation engine. No AppKit, no SwiftUI, no Swift Concurrency.
    // Keeping this module genuinely UI-free is what makes the headless differential
    // harness possible at all (D9).
    .target(
      name: "LogisimKernel",
      swiftSettings: kernelSettings
    ),

    // .circ XML reading/writing, including every version-migration pass.
    // Depends on LogisimDraw because a circuit's `<appear>` section IS a shape model:
    // CircuitAppearanceReader/Writer need AppearanceAnchor, AppearancePort and the SVG reader.
    // Safe only because LogisimDraw depends on LogisimKernel alone — geometry, not drawing — so
    // the headless CLI does not acquire CoreGraphics through it.
    .target(
      name: "LogisimFile",
      dependencies: ["LogisimKernel", "LogisimDraw"],
      swiftSettings: kernelSettings
    ),

    // D6: components emit primitives into a retained RenderScene and never touch a
    // drawing context. CoreGraphics backs it now; Metal drops in behind the same API
    // at M9 without touching any of the 109 component draw implementations.
    .target(
      name: "LogisimRender",
      dependencies: ["LogisimKernel"],
      swiftSettings: uiSettings
    ),

    // The builtin component library. Below the UI, not above it: a component's propagate()
    // runs on the simulation thread, so this target lives in the D1 world (Swift 5 language
    // mode, no Swift Concurrency) exactly as the kernel does. It depends on LogisimFile
    // because a factory has to read and write its own attributes from a .circ, and on
    // LogisimRender because D6 says a component paints by emitting primitives into a
    // RenderScene — without this edge no component can construct a SceneBuilder, and the
    // renderer is unreachable scaffolding rather than a dependency of anything.
    .target(
      name: "LogisimStd",
      // LogisimDraw added 2026-09-06: a subcircuit placement drew NOTHING (measured
      // painted=0 prims=0), and its custom `<appear>` half needs the shape model. LogisimDraw
      // depends on LogisimKernel alone -- geometry, not drawing -- so this adds no UI to Std
      // and does not violate D9.
      dependencies: ["LogisimKernel", "LogisimFile", "LogisimRender", "LogisimDraw"],
      swiftSettings: kernelSettings
    ),

    // Truth tables, Quine-McCluskey/Petrick minimisation, K-maps. Kept out of LogisimStd
    // because it consumes circuits rather than defining components.
    .target(
      name: "LogisimAnalyze",
      dependencies: ["LogisimKernel", "LogisimFile"],
      swiftSettings: kernelSettings
    ),

    // The `<appear>` shape model: rectangles, ovals, polylines, curves, text. Deliberately
    // depends on LogisimKernel alone and NOT on LogisimRender — it is geometry, not drawing,
    // and keeping the arrow pointing this way lets LogisimFile use it for custom appearances
    // without dragging CoreGraphics into the headless CLI.
    .target(
      name: "LogisimDraw",
      dependencies: ["LogisimKernel"],
      swiftSettings: kernelSettings
    ),

    // VHDL entity model backing `<vhdl>` elements.
    .target(
      name: "LogisimVhdl",
      dependencies: ["LogisimKernel"],
      swiftSettings: kernelSettings
    ),

    // HDL generation. Not wired into LogisimStd yet: component HDL generators are stripped
    // during the M4/M5 port and come back once the component library is complete.
    //
    // Depends on LogisimFile because the netlist under Sources/LogisimHdl/Netlist/ is built from
    // a Circuit: `Netlist` walks `circuit.wires`/`circuit.nonWires` and resolves every component
    // pin to a (root net, bit index). Without that edge the generation framework has no graph to
    // read and nothing in the module is reachable. The arrow points this way, never back —
    // LogisimFile must not name HdlGeneratorFactory, or the LogisimStd -> LogisimHdl edge the
    // component generators will need becomes a cycle. `HdlGeneratorLookup.swift` is what keeps
    // it pointing this way.
    .target(
      name: "LogisimHdl",
      dependencies: ["LogisimKernel", "LogisimFile"],
      swiftSettings: kernelSettings
    ),

    // The SoC subsystem: the Nios2 and RV32IM cores, the bus/DMA fabric, the memory-mapped
    // peripherals (PIO, VGA, JTAG UART), and the assembler and ELF loader that feed them.
    // Like LogisimStd this is a component library whose propagate() runs on the simulation
    // thread, so it belongs to the D1 world (Swift 5 language mode, no Swift Concurrency),
    // not the UI world. It depends on LogisimStd for Port/StdAttr/ComponentError and the
    // InstanceFactory base, and reaches LogisimKernel and LogisimFile through it.
    //
    // Declaring the target is itself the point: until this entry existed swift build had
    // never compiled these 73 files, so their errors accumulated invisibly and one missing
    // import sat undetected. A module absent from the build graph is not a module that works.
    .target(
      name: "LogisimSoc",
      dependencies: ["LogisimKernel", "LogisimFile", "LogisimStd"],
      swiftSettings: kernelSettings
    ),

    // Constructs the HDL generator registry's bindings, which is the one job that needs to see
    // BOTH LogisimStd and LogisimHdl at once.
    //
    // It exists as its own target because neither of those two can host it. `LogisimHdl` must not
    // depend on `LogisimStd` — that closes a cycle, since the per-component generators need
    // `LogisimStd -> LogisimHdl`. And `LogisimStd` cannot depend on `LogisimHdl` for the same
    // reason from the other side. So the binding construction, which reads real `LogisimStd`
    // attributes (`Comparator.modeAttr`, `Shifter.attrShift`, `StdAttr.label`, the `Pla` table,
    // a ROM's `MemContents`) and hands them to `HdlGeneratorLookup.BuiltinBindings`, lives above
    // both and is depended on by the two things that actually run.
    //
    // Without this, `registerAllBuiltins` is a registry nobody calls — the defect class this
    // project has hit eleven times. `LogisimHdlTests` was the ONLY target in the package that
    // could see both modules, and a test target is not a runtime.
    .target(
      name: "LogisimHdlWiring",
      dependencies: ["LogisimKernel", "LogisimFile", "LogisimStd", "LogisimHdl"],
      swiftSettings: kernelSettings
    ),

    // D6's drawing API, split in two so D9 can actually hold.
    //
    // `LogisimRender` is the PURE half — the scene a component emits primitives into. It imports
    // `LogisimKernel` and nothing platform-shaped: no CoreGraphics, no CoreText, no AppKit. That
    // is what makes `LogisimStd -> LogisimRender` safe to assert: 113 `LogisimStd` files import
    // it, and D9 requires that module to stay platform-free. Before the split the edge was true
    // but weak — it dragged CoreGraphics into anything that merely wanted to build a scene,
    // including the headless CLI and every test.
    //
    // Keeping the pure half under the ORIGINAL name is deliberate: those 113 imports and
    // graphcheck's existing edge stay literally unchanged while the claim they make gets
    // stronger.
    //
    // `LogisimRenderBackend` is the rasteriser — the `SceneRenderer` seam and its CoreGraphics
    // conformer. D6 sequences Metal at M9; when it lands it is a second conformer here, and
    // nothing above this line has to move.
    .target(
      name: "LogisimRenderBackend",
      dependencies: ["LogisimKernel", "LogisimRender"],
      swiftSettings: uiSettings
    ),

    .target(
      name: "LogisimUI",
      // The last three added 2026-09-06, after a sweep asked of every module "what in the
      // shipping app imports this". Three answers were nothing at all:
      //
      //   LogisimAnalyze  22 files, imported by NOTHING -- the whole combinational-analysis
      //                   subsystem, which is upstream's headline "Analyze Circuit" feature
      //                   and a core teaching tool, was unreachable from the app.
      //   LogisimVhdl     11 files, imported by NOTHING.
      //   LogisimSoc      82 files, imported ONLY by logisim-cli, so the GUI could not place
      //                   or simulate a single SoC component -- `#Soc` loaded as a D8
      //                   placeholder, which LogisimFileProjectHost's own comment predicted.
      //
      // 115 files of ported, gated functionality the application could not reach. An edge is
      // not the whole fix -- each still needs its registration and its UI -- but without the
      // edge nothing in the app can even name these types, so the gap was invisible to every
      // check except this one.
      //
      // `LogisimHdl` added 2026-09-06, and it is EXPLICIT on purpose even though
      // `LogisimHdlWiring` already pulls it in transitively. SwiftPM lets a target import a
      // transitive dependency, so the edge "worked" — but an edge nothing declares is one the
      // next dependency cleanup silently deletes, and it is the only thing standing between
      // `AnalyzeSyntaxChecker.hdlKeywordCheck` and `CorrectLabel.hdlCorrectLabel`. Recorded in
      // `tools/graphcheck.py`'s REQUIRED list for the same reason.
      dependencies: [
        "LogisimKernel", "LogisimFile", "LogisimRender", "LogisimRenderBackend", "LogisimStd",
        "LogisimHdl", "LogisimHdlWiring", "LogisimAnalyze", "LogisimSoc", "LogisimVhdl",
      ],
      swiftSettings: uiSettings
    ),

    // Headless driver. This is the half of the differential rig that we control;
    // its output must byte-match `java -jar logisim-evolution.jar -tty ...`.
    //
    // It depends on LogisimStd because loading a .circ faithfully needs the real builtin
    // components: Java writes a <tool> block only for attributes differing from the builtin
    // default, so without the component library the writer cannot tell default from
    // user-modified and the migration gate cannot pass. The CLI calls
    // StdLibraries.registerAll() before its first load.
    .executableTarget(
      name: "logisim-cli",
      // LogisimSoc is here because only an executable can register #Soc: its factories live in
      // LogisimSoc, which depends on LogisimStd, so registerAll() cannot reach back to them.
      //
      // LogisimHdlWiring is here for exactly the same reason, one layer up: the HDL generator
      // registry's bindings need both LogisimStd and LogisimHdl, and neither may depend on the
      // other. Same principle main.swift already states for #Soc — a registration living in one
      // executable's main is a registration the other executable silently lacks.
      dependencies: [
        "LogisimKernel", "LogisimFile", "LogisimStd", "LogisimSoc", "LogisimHdlWiring",
      ],
      swiftSettings: kernelSettings
    ),

    // Direct assertions on the wiring target. Without it, both of its suites had to live in
    // LogisimHdlTests, which cannot import LogisimHdlWiring — so the ROM binding test had to
    // rebuild the reader closure by hand and the UI half had to be a SOURCE SCAN rather than a
    // call. Two workarounds that each test a copy of the thing instead of the thing.
    // Declaring this is itself the point: the SoC suite went from 0 to 25 tests, and until the
    // target existed SPM silently omitted the directory, so a standalone verification script had
    // to run the
    // suite inside a scratch package copy to get any signal at all.
    // Three lines that call LogisimEvolvedApp.launch(). LogisimUI stays a library so the shell
    // is testable; this target is what makes it a program. Swift 6 settings, matching LogisimUI.
    .executableTarget(
      name: "logisim-evolved-app",
      dependencies: ["LogisimUI"],
      swiftSettings: uiSettings
    ),

    .testTarget(
      name: "LogisimSocTests",
      dependencies: ["LogisimSoc", "LogisimStd", "LogisimFile", "LogisimKernel"],
      swiftSettings: kernelSettings
    ),
    .testTarget(
      name: "LogisimHdlWiringTests",
      dependencies: [
        "LogisimHdlWiring", "LogisimHdl", "LogisimStd", "LogisimFile", "LogisimKernel",
      ],
      swiftSettings: kernelSettings
    ),
    .testTarget(
      name: "LogisimRenderBackendTests",
      dependencies: ["LogisimRenderBackend", "LogisimRender"],
      swiftSettings: uiSettings
    ),
    .testTarget(
      name: "LogisimKernelTests",
      dependencies: ["LogisimKernel"],
      swiftSettings: kernelSettings
    ),
    .testTarget(
      name: "LogisimFileTests",
      dependencies: ["LogisimFile"],
      swiftSettings: kernelSettings
    ),
    .testTarget(
      name: "LogisimAnalyzeTests",
      dependencies: ["LogisimAnalyze"],
      swiftSettings: kernelSettings
    ),
    .testTarget(
      name: "LogisimRenderTests",
      dependencies: ["LogisimRender"],
      swiftSettings: uiSettings
    ),
    .testTarget(
      name: "LogisimVhdlTests",
      dependencies: ["LogisimVhdl"],
      swiftSettings: kernelSettings
    ),
    // Note SPM SILENTLY OMITS a test target whose directory has no sources — it does not error.
    // An unregistered test target is indistinguishable from a passing one, so whenever a Tests/
    // directory appears, check it against `swift package describe` rather than assuming.
    .testTarget(
      name: "LogisimDrawTests",
      dependencies: ["LogisimDraw", "LogisimKernel"],
      swiftSettings: kernelSettings
    ),
    // The simulation gate: drives LogisimStd/Simulation against the Java `-tty table` oracle.
    // Skips itself when LOGISIM_CORPUS is unset, like the other corpus-backed suites.
    // The Log window and the chronogram. LogisimUI is a Swift 6 / @MainActor module, so its
    // tests are too; the log *model* itself is deliberately headless, which is what lets this
    // suite run with no window, no circuit and no simulation attached.
    .testTarget(
      name: "LogisimUITests",
      dependencies: ["LogisimUI", "LogisimKernel"],
      swiftSettings: uiSettings
    ),
    .testTarget(
      name: "LogisimStdTests",
      dependencies: ["LogisimStd", "LogisimFile", "LogisimKernel"],
      swiftSettings: kernelSettings
    ),
    // The netlist gate: builds a Netlist from a Circuit and compares it line for line against
    // what the shipped 4.1.0 jar builds (tools/hdlbridge/). LogisimStd is here because a .circ
    // cannot be loaded faithfully without the real builtin components — the same reason
    // logisim-cli depends on it. Registered here because SPM silently omits an unregistered
    // test target; see the note above LogisimDrawTests.
    .testTarget(
      name: "LogisimHdlTests",
      // LogisimHdlWiring is here so the FPGA map bindings have ONE copy. They were gated at 224
      // MAPINFO rows while living in this test target, which meant production installed nothing —
      // bindings and runtime each correct, nothing owning the join. The alternative was a second
      // copy under Sources, i.e. the LedArrayDriving duplication on purpose.
      // No cycle: LogisimHdlWiring -> {LogisimStd, LogisimHdl}, and this target already had both.
      dependencies: [
        "LogisimHdl", "LogisimStd", "LogisimFile", "LogisimKernel", "LogisimHdlWiring",
      ],
      swiftSettings: kernelSettings
    ),
  ]
)

// SwiftPM otherwise builds unrelated executables during `swift test`.
// Keep the complete test graph while excluding the GUI entry point for headless validation.
if ProcessInfo.processInfo.environment["LOGISIM_HEADLESS_TESTS"] == "1" {
  package.products.removeAll { $0.name == "logisim-evolved-app" }
  package.targets.removeAll { $0.name == "logisim-evolved-app" }
}
