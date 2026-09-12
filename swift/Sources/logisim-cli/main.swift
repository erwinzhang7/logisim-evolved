// logisim-cli; headless driver for logisim-evolved.
//
// Its output must byte-match the Java implementation. `--convert` is the M2 gate's entry
// point and mirrors what tools/valuebridge/CircBridge.java does on the Java side, so the
// two are directly diffable:
//
//     logisim-cli --convert <in.circ> <out.circ>
//
// The gate applies it two ways (tools/difftest/rig.py --roundtrip):
//
//     MIGRATION   convert(original)  must byte-match  CircBridge(original)
//     CANONICAL   convert(canonical) must byte-match  canonical
//
// where `canonical` is the fixed point of repeated Java conversion: iterated, not assumed,
// because 20 corpus files need three passes and 2 never converge at all.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import LogisimFile
import LogisimHdl
import LogisimHdlWiring
import LogisimKernel
import LogisimSoc
import LogisimStd

// Install the builtin component libraries before anything is loaded.
//
// `LogisimFile` cannot name a component, the dependency runs LogisimStd → LogisimFile, which is
// what lets the codec load a file headlessly, so builtin tools arrive through the
// `BuiltinToolProviders` registry and someone has to fill it in. Without this call the CLI still
// runs and still writes output; every `<comp>` simply resolves to nothing, which presents as a
// corrupt-looking file rather than a missing registration.
//
// It must precede the first load: a `BuiltinLibraryShell` materialises its tool list once, on
// first use, and caches it thereafter.
StdLibraries.registerAll()

// `#Soc` is the one registration `StdLibraries.registerAll()` genuinely CANNOT make. Its
// factories are `com.cburch.logisim.soc.*`, they live in `LogisimSoc`, and `LogisimSoc` depends
// on `LogisimStd`; the arrow cannot point back. So whoever links an executable makes this call:
// here for the CLI, and the same call in the app's startup.
//
// Everything else that used to sit here, `#Base` with the real `Text` factory, `#Plexers`,
// `#FpArithmetic`, `#ExtraIo`, `#TCL`, `#HDL-IP`, `#BFH-Praktika`, has moved into
// `StdLibraries.registerAll()`, which is its only correct home. A registration living in one
// executable's `main` is a registration the other executable silently lacks.
SocLibrary.registerBuiltinTools()

// The 40 per-component HDL generators, for exactly the same reason and by exactly the same rule.
// `HdlGeneratorLookup.registerAllBuiltins` needs bindings drawn from BOTH `LogisimStd` and
// `LogisimHdl`, and neither module may depend on the other (the per-component generators run
// LogisimStd → LogisimHdl, so the reverse edge closes a cycle). `LogisimHdlWiring` is the target
// above both that holds the bindings; only an executable can make the call.
//
// Until this line existed the registry was populated by nothing at runtime: `LogisimHdlTests` was
// the only target in the package that could see both modules, and a test target is not a runtime.
// An unpopulated `HdlGeneratorLookup` does not error; it answers `nil` for every component, which
// is indistinguishable from "this design has no synthesizable parts".
//
// The return value is deliberately checked rather than discarded: a registration call that
// installs nothing looks exactly like one that works.
let installedHdlGenerators = BuiltinHdlWiring.installBuiltins()
if installedHdlGenerators.isEmpty {
  FileHandle.standardError.write(
    Data(("logisim-cli: no HDL generators were installed; every component would be treated as "
      + "non-synthesizable\n").utf8))
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("logisim-cli: \(message)\n".utf8))
  exit(code)
}

// ── Loader diagnostics are SURFACED, not merely recorded ────────────────────────────────────
//
// `HeadlessLoaderUI` records every `showError`/`showMessage` into two arrays. Until this pair of
// functions existed **nothing read them back**, so a file naming an unresolvable library loaded
// in total silence; the twenty-second recorded-and-never-surfaced seam in this port.
//
// ── What the jar does, measured, because the reading and the measurement disagree ────────────
//
// The brief for this change said the jar "logs `the built-in library #Risc-V is not available`"
// while the port prints nothing. **Half of that is wrong, and the wrong half is the interesting
// one.** Two fixtures, same shape, differing only in which loader error they trigger, run as
// `java -Djava.awt.headless=true -jar J -tty table <f>`:
//
//   fixture                        jar stderr                                          jar rc
//   ------------------------------ -------------------------------------------------- ------
//   <lib desc="bogus" name="98"/>  ERROR … OptionPane - File Error:baddesc: 0
//                                  Unrecognized library descriptor bogus
//   <lib desc="#Risc-V" name="99"/>  (nothing at all)                                       0
//   source="2.7.1"                 WARN … OptionPane - Old file format -- compatibility      0
//                                  mode:You are opening a file created with original …
//
// The jar is SILENT on the `#Risc-V` case. `Loader.showError` (`Loader.java:579`) branches on
// `description.contains("\n") || description.length() > 60`: the long branch wraps the text in a
// `JScrollPane` and hands *that* to `OptionPane.showMessageDialog`, whose headless arm is
// `else if (message instanceof String)` (`OptionPane.java:71`). A JScrollPane is not a String, so
// the message is dropped on the floor. `The built-in library “#Risc-V” is not available in this
// version.` is 63 characters. It loses by three.
//
// So upstream's diagnostic is suppressed exactly when it is longest, and the longest loader
// errors are the unresolvable-library ones, which are precisely the errors that cost the user
// components (D8: 14 components in, 13 out). That is not a behaviour to reproduce.
//
// ── The divergence, and its limit ────────────────────────────────────────────────────────────
//
// **Every recorded diagnostic is printed, whatever its length.** The message TEXT is upstream's
// byte for byte (`FileStrings`), including the `<project>: ` prefix `Loader.showError` prepends,
// so a script grepping for upstream's wording still matches; only the length-dependent silence is
// dropped.
//
// **Exit codes do not move.** The jar exits 0 with an unresolvable library and so does this: the
// file loaded, the table is correct for what resolved, and 39 corpus files are in this state, so
// making it nonzero would turn the whole migration gate red for a condition upstream tolerates.
// A diagnostic on stderr and an unchanged status is the combination that lets `rig.py` and
// `statsgate.py` keep diffing stdout untouched while a human still sees the warning.
//
// Order: messages before errors. Upstream emits the pre-2.7.2 warning from `XmlReader` during the
// parse and the library errors after it; the port's `Loader` drains `showMessages` only once the
// read returns, so the two channels are separate arrays here and the interleaving is gone either
// way. Upstream's emission order is the one reproduced, and it is pinned rather than incidental.
private func makeLoader() -> (loader: Loader, ui: HeadlessLoaderUI) {
  let ui = HeadlessLoaderUI()
  return (Loader(ui: ui), ui)
}

