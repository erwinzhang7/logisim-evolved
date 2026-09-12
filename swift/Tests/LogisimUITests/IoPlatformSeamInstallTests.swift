// IoPlatformSeamInstallTests.swift: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// BOARD #75; THE TWO `LogisimStd/Io` SEAMS NOTHING INSTALLED.
//
// Both were read on a live path and assigned nowhere in `Sources`:
//
//   `Tty.textMeasurer`            read by `Tty.columnWidth`, which `Tty.offsetBounds` multiplies
//                                 by the column count, so it sizes every placed TTY's box.
//   `TelnetServer.transportFactory`
//                                 read by `TelnetServer.init`, reached from `Telnet.propagate`
//                                 via `TelnetServerHolder.shared.server(port:bufferSize:)`.
//                                 Assigned in `Tests/LogisimStdTests` ONLY, which is why the
//                                 suite was green while the product was unwired.
//
// **"The seam is non-nil" is not the test here**, for the reason `UnassignedSeamInstallTests`'
// header records; this project has shipped several assertions that were green against exactly
// the version worth rejecting. So:
//
//   * the measurer is asserted through `Tty.offsetBounds`, the OBSERVABLE; the drawn box must
//     come out a different width installed than it does with the seam nil, and must match what
//     the installed measurer itself answers;
//   * the transport is asserted by connecting a REAL TCP CLIENT to the port a placed `Telnet`
//     component was configured with, after driving that component's own `propagate`, and
//     watching bytes travel in both directions. A transport that accepts and delivers nothing,
//     or a factory that hands back a stub, fails it.
//
// `.serialized`: both seams are process-global, and `swift test` links every test target into one
// process, so `LogisimStdTests`' own `TelnetTransportSeamTests` writes the very same
// `TelnetServer.transportFactory` this suite reads. That is a cross-target race this suite cannot
// fix from here (see `telnetTransportIsInstalled`'s comment on re-asserting), and it is exactly
// the hazard `UnassignedSeamInstallTests` section 6 already documents for `hdlKeywordCheck`.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Darwin
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender
import LogisimStd
import Testing

@testable import LogisimUI

@Suite("Board #75 — the two Io platform seams", .serialized)
struct IoPlatformSeamInstallTests {

