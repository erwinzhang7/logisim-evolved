#!/usr/bin/env bash
# Local CI gate for the Swift port. Run before every commit.
#
#   tools/ci.sh             # build, test, M3 corpus sweep, leaks, round-trip, differential rig
#   tools/ci.sh --quick     # skip the three corpus-wide steps: the M3 sweep, the round-trip
#                           # gate, and the differential rig (which shells out to a JVM per case)
#   tools/ci.sh --strict    # release mode: skipped or unmeasured gates are fatal
#
# Exits nonzero if ANY step fails. Steps do not short-circuit: a full run reports
# every failure at once rather than only the first.
#
# Exit codes are captured directly from each command, never from a pipeline --
# `$?` after a pipe is the LAST command's status, which silently produces a
# permanently-green gate.
#
# ...but the fix for that must not be "run the command twice", which is what the build and test
# steps used to do: one piped invocation for display, a second discarded one for the status. That
# is invisible when a step costs seconds and ruinous when it does not -- with `LOGISIM_CORPUS`
# set, `swift test` ran the whole suite TWICE, and the leaks step below then ran the same binary
# a THIRD time. Every step now runs once, into a file, and reads its own `$?` before anything
# else can clobber it.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$REPO/swift"
QUICK=0
STRICT=0
case "${LOGISIM_CI_STRICT:-0}" in
  1|true|TRUE|yes|YES) STRICT=1 ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --strict) STRICT=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

FAILURES=()
SKIPS=()
UNMEASURED=()
step()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()    { printf '   \033[32mok\033[0m  %s\n' "$1"; }
bad()   { printf '   \033[31mFAIL\033[0m %s\n' "$1"; FAILURES+=("$1"); }
skip()  { printf '   \033[33mSKIP\033[0m %s\n' "$1"; SKIPS+=("$1"); }
# Neither green nor red: the check ran and could not reach a verdict. It is not a regression, but
# it still enters the summary so the final verdict cannot claim a complete green run.
warn()  { printf '   \033[33m????\033[0m %s\n' "$1"; UNMEASURED+=("$1"); }

# ---------------------------------------------------------------- build
step "swift build"
(cd "$SWIFT_DIR" && swift build > /tmp/ci-build.out 2>&1)
BUILD=$?
tail -20 /tmp/ci-build.out
[[ $BUILD -eq 0 ]] && ok "builds" || bad "swift build"

# ---------------------------------------------------------------- tests
#
# DEBUG, and WITHOUT the M3 corpus sweep -- `LOGISIM_M3_SWEEP` is deliberately not set here. This
# is the run that has to stay cheap enough to repeat, because five of the defects found in this
# port were parallel-execution races (#34, #40, #60, #67, #74) and every one of them was found by
# running this suite five or more times and comparing. The sweep gets its own step below, in
# release. See `swift/Tests/LogisimStdTests/TruthTableGoldenTests.swift` (`sweepRequested`) for
# the measurements behind the split.
step "swift test"
(cd "$SWIFT_DIR" && swift test > /tmp/ci-test.out 2>&1)
TEST=$?
tail -15 /tmp/ci-test.out
[[ $TEST -eq 0 ]] && ok "tests pass" || bad "swift test"

# ------------------------------------------- leak-detector self-check
# D3: the object graph is cyclic in nine independent directions and ARC cycle
# leaks produce ZERO test failures. So the leak detector is load-bearing -- and
# a detector that never fires is indistinguishable from clean code.
#
# ---------------------------------------------------------------- dependency graph
#
# Unlike the seam check this is a HARD gate, not a ratchet. Every edge it asserts was added to
# fix a specific failure, and every one has been silently reverted by a merge at least once;
# three times for the file as a whole. There is no legitimate reason for one to disappear, so
# there is nothing to ratchet: if it is gone, something ate it.
step "module dependency graph"
if python3 "$REPO/tools/graphcheck.py" > /tmp/graphcheck.out 2>&1; then
  ok "$(tail -1 /tmp/graphcheck.out | sed 's/^ *//')"
