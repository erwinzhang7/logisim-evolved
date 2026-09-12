// DualRam.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.DualRam),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Ownership note ───────────────────────────────────────────────────────────────────────────
//
// `DualRam`/`DualRamAppearance`/`DualRamAttributes`/`DualRamState` are a self-contained second
// RAM implementation: upstream's own file header credits a named external contributor and a
// Feb-2026 date, i.e. this is a community-contributed variant living in the `std/memory`
// package, not core Logisim. Named in neither this task's explicit remit ("RamAppearance,
// MemMenu, MemPoker, and remaining memory/*.java") nor the sibling Mem/Ram/Rom slice's ("Mem/
// MemContents/MemContentsSub/MemState/Ram/Rom": six specific files, not "every RAM-shaped
// component"). Ported here under the "remaining memory/*.java, not named by either slice" clause
// of this task's ownership rule, mirroring `Ram.swift` (landed by the sibling slice while this
// file was being written) function-for-function with every port doubled A/B.
//
// ── What's deleted outright, not just deferred (same reasoning as `Ram.swift`) ────────────────
//
// `instanceAttributeChanged` is not overridden. Every upstream branch only calls
// `recomputeBounds()`/`configurePorts(instance)`, which the chassis's `ports(_:)` + diffing
// already does automatically for any attribute whose change affects the port list (`Instance/
// InstanceFactory.swift`'s header). `configureNewInstance`'s body (`instance.addAttributeListener()`)
// is likewise automatic; see `StdInstanceComponent.init`.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `Logger` (`InstanceLogger`); the Log-window value probe; `InstanceLogger` does not exist
//     anywhere in this port yet (`Ram.swift`'s identical note).
//   * `getHDLName`: HDL (stripped per this task's instructions).
//   * `getHexFrame`, `closeHexFrame`, `windowRegistry`: the interactive hex-editor window
//     (`HexFrame`, UI/M6). `DualRam.getContents(InstanceState)` (the one accessor that does not
//     require a window) is kept.
//   * `checkForGatedClocks`, `clockPinIndex`: FPGA/HDL clock-tree analysis (D11).
//   * `reset(CircuitState, Instance)`: `CircuitState`'s "soft reset" hook, iterated by
//     `CircuitState.java:512`'s `instanceof Ram` check (which would need an `instanceof DualRam`
//     twin). `CircuitState`'s per-instance data map is M3 (task list #22), not this slice; the
//     attribute names it would need (`DualRamAttributes.type`/`.volatileOption`) are already
//     ported in `DualRamAttributes.swift` for whenever it lands.
//   * (`paintInstance` is now ported, M6: see the bottom of the class.) Upstream's comment for
//     reference: dispatches to `DualRamAppearance.drawRamClassic`/
//     `drawRamEvolution` depending on `StdAttr.appearance`. See DualRam.java:220-227.
import Foundation
import LogisimFile
import LogisimKernel

/// `com.cburch.logisim.std.memory.DualRam`.
public final class DualRam: Mem {

  /// `DualRam._ID`. Do NOT change; it is the `.circ` `<comp name="DualRAM">` token.
  public static let id = "DualRAM"

  public init() {
    super.init(DualRam.id, displayName: "Dual Port RAM", requiresLabel: true)
  }

  // MARK: InstanceFactory

