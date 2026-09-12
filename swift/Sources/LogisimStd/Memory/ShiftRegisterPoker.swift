// ShiftRegisterPoker.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.ShiftRegisterPoker),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Editing one *stage* of a placed shift register: click a stage to select it, type hex digits
// into it, walk between stages with space/tab and backspace, nudge with the arrow keys, or, at
// width 1 only, just click to toggle the bit. Without it the register's contents can only ever
// be shifted in through the data port.
//
// ── The two appearances hit-test completely differently ─────────────────────────────────────
//
// CLASSIC draws the stages as a horizontal row of 10-wide cells starting 15px into the body,
// and only when the parallel-load attribute is on *and* the data width is 4 bits or fewer:
// upstream simply refuses to hit-test a wider or non-parallel classic register, so those are
// not pokable at all. EVOLUTION draws them as a vertical column of 20-tall rows starting 80px
// down, always pokable. `computeStage` is that whole decision, transcribed branch for branch.
//
// ── An upstream out-of-range, and why this port guards instead of reproducing it ─────────────
//
// The EVOLUTION branch bounds `y` from below (`if (y < 0) return -1`) but never from above, so
// `computeStage` can return a stage index at or past the register's length. `loc` also survives
// an attribute edit: select stage 7, shrink ATTR_LENGTH to 2, then press a key, and upstream
// computes `i = data.getLength() - 1 - loc` = -6 and indexes `ShiftRegisterData` with it. In
// Java that is an `ArrayIndexOutOfBoundsException` thrown on the AWT event thread, which prints
// a stack trace and leaves the application running; the poke is simply lost.
//
// A Swift array subscript with the same index is a **trap**, i.e. the process dies with the
// user's unsaved circuit in it. That is the exact substitution D13 forbids, so every one of the
// four sites that computes that index goes through `stageIndex(in:)`, which returns `nil` for an
// out-of-range stage and makes the poke a no-op. Observably this matches Java: nothing happens.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.ShiftRegisterPoker`.
public final class ShiftRegisterPoker: InstancePoker {

  /// `ShiftRegisterPoker.loc`: the selected stage, counted from the *left*/*top* of the drawn
  /// register, or negative for "no stage selected". Note this is the display index; the data
  /// index is its mirror (`length - 1 - loc`), computed by `stageIndex(in:)`.
  private var loc: Int = -1

  public init() {}

