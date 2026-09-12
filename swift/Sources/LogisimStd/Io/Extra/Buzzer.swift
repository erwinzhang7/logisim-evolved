// Buzzer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.extra.Buzzer),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── Audio is produced through a seam, not by this module (D9) ────────────────────────────────
//
// This component genuinely produces sound as a side effect of `propagate`, exactly as upstream
// does through `javax.sound.sampled`. An earlier revision of this file imported `AVFoundation`
// and drove an `AVAudioEngine` directly, on the reasoning that D9 names AppKit/SwiftUI/UIKit/
// CoreGraphics and audio is not a UI framework. That reasoning is wrong in consequence, and for
// the same reason D9 exists at all: `logisim-cli` converts a `.circ` headless, and linking a
// platform media framework into `LogisimStd` to do it makes the differential harness carry an
// audio stack it can never use. It is gone.
//
// It was *not* the only one, though this header once claimed so: `TelnetServer` imported
// `Network` for an `NWListener`, found later and fixed the same way (`TelnetServer
// .transportFactory`). Two independent slices reached for a platform framework because their
// component genuinely needs a platform capability, which is an argument for a seam and never
// for an import. `PlatformFreedomTests` now enforces that from CI so the next one is caught by
// a machine rather than by a reader.
//
// What stays here is the whole *model*, which is what a fidelity port owes: `BuzzerWaveform`'s
// amplitude strategies, the box-car smoothing pass, the cycle-repeat fill, and the 16-bit signed
// little-endian stereo interleave: right down to `(short) Math.round(rvalues[j] * vol)`'s
// truncation and to leaving an unselected channel's two bytes zero. The result is a `BuzzerTone`
// holding exactly the `byte[]` upstream hands `AudioInputStream`, plus the sample rate upstream
// would have put in its `AudioFormat`. Playing it is somebody else's job:
//
//   * `BuzzerAudioSink`; `loop(_:)` starts/replaces a continuously looping tone, `stop()` ends
//     it. Two methods, no platform types in either signature.
//   * `Buzzer.audioSinkFactory`: a static hook the UI layer (or `logisim-cli -sound`) installs,
//     producing one sink per `BuzzerData`, matching upstream's one `Clip` per `Data`. Left `nil`
//     the component computes the waveform and discards it, which is the correct headless
//     behaviour: silent, and no audio framework loaded.
//
// ── One deliberate mechanism deviation: no busy-spin ─────────────────────────────────────────
//
// Upstream's `threadFunc()` is, literally, `while (isOn.get()) { if (updateRequired) { … } }`:
// no `sleep`, no wait, in either branch. Once a buzzer is enabled its background thread pins a
// full CPU core for as long as it stays enabled, doing nothing between parameter changes. That is
// a resource-usage defect, not an observable simulated value, nothing a `.circ` file's outputs
// depend on, so unlike the Telnet trigger bug or the GateAttributes negation mask (D13/decisions.md
// precedent: preserve behaviour that produces a *wrong value*), this is not preserved. The
// **waveform generation itself is bit-for-bit the same algorithm**; only the "keep checking for
// new parameters" loop uses an `NSCondition` wait instead of spinning.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   (`paintInstance` IS ported; see the Paint section at the end of the factory.)
//   * `removeComponent(Circuit, Component, CircuitState)`; stops the sound thread when a buzzer
//     (or one nested in a subcircuit) is deleted. `CircuitState`/`Circuit` traversal is M3; the
//     signature this factory's `removeComponent` must satisfy
//     (`ComponentFactory.removeComponent(from:component:state:)`) currently receives
//     `state: AnyObject?` with no way to reach `getData(comp)` or subcircuit substates. Left
//     unimplemented with a `// TODO(M3)` below; until then a deleted `Buzzer`'s audio thread
//     keeps running, same as upstream would if `stopBuzzerSound` were never wired (it is, in
//     Java; this is a genuine, temporary regression versus upstream, not a preserved quirk).

