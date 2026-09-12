// M3 gate: the ported simulation kernel must reproduce the Java `-tty table` oracle.
//
// 1,392 golden files / 7.6M rows were generated from the shipped 4.1.0 jar over the whole
// corpus by `tools/difftest/rig.py --regenerate`, using exactly:
//
//     java -Djava.awt.headless=true -jar logisim-evolution-4.1.0-all.jar \
//          --toplevel-circuit <name> -tty table <file.circ>
//
// and had never been compared against the port even once, because nothing could run a
// simulation. This suite is that comparison. It reads the golden set from the corpus rather
// than spawning a JVM, for the same reason `ValueGoldenTests` does.
//
// The corpus lives outside the repo (private coursework; the tables are effectively lab
// solutions: see docs/decisions.md):
//
//     LOGISIM_CORPUS=/path/to/corpus swift test
//
// ── How this suite EXECUTES: one always-on tier, one opt-in tier ────────────────────────────
//
// `corpusSmoke` always runs (given a corpus). `corpusScoreboard`, the full 1,391-oracle sweep,
// runs only under `LOGISIM_M3_SWEEP=1`, and `tools/ci.sh` runs it in **release**. See the comment
// on `sweepRequested` for the measurements behind that split; the short version is that the sweep
// was a 3,283 s test inside a 272 s suite, and the defect class this repo actually keeps hitting
// (five parallel-execution races: #34, #40, #60, #67, #74) is only findable by running the whole
// suite five or more times.
//
// ── Why this reports a scoreboard instead of asserting every case ───────────────────────────
//
// The port cannot yet reproduce every corpus circuit byte-for-byte, and some of what remains is
// upstream behaviour the port matches rather than port defects (see `Outcome.unreproducibleLabel`
// for oracles the Java itself cannot reproduce twice). A suite that asserted 1,392 equalities
// would be red for known-and-recorded reasons and would therefore stop being read.
//
// So: the *ratchet* is asserted (a floor that must not regress) and the full breakdown is
// printed. Raise the floor whenever it moves. That keeps the number honest and keeps the signal
// alive, which a permanently-red gate does not.
//
// **Stale claim removed, for the record.** This header used to say hierarchical designs were "out
// of reach by construction" because `CircuitSubcircuitFactory.computePorts` was unimplemented and
// needed `CircuitAppearance` at M6. Both halves are now false: `computePorts` is implemented and
// corpus-validated (`SubcircuitPortCorpusTests`, 786 placements, none portless), and
// `SubcircuitPropagation` drives them. A note like that is worth more than a passing test when it
// is true and actively harmful once it is not; it was the standing reason for nobody to look at
// the largest block of mismatches in the scoreboard.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import CryptoKit
import Foundation
import LogisimFile
import LogisimKernel
import Testing

@testable import LogisimStd

// MARK: - Corpus access

private func corpusDirectory() -> URL? {
  guard let path = ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] else { return nil }
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
    isDirectory.boolValue
  else { return nil }
  return URL(fileURLWithPath: path)
}

/// One entry of `golden/_inventory.json`, written by `rig.py`.
private struct GoldenEntry: Decodable {
  let file: String
  let circuit: String
  let golden: String
  let lines: Int
}

private func inventory(_ corpus: URL) -> [GoldenEntry] {
  let url = corpus.appendingPathComponent("golden/_inventory.json")
  guard let data = try? Data(contentsOf: url),
    let decoded = try? JSONDecoder().decode([String: GoldenEntry].self, from: data)
  else { return [] }
  // Deterministic order so a truncated run is reproducible.
  return decoded.values.sorted { $0.golden < $1.golden }
}

// MARK: - Oracles the jar cannot reproduce against itself