  @MainActor
  private func makeHost() throws -> LogisimFileProjectHost {
    try #require(
      try LogisimFileProjectHostFactory().makeEmptyProject() as? LogisimFileProjectHost)
  }

  // MARK: - 1. `Tty.textMeasurer`

  /// The observable is the BOX, not the seam, and NOT "the box changed".
  ///
  /// ── WHY THE OBVIOUS ASSERTION IS THE WRONG ONE, MEASURED ────────────────────────────────────
  ///
  /// "`Tty.offsetBounds` returns a different width once the measurer is installed" is the natural
  /// test and it is green only against a measurer that is WRONG. `Tty.COL_WIDTH` is 7 and the
  /// JDK's `charWidth('W')` for `DEFAULT_FONT` is also 7, so a correct measurement reproduces the
  /// fallback exactly and the box does not move.
  ///
  /// That is not a guess. Installing `CoreTextMeasurer`, whose `width` truncates, per
  /// `TextMeasurer.width`'s own contract, made a 32-column TTY 204 wide against the fallback's
  /// 236, and turned `LogisimStdTests.OffsetBoundsOracleTests` from 0 mismatches to 9, every one
  /// of them a TTY row: `java=0,-122,236,132  swift=0,-122,204,132` and four more `rows=` rows,
  /// plus `cols=60` (432 vs 372), `cols=119` (845 vs 726) and `cols=120` (852 vs 732). Back the
  /// numbers out and every Java row is `2 * BORDER + cols * 7`. See `TtyCharWidthMeasurer`.
  ///
  /// So this test pins the two things that can actually be wrong:
  ///
  ///   1. the box the shipping measurer produces equals the jar's, at three column counts taken
  ///      straight from those oracle rows;
  ///   2. `Tty.columnWidth` genuinely CONSULTS the seam: proven with a sentinel measurer, since
  ///      the real one is indistinguishable from the fallback by construction.
  @Test("the TTY box matches the jar, and Tty.offsetBounds really reads the seam")
  @MainActor
  func ttyOffsetBoundsUsesTheInstalledMeasurer() throws {
    _ = try makeHost()

    let installed = try #require(
      Tty.textMeasurer,
      """
      Tty.textMeasurer is unassigned, so Tty.columnWidth asserts the COL_WIDTH constant instead \
      of measuring the font actually resolved for DEFAULT_FONT.
      """)
    #expect(
      installed === TtyTextMeasurer.shared,
      """
      the seam must hold the shared charWidth measurer. CoreTextMeasurer is NOT interchangeable \
      here — it truncates where FontMetrics.charWidth rounds, which is 9 oracle mismatches.
      """)
    #expect(
      installed.width(of: "W", font: Tty.defaultFont) == 7,
      "charWidth('W') for Font(\"monospaced\", PLAIN, 11) is 7 in the 4.1.0 jar")

    let factory = Tty()

    // The three widths lifted from `OffsetBoundsOracleTests`' own comparison rows.
    for (columns, javaWidth) in [(32, 236), (60, 432), (119, 845), (120, 852)] {
      let attributes = factory.createAttributeSet()
      try attributes.setValue(Tty.attrColumns, Int32(columns))
      try attributes.setValue(Tty.attrRows, 8)
      #expect(
        factory.offsetBounds(attributes).width == javaWidth,
        """
        a \(columns)-column TTY is \(factory.offsetBounds(attributes).width) wide; the 4.1.0 jar \
        draws \(javaWidth). The installed measurer does not answer FontMetrics.charWidth.
        """)
    }

    // ── The seam is actually READ ───────────────────────────────────────────────────────────
    //
    // A sentinel, because a correct measurer and the fallback constant agree. If `columnWidth`
    // ignored `Tty.textMeasurer`, or read it once and cached, this is the only assertion in
    // the file that would notice.
    let attributes = factory.createAttributeSet()
    try attributes.setValue(Tty.attrColumns, 32)
    try attributes.setValue(Tty.attrRows, 8)
    let real = factory.offsetBounds(attributes)

    let saved = Tty.textMeasurer
    defer { Tty.textMeasurer = saved }
    Tty.textMeasurer = SentinelMeasurer(charWidth: 11)
    let sentinel = factory.offsetBounds(attributes)

    #expect(
      sentinel.width == 2 * Tty.border + 32 * 11,
      """
      offsetBounds reported \(sentinel.width) with a measurer answering 11; expected \
      \(2 * Tty.border + 32 * 11). Tty.columnWidth is not reading the seam on every call.
      """)
    #expect(sentinel.width != real.width, "sanity: the sentinel must not agree with the real one")
    // The height has no measurer in it (`ROW_HEIGHT` is a constant upstream too), so it must NOT
    // move; a measurer wired into the wrong axis would still satisfy everything above.
    #expect(sentinel.height == real.height)

    Tty.textMeasurer = nil
    #expect(
      factory.offsetBounds(attributes).width == 2 * Tty.border + 32 * Tty.colWidth,
      "sanity: with the seam nil the box is the COL_WIDTH fallback")
  }

  // MARK: - 2. `TelnetServer.transportFactory`

  /// The whole path: the application installs the factory, a placed `Telnet` component
  /// propagates, and a real telnet client can then connect to the configured port and exchange
  /// bytes with the component's own `TelnetServer`.
  ///
  /// Driven through `SimulatableComponent.propagate(in:)` rather than by calling the holder,
  /// because the holder is not the thing that was broken; `Telnet.data(for:)` reaching a
  /// `TelnetServer` with a live listener is. With the seam unassigned the component takes
  /// `TelnetServer.init`'s documented headless branch, the port is never bound, and the
  /// `connect(2)` below fails.
  @Test("a placed Telnet component ends up listening, and bytes travel both ways")
  @MainActor
  func telnetTransportIsInstalled() throws {
    _ = try makeHost()

    // Read the seam the host installed. This `#require` is the half that fails outright when the
    // install line is deleted.
    let saved = TelnetServer.transportFactory
    let installed = try #require(
      saved,
      """
      TelnetServer.transportFactory is unassigned: TelnetServer.init takes its headless branch, \
      so a Telnet component in the shipped app never opens a socket whatever port it is set to.
      """)
    // Re-asserted, and restored on the way out, ONLY because `LogisimStdTests`'
    // `TelnetTransportSeamTests` writes this same process-global from another suite that
    // swift-testing may run in parallel with this one. The value written is the one the host
    // installed, so this cannot manufacture a pass: if the install line is gone, the `#require`
    // above has already failed.
    defer { TelnetServer.transportFactory = saved }
    TelnetServer.transportFactory = installed

    // The factory produces the REAL transport, not a stub. `Buzzer.audioSinkFactory`'s test makes
    // the same check for the same reason: `{ _ in NoOpTransport() }` satisfies every assertion
    // that only looks at the seam.
    let probePort = try #require(TelnetTestSocket.freePort(), "could not reserve a probe port")
    let probe = try #require(
      try installed(probePort) as? TelnetNetworkTransport,
      "the installed factory produced something other than the real network transport")
    probe.stop()

    let port = try #require(TelnetTestSocket.freePort(), "could not reserve a port")
    let (circuit, placement) = try makeTelnetCircuit(port: port)
    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)

    try placement.propagate(in: root)

    let server = try #require(
      root.getData(placement) as? TelnetServer,
      "Telnet.propagate did not attach a TelnetServer to the component")
    #expect(server.port == port)

    let client = try #require(
      TelnetTestSocket(connectingTo: port),
      """
      nothing is listening on port \(port) after the component propagated. \
      TelnetServer.transportFactory did not open a socket — this is the headless branch, which \
      is what the shipped app took for every Telnet component.
      """)
    defer { client.close() }

    // Inbound: client → component. `ATTR_TELNET_MODE` defaults to false, so no IAC negotiation
    // is in flight and every byte is a data byte.
    client.write([0x48, 0x69])  // "Hi"
    #expect(
      TelnetTestSocket.wait(untilTrue: { server.hasData() }),
      """
      the bytes a connected client sent never reached the component's ring buffer. The socket \
      accepted but nothing is delivering — TelnetTransportConnection.start(onBytes:) is not wired.
      """)
    #expect(server.data() == 0x48)
    server.deleteOldest()
    #expect(TelnetTestSocket.wait(untilTrue: { server.data() == 0x69 }))

    // Outbound: component → client. `TelnetServer.send` reaches the accepted connection, which
    // only exists once `onConnect` fired: proven by the inbound half above.
    server.send(0x5A)
    #expect(
      client.readByte() == 0x5A,
      "the component wrote a byte and the connected client never received it")
  }

  /// The control that makes the test above mean something.
  ///
  /// Same component, same propagate, same assertions: with the seam forced to `nil`, which is
  /// the state the shipped application was in. The server is still constructed and still
  /// simulates (that is `TelnetServer.init`'s documented headless contract), and nothing is
  /// listening, so the `connect(2)` fails. If this ever passes, the socket assertion above is not
  /// measuring the socket.
  @Test("with the seam nil the component still simulates and nothing is listening")
  @MainActor
  func headlessBranchBindsNothing() throws {
    _ = try makeHost()

    let saved = TelnetServer.transportFactory
    defer { TelnetServer.transportFactory = saved }
    TelnetServer.transportFactory = nil

    let port = try #require(TelnetTestSocket.freePort(), "could not reserve a port")
    let (circuit, placement) = try makeTelnetCircuit(port: port)
    let session = SimulationSession(host: SimulationHost())
    let root = session.createRootState(for: circuit)

    try placement.propagate(in: root)

    let server = try #require(root.getData(placement) as? TelnetServer)
    #expect(server.port == port)
    #expect(server.hasData() == false)
    #expect(server.isDead() == false, "an idle server must not be rebuilt on every propagation")

    #expect(
      TelnetTestSocket(connectingTo: port) == nil,
      "something is listening on \(port) with the transport seam nil")
  }

  /// A one-component circuit holding a `Telnet` bound to `port`.
  ///
  /// No wires: `Telnet.propagate` reads its ports and, with the clock undefined, does no I/O of
  /// its own, but it still runs `Telnet.data(for:)`, which is the line that reaches the seam.
  @MainActor
  private func makeTelnetCircuit(port: Int) throws -> (Circuit, any SimulatableComponent) {
    let circuit = try Circuit(name: "telnet-host", defaultAppearance: CircuitAttributes.appearEvolution)
    let factory = Telnet()
    let attributes = factory.createAttributeSet()
    try attributes.setValue(Telnet.attrPort, Int32(port))
    try attributes.setValue(Telnet.attrBuffer, 1024)
    try attributes.setValue(Telnet.attrTelnetMode, false)
    let component = try factory.createComponent(
      location: Location.create(200, 200, hasToSnap: true), attributes: attributes)
    // `StdInstanceComponent`, not `InstanceComponent`; `Telnet` is an `InstanceFactoryBase`, and
    // both types conform to `SimulatableComponent`, which is what carries `propagate(in:)`.
    let placement = try #require(component as? any SimulatableComponent)
    try circuit.mutatorAdd(placement)
    return (circuit, placement)
  }
}