/// Print everything the loader recorded, and return how many were errors.
///
/// Called on the success path AND before every load-failure `fail`, because the recorded
/// diagnostics are usually the explanation for the failure; an exception message alone says
/// "could not open", the diagnostics say which library was missing.
@discardableResult
private func reportLoaderDiagnostics(_ ui: HeadlessLoaderUI) -> Int {
  for message in ui.messages {
    FileHandle.standardError.write(Data("logisim-cli: warning: \(message)\n".utf8))
  }
  for error in ui.errors {
    FileHandle.standardError.write(Data("logisim-cli: file error: \(error)\n".utf8))
  }
  return ui.errors.count
}

// ── The exit-code contract ──────────────────────────────────────────────────────────────────
//
// A grading script branches on these, so they are part of the interface and are pinned by
// `CliExitCodeTests`. Every value below was MEASURED against the 4.1.0 jar, not read off the
// Java: three of the five surprised the reading.
//
//   scenario                              jar   here   mechanism in upstream
//   ------------------------------------- ----- -----  -------------------------------------
//   `-tty stats` succeeded                  0     0    format becomes 0 -> TtyInterface:296
//   `-tty table` succeeded                  0     0    doTableAnalysis returns -> Startup:863
//   `-tty table` on an OSCILLATING circuit  0     0    rows print as all-E; see below
//   file will not parse / does not exist  255   255    System.exit(-1), TtyInterface:277
//   --toplevel-circuit names no circuit   255   255    NPE -> Startup.run catch -> exit(-1)
//   halt pin reached (runSimulation)        0    n/a   not ported; see the `--tty` guard
//   oscillation (runSimulation)             1    n/a   not ported; see the `--tty` guard
//   unknown -tty format                     0     2    DELIBERATE DIVERGENCE, see below
//   -tty with no value, or with no file    10     2    our own usage error
//   -tty csv (a modifier with no `table`)  hangs  2    DELIBERATE DIVERGENCE, see the `--tty`
//                                                      guard; measured, killed at a 20 s cap
//   a library the build cannot resolve      0     0    MATCHED. The diagnostic is new (stderr);
//                                                      the status deliberately is not.
//
// **`exit(-1)` in Java surfaces as 255**, because the process exit status is the low 8 bits.
// Reproducing 255 rather than "some nonzero" is the point: a script that already branches on
// upstream's codes keeps working against this binary.
//
// **Exit 1 belongs exclusively to `runSimulation`.** Measured on `2.7.1__case-514.circ::main`, the corpus'
// one confirmed oscillator: `-tty table` prints every output column as `0xEE`/`EEEE` and exits
// **0**. `doTableAnalysis` substitutes `Value.createError(width)` per row and returns 0
// unconditionally (TtyInterface:437-444, :454), so an oscillation is visible in the OUTPUT and
// never in the status. A grader must test the rows, not the code. Since `speed`/`halt` are not
// ported (see the `--tty` guard for the measurement), exit 1 is unreachable here as well, and
// saying that plainly is better than reserving a code nothing can produce.
//
// **The one deliberate divergence: an unrecognised `-tty` format.** Upstream exits **0**:
// `handleArgTty` returns `RC.QUIT`, `parseArgs` does `case QUIT: return startup` (Startup:410)
// , the object, not null, and `Main` then reads `startup.shallQuit()` and calls
// `System.exit(0)`. The javadoc on `shallQuit` literally says "requested app termination
// (w/o error)". Measured:
//
//     $ java -jar J -tty bogus golden-15.circ ; echo $?
//     [main] ERROR ... “--tty” requires at least one of the following: halt, speed, stats, ...
//     0
//
// So `logisim-cli --tty tabel lab.circ` under upstream's contract would print nothing, exit 0,
// and score every student in the loop as passing. That is the same silent-empty-output class
// this project has already been bitten by twice, and it is a large part of what #1546 is asking
// to have cleaned up. This binary exits 2.
private let exitOk: Int32 = 0
/// Java `System.exit(-1)` as the shell sees it.
private let exitLoadFailure: Int32 = 255
/// Usage / unparseable arguments. Upstream uses 10 here and 0 for an unknown format; see above.
private let exitUsage: Int32 = 2

