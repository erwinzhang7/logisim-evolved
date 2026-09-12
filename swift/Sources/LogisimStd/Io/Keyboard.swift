// Keyboard.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.{Keyboard, KeyboardData}),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `KeyboardData` is folded into this file rather than given its own: it is `package`-private in
// Java with exactly one consumer, and the task's file list names only `Keyboard.java`.
//
// Poker seam: see the ASSUMED CHASSIS ADDITION #1 note in Button.swift: `PokeKeyEvent.keyCode`
// mirrors `KeyEvent.getKeyCode()` (an AWT `VK_*` constant), `.keyChar` mirrors
// `KeyEvent.getKeyChar()` with `nil` standing in for `CHAR_UNDEFINED`.
//
// ── The queue discipline, ported literally ──────────────────────────────────────────────────
//
// `KeyboardData` is a fixed-capacity ring-like buffer that is really a flat array shifted in
// place: `insert` at the cursor shifts everything after it right by one, `delete`/`dequeue`
// shift everything after the removed slot left by one. Capacity changes
// (`updateBufferLength`, driven by `ATTR_BUFFER`) reallocate and truncate the *tail*, clamping
// `bufferLength`/`cursorPos` down if they now exceed the shrunk capacity. All of this is
// transcribed index-for-index rather than reimplemented against a Swift collection, because the
// clamping edge cases (`len >= pos + 1` before the delete-shift, `len >= pos` before the
// insert-shift) are exactly the kind of off-by-one a "cleaner" rewrite would silently change.
//
// Java's buffer is `char[]` (UTF-16 code units); the port keeps `UInt16` for the same reason;
// `Character.isISOControl` and the control-character filter in `keyTyped` are defined in terms
// of 16-bit code units, and a `Character`-based buffer would let a multi-scalar grapheme occupy
// "one slot" where Java's could not.
//
// ── Real concurrency, preserved with `NSLock` ───────────────────────────────────────────────
//
// Java wraps every buffer access from `Poker.keyPressed`/`keyTyped` and `Keyboard.propagate` in
// `synchronized (data) { ... }`, because those run on different threads (AWT's event thread and
// the simulation thread) and genuinely race. D1 keeps Foundation's threading primitives
// available for exactly this kind of Java `synchronized` block outside `LogisimKernel` too, so
// `KeyboardData.synchronized(_:)` wraps an `NSLock` the same way. Note the *granularity*
// matters: Java takes one lock for a whole multi-call block (e.g. `setLastClock` +
// `clear`/`dequeue` + `getChar` together in `propagate`), not one lock per method, so the port
// mirrors that grouping rather than locking inside each individual method.
//
// ── Not ported ────────────────────────────────────────────────────────────────────────────────
//
//   * `setIcon`: UI (D9).
//
// The text windowing and caret rendering, `dispValid`/`dispStart`/`dispEnd`, `fits`,
// `updateDisplay`, `getNextSpecial`, `drawBuffer`, `drawDots`, `drawSpecials`, `Poker.draw` and
// `paintInstance`, ARE ported; see the Paint section at the end of this file. `updateDisplay`
// takes a measuring closure instead of a `FontMetrics`, so `KeyboardData` still knows nothing
// about fonts.

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.io.KeyboardData`.
private final class KeyboardData: InstanceData {
  private let lock = NSLock()
  private var lastClock: Value = .unknownValue
  private var buffer: [UInt16]
  private var str: String?
  private var bufferLength = 0
  private var cursorPos = 0

  // The horizontal scroll window, `dispValid`/`dispStart`/`dispEnd`.
  //
  // Pure display state, it is what lets a 32-character buffer show inside a 145-unit-wide
  // component with an ellipsis at whichever end is clipped, but it lives here, not in the
  // painter, because every buffer mutation has to invalidate it and only this class sees those.
  private var dispValid = false
  private var dispStart = 0
  private var dispEnd = 0

  init(capacity: Int) {
    buffer = [UInt16](repeating: 0, count: max(capacity, 0))
  }

  private init(
    buffer: [UInt16], str: String?, bufferLength: Int, cursorPos: Int, lastClock: Value,
    dispValid: Bool, dispStart: Int, dispEnd: Int
  ) {
    self.buffer = buffer
    self.str = str
    self.bufferLength = bufferLength
    self.cursorPos = cursorPos
    self.lastClock = lastClock
    self.dispValid = dispValid
    self.dispStart = dispStart
    self.dispEnd = dispEnd
  }

  func cloneData() -> any InstanceData {
    KeyboardData(
      buffer: buffer, str: str, bufferLength: bufferLength, cursorPos: cursorPos,
      lastClock: lastClock, dispValid: dispValid, dispStart: dispStart, dispEnd: dispEnd)
  }

  /// The critical section every Java call site wraps in `synchronized (data) { ... }`. Call
  /// sites group multiple operations into one lock acquisition exactly where Java does.
  func synchronized<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  func clear() {
    bufferLength = 0
    cursorPos = 0
    str = ""
    dispValid = false
    dispStart = 0
    dispEnd = 0
  }

  func delete() -> Bool {
    let len = bufferLength
    let pos = cursorPos
    guard pos < len else { return false }
    if len >= pos + 1 { buffer.replaceSubrange(pos..<(len - 1), with: buffer[(pos + 1)..<len]) }
    bufferLength = len - 1
    str = nil
    dispValid = false
    return true
  }

  @discardableResult
  func dequeue() -> UInt16 {
    let len = bufferLength
    guard len != 0 else { return 0 }
    let result = buffer[0]
    if len >= 1 { buffer.replaceSubrange(0..<(len - 1), with: buffer[1..<len]) }
    bufferLength = len - 1
    if cursorPos > 0 { cursorPos -= 1 }
    str = nil
    dispValid = false
    return result
  }

  func getChar(_ pos: Int) -> UInt16 {
    (pos >= 0 && pos < bufferLength) ? buffer[pos] : 0
  }

  func insert(_ value: UInt16) -> Bool {
    let len = bufferLength
    guard len < buffer.count else { return false }
    let pos = cursorPos
    // `System.arraycopy(buf, pos, buf, pos + 1, len - pos)`: shift `buf[pos..<len]` right by
    // one. Written as a half-open range rather than Java's closed-form translation: inserting
    // at the end of the buffer (`pos == len`, the common case) makes this an empty copy, and a
    // closed range `(pos+1)...len` would construct `lowerBound > upperBound` there and trap.
    if len >= pos {
      buffer.replaceSubrange((pos + 1)..<(len + 1), with: buffer[pos..<len])
    }
    buffer[pos] = value
    bufferLength = len + 1
    cursorPos = pos + 1
    str = nil
    dispValid = false
    return true
  }

  func moveCursorBy(_ delta: Int) -> Bool {
    let newPos = cursorPos + delta
    guard newPos >= 0, newPos <= bufferLength else { return false }
    cursorPos = newPos
    dispValid = false
    return true
  }

  @discardableResult
  func setCursor(_ value: Int) -> Bool {
    let clamped = min(value, bufferLength)
    guard cursorPos != clamped else { return false }
    cursorPos = clamped
    dispValid = false
    return true
  }

  func setLastClock(_ newClock: Value) -> Value {
    let previous = lastClock
    lastClock = newClock
    return previous
  }

  func text() -> String {
    if let str { return str }
    var scalars = String.UnicodeScalarView()
    for i in 0..<bufferLength {
      let c = buffer[i]
      scalars.append(isISOControl(c) ? " " : Unicode.Scalar(c) ?? " ")
    }
    let built = String(scalars)
    str = built
    return built
  }

  func updateBufferLength(_ len: Int) {
    synchronized {
      let oldLen = buffer.count
      guard oldLen != len else { return }
      var newBuffer = [UInt16](repeating: 0, count: max(len, 0))
      for i in 0..<min(len, oldLen) { newBuffer[i] = buffer[i] }
      if len < oldLen {
        if bufferLength > len { bufferLength = len }
        if cursorPos > len { cursorPos = len }
      }
      buffer = newBuffer
      str = nil
      dispValid = false
    }
  }

  // MARK: Display windowing — `dispValid`/`dispStart`/`dispEnd`, `fits`, `updateDisplay`

  var cursorPosition: Int { cursorPos }
  var isDisplayValid: Bool { dispValid }
  var displayStart: Int { dispStart }
  var displayEnd: Int { dispEnd }

  /// `KeyboardData.getNextSpecial(int)`: the index of the next control character at or after
  /// `pos`, or `-1`. The painter overlays a glyph (backspace arrow, return hook, form-feed box)
  /// on each of these, since `toString()` has already flattened them to spaces.
  func nextSpecial(from pos: Int) -> Int {
    for i in max(pos, 0)..<bufferLength where isISOControl(buffer[i]) { return i }
    return -1
  }

  /// `KeyboardData.fits(FontMetrics, String, int, int, int, int, int)`.
  ///
  /// `w0`/`w1` are the widths the leading and trailing ellipses consume; they are only charged
  /// when the window actually clips that end.
  private func fits(
    _ measure: (String) -> Int, _ text: [Character], _ w0: Int, _ w1: Int,
    _ i0: Int, _ i1: Int, _ max: Int
  ) -> Bool {
    if i0 >= i1 { return true }
    let len = text.count
    if i0 < 0 || i1 > len { return false }
    var w = measure(String(text[i0..<i1]))
    if i0 > 0 { w += w0 }
    if i1 < len { w += w1 }
    return w <= max
  }

  /// `KeyboardData.updateDisplay(FontMetrics)`.
  ///
  /// Takes a measuring closure rather than a `FontMetrics`: this type has no business knowing
  /// what a font is, and the only thing Java uses the metrics for here is `stringWidth`.
  ///
  /// Transcribed rather than rewritten. The two `if i0 <= 2 { i0 = 0 }` / `if i0 == 1 { i0 = 0 }`
  /// snaps and the asymmetric grow-then-shrink are upstream's heuristic for "close enough to the
  /// start that the leading ellipsis is not worth it", and any tidier formulation moves the
  /// window by a character on some inputs.
  func updateDisplay(measure: (String) -> Int) {
    if dispValid { return }
    let pos = cursorPos
    var i0 = dispStart
    var i1 = dispEnd
    // Indexed by character, matching Java's `char`-indexed `substring`. The buffer holds UTF-16
    // code units and `text()` maps each to exactly one `Character` (controls become a space),
    // so index arithmetic agrees with Java's for every input the buffer can hold.
    let text = Array(self.text())
    let len = text.count
    let max = Keyboard.width - 8 - 4

    if len == 0 || measure(String(text)) <= max {
      i0 = 0
      i1 = len
    } else {
      let w0 = measure(String(text[0]) + "m")
      let w1 = measure("m")
      let w = i0 == 0 ? measure(String(text)) : w0 + measure(String(text[min(i0, len)...]))
      if w <= max { i1 = len }

      // Rearrange start/end so the cursor is inside the window.
      if pos <= i0 {
        if pos < i0 {
          i1 += pos - i0
          i0 = pos
        }
        if pos == i0 && i0 > 0 {
          i0 -= 1
          i1 -= 1
        }
      }
      if pos >= i1 {
        if pos > i1 {
          i0 += pos - i1
          i1 = pos
        }
        if pos == i1 && i1 < len {
          i0 += 1
          i1 += 1
        }
      }
      if i0 <= 2 { i0 = 0 }

      if fits(measure, text, w0, w1, i0, i1, max) {
        while fits(measure, text, w0, w1, i0, i1 + 1, max) { i1 += 1 }
        while fits(measure, text, w0, w1, i0 - 1, i1, max) { i0 -= 1 }
      } else {
        if pos < (i0 + i1) / 2 {
          i1 -= 1
          while !fits(measure, text, w0, w1, i0, i1, max) { i1 -= 1 }
        } else {
          i0 += 1
          while !fits(measure, text, w0, w1, i0, i1, max) { i0 += 1 }
        }
      }
      if i0 == 1 { i0 = 0 }
    }
    dispStart = i0
    dispEnd = i1
    dispValid = true
  }
}

/// `Character.isISOControl(char)`: the Cc/Cf ranges Java tests: `0x00...0x1F` and
/// `0x7F...0x9F`.
private func isISOControl(_ c: UInt16) -> Bool {
  c <= 0x1F || (c >= 0x7F && c <= 0x9F)
}

/// AWT `KeyEvent.VK_*` constants `keyPressed` switches on.
private enum AwtKeyCode {
  // `Int`, not `Int32`, to match `PokeKeyEvent.keyCode`. Java's `KeyEvent.getKeyCode()` returns
  // a plain `int`, and this port's convention is that a Java `int` becomes a Swift `Int` (with
  // `wrap32` applied wherever overflow is reachable; key codes are small constants, so it is
  // not). The `Int32` on `bufferLength` below is a different thing: that is an
  // `Attribute<Int32>` built by `Attributes.forIntegerRange`, where the width is part of the
  // attribute's own type.
  static let end: Int = 0x23
  static let home: Int = 0x24
  static let left: Int = 0x25
  static let right: Int = 0x27
  static let delete: Int = 0x7F
}

/// `com.cburch.logisim.std.io.Keyboard`.
public final class Keyboard: InstanceFactoryBase {
  /// `Keyboard._ID`.
  public static let id = "Keyboard"

  // `Keyboard`'s port constants, transcribed verbatim.
  private static let portClr = 0
  private static let portClk = 1
  private static let portEnable = 2
  private static let portAvailable = 3
  private static let portOut = 4

  private static let delay0 = 9
  private static let delay1 = 11

  public static let width = 145
  public static let height = 25

  /// `Keyboard.FORM_FEED`; control-L. (Upstream's own comment calling it "LINE FEED" is wrong;
  /// preserved as data only, it does not affect behaviour.)
  private static let formFeed: UInt16 = 12

  /// `Keyboard.ATTR_BUFFER`.
  public static let bufferLength: Attribute<Int32> = Attributes.forIntegerRange(
    "buflen", start: 1, end: 256)

  /// `Keyboard.getBufferLength(Object)`. Java defends a raw `Object` attribute value that is not
  /// an `Integer`; the typed Swift attribute makes that case unrepresentable, so this is just
  /// the default-fallback half.
  private static func bufferCapacity(for state: any InstanceState) -> Int {
    Int(state.attributeValue(Keyboard.bufferLength, default: 32))
  }

  /// `Keyboard.getKeyboardState(InstanceState)`.
  private static func keyboardState(for state: any InstanceState) -> KeyboardData {
    let capacity = bufferCapacity(for: state)
    if let existing = state.data as? KeyboardData {
      existing.updateBufferLength(capacity)
      return existing
    }
    let created = KeyboardData(capacity: capacity)
    state.setData(created)
    return created
  }

  /// `Keyboard.addToBuffer(InstanceState, char[])`: a public hook for injecting characters from
  /// outside the poke tool (e.g. a scripted test harness).
  ///
  /// **Deviation, strictly more careful than Java.** Upstream's version does not wrap this loop
  /// in `synchronized (keyboardData)`, unlike every other buffer-mutating call site in this
  /// file: an apparent oversight, since it races the simulation thread's `propagate` exactly
  /// like the poker methods do. Adding the lock here cannot change the resulting buffer contents
  /// (this method's return value is `Void` and nothing here reads shared state back), so it only
  /// removes a race Java has, without altering any observable single-threaded behaviour.
  public static func addToBuffer(_ state: any InstanceState, _ newChars: [UInt16]) {
    let data = keyboardState(for: state)
    data.synchronized {
      for c in newChars { _ = data.insert(c) }
    }
  }

  /// `Keyboard.Poker`. `draw` (the caret) is M6 and not ported.
  public final class Poker: InstancePoker {
    public init() {}

    public func keyPressed(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
      let data = Keyboard.keyboardState(for: state)
      var changed = false
      var used = true
      data.synchronized {
        switch event.keyCode {
        case AwtKeyCode.delete: changed = data.delete()
        case AwtKeyCode.left: _ = data.moveCursorBy(-1)
        case AwtKeyCode.right: _ = data.moveCursorBy(1)
        case AwtKeyCode.home: _ = data.setCursor(0)
        case AwtKeyCode.end: _ = data.setCursor(Int.max)
        default: used = false
        }
      }
      if used { event.consumed = true }
      if changed { state.fireInvalidated() }
    }

    public func keyTyped(_ state: any InstanceState, _ event: inout PokeKeyEvent) {
      let data = Keyboard.keyboardState(for: state)
      var changed = false
      if let ch = event.keyChar {
        if !isISOControl(ch) || ch == 8 || ch == 10 || ch == Keyboard.formFeed {
          data.synchronized { changed = data.insert(ch) }
        }
        event.consumed = true
      }
      if changed { state.fireInvalidated() }
    }
  }

  public init() {
    super.init(Keyboard.id)
    setAttributes([
      Keyboard.bufferLength.binding(32),
      StdAttr.edgeTrigger.binding(StdAttr.triggerRising),
    ])
    setOffsetBounds(Bounds.create(0, -15, Keyboard.width, Keyboard.height))
    setPorts([
      Port(20, 10, .input, 1),
      Port(0, 0, .input, 1),
      Port(10, 10, .input, 1),
      Port(130, 10, .output, 1),
      Port(140, 10, .output, 7),
    ])
  }

  public override func makePoker() -> (any InstancePoker)? { Poker() }

  /// `propagate(InstanceState)`.
  public override func propagate(_ state: any InstanceState) throws {
    let trigger = state.attributeValue(StdAttr.edgeTrigger, default: StdAttr.triggerRising)
    let data = Keyboard.keyboardState(for: state)
    let clear = state.portValue(Keyboard.portClr)
    let clock = state.portValue(Keyboard.portClk)
    let enable = state.portValue(Keyboard.portEnable)

    var c: UInt16 = 0
    data.synchronized {
      let lastClock = data.setLastClock(clock)
      if clear == .trueValue {
        data.clear()
      } else if enable != .falseValue {
        let go: Bool = (trigger == StdAttr.triggerFalling)
          ? (lastClock == .trueValue && clock == .falseValue)
          : (lastClock == .falseValue && clock == .trueValue)
        if go { data.dequeue() }
      }
      c = data.getChar(0)
    }

    let out = Value.createKnown(BitWidth.known(7), Int64(c & 0x7F))
    state.setPort(Keyboard.portOut, out, Keyboard.delay0)
    state.setPort(Keyboard.portAvailable, c != 0 ? .trueValue : .falseValue, Keyboard.delay1)
  }

  // MARK: - Paint (D6)

  /// `Keyboard.DEFAULT_FONT`: `new Font("monospaced", Font.PLAIN, 12)`.
  public static let defaultFont = SceneFont(family: .monospaced, size: 12)

  /// The paint-path twin of `keyboardState(for:)`; see `Video`'s equivalent.
  private static func keyboardState(painting painter: any IoInstancePainter) -> KeyboardData {
    let capacity = Int(painter.attributeValue(Keyboard.bufferLength, default: 32))
    if let existing = painter.data as? KeyboardData {
      existing.updateBufferLength(capacity)
      return existing
    }
    let created = KeyboardData(capacity: capacity)
    painter.setData(created)
    return created
  }

  /// `drawDots(Graphics, int, int, int, int)`; `Keyboard.java:225-232`.
  ///
  /// The three-dot ellipsis marking a clipped end. Each guard is a different inequality
  /// (`2r + d`, `3r + 2d`, `5r + 3d`): note the jump from 3 to 5, which is upstream's, so the
  /// third dot needs disproportionately more room than the second. Transcribed, not derived.
  private static func drawDots(_ g: SceneBuilder, _ x: Int, _ y: Int, _ width: Int, _ ascent: Int) {
    var r = width / 10
    if r < 1 { r = 1 }
    let d = 2 * r
    if 2 * r + 1 * d <= width { g.fillOval(x + r, y - d, d, d) }
    if 3 * r + 2 * d <= width { g.fillOval(x + 2 * r + d, y - d, d, d) }
    if 5 * r + 3 * d <= width { g.fillOval(x + 3 * r + 2 * d, y - d, d, d) }
  }

  /// `drawSpecials(...)`: `Keyboard.java:234-285`.
  ///
  /// `toString()` renders every control character as a space, so the glyph that says *which*
  /// control it was is overlaid here: a left arrow for backspace, a return hook for newline, an
  /// empty box for form feed. Anything else in the specials list draws nothing at all, which is
  /// why a stray `\t` shows as a plain gap.
  ///
  /// The packing `c << 16 | i` is upstream's, and so is the asymmetric unpacking; the index is
  /// masked to **8** bits (`code & 0xFF`) while the character is shifted by 16. With the buffer
  /// capped well under 256 the masked bits are always zero, so it is harmless; it is preserved
  /// rather than widened because widening it would change nothing except this comment.
  private static func drawSpecials(
    _ specials: [Int], _ x0: Int, _ xs: Int, _ ys: Int, _ asc: Int,
    _ g: SceneBuilder, _ text: [Character], _ dispStart: Int, _ dispEnd: Int
  ) {
    for code in specials {
      let pos = code & 0xFF
      var w0: Int
      var w1: Int
      if pos == 0 {
        w0 = x0
        w1 = x0 + g.measuredWidth(of: String(text[0..<min(1, text.count)]))
      } else if pos >= dispStart && pos < dispEnd {
        w0 = xs + g.measuredWidth(of: String(text[dispStart..<pos]))
        w1 = xs + g.measuredWidth(of: String(text[dispStart..<(pos + 1)]))
      } else {
        continue  // not in the current view
      }
      w0 += 1
      w1 -= 1

      let key = code >> 16
      if key == 0x08 {  // backspace
        let y1 = ys - asc / 2
        g.drawLine(w0, y1, w1, y1)
        g.drawPolyline(
          [w0 + 3, w0, w0 + 3],
          [y1 - 3, y1, y1 + 3])
      } else if key == 0x0A {  // newline
        let y1 = ys - 3
        g.drawPolyline(
          [w1, w1, w0],
          [ys - asc, y1, y1])
        g.drawPolyline(
          [w0 + 3, w0, w0 + 3],
          [y1 - 3, y1, y1 + 3])
      } else if key == Int(Keyboard.formFeed) {
        g.drawRect(w0, ys - asc, w1 - w0, asc)
      }
    }
  }

  /// `drawBuffer(...)`: `Keyboard.java:183-223`.
  ///
  /// Three cases, in Java's order: clipped at the left (draw character 0, an ellipsis, then the
  /// window), clipped only at the right, or the whole string. The first case's `xs` is
  /// `x0 + stringWidth(str[0] + "m")`: the *pair*, measured together, not the two widths
  /// summed, which is the same number for a monospaced font and would not be for any other.
  private static func drawBuffer(
    _ g: SceneBuilder, _ text: [Character], _ dispStart: Int, _ dispEnd: Int,
    _ specials: [Int], _ bds: Bounds
  ) {
    let x = bds.x
    let y = bds.y

    g.font = Keyboard.defaultFont
    let asc = g.fontMetrics().ascent
    let x0 = x + 8
    let ys = y + (Keyboard.height + asc) / 2
    let dotsWidth = g.measuredWidth(of: "m")
    let len = text.count
    let xs: Int
    if dispStart > 0 {
      g.drawString(String(text[0..<1]), x: x0, y: ys)
      xs = x0 + g.measuredWidth(of: String(text[0]) + "m")
      drawDots(g, xs - dotsWidth, ys, dotsWidth, asc)
      let sub = String(text[dispStart..<dispEnd])
      g.drawString(sub, x: xs, y: ys)
      if dispEnd < len {
        drawDots(g, xs + g.measuredWidth(of: sub), ys, dotsWidth, asc)
      }
    } else if dispEnd < len {
      let sub = String(text[dispStart..<dispEnd])
      xs = x0
      g.drawString(sub, x: xs, y: ys)
      drawDots(g, xs + g.measuredWidth(of: sub), ys, dotsWidth, asc)
    } else {
      xs = x0
      g.drawString(String(text), x: xs, y: ys)
    }

    if !specials.isEmpty {
      drawSpecials(specials, x0, xs, ys, asc, g, text, dispStart, dispEnd)
    }
  }

  /// `paintInstance(InstancePainter)`, `Keyboard.java:287-333`.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let g = painter.scene
    g.color = painter.componentColor
    painter.drawClock(Keyboard.portClk, .east)
    painter.drawBounds()
    painter.drawPort(Keyboard.portClr)
    painter.drawPort(Keyboard.portEnable)
    painter.drawPort(Keyboard.portAvailable)
    painter.drawPort(Keyboard.portOut)

    if painter.showState {
      let state = Keyboard.keyboardState(painting: painter)
      let text = Array(state.text())
      var specials: [Int] = []
      var i = state.nextSpecial(from: 0)
      while i >= 0 {
        specials.append(Int(state.getChar(i)) << 16 | i)
        i = state.nextSpecial(from: i + 1)
      }
      if !state.isDisplayValid {
        // The window is recomputed with the *keyboard's* font, which is not the font installed
        // on the builder at this point; Java is explicit about this (`g.getFontMetrics(
        // DEFAULT_FONT)`, the overload that takes a font). Measuring with the ambient font
        // instead would size the window against the wrong advance and clip a character early.
        let saved = g.font
        g.font = Keyboard.defaultFont
        state.updateDisplay { g.measuredWidth(of: $0) }
        g.font = saved
      }
      if !text.isEmpty {
        Keyboard.drawBuffer(
          g, text, state.displayStart, state.displayEnd, specials, painter.bounds)
      }
    } else {
      let bds = painter.bounds
      let len = Int(painter.attributeValue(Keyboard.bufferLength, default: 32))
      let str = "keyboard (buffer cap. \(len))"
      let fm = g.fontMetrics()
      // Note the horizontal centring uses the *constant* `WIDTH`, not `bds.getWidth()`, while
      // the vertical uses the constant `HEIGHT`. They happen to be equal here, since the offset
      // bounds are exactly `WIDTH × HEIGHT`, but the asymmetry is upstream's.
      let x = bds.x + (Keyboard.width - g.measuredWidth(of: str)) / 2
      let y = bds.y + (Keyboard.height + fm.ascent) / 2
      g.drawString(str, x: x, y: y)
    }
  }
}