import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// One generated tone, in exactly the shape upstream's `threadFunc` hands to `AudioInputStream`:
/// the `byte[]` it built, and the sample rate its `new AudioFormat(sampleRate, 16, 2, true, false)`
/// carried. The other four format parameters are invariant upstream, so they are `static let`s
/// here rather than fields; a sink still needs them to describe the buffer to whatever it plays
/// through.
public struct BuzzerTone: Equatable, Sendable {
  /// `Data.sampleRate`: `ceil(44100.0 / hz) * hz`, so an exact whole number of cycles fits.
  public let sampleRate: Int
  /// `buf`: `4 * sampleRate` bytes: interleaved stereo, low byte first per sample.
  public let pcm: [UInt8]

  public static let bitsPerSample = 16
  public static let channelCount = 2
  public static let isSigned = true
  public static let isBigEndian = false

  public init(sampleRate: Int, pcm: [UInt8]) {
    self.sampleRate = sampleRate
    self.pcm = pcm
  }
}

/// Where a `Buzzer`'s sound actually leaves the process. Upstream this is a `javax.sound.sampled`
/// `Clip`; here it is a protocol so `LogisimStd` stays platform-free (D9) and a headless
/// `logisim-cli` run links no audio framework at all.
///
/// The contract is `Clip`'s, narrowed to what `threadFunc` uses: `loop` opens the new buffer,
/// starts it at `Clip.LOOP_CONTINUOUSLY`, and closes whatever was playing before; `stop` is
/// upstream's `finally { clip.close(); }`. A class-bound protocol because a sink owns a live
/// resource and `BuzzerData` holds it across the lifetime of its thread.
public protocol BuzzerAudioSink: AnyObject {
  /// Replace the currently looping tone with `tone`, looping forever.
  func loop(_ tone: BuzzerTone)
  /// Stop and release. Called once, as the sound thread exits.
  func stop()
}

/// `Buzzer.BuzzerWaveform`. Upstream's is a Java enum with a strategy lambda per case; the
/// `.circ` token is the enum constant's own `Object.toString()` (its declared name), which the
/// two-argument `AttributeOption(Object, StringGetter)` constructor uses directly.
public enum BuzzerWaveform: String, AttributeOptionValue, CaseIterable, Sendable {
  case sine = "Sine"
  case square = "Square"
  case triangle = "Triangle"
  case sawtooth = "Sawtooth"
  case noise = "Noise"

  public static var attributeOptions: [BuzzerWaveform] { Array(allCases) }

  /// `BuzzerWaveformStrategy.amplitude(double, double, double)`.
  func amplitude(i: Double, hz: Double, pw: Double) -> Double {
    switch self {
    case .sine:
      return sin(i * hz * 2 * Double.pi)
    case .square:
      return (hz * i).truncatingRemainder(dividingBy: 1) < pw ? 1 : -1
    case .triangle:
      return asin(BuzzerWaveform.sine.amplitude(i: i, hz: hz, pw: pw)) * 2 / Double.pi
    case .sawtooth:
      return 2 * (hz * i).truncatingRemainder(dividingBy: 1) - 1
    case .noise:
      return Double.random(in: 0..<1) * 2 - 1
    }
  }
}

/// `Buzzer.Hz` / `dHz`: `FREQUENCY_MEASURE`'s two options.
public enum BuzzerFrequencyMeasure: String, AttributeOptionValue, CaseIterable, Sendable {
  case hz = "Hz"
  case dHz = "dHz"
  public static var attributeOptions: [BuzzerFrequencyMeasure] { Array(allCases) }
}

/// `Buzzer.C_BOTH` / `C_LEFT` / `C_RIGHT`: `CHANNEL`'s options. Upstream builds these from the
/// one-arg-`Object` `AttributeOption` constructor with an `Integer` payload, so the `.circ`
/// token is the decimal number itself (`"3"`, `"1"`, `"2"`), not a name.
public enum BuzzerChannel: Int32, AttributeOptionValue, CaseIterable, Sendable {
  case both = 3
  case left = 1
  case right = 2
  public static var attributeOptions: [BuzzerChannel] { Array(allCases) }
  public var attributeOptionName: String { String(rawValue) }
}

/// `com.cburch.logisim.std.io.extra.Buzzer`.
public final class Buzzer: InstanceFactoryBase {

  public static let id = "Buzzer"

  private static let freqPort = 0
  private static let enablePort = 1
  private static let volPort = 2
  private static let pwPort = 3

