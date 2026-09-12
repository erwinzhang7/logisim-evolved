# Port decisions

Binding decisions for the Swift/macOS port of logisim-evolution. Anything delegated to a
subagent or another tool must be consistent with this file. Each entry states the decision,
the reason, and what it would cost to reverse.

Status: settled unless marked OPEN.

---

## D0 — Target and scope

macOS only, Apple Silicon first. Cross-platform support is explicitly abandoned; that is what
licenses the Metal/CoreText/mach-level choices below.

Full functional parity with logisim-evolution 4.1.0 is the destination, **minus** anything
bound to toolchains that have never existed on macOS (see D10). There is no reduced "v1"
release gate; milestones are verification checkpoints, not ship gates.

---

## D1 — The simulation kernel opts out of Swift Concurrency

`LogisimKernel` compiles in **Swift 5 language mode**. It uses `Thread`, `NSLock`,
`NSRecursiveLock`, `NSCondition`, and thread-identity assertions, mirroring the Java. Modules
above it (`LogisimRender`, `LogisimUI`) are Swift 6 with `@MainActor`.

Why: the Java enforces its invariants with `Thread.currentThread() != propagatorThread` checks
at 62 sites. Adopting actors would make `propagate()` `async`, which virally infects all **108**
`propagate(InstanceState)` implementations and destroys the reusable `InstanceStateImpl` scratch
object (a documented ~90% speedup that is only safe because propagation is synchronous and
non-reentrant). Foundation's threading primitives behave exactly like Java's, so 62 sites port
unchanged.

Reversal cost: extreme. Every component and the whole engine.

### D1 corollary — a kernel callback crossing into a `@MainActor` type must HOP, never assert

Added 2026-09-05, after this exact boundary crashed the process twice.

D1 puts the kernel in Swift 5 mode on its own `Thread` and everything above it in Swift 6 under
`@MainActor`. Kernel listeners, `CircuitListener`, `ComponentListener`, the log and simulation
observers, are therefore invoked **on whatever thread propagation is running on**, with no actor
to inherit. `MainActor.assumeIsolated` is an *assertion*, not a hop: off the main thread it traps
the whole process with `EXC_BREAKPOINT`, and no test failure is reported because the test binary
dies.

So, in any `LogisimUI` type that subscribes to a kernel event:

* **`onMainActor { … }`** (`Project/LogisimFileProjectHost.swift`): hops if needed, stays
  synchronous when already on main so that a user edit is still delivered *before* the
  `CircuitMutation` that triggered it completes.
* **`MainActor.assumeIsolated`** only where the call site can be shown to originate on the main
  actor and nothing in the kernel can reach it. Say which, at the site.

The trap is easy to miss because it is *usually* right: while the only source of circuit events
was a user edit, asserting isolation held. Subcircuit propagation made `.invalidate` reachable
from the simulation thread, `SubcircuitPropagation.substate` → `InstanceComponent.fireInvalidated()`
→ `Circuit.fireEvent`, and two listeners that had been correct became crashes on the same day.
Note that `LogController.onMain` and `SimulationEngine.mutateSnapshot` had *already* derived this
rule independently, each with a comment saying so, and two other listeners still got it wrong.
Deriving a rule three times and applying it twice is what a written decision is for.

## D2 — `propagate()` is synchronous and non-reentrant

Follows from D1 but stated separately because it is the specific property that licenses the
reusable `InstanceStateImpl` and the delay-queue design.

## D3 — ARC ownership direction

Java's GC collects cycles; ARC does not, and the object graph is cyclic in at least nine
independent directions.

**Owning edges:** `Circuit` → components. `CircuitState` → `substates`, `componentData`.

**Every other edge is `weak`/`unowned`:** `parentState`, `parentComp`, `base` (Propagator),
`proj`, `Circuit.proj`, `Project.frame`, `InstanceComponent.instanceState`.

**Delete the `Instance` facade.** `Instance` ⇄ `InstanceComponent` is an unconditional strong
2-cycle on *every placed component in every circuit*; the highest-multiplicity cycle in the
app. `Instance` is a pure forwarder, so it collapses into `InstanceComponent`.

**Do not mechanically port the 19 `WeakReference`/`WeakHashMap` sites** to
`NSMapTable.weakToStrongObjects()`. It compiles, looks correct, and leaks everything: under ARC
those keys are pinned by the very cycles they exist to escape. Each site needs an explicit
eviction owner.

Corollary: Instruments Leaks runs in CI from day one. ARC cycle leaks produce zero test
failures and are invisible without instrumentation.

## D4 — Component identity is reference identity

`Component` is a `final class`; all keying is by `ObjectIdentifier`.

**Synthesized `Equatable`/`Hashable` on `Component` and `AttributeSet` is forbidden.** The Java
relies on reference identity for dirty lists, `componentData`, `CircuitPoints`, and
`BusConnection` matching. Structural equality corrupts simulation silently; it will not throw,
it will produce wrong values.

## D5 — `AttributeSet` type erasure — settled: hybrid

`Attribute<V>` is a generic used as a heterogeneous map key, which Swift cannot express
directly. This shapes all 108 component constructors *and* the `.circ` `<a name= val=>` codec
on both sides, so a wrong choice means rewriting M1, M2, M4, M5.

**Decision — both, split by job:**

- `Attribute<V>` stays generic and is the API components see, so a call site reads
  `attrs[Pin.appearance]` and gets a `PinAppearance?` with full static typing. Its non-generic
  base `AnyAttribute` is the port's `Attribute<?>`, used for set keys and by the codec.
- **Storage and the `.circ` codec go through an `AttributeValue` enum**, one case per concrete
  kind the Java `Attribute` subclasses actually produce, plus `.opaque(String)`.

