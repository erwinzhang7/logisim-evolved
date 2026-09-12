# LogisimStd — the shape every component port follows

This module holds the component chassis and one worked exemplar per family. The bulk port
copies these shapes across ~350 components, so **follow this file literally**. If a component
does not fit one of the five shapes below, that is a signal to stop and think, not to invent a
sixth.

Reference tree is **`upstream-java-4.1.0`** (D16). Never port from `upstream-java` (main).

---

## 0. The chassis in one page

| Java | Swift | Where |
|---|---|---|
| `InstanceFactory` (abstract class) | `InstanceFactory` protocol + `InstanceFactoryBase` class | `Instance/InstanceFactory.swift` |
| `Instance` (facade) | **deleted**: D3 | folded into `StdInstanceComponent` |
| `InstanceComponent` | `StdInstanceComponent` | `Instance/StdInstanceComponent.swift` |
| `InstanceState` | `InstanceState` protocol | `Instance/InstanceState.swift` |
| `Port` (mutable class) | `Port` struct | `Instance/Port.swift` |
| `configureNewInstance` + `instanceAttributeChanged` + `computeEnds` | `func ports(_:) -> [Port]` | see below |

### The one structural change: ports are a pure function

Upstream declares connection points through three cooperating methods and a mutable array.
Every one of the ~350 implementations reads *only* the attribute set. So they collapse into

```swift
open override func ports(_ attributes: any AttributeSet) -> [Port]
```

and `StdInstanceComponent` recomputes-and-diffs on every attribute change. The diff recovers
exactly what upstream's `instanceAttributeChanged` filter bought: an attribute that does not
affect the ports produces an identical array and fires nothing.

**Consequence for the bulk port: never write an `updatePorts(instance)`.** Transcribe its body
into `ports(_:)` as a pure function of `attributes`, delete the `instance.setPorts(...)` call,
and delete the `instanceAttributeChanged` branches that only called `updatePorts`,
`recomputeBounds` or `fireInvalidated`. Keep `instanceAttributeChanged` **only** when it does
something else (memory resizing, poking its own `InstanceData`).

### Fixed vs. computed

| the component's … | is fixed | is attribute-dependent |
|---|---|---|
| bounds | `setOffsetBounds(_:)` in `init` | `override func offsetBounds(_:)` |
| ports | `setPorts([...])` in `init` | `override func ports(_:)` |
| attributes | `setAttributes([...])` in `init` | `override func createAttributeSet()` |

Never do both for the same thing. `Adder` is all-fixed; `Multiplexer` is all-computed;
`Constant` and every gate are computed with a bespoke attribute set.

### D13 — what throws

| call | throws? |
|---|---|
| `propagate(_:)` | **yes**, always declared `throws` |
| `Value.create([Value])`, `Value.repeat`, `Value.set`, `BitWidth.create` | yes |
| `Value.createKnown`, `Value.createError`, `Value.createUnknown`, `BitWidth.known` | no |
| `attrs.setValue(_:_:)` | yes (and `attrs[x]` is **read-only**) |
| `createComponent`, `validateAttributeSet` | yes |
| `offsetBounds`, `ports`, `contains`, `hasThreeStateDrivers` | **no**, protocol forbids it |

A trap (`fatalError`/`precondition`) is correct **only** for things no `.circ` file can reach:
abstract-method stubs, and internal tables the component itself declares.

### D6 — drawing is out of scope

Every `paintInstance`/`paintGhost`/`paintIcon` becomes a comment at the bottom of the file:

```swift
// PAINT (M6): <one line saying what it draws>. See <JavaFile>.java:<lines>.
```

Grep `PAINT (M6):` to find the M6 work list. **Do not import AppKit or CoreGraphics.**

### Java-vs-Swift arithmetic

`Instance/JavaBits.swift` holds the shift helpers. The rules:

* `a + b` on a Java `long` → **`&+`** in Swift. Swift traps on overflow; Java wraps, and
  several components (Adder at width 64) depend on the wrap.
* `1L << n` → `javaLongBit(n)`. Java masks the distance by 63; `1L << 64` is `1` in Java and
  `0` in Swift.