else
  cat /tmp/graphcheck.out
  bad "required dependency edge missing from Package.swift"
fi

# ---------------------------------------------------------------- unwired seams
#
# The largest defect class in this port is something declared, called, and never implemented.
# It has happened nine times, every one found by hand long after it landed, because neither the
# compiler nor the tests can see it: an unassigned Optional is legal, an unconformed protocol is
# legal, and nothing exercises the path.
#
# This is a RATCHET, not a gate. Most current findings are seams somebody deliberately left open
# for a later milestone; failing on those would make the check permanently red, and a permanently
# red check is one people scroll past. It fails only when a NEW one appears.
# The corpus is coursework and every citation of it in this tree must be an anonymous handle. This
# is a gate rather than a habit because three hand scans in a row each missed the same shape: an
# abbreviated citation, where the pattern being grepped for no longer matches. See
# `tools/corpuscheck.py` for the four shapes that got through.
step "corpus citations are anonymous"
if ! python3 "$REPO/tools/corpuscheck.py" --selftest > /tmp/corpuscheck-self.out 2>&1; then
  cat /tmp/corpuscheck-self.out
  bad "corpuscheck.py is MISCALIBRATED — a green run below would mean nothing"
fi
if python3 "$REPO/tools/corpuscheck.py" > /tmp/corpuscheck.out 2>&1; then
  ok "$(tail -1 /tmp/corpuscheck.out)"
else
  cat /tmp/corpuscheck.out
  bad "a corpus filename is in the tree; run tools/corpuscheck.py"
fi

step "unwired seams"
if python3 "$REPO/tools/seamcheck.py" > /tmp/seamcheck.out 2>&1; then
  ok "$(tail -3 /tmp/seamcheck.out | grep -o '[0-9]* candidate seam(s); [0-9]* were already known' || echo 'no new seams')"
else
  tail -25 /tmp/seamcheck.out
  bad "new unwired seam(s) — see above, or run tools/seamcheck.py"
fi

# `seamcheck` sees ONE shape: a protocol with no conformer. `deadseam` sees the other three, and
# each of them has already shipped a real defect that seamcheck was structurally blind to:
# an unassigned closure seam (#22 wireRepair, #25 appearanceHook), a collection written and never
# read (#25's other half), and a type constructed only by tests (#17 SocCircuitBinder).
#
# Its `--selftest` runs FIRST and is a hard failure, because this script's three modes were each
# wrong on their first run while their selftest passed. An uncalibrated seam checker is precisely
# the thing it exists to prevent, so a broken calibration must stop the build even though a
# finding does not.
step "seam checker calibration"
if python3 "$REPO/tools/deadseam.py" --selftest > /tmp/deadseam-self.out 2>&1 \
   && grep -q "selftest passed" /tmp/deadseam-self.out; then
  ok "5 anchors across 3 modes, both directions"
else
  cat /tmp/deadseam-self.out
  bad "deadseam.py is MISCALIBRATED — its findings cannot be trusted until this passes"
fi

# The report itself is advisory, exactly like seamcheck's ratchet reasoning above: most findings
# are deliberate (a nil-by-default platform hook, a test double, a documented D9 seam), and
# failing on those would make it permanently red.
step "unassigned seams (closures, collections, test-only types)"
python3 "$REPO/tools/deadseam.py" > /tmp/deadseam.out 2>&1 || true
ok "$(grep -cE '^    [a-zA-Z]' /tmp/deadseam.out | tr -d ' ') candidate(s) — see /tmp/deadseam.out"