Why the enum and not `Any`: `.circ` stores every attribute as a plain string, and M2's pass
condition is byte-exact round-tripping. A closed enum makes the string↔value mapping total and
forces every serialisation switch to be exhaustive at compile time rather than failing on one
unusual component at load time. `.opaque` is also what carries D8's unknown-component
round-trip; an attribute we do not recognise survives load→save unchanged.

Each `Attribute<V>` carries an `AttributeCodec<V>` (`parse`/`toStandardString`/`encode`/
`decode`) instead of being subclassed, which is how the ~25 Java `Attribute` subclasses come
across without a parallel class hierarchy.

Localisation does not come across: `Attribute` keeps its raw `name` and the standard-string
codec only. Display names for attributes *and* for values (`toDisplayString`) belong to the UI
layer, as does `getCellEditor`.

Listeners follow D3: `addAttributeListener` returns an `AttributeSubscription` the caller
stores. The set holds the token weakly and the token holds the listener strongly, so dropping
the token unsubscribes and no set→listener strong edge exists to leak.

Implemented in `swift/Sources/LogisimKernel/Attributes.swift`, `AttributeSet.swift`,
`AttributeTextFormat.swift`, `AttributeBridges.swift`.

## D6 — `RenderScene` is the drawing API; CoreGraphics now, Metal at M9

Component `draw` implementations emit typed primitives into a retained scene with a per-instance
colour index. **They never touch a `CGContext` or an `MTLRenderCommandEncoder`.**

Why the abstraction is the real decision: it is what every ported component painter is written
against, **75 `paintInstance` implementations across 65 component files**
(`rg -c 'func paintInstance' swift/Sources`). Retrofitting it later means touching all of them.
*(Recounted 2026-09-13. This read "109 `paintInstance` ports"; no current count supports 109,
and 109 is the number of `paintGhost` mentions, so it looks like the wrong symbol was counted.)*

Why CoreGraphics first: Metal is the right end state; schematic geometry is static integer-grid
and the only per-frame delta is a 6-entry colour palette (`Value.java:296-302`), which is a
textbook instanced-GPU case. But you cannot debug a fidelity port through a renderer you are
simultaneously inventing, with image-diff as the only signal. CG plus viewport culling, cached
`CTLine` text shaping, and no per-component context clone already beats the Java comfortably.