extension Keyboard: IoPaintable {}

extension Keyboard.Poker {

  /// `Keyboard.Poker.draw(InstancePainter)`: `Keyboard.java:45-73`.
  ///
  /// The text caret, drawn only for the keyboard currently being typed into. Same seam caveat as
  /// `Joystick.Poker.paint`: `InstancePoker` as this port assumes it has no draw hook.
  ///
  /// The `dispStart > 0` branch measures `str[0] + "m"` and *then* the window prefix, so the
  /// caret sits after the leading character and its ellipsis; the same pair-measurement
  /// `drawBuffer` uses to place `xs`, and it has to stay identical or the caret drifts off the
  /// text by a pixel per character.
  public func draw(_ painter: any IoInstancePainter) {
    let data = Keyboard.keyboardState(painting: painter)
    let bds = painter.bounds
    let g = painter.scene

    let saved = g.font
    g.font = Keyboard.defaultFont

    let text = Array(data.text())
    let cursor = data.cursorPosition
    if !data.isDisplayValid {
      data.updateDisplay { g.measuredWidth(of: $0) }
    }
    let dispStart = data.displayStart

    let asc = g.fontMetrics().ascent
    var x = bds.x + 8
    if dispStart > 0 {
      x += g.measuredWidth(of: String(text[0]) + "m")
      x += g.measuredWidth(of: String(text[dispStart..<min(cursor, text.count)]))
    } else if cursor >= text.count {
      x += g.measuredWidth(of: String(text))
    } else {
      x += g.measuredWidth(of: String(text[0..<cursor]))
    }
    let y = bds.y + (bds.height + asc) / 2
    g.drawLine(x, y - asc, x, y)

    g.font = saved
  }
}