// ── THE SoC BUS FABRIC IS PART OF LOADING, NOT PART OF SIMULATING ───────────────────────────
//
// Java's `Circuit` owns a `SocSimulationManager socSim` field and calls `registerComponent` from
// `mutatorAdd` (`Circuit.java:778`). The port cannot reproduce a stored property there,
// `Circuit` lives in `LogisimFile`, below `LogisimSoc`, and a Swift extension adds no storage,
// so `SocCircuitBinder` reproduces the three mutator calls from a `CircuitListener`, and is
// explicitly **session-scoped: somebody has to own one**. The app does (`LogisimFileProjectHost
// .socBinder`). This executable did not, and that is the defect this function closes.
//
// ── WHY IT IS A WRONG ANSWER RATHER THAN AN ERROR ───────────────────────────────────────────
//
// Nothing fails when the binder is missing. Every SoC component still loads, still resolves to
// its real factory, still has ends and bounds and attributes, and its live `SocBusInfo` keeps
// `simulationManager == nil` forever. Downstream that reads as an empty machine rather than a
// broken one:
//
//   * `SocMemoryState.performReadAction` → `regPropagateState()` is nil → the read returns
//     `Int32.random(in:)` (`SocMemoryState.swift:282`). A plausible word, every time, different
//     every run.
//   * `PioState.handleOutputWriteTransaction` → `regPropagateState()` is nil → the write is
//     dropped on the floor and the PIO's output pins keep their old value.
//   * `SocBusInfo.simulationManager` nil → `slaveName` answers `"BUG: Unknown"`.
//
// So a graded SoC submission produced output, exit 0, and no diagnostic: the exact shape this
// file's `--tty`-format guard and `--test-vector` exit code exist to prevent, arriving through a
// different door.
//
// ── WHY EVERY LOAD PATH GOES THROUGH ONE FUNCTION ───────────────────────────────────────────
//
// `--tty` and `--test-vector` each had their own `makeLoader()` + `openLogisimFile` + report
// block, identical line for line. Two copies is two places to forget the attach, and forgetting
// it in one is invisible; see above. There is now one, so there is exactly one line to delete
// to break this, and `--soc-fabric` observes the result of that same line.
//
// ── `--convert` DELIBERATELY DOES NOT USE THIS, AND THAT WAS MEASURED ───────────────────────
//
// Attaching a binder mutates only `SocBusInfo.simulationManager` / `.component`, both of which
// are runtime back-pointers; the codec writes `SocBusInfo` through `toStandardString`, which is
// the bus id and nothing else. So conversion output cannot move. Measured rather than argued:
// `--convert` run over each of the two files in existence that PLACE SoC components, once with
// the attach forced into the `--convert` branch and once without it (sha1 of the output):
//
//   file                                             without binder      with binder
//   -----------------------------------------------  ------------------  ------------------
//   the four-part SoC fixture (one of each part)      2fff1a75d24db261…   2fff1a75d24db261…
//   harvested/3.7.2__case-186.circ   69264d19c3c4033e…   69264d19c3c4033e…
//
// Byte-identical, so `--convert` keeps its own bare loader and the M2 gate is untouched. That is
// the claim the brief asked to be verified rather than assumed; this is the verification.
//
// ── AND THE WHOLE CHANGE, A/B'd OVER THE CORPUS ─────────────────────────────────────────────
//
// Pre-change and post-change binaries, both kept, run over the first 200 harvested files in
// `--tty table`, `--tty stats` and `--convert`:
//
//     attributed=436  self_unstable=141  capped=23  diffs=0  rc_diffs=0
//
// **`self_unstable` is not noise and it is not this change.** The PRE-change binary already
// disagrees with itself run to run on 141 of the 600 cases, so a plain A/B diff over this corpus
// is uninterpretable; the first attempt reported 141 "differences" that were nothing of the
// kind. Every case is therefore run twice on the OLD binary first and only self-stable cases are
// attributed. Measured cause, not guessed: `XmlReader.generateValidVHDLLabel` appends
// `UUID.randomUUID().toString().substring(0, 8)` when it repairs a pre-2.7.2 label, exactly as
// upstream does, so `N18-23` comes back as `N18_23_c2092403` and again as `N18_23_c0613cc0`.
// That is faithful, it is already documented at `XmlReader.swift:935`, and `labelSuffixProvider`
// exists precisely so a byte-comparison gate can pin it, which `rig.py` would need to do, and
// which is not this task's to change. `capped` is the 8-second per-invocation cap, hit by the
// large truth tables board #46 is about.

/// The one SoC session this process has, held for the life of the process.
///
/// `SocCircuitBinder` is the eviction owner for the per-`Circuit` managers, and `SocBusInfo`
/// holds its manager **weakly**, so if this reference is dropped, every fabric the load just
/// built deallocates and every peripheral silently returns to reading noise. A `let` inside a
/// `case` block is not enough: nothing reads it after the attach, so ARC is free to release it
/// before the first propagation.
///
/// This is not the process-global table `SocCircuitBinder`'s header rejects; that was a
/// `[ObjectIdentifier: SocSimulationManager]` with no eviction owner and an address-reuse
/// hazard. This is one session object, owned by the one session this process runs, released
/// when the process exits. It is the CLI's analogue of the app's per-document `socBinder`.
private var socSession: SocCircuitBinder?