# Validate it BOTH ways. The control must pass, or a mere crash would look like
# a successful injection.
step "leak detector self-check"
CANARY_DIR="$(mktemp -d)"
trap 'rm -rf "$CANARY_DIR"' EXIT
cat > "$CANARY_DIR/canary.swift" <<'SWIFT'
// Retain-cycle canary. With --leak, builds exactly the shape D3 warns about:
// a mutual strong reference that Java's GC would collect and ARC will not.
final class Node {
  var peer: Node?          // strong on purpose
  let payload = [UInt8](repeating: 0, count: 1 << 16)
}
let shouldLeak = CommandLine.arguments.contains("--leak")
func build() {
  let a = Node(), b = Node()
  if shouldLeak {
    a.peer = b
    b.peer = a             // cycle: neither is ever freed
  }
}
for _ in 0..<50 { build() }
SWIFT
if swiftc -O "$CANARY_DIR/canary.swift" -o "$CANARY_DIR/canary" 2>/dev/null; then
  # Control: unmodified canary must be CLEAN (exit 0). If this fails, the
  # detector is broken or noisy and the injection result below means nothing.
  leaks --atExit -- "$CANARY_DIR/canary" >/dev/null 2>&1
  CONTROL=$?
  # Injection: the leaking canary must be DETECTED (nonzero).
  leaks --atExit -- "$CANARY_DIR/canary" --leak >/dev/null 2>&1
  INJECTED=$?
  if [[ $CONTROL -eq 0 && $INJECTED -ne 0 ]]; then
    ok "detector validated (control clean=$CONTROL, injected leak detected=$INJECTED)"
    LEAK_DETECTOR_TRUSTED=1
  else
    bad "leak detector unusable (control=$CONTROL want 0, injected=$INJECTED want nonzero)"
    LEAK_DETECTOR_TRUSTED=0
  fi
else
  bad "leak canary failed to compile"
  LEAK_DETECTOR_TRUSTED=0
fi

# ---------------------------------------------------------------- leaks
#
# This runs the debug test binary a second time, under `leaks`, which is unavoidable -- the
# detector needs the process to exit under its supervision. It is also why the M3 sweep must not
# be in the default run: with the sweep on and a corpus set, this step alone re-ran it.
step "leaks on the test binary"
if [[ "${LEAK_DETECTOR_TRUSTED:-0}" -eq 1 ]]; then
  BIN="$(cd "$SWIFT_DIR" && swift build --show-bin-path 2>/dev/null)"
  XCTEST="$(find "$BIN" -name '*.xctest' -maxdepth 1 2>/dev/null | head -1)"
  if [[ -n "$XCTEST" && -d "$XCTEST" ]]; then
    # `xcrun xctest <bundle>`, NOT the Mach-O inside it. The inner file is a
    # `Mach-O 64-bit BUNDLE`, which cannot be exec'd: `leaks` spawned a shell, the shell printed
    # "cannot execute binary file", and `leaks` **exited 0**. This gate therefore reported
    # "no leaks in test run" for two months while running zero tests. Measured 2026-09-06:
    #   leaks --atExit -- .../Contents/MacOS/logisim-evolvedPackageTests  ->  exit=0, 0 tests
    #   xcrun xctest .../logisim-evolvedPackageTests.xctest               ->  1,218 tests ran
    #
    # AND THE EXIT CODE ALONE IS NOT A PASS CONDITION. `leaks --atExit` also exits 0 when the
    # target dies before it allocates anything: verified with a deliberately broken invocation
    # that crashed on a missing rpath and still returned 0. "No leaks" and "nothing ran" are
    # indistinguishable by status, so the gate demands POSITIVE EVIDENCE that the suite executed
    # before it is allowed to report success. A green that cannot tell those two apart is the
    # shape that made this gate useless in the first place (and board #35 before it).
    LEAKLOG="$(mktemp)"
    leaks --atExit -- xcrun xctest "$XCTEST" >"$LEAKLOG" 2>&1
    LEAKSTATUS=$?
    if ! grep -qE "Test run with [0-9]+ tests" "$LEAKLOG"; then
      bad "leaks gate ran no tests -- $(tail -1 "$LEAKLOG" | cut -c1-120)"
    elif [[ $LEAKSTATUS -eq 0 ]]; then
      ok "no leaks in test run ($(grep -oE "Test run with [0-9]+ tests in [0-9]+ suites" "$LEAKLOG" | head -1))"
    else
      bad "leaks detected in test run -- $(grep -m1 -E "[0-9]+ leaks for" "$LEAKLOG")"
    fi
    rm -f "$LEAKLOG"
  else
    ok "skipped (no .xctest bundle yet)"
  fi