  public static let attrVolumeWidth: Attribute<BitWidth> = Attributes.forBitWidth("vol_width")
  public static let attrFrequencyMeasure: Attribute<BuzzerFrequencyMeasure> =
    Attributes.forOption("freq_measure")
  public static let attrWaveform: Attribute<BuzzerWaveform> = Attributes.forOption("waveform")
  public static let attrChannel: Attribute<BuzzerChannel> = Attributes.forOption("channel")
  public static let attrSmoothLevel: Attribute<Int32> = Attributes.forIntegerRange(
    "smooth_level", start: 0, end: 10)
  public static let attrSmoothWidth: Attribute<Int32> = Attributes.forIntegerRange(
    "smooth_width", start: 1, end: 10)

  /// The D9 seam described in the file header: upstream's `AudioSystem.getClip()`, hoisted out
  /// of this module. Each `BuzzerData` asks for its own sink the first time its sound thread has
  /// a tone to play, mirroring one `Clip` per `Data`. `nil` (the default, and what every headless
  /// run sees) means the waveform is still computed and simply goes nowhere.
  nonisolated(unsafe) public static var audioSinkFactory: (() -> any BuzzerAudioSink)?

  public init() {
    super.init(Buzzer.id)
    setAttributes([
      StdAttr.facing.binding(.west),
      StdAttr.selectLocation.binding(StdAttr.selectBottomLeft),
      Buzzer.attrFrequencyMeasure.binding(.hz),
      Buzzer.attrVolumeWidth.binding(BitWidth.known(7)),
      StdAttr.label.binding(""),
      StdAttr.labelFont.binding(StdAttr.defaultLabelFont),
      Buzzer.attrWaveform.binding(.sine),
      Buzzer.attrChannel.binding(BuzzerChannel.both),
      Buzzer.attrSmoothLevel.binding(2),
      Buzzer.attrSmoothWidth.binding(2),
    ])
    setFacingAttribute(StdAttr.facing)
  }

  public override func offsetBounds(_ attributes: any AttributeSet) -> Bounds {
    let facing = attributes.getValue(StdAttr.facing) ?? .west
    if facing == .east || facing == .west {
      return Bounds.create(-40, -20, 40, 40).rotate(from: .east, to: facing, xc: 0, yc: 0)
    }
    return Bounds.create(-20, 0, 40, 40).rotate(from: .north, to: facing, xc: 0, yc: 0)
  }

  public override func ports(_ attributes: any AttributeSet) -> [Port] {
    let facing = attributes.getValue(StdAttr.facing) ?? .west
    let volumeWidth = (attributes.getValue(Buzzer.attrVolumeWidth) ?? BitWidth.known(7))
    let selectLoc = attributes.getValue(StdAttr.selectLocation) ?? StdAttr.selectBottomLeft

    var freqPort: Port
    var volPort: Port
    if facing == .east || facing == .west {
      freqPort = Port(0, -10, .input, 14)
      volPort = Port(0, 10, .input, volumeWidth)
    } else {
      freqPort = Port(-10, 0, .input, 14)
      volPort = Port(10, 0, .input, volumeWidth)
    }
    let enable = Port(0, 0, .input, 1)

    var xPw = 20
    var yPw = 20
    if facing == .north || facing == .south {
      xPw *= (selectLoc == StdAttr.selectBottomLeft ? -1 : 1)
      yPw *= (facing == .south ? -1 : 1)
    } else {
      xPw *= (facing == .east ? -1 : 1)
      yPw *= (selectLoc == StdAttr.selectTopRight ? -1 : 1)
    }
    let pwPort = Port(xPw, yPw, .input, 8)

    return [freqPort, enable, volPort, pwPort]
  }

