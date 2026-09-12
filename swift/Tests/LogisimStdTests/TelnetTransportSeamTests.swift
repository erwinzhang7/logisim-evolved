// TelnetTransportSeamTests.swift: part of logisim-evolved.
//
// The D9 seam that replaced `TelnetServer`'s `import Network`. Two things need proving, and the
// first is the one that matters for the headless gate:
//
//   1. With no transport installed, every `swift test` run, every `logisim-cli` conversion,
//      constructing a `TelnetServer` binds nothing, does not throw, and leaves the model fully
//      usable. A `Telnet` component simulates against an empty buffer, which is exactly how it
//      behaves with a real listener that no client has connected to.
//   2. With a transport installed, bytes travel and the telnet `IAC` filter still strips
//      command sequences: including one split across two deliveries, which is the case the
//      one-byte-at-a-time Java original never had to handle.
//
// Serialised: `TelnetServer.transportFactory` and `TelnetServerHolder.shared` are process-wide,
// exactly as upstream's `ServerHolder.INSTANCE` is, so these cases cannot run concurrently.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import Foundation
import Testing

@testable import LogisimStd

/// A `TelnetTransportConnection` that is just two arrays; what the seam is worth.
private final class FakeConnection: TelnetTransportConnection {
  private let lock = NSLock()
  private var onBytes: (([UInt8]) -> Void)?
  private(set) var sent: [UInt8] = []
  private(set) var closed = false

  func start(onBytes: @escaping ([UInt8]) -> Void) {
    lock.lock()
    self.onBytes = onBytes
    lock.unlock()
  }

  func send(_ bytes: [UInt8]) {
    lock.lock()
    sent.append(contentsOf: bytes)
    lock.unlock()
  }

  func close() {
    lock.lock()
    closed = true
    lock.unlock()
  }

  /// Simulate the peer writing `bytes` as one delivery.
  func deliver(_ bytes: [UInt8]) {
    lock.lock()
    let handler = onBytes
    lock.unlock()
    handler?(bytes)
  }
}

private final class FakeTransport: TelnetTransport {
  let connection = FakeConnection()
  private var onConnect: ((any TelnetTransportConnection) -> Void)?
  var isDead = false

  func start(onConnect: @escaping (any TelnetTransportConnection) -> Void) {
    self.onConnect = onConnect
  }

  /// Simulate a client arriving.
  func accept() { onConnect?(connection) }
}

@Suite("D9 — the telnet transport seam", .serialized)
struct TelnetTransportSeamTests {

  /// Restore the process-wide hook whatever a case does with it.
  private func withTransportFactory(
    _ factory: ((Int) throws -> any TelnetTransport)?, _ body: () throws -> Void
  ) rethrows {
    let saved = TelnetServer.transportFactory
    TelnetServer.transportFactory = factory
    defer { TelnetServer.transportFactory = saved }
    try body()
  }

  @Test("headless: no transport installed binds nothing and still simulates")
  func headlessIsSilentButLive() throws {
    try withTransportFactory(nil) {
      let server = try TelnetServerHolder.shared.server(port: 45_001, bufferSize: 8)

      // The model is fully functional; there is simply never any input.
      #expect(server.hasData() == false)
      #expect(server.data() == -1)
      #expect(server.bufferSize() == 8)
      #expect(server.port == 45_001)

      // Not "dead"; see `isDead()`'s note. A dead server would be rebuilt by the holder on
      // every propagation, discarding the ring buffer each time.
      #expect(server.isDead() == false)
      let again = try TelnetServerHolder.shared.server(port: 45_001, bufferSize: 8)
      #expect(again === server, "the holder must reuse one server per port, as ServerHolder does")

      // Writing to a client that is not there must not trap.
      server.send(0x41)
    }
  }

  @Test("an out-of-range port is rejected by the model, not by the transport")
  func portRangeIsModelSide() throws {
    try withTransportFactory(nil) {
      #expect(throws: TelnetServer.TelnetServerError.self) {
        _ = try TelnetServerHolder.shared.server(port: 0, bufferSize: 4)
      }
    }
  }

  @Test("with a transport, bytes arrive and outbound writes reach the connection")
  func bytesTravel() throws {
    let transport = FakeTransport()
    try withTransportFactory({ _ in transport }) {
      let server = try TelnetServerHolder.shared.server(port: 45_002, bufferSize: 16)
      server.setTelnetEscape(false)
      transport.accept()

      transport.connection.deliver([0x48, 0x69])  // "Hi"
      #expect(server.hasData())
      #expect(server.data() == 0x48)
      server.deleteOldest()
      #expect(server.data() == 0x69)

      server.send(0x5A)
      #expect(transport.connection.sent.contains(0x5A))
    }
  }

  @Test("the IAC filter strips a command sequence split across two deliveries")
  func iacFilterSpansDeliveries() throws {
    let transport = FakeTransport()
    try withTransportFactory({ _ in transport }) {
      let server = try TelnetServerHolder.shared.server(port: 45_003, bufferSize: 16)
      server.setTelnetEscape(true)
      transport.accept()

      // `IAC WILL ECHO` split after the IAC; the case Java's blocking one-byte read never
      // saw, and the reason the filter is a state machine rather than a per-chunk scan.
      transport.connection.deliver([0x41, 0xFF])
      transport.connection.deliver([251, 1, 0x42])

      #expect(server.data() == 0x41, "the byte before IAC must survive")
      server.deleteOldest()
      #expect(server.data() == 0x42, "the 3-byte IAC sequence must be stripped entirely")
      server.deleteOldest()
      #expect(server.hasData() == false)

      // Escaping on also means the server announced its options to the client.
      #expect(transport.connection.sent.starts(with: [0xFF, 251, 3, 0xFF, 251, 1]))
    }
  }
}