else
  bad "leaks skipped -- detector not trusted"
fi

# ------------------------------------------------- M3 corpus truth-table sweep
#
# THIS IS WHERE THE SWEEP RUNS, and it is the whole point of making it opt-in above: coverage does
# not drop, it moves from "every developer's `swift test`" to "every CI run", and it runs in
# RELEASE, where it is several times faster for byte-identical output.
#
# The release build costs one compile, once, and does not come close to eating the saving -- that
# was the open question and the answer is no: 126.96 s of cold release build buys 2578.7 s of
# sweep. It also warms `.build/release` for the differential rig below, which needs a release CLI
# anyway. Measured in a full run of this script, 2026-09-06: this step 711.9 s, reporting
# 1252 byte-exact of 1282 attempted, 0 mismatched -- identical to the debug scoreboard.
#
# The guard below was RED-PROBED against the real command line, not a hypothetical: a filter of
# `corpusScoreboardXYZ` exits 0 and prints "Test run with 0 tests in 0 suites passed". That is
# what a silently-dead gate looks like from the outside, and it is exactly the shape that let
# rig.py's simulation mode report nothing for its entire existence (task #35).
#
# `-Xswiftc -enable-testing` IS REQUIRED, not a precaution. Release builds drop testability by
# default, so every `@testable import` in the suite fails to compile with "module was not compiled
# for testing" -- measured here, `swift build -c release --build-tests` fails in 10.5 s. The flag
# costs some cross-module optimisation, so the release timing quoted in TruthTableGoldenTests is
# measured WITH it, which is the only number that describes what CI actually runs.
#
# `--filter` matching NOTHING prints "0 tests" and exits 0, which looks exactly like a pass. So a
# clean exit is not accepted as evidence on its own: the scoreboard must actually appear in the
# output. The same guard catches the two other ways this step can silently do nothing -- the
# inventory being absent, and `LOGISIM_M3_SWEEP` failing to reach the test process.
if [[ $QUICK -eq 0 ]]; then
  step "M3 corpus truth-table sweep (release)"
  if [[ -z "${LOGISIM_CORPUS:-}" ]]; then
    skip "M3 sweep skipped (LOGISIM_CORPUS unset)"
  else
    (cd "$SWIFT_DIR" && swift build -c release --build-tests -Xswiftc -enable-testing \
       > /tmp/ci-m3-build.out 2>&1)
    M3BUILD=$?
    if [[ $M3BUILD -ne 0 ]]; then
      tail -20 /tmp/ci-m3-build.out
      bad "release test build failed — the M3 sweep did not run"
    else
      (cd "$SWIFT_DIR" && LOGISIM_M3_SWEEP=1 swift test -c release -Xswiftc -enable-testing \
         --filter corpusScoreboard > /tmp/ci-m3-sweep.out 2>&1)
      M3=$?
      sed -n '/── M3 `-tty table` gate/,/per-case log/p' /tmp/ci-m3-sweep.out
      if ! grep -q 'golden oracles' /tmp/ci-m3-sweep.out; then
        tail -20 /tmp/ci-m3-sweep.out
        bad "M3 sweep produced NO scoreboard — it did not run (filter matched nothing, no golden inventory, or LOGISIM_M3_SWEEP did not reach the test)"
      elif [[ $M3 -ne 0 ]]; then
        bad "M3 sweep below its recorded floor — see /tmp/ci-m3-sweep.out"
      else
        ok "$(grep -m1 'byte-exact match' /tmp/ci-m3-sweep.out | sed 's/^ *//')"
      fi
    fi
  fi