  public override func propagate(_ state: any InstanceState) throws {
    let data = (state.data as? BuzzerData) ?? {
      let fresh = BuzzerData()
      state.setData(fresh)
      return fresh
    }()

    let active = state.portValue(Buzzer.enablePort) == .trueValue

    var frequency = Int(state.portValue(Buzzer.freqPort).toLongValue())
    if frequency >= 0 {
      if state.attributeValue(Buzzer.attrFrequencyMeasure, default: .hz) == .dHz {
        frequency /= 10
      }
    } else {
      frequency = 440
    }

    let pwValue = state.portValue(Buzzer.pwPort)
    let pulseWidth = pwValue.isFullyDefined() ? Int(pwValue.toLongValue()) : 128

    let volValue = state.portValue(Buzzer.volPort)
    let volume: Double
    if volValue.isFullyDefined() {
      let raw = volValue.toLongValue()
      let volumeWidth = (state.attributeValue(Buzzer.attrVolumeWidth) ?? BitWidth.known(7)).width
      volume = (Double(UInt32(truncatingIfNeeded: raw)) * 32767.0) / (pow(2.0, Double(volumeWidth)) - 1)
    } else {
      volume = 0.5
    }

    data.update(
      isOn: active,
      hz: frequency,
      waveform: state.attributeValue(Buzzer.attrWaveform, default: .sine),
      channel: state.attributeValue(Buzzer.attrChannel, default: .both),
      pulseWidth: pulseWidth,
      smoothLevel: Int(state.attributeValue(Buzzer.attrSmoothLevel, default: 2)),
      smoothWidth: Int(state.attributeValue(Buzzer.attrSmoothWidth, default: 2)),
      volume: volume)
  }

  // TODO(M3): `removeComponent` needs `CircuitState.getData(Component)` and
  // `SubcircuitFactory.getSubstate` to recurse into nested subcircuits the way
  // `Buzzer.stopBuzzerSound` does. Until `CircuitState` lands, a removed `Buzzer`'s sound thread
  // is not stopped here, see the file header.

  // MARK: - Paint (D6)

  /// `paintInstance(InstancePainter)`: `Buzzer.java:189-214`.
  ///
  /// A speaker glyph: a DARK_GRAY disc, three GRAY concentric rings, a crosshair, a black cone
  /// centre and the component outline.
  ///
  /// It draws **nothing** that depends on simulation state: no on/off indication at all, even
  /// though `getData().isOn` is right there. A running buzzer looks exactly like a silent one,
  /// which is upstream's appearance and is not a gap in this port.
  ///
  /// The mixed hard-coded `40`s and derived `width`/`height`s are also upstream's: the disc is
  /// literally 40×40 while the crosshair is measured off the bounds. They agree because
  /// `getOffsetBounds` is always 40×40, but the two are written differently and are kept that
  /// way.
  public func paintInstance(_ painter: any IoInstancePainter) {
    let g = painter.scene
    let b = painter.bounds
    let x = b.x
    let y = b.y
    // Java narrows both to `byte` before use. At the fixed 40×40 bounds this is a no-op; it is
    // *not* a no-op above 127, which no shipped configuration reaches, so the narrowing is
    // recorded here rather than reproduced with a truncating conversion that could only ever
    // differ on an unreachable input.
    let height = b.height
    let width = b.width

    g.color = .darkGray
    g.fillOval(x, y, 40, 40)
    g.color = .gray
    g.strokeWidth = 2
    for k in stride(from: 8, through: 16, by: 4) {
      g.drawOval(x + 20 - k, y + 20 - k, k * 2, k * 2)
    }
    g.strokeWidth = 2
    g.color = .darkGray
    g.drawLine(x + 4, y + height / 2, x + 36, y + height / 2)
    g.drawLine(x + width / 2, y + 4, x + width / 2, y + 36)
    g.color = .black
    g.fillOval(x + 15, y + 15, 10, 10)
    g.color = painter.componentColor
    g.drawOval(x, y, 40, 40)
    painter.drawPorts()
    painter.drawLabel()
  }
}

extension Buzzer: IoPaintable {}

// MARK: - Label (board #78)

extension Buzzer: InstanceLabelProvider {

  /// `instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, b.getX() + b.getWidth() / 2,`
  /// `b.getY() - 3, H_CENTER, V_BOTTOM)`: `Buzzer.java:149-155`.
  ///
  /// Note `- 3`, not the `- 2` every `computeLabelTextField` NORTH arm uses, and no `LABEL_LOC`
  /// at all: a Buzzer's label is always above its body whatever the facing. Pure geometry:
  /// nothing here touches the tone generator, so D9/board #25 is untouched.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    return LabelPlacement(
      x: bds.x + bds.width / 2, y: bds.y - 3, halign: .center, valign: .bottom)
  }
}