  /// `computeStage(InstanceState, MouseEvent)`.
  private func computeStage(_ state: any InstanceState, _ event: PokeMouseEvent) -> Int {
    let widObj = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
    let bds = state.component.bounds

    if state.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      let lenObj = Int(state.attributeValue(ShiftRegister.attrLength, default: 8))
      let loadObj = state.attributeValue(ShiftRegister.attrLoad, default: true)

      // The row of cells sits on the vertical centre of the body, or three quarters down when a
      // label is drawn above it.
      var y = bds.y
      let label = state.attributeValue(StdAttr.label)
      if label == nil || label == "" {
        y += bds.height / 2
      } else {
        y += 3 * bds.height / 4
      }
      y = event.y - y
      if y <= -6 || y >= 8 { return -1 }
      let x = event.x - (bds.x + 15)
      // Upstream tests the attributes *after* the vertical hit and before the horizontal one;
      // the order is behaviour-neutral but kept so the two files read the same.
      if !loadObj || widObj.width > 4 { return -1 }
      if x < 0 || x >= lenObj * 10 { return -1 }
      return x / 10
    } else {
      let len = (widObj.width + 3) / 4
      let boxXpos = ((ShiftRegister.symbolWidth - 30) / 2 + 30) - (len * 4)
      let boxXend = boxXpos + 2 + len * 8
      let y = event.y - bds.y - 80
      // No upper bound on `y`, see this file's header.
      if y < 0 { return -1 }
      let x = event.x - bds.x - 10
      if x < boxXpos || x > boxXend { return -1 }
      return y / 20
    }
  }

  /// `data.getLength() - 1 - loc`, validated. `nil` where upstream throws, see the header.
  private func stageIndex(in data: ShiftRegisterData) -> Int? {
    guard loc >= 0 else { return nil }
    let i = data.length - 1 - loc
    guard i >= 0, i < data.length else { return nil }
    return i
  }

  /// `init(InstanceState, MouseEvent)`. Unlike `RegisterPoker`, this one *rejects* the poke when
  /// the click did not land on a stage, which is how clicking the body of a classic 8-bit
  /// register does nothing at all.
  public func beginPoke(_ state: any InstanceState, _ event: PokeMouseEvent) -> Bool {
    loc = computeStage(state, event)
    return loc >= 0
  }

  public func mousePressed(_ state: any InstanceState, _ event: PokeMouseEvent) {
    loc = computeStage(state, event)
  }

  /// A press and release on the same stage of a **width-1** register toggles that bit; at any
  /// other width a click only selects, and the digits have to be typed.
  public func mouseReleased(_ state: any InstanceState, _ event: PokeMouseEvent) {
    let oldLoc = loc
    if oldLoc < 0 { return }
    let widObj = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
    guard widObj == BitWidth.one else { return }
    let newLoc = computeStage(state, event)
    guard oldLoc == newLoc else { return }
    guard let data = state.data as? ShiftRegisterData, let i = stageIndex(in: data) else { return }
    // Java compares against the interned `Value.FALSE` by reference; structural `==` reproduces
    // that here (PATTERNS.md "Equality"). Anything that is not exactly FALSE, including
    // UNKNOWN and ERROR; therefore becomes FALSE on the first click.
    let v = data.get(i)
    data.set(i, v == .falseValue ? .trueValue : .falseValue)
    state.fireInvalidated()
  }

  public func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
    let loc = self.loc
    if loc < 0 { return }
    guard let c = event.keyChar else { return }
    if c == 0x20 || c == 0x09 {  // space, tab: forward one stage
      let lenObj = Int(state.attributeValue(ShiftRegister.attrLength, default: 8))
      if loc < lenObj - 1 {
        self.loc = loc + 1
        state.fireInvalidated()
      }
    } else if c == 0x08 {  // backspace: back one stage
      if loc > 0 {
        self.loc = loc - 1
        state.fireInvalidated()
      }
    } else {
      // `Integer.parseInt("" + e.getKeyChar(), 16)` inside a `try`/`catch (NumberFormatException)`
      // that swallows the miss: over a single character that is exactly `Character.digit(c, 16)`,
      // so `javaHexDigit`'s `nil` is upstream's caught exception.
      guard let val = javaHexDigit(c) else { return }
      let widObj = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
      guard let data = state.data as? ShiftRegisterData, let i = stageIndex(in: data) else { return }
      // `&*`/`&+`: Java's `long` shift-in wraps, and at width 64 the mask does not clip it.
      var value = data.get(i).toLongValue()
      value = (value &* 16 &+ Int64(val)) & widObj.mask
      data.set(i, Value.createKnown(widObj, value))
      state.fireInvalidated()
    }
  }

  public func keyPressed(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
    let loc = self.loc
    if loc < 0 { return }
    let dataWidth = state.attributeValue(StdAttr.width, default: BitWidth.known(8))
    guard let data = state.data as? ShiftRegisterData, let i = stageIndex(in: data) else { return }
    var curValue = data.get(i).toLongValue()
    if event.keyCode == MemoryAwtKeyCode.up {
      // Saturating at the mask, exactly as `RegisterPoker` does.
      let maxVal = dataWidth.mask
      if curValue != maxVal {
        curValue = curValue &+ 1
        data.set(i, Value.createKnown(dataWidth, curValue))
        state.fireInvalidated()
      }
    } else if event.keyCode == MemoryAwtKeyCode.down {
      if curValue != 0 {
        curValue = curValue &- 1
        data.set(i, Value.createKnown(dataWidth, curValue))
        state.fireInvalidated()
      }
    }
  }

  // MARK: - Painting (M6)

  /// `ShiftRegisterPoker.paint(InstancePainter)` (`ShiftRegisterPoker.java:141-164`); outlines
  /// the selected stage in red.
  ///
  /// The CLASSIC caret sits on the same vertical anchor `computeStage` hit-tests against (the
  /// body's mid-height, or three-quarters down when the register carries a label), which is why
  /// the label lookup is repeated here rather than shared: upstream duplicates it too, and the
  /// two copies must stay in step.
  ///
  /// Upstream reads `painter.getInstance().getBounds()`, not `painter.getBounds()`. For a
  /// component-backed painter those are the same rectangle; `getBounds()` only differs when the
  /// painter is factory-backed (drawing a toolbar ghost), and a poker never paints in that case.
  public func paint(_ painter: any MemPainter) {
    guard loc >= 0 else { return }
    let bds = painter.bounds
    let g = painter.graphics

    if painter.attributeValue(StdAttr.appearance) == StdAttr.appearClassic {
      let x = bds.x + 15 + loc * 10
      var y = bds.y
      let label = painter.attributeValue(StdAttr.label)
      if label == nil || label == "" {
        y += bds.height / 2
      } else {
        y += 3 * bds.height / 4
      }
      g.color = MemPaint.red
      g.drawRect(x, y - 6, 10, 13)
    } else {
      // `widObj.getWidth()`; upstream would NPE on a missing width; 8 is the fallback every
      // other memory painter uses for exactly this attribute.
      let width = painter.attributeValue(StdAttr.width)?.width ?? 8
      let len = (width + 3) / 4
      let boxXpos = ((ShiftRegister.symbolWidth - 30) / 2 + 30) - (len * 4) + bds.x + 10
      let y = bds.y + 82 + loc * 20
      g.color = MemPaint.red
      g.drawRect(boxXpos, y, 2 + len * 8, 16)
    }
  }
}