* `1 << n` assigned into a `long` → `javaIntBitWidened(n)`; `~(1 << n)` →
  `javaIntBitComplementWidened(n)`. These reproduce Java's `int`-shift-then-sign-extend.
* `(int) (x >> n) & 1` → `javaLongBitAt(x, n)`.

### Equality

Java compares `Value`, `AttributeOption` and `Direction` singletons with `==` (reference).
Swift compares structurally. **This is safe and needs no per-site thought for `Value` at width
≤ 1 and for `AttributeOption`**, because Java interns both and the options have distinct names.
Say so in a comment at the site, once per file, and move on.

---

## 1. gates — exemplar `Gates/AndGate.swift`

**Files:** `AbstractGate.swift` (family base, done), `GateAttributes.swift`,
`NegateAttribute.swift`, `GateFunctions.swift`; all shared and already written. A concrete
gate is **one small file**.

**The whole of a gate:**

```swift
public final class AndGate: AbstractGate {
  public static let id = "AND Gate"       // NB: no `_ID` in Java; the ctor string IS the token
  public static let factory = AndGate()

  public init() {
    super.init(AndGate.id)                // or super.init(id, isXor: true) for XOR/XNOR
    setRectangularLabel("&")              // plus setNegateOutput / setAdditionalWidth as Java does
  }

  public override func computeOutput(
    _ inputs: [Value], _ numInputs: Int, _ state: any InstanceState
  ) throws -> Value {
    GateFunctions.computeAnd(inputs, numInputs)
  }

  public override var identity: Value { .trueValue }
}
```

**Do not touch** bounds, ports, `contains` or `propagate` in a concrete gate; `AbstractGate`
owns all four and they are driven entirely by `GateAttributes`.

**Ports:** declared by `AbstractGate.ports(_:)`. Port 0 is the output at the component's own
location; inputs 1…n follow, positioned by `inputOffset(_:_:)`.

**Attributes:** `GateAttributes` (a hand-written `AbstractAttributeSet`), because the attribute
*list* grows with the input count. Concrete gates declare no attributes.

**`propagate` reads and writes:** `AbstractGate.propagate` reads
`state.attributeSet as? GateAttributes`, skips unconnected inputs entirely, negates per the
`negated` bit mask, calls `computeOutput`, pulls the result through `pullOutput`, and writes
`state.setPort(0, out, GateAttributes.delay)`.

**Deviations recorded:** two upstream bugs are preserved in `contains` (a WEST branch that uses
`bds.height` where it means `bds.width`; a loop over input offsets `1…inputs` where ports are
numbered `0…inputs-1`) and two more in `GateAttributes.setValue` (a width guard that masks
against the *input count*; `int` shifts into a `long` field, so a 64-input gate cannot negate
inputs 32–63 independently). Do not "fix" any of them.

---

## 2. ttl — exemplar `Ttl/Ttl7400.swift`

**The template for 65 chips.** A TTL chip is four things: an `_ID`, a pin count, the output pin
numbers, and `propagateTtl`. Nothing else.

```swift
public final class Ttl7400: AbstractTtlGate {
  public static let id = "7400"
  private static let pinCount = 14
  private static let outPins = [3, 6, 8, 11]     // PIN numbers (1-based), not port indices

  public convenience init() { self.init(Ttl7400.id) }
  public init(_ name: String) {
    super.init(name, pins: Ttl7400.pinCount, outputPorts: Ttl7400.outPins, drawGates: true)
  }

  public override func propagateTtl(_ state: any InstanceState) throws {
    for i in stride(from: 2, to: 6, by: 3) {
      state.setPort(i, state.portValue(i - 1).and(state.portValue(i - 2)).not(), 1)
    }
    for i in stride(from: 6, to: 12, by: 3) {
      state.setPort(i, state.portValue(i + 1).and(state.portValue(i + 2)).not(), 1)
    }
  }
}
```

Java's eight `AbstractTtlGate` constructor overloads collapse into one initialiser with default
arguments: `pins:`, `outputPorts:`, `notUsedPins:`, `inoutPorts:`, `portNames:`, `drawGates:`,
`height:`. Pass only what the Java constructor passed.

**The port-index contract — get this right or every chip is silently miswired.** The port array
is ordered:

```
[ pins 1 … n/2-1 ] [ pins n/2+1 … n-1 ] [ GND (pin n/2) ] [ Vcc (pin n) ]
   lower row, no GND    upper row, no Vcc     only when VCC_GND is on
```

so for a 14-pin chip: port = pin−1 for pins 1…6, port = pin−2 for pins 8…13, then 12 = GND and
13 = Vcc. Unused pins are squeezed out and shift everything after them down. `propagateTtl`
addresses **port indices**; `outputPorts`/`notUsedPins` are **pin numbers**. Transcribe the
Java loop indices verbatim, never re-derive them.

**Attributes:** fixed template: `StdAttr.facing`, `TtlLibraryAttributes.vccGnd`,
`TtlLibraryAttributes.drawInternalStructure`, `StdAttr.label`. Set by `AbstractTtlGate.init`;
a chip declares none.

**`propagate`:** owned by `AbstractTtlGate`. It checks GND/Vcc when `VCC_GND` is on and drives
every output to `UNKNOWN` if the chip is mis-powered, otherwise calls `propagateTtl`.
**The `&&` must short-circuit**, with `VCC_GND` off the port array is two entries shorter and
the GND index is past its end.

---

## 3. plexers — exemplar `Plexers/Multiplexer.swift`

**Files:** `PlexersLibraryAttributes.swift` (shared attributes, `contains`, `DELAY`) plus one
file per component. No family base class: the five plexers share attributes, not behaviour.

**Attributes**, fixed template, in `init`:

```swift
setAttributes([
  StdAttr.facing.binding(Direction.east),
  PlexersLibraryAttributes.size.binding(PlexersLibraryAttributes.sizeWide),
  StdAttr.selectLocation.binding(StdAttr.selectBottomLeft),
  PlexersLibraryAttributes.select.binding(PlexersLibraryAttributes.defaultSelect),
  StdAttr.width.binding(BitWidth.one),
  PlexersLibraryAttributes.disabled.binding(PlexersLibraryAttributes.disabledZero),
  PlexersLibraryAttributes.enable.binding(PlexersLibraryAttributes.defaultEnable),
])
setFacingAttribute(StdAttr.facing)
```

**Bounds and ports** are both attribute-dependent: override `offsetBounds(_:)` and `ports(_:)`.
Build the port array as `[Port?]` sized exactly as Java sizes it, fill by index in Java's order,
and unwrap at the end with a `preconditionFailure` for a hole (Java gets an NPE there; it is a
transcription defect, not user input).

**Version-dependent defaults** live in `defaultAttributeValue(_:version:)`:

```swift
public override func defaultAttributeValue(
  _ attribute: AnyAttribute, version: LogisimVersion
) -> AttributeValue? {
  if attribute === PlexersLibraryAttributes.enable {
    return .boolean(version.compare(to: LogisimVersion(3, 6, 1)) <= 0)
  }
  return super.defaultAttributeValue(attribute, version: version)
}
```

Dropping this adds or removes an enable port on every pre-3.6.2 file.

**`propagate` reads and writes:**

```swift
let data   = state.attributeValue(StdAttr.width, default: .one)
let select = state.attributeValue(PlexersLibraryAttributes.select, default: …)
let enable = state.attributeValue(PlexersLibraryAttributes.enable, default: false)
let inputs = 1 << select.width
…
state.setPort(inputs + (enable ? 2 : 1), out, PlexersLibraryAttributes.delay)
```

Port indices are computed off `inputs`, so the port *order* built in `ports(_:)` is a hard
contract with `propagate`. Keep both in the same file and check them against each other.

---

## 4. arith — exemplar `Arith/Adder.swift`

The simplest chassis shape: fixed bounds, fixed ports, one attribute. All of the interest is in
a `static` compute function.