  /// Width threaded from **this factory's** `offsetBounds`, mirroring upstream's
  /// `instance.getBounds().getWidth()`. Same rectangle either way for `DualRam`, which does not
  /// override; written explicitly for the reason `RamAppearance.ports(_:width:)` gives.
  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    DualRamAppearance.ports(attributes, width: offsetBounds(attributes).width)
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    DualRamAppearance.offsetBounds(attributes)
  }

  public override func createAttributeSet() -> any AttributeSet {
    DualRamAttributes()
  }

  /// The port's stand-in for `(DualRamAttributes) attrs` throwing `ClassCastException`: see
  /// `Ram.swift`'s identical override and `InstanceFactoryBase.validateAttributeSet`'s doc
  /// comment.
  public override func validateAttributeSet(_ attributes: any AttributeSet) throws {
    guard attributes is DualRamAttributes else {
      throw ComponentError.wrongAttributeSet(factory: DualRam.id)
    }
  }

  /// `DualRam.propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let attrs = state.attributeSet
    let myState = dualRamState(for: state)

    // If Clear is active: wipe memory contents and reset data outputs for both ports (A & B).
    if attrs.getValue(DualRamAttributes.clearPin) ?? false {
      let clearValue = state.portValue(DualRamAppearance.clrPortIndex(0, attrs))
      if clearValue == .trueValue {
        myState.getContents().clear()
        let dataBits = state.attributeValue(Mem.data, default: .unknown)
        for i in 0..<DualRamAppearance.dataOutPortCount(attrs) {
          let portValue = DualRam.isSeparate(attrs) ? Value.createKnown(dataBits, 0) : Value.createUnknown(dataBits)
          state.setPort(DualRamAppearance.dataOutPortIndex(i, attrs), portValue, Mem.delay)
        }
        return
      }
    }

    for portIndex in 0..<2 {
      let addrValue = state.portValue(DualRamAppearance.addrPortIndex(portIndex, attrs))
      let addr = addrValue.toLongValue()
      let goodAddr = addrValue.isFullyDefined() && addr >= 0

      if goodAddr && addr != myState.current(portIndex: portIndex) {
        myState.setCurrent(portIndex: portIndex, addr)
        if portIndex == 0 { myState.scrollToShow(portIndex: portIndex, addr) }
      }
      if attrs.getValue(Mem.enables) == Mem.useLineEnables {
        propagateLineEnables(
          state, portIndex: portIndex, addr: addr, goodAddr: goodAddr, errorValue: addrValue.isErrorValue())
      } else {
        propagateByteEnables(
          state, portIndex: portIndex, addr: addr, goodAddr: goodAddr, errorValue: addrValue.isErrorValue())
      }
    }
  }

  /// `DualRam.propagateLineEnables`.
  private func propagateLineEnables(
    _ state: any InstanceState, portIndex: Int, addr: Int64, goodAddr: Bool, errorValue: Bool
  ) {
    let attrs = state.attributeSet
    let myState = dualRamState(for: state)
    let separate = DualRam.isSeparate(attrs)

    let totalLEs = DualRamAppearance.lePortCount(attrs)
    let dataLines = totalLEs == 0 ? 1 : totalLEs / 2

    let misaligned = addr % Int64(dataLines) != 0
    let misalignError = misaligned && !state.attributeValue(Mem.allowMisaligned, default: false)

    let trigger = state.attributeValue(StdAttr.trigger)
    let triggered = myState.setClock(
      portIndex: portIndex, newClock: state.portValue(DualRamAppearance.clkPortIndex(portIndex, attrs)),
      trigger: trigger)
    let writeEnabled =
      triggered && state.portValue(DualRamAppearance.wePortIndex(portIndex, attrs)) == .trueValue

    if writeEnabled && goodAddr && !misalignError {
      for i in 0..<dataLines {
        let absIndex = portIndex * dataLines + i
        if dataLines > 1 {
          let le = state.portValue(DualRamAppearance.lePortIndex(absIndex, attrs))
          if le == .falseValue { continue }
        }
        let dataValue = state.portValue(DualRamAppearance.dataInPortIndex(absIndex, attrs)).toLongValue()
        myState.getContents().set(addr &+ Int64(i), dataValue)
      }
    }

    let width = state.attributeValue(Mem.data, default: .unknown)
    let outputEnabled =
      separate || state.portValue(DualRamAppearance.oePortIndex(portIndex, attrs)) != .falseValue

    if outputEnabled && goodAddr && !misalignError {
      for i in 0..<dataLines {
        let absIndex = portIndex * dataLines + i
        let val = myState.getContents().get(addr &+ Int64(i))
        state.setPort(DualRamAppearance.dataOutPortIndex(absIndex, attrs), Value.createKnown(width, val), Mem.delay)
      }
    } else if outputEnabled && (errorValue || (goodAddr && misalignError)) {
      for i in 0..<dataLines {
        let absIndex = portIndex * dataLines + i
        state.setPort(DualRamAppearance.dataOutPortIndex(absIndex, attrs), Value.createError(width), Mem.delay)
      }
    } else {
      for i in 0..<dataLines {
        let absIndex = portIndex * dataLines + i
        state.setPort(DualRamAppearance.dataOutPortIndex(absIndex, attrs), Value.createUnknown(width), Mem.delay)
      }
    }
  }

  /// `DualRam.propagateByteEnables`.
  private func propagateByteEnables(
    _ state: any InstanceState, portIndex: Int, addr: Int64, goodAddr: Bool, errorValue: Bool
  ) {
    let attrs = state.attributeSet
    let myState = dualRamState(for: state)
    let separate = DualRam.isSeparate(attrs)
    let oldMemValue = myState.getContents().get(myState.current(portIndex: portIndex))
    var newMemValue = oldMemValue

    let trigger = state.attributeValue(StdAttr.trigger)
    let weValue = state.portValue(DualRamAppearance.wePortIndex(portIndex, attrs))
    let async = trigger == StdAttr.triggerHigh || trigger == StdAttr.triggerLow

    var clkValue = Value.falseValue
    if !async {
      let clkIdx = DualRamAppearance.clkPortIndex(portIndex, attrs)
      if clkIdx != -1 { clkValue = state.portValue(clkIdx) }
    }

    let edge = !async && myState.setClock(portIndex: portIndex, newClock: clkValue, trigger: trigger)

    let weAsync =
      (trigger == StdAttr.triggerHigh && weValue == .trueValue)
      || (trigger == StdAttr.triggerLow && weValue == .falseValue)
    let weTriggered = (async && weAsync) || (edge && weValue == .trueValue)

    if goodAddr && weTriggered {
      let dataInValue = state.portValue(DualRamAppearance.dataInPortIndex(portIndex, attrs)).toLongValue()
      let bePorts = DualRamAppearance.bePortCount(attrs)
      if bePorts == 0 {
        newMemValue = dataInValue
      } else {
        let bytesPerWord = bePorts / 2
        for i in 0..<bytesPerWord {
          let mask: Int64 = 0xFF << Int64(i * 8)
          let andMask = ~mask
          let bePinIndex = portIndex * bytesPerWord + i
          if state.portValue(DualRamAppearance.bePortIndex(bePinIndex, attrs)) == .trueValue {
            newMemValue &= andMask
            newMemValue |= (dataInValue & mask)
          }
        }
      }
      myState.getContents().set(addr, newMemValue)
    }

    let dataBits = state.attributeValue(Mem.data, default: .unknown)
    let outputNotEnabled = state.portValue(DualRamAppearance.oePortIndex(portIndex, attrs)) == .falseValue

    func setOutput(_ value: Value) {
      state.setPort(DualRamAppearance.dataOutPortIndex(portIndex, attrs), value, Mem.delay)
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
    // `closeHexFrame((DualRamState) state.getData(c))`: the interactive hex-editor window, UI/M6.
  }

  // MARK: `Mem` overrides

  /// `DualRam.getState(Instance, CircuitState)` / `DualRam.getState(InstanceState)`, collapsed
  /// into one per-`InstanceState` accessor: see `Ram.swift`'s identical `ramState(for:)` and
  /// `Mem.swift`'s header on why the two-argument overload (used only by `getHexFrame`, UI/M6)
  /// is not ported.
  private func dualRamState(for state: any InstanceState) -> DualRamState {
    if let existing = state.data as? DualRamState {
      if let component = state.component as? StdInstanceComponent {
        existing.setRam(component)
      }
      return existing
    }
    let component = state.component as? StdInstanceComponent
    // Safe to force-try: `Mem.addr`/`Mem.data` are bounded 2...24 / 1...64 by their own
    // attribute codecs (`Attributes.forBitWidth`'s `min`/`max`), so `MemContents.create`'s only
    // throwing path (a pathological address width) is unreachable from an attribute set any
    // `.circ` file can actually produce for a `DualRam` component: `Ram.swift`'s identical note.
    let contents = try! DualRam.newContents(attrs: state.attributeSet)
    let listener = component.map { Mem.MemListener($0) }
    let fresh = DualRamState(contents: contents, parent: component, listener: listener)
    state.setData(fresh)
    return fresh
  }

  /// `DualRam.getNewContents(AttributeSet)`.
  private static func newContents(attrs: any AttributeSet) throws -> MemContents {
    let addrWidth = attrs.getValue(Mem.addr)?.width ?? 0
    let dataWidth = attrs.getValue(Mem.data)?.width ?? 0
    let contents = try MemContents.create(addrBits: addrWidth, width: dataWidth, randomize: true)
    contents.condFillRandom()
    return contents
  }

  /// `DualRam.getContents(InstanceState)`.
  public func getContents(_ state: any InstanceState) -> MemContents {
    dualRamState(for: state).getContents()
  }

  // MARK: Static helpers

  /// `DualRam.isSeparate(AttributeSet)`.
  public static func isSeparate(_ attrs: any AttributeSet) -> Bool {
    let bus = attrs.getValue(DualRamAttributes.dataBus)
    return bus == nil || bus == DualRamAttributes.busSeparate
  }

  // MARK: - Painting (M6)

  /// `DualRam.paintInstance(InstancePainter)`. Both appearances live in `DualRamAppearance`.
  public func paintInstance(_ painter: any MemPainter) {
    if DualRamAppearance.classicAppearance(painter.attributeSet) {
      DualRamAppearance.drawRamClassic(painter)
    } else {
      DualRamAppearance.drawRamEvolution(painter)
    }
  }
}