/// Loads a file for SIMULATION: opens it, surfaces the loader's diagnostics, and gives every
/// circuit in it a live SoC bus fabric.
///
/// Every circuit, not only the top level: `SocSimulationManager` is per-`Circuit` upstream, and
/// a SoC design is routinely a subcircuit.
private func loadForSimulation(_ url: URL) -> LogisimFile {
  let (loader, ui) = makeLoader()
  let file: LogisimFile
  do {
    file = try loader.openLogisimFile(url)
  } catch {
    // The recorded diagnostics come first because they usually name the library the exception
    // only alludes to. 255, matching `System.exit(-1)` at TtyInterface:277 as the shell sees it.
    reportLoaderDiagnostics(ui)
    fail("\(url.lastPathComponent): \(error)", code: exitLoadFailure)
  }
  // Emitted BEFORE any stdout, so a `2>&1` capture reads in the order the jar's does, and on
  // stderr, so `rig.py`/`statsgate.py` keep diffing an unchanged stdout. Exit status is untouched
  // , see `reportLoaderDiagnostics`.
  reportLoaderDiagnostics(ui)

  let binder = SocCircuitBinder()
  for circuit in file.circuits { binder.attach(to: circuit) }
  socSession = binder
  return file
}

private func usage() -> Never {
  FileHandle.standardError.write(Data("""
    usage:
      logisim-cli --convert <in.circ> <out.circ>   load and re-save (M2 gate)
      logisim-cli --tty <formats> <file.circ>      headless verification; <formats> is a
                                                   comma-separated list of: table, stats
                                                   plus modifiers for table:
                                                     binary  every column in binary, with a space
                                                             every four bits (upstream's
                                                             Value.toString, not toBinaryString)
                                                     hex     every column in hex, no 0x prefix
                                                     csv     comma separated, unpadded
                                                     tabs    tab separated, unpadded
                                                   e.g. --tty table,csv  for a diffable table.
                                                   A modifier alone is refused: upstream accepts
                                                   it and then never terminates.
      logisim-cli --test-vector <circuit> <vectors.txt> <file.circ>
                                                   run a test-vector file and EXIT NONZERO if
                                                   any vector fails (upstream always exits 0)
      logisim-cli --hdl-generators                 list the HDL generators installed at startup
      logisim-cli --soc-fabric <file.circ>         report the SoC bus fabric THIS binary's own
                                                   load path built: which busses exist, which
                                                   peripherals reached one, and whether a bus
                                                   read is answered

    global options:
      --toplevel-circuit <name>   the circuit to act on; accepted before or after the command

    exit codes:
      0    the requested output was produced; for --test-vector, every vector passed
      1    --test-vector only: at least one vector failed
      2    usage error, including an unrecognised --tty format
      3    --hdl-generators only: the HDL generator registry was empty at startup
      4    --hdl-generators only: the FPGA map bindings were not installed at startup
      5    --soc-fabric only: a SoC component reached no SocSimulationManager, so the file
           would simulate with no bus fabric and every bus read would return noise
      255  the file could not be loaded, --toplevel-circuit named no circuit in it, or a
           --test-vector run could not be set up at all

""".utf8))
  exit(exitUsage)
}

// ── Global options are hoisted out before the command is dispatched ─────────────────────────
//
// Upstream's real syntax puts `--toplevel-circuit` BEFORE the subcommand:
//
//     java -jar logisim-evolution.jar --toplevel-circuit <c> -tty table <file>
//
// This parser originally accepted it only *after* `--tty table`, so every invocation the
// differential rig makes, and `rig.py` passes the flag on every case, hit the command switch
// with `--toplevel-circuit` in args[0] and died with "unknown command", exit 2. The rig scores a
// nonzero exit as a failed case, so its simulation mode reported **0 pass / 1392 fail** for its
// entire existence, and did so silently: an all-fail rig was the expected reading until M3
// landed, so nothing about the number looked wrong.
//
// The 1,026 byte-exact figure quoted for M3 comes from `TruthTableGoldenTests`, a *different*
// harness over the same golden set. Two gates over one corpus, one of them structurally dead:
// each half correct on its own, nothing owning the join.
//
// Parsing globals here, in one place, is what keeps the two entry points from drifting again.
var args = Array(CommandLine.arguments.dropFirst())
var toplevelOption: String?
if let i = args.firstIndex(of: "--toplevel-circuit"), i + 1 < args.count {
  toplevelOption = args[i + 1]
  args.removeSubrange(i...(i + 1))
}

guard let command = args.first else { usage() }

