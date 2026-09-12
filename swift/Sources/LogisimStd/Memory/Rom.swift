// Rom.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.Rom),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The one thing in this file that is load-bearing for M2's pass condition ─────────────────
//
// `contentsAttr`'s codec is upstream's `Rom.ContentsAttribute`. Its `toStandardString`/`parse`
// are the entire reason `MemContents.saveRawToString`/`parseRaw` exist: they are what actually
// gets written into and read back from a `.circ` file's `<a name="contents" val="…">`. The
// header line (`"addr/data: <addrBits> <dataWidth>\n"`) is this file's responsibility, not
// `MemContents`'s: upstream splits it the same way (`Rom.java`'s `ContentsAttribute` builds the
// header; `HexFile.saveToString`/`parseFromCircFile` only ever see the body after it).
//
// ── Assumed API this file does not own ──────────────────────────────────────────────────────
//
// `RamAppearance` (already ported, `Memory/RamAppearance.swift`) and `RomAttributes` (not yet
// ported anywhere in this tree). `RomAttributes` needs to be a hand-written `AbstractAttributeSet`
// (the `GateAttributes`/`RamAttributes` shape) whose fields include at least `Mem.addr`,
// `Mem.data`, `Mem.line`, `StdAttr.appearance`, `StdAttr.label`, `StdAttr.labelFont`, and
// `Rom.contentsAttr` itself, with a default `MemContents` value the constructor creates via
// `try! MemContents.create(addrBits:width:randomize:)` at whatever the attribute set's own
// default address/data width is (upstream defaults to a small ROM; see `RomAttributes.java`
// when it is ported). `Rom.memState(for:)` below force-unwraps `Rom.contentsAttr`'s value on the
// assumption `RomAttributes` always answers it; an internal invariant no `.circ` file can
// violate (D13), not a gap in this file.
//
// ── What's deleted outright, not just deferred ──────────────────────────────────────────────
//
// `instanceAttributeChanged` is not overridden. Its only branches call
// `recomputeBounds()`/`configurePorts(instance)`, which the chassis's `ports(_:)` + diffing
// already does for any attribute that changes the port list (see `Ram.swift`'s header, which
// makes the identical cut, and `PATTERNS.md`).
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `ContentsCell`, `getCellEditor` on `ContentsAttribute`: the attribute-table cell that
//     opens the hex editor on click. UI (M6); `Rom.contentsAttr`'s codec (parse/toStandardString)
//     is the part with model-level meaning and is fully ported.
//   * `getHexFrame`, `closeHexFrame`: the interactive hex-editor window (`HexFrame`, UI/M6).
//   * `configureNewInstance`'s `MemListener` registration (`memListeners.put(...)`,
//     `contents.addHexModelListener(listener)`, `instance.addAttributeListener()`); exists
//     upstream purely to repaint the component when its contents change via the hex editor.
//     **Needed change outside this slice's ownership**: there is currently no
//     "component just got placed" hook on `StdInstanceComponent`/`InstanceFactory` to run this
//     at the right time (Java's `configureNewInstance` has no chassis equivalent: see
//     `Instance/InstanceFactory.swift`'s header, which folds `configureNewInstance` into
//     `ports(_:)` for the ports-only case but has nothing for one-time side effects). Until one
//     exists, this port can wire the listener lazily on first `getState`/`propagate` instead
//     (mirroring what `Ram.swift` already does via `RamState`'s constructor), which changes
//     upstream's continuous "always listening from placement" a Ram/Rom is watched, once
//     simulated, is likely small enough) at the change is recorded here rather than silently
//     dropped.
//   * `getInstanceFeature(MenuExtender.class)`: reads `Mem.getInstanceFeature`, not overridden
//     separately here; see `Mem.swift`.
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `paintInstance` is at the bottom of the class; it dispatches to `RamAppearance`'s two
// renderers, the same pair `Ram` uses (`Rom.java:206-212`). Note the dispatch condition differs
// in spelling only: `Rom` tests `StdAttr.APPEARANCE == APPEAR_CLASSIC` directly where `Ram`
// calls `RamAppearance.classicAppearance(attrs)`, which is that same test.
import Foundation
import LogisimFile
import LogisimKernel