```swift
public final class Adder: InstanceFactoryBase {
  public static let id = "Adder"
  static let perDelay = 1
  public static let in0 = 0, in1 = 1, out = 2, cIn = 3, cOut = 4   // keep Java's names

  public init() {
    super.init(Adder.id)
    setAttributes([StdAttr.width.binding(BitWidth.known(8))])
    setOffsetBounds(Bounds.create(-40, -20, 40, 40))
    setPorts([ Port(-40, -10, .input, StdAttr.width), … ])
  }

  public override func propagate(_ state: any InstanceState) throws {
    let dataWidth = state.attributeValue(StdAttr.width, default: .one)
    let outs = try Adder.computeSum(dataWidth, state.portValue(Adder.in0), …)
    let delay = (dataWidth.width + 2) * Adder.perDelay
    state.setPort(Adder.out, outs.sum, delay)
    state.setPort(Adder.cOut, outs.carryOut, delay)
  }
}
```

Java's `Value[]` return becomes a **named tuple**. Keep Java's port-index constants; the arith
family is unreadable with bare integers.

**Three arithmetic rules for this family specifically:**

1. Every `+` on a `long` is `&+`.
2. The width-64 case is always a separate branch, because `sum >> 64` is `>> 0` in Java.
3. `Multiplier` and `Divider` use `UInt64.multipliedFullWidth(by:)` /
   `dividingFullWidth(_:)`, **not** `toBigInteger`; `Int128` is too narrow (D15).
   `Exponentiator` needs real arbitrary precision and is blocked on that dependency.

---

## 5. wiring — exemplar `Wiring/Constant.swift`

The family with the most bespoke attribute sets. The pattern for one:

```swift
public final class ConstantAttributes: AbstractAttributeSet {
  public var facing: Direction = .east          // Java's fields, verbatim, with Java's defaults
  public var width: BitWidth = .one
  public var value: Value = .trueValue

  public override var attributes: [AnyAttribute] { Constant.attributeList }
  public override func rawValue(_ a: AnyAttribute) -> AttributeValue? { … }        // getValue
  public override func setRawValue(_ a: AnyAttribute, _ v: AttributeValue?) throws { … }
  public override func attributesMayAlsoBeChanged<V>(_ a: Attribute<V>, _ v: V?) -> [AnyAttribute]? { … }
  public override func makeCopyInstance() -> AbstractAttributeSet { ConstantAttributes() }
  public override func copyInto(_ d: AbstractAttributeSet) { /* copy EVERY field */ }
}
```

Three rules, each of which has already bitten once:

* **`copyInto` must copy every field**, even where the Java body is empty with the comment
  "nothing to do". Java's `clone()` calls `Object.clone()` *first*, so the fields are already
  there; Swift has no such thing. An empty `copyInto` makes every instance compare "at its
  default" and silently changes what the `.circ` writer emits.
* **`setRawValue` ends with `fireAttributeValueChanged(attr, value:, oldValue:)`**, and the
  `oldValue` is non-nil only where Java passes one (`StdAttr.LABEL`).
* The factory must **override `validateAttributeSet(_:)`** to reject a foreign set. That is
  the port's stand-in for the `ClassCastException` Java raises on its first cast, hoisted to
  construction so it becomes a file error instead of a silently wrong component:

```swift
public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
  guard attributes is ConstantAttributes else {
    throw ComponentError.wrongAttributeSet(factory: Constant.id)
  }
}
```

Wiring components are also the ones where `offsetBounds` is computed from the width
(`chars = (width + 3) / 4`), so override it rather than calling `setOffsetBounds`.

Where Java ends a `Direction` chain with `else throw new IllegalArgumentException(...)`, the
Swift `switch` is exhaustive over the four cases and the throw simply disappears. Note it in a
comment; do not add an unreachable `default`.

---

## 6. Checklist for every ported file

1. GPL-3.0-only header naming the Java class it derives from, and `Reference tree:
   upstream-java-4.1.0 (D16)`.
2. `_ID` transcribed exactly, with the "do NOT change" note. Where Java has no `_ID`, the
   constructor's name string is the `.circ` token (`"AND Gate"`).
3. Every dropped Java member accounted for: `// NOT PORTED:` with a reason, or
   `// PAINT (M6):` with a file:line.
4. Every preserved upstream bug marked `// ── UPSTREAM BUG, PRESERVED ──` with what it does and
   what "fixing" it would change.
5. Every mechanism deviation marked `// **Deviation (mechanism)**` with an argument for why it
   is unobservable.
6. `swift build --target LogisimStd` clean. (The whole-package build may fail on another
   workflow's in-flight target; build this target specifically.)