/// `file::circuit` keys whose oracle is not reproducible by the Java jar, keyed to the class of
/// nondeterminism observed. Written by `tools/difftest/nondet.py` from **N real runs of the jar
/// over the same bytes**; see `Outcome.unreproducibleOracle` for why this is measured rather
/// than derived from static reachability of a seed-0 `Random`.
///
/// Located from `#filePath` rather than an env var: the file is committed alongside the tool that
/// writes it, so it travels with the repo, while the corpus it describes deliberately does not.
private let unreproducibleOracles: [String: String] = {
  let here = URL(fileURLWithPath: #filePath)          // …/swift/Tests/LogisimStdTests/<this>
  let repo =
    here
    .deletingLastPathComponent()  // LogisimStdTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // swift
    .deletingLastPathComponent()  // repo root
  let url = repo.appendingPathComponent("tools/difftest/nondeterministic.json")
  struct Payload: Decodable {
    struct Case: Decodable { let `class`: String }
    let cases: [String: Case]
  }
  guard let data = try? Data(contentsOf: url),
    let decoded = try? JSONDecoder().decode(Payload.self, from: data)
  else { return [:] }
  return decoded.cases.mapValues { $0.class }
}()

/// `rig.py` runs the JVM with `cwd = dirname(path)` and passes `basename(path)`, so a golden
/// entry's `file` is a bare name, and **two corpus files can share one**. `rig.py`'s own
/// `golden_name` comment records that it hit exactly this ("two corpus files can share a basename
/// and a circuit name, which collides even with a hash of the basename key") and fixed it by
/// keying the golden name on the *full* path.
///
/// So picking the first file whose basename matches silently compares a circuit against another
/// file's oracle. That is not hypothetical: it accounted for a visible block of the first run's
/// "mismatches", showing up as anonymised labels whose hash suffixes differed
/// (`A_xor_B_5bfcc498` against `A_xor_B_5b4698b9`): two near-identical harvested copies, with
/// the port being blamed for reading the one it was handed.
///
/// The disambiguator is already in the golden filename: `rig.py` ends it with
/// `sha256(abspath + "__" + circuit)[:8]`, so the candidate whose digest reproduces the entry's
/// is exactly the file the oracle ran on.
private func locate(_ entry: GoldenEntry, in corpus: URL) -> URL? {
  let candidates =
    ["", "harvested"]
    .map { sub -> URL in
      sub.isEmpty
        ? corpus.appendingPathComponent(entry.file)
        : corpus.appendingPathComponent(sub).appendingPathComponent(entry.file)
    }
    .filter { FileManager.default.fileExists(atPath: $0.path) }

  guard candidates.count > 1 else { return candidates.first }

  // `golden_name` builds `"{safe[:160]}__{digest}.table"`, so the digest is the last `__`-run.
  let stem = (entry.golden as NSString).deletingPathExtension
  guard let digest = stem.components(separatedBy: "__").last else { return candidates.first }

  for candidate in candidates {
    let key = candidate.standardizedFileURL.path + "__" + entry.circuit
    if sha256Prefix8(key) == digest { return candidate }
  }
  return candidates.first
}

/// `hashlib.sha256(key.encode()).hexdigest()[:8]`.
private func sha256Prefix8(_ key: String) -> String {
  SHA256.hash(data: Data(key.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Outcome accounting

private enum Outcome {
  case match
  /// Too many rows to be worth running in a unit test. `1 << 18` rows at ~20 columns is a
  /// multi-minute run *per file* and tells you nothing a 16-row file does not; the cap keeps the
  /// gate usable and is reported rather than hidden.
  case skippedForSize
  /// The tables agree except for a column *name* carrying a random UUID suffix.
  ///
  /// **These goldens are not reproducible by the Java oracle either, and that is upstream
  /// behaviour, not corpus damage.** `XmlReader.generateValidVHDLLabel` repairs a label that is
  /// not a legal VHDL identifier, `Q'` becomes `Q`, and, *if it changed anything*, appends
  /// `UUID.randomUUID().toString().substring(0, 8)` with dashes turned to underscores
  /// (`XmlReader.java:717`, `:758`). So `-tty table` on such a file emits a different header on
  /// every run of the same jar over the same bytes.
  ///
  /// The port reproduces this faithfully (`XmlReader.swift:932`), which is why it shows up here
  /// at all. Counting it as a mismatch would permanently blame the port for matching upstream;
  /// counting it as a match would hide a real header difference. So it is its own bucket, and it
  /// is only awarded when *every other line is byte-identical* and the headers agree after the
  /// 8-hex-digit suffixes are masked.
  case unreproducibleLabel
  /// The oracle itself is not reproducible: running the **same jar over the same bytes** N times
  /// produces N different tables, and they still differ once the UUID suffixes are masked. So the
  /// column *values* move, not just a column name.
  ///
  /// Cause is `Random.StateData.getRandomSeed` (4.1.0, `std/memory/Random.java:103-115`): seed 0
  /// is the default and means "use `System.currentTimeMillis()`". The port reproduces this
  /// faithfully, so a byte comparison can never pass; there is no stable answer to compare to.
  ///
  /// **Membership is measured, never inferred.** `tools/difftest/nondet.py` hashes N real runs of
  /// the jar; it is not a static search for circuits that place a seed-0 `Random`. That static
  /// detector was written and it is wrong: it flagged `3.6.0__case-458.circ::MoveCore`, which then
  /// passed byte-exactly once an unrelated ROM defect was fixed. Whether the nondeterminism
  /// reaches an output column is circuit-dependent.
  case unreproducibleOracle
  case mismatch(String)
  /// The file would not load. A loader defect, not a simulation one; kept separate so the
  /// simulation number is not flattered or blamed by it.
  case loadFailed(String)
  /// The run threw. Almost always a not-yet-ported component or a hierarchical circuit.
  case runFailed(String)
}

/// Row cap. Override with `LOGISIM_M3_MAX_ROWS`; the corpus median is 17 rows and 1,282 of the
/// 1,391 oracles are under 4,096.
///
/// ── M9: the cap was reviewed against measurement, and it stays at 4,096 ─────────────────────
///
/// The cap exists for **time, not correctness**, `.skippedForSize` says so, so it should move
/// whenever the time does. M9 asked whether bitsliced evaluation could make it move. It cannot:
/// `TruthTableRun`'s header records why row bitslicing is unsound for this component set, and
/// the sweep is therefore no faster than it was. **A cap that exists because of time must not be
/// raised on a change that did not change the time.**
///
/// What it costs to raise it, measured rather than guessed. The sweep does **221,446 rows in
/// 2,994 s = 74 rows/s** (2026-09-06, debug, whole corpus). Row counts come from the inventory,
/// so these totals are exact; the hours are *optimistic*, because they assume the aggregate rate
/// holds for the skipped set, and it does not, since 90 of those 109 oracles hold a sequential
/// component and the slowest cases in the sweep run at 5–10 rows/s, not 74.
///
///     cap        oracles run   skipped   rows        hours @74 rows/s
///     4,096      1,282         109         221,446    0.8      (today)
///     8,193      1,319          72         446,726    1.7
///     16,385     1,330          61         626,950    2.4
///     32,769     1,337          54         856,326    3.2
///     65,537     1,363          28       2,560,262    9.6
///     131,073    1,381          10       4,919,558   18.5
///     262,145    1,391           0       7,540,998   28.3      (no cap)
///
/// Read the first and last rows together: **the cap hides 7.8% of the oracles and 97% of the
/// rows.** That is the honest shape of the gap, and it is why "1,252 of 1,282" overstates
/// coverage.
///
/// **Two measured changes would justify moving it, and neither is in this file:**
///
///   * ~~**Run the gate in release.**~~ **DONE; see `sweepRequested`.** `tools/ci.sh` now runs the
///     sweep under `-c release -Xswiftc -enable-testing`, measured at **3283.3 s → 704.6 s over
///     the whole sweep, 4.66×** (`2.7.1__case-438.circ::CPU` alone: 219.3 s → 50.3 s), with the scoreboard
///     identical line for line. Note the numbers moved from the 212.7/43.3 pair recorded here:
///     that was one case timed alone, this is the same case inside the full sweep, and release
///     now carries `-enable-testing`, which is mandatory for `@testable import` and costs some
///     optimisation. **The 4.66× is the one to plan against**; it is what CI actually runs.
///   * **Fix `SimulatableComponent.wireEnds`.** `InstanceStateImpl.end(at:)` rebuilds and discards
///     the component's whole `[WireEndInfo]` array on every port read and write. Caching the
///     projection took the same case from 212.7 s to **134.8 s, 1.58×**, again byte-identical.
///     Reported, not fixed here; it is outside this slice.
///
/// Together those put cap 32,769, **+55 oracles, 109 skips down to 54**, inside the time the
/// gate already takes today. That is the move to make once they land; making it now would take
/// the sweep from 50 minutes to over three hours and nobody would run it.
///
/// **Half of that is now real, and the cap still does not move here.** With the sweep running in
/// release at 314 rows/s, the 3.2 h estimate for cap 32,769 becomes roughly 856,326 / 314 ≈ 45
/// min: arithmetic on the measured aggregate rate, not a timed run, and optimistic for the same
/// reason the table above is. That is a defensible CI cost and a straightforward `LOGISIM_M3_MAX_ROWS`
/// away, since the cap is already an env override. It is deliberately NOT taken here: #46 decided
/// this number on measurement, moving it is that task's call and not this one's, and it should be
/// decided against a real timed run rather than a division. Raising the cap is also strictly an
/// increase in coverage; nothing in this slice depends on it.
private let maxRows: Int = {
  ProcessInfo.processInfo.environment["LOGISIM_M3_MAX_ROWS"].flatMap(Int.init) ?? 4096
}()

private func envFlag(_ name: String) -> Bool {
  guard let raw = ProcessInfo.processInfo.environment[name]?
    .trimmingCharacters(in: .whitespaces).lowercased()
  else { return false }
  return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
}

/// Whether the full 1,391-oracle sweep runs. **Opt-in, and this is the settled answer to #61/#71.**
///
/// ── The two facts pull opposite ways, so measure both ───────────────────────────────────────
///
/// Everything below was run on this tree, this machine (18 cores, Swift 6.3.3), 2026-09-06, with
/// `LOGISIM_CORPUS` set. Wall seconds, `/usr/bin/time -p`:
///
///     cold `swift build --build-tests`                                    20.61 s
///     cold `swift build -c release --build-tests -Xswiftc -enable-testing` 126.96 s
///     full `swift test`, debug, sweep ON      3287.55 s   (the sweep itself 3283.3 s)
///     full `swift test`, debug, sweep OFF      272.58 s   ← the new default
///     release `--filter corpusScoreboard`      775.74 s   (the sweep itself  704.6 s)
///
/// Both full-suite runs report **1,132 tests in 112 suites, green**: the sweep test still runs
/// either way, it just returns early. And the sweep is **4.66× faster in release**: 3283.3 s to
/// 704.6 s, 67 rows/s to 314 rows/s over the same 221,446 rows. Per case, the one #71 named:
/// `2.7.1__case-438.circ::CPU`, 2,048 rows, **219.3 s debug → 50.3 s release**.
///
/// ── The two things #71 said to check rather than assume ─────────────────────────────────────
///
/// **Does the release compile eat the saving for a one-shot CI run?** No, and not close. The
/// release test build costs 126.96 s cold and buys 2,578.7 s of sweep: a 20:1 return, on a build
/// that is incremental on every run after the first. Whole release step, cold: 902.70 s ≈ 15.0
/// min, against 54.7 min for the same work in debug.
///
/// **BUT `-c release` alone does not build this package's tests at all.** Release drops
/// testability, so every `@testable import` fails with "module was not compiled for testing";
/// `swift build -c release --build-tests` dies in 10.53 s on `LogisimVhdlTests` and
/// `LogisimKernelTests`. `-Xswiftc -enable-testing` is mandatory, and it is not free; it keeps
/// internal symbols visible and costs some cross-module optimisation. Every release number here
/// is measured **with** the flag, because that is the only build CI can actually run.
///
/// **Does `-c release` change anything this gate depends on?** No: verified, not asserted. The
/// two scoreboards are identical line for line:
///
///     debug    1391 oracles · 109 skipped · 1282 attempted · 1252 exact · 30 UUID · 0 mismatched
///     release  1391 oracles · 109 skipped · 1282 attempted · 1252 exact · 30 UUID · 0 mismatched
///
/// with 0 load failures and 0 throws on both sides. That is what "integer and deterministic"
/// should mean and now it is measured over 1,282 circuits rather than argued from the type system.
///
/// ── Why release does NOT make the sweep affordable in the default run ────────────────────────
///
/// This is the part worth being explicit about, because "make it fast" and "make it optional"
/// look like alternatives and are not. The reason the default run must be short is not comfort:
/// **five of the defects found in this port were parallel-execution races** (#34, #40, #60, #67,
/// #74), and every one was found by running the *whole suite repeatedly*: 5 runs, 2 failures,
/// different suites each time. Sampling is the instrument, and five is the floor. What five
/// samples cost, from the numbers above:
///
///     sweep off, debug          5 × 272.58 s  =  22.7 min      ← what this change buys
///     sweep on, release         5 × 775.74 s  =  64.6 min  (plus the other 1,131 tests)
///     sweep on, debug           5 × 3287.55 s =   4 h 34 min   ← what it cost before
///
/// So release is a 4.66× discount on something that must not be in the loop at all. And the sweep
/// contributes nothing to what the sampling is looking for: it is one test that holds a worker for
/// 55 minutes and *reduces* the concurrency the races need. Leaving it in makes the instrument
/// both slower and blunter.
///
/// There is a second, quieter reason not to answer this by moving the *default* run to release:
/// release changes the timing races manifest under. The suite that found those five is the debug
/// one. Making release the only way anyone runs it would retune the instrument that found them.
///
/// So: default `swift test` stays debug and skips the sweep; `tools/ci.sh` runs the sweep, in
/// release, on every run without `--quick`. Coverage does not drop; it moves from "every
/// developer run" to "every CI run", and CI additionally runs `tools/difftest/rig.py` over all
/// 1,391 oracles with **no row cap** against the release CLI.
///
/// What this suite still contributes that `rig.py` does not, and why it must keep running rather
/// than be retired in the rig's favour: `rig.py` forks a fresh `logisim-cli` per case, so it
/// cannot see state that leaks *between* circuits. This sweep runs all 1,282 attempted oracles in
/// **one process, sequentially, through `StdLibraries.registerAll()`**; the same shape as the
/// app. It also has no per-case timeout, where `rig.py`'s 25 s cap silently moves cases into its
/// UNMEASURED bucket on a loaded box (a 27-case swing with no code change, recorded in
/// `tools/ci.sh`).
private let sweepRequested = envFlag("LOGISIM_M3_SWEEP")

/// The always-on tier's row ceiling and sample size, see `corpusSmoke`.
private let smokeMaxRows = 33
private let smokeSampleSize = 60

private func classify(_ entry: GoldenEntry, corpus: URL) -> Outcome {
  if entry.lines > maxRows { return .skippedForSize }
  guard let circPath = locate(entry, in: corpus) else {
    return .loadFailed("corpus file not found: \(entry.file)")
  }
  let goldenURL = corpus.appendingPathComponent("golden").appendingPathComponent(entry.golden)
  guard let expected = try? String(contentsOf: goldenURL, encoding: .utf8) else {
    return .loadFailed("golden unreadable: \(entry.golden)")
  }

  let file: LogisimFile
  do {
    file = try Loader().openLogisimFile(circPath)
  } catch {
    return .loadFailed("\(error)")
  }

  do {
    let actual = try TruthTableRun.run(file: file, circuitName: entry.circuit)
    if actual == expected { return .match }
    if differsOnlyByGeneratedLabel(expected: expected, actual: actual) {
      return .unreproducibleLabel
    }
    // Checked only AFTER a byte comparison and the label bucket have both been tried, so a case
    // that happens to agree is still scored as a match. That ordering is the whole lesson of the
    // `MoveCore` false positive: membership here means "the jar's output moved when we ran it",
    // not "this circuit is excused from the gate".
    if unreproducibleOracles["\(entry.file)::\(entry.circuit)"] == "value" {
      return .unreproducibleOracle
    }
    return .mismatch(firstDifference(expected: expected, actual: actual))
  } catch {
    return .runFailed("\(error)")
  }
}

/// `XmlReader`'s random 8-hex-digit label suffix, masked out. See `Outcome.unreproducibleLabel`.
///
/// The suffix is always exactly eight characters, so masking does not disturb column widths and a
/// genuine header difference, a missing column, a different label, a different order, still
/// shows.
private let labelSuffix = try! NSRegularExpression(pattern: "_[0-9a-f]{8}\\b")

private func maskGeneratedLabels(_ text: String) -> String {
  labelSuffix.stringByReplacingMatches(
    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "_UUID")
}

/// Whether the only difference is the random label suffix: **decided by masking it out of BOTH
/// sides and comparing everything**, rather than by requiring every other line to be identical.
///
/// ── Why this changed, and it is a bug fix rather than a loosening ──────────────────────────────
///
/// The previous rule demanded that every line after the header be byte-identical before it would
/// award this bucket. That sounds strict, and it is, but strictness in the *classifier* is not
/// the same as strictness in the *gate*, and here it actively hid defects. A case whose header
/// carries a UUID **and** whose body genuinely diverges failed the all-lines-identical test, fell
/// through to `.mismatch`, and was then described by `firstDifference`, which reported line 1,
/// the random header. So the scoreboard's diagnostic for those cases pointed at a label that
/// differs by construction and says nothing, while the real divergence sat further down the table
/// unmentioned. **8 real defects were found this way** during the M3 investigation, only after
/// someone masked the suffix out of both sides by hand and re-diffed token by token.
///
/// Masking both sides fixes both halves at once: a body divergence is still a `.mismatch` (it is
/// no longer absorbed), and the difference *reported* for it is now the first genuinely differing
/// line instead of the header. Nothing that used to be counted as a match is counted as one now;
/// the bucket is still only awarded when the masked texts are exactly equal.
private func differsOnlyByGeneratedLabel(expected: String, actual: String) -> Bool {
  let maskedExpected = maskGeneratedLabels(expected)
  // Only claim this bucket when a suffix was actually present; otherwise two texts that differ
  // for unrelated reasons could reach it by masking nothing on either side.
  guard maskedExpected != expected else { return false }
  return maskedExpected == maskGeneratedLabels(actual)
}

/// Whether the named circuit instantiates another circuit from the same file.
///
/// Read straight out of the XML rather than off the loaded model, because the point is to
/// attribute mismatches *independently* of the code under test. A subcircuit placement is a
/// `<comp>` whose `name=` is one of the file's `<circuit name=>` values: subcircuit components
/// carry no `lib=` attribute, but matching on the name set is the same answer without relying on
/// that.
private func isHierarchical(_ entry: GoldenEntry, corpus: URL) -> Bool {
  guard let path = locate(entry, in: corpus),
    let source = try? String(contentsOf: path, encoding: .utf8)
  else { return false }

  let circuitNames = Set(
    matches(of: "<circuit name=\"([^\"]+)\"", in: source))
  guard
    let start = source.range(of: "<circuit name=\"\(entry.circuit)\">"),
    let end = source.range(of: "</circuit>", range: start.upperBound..<source.endIndex)
  else { return false }

  let body = String(source[start.upperBound..<end.lowerBound])
  return matches(of: "<comp[^>]* name=\"([^\"]+)\"", in: body).contains { circuitNames.contains($0) }
}

/// Capture group 1 of every match.
private func matches(of pattern: String, in text: String) -> [String] {
  guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
  return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
}

/// The first differing line, which is far more useful in a scoreboard than a whole-table dump.
///
/// **Compared with the random label suffix masked out of both sides.** Without that, any case
/// whose header carries a `generateValidVHDLLabel` UUID reports line 1, a difference that exists
/// by construction and conveys nothing, and the actual divergence is never named. That is
/// precisely how 8 real defects went unattributed; see `differsOnlyByGeneratedLabel`.
private func firstDifference(expected: String, actual: String) -> String {
  let e = maskGeneratedLabels(expected).split(separator: "\n", omittingEmptySubsequences: false)
  let a = maskGeneratedLabels(actual).split(separator: "\n", omittingEmptySubsequences: false)
  for i in 0..<max(e.count, a.count) {
    let el = i < e.count ? String(e[i]) : "<missing>"
    let al = i < a.count ? String(a[i]) : "<missing>"
    if el != al { return "line \(i + 1): java=\(el.prefix(60))| swift=\(al.prefix(60))|" }
  }
  return "identical lines but unequal text (trailing newline?)"
}

// MARK: - The sweep, shared by both tiers

/// Everything a run of the classifier counts. Extracted so the full gate and the always-on smoke
/// tier share one body: two copies of this loop would drift, and the smoke tier's whole value is
/// that it exercises *the same* `classify` path the gate does.
private struct Scoreboard {
  var matched = 0
  var skippedForSize = 0
  var unreproducibleLabels = 0
  var unreproducibleValues = 0
  var hierarchicalMismatches = 0
  var mismatched: [(GoldenEntry, String)] = []
  var loadFailed: [String: Int] = [:]
  var runFailed: [String: Int] = [:]
  var attemptedRows = 0
  var skippedRows = 0
  var slowest: [(GoldenEntry, Double)] = []
  var elapsed: Double = 0
  var progressPath = ""
}

/// Collapse an error string to its shape so the scoreboard groups rather than lists.
private func bucket(_ reason: String) -> String { String(reason.prefix(90)) }

/// Run `classify` over `entries` and account for the result.
///
/// `tag` names the per-case progress log. It is **not** decoration: the log path used to be keyed
/// on the pid alone, and both tiers run in one test process, so a shared name would have had the
/// two tests overwriting each other's progress; the exact failure the pid qualifier was added to
/// fix when two agents in two worktrees clobbered one path and the counter was seen going
/// backwards, 282 → 261.
private func sweep(_ entries: [GoldenEntry], corpus: URL, tag: String) -> Scoreboard {
  var board = Scoreboard()
  let start = Date()

  // A live log, because the sweep takes tens of minutes and a run that wedges on one circuit is
  // otherwise indistinguishable from a slow one. The last line names the case being run. This is
  // what told us the sweep was progressing (502 → 553 in 120 s) rather than hung, so it stays;
  // it costs one small write per case and it is the only thing that answers that question.
  let progress = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("logisim-m3-\(tag)-\(ProcessInfo.processInfo.processIdentifier).log")
  board.progressPath = progress.path
  var log = ""
  func note(_ line: String) {
    log += line + "\n"
    try? log.write(to: progress, atomically: false, encoding: .utf8)
  }

  for (index, entry) in entries.enumerated() {
    note("[\(index + 1)/\(entries.count)] \(entry.file)::\(entry.circuit) (\(entry.lines) rows)")
    let caseStart = Date()
    let outcome = classify(entry, corpus: corpus)
    let caseElapsed = Date().timeIntervalSince(caseStart)
    if case .skippedForSize = outcome {
      board.skippedRows += max(0, entry.lines - 1)
    } else {
      board.attemptedRows += max(0, entry.lines - 1)
      board.slowest.append((entry, caseElapsed))
      board.slowest.sort { $0.1 > $1.1 }
      if board.slowest.count > 12 { board.slowest.removeLast() }
    }
    switch outcome {
    case .match:
      board.matched += 1
    case .skippedForSize:
      board.skippedForSize += 1
    case .unreproducibleLabel:
      board.unreproducibleLabels += 1
    case .unreproducibleOracle:
      board.unreproducibleValues += 1
    case let .mismatch(detail):
      board.mismatched.append((entry, detail))
      if isHierarchical(entry, corpus: corpus) { board.hierarchicalMismatches += 1 }
    case let .loadFailed(reason):
      board.loadFailed[bucket(reason), default: 0] += 1
    case let .runFailed(reason):
      board.runFailed[bucket(reason), default: 0] += 1
    }
  }

  board.elapsed = Date().timeIntervalSince(start)
  return board
}

private func report(_ board: Scoreboard, title: String, oracles: Int, showSlowest: Bool) {
  print("""

    ── \(title) ────────────────────────────────────────────
      golden oracles      \(oracles)
      skipped (> \(maxRows) rows)  \(board.skippedForSize)
      attempted           \(oracles - board.skippedForSize)
      byte-exact match    \(board.matched)
      match but for a random UUID label  \(board.unreproducibleLabels)
      oracle not reproducible by the jar \(board.unreproducibleValues)
      mismatched          \(board.mismatched.count)
        of which hierarchical  \(board.hierarchicalMismatches)
      would not load      \(board.loadFailed.values.reduce(0, +))
      run threw           \(board.runFailed.values.reduce(0, +))
    """)

  print("""
      ── cost ────────────────────────────────────────────────────────────
      rows attempted      \(board.attemptedRows)
      rows skipped        \(board.skippedRows)
      wall seconds        \(String(format: "%.1f", board.elapsed))
      rows/second         \(String(format: "%.0f", Double(board.attemptedRows) / max(board.elapsed, 0.001)))
    """)
  if showSlowest {
    for (entry, seconds) in board.slowest.prefix(12) {
      let rows = max(1, entry.lines - 1)
      print(
        "    slow  \(String(format: "%7.1fs", seconds))  \(rows) rows"
          + "  \(String(format: "%6.0f", Double(rows) / max(seconds, 0.001))) rows/s"
          + "  \(entry.file)::\(entry.circuit)")
    }
  }
  for (reason, count) in board.loadFailed.sorted(by: { $0.value > $1.value }).prefix(8) {
    print("    load  ×\(count)  \(reason)")
  }
  for (reason, count) in board.runFailed.sorted(by: { $0.value > $1.value }).prefix(8) {
    print("    run   ×\(count)  \(reason)")
  }
  for (entry, detail) in board.mismatched.prefix(8) {
    print("    diff  \(entry.file)::\(entry.circuit)  \(detail)")
  }
  print("  (per-case log: \(board.progressPath))\n")
}

// MARK: - The gate

@Suite("M3 — `-tty table` against the 4.1.0 Java oracle")
struct TruthTableGoldenTests {

  /// **The ratchet.** Raise `floor` whenever the match count rises; never lower it.
  ///
  /// First measured 2026-09-05, the first time the port had ever been run against these oracles:
  /// **933 byte-exact of 1,282 attempted**, plus 12 more that agree except for upstream's random
  /// UUID label (see `Outcome.unreproducibleLabel`), 945 / 1,282, with **0** load failures and
  /// **0** runs that threw. `LOGISIM_M3_MAX_ROWS=4096` skips the 110 largest oracles.
  ///
  /// Raised the same day to **1,026 byte-exact**, plus 16 UUID-only, 1,042 / 1,282, 73.7% →
  /// 81.3%. One cause, and it was a missing join rather than a simulation bug:
  /// `StdLibraries.registerAll()` never registered `PlexersLibrary` or `ExtraIoLibrary`, both of
  /// which were fully ported, so every `<comp lib="…" name="Multiplexer">` in the corpus, 2,052
  /// placements across 225 files; became an `UnresolvedComponent` with no ends. Its neighbours
  /// then read `UNKNOWN` and the whole table went `U`.
  ///
  /// Worth knowing for the next person reading a flat gate: **this suite loads in-process
  /// through `registerAll()`, while `tools/difftest/rig.py` drives `logisim-cli`, which
  /// registered those libraries itself.** The two gates were therefore exercising different
  /// library sets, and the round-trip columns did not move at all for this fix. When one gate
  /// moves and the other does not, check whether they share a registration path before
  /// concluding anything about the code.
  ///
  /// Non-hierarchical mismatches fell from 105 to **9**; the remaining 231 of 240 were
  /// subcircuits.
  ///
  /// Raised again the same day to **1,128 byte-exact**, plus 17 UUID-only, 1,145 / 1,282,
  /// 81.3% → 89.3%. Cause: subcircuit *propagation*, which did not exist.
  /// `CircuitSubcircuitFactory.computePorts` had already been implemented and validated across
  /// 786 corpus placements, but ends alone are inert:
  /// `SimulatableComponent.propagate(in:)` opened with `as? any InstanceFactory`, and a
  /// subcircuit is the one component in the tree that fails that cast (Java's
  /// `SubcircuitFactory extends InstanceFactory`; D9 puts the two types in modules that cannot
  /// see each other that way). So every hierarchical design had correct ports that nothing ever
  /// drove, and read all-`U`. `Simulation/SubcircuitPropagation.swift` is the missing behaviour.
  ///
  /// Hierarchical mismatches fell 231 → **128**, and they are now a real backlog rather than one
  /// known cause: what is left is a mix of the port's own defects and cases where the *oracle* is
  /// not reproducible (see `Outcome.unreproducibleLabel`). Nine non-hierarchical mismatches
  /// remain, unchanged; the `E`-vs-`U` cases in the printed sample are error-value propagation,
  /// not hierarchy.
  ///
  /// A note on cost, since it changes how this suite feels to run: the sweep went from ~5 minutes
  /// to ~20. That is not a regression, it is the gate finally doing the work: before this,
  /// hierarchical circuits fell through propagation almost immediately.
  ///
  /// ── Raised 2026-09-05 to 1,250, from a stale 1128 ──────────────────────────────────────────
  ///
  /// The ratchet had been left at `1128` while the measurement was ~1,239: **stale by over 100,
  /// so it could not have caught a regression.** A floor that far below the truth is not a
  /// conservative floor, it is an absent one.
  ///
  /// Two things moved the number since: the `Rom.ports` fix (task #47), and the golden-set repair
  /// (`docs/experiments/m3-golden-set-repair.md`) which dropped one oracle upstream cannot
  /// produce and corrected one that had been compared against another circuit's output. The
  /// denominator is now **1,391**, not 1,392.
  ///
  /// Derived from the release-CLI `rig.py` sweep *before* being run, the same way §6 of
  /// `m3-simulation-gate.md` did it, 1,391 oracles, 109 over the 4,096-row cap, 1,282 attempted,
  /// 48 rig failures of which 32 fall inside the cap, then **confirmed by running the suite**
  /// (3,295 s). Prediction and measurement agree on every line:
  ///
  ///     golden oracles      1391       skipped (>4096)  109      attempted  1282
  ///     byte-exact match    1250       UUID label        24      mismatched    8
  ///     oracle not reproducible by the jar  0            would not load 0 · run threw 0
  ///
  /// That is two independent harnesses agreeing again (`rig.py` over 1,391 with no cap, and this
  /// suite over its 1,282), which is the check worth keeping: when they disagree it is one of the
  /// four structural differences in §3, never a code difference.
  ///
  /// Note what this floor does and does not assert. It ratchets **byte-exact matches only**; the
  /// UUID and unreproducible buckets are reported but not floored, deliberately, because their
  /// membership depends on a random label and on a jar re-run rather than on the port.
  ///
  /// ── Raised 2026-09-06 to 1,252, and the mismatch column reached zero ────────────────────────
  ///
  /// Measured **twice on this tree, either side of the M9 change**, and the two runs agree line
  /// for line:
  ///
  ///     golden oracles 1391 · skipped 109 · attempted 1282
  ///     byte-exact match 1252 · UUID label 30 · not reproducible 0
  ///     mismatched 0 · would not load 0 · run threw 0
  ///
  /// **`mismatched` is 0.** Every one of the 1,282 attempted oracles now either matches the 4.1.0
  /// jar byte for byte, or differs only in a label the jar itself randomises. That is worth
  /// stating plainly because the number the floor guards no longer tells the whole story: the
  /// remaining gap in this gate is not defects, it is the 109 oracles the row cap declines to run
  /// , 7,319,552 rows, **97% of the corpus**. See `maxRows` for what raising it costs and what
  /// would have to change first.
  ///
  /// The floor was left at 1250 while the truth was 1252; the two extra came from other slices
  /// landing on `swift-port`, not from M9, which is a pure evaluation-strategy change and moved no
  /// bucket at all.
  static let floor = 1252

  // An explicit skip, not a silent `return`: a gate that returns early still reports as a
  // PASS, and the corpus is not published, so in a clean clone there is nothing to compare.
  @Test("the corpus scoreboard does not regress",
    .enabled(if: ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] != nil,
      "needs LOGISIM_CORPUS: the corpus is coursework and is not in this repository"),
    .enabled(if: ProcessInfo.processInfo.environment["LOGISIM_M3_SWEEP"] != nil,
      "opt-in: set LOGISIM_M3_SWEEP to run the full sweep; corpusSmoke covers a sample always"))
  func corpusScoreboard() throws {
    // Both conditions are traits, so the runner reports this as SKIPPED. It used to print a reason
    // and return, which Swift Testing still scores as a PASS: the one case most likely to be read
    // as coverage, because it is skipped by DEFAULT. See `sweepRequested` for the decision itself.
    let corpus = try #require(corpusDirectory())
    if !sweepRequested {
      print("""
        LOGISIM_M3_SWEEP unset — full M3 corpus sweep skipped (1,391 oracles; measured 3283 s
          in debug, 705 s in release). The always-on `corpusSmoke` tier still runs a
          deterministic sample of it, and `tools/ci.sh` runs the whole sweep in release on
          every run without --quick. To run it here, exactly as CI does:
            LOGISIM_M3_SWEEP=1 swift test -c release -Xswiftc -enable-testing \\
              --filter corpusScoreboard
          (`-enable-testing` is required: release drops testability and every @testable
           import fails to compile without it.)
        """)
      return
    }
    StdLibraries.registerAll()

    let entries = inventory(corpus)
    // A corpus is configured and the sweep was asked for, so an empty inventory is a
    // miscalibration rather than an absence: failing names the reason, returning would not.
    #expect(!entries.isEmpty, "LOGISIM_CORPUS is set but golden/_inventory.json is empty or absent")
    guard !entries.isEmpty else {
      print("no golden inventory at \(corpus.path)/golden/_inventory.json — gate skipped")
      return
    }

    // ── Cost accounting ────────────────────────────────────────────────────────────────────
    //
    // The scoreboard reported correctness and nothing about cost, so "the gate takes about an
    // hour" was folklore rather than a number, and there was no denominator to divide by. Both
    // are needed to say whether an evaluation-strategy change actually paid: a sweep that spends
    // its time in ten pathological circuits does not get faster by making the other 1,272
    // quicker. `lines` is the golden file's line count, i.e. one header plus one line per row, so
    // the row denominator is `lines - 1` per attempted case. `sweep` does that accounting.
    let board = sweep(entries, corpus: corpus, tag: "gate")
    report(board, title: "M3 `-tty table` gate", oracles: entries.count, showSlowest: true)

    // Distinguish "the bucket loaded nothing" from "the bucket loaded and nothing hit it". Both
    // print 0 above, and they mean opposite things; one is a broken gate, the other is a result.
    let valueClass = unreproducibleOracles.filter { $0.value == "value" }.count
    if unreproducibleOracles.isEmpty {
      print(
        """
            NOTE: tools/difftest/nondeterministic.json is missing or empty, so the
            "not reproducible" bucket is INERT and those cases are being counted as
            mismatches. Regenerate it with tools/difftest/nondet.py.
        """)
    } else {
      print(
        """
            (bucket loaded: \(unreproducibleOracles.count) case(s), of which \(valueClass) are
             value-class. Measured 2026-09-05: the only value-class oracle in the corpus is
             3.3.0__case-075.circ::Datapath at 131,073 rows, which this suite skips for size — so a 0 on
             the line above is the expected result here, not an inert bucket. The other five
             oracles a *static* seed-0 `Random` search once flagged are in 3.6.0__case-458.circ,
             and they pass byte-exactly; that is why membership is measured, not inferred.)
        """)
    }

    #expect(
      board.matched >= TruthTableGoldenTests.floor,
      "match count fell below the recorded floor of \(TruthTableGoldenTests.floor)")
  }

  /// **The always-on tier.** Runs whenever a corpus is present, sweep flag or not.
  ///
  /// Making the sweep opt-in has one predictable failure mode: nobody sets the flag, this file
  /// stops executing in the default run, and the day it breaks is the day CI runs, which on this
  /// project has meant "a week later, attributed to the wrong change". An opt-in gate with nothing
  /// left behind it is how a suite quietly stops being a suite. So a fixed, cheap slice stays in
  /// the default run: it keeps `locate`, `classify`, the UUID masking and `TruthTableRun` on the
  /// in-process `registerAll()` path exercised on every `swift test`, and it fails in seconds.
  ///
  /// It is a **deterministic stratified sample**, not the first N entries. Taking the first N of a
  /// name-sorted inventory would draw every case from the same handful of files; striding across
  /// the size-filtered list touches the breadth of the corpus for the same cost, and, being a
  /// pure function of the inventory, picks the same cases on every machine, so a failure here
  /// reproduces from the case name alone.
  ///
  /// Unlike the full gate this asserts EXACTLY, with no ratchet: every sampled oracle must either
  /// match the jar byte for byte or differ only in the UUID label. That is not a stricter standard
  /// than the gate's, it is the same standard; the full sweep's `mismatched` column has measured
  /// 0 since 2026-09-06. A ratchet exists to tolerate a known backlog; there is none in this size
  /// class, so a floor here would only be somewhere for a regression to hide.
  ///
  /// The one bucket it must never draw is `.unreproducibleOracle`; a case with no stable answer
  /// would fail this assertion by construction. It cannot today: the corpus's only value-class
  /// oracle is `3.3.0__case-075.circ::Datapath` at 131,073 rows, three orders of magnitude above
  /// `smokeMaxRows`. That is asserted rather than assumed, so if it ever changes the failure names
  /// the reason instead of looking like a port defect.
  // An explicit skip, not a silent `return`: a gate that returns early still reports as a
  // PASS, and the corpus is not published, so in a clean clone there is nothing to compare.
  @Test("the corpus smoke sample matches the jar exactly",
    .enabled(if: ProcessInfo.processInfo.environment["LOGISIM_CORPUS"] != nil,
      "needs LOGISIM_CORPUS: the corpus is coursework and is not in this repository"))
  func corpusSmoke() throws {
    // The sibling of `corpusScoreboard`, and it kept the old shape when that one was repaired: a
    // configured corpus with no inventory printed a line and returned, which Swift Testing scores
    // as a PASS. A reviewer caught it by pointing LOGISIM_CORPUS at an empty directory.
    let corpus = try #require(corpusDirectory())
    StdLibraries.registerAll()

    let entries = inventory(corpus)
    #expect(
      !entries.isEmpty,
      "LOGISIM_CORPUS is set but golden/_inventory.json is empty or absent: compared nothing")
    guard !entries.isEmpty else { return }

    let sample = smokeSample(entries)
    let board = sweep(sample, corpus: corpus, tag: "smoke")
    report(
      board, title: "M3 smoke sample (<= \(smokeMaxRows) rows)", oracles: sample.count,
      showSlowest: false)

    #expect(board.mismatched.isEmpty, "smoke sample mismatched: \(board.mismatched.map(\.1))")
    #expect(board.loadFailed.isEmpty, "smoke sample failed to load: \(board.loadFailed)")
    #expect(board.runFailed.isEmpty, "smoke sample threw: \(board.runFailed)")
    #expect(
      board.unreproducibleValues == 0,
      "a value-class nondeterministic oracle entered the smoke sample; it has no stable answer, so it must be excluded rather than asserted on")
    #expect(
      board.matched + board.unreproducibleLabels == sample.count,
      "smoke sample: \(board.matched) exact + \(board.unreproducibleLabels) UUID-label of \(sample.count)")
  }

  /// A fixed-size stride across the oracles at or under `smokeMaxRows`, in inventory order.
  ///
  /// `inventory` sorts by golden name, so the stride is stable across machines and runs.
  private func smokeSample(_ entries: [GoldenEntry]) -> [GoldenEntry] {
    let small = entries.filter { $0.lines <= smokeMaxRows }
    guard small.count > smokeSampleSize else { return small }
    let step = Double(small.count) / Double(smokeSampleSize)
    return (0..<smokeSampleSize).map { small[min(small.count - 1, Int(Double($0) * step))] }
  }
}