else
  step "M3 corpus truth-table sweep (release)"
  skip "M3 sweep skipped (--quick)"
fi

# ------------------------------------------------------- M2 round-trip gate
if [[ $QUICK -eq 0 ]]; then
  step "M2 round-trip gate (.circ codec)"
  if [[ -z "${LOGISIM_CORPUS:-}" ]]; then
    skip "M2 round-trip skipped (LOGISIM_CORPUS unset)"
  elif [[ ! -f "$LOGISIM_CORPUS/canonical/_index.json" ]]; then
    skip "M2 round-trip skipped (no canonical baselines — run tools/difftest/canonical.py)"
  else
    # M2 is now claimed as done and green in docs/objectives.md, so this is no longer
    # informational. The two conditions are still printed separately on purpose: a green canonical
    # column with a red migration column means something very different from the reverse.
    python3 "$REPO/tools/difftest/rig.py" --roundtrip --max-fail 3 --jobs 4 \
      > /tmp/ci-m2-roundtrip.out 2>&1
    M2=$?
    tail -4 /tmp/ci-m2-roundtrip.out
    if [[ $M2 -eq 0 ]]; then
      ok "round-trip gate green"
    else
      bad "M2 round-trip gate red — docs/objectives.md claims M2 is done, so this is a regression"
    fi
  fi
else
  step "M2 round-trip gate (.circ codec)"
  skip "M2 round-trip skipped (--quick)"
fi

# ------------------------------------------------------- differential rig
if [[ $QUICK -eq 0 ]]; then
  step "differential rig"
  if [[ -z "${LOGISIM_CORPUS:-}" ]]; then
    skip "differential rig skipped (LOGISIM_CORPUS unset)"
  else
    # BUILD RELEASE FIRST. rig.py now prefers the release binary, but only if one exists; a
    # debug sweep reaches ~100 of 1,392 cases in 30 minutes and never finishes, so a CI run
    # against debug is not a slow gate, it is a gate that never reports.
    (cd "$SWIFT_DIR" && swift build -c release --product logisim-cli \
       > /tmp/ci-rig-build.out 2>&1)
    RIGBUILD=$?
    if [[ $RIGBUILD -ne 0 ]]; then
      tail -20 /tmp/ci-rig-build.out
      bad "release CLI build failed — differential rig did not run"
    elif [[ ! -x "$SWIFT_DIR/.build/release/logisim-cli" ]]; then
      bad "release CLI missing after successful build — differential rig did not run"
    else
      # Keep these explicit: this is the measured setting for the 6P+12E CI host, and prevents a
      # library-level default change from silently retuning the gate's load or timeout coverage.
      #
      # The cap was 60s and returned UNMEASURED on four consecutive runs, because a run of the whole
      # pipeline is exactly when the box is busiest, so the gate was never definitive in the
      # situation it exists for. Measured 2026-09-13: at 60s under load, 6 cases timed out; alone at
      # 600s, all 1,347 measurable cases passed with zero timeouts. So the slow cases are a load
      # artefact, not circuits needing more than a minute of release-build simulation, and not a
      # finding in the port. 300s costs at most one stall per pathological case and makes an
      # ordinary run definitive. The rig still wants the box to itself: the cap is load-sensitive by
      # design, and no timeout is generous enough to make co-scheduling sound.
      python3 "$REPO/tools/difftest/rig.py" --max-fail 8 --jobs 10 --timeout 300 \
        --cli "$SWIFT_DIR/.build/release/logisim-cli"
      RIG=$?
      # This step used to say "an all-fail rig is EXPECTED, not a regression -- treat it as
      # informational". That was true before M3 landed and it is the exact reason rig.py's
      # simulation mode could report 0 pass / 1392 fail for its ENTIRE EXISTENCE without anyone
      # noticing: the documented expectation covered the failure. M3 now measures ~1,343 of 1,391,
      # so a red rig is a regression and is reported as one.
      # Exit 2 is rig.py's third state: no case FAILED, but some could not be measured because the
      # CLI did not answer within --timeout. That is a statement about the machine, not the port,
      # on a loaded box this gate swung by 27 cases with no code change, so it is neither green
      # nor a regression, and it must not be silently rounded to either.
      case $RIG in
        0) ok  "differential rig green" ;;
        2) warn "differential rig UNMEASURED — cases timed out; re-run with --jobs 1 --timeout 600" ;;
        *) bad "differential rig red: M3 has landed, so this is a regression" ;;
      esac
    fi
  fi