switch command {
case "--convert":
  guard args.count >= 3 else { usage() }
  let input = URL(fileURLWithPath: args[1])
  let output = URL(fileURLWithPath: args[2])

  // A fresh Loader per conversion, matching CircBridge. Sharing one lets library-resolution
  // state leak between files, which is the kind of order dependence that makes a baseline
  // irreproducible.
  let (loader, convertUI) = makeLoader()
  do {
    let file = try loader.openLogisimFile(input)
    // NOT `loadForSimulation`: a conversion is not a simulation, and the SoC binder it attaches
    // provably cannot move the bytes. Measured both ways on the four-part SoC fixture and on the
    // one corpus file that places SoC components: see the note above `loadForSimulation`.
    // Before the write, so a diagnostic is not lost if the write itself fails.
    reportLoaderDiagnostics(convertUI)
    guard loader.save(file, to: output) else {
      fail("could not write \(output.path)")
    }
  } catch {
    // Load failures are reported, never swallowed: upstream silently drops components whose
    // library it cannot resolve (measured: 14 components in, 13 out), and D8 exists so this
    // port does not repeat that. The recorded diagnostics come first because they usually name
    // the library the exception only alludes to.
    reportLoaderDiagnostics(convertUI)
    fail("\(input.lastPathComponent): \(error)")
  }

case "--tty":
  // `java -jar logisim-evolution.jar [--toplevel-circuit <c>] -tty table <file>`.
  //
  // This is the other half of the differential rig. `rig.py` compares this output against 1,392
  // golden oracles captured from the 4.1.0 jar, 7.6 million rows, which sat unused from M0
  // until the simulation kernel was wired, because nothing could run a circuit.
  //
  // ── Which formats are accepted, and why the refusal is still load-bearing ─────────────────
  //
  // Upstream's `-tty` takes a comma-separated list and ORs the bits together
  // (`Startup.handleArgTty`): `table`, `stats`, `speed`, `halt`, `tty`, plus four MODIFIERS,
  // `binary`, `hex`, `csv`, `tabs`, which reshape what `table` prints.
  //
  // `table`, `stats` and all four modifiers are implemented, and each is gated against the jar
  // (`tools/difftest/ttybridge/tablefmtgate.py` covers the modifiers, over the same corpus as the
  // plain table). `speed`, `halt` and `tty` are REFUSED rather than accepted-and-ignored, and that
  // guard predates this change: accepting a format and printing nothing for it reads as a passing
  // run that produced no output, which is the failure mode this project has had to dig out of
  // twice (once an md5 of two EMPTY outputs scored a case OK). The refusal is what keeps that from
  // recurring, so it stays; narrowed to the three formats that genuinely are not implemented.
  //
  // ── A modifier with no `table` is refused too, and THAT is a divergence ────────────────────
  //
  // A modifier alone sets no `FORMAT_TABLE` bit, so upstream's `format == 0` early exit does not
  // fire and `(format & FORMAT_TABLE) != 0` is false: control reaches `runSimulation`, whose
  // `while (true)` has no exit without an output pin labelled `halt`. Measured on the AND-gate
  // fixture, 20-second cap, all four killed at the cap with no output:
  //
  //     -tty csv | -tty tabs | -tty binary | -tty hex   ->  runs forever, prints nothing
  //     -tty stats,csv                                  ->  prints the stats, then runs forever
  //
  // So `--tty csv lab.circ` under upstream's contract is a grading loop that hangs. This binary
  // exits 2 and names the spelling that works. Deliberately NOT implied-`table`: inventing a
  // meaning upstream has not defined is how two implementations of one flag drift, and a one-line
  // message costs the user one retry.
  //
  // ── `speed` and `halt`: measured, and the answer is no ────────────────────────────────────
  //
  // Both report on `TtyInterface.runSimulation`, and `TtyInterface.run` only routes there when
  // the circuit has an OUTPUT PIN LABELLED EXACTLY `halt` (`:315-318`). Without one, the loop's
  // `while (true)` has no exit but an oscillation, so a healthy circuit runs forever. Measured:
  // `-tty speed` on `golden-15.circ` printed nothing and was still running when killed at 15 s.
  //
  // So the answerable population is "corpus circuits with a `halt` output pin", and
  // `tools/difftest/ttybridge/find_halt.py` enumerates it over all 591 parseable files:
  //
  //     8 pins labelled 'halt'; 6 of them are OUTPUT pins
  //
  // `probe_halt.py` then ran the jar on all 6. **Four fail to load at all** (each needs a sibling
  // `.circ` the harvest did not capture, so the jar tries to pop a JFileChooser and dies with
  // HeadlessException, exit 255) and **two did not terminate in 40 s**. Zero produced output.
  //
  // That is the whole case: there is not one corpus case against which a `speed` or `halt`
  // implementation could be diffed, so porting them would add exactly the untested scaffolding
  // the gate exists to prevent. `speed` additionally reports wall-clock Hz, which is not
  // byte-comparable against anything. Revisit if a corpus with `halt`-terminating circuits shows
  // up; the entry point is `runSimulation` and nothing else here has to change.
  //
  // `tty` needs the `Tty`/`Keyboard` components plus a stdin reader thread, and its output is
  // interactive by construction.
  //
  // The four modifiers now live in `LogisimStd/Simulation/TruthTableRun.swift`. The handover note
  // called them "one `switch` inside `TruthTableRun.valueFormat`"; that was checked before being
  // believed and it is HALF right; `csv` and `tabs` are not in `valueFormat` at all, they are the
  // separator *and* the padding in `displayTableRow`. See `TruthTableRun.TableFormat`.
  guard args.count >= 3 else {
    fail("usage: logisim-cli --tty <formats> [--toplevel-circuit <name>] <file.circ>",
      code: exitUsage)
  }

  // `ttyVal.split(",")` then `singleFmt.trim()`, exactly as `handleArgTty` does it. Java's
  // one-argument `split` drops trailing empty fields (D15a), so `-tty "table,"` is a
  // single-element list upstream; `filter { !$0.isEmpty }` reproduces that for this use without
  // pulling `javaSplitOnLiteral` into the executable.
  let requested = args[1]
    .split(separator: ",", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
  guard !requested.isEmpty else {
    fail(
      "--tty: no format given; expected a comma-separated list of: stats, table"
        + " (table may be modified by binary, hex, csv, tabs)",
      code: exitUsage)
  }
  /// Formats that produce output on their own.
  let implemented: Set<String> = ["table", "stats"]
  /// Modifiers: legal only alongside `table`, because on their own upstream hangs (see above).
  let tableModifiers: Set<String> = ["binary", "hex", "csv", "tabs"]
  // Named separately from "never heard of it" so the message can say WHY. `-tty speed` is a real
  // upstream format and being told "unknown format" would send a reader looking for a typo.
  let knownUnimplemented: Set<String> = ["speed", "halt", "tty"]
  let accepted = "Implemented: stats, table; table modifiers: binary, hex, csv, tabs"
  for format in requested where !implemented.contains(format) {
    if tableModifiers.contains(format) {
      // Only reachable when `table` is absent; otherwise the modifier is legal. Upstream reaches
      // `runSimulation` here and never returns; measured at a 20 s cap on all four.
      guard requested.contains("table") else {
        fail(
          "--tty: '\(format)' modifies the truth table and does nothing on its own — write "
            + "'--tty table,\(format)'. (Upstream accepts '-tty \(format)' and then runs forever "
            + "without printing anything; measured on the 4.1.0 jar.)",
          code: exitUsage)
      }
      continue
    }
    if knownUnimplemented.contains(format) {
      fail(
        "--tty: '\(format)' is an upstream format that is deliberately not implemented — see the "
          + "note in logisim-cli/main.swift. \(accepted)",
        code: exitUsage)
    }
    fail("--tty: unknown format '\(format)'. \(accepted)", code: exitUsage)
  }
  // Resolved in upstream's own test order, so `table,csv,tabs` picks tabs and `table,binary,hex`
  // picks binary: both measured against the jar. See `TruthTableRun.TableFormat`.
  let tableFormat = TruthTableRun.TableFormat(modifiers: Set(requested))

  // `--toplevel-circuit` is what turns 12 file-level oracles into 100 circuit-level ones, so the
  // rig passes it constantly. Absent, upstream falls back to the file's main circuit.
  //
  // Accepted in either position: hoisted above if it preceded the subcommand (upstream's own
  // order), and still parsed here if it trails it.
  var toplevel: String? = toplevelOption
  var path: String?
  var i = 2
  while i < args.count {
    if args[i] == "--toplevel-circuit", i + 1 < args.count {
      toplevel = args[i + 1]
      i += 2
    } else {
      path = args[i]
      i += 1
    }
  }
  guard let path else { fail("--tty: no input file given", code: exitUsage) }

  let ttyInput = URL(fileURLWithPath: path)

  // The file is loaded ONCE and shared by every requested format, which is what upstream does
  // (`TtyInterface.run` loads before it looks at `getTtyFormat()`), and it is why `stats,table`
  // is cheaper than two invocations.
  //
  // `loadForSimulation`, not a bare `openLogisimFile`: this is the grading path, and without the
  // SoC binder every bus read on it answers noise rather than failing. See the function.
  let ttyFile = loadForSimulation(ttyInput)

  // Order is upstream's, not the order the user typed: `TtyInterface.run` emits statistics first
  // (`:291-294`), clears the bit, and only then decides whether any simulation remains. So
  // `-tty table,stats` and `-tty stats,table` produce identical bytes, and this reproduces that.
  do {
    if requested.contains("stats") {
      let text = try StatsRun.run(file: ttyFile, circuitName: toplevel)
      FileHandle.standardOutput.write(Data(text.utf8))
    }
    if requested.contains("table") {
      let text = try TruthTableRun.run(
        file: ttyFile, circuitName: toplevel, format: tableFormat)
      FileHandle.standardOutput.write(Data(text.utf8))
    }
  } catch {
    // `--toplevel-circuit` naming a circuit the file does not have lands here. Upstream NPEs,
    // `Analyze.getPinLabels` on a null circuit for `table`, `FileStatistics.doSimpleCount` for
    // `stats`, and `Startup.run`'s `catch (Exception)` turns that into exit(-1) = 255. Both were
    // measured; reproducing the code exactly is what lets an existing grading script keep
    // working, and D13 is why this arrives as a `throw` rather than a trap.
    fail("\(ttyInput.lastPathComponent): \(error)", code: exitLoadFailure)
  }

case "--test-vector":
  // `java -jar logisim-evolution.jar --test-vector <circuit> <vectors.txt> <file.circ>`, with
  // upstream's argument order preserved so a script written against the jar keeps working.
  //
  // See TestVectorRun.swift for what upstream does with these arguments and why it is unusable:
  // the flag throws HeadlessException before printing anything, and even with a display
  // `Startup.java:1029` discards `doTestVector`'s return and then exits 0 unconditionally.
  //
  // Circuit selection here is `Project.doTestVector`'s, not `TtyInterface.run`'s: the name is a
  // positional argument, and `--toplevel-circuit` is accepted as a synonym so the three verbs of
  // this CLI select a circuit the same way.
  guard args.count >= 4 || (toplevelOption != nil && args.count >= 3) else {
    fail(
      "usage: logisim-cli --test-vector <circuit> <vectors.txt> <file.circ>", code: exitUsage)
  }
  let vectorCircuit: String
  let vectorFile: String
  let vectorCirc: String
  if let toplevelOption, args.count == 3 {
    vectorCircuit = toplevelOption
    vectorFile = args[1]
    vectorCirc = args[2]
  } else {
    vectorCircuit = args[1]
    vectorFile = args[2]
    vectorCirc = args[3]
  }

  let vectorInput = URL(fileURLWithPath: vectorCirc)
  // Same loader as `--tty`, for the same two reasons: a submission naming a library this build
  // cannot resolve is exactly the case a grader needs to see BEFORE reading a pass/fail tally
  // computed from whatever did resolve, and a SoC submission whose peripherals reached no bus
  // fabric produces a tally computed from random words.
  let loadedForVectors = loadForSimulation(vectorInput)

  do {
    let outcome = try TestVectorRun.run(
      file: loadedForVectors, circuitName: vectorCircuit, vectorPath: vectorFile)
    FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
    // THE WHOLE REASON THIS SUBCOMMAND EXISTS. Upstream reaches
    // `if (exitAfterStartup) System.exit(0);` regardless of the result, so a grading loop
    // branching on `$?` scores every submission as passing. Clamped to 0/1 rather than passing
    // the failure COUNT out, because a process status is taken mod 256 and a run with exactly
    // 256 failures would exit 0: the same silent success, reintroduced by arithmetic.
    exit(outcome.failed == 0 ? exitOk : 1)
  } catch let failure as TestVectorRun.Failure {
    // `Project.doTestVector` / `TestThread.doTestVector` return -1 for a missing circuit, an
    // unreadable vector file, or a pin binding that cannot be made. -1 is 255 to the shell, and
    // that is the code used here so "the test could not be run" is distinguishable from "the
    // test ran and something failed".
    fail("\(failure)", code: exitLoadFailure)
  } catch {
    fail("\(vectorInput.lastPathComponent): \(error)", code: exitLoadFailure)
  }

case "--hdl-generators":
  // The observable form of "the registration at the top of this file actually ran".
  //
  // It reads `HdlGeneratorLookup.shared` and does NOT install anything itself; that distinction
  // is the whole point. `BuiltinHdlWiringInstallationTests` runs this subcommand as a subprocess
  // and asserts a non-empty list; delete the `installBuiltins()` call above and this prints
  // nothing, exits 3, and that test goes red. A test that called `installBuiltins` itself would
  // stay green with the startup call gone, which is precisely the failure this project keeps
  // shipping.
  //
  // `isInstalled` is the queryable form of the gap, and this is the one place that consults it,
  // so it is load-bearing rather than decorative: it answered `false` for as long as nothing
  // called the builder, and must answer `true` here.
  guard BuiltinHdlWiring.isInstalled else {
    fail(
      "no HDL generators are registered — BuiltinHdlWiring.installBuiltins() was not called at "
        + "startup", code: 3)
  }
  let names = HdlGeneratorLookup.shared.registeredFactoryNames.sorted()
  FileHandle.standardOutput.write(Data((names.joined(separator: "\n") + "\n").utf8))

  // The FPGA map bindings are a SECOND registration, installed on the line after the generators
  // in `installBuiltins`. Reporting only the generator names would have proved the first call ran
  // and said nothing about the second: and those bindings spent their whole existence gated at
  // 224 MAPINFO rows inside a test target while production installed none of them.
  //
  // Counted, not listed: the count is what a test can assert, and it distinguishes "installed"
  // from "installed nothing", which an empty registry does not.
  // `FpgaStdIoFacts.isConfigured` is the second installer's observable form. The FPGA author left
  // it there explicitly "to be asserted", which is the right instinct: a provider that is
  // half-filled or unfilled otherwise looks exactly like one that is complete.
  FileHandle.standardError.write(
    Data("fpga std-io facts configured: \(FpgaStdIoFacts.shared.isConfigured)\n".utf8))
  if !FpgaStdIoFacts.shared.isConfigured {
    fail(
      "the FPGA map bindings were not installed at startup — every factory then answers nil for "
        + "map information, which is indistinguishable from a design with no mappable I/O",
      code: 4)
  }

case "--soc-fabric":
  // ── THE OBSERVABLE FORM OF "the binder at `loadForSimulation` actually ran" ────────────────
  //
  // Exactly the role `--hdl-generators` plays for `BuiltinHdlWiring.installBuiltins()`, and it
  // exists for the same reason: the registration it reports on is made by an *executable's*
  // startup, so the only test that can prove it is one that runs an executable and looks at what
  // that executable's own load left behind. A test that constructs a `SocCircuitBinder` itself is
  // a test of `SocCircuitBinder`; `LogisimSocTests` already has several, and every one of them
  // was green throughout the entire life of this defect.
  //
  // ── THIS BRANCH INSTALLS NOTHING, and that is what keeps the test non-circular ─────────────
  //
  // It never names `SocCircuitBinder`, never calls `attach`, and never calls `registerComponent`.
  // Everything below is read off the COMPONENTS: `SocSimulationManager.socBusSelect` /
  // `SocBusAttributes.socBusId` are live `SocBusInfo` objects carried by the components
  // themselves, and `simulationManager` is the exact `weak` field whose nil-ness makes
  // `SocMemoryState.performReadAction` return `Int32.random`. If the attach in
  // `loadForSimulation` is deleted, every line below flips to `fabric=DETACHED` and this exits 5.
  //
  // ── WHY `bus-read` DOES NOT PRINT THE DATA ────────────────────────────────────────────────
  //
  // It cannot be deterministic: the CLI has no `CircuitState`, so `SocSimulationManager
  // .data(for:)` is nil even with a live fabric and the memory's read falls through to
  // `Int32.random` anyway. What IS deterministic, and what actually distinguishes a live fabric
  // from an absent one, is whether a slave *answered*: the error code and the responder. Those
  // are printed; the word is not. Printing a random number as if it were evidence is the failure
  // mode this whole subcommand exists to expose.
  //
  // Side effect, stated because it is real: `initializeTransaction` runs upstream's
  // `drainPendingOnTransaction`, which blanks a `SocBusSelection` naming a bus that is not there
  // (SocSimulationManager.java:252-269). In-memory only; this subcommand never writes a file.
  //
  // `--toplevel-circuit` is accepted (it is hoisted out above with every other command) and
  // deliberately IGNORED: `SocSimulationManager` is per-`Circuit` upstream and a SoC design is
  // routinely a subcircuit, so reporting one circuit would hide exactly the case this is for.
  guard args.count >= 2 else {
    fail("usage: logisim-cli --soc-fabric <file.circ>", code: exitUsage)
  }
  let fabricInput = URL(fileURLWithPath: args[1])
  let fabricFile = loadForSimulation(fabricInput)

  var out = ""
  var detached = 0
  for circuit in fabricFile.circuits {
    let socComponents = circuit.nonWires.filter { $0.factory is any SocInstanceFactory }
    out += "circuit \(circuit.name): soc-components=\(socComponents.count)\n"

    // Reached through the components, never through the binder, see above.
    var managers: [String: SocSimulationManager] = [:]
    for component in socComponents {
      guard let factory = component.factory as? any SocInstanceFactory else { continue }
      let attributes = component.attributeSet
      // A bus carries its identity in `SocBusIdentifier`; everything else in `SocBusSelection`.
      let info: SocBusInfo? =
        factory.isSocBus
        ? attributes.getValue(SocBusAttributes.socBusId)
        : attributes.getValue(SocSimulationManager.socBusSelect)
      // A SoC factory carrying NEITHER bus attribute has nothing to attach and is reported as
      // `n/a` rather than counted; an absent attribute is not a failed registration, and
      // conflating the two would make this subcommand cry wolf on a future factory.
      guard let info else {
        out += "  \(factory.name) \(SocSupport.componentName(component)) bus=n/a fabric=n/a\n"
        continue
      }
      let busId = info.busId
      // `registerComponent` attaches the manager UNCONDITIONALLY for any component carrying the
      // attribute: including one whose bus id is still empty (`SocSimulationManager.swift`, the
      // `containsAttribute(socBusSelect)` branch). So "has the attribute but no manager" is
      // exactly and only "the binder never ran"; the bus id does not enter into it.
      let bound = info.simulationManager != nil
      if let manager = info.simulationManager, !busId.isEmpty { managers[busId] = manager }
      if !bound { detached += 1 }
      out += "  \(factory.name) \(SocSupport.componentName(component)) bus=\(busId) "
        + "fabric=\(bound ? "attached" : "DETACHED")\n"
    }

    // `sorted()` is load-bearing: `Dictionary` seeds its hashing per process, so an unsorted
    // iteration makes this diagnostic disagree with itself between runs of the same binary.
    // Pinned by `theDiagnosticIsDeterministic`, whose two-bus fixture exists for this line.
    for busId in managers.keys.sorted() {
      guard let manager = managers[busId] else { continue }
      let fabric = manager.busFabric(busId)
      // No sniffer count: `SocBusFabric.sniffers` is private, and none of the eight ported
      // factories returns a `snifferInterface` today, so the number would be a constant zero
      // dressed as a measurement.
      out += "  bus \(busId): live=\(fabric?.component != nil) "
        + "slaves=\(fabric?.slaves.count ?? 0)\n"

      let probe = SocBusTransaction(
        kind: .read, address: 0, writeData: 0, accessType: .word, initiator: "logisim-cli")
      manager.initializeTransaction(probe, busId: busId, circuitState: nil)
      let responder = probe.responder.map(SocSupport.componentName) ?? "none"
      out += "  bus-read \(busId) @0x00000000: responder=\(responder) "
        + "error=\(probe.error.description)\n"
    }
  }
  FileHandle.standardOutput.write(Data(out.utf8))

  if detached > 0 {
    fail(
      "\(detached) SoC component(s) carry a bus attribute and reached no SocSimulationManager "
        + "— no SocCircuitBinder was attached at load, so this file would simulate with no bus "
        + "fabric and every bus read would return noise instead of failing", code: 5)
  }

case "-h", "--help":
  usage()

default:
  fail("unknown command '\(command)'", code: 2)
}
