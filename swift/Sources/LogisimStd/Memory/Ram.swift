// Ram.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.Ram),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Assumed API this file does not own ──────────────────────────────────────────────────────
//
// `RamAppearance` (port topology: already ported, `Memory/RamAppearance.swift`, sibling slice)
// and `RamAttributes`/`RamState` (not yet ported anywhere in this tree as of this writing) are
// used below with the exact shapes upstream gives them, D3-adjusted. If either lands with
// different names, only the call sites here need to change:
//
//   `RamAttributes`: a hand-written `AbstractAttributeSet` (`GateAttributes`'s shape), needs:
//     `.dataBus: Attribute<AttributeOption>`, `.busSeparate: AttributeOption` (ATTR_DBUS/BUS_SEP)
//     `.byteEnables: Attribute<AttributeOption>`, `.busWithByteEnables: AttributeOption`
//         (ATTR_ByteEnables / BUS_WITH_BYTEENABLES)
//     `.clearPin: Attribute<Bool>`                                (CLEAR_PIN)
//     `.type: Attribute<AttributeOption>`, `.volatile: AttributeOption`  (ATTR_TYPE / VOLATILE;
//         only `reset(_:)` below needs these, and that method is not ported: see its comment)
//   `RamState`: `class RamState: MemState`, mirroring `com.cburch.logisim.std.memory.RamState`:
//     `init(component: StdInstanceComponent?, contents: MemContents, listener: Mem.MemListener?)`
//     `func setClock(_ newClock: Value, trigger: AttributeOption?) -> Bool`
//         (`RamState.setClock`: delegates to a `ClockState`, already ported at
//         `Memory/ClockState.swift`)
//     `func setRam(_ component: StdInstanceComponent)`
//     and `cloneData()` per `MemState.swift`'s doc comment on `cloneBaseState(into:)`.
//
// ── What's deleted outright, not just deferred ──────────────────────────────────────────────
//
// `instanceAttributeChanged` is not overridden at all. Every one of its upstream branches only
// calls `recomputeBounds()`/`configurePorts(instance)`; exactly what the chassis's `ports(_:)`
// + diffing already does automatically for *any* attribute whose change affects the port list
// (see `Instance/InstanceFactory.swift`'s header and `PATTERNS.md` §"the one structural change").
// `configureNewInstance`'s body (`instance.addAttributeListener()`, upstream's own
// `super.configureNewInstance` setting the label text field's paint position) is pure paint/
// self-invalidation bookkeeping and is dropped for the same reason.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `Logger` (implements `InstanceLogger`); feeds the waveform/log-table UI. `InstanceLogger`
//     itself does not exist anywhere in this port yet.
//   * `getHDLName`: HDL (stripped per this task's instructions).
//   * `getHexFrame`, `closeHexFrame`, `windowRegistry`: the interactive hex-editor window
//     (`HexFrame`, UI/M6). `Ram.getContents(InstanceState)` (the one accessor that does not
//     require a window) is kept.
//   * `checkForGatedClocks`, `clockPinIndex`: FPGA/HDL clock-tree analysis (D11).
//   * `reset(CircuitState, Instance)`; Circuit's "soft reset" hook. `CircuitState`'s
//     per-instance data map is M3, not this slice; the attribute names it would need
//     (`RamAttributes.type`/`.volatile`) are recorded above for when it lands.
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `paintInstance` is at the bottom of the class; it dispatches to `RamAppearance`'s two
// renderers, which are where all of a RAM's drawing lives (`Ram.java:218-225`).
import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.Ram`.
public final class Ram: Mem {

  /// `Ram._ID`. Do NOT change; it is the `.circ` `<comp name="RAM">` token.
  public static let id = "RAM"

  public init() {
    super.init(Ram.id, requiresLabel: true)
  }

  // MARK: InstanceFactory

  /// `Ram.configurePorts` → `RamAppearance.configurePorts(instance)`.
  ///
  /// The width is threaded from **this factory's** `offsetBounds`, mirroring upstream's
  /// `instance.getBounds().getWidth()`. For `Ram` that is the same rectangle
  /// `RamAppearance.offsetBounds` returns, `Ram.getOffsetBounds` does not override anything
  /// (`Ram.java:175-177`), so this is not a behaviour change here. It is written this way
  /// because `Rom` *does* override, and being the same by construction beats being the same by
  /// coincidence; see `RamAppearance.ports(_:width:)`.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    RamAppearance.ports(attributes, width: offsetBounds(attributes).width)
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    RamAppearance.offsetBounds(attributes)
  }

  public override func createAttributeSet() -> any AttributeSet {
    RamAttributes()
  }

  /// The port's stand-in for `(RamAttributes) attrs` throwing `ClassCastException`: see
  /// `InstanceFactoryBase.validateAttributeSet`'s doc comment and `Wiring/Constant.swift`'s
  /// exemplar of the same pattern.
  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is RamAttributes else {
      throw ComponentError.wrongAttributeSet(factory: Ram.id)
    }
  }

  /// `Ram.propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let attrs = state.attributeSet
    let myState = ramState(for: state)

    // The clear pin, if present, wins outright.
    if attrs.getValue(RamAttributes.clearPin) ?? false {
      let clearValue = state.portValue(RamAppearance.clrPortIndex(0, attrs))
      if clearValue == .trueValue {
        myState.getContents().clear()
        let dataBits = state.attributeValue(Mem.data, default: .unknown)
        for i in 0..<RamAppearance.dataOutPortCount(attrs) {
          let portValue = Ram.isSeparate(attrs) ? Value.createKnown(dataBits, 0) : Value.createUnknown(dataBits)
          state.setPort(RamAppearance.dataOutPortIndex(i, attrs), portValue, Mem.delay)
        }
        return
      }
    }

    let addrValue = state.portValue(RamAppearance.addrPortIndex(0, attrs))
    let addr = addrValue.toLongValue()
    let goodAddr = addrValue.isFullyDefined() && addr >= 0
    if goodAddr && addr != myState.getCurrent() {
      myState.setCurrent(addr)
      myState.scrollToShow(addr)
    }

    if attrs.getValue(Mem.enables) == Mem.useLineEnables {
      propagateLineEnables(state, addr: addr, goodAddr: goodAddr, errorValue: addrValue.isErrorValue())
    } else {
      propagateByteEnables(state, addr: addr, goodAddr: goodAddr, errorValue: addrValue.isErrorValue())
    }
  }

  /// `Ram.propagateLineEnables`.
  private func propagateLineEnables(
    _ state: any InstanceState, addr: Int64, goodAddr: Bool, errorValue: Bool
  ) {
    let attrs = state.attributeSet
    let myState = ramState(for: state)
    let separate = Ram.isSeparate(attrs)

    let dataLines = max(1, RamAppearance.lePortCount(attrs))
    let misaligned = addr % Int64(dataLines) != 0
    let misalignError = misaligned && !state.attributeValue(Mem.allowMisaligned, default: false)

    // Java: `Object trigger = ...`; compared with `==` against `Value.TRUE`/`FALSE` throughout:
    // safe as structural equality here (PATTERNS.md's "Equality" note: interned in Java, and
    // this port's `Value` at width <=1 compares identically either way).
    let trigger = state.attributeValue(StdAttr.trigger)
    let triggered = myState.setClock(state.portValue(RamAppearance.clkPortIndex(0, attrs)), trigger: trigger)
    let writeEnabled = triggered && state.portValue(RamAppearance.wePortIndex(0, attrs)) == .trueValue
    if writeEnabled && goodAddr && !misalignError {
      for i in 0..<dataLines {
        if dataLines > 1 {
          let le = state.portValue(RamAppearance.lePortIndex(i, attrs))
          if le == .falseValue { continue }
        }
        let dataValue = state.portValue(RamAppearance.dataInPortIndex(i, attrs)).toLongValue()
        myState.getContents().set(addr &+ Int64(i), dataValue)
      }
    }

    let width = state.attributeValue(Mem.data, default: .unknown)
    let outputEnabled = separate || state.portValue(RamAppearance.oePortIndex(0, attrs)) != .falseValue
    if outputEnabled && goodAddr && !misalignError {
      for i in 0..<dataLines {
        let val = myState.getContents().get(addr &+ Int64(i))
        state.setPort(RamAppearance.dataOutPortIndex(i, attrs), Value.createKnown(width, val), Mem.delay)
      }
    } else if outputEnabled && (errorValue || (goodAddr && misalignError)) {
      for i in 0..<dataLines {
        state.setPort(RamAppearance.dataOutPortIndex(i, attrs), Value.createError(width), Mem.delay)
      }
    } else {
      for i in 0..<dataLines {
        state.setPort(RamAppearance.dataOutPortIndex(i, attrs), Value.createUnknown(width), Mem.delay)
      }
    }
  }

  /// `Ram.propagateByteEnables`.
  private func propagateByteEnables(
    _ state: any InstanceState, addr: Int64, goodAddr: Bool, errorValue: Bool
  ) {
    let attrs = state.attributeSet
    let myState = ramState(for: state)
    let separate = Ram.isSeparate(attrs)
    let oldMemValue = myState.getContents().get(myState.getCurrent())
    var newMemValue = oldMemValue

    let trigger = state.attributeValue(StdAttr.trigger)
    let weValue = state.portValue(RamAppearance.wePortIndex(0, attrs))
    let async = trigger == StdAttr.triggerHigh || trigger == StdAttr.triggerLow
    let edge = !async && myState.setClock(state.portValue(RamAppearance.clkPortIndex(0, attrs)), trigger: trigger)
    let weAsync =
      (trigger == StdAttr.triggerHigh && weValue == .trueValue)
      || (trigger == StdAttr.triggerLow && weValue == .falseValue)
    let weTriggered = (async && weAsync) || (edge && weValue == .trueValue)

    if goodAddr && weTriggered {
      let dataInValue = state.portValue(RamAppearance.dataInPortIndex(0, attrs)).toLongValue()
      let bePorts = RamAppearance.bePortCount(attrs)
      if bePorts == 0 {
        newMemValue = dataInValue
      } else {
        for i in 0..<bePorts {
          let mask: Int64 = 0xFF << Int64(i * 8)
          let andMask = ~mask
          if state.portValue(RamAppearance.bePortIndex(i, attrs)) == .trueValue {
            newMemValue &= andMask
            newMemValue |= (dataInValue & mask)
          }
        }
      }
      myState.getContents().set(addr, newMemValue)
    }

    let dataBits = state.attributeValue(Mem.data, default: .unknown)
    let outputNotEnabled = state.portValue(RamAppearance.oePortIndex(0, attrs)) == .falseValue

    func setOutput(_ value: Value) {
      state.setPort(RamAppearance.dataOutPortIndex(0, attrs), value, Mem.delay)
    }

    if !separate && outputNotEnabled {
      setOutput(Value.createUnknown(dataBits))
      return
    }
    if outputNotEnabled { return }

    if errorValue {
      setOutput(Value.createError(dataBits))
      return
    }

    if !goodAddr {
      setOutput(Value.createUnknown(dataBits))
      return
    }

    let asyncRead = async || (attrs.getValue(Mem.asyncRead) ?? false)
    if asyncRead {
      setOutput(Value.createKnown(dataBits, newMemValue))
      return
    }

    if edge {
      if attrs.getValue(Mem.readBehavior) == Mem.readAfterWrite {
        setOutput(Value.createKnown(dataBits, newMemValue))
      } else {
        setOutput(Value.createKnown(dataBits, oldMemValue))
      }
    }
  }

  public override func removeComponent(from circuit: Circuit, component: any Component, state: AnyObject?) {
    // `closeHexFrame((RamState) state.getData(c))`: the interactive hex-editor window, UI/M6.
  }

  // MARK: `Mem` overrides

  /// `Ram.getState(Instance, CircuitState)` / `Ram.getState(InstanceState)`, collapsed into one
  /// per-`InstanceState` accessor; see `Mem.swift`'s header on why the two-argument overload
  /// (used only by `getHexFrame`, UI/M6) is not ported.
  private func ramState(for state: any InstanceState) -> RamState {
    if let existing = state.data as? RamState {
      if let component = state.component as? StdInstanceComponent {
        existing.setRam(component)
      }
      return existing
    }
    let component = state.component as? StdInstanceComponent
    // Safe to force-try: `Mem.addr`/`Mem.data` are bounded 2...24 / 1...64 by their own
    // attribute codecs (`Attributes.forBitWidth`'s `min`/`max`), so `MemContents.create`'s only
    // throwing path (a pathological address width; see `MemContents.swift`) is unreachable
    // from an attribute set any `.circ` file can actually produce for a `Ram` component.
    let contents = try! Ram.newContents(attrs: state.attributeSet)
    let listener = component.map { Mem.MemListener($0) }
    let fresh = RamState(component: component, contents: contents, listener: listener)
    state.setData(fresh)
    return fresh
  }

  /// `Ram.getNewContents(AttributeSet)`.
  private static func newContents(attrs: any AttributeSet) throws -> MemContents {
    let addrWidth = attrs.getValue(Mem.addr)?.width ?? 0
    let dataWidth = attrs.getValue(Mem.data)?.width ?? 0
    let contents = try MemContents.create(addrBits: addrWidth, width: dataWidth, randomize: true)
    contents.condFillRandom()
    return contents
  }

  /// `Ram.getContents(InstanceState)`.
  public func getContents(_ state: any InstanceState) -> MemContents {
    ramState(for: state).getContents()
  }

  // MARK: Static helpers

  /// `Ram.isSeparate(AttributeSet)`.
  public static func isSeparate(_ attrs: any AttributeSet) -> Bool {
    let bus = attrs.getValue(RamAttributes.dataBus)
    return bus == nil || bus == RamAttributes.busSeparate
  }

  // MARK: - Painting (M6)

  /// `Ram.paintInstance(InstancePainter)` (`Ram.java:218-225`). Both appearances live in
  /// `RamAppearance`; a RAM's `paintInstance` is nothing but the dispatch.
  public func paintInstance(_ painter: any MemPainter) {
    if RamAppearance.classicAppearance(painter.attributeSet) {
      RamAppearance.drawRamClassic(painter)
    } else {
      RamAppearance.drawRamEvolution(painter)
    }
  }
}