/// Thrown by `Rom.contentsAttr`'s codec when the `contents` attribute's header does not match
/// `"addr/data: <addrBits> <dataWidth>"`. Upstream's `ContentsAttribute.parse` returns `null` on
/// exactly this condition (a caught `NoSuchElementException`/`NumberFormatException`); this port
/// throws instead, per D13; a malformed `.circ` attribute value is exactly the kind of bad
/// input that must produce a load error, not propagate a `nil` `MemContents` for every later
/// reader of the attribute to NPE on.
public enum RomContentsError: Error, CustomStringConvertible, Sendable {
  case malformedHeader(String)

  public var description: String {
    switch self {
    case .malformedHeader(let header):
      return "malformed ROM contents header: \(header)"
    }
  }
}

/// `com.cburch.logisim.std.memory.Rom`.
public final class Rom: Mem {

  /// `Rom._ID`. Do NOT change; it is the `.circ` `<comp name="ROM">` token.
  public static let id = "ROM"

  /// `Rom.CONTENTS_ATTR` (`ContentsAttribute`, an inline `Attribute<MemContents>` subclass in
  /// Java). Storage form is `.object(AttributeObjectBox(_:))`, `MemContents` is a live,
  /// identity-significant object with no closed `AttributeValue` case of its own (see
  /// `AttributeObjectBox`'s doc comment in `Attributes.swift`; `Attributes.forMap()` is the
  /// other user of the same case, for the same "live object, not a value" reason), but unlike
  /// `forMap` this attribute *is* saved, the codec's `parse`/`toStandardString` are what give
  /// it real `.circ` text, `.object` is only the in-memory carrier.
  public static let contentsAttr: Attribute<MemContents> = Attribute(
    name: "contents",
    codec: AttributeCodec(
      parse: { value in
        let lineBreak = value.firstIndex(of: "\n")
        let first = lineBreak.map { String(value[value.startIndex..<$0]) } ?? value
        let rest = lineBreak.map { String(value[value.index(after: $0)...]) } ?? ""
        let tokens = first.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 3, tokens[0] == "addr/data:" else {
          throw RomContentsError.malformedHeader(first)
        }
        guard let addrBits = javaParseInt32(tokens[1]), let width = javaParseInt32(tokens[2]) else {
          throw RomContentsError.malformedHeader(first)
        }
        return try MemContents.parseRaw(rest, addrBits: addrBits, width: width)
      },
      toStandardString: { contents in
        let addr = contents.logLength
        let data = contents.valueWidth
        let body = MemContents.saveRawToString(contents)
        return "addr/data: \(addr) \(data)\n\(body)"
      },
      encode: { .object(AttributeObjectBox($0)) },
      decode: { stored in
        guard case .object(let box) = stored, let contents = box.object as? MemContents else {
          return nil
        }
        return contents
      }))

  public init() {
    super.init(Rom.id, requiresLabel: true)
  }

  // MARK: InstanceFactory