/// `Buzzer.Data`; the tone generator backing one placed `Buzzer`.
///
/// Not a value-like `InstanceData`: `cloneData()` is upstream's own `new Data()` (a *fresh* clip,
/// not a copy of the running one); a forked `CircuitState` gets its own independent tone
/// generator, exactly matching `Data.clone()`.
public final class BuzzerData: InstanceData {
  private let condition = NSCondition()
  private var isOn = false
  private var updateRequired = true
  private var hz = 440
  private var waveform: BuzzerWaveform = .sine
  private var channel: BuzzerChannel = .both
  private var pulseWidth = 128
  private var smoothLevel = 0
  private var smoothWidth = 0
  private var volume: Double = 0.5

  private var thread: Thread?
  /// `Data.clip`: created lazily on the first tone, as upstream's `AudioSystem.getClip()` is, so
  /// a `Buzzer` that never reaches a playable frequency never asks the host for an audio device.
  private var sink: (any BuzzerAudioSink)?

  public init() {}

  public func cloneData() -> any InstanceData { BuzzerData() }

  /// `Buzzer.propagate`'s field assignments, gathered into one call.
  func update(
    isOn: Bool, hz: Int, waveform: BuzzerWaveform, channel: BuzzerChannel, pulseWidth: Int,
    smoothLevel: Int, smoothWidth: Int, volume: Double
  ) {
    condition.lock()
    self.isOn = isOn
    self.hz = hz
    self.waveform = waveform
    self.channel = channel
    self.pulseWidth = pulseWidth
    self.smoothLevel = smoothLevel
    self.smoothWidth = smoothWidth
    self.volume = volume
    self.updateRequired = true
    condition.signal()
    condition.unlock()

    // `if (active && !data.thread.isAlive()) data.startThread();`: checked on *every*
    // `isExecuting`, not merely "has a thread ever been created", because `threadFunc` exits
    // (and stops the engine) as soon as `isOn` goes false; toggling `ENABLE` back on must spawn
    // a fresh thread, not skip re-starting because `thread` is still non-nil from last time.
    if isOn, thread?.isExecuting != true {
      startThread()
    }
  }

  /// `Data.startThread()`: "avoid crash (for example if you connect a clock at 4KHz to the
  /// enable pin)". Upstream guards with `Thread.activeCount() > 100`, a process-wide count Swift
  /// exposes no equivalent for; the guard's actual job, never spawning a second live thread for
  /// a `Data` that already has one running, even under a fast-toggling `ENABLE`, is preserved by
  /// the `isExecuting` check at this method's one call site in `update(...)`.
  private func startThread() {
    let t = Thread { [weak self] in self?.threadFunc() }
    t.name = "Sound Thread"
    thread = t
    t.start()
  }