For reference, what the Java does per frame and we do not: one `Graphics2D` clone per component
(`Circuit.java:474` / `:484`, mutually exclusive branches of `if (isNullOrEmpty(hidden))`, so
~5,001 clones/frame at 5,000 components including the frame's own), no viewport culling
anywhere, no spatial index in the codebase, full text re-shaping on every label with line 0
measured twice (`GraphicsUtil.java:282-299`), and a fresh `BasicStroke` per width change across
**253** call sites (counted 2026-09-13 by disassembling the shipped jar:
`javap -p -c` over all 1,964 `com.cburch` classes gives 253 `switchToWidth` invocations and one
declaration; this read 264). The 20 fps cap in `CanvasPaintCoordinator` is not a tuning constant, it is a
defence against a frame costing O(all components).

## D7 — The simulation clock is phase-anchored — headline behavioural fix

Upstream's tick scheduler is `deadline = lastTick + period`, with `lastTick` assigned the moment
the loop *noticed* the deadline had passed (`Simulator.java:540`), after the previous
propagation completed. Errors are absorbed permanently; propagation time is added to the period
every cycle. The weighted-moving-average correction that looks like it compensates is
algebraically zero at the default `smoothingFactor = 1`. Within 1 ms of the deadline it
busy-spins a core (`Simulator.java:468-474`). `TickCounter` then reports the *requested*
frequency whenever it cannot compute a real one, so the UI hides the problem.

The port instead computes `deadline(n) = t0 + n * period` from a fixed origin, waits with
`mach_wait_until` on a `THREAD_TIME_CONSTRAINT_POLICY` thread, and never lets propagation cost
shift the schedule. Simulation time is decoupled from render time; the renderer samples committed
state at display refresh.

Measured on this machine (same language, same workload, same seed; only the algorithm differs):

| case | upstream drift | ported drift | upstream jitter | ported jitter | upstream CPU | ported CPU |
|---|---|---|---|---|---|---|
| 1 Hz, 2 ms prop | 80.3 ms | 3.6 µs | 24.1 ms | 3.2 µs | 0.2% | 0.2% |
| 100 Hz | 8.71 ms | 1.2 µs | 2.52 ms | 2.6 µs | 9.9% | 9.9% |
| 10 kHz | 7.22 ms | 251 µs | 3.07 ms | 3.4 µs | **99.6%** | **22.8%** |

Also required: report achieved rate and jitter honestly, and say so when the target cannot be met.

## D8 — Unknown components round-trip instead of being dropped

Upstream silently drops components from unresolvable libraries and permanently loses them on
re-save; there is no placeholder mechanism anywhere in the codebase.

**Measured, not inferred.** A file carrying `<lib desc="#Legacy" name="99"/>` and one component
using it, loaded and saved through 4.1.0:

```
input :  #Legacy present, Logger component present, 14 components
output:  #Legacy gone,    Logger component gone,   13 components
```

One component destroyed by a plain open-and-save, with nothing in the saved file recording that
it happened. This is not a rare path: 39 corpus files name libraries 4.1.0 does not have
(`#MIPS Tools`, `#Yosys Components`, `#Risc-V`), and any of them loses components this way.

Note the same output results whether the library was removed by the `<2.6.3` repair or simply
dropped as unresolvable; the two mechanisms are indistinguishable from the saved file, which is
why the `<2.6.3` gate cannot be verified by output comparison (see the migration-coverage note
below).

The port round-trips unrecognized `<comp>`/`<lib>` XML verbatim as opaque placeholders. This is
the only thing that makes the permanent `jar#` gap (D11) non-destructive. It changes `Circuit`'s
data model, so it cannot be retrofitted cheaply.

## D9 — Module boundaries

`LogisimKernel` (Swift 5, no Concurrency) → `LogisimFile` → `LogisimRender` → `LogisimUI`, plus
`logisim-cli`.

`LogisimKernel` must stay genuinely UI-free: no AppKit import, no `Value.getColor()` returning a
colour (it returns a palette *index*), no `AppPreferences` reach-in. That is what makes the
headless differential harness possible. Note `AppPreferences` currently has **287 of 1,204**
files depending on it; that coupling does not come across.

## D10 — Distribution: GPL-3.0-only, notarized DMG, no App Store

Upstream is GPL-3.0-**only**; the "or any later version" boilerplate is deliberately absent from
`LICENSE.md`. A Swift translation is a derivative work, so the port is GPL-3.0-only, permanently.

**The Mac App Store is not available**, on three independent grounds: the Standard EULA makes the
licence nontransferable and device-limited (GPLv3 §10 forbids such further restrictions), the
Usage Rules impose account/device counts and a noncommercial limit that bind the user by contract
with Apple regardless of what EULA the developer supplies, and the anti-circumvention duty
conflicts with §3. A Custom EULA does not cure the Usage Rules. VLC and GNU Go were both pulled
over exactly this.

Relicensing is not achievable: ~183 contributors, no CLA, no DCO.

Ship: Developer ID signed + notarized DMG, plus a Homebrew cask, with the source repo linked
beside every binary (§6(d)). Note upstream *cannot* do this; maintainers stated in issue #2699
that they have no paid Apple Developer account, and the existing Homebrew cask is deprecated and
scheduled for disablement.

Obligations to honour: §5(a) prominent modified-version notice with a date; §5(b) GPLv3 notice;
Appropriate Legal Notices in the UI; Corresponding Source includes the whole build pipeline, not
just the Swift sources. Distinct app name, own icon, own bundle ID, and **own document UTI**;
do not claim upstream's `application/x-logisim-circuit`.

Attribution: two lineages, Carl Burch (original Logisim) and the logisim-evolution developers.

## D11 — ~~Permanent functional gaps~~ → **CAPABILITY PARITY IS NON-NEGOTIABLE**

**Superseded 2026-09-08 by owner decision. Quoted, because the framing matters more than the
list:** *"so we need full parity, thats the problem ur not getting, if smth is genuinely
unportable: aight, still maintain functionality and refine it in that language. swift is a
preference, native is a preference, we can just be honest in the readme and call it a day."*

**The policy.** Every capability 4.1.0 offers a user, this port offers. When the Java *mechanism*
does not translate to AOT Swift, the *capability* is reimplemented natively and the README
documents the difference. "Permanent gap" is no longer an available disposition, and neither is
greying a menu item out and calling it honest; a greyed item is a missing feature with better
manners. Only two things justify not shipping a capability: it is physically impossible on macOS,
or the owner has explicitly deferred it (D12-style, with a date).

**This retires a disposition I had been recommending.** Several boards proposed making
`exportProject`, `extractRunProject`, `mergeProject` and `openFpgaWindow` return `false` from
`canPerform` so they grey out. That is now wrong. They get ported.

Item by item, with what parity actually requires:

- **JAR component libraries (`desc="jar#file.jar#com.Foo"`).** Java does `ZipClassLoader` +
  `Class.forName` + reflective instantiation; AOT Swift has no equivalent and never will. **The
  capability is "extend the app with third-party component libraries", and that ships**: as a
  native plugin ABI loading `.dylib`/bundle, or compiled-in libraries, or an interpreted
  descriptor format. Choice deferred to whoever builds it; *not* building it is not a choice.
  Until then `D8` already round-trips the descriptor verbatim so no user file is damaged.
- **Vendor FPGA toolchains (Xilinx ISE/Vivado, Intel Quartus).** These have never shipped a macOS
  build, so the port cannot invoke them: you cannot exec software that does not exist for the
  platform. **This is the one genuine physical constraint, and the capability still ships** via
  the open toolchain: ghdl, yosys, nextpnr-ecp5, ecppack, openFPGALoader, all native on Apple
  Silicon through Homebrew. A user synthesises and programs an FPGA; the vendor chain differs.
  README states it plainly. The FPGA Commander UI itself (86 files) is ordinary porting work.
- **`std/tcl`.** Needs a `tclsh` subprocess over a socket. Ordinary macOS work. Ships.

**The README carries the differences, not the code comments.** Anywhere the mechanism diverges,
say so in the README where a user reads it, rather than burying it in a source header where only
a maintainer finds it. Honesty about *how* something is implemented is the price of parity, not a
substitute for it.

## D12 — Third-party content not inherited — **DEFERRED by owner decision**

Upstream ships content it does not own the rights to: vendor product photography with visible
trademarks embedded in the board XMLs (e.g. a 1600×1002 Digilent Basys 3 photo showing
DIGILENT®, XILINX, ARTIX-7™), two non-free fonts under `artwork/fonts/`, and the Hendrix College
crest. There are also 36 `.java` files with no licence header and unmarked attribution debts
(David Koelle, MIT; Helmut Neemann).

Owner has deliberately deferred this; it is not a blocker for the code port. Revisit before any
public binary is distributed, since it attaches to distribution rather than to development.

## D13 — A catchable Java exception becomes a Swift `throw`, never a trap

Found by the M1 golden gate on its first run, and it is systemic: the initial port turned
Java's unchecked `RuntimeException`s into `preconditionFailure`/`fatalError`, reasoning that
"unchecked" ≈ "untrappable". That reasoning is wrong in consequence.

`Simulator.java:520`, `:533` and `:556` wrap propagation in `catch (Exception err)` →
`recordException(err)`. So in the Java, a component that misbehaves during propagation produces
a **circuit error the user sees**. A Swift `preconditionFailure` is not catchable and terminates
the process, converting a recoverable simulation error into **an app crash with unsaved work
lost**. That is a worse outcome than the bug being ported.

Concrete case the gate caught:

| input | Java | initial Swift port |
|---|---|---|
| `set(99, TRUE)` on a width-4 value | throws `RuntimeException` (catchable) | `preconditionFailure`; process dies |
| `get(99)` on a width-4 value | returns `ERROR` | matches |

Note the asymmetry in the Java is deliberate: `get` returns `ERROR`, `set` throws. Preserve it.

**Rule.** Where the Java throws an exception that can reach `recordException`, anything on the
propagation, attribute, or file-loading paths, the Swift must `throw`, so the simulator can
catch it and mark the circuit in error.

**Trapping remains correct** for genuine programmer errors that no user input can reach:
abstract-method stubs (`AnyAttribute` is abstract, `AbstractAttributeSet` subclass
requirements), and internal invariants a caller cannot violate from a `.circ` file.

### Audit result — complete, 25 traps → 14

**Converted to `throws` (11), all reachable from an ordinary `.circ` file:**

| site | Java | why it is reachable |
|---|---|---|
| `Value` ×7 | `RuntimeException` / `IllegalArgumentException` | over-wide bus, `repeat` on a multi-bit base, mismatched wire widths, malformed `PullResistor`, `set` misuse |
| `BitWidth.create` ×2 | `IllegalArgumentException` (`BitWidth.java:72/74`) | `<a name="width" val="999"/>` |
| `AttributeSet.setRawValue` ×2 | `IllegalArgumentException` (`AttributeSets.java:72/81/130/137`) | a component element naming an attribute its factory does not define, or writing a read-only one |

Error types: `ValueError`, `BitWidthParseError`, `AttributeSetError`.

Two consequences worth knowing:

- `BitWidth.known(_:)` was added alongside the throwing `create(_:)`, for widths already proven
  in range (literals, or derived from an existing `BitWidth`). It traps, correctly; a literal
  `BitWidth.known(8)` cannot fail on user input.
- **`AttributeSet`'s subscript is now read-only.** `setValue` throws and a Swift subscript
  setter cannot, so writes go through `try attrs.setValue(attr, value)`. Keeping `attrs[x] = y`
  would have meant swallowing the error, which is exactly the failure D13 exists to prevent.

**Left trapping (14), none reachable from file input:**

- 8 abstract-method stubs: `AnyAttribute` ×3, `AbstractAttributeSet` ×5. Java declares these
  `abstract`, so the compiler makes them uncallable; Swift has no equivalent and `fatalError`
  is the idiomatic stand-in.
- 6 API-misuse cases: `setReadOnly` on an absent attribute ×2, `copyInto` with a mismatched
  set type ×2, `setReadOnly` on a set that does not support it ×2. All are programmatic; no
  `.circ` file reaches them.

## D14 — `Location` is not interned, and that is a deliberate divergence

Java's `Location.create` caches on `hashCode = 31 * xRounded + yRounded` and returns the cached
instance when `loc.x == xRounded && loc.y == yRounded`; **without comparing `hasToSnap`**
(`Location.java:21-31`). The returned object therefore carries whatever snap mode it was *first*
created with, anywhere in the JVM.

Measured, same build, same inputs, only creation order differing:

```
fresh JVM:                        Location.create(0,0,false).translate(1,0)  ->  (1,0)
after Location.create(0,0,true):  Location.create(0,0,false).translate(1,0)  ->  (0,0)
fresh JVM:                        Location.create(5,0,false).translate(-1,0) ->  (4,0)
after Location.create(5,0,true):  Location.create(5,0,false).translate(-1,0) ->  (0,0)
```

So in upstream, whether a translate snaps depends on unrelated earlier allocations. That is a
bug, not a behaviour, and it is not reproducible by construction; replicating it would mean
importing process-global nondeterminism into the kernel.

**The port drops the cache** (`Location` is a struct, so interning buys nothing) and is
therefore deterministic: it always honours the `hasToSnap` it was given. It matches Java's
cold-cache behaviour, which is what upstream evidently intends.

Consequence for the harness: `P translate … false …` golden cases are order-dependent on the
Java side, so `gen_golden.py` emits them before anything that could warm the cache for the same
coordinates. If they are ever reordered, they will "fail" against a correct port.

## D15 — Wide arithmetic, and the `create_unsafe` narrow-width invariant

Two findings from the M1 adversarial review that are constraints on *future* work rather than
bugs in current code.

### `Int128` is not wide enough for the arithmetic components

`Value.toBigInteger(unsigned:)` returns `Int128`, which holds every value *that method* can
produce. It does not hold what the callers then compute:

| call site | operation | needs |
|---|---|---|
| `Multiplier.java:72` | `aa.multiply(bb)` | `(2^64-1)^2` ≈ 3.4e38, past `Int128.max` ≈ 1.7e38 |
| `Divider.java:68` | `.shiftLeft(64)` with bit 63 set | 128 *unsigned* bits |
| `Exponentiator.java:73` | `aa.pow(b)` | unbounded: 3^100 is 5.15e47 |

At M5, Multiplier and Divider use `Value.magnitudeUInt64` with
`UInt64.multipliedFullWidth(by:)` / `dividingFullWidth(_:)`. **Exponentiator needs a real
arbitrary-precision integer**, which Swift's standard library does not have; that is a known,
scheduled dependency, not something to discover mid-port.

### `create_unsafe` must not be called with width < 2

Java's narrow-width branches in `and`/`or`/`xor`/`not`/`combine` compare by **reference** against
the interned singletons (`Value.java:329-332`, `:370-374`, `:792-796`). A value from
`create_unsafe` is never interned, so at width 1 those comparisons all miss and the result is
`ERROR`:

```
Java:  Value.create_unsafe(1,0,0,1).and(itself)  ->  ERROR
Swift: Value.createUnsafe(width:1,…).and(itself) ->  TRUE
```

Upstream never hits this because `CircuitWires.java:348-352` returns early for `width <= 0` and
`width == 1`, well before the `create_unsafe` at `:377`. The guard is 400 lines from the call it
protects, which is exactly the kind of invariant a port drops silently.

The port does **not** replicate the quirk; reference-identity results are an artifact of
interning, not intended behaviour, and the port has no interning to reproduce. Instead:
**when `CircuitWires` is ported at M3, the `width <= 1` early return is mandatory and must be
covered by a test.** `createUnsafe` itself stays permissive, because the `X` golden cases
deliberately probe out-of-range widths where Java is also permissive.

#### Correction, 2026-09-05 — the guard is right, but NOT for the reason above

Verified in the port (`LogisimKernel/Propagation/CircuitWires.swift`, `ValuedBus.recalculate()`):
all three early returns are present in Java's exact order and `createUnsafe` is reached only at
`width >= 2`. The code is correct. **The reasoning in this entry is not**, and that matters,
because a stated rationale that does not hold is an invitation to delete working code.

The interning argument above is Java's, and it does not transfer: `Value` is a **struct** here
with no interning, so a width-1 `createUnsafe` value is `==`-equal to the canonical one and every
operator behaves normally. **Remove the guard for that reason alone and nothing would change.**

#### Second correction, same day — MY replacement rationale was also wrong

I wrote that guard 3 "converts a width-1 bus whose thread is NIL from `E` into `NIL`", reasoning
that the fold's `else` branch catches `.nilValue`. **That mechanism does not exist.**

`ValuedThread.threadValue()` **cannot return NIL.** It seeds `.unknownValue`, and its only
mutation is `combine` with `Value.get(_:)`, which is *total*: an out-of-range index yields
`.errorValue`, never NIL (`Value.swift:865-872` = `Value.java:456-463`), and `combine` over
width-1 operands is closed over {T, F, U, E}. **The fold's `else` branch is unreachable at width
1.** A test now pins that.

So there is no behavioural difference to find, and the measurement says so at two levels:
deleting guard 3 leaves `NarrowWidthBusTests` **9/9 green** and the corpus gate at **1,343 / 48 of
1,391 with a byte-identical failure list** (`diff` exit 0). No test can go red when it is removed.

**Guard 3 stays anyway, and the honest reason is D16, not a mechanism:** upstream has it, the port
target is 4.1.0, and "be 4.1.0" is the standard. Inventing a local justification for it was the
error: twice over, first Java's interning argument and then mine.

**Guards 1 and 2 ARE load-bearing here**, and that is measured rather than assumed: both test
buses have `threads == nil`, so without the early return they reach the fold and *throw*
`staleConnectivity`, turning a value Java computes into a simulation error. Disabling either turns
2 unit tests red.

Also corrected at the site: the file header cited "**344 false divergences**" as a `CircuitWires`
measurement. That number belongs to `tools/valuebridge/ValueBridge.java`: its own header explains
that building cases through `create_unsafe` defeated Java's identity branches. It was never a
`CircuitWires` result.

**The test this entry demanded now exists**: `LogisimKernelTests/NarrowWidthBusTests.swift`, 9
tests over a real `ValuedBus`/`WireBundle`/`WireThread`/`Connectivity` fixture, mutation-checked
one guard at a time. It took from M3 planning until 2026-09-05 to write, which is the actual
lesson: a *mandatory* requirement recorded in a binding decision and enforced by nothing
enforced by anything that fails.

## D15a — `String.split` is not `split`, and it has bitten five call sites in two modules

Added 2026-09-05, after this one Java behaviour produced defects in the codec and in every HDL
component family, and after *two* attempts to fix it were themselves wrong.

**Java's one-argument `String.split(String)` uses limit 0, which discards ALL trailing empty
fields.** Swift's `split(separator:omittingEmptySubsequences: false)` keeps them. Probed on
openjdk@21; these are literal outputs, not reasoning:

| input | `.split(",")` / `.split("\n")` |
|---|---|
| `""` | len 1, `[""]` |
| `","` | len 0, `[]` |
| `",,"` | len 0, `[]` |
| `",a"` | len 2, `["", "a"]` |
| `"a,,"` | len 1: `["a"]` |
| `"\n"` | len 0: `[]` |
| `"a\n\n"` | len 1, `["a"]` |

The empty-input row looks inconsistent with the all-separators rows and is not: **Java returns the
whole input when the pattern never matches**, so `""` survives as `[""]`, while every other
trailing empty is *produced by a match* and is therefore discarded.

Use `javaSplit` (`LogisimHdl/LineBuffer.swift`) or `javaSplitOnLiteral` (`LogisimFile`). Do not
hand-roll it a sixth time.

**Two wrong fixes are worth recording, because both looked right.** Returning `[]` for `""`
deletes every `LineBuffer.empty()` in every generator: the memory family measured that as 14
failures becoming 152. Guarding with `count > 1` instead, "one empty field survives", fixes
`""` and breaks every all-separator input. The second one shipped, and was caught only because
the codec's copy was being fixed for the same behaviour at the same time and had arrived at a
different shape. **Two implementations of one semantic disagreeing is the same defect pattern as
every seam in this project**: each half plausible, nothing owning the join. Here the join was a
fact about Java, and the jar settled it.

Pinned by `JavaSplitSemanticsTests`, whose expectations are the probe's stdout.

## D15b — Where parallelism applies, and where it is explicitly rejected

Added 2026-09-05. Settled so it is not relitigated: this is a latency-bound graph workload, not a
throughput one, and most of the obvious hardware levers do not apply to it.

**The simulation kernel stays single-threaded.** Event-driven propagation is serial by data
dependence, tick N+1 needs N, the work units are nanoseconds, and it pointer-chases a netlist,
so it is latency-bound. D1 already records the specific cost of changing this: `propagate()`
becoming `async` infects all 108 implementations and destroys the reusable `InstanceStateImpl`
scratch object, a documented ~90% speedup that is only safe *because* propagation is synchronous.
Threading it would be slower and cost a rewrite.

**No GPU for simulation, and no GEMM anywhere.** There is no dense linear algebra in a logic
simulator, so the matrix/neural units have nothing to do. Simulation itself is the wrong shape for
a GPU, divergent control flow, tiny kernels, serial dependencies, and kernel-launch latency
alone exceeds the time to propagate a small circuit on CPU.

**Metal is for the canvas, and only the canvas.** D6 already sequences it: `RenderScene` now, a
CoreGraphics backend today, Metal at M9. A large circuit is thousands of retained primitives, and
that is a genuine GPU workload. This is the one place the GPU earns its place.

**CPU SIMD is the real win, in exactly one place: bitsliced truth tables** (task #46). `Value` is
already a 2-bit encoding, so 64 input assignments pack into a `UInt64` per net and the circuit
evaluates once per 64 rows with bitwise ops. Valid for combinational evaluation only.

**Thread QoS is load-bearing for D7, and is already correct.** `SimulationClock` sets
`.userInteractive` and applies `RealtimeThreadPolicy` to the propagation thread. D7's headline
claim is that 1 Hz is actually 1 Hz; that survives only if the clock thread is not preempted.
Do not lower it.

*Hardware note:* this machine reports `hw.perflevel0.name = Super` (6 cores, 16 MB L2) and
`hw.perflevel1.name = Performance` (12 cores, 8 MB L2): Apple's M5-era naming, with no efficiency
cluster. Do not assume a P/E split when reasoning about scheduling here.

## D16 — Port target is **4.1.0**, and the reference tree must be the tag, not main

### The trap this decision does not protect you from (added 2026-09-06)

**The development fork contains a full Java tree at `src/main/java`, and it is upstream `main`,
not 4.1.0.** The port is a fork of logisim-evolution, so `origin/main` is upstream's Java and the
fork's working tree carries it alongside the Swift port. It is the most convenient thing in the
world to grep, and it is the wrong version. (That tree is not published: this repository holds
the port only, so the hazard below is a note on how the citations were produced rather than
something you can reproduce here.)

Measured: `computeEditMenuEnabled` appears **once** in `src/main/java/…/gui/main/Frame.java` and
**zero** times in `~/Developer/logisim/upstream-java-4.1.0/…/gui/main/Frame.java`.

This has already cost real work. An agent auditing `EditBridge`'s frame dereferences read the
in-repo tree, concluded `TextTool.refreshEditMenu → Frame.computeEditMenuEnabled()` was a live
fifth dereference, and wrote the override; **which did not compile**, because neither the method
nor the call exists in 4.1.0. It was caught only because that particular error happened to be a
compile error; re-checking the rest of that audit against the 4.1.0 tree then found **four more
wrong line citations** that would have been silently wrong forever.

So, concretely:

  * **Read `~/Developer/logisim/upstream-java-4.1.0`.** Never `src/main/java`, never
    `~/Developer/logisim/upstream-java` (4.2.0-dev).
  * **A line citation is a claim about a specific tree**, and one read from the wrong tree looks
    exactly like one read from the right tree. `javap` on the shipped jar settles it when a
    signature is in doubt.
  * Every agent brief that asks for Java references should name the 4.1.0 path explicitly, which
    is why they do.

This is the same shape as the six instrument failures logged in `objectives.md`: the tool was fine
and the *input to the tool* was the wrong artefact.

The oracle jar (`/Applications/Logisim-evolution.app/.../logisim-evolution-4.1.0-all.jar`) and
Erwin's installed app are **4.1.0**. The original `upstream-java` clone was `main`, which reports
`version = 4.2.0-dev`. **They differ**, and the difference lands exactly where M2 is measured:

```
git diff --stat v4.1.0 HEAD -- .../logisim/file .../logisim/data
   XmlWriter.java     |  47 ++++--          <- byte-exact output IS the M2 pass condition
   Loader.java        |  52 +++++--
   XmlCircuitReader   |  34 ++++-
   XmlReader.java     |  25 +++-
   LogisimFile.java   |  19 ++-
   ... 388 insertions(+), 89 deletions(-)
```

Concretely observed: 4.2.0-dev added `public void write(OutputStream, LibraryLoader, File)`;
the 4.1.0 jar has no such overload and every `write` is package-private. Code written against
the main-branch signature does not compile against the shipped jar.

**Reference tree: `~/Developer/logisim/upstream-java-4.1.0`** (a git worktree at tag `v4.1.0`).
`upstream-java` remains on main for comparison only. Any line citation must come from the 4.1.0
tree; earlier notes citing main are off by a little (the old-format dialog is
`XmlReader.java:414` in 4.1.0, not `:405`).

Porting main-branch behaviour while diffing against a 4.1.0 oracle would have produced
systematic failures indistinguishable from port bugs.

## D17 — Dialogs are disabled with `Main.headless`, and the converter is a bridge

`OptionPane` gates every dialog on `Main.hasGui()`:

```java
if (Main.hasGui()) { JOptionPane.showMessageDialog(...); }   // modal, blocks forever
else if (message instanceof String msg) { logger.info(msg); } // a log line
```

`Main.headless` is a public static field and `hasGui()` is `!headless`, so setting it converts
every warning into a log line. Without it, generating baselines across the corpus pops modal
dialogs at whoever is at the keyboard: the pre-2.7.2 "Old file format" notice (116 corpus
files) and "the built-in library X is not available" for `#MIPS Tools`, `#Yosys Components` and
`#Risc-V`, which appear in 39 more.

`tools/valuebridge/CircBridge.java` replaces `-jar logisim.jar -n in out`. `-n` routes through
`ProjectActions.doOpen`, which builds a `Frame` and therefore needs a GUI; the bridge goes
through `Loader` + `LogisimFile` instead. It is declared in `com.cburch.logisim.file` because
4.1.0's `write` overloads are package-private (D16), and it batches: one JVM converts every
pair on stdin, at **0.15 s per conversion versus 0.9 s** for `-n`.

Two traps worth remembering:
- **It must call `System.exit(0)`.** Loading a `LogisimFile` initialises AWT and starts the
  non-daemon EDT, so without it every conversion succeeds and the JVM then hangs at exit;
  which looks exactly like a blocking dialog and is not one.
- A fresh `Loader` per file. Sharing one lets library-resolution state leak between files,
  which is the kind of order dependence that makes a baseline irreproducible.

Genuine failures still surface: a file naming `#MIPS Tools` raises `LoadFailedException`
because that library does not exist in 4.1.0; upstream cannot load it either.

---

## Verification oracles (established, M0)

The Java app is the oracle. `openjdk@21` (Homebrew) runs the shipped 4.1.0 fat jar at
`/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar`. The bundled
runtime has no `bin/java`, jpackage strips it, so use the Homebrew JDK.

| Oracle | Command | Gates | Notes |
|---|---|---|---|
| Truth table | `-Djava.awt.headless=true -jar J --toplevel-circuit <c> -tty table <f>` | M3–M5 propagation | Combinational circuits only. `--toplevel-circuit` drives any subcircuit, which multiplies coverage substantially. |
| Canonical round-trip | `-jar J -n <in> <out>` | M2 writer | **Not headless-safe** (constructs an AWT `Window`); needs a GUI session. **Not idempotent at pass 1**; reaches a fixed point at pass 2, so canonical form is `-n(-n(f))`. |
| Migration fidelity | `-n(f)` vs Swift load(f)→save | M2 migration | Pass-1 output specifically. The pass1/pass2 delta is real migration state (e.g. pre-4.0 `Pin.appearance` defaults), not noise. |
| Test bench | `-jar J -b <f>` | sequential circuits | Returns success/fail. |
| Test vectors | `.tv` files via `TestVectorEvaluator` | sequential circuits | Corpus ships real ones (`test.txt`, `op*_test.txt`, format `A[4] B[4] Cin S[4] Cout`). |

**Corpus.** Seeded from a private CSC258 repo: 17 `.circ` files, 107 circuits, `source=` 3.6.1
and 3.7.2 (so the 4.0.0 migration gate is exercised; older gates 2.3.0/2.6.3/2.7.2 are **not yet
covered** and need files harvested from upstream's 1,002 forks).

**The corpus and its golden outputs must never be committed to this public repo.** They derive
from private coursework, and the golden truth tables are effectively lab solutions. The rig takes
the corpus path from the environment.

Also load-bearing: every corpus file declares **12** builtin libraries while instantiating
components from only 2–3. The loader must resolve all 12 declarations or the file will not open,
so all 12 library shells must be registerable at M2 even though SoC/TCL components come much
later.

## D18 — When the port reproduces an upstream defect, and when it fixes one

The tree already does both, and until now nothing said why. Every `Bug-for-bug` comment in it sits
in the codec/attribute path, `CircuitAttributes.swift:199,258,369`, `SocBusAttributes.swift:150,174`
, while D7 (tick scheduling) and D14 (`Location` interning) diverge outright. That is not
inconsistency; it is an unstated rule, and this is the rule.

**Reproduce the defect when it is deterministic AND observable in a gate.** The gates are the
contract: `canonical`/`migration` compare bytes against the jar's own converter, `-tty table` and
`-tty stats` compare its stdout. Anything upstream does that shows up there is not a bug to us, it
is the specification; `LABEL_LOCATION_ATTR` not being copied by "Copy circuit" produces different
bytes, so copying it "correctly" would fail the gate and be *wrong*.

**Fix it when it is non-deterministic, or when it is unobservable in any gate and plainly a
defect.** Non-determinism cannot be a contract: upstream's `Location.create` returns a cached
instance whose `hasToSnap` depends on unrelated earlier allocations (D14), so there is no behaviour
to be faithful *to*. And where no gate can see it, the GUI has no jar oracle, which
`CircuitAnalysis.swift`'s header has said since it was written, reproducing a defect buys nothing
and costs the user.

**Three obligations, none optional.** A divergence must be (1) *measured* against the jar, not
argued from reading; (2) recorded at the site, naming the upstream file and line; and (3) covered
by a test that fails if the port silently drifts back. D7 carries a drift/jitter table, D14 a
reproduction transcript. A divergence with no measurement is indistinguishable from a porting
mistake, and that is the whole problem it has to avoid.

### The case that forced this: 4.1.0's Minimize buttons cannot work

Measured while porting them (board #68). `OutputExpressions.forcedOptimize` iterates `outputData`,
which `OutputExpressions` fills **lazily**. In the analyzer GUI the only thing that fills it is
`MinimizedTab.updateTab` → `getMinimalExpression(output)` (`MinimizedTab.java:452`), reached only
by selecting the Minimized tab: which `Analyzer.java:126` **disables** at `nrOfInputs > 6`, the
exact and only condition under which `Analyzer.java:116-119` **enables** the Minimize buttons.

    n=7 SOP UNTOUCHED-FIRST  AFTER=[0]  REPORTLEN=0

So in 4.1.0 the buttons are a no-op on every circuit that took the truth-table path. They appear to
work only when `Analyze.computeExpression` succeeded, because that path calls `setExpression` per
output and populates the map as a side effect.

This is squarely in the second category, a GUI action, invisible to every gate, and useless
rather than merely surprising, so **the port fixes it**: `Minimization.run` touches every output
bit before optimising. Recorded in `Minimization.swift`, and the test asserts the fixed behaviour
while pinning upstream's measured one beside it, so the divergence stays a decision rather than
becoming folklore.

---

## D19 — The canvas has no origin wall, because this port's camera is unbounded

Upstream enforces a non-negative quadrant in four places. This port removes all four. The
decision is D18's second category, a GUI behaviour no gate can observe, which costs the user
something real, and it was taken on a report from hands-on use, with the pointer readout sitting
at (78, −108) while the component refused to follow:

> there seems to be invisible limits to canvas size. this is the highest it will go but clearly
> tons of canvas left … kinda be unlimited canvas size but when we save photo or smth, wrap to
> like a certain distance from actual elements

### Why upstream needs the wall and this port does not

`com.cburch.logisim.gui.main.Canvas` is a `JScrollPane` viewport over a component whose
**preferred size is the circuit bounds times the zoom** (`Canvas.computeSize`). The drawable sheet
therefore begins at the origin and there is nowhere above or left of it to scroll to: one of the
three symptoms of issue #1262, quoted at length in `CanvasViewport`'s header. Given that,
`SelectTool.computeDxDy`'s clamp is not an arbitrary restriction, it is what stops a user dragging
a component somewhere the scrollbars can never reach again.

This port's camera is `(center, zoom)` with no bounds of any kind, and pan is a direct translation
in world units. The quadrant the wall protected does not exist here, so the wall only removes
reachable space.

### The five sites

| site | upstream | now |
|---|---|---|
| `SelectTool.computeDxDy` | `dx = Math.max(e.getX() - start.getX(), -bds.getX())` | the raw delta, still grid-snapped |
| `AddTool.performPlacement` | `if (bds.getX() < 0 …) setErrorMessage(negativeCoordError)` | removed, with the `ToolStatusMessage` case |
| `TextTool.createTextComponent` | `if (loc.getX() < 0 …) return` | removed |
| `SelectionBase.copyComponents` | `bds.getX() + dx >= 0` | `>= min(bds.x, 0)` |
| `SearchNode.next` | `if (nextLoc.getX() < 0 …) return null` | removed |

**The fifth was found by the owner, not by the sweep**, one build later: "objects do drag
anywhere, wires dont follow at same prev boundary." The wire router is a separate subsystem under
`Tools/Move/` and the first four were found by grepping `Tools/*.swift`, which does not recurse.
With the drag clamp gone the component moved, the route's destination sat outside the router's
pen, `findShortestPath` exhausted, and the connector published an empty replacement map, so every
attached wire stayed put. The port's own comment on that line had predicted it verbatim: "a route
never leaves the first quadrant even though the rest of the engine would happily go there."

Removing it does not make the A* unbounded, because it never bounded it: `next` refuses nothing in
+x or +y, so the space was already infinite and termination comes from `Connector`'s
`maximumSearchIterations` (20,000 expansions) and `maximumSeconds` (10). And route fidelity is
untouched for anything upstream can draw; a node only offers a negative neighbour when it is
within one 10-unit step of an axis. Measured, not argued: `EditParityTests` runs
`05-move-selection` and `09-move-reconnects-wire` through the real router and byte-compares the
resulting wires against the 4.1.0 jar's. Both still match.

The fourth is a **relaxation, not a deletion**, and that distinction is the whole of its safety.
The ring search's offsets are byte-exact territory: the (10, 10) a duplicate appears at is
emergent from the search, not a constant anywhere in the code. For any group in the non-negative
quadrant `min(bds.x, 0)` **is** `0`, so the condition is character for character upstream's. For a
group already above the origin a literal `0` stops being "keep the copy on the sheet" and becomes
"drag the copy back to it": measured, a gate at (−400, −300) copied under the old floor lands at
(50, 150), 450 units from its original.

### The obligations D18 requires

1. **Traced before it was changed, not after.** `NegativeCoordinateTraceTests` drives a component
   at (−200, −140) through grid snapping, the `.circ` round-trip, hit testing, zoom-to-fit and
   image export. All five already worked; the negative branches in `CanvasGrid.snapXToGrid` and
   `SpatialIndex`'s bucketing were written years of commits before anything could reach them.
2. **Recorded at each site**, naming upstream's line.
3. **Covered.** `NoOriginWallTests` (eight tests) and `WireRoutesPastOriginTests` (three).
   Restoring any one of the five guards reddens its own test and only its own; the router probe
   reddens both negative-side routing tests and leaves the positive-quadrant calibration green.

### The finding that came with it

Deleting the first four guards left the suite at **1,676 passing**. Not one of them was gated by
anything: a rule enforced in four files that no test watched, which is the state in which a later
edit can restore half of it with no signal at all. `NoOriginWallTests` exists as much for that as
for the divergence.

### What the report's second half asked for, which was already true

> when we save photo or smth, wrap to like a certain distance from actual elements

Image export is `circuit.bounds.expand(5)` and print is `circuit.bounds.expand(4)`, both
upstream's own rule and both origin-independent, so a circuit above the axis is already cropped to
itself rather than to the quadrant. Asserted rather than assumed, in
`NegativeCoordinateTraceTests.exportWrapsTheContentNotTheOrigin`.