  /// `Rom.configurePorts` → `RamAppearance.configurePorts(instance)` (`Rom.java:141-143`).
  ///
  /// **The width has to come from `Rom`'s own `offsetBounds`, not `RamAppearance`'s.** Upstream
  /// gets this for free because `configurePorts` reads `instance.getBounds().getWidth()`, and an
  /// instance's bounds come from *its factory's* `getOffsetBounds`; the override just below.
  /// `RamAppearance.offsetBounds` returns `symbolWidth + 50` for a ROM (no `dataBus` attribute,
  /// so `separatedBus` is false), while this factory reports `symbolWidth + 40`. Ten units of
  /// difference is the whole defect: the data output lands off the wire, the ROM drives nothing,
  /// and everything downstream reads `U`. See `RamAppearance.ports(_:width:)`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    RamAppearance.ports(attributes, width: offsetBounds(attributes).width)
  }

  /// `Rom.getOffsetBounds`.
  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let len = attributes.getValue(Mem.data)?.width ?? 0
    if attributes.getValue(StdAttr.appearance) == StdAttr.appearClassic {
      return Bounds.create(0, 0, Mem.symbolWidth + 40, 140)
    } else {
      return Bounds.create(0, 0, Mem.symbolWidth + 40, RamAppearance.controlHeight(attributes) + 20 * len)
    }
  }

  public override func createAttributeSet() -> any AttributeSet {
    RomAttributes()
  }

  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is RomAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Rom.id)
    }
  }

  /// `Rom.propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let myState = memState(for: state)
    let dataBits = state.attributeValue(Mem.data, default: .unknown)
    let attrs = state.attributeSet

    let addrValue = state.portValue(RamAppearance.addrPortIndex(0, attrs))
    let nrDataLines = RamAppearance.dataOutPortCount(attrs)
    let addr = addrValue.toLongValue()

    if addrValue.isErrorValue() || (addrValue.isFullyDefined() && addr < 0) {
      for i in 0..<nrDataLines {
        state.setPort(RamAppearance.dataOutPortIndex(i, attrs), Value.createError(dataBits), Mem.delay)
      }
      return
    }
    if !addrValue.isFullyDefined() {
      for i in 0..<nrDataLines {
        state.setPort(RamAppearance.dataOutPortIndex(i, attrs), Value.createUnknown(dataBits), Mem.delay)
      }
      return
    }
    if addr != myState.getCurrent() {
      myState.setCurrent(addr)
      myState.scrollToShow(addr)
    }

    let misaligned = addr % Int64(nrDataLines) != 0
    let misalignError = misaligned && !state.attributeValue(Mem.allowMisaligned, default: false)

    for i in 0..<nrDataLines {
      let val = myState.getContents().get(addr &+ Int64(i))
      state.setPort(
        RamAppearance.dataOutPortIndex(i, attrs),
        misalignError ? Value.createError(dataBits) : Value.createKnown(dataBits, val),
        Mem.delay)
    }
  }

  public override func removeComponent(from circuit: Circuit, component: any Component, state: AnyObject?) {
    // `closeHexFrame(Component)`: the interactive hex-editor window, UI/M6.
  }

  // MARK: `Mem` overrides / helpers

  /// `Rom.getState(Instance, CircuitState)` / `Rom.getState(InstanceState)`, collapsed to the
  /// per-`InstanceState` accessor: see `Mem.swift`'s header on the two-argument overload.
  private func memState(for state: any InstanceState) -> MemState {
    if let existing = state.data as? MemState { return existing }
    guard let contents = state.attributeSet.getValue(Rom.contentsAttr) else {
      // Internal invariant: `RomAttributes` always answers `Rom.contentsAttr` with a real
      // `MemContents` (its own construction guarantees this). No `.circ` file can produce a
      // `RomAttributes` that fails to: D13's "genuine programmer error" carve-out.
      preconditionFailure("Rom: RomAttributes did not supply a value for Rom.contentsAttr")
    }
    let fresh = MemState(contents)
    state.setData(fresh)
    return fresh
  }

  /// `Rom.getMemContents(Instance)`.
  public static func memContents(_ component: any Component) -> MemContents? {
    component.attributeSet.getValue(Rom.contentsAttr)
  }

  // MARK: - Painting (M6)

  /// `Rom.paintInstance(InstancePainter)` (`Rom.java:206-212`).
  public func paintInstance(_ painter: any MemPainter) {
    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      RamAppearance.drawRamClassic(painter)
    } else {
      RamAppearance.drawRamEvolution(painter)
    }
  }
}