  /// `Data.threadFunc()`. See the file header: the parameter-change wait uses `NSCondition`
  /// rather than upstream's unconditional busy-spin; the waveform generation itself is verbatim.
  private func threadFunc() {
    var sampleRate = 44100
    var oldFrequency = -1

    while true {
      condition.lock()
      while isOn && !updateRequired {
        condition.wait()
      }
      guard isOn else {
        condition.unlock()
        break
      }
      updateRequired = false
      let hz = self.hz
      let waveform = self.waveform
      let channel = self.channel
      let pulseWidth = self.pulseWidth
      let smoothLevel = self.smoothLevel
      let smoothWidth = self.smoothWidth
      let volume = self.volume
      condition.unlock()

      // `if (!(hz >= 20 && hz <= 20000)) return;`; upstream *leaves* `threadFunc` here rather
      // than skipping the update, so its `finally` closes the clip and the buzzer falls silent
      // until the next `propagate` sees a dead thread and starts a new one. Breaking out of the
      // loop reproduces that; `continue` (an earlier revision) did not, and left the previous
      // tone looping through an out-of-range frequency.
      guard hz >= 20, hz <= 20000 else { break }

      if hz != oldFrequency {
        sampleRate = Int((44100.0 / Double(hz)).rounded(.up)) * hz
        oldFrequency = hz
      }

      let cycle = max(1, sampleRate / hz)
      var values = [Double](repeating: 0, count: 4 * cycle)
      for i in 0..<values.count {
        values[i] = waveform.amplitude(
          i: Double(i) / Double(sampleRate), hz: Double(hz), pw: Double(pulseWidth) / 256.0)
      }

      // `Data.threadFunc`'s box-car smoothing pass: skipped for `.sine`, exactly as upstream.
      if waveform != .sine, smoothLevel > 0, smoothWidth > 0 {
        var smoothed = [Double](repeating: 0, count: values.count)
        for _ in 0..<smoothLevel {
          var sum = 0.0
          for i in 0..<values.count {
            if i > 2 * smoothWidth {
              smoothed[i - smoothWidth - 1] = (sum - values[i - smoothWidth - 1]) / Double(2 * smoothWidth)
              sum -= values[i - 2 * smoothWidth - 1]
            }
            sum += values[i]
          }
          let lo = smoothWidth
          let hi = values.count - smoothWidth
          if hi > lo {
            values.replaceSubrange(lo..<hi, with: smoothed[lo..<hi])
          }
        }
      }

      var repeated = [Double](repeating: 0, count: sampleRate)
      var i = 0
      while i < sampleRate {
        let take = min(cycle, sampleRate - i)
        for j in 0..<take { repeated[i + j] = values[2 * cycle + j] }
        i += cycle
      }

      // `var buf = new byte[4 * sampleRate]` and its interleave loop, verbatim. Note the
      // asymmetry that makes this worth porting byte-for-byte rather than "scaling floats": a
      // channel the `CHANNEL` attribute masks out is not silenced by writing zero *samples*, it
      // is simply never written, so its two bytes keep `new byte[]`'s zero fill. Same result,
      // but the buffer a sink receives is bit-identical to Java's, which is the point.
      var pcm = [UInt8](repeating: 0, count: 4 * sampleRate)
      let leftOn = (channel.rawValue & 1) != 0
      let rightOn = (channel.rawValue & 2) != 0
      for frame in 0..<sampleRate {
        let val = javaShortRound(repeated[frame] * volume)
        // `val & 0xff` then `val >> 8`: Java's `>>` sign-extends the `short` through `int` before
        // the `(byte)` cast, which is the same low eight bits an arithmetic shift on `Int16`
        // gives, so both bytes come out identical.
        let low = UInt8(truncatingIfNeeded: val)
        let high = UInt8(truncatingIfNeeded: val >> 8)
        let base = frame * 4
        if leftOn {
          pcm[base] = low
          pcm[base + 1] = high
        }
        if rightOn {
          pcm[base + 2] = low
          pcm[base + 3] = high
        }
      }

      // `AudioSystem.getClip()` / `newClip.open(newAis)` / `clip.loop(LOOP_CONTINUOUSLY)`, with
      // the old clip closed: all of which the sink's own `loop(_:)` contract covers.
      if sink == nil { sink = Buzzer.audioSinkFactory?() }
      sink?.loop(BuzzerTone(sampleRate: sampleRate, pcm: pcm))
    }

    // `finally { clip.close(); ais.close(); }`.
    sink?.stop()
    sink = nil
  }
}

/// Java's `(short) Math.round(double)` as used in `threadFunc`'s interleave. `Math.round(double)`
/// is `(long) floor(d + 0.5)`, mapping NaN to 0 and saturating at the `long` bounds; the `(short)`
/// cast then keeps the low 16 bits rather than clamping. Reachable with a large `vol`, which is
/// derived from a port value and `VOLUME_WIDTH`, so the wrap has to be the truncating one.
@inline(__always)
private func javaShortRound(_ d: Double) -> Int16 {
  if d.isNaN { return 0 }
  let f = (d + 0.5).rounded(.down)
  if f >= 9_223_372_036_854_775_808.0 { return Int16(truncatingIfNeeded: Int64.max) }
  if f <= -9_223_372_036_854_775_808.0 { return Int16(truncatingIfNeeded: Int64.min) }
  return Int16(truncatingIfNeeded: Int64(f))
}
