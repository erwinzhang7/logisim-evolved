// BuzzerAudioEngineSink.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (the `javax.sound.sampled` half of
// com.cburch.logisim.std.io.extra.Buzzer.Data.threadFunc),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// WHERE A BUZZER'S SOUND LEAVES THE PROCESS.
//
// `Buzzer.audioSinkFactory` was declared, read once, and assigned nowhere: a placed Buzzer
// computed its waveform byte-for-byte correctly and then discarded it, so the component was
// silent in the app.
//
// **`nil` remains the correct DEFAULT**, and this file is deliberately not in `LogisimStd`.
// Board #25 hoisted `AVFoundation` out of that module for exactly this reason: `logisim-cli`
// converts a `.circ` headlessly, and linking a platform media framework into the component
// library makes the differential harness carry an audio stack it can never use.
// `PlatformFreedomTests` enforces that from CI. So the model stays down there and the join is
// made in `LogisimFileProjectHostFactory.registerBuiltinLibrariesIfNeeded`; the one process
// that has a UI to make noise in.
//
// ── WHAT IS PORTED, AND THE ONE FORMAT CONVERSION ────────────────────────────────────────────
//
// `BuzzerTone` carries the exact `byte[]` upstream hands `AudioInputStream`: 16-bit signed
// little-endian, two interleaved channels, `4 * sampleRate` bytes. `AVAudioEngine` is happiest
// with deinterleaved Float32, so `frames(from:)` below performs that conversion: division by
// 32768 and nothing else, so it is exact for every representable sample and reversible.
//
// The conversion is a separate, pure, testable function rather than being buried in `loop`,
// because it is the only part of this file that can be checked without an audio device.
//
// ── UPSTREAM'S `Clip` CONTRACT, NARROWED ─────────────────────────────────────────────────────
//
//   * `loop(_:)` : `AudioSystem.getClip()` / `newClip.open(ais)` /
//                   `clip.loop(Clip.LOOP_CONTINUOUSLY)`, with the previously playing clip closed.
//   * `stop()`   ; the `finally { clip.close(); ais.close(); }`.
//
// One `Data` owns one sink for the life of its sound thread, matching one `Clip` per `Data`.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import AVFoundation
import Foundation
import LogisimStd

/// The shipping conformer for `Buzzer.audioSinkFactory`.
///
/// `@MainActor` is deliberately NOT applied: `Buzzer`'s sound thread calls `loop`/`stop`
/// directly, off any actor, exactly as upstream's `threadFunc` calls `Clip`. The class is
/// `@unchecked Sendable` with an `NSLock` around every mutable field, which is the same
/// discipline the rest of the D1 layer uses.
public final class BuzzerAudioEngineSink: BuzzerAudioSink, @unchecked Sendable {

  private let lock = NSLock()
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()

  private var attached = false
  private var storedTone: BuzzerTone?
  private var storedFailure: String?

  public init() {}

  // MARK: - Observability
  //
  // These three exist so this class can be tested without an audio device, and so a test can
  // tell a working sink from a plausible-looking one that does nothing. "The factory is
  // non-nil" is necessary and nowhere near sufficient; `Buzzer.audioSinkFactory = { NoOpSink() }`
  // would satisfy it.

  /// The tone currently looping, or `nil` before the first `loop` and after `stop`.
  public var currentTone: BuzzerTone? { lock.withLock { storedTone } }

  /// Why the engine could not start, if it could not. `nil` means it did.
  ///
  /// A headless CI machine with no output device is a real and expected case, and it must not
  /// take the simulation down: the waveform is still computed and the component still behaves.
  /// Recorded rather than swallowed so "silent" and "silently broken" stay distinguishable.
  public var lastFailure: String? { lock.withLock { storedFailure } }

  /// Whether the underlying engine is running.
  public var isRunning: Bool { engine.isRunning }

  // MARK: - BuzzerAudioSink

  public func loop(_ tone: BuzzerTone) {
    lock.lock()
    storedTone = tone
    lock.unlock()

    guard let buffer = Self.makeBuffer(from: tone) else {
      lock.withLock { storedFailure = "could not describe a \(tone.sampleRate) Hz stereo buffer" }
      return
    }

    // `clip.close()` on the old one, before opening the new: upstream replaces the clip outright
    // rather than crossfading, and a second `scheduleBuffer` without this would queue behind the
    // first loop rather than replacing it: an audible difference, and one that never ends.
    player.stop()

    do {
      if !attached {
        engine.attach(player)
        attached = true
      }
      engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
      if !engine.isRunning { try engine.start() }
      player.scheduleBuffer(buffer, at: nil, options: .loops)
      player.play()
      lock.withLock { storedFailure = nil }
    } catch {
      lock.withLock { storedFailure = "\(error)" }
    }
  }

  public func stop() {
    player.stop()
    if engine.isRunning { engine.stop() }
    lock.withLock { storedTone = nil }
  }

  // MARK: - Format conversion

  /// The interleaved 16-bit little-endian PCM upstream builds, as deinterleaved Float32 frames.
  ///
  /// Pure, and separated out so it can be checked with no audio device: `[low, high]` per sample,
  /// left then right, `4 * sampleRate` bytes in, `sampleRate` frames per channel out. A trailing
  /// partial frame is impossible by `BuzzerTone`'s construction and is dropped rather than
  /// trapped if one ever appears (D13; this is a media path, not an invariant a caller controls).
  public static func frames(from tone: BuzzerTone) -> (left: [Float], right: [Float]) {
    let frameCount = tone.pcm.count / 4
    var left = [Float](repeating: 0, count: frameCount)
    var right = [Float](repeating: 0, count: frameCount)
    for frame in 0..<frameCount {
      let base = frame * 4
      let l = Int16(bitPattern: UInt16(tone.pcm[base]) | (UInt16(tone.pcm[base + 1]) << 8))
      let r = Int16(bitPattern: UInt16(tone.pcm[base + 2]) | (UInt16(tone.pcm[base + 3]) << 8))
      // 32768, not 32767: the divisor is the magnitude of the most negative representable
      // sample, so -32768 maps to exactly -1.0 and nothing can clip.
      left[frame] = Float(l) / 32768
      right[frame] = Float(r) / 32768
    }
    return (left, right)
  }

  /// `new AudioInputStream(new ByteArrayInputStream(buf), format, buf.length)`.
  static func makeBuffer(from tone: BuzzerTone) -> AVAudioPCMBuffer? {
    let frameCount = tone.pcm.count / 4
    guard frameCount > 0,
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(tone.sampleRate),
        channels: AVAudioChannelCount(BuzzerTone.channelCount),
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
      let channels = buffer.floatChannelData
    else { return nil }

    let (left, right) = frames(from: tone)
    left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: frameCount) }
    right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: frameCount) }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    return buffer
  }
}