/// Answers a fixed advance for every string, so `Tty.offsetBounds` moving is proof the seam was
/// consulted. Needed because a *correct* measurer is indistinguishable from the `COL_WIDTH`
/// fallback for `DEFAULT_FONT`, see `ttyOffsetBoundsUsesTheInstalledMeasurer`.
private final class SentinelMeasurer: TextMeasurer {
  private let charWidth: Int

  init(charWidth: Int) {
    self.charWidth = charWidth
  }

  func metrics(for font: SceneFont) -> FontMetrics {
    NominalTextMeasurer().metrics(for: font)
  }

  func width(of string: String, font: SceneFont) -> Int { charWidth * string.count }
}

// MARK: - A telnet client made of nothing but BSD sockets

/// Deliberately POSIX rather than `Network`: the production transport is Network.framework, and a
/// test client built on the same API could be green against a transport that talks only to
/// itself. `connect(2)` succeeding is the assertion that a real listening socket exists.
private final class TelnetTestSocket {
  private let descriptor: Int32

  /// A port nothing is currently listening on: bind `0`, read what the kernel assigned, release
  /// it. Racy in principle, and the alternative, a hardcoded port, collides with whatever else
  /// is on the machine, which is worse and less obvious when it happens.
  static func freePort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = INADDR_ANY.bigEndian
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return nil }
    var assigned = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &assigned) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else { return nil }
    let port = Int(UInt16(bigEndian: assigned.sin_port))
    return port == 0 ? nil : port
  }

  init?(connectingTo port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else {
      Darwin.close(fd)
      return nil
    }
    // Bounded, so a transport that accepts and never writes fails the assertion rather than
    // hanging the suite.
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    descriptor = fd
  }

  func write(_ bytes: [UInt8]) {
    _ = bytes.withUnsafeBytes { buffer in
      Darwin.send(descriptor, buffer.baseAddress, buffer.count, 0)
    }
  }

  func readByte() -> UInt8? {
    var byte: UInt8 = 0
    return recv(descriptor, &byte, 1, 0) == 1 ? byte : nil
  }

  func close() {
    Darwin.close(descriptor)
  }

  /// Poll rather than block: delivery happens on the transport's `DispatchQueue`, so the byte
  /// arrives some short time after `write` returns. Three seconds is orders of magnitude more
  /// than a loopback round trip and short enough to fail rather than hang.
  static func wait(untilTrue condition: () -> Bool, seconds: Double = 3) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      usleep(2000)
    }
    return condition()
  }
}
