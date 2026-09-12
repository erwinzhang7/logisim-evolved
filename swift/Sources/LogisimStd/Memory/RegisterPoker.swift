// RegisterPoker.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.RegisterPoker),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// Typing hex digits into a placed register, and nudging it with the arrow keys. Without this a
// `Register` (and, through `CounterPoker`, a `Counter`) can only ever be loaded through its data
// port, so a circuit that expects a hand-seeded initial value cannot be exercised at all.
//
// This file also owns the two small helpers the three memory pokers share; see below.
//
// ── Not ported ──────────────────────────────────────────────────────────────────────────────
//
//   * (nothing further; `paint(InstancePainter)` is now ported at the bottom of the class.)
//
// ── PAINTING (M6) ───────────────────────────────────────────────────────────────────────────
//
// `paint(InstancePainter)` draws the red edit-caret rectangle around the digits being typed. It
// is the only method `CounterPoker` overrides, which is why `CounterPoker` is otherwise an empty
// subclass. Both are ported; see `MemPainter.swift` for the paint seam. `paint` is a plain
// method rather than an `InstancePoker` requirement because `Instance/InstancePoker.swift`
// deliberately omits `getBounds`/`paint` until `InstancePainter` lands; adding the requirement
// there is that slice's call, and this class satisfies it the moment it appears.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// AWT `KeyEvent.VK_*` constants the memory pokers switch on.
///
/// `Io/Keyboard.swift` declares its own `private` enum for the same job. This one is `internal`
/// because three files in this directory need it, and it is deliberately **not** also named
/// `AwtKeyCode`: two same-named top-level types in one module, one `private` and one `internal`,
/// make every unqualified use inside `Keyboard.swift` an ambiguous lookup.
enum MemoryAwtKeyCode {
  static let up: Int = 0x26
  static let down: Int = 0x28
}

/// Java's `Character.digit(e.getKeyChar(), 16)` over `PokeKeyEvent.keyChar`'s UTF-16 code unit.
/// `nil` is Java's `-1` (and its `CHAR_UNDEFINED`, which `keyChar == nil` represents).
///
/// **Documented narrowing.** `AttributeTextFormat.digitValue` is ASCII-only by an explicit
/// kernel decision (its own header explains why); the JDK's `Character.digit` also accepts
/// non-ASCII decimal digits, so a fullwidth `１` typed at a register edits it upstream and is
/// ignored here. Following the kernel's existing choice rather than inventing a second, wider
/// one for three keystroke handlers.
func javaHexDigit(_ keyChar: UInt16?) -> Int? {
  guard let keyChar, let scalar = Unicode.Scalar(keyChar) else { return nil }
  return AttributeTextFormat.digitValue(scalar, radix: 16)
}

/// `com.cburch.logisim.std.memory.RegisterPoker`.
///
/// Not `final`: `CounterPoker` extends it upstream, and the port preserves inheritance chains.
public class RegisterPoker: InstancePoker {

  /// `RegisterPoker.initValue`. Assigned by `beginPoke` and never read again anywhere in 4.1.0;
  /// kept so the two classes line up field for field, not because anything depends on it.
  private var initValue: Int64 = 0

  /// `RegisterPoker.curValue`: the value typed so far, shifted in one hex digit at a time.
  /// Lives on the poker rather than in the component data, so it survives across keystrokes for
  /// as long as this poke session does and resets on the next `beginPoke`.
  private var curValue: Int64 = 0

  public init() {}

  /// `init(InstanceState, MouseEvent)`. Always accepts the poke, a register is editable
  /// anywhere on its body, and creates the data if the component has not propagated yet, which
  /// is what makes a freshly placed register typeable before the simulation has run.
  public func beginPoke(_ state: any InstanceState, _ event: PokeMouseEvent) -> Bool {
    let data: RegisterData
    if let existing = state.data as? RegisterData {
      data = existing
    } else {
      data = RegisterData(width: RegisterPoker.dataWidth(state))
      state.setData(data)
    }
    // A partially-defined register (floating or error bits) starts the edit from zero rather
    // than from a meaningless `toLongValue()`.
    initValue = data.value.isFullyDefined() ? data.value.toLongValue() : 0
    curValue = initValue
    return true
  }

  public func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
    guard let val = javaHexDigit(event.keyChar) else { return }
    let dataWidth = RegisterPoker.dataWidth(state)
    // `&*`/`&+`: Java's `long` arithmetic wraps, and at width 64 the mask is all ones, so the
    // shift-in genuinely overflows once a caller has typed 16 digits. Swift's `*`/`+` would trap.
    curValue = (curValue &* 16 &+ Int64(val)) & dataWidth.mask
    guard let data = state.data as? RegisterData else { return }
    data.value = Value.createKnown(dataWidth, curValue)
    state.fireInvalidated()
  }

  public func keyPressed(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
    let dataWidth = RegisterPoker.dataWidth(state)
    if event.keyCode == MemoryAwtKeyCode.up {
      // Saturating, not wrapping: upstream compares against the mask and simply declines.
      let maxVal = dataWidth.mask
      if curValue != maxVal {
        curValue = curValue &+ 1
        guard let data = state.data as? RegisterData else { return }
        data.value = Value.createKnown(dataWidth, curValue)
        state.fireInvalidated()
      }
    } else if event.keyCode == MemoryAwtKeyCode.down {
      if curValue != 0 {
        curValue = curValue &- 1
        guard let data = state.data as? RegisterData else { return }
        data.value = Value.createKnown(dataWidth, curValue)
        state.fireInvalidated()
      }
    }
  }

  /// `state.getAttributeValue(StdAttr.WIDTH)`, with upstream's own `if (dataWidth == null)
  /// dataWidth = BitWidth.create(8)` fallback hoisted out of the two key handlers.
  ///
  /// `beginPoke` is the one place Java does *not* apply that fallback: it hands a possibly-null
  /// width straight to `new RegisterData(...)`, which would NPE. Sharing the fallback here uses
  /// upstream's own answer for the missing-attribute case instead of inventing a third one.
  private static func dataWidth(_ state: any InstanceState) -> BitWidth {
    state.attributeValue(StdAttr.width, default: BitWidth.known(8))
  }

  // MARK: - Painting (M6)

  /// `RegisterPoker.paint(InstancePainter)` (`RegisterPoker.java:73-85`).
  ///
  /// Note the caret is `8 * len + 2` wide and 16 high, the same box
  /// `Register.drawRegisterEvolution` fills behind the digits, but it is positioned from the
  /// component's own bounds rather than from the symbol geometry, and drawn at `bds.y` with no
  /// vertical offset. That is upstream's geometry, including the fact that it lines up with the
  /// EVOLUTION readout and only approximately with the CLASSIC one.
  open func paint(_ painter: any MemPainter) {
    let bds = painter.bounds
    let width = painter.attributeValue(StdAttr.width)?.width ?? 8
    let len = (width + 3) / 4

    let g = painter.graphics
    g.color = MemPaint.red
    let wid = 8 * len + 2
    g.drawRect(bds.x + (bds.width - wid) / 2, bds.y, wid, 16)
    g.color = MemPaint.black
  }

}