else
  step "differential rig"
  skip "differential rig skipped (--quick)"
fi

# ── The three `-tty` gates, which docs/objectives.md quotes and CI did not run ────────────────
#
# `statsgate`, `tablefmtgate` and `vectorgate` live under `tools/difftest/ttybridge/` and each has
# a `--selfcheck` that pins BOTH directions of its own comparison. They were being run by hand,
# while `docs/objectives.md` quoted their numbers ("-tty stats 1,731/6 of 1,737") alongside gates
# CI actually enforces. A number in the baseline that nothing re-measures is a number that drifts,
# and this project has already been bitten twice by exactly that; a claim believed because it was
# once true.
#
# They are corpus-dependent, so they record a SKIP rather than a pass when it is absent, which is
# what the new three-state summary is for: a laptop run says CI INCOMPLETE, a release run with
# --strict fails.
if [[ $QUICK -eq 0 ]]; then
  for gate in statsgate tablefmtgate vectorgate; do
    step "$gate"
    if [[ -z "${LOGISIM_CORPUS:-}" ]]; then
      skip "$gate skipped (LOGISIM_CORPUS unset)"
      continue
    fi
    GATE_OUT="$(cd "$REPO/tools/difftest/ttybridge" && python3 "$gate.py" 2>&1)"
    GATE_RC=$?
    if [[ $GATE_RC -eq 0 ]]; then
      ok "$(printf '%s' "$GATE_OUT" | tail -1)"
    else
      printf '%s\n' "$GATE_OUT" | tail -20
      bad "$gate red (exit $GATE_RC)"
    fi
  done
else
  for gate in statsgate tablefmtgate vectorgate; do
    step "$gate"
    skip "$gate skipped (--quick)"
  done
fi

# ---------------------------------------------------------------- verdict
printf '\n%s\n' "------------------------------------------------------------"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf 'failures:\n'
  printf '  - %s\n' "${FAILURES[@]}"
fi
if [[ ${#SKIPS[@]} -gt 0 ]]; then
  printf 'skipped gates:\n'
  printf '  - %s\n' "${SKIPS[@]}"
fi
if [[ ${#UNMEASURED[@]} -gt 0 ]]; then
  printf 'unmeasured gates:\n'
  printf '  - %s\n' "${UNMEASURED[@]}"
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  printf '\033[31mCI FAIL\033[0m (%d failure(s))\n' "${#FAILURES[@]}"
  exit 1
fi

INCOMPLETE=$(( ${#SKIPS[@]} + ${#UNMEASURED[@]} ))
if [[ $INCOMPLETE -gt 0 ]]; then
  if [[ $STRICT -eq 1 ]]; then
    printf '\033[31mCI FAIL\033[0m (strict: %d skipped, %d unmeasured)\n' "${#SKIPS[@]}" "${#UNMEASURED[@]}"
    exit 1
  fi
  printf '\033[33mCI INCOMPLETE\033[0m (0 failures, %d skipped, %d unmeasured)\n' "${#SKIPS[@]}" "${#UNMEASURED[@]}"
  exit 0
fi
printf '\033[32mCI PASS\033[0m\n'
exit 0
