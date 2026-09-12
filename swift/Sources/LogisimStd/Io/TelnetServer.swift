// TelnetServer.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.TelnetServer), itself "based on code
// from Digital, Copyright (c) 2021 Helmut Neemann"
// (https://github.com/logisim-evolution/logisim-evolution). This translation is a derivative
// work and is therefore GPL-3.0-only. See LICENSE.md. D12 records the missing upstream license
// header on the Java file; not resolved here.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── The socket is reached through a seam, not opened here (D9) ───────────────────────────────
//
// An earlier revision of this file imported `Network` and drove `NWListener`/`NWConnection`
// directly. That is the same D9 violation `Buzzer` had with `AVFoundation`, and it is wrong for
// the same reason: `logisim-cli` converts a `.circ` headless, and linking a platform networking
// framework into `LogisimStd` to do it makes the differential harness carry a transport it can
// never use. `Network` was the last non-`Foundation` platform import in the module.
//
// What stays here is the whole *model*, which is what a fidelity port owes: `ByteRingBuffer`
// with its sign-extending `peek()` ambiguity, the three-state `IAC` filter, the one-server-per-
// port `ServerHolder`, the `lastClock` edge latch, and `setBufferSize`'s discard-everything
// semantics. What leaves is only the bytes' means of travel:
//
//   * `TelnetTransport`; a listener. `start(onConnect:)` begins accepting; `isDead` is
//     upstream's `!serverThread.isAlive()`.
//   * `TelnetTransportConnection`; one accepted client. Raw bytes in and out; the `IAC`
//     filtering stays on this side, because it is protocol semantics rather than transport.
//   * `TelnetServer.transportFactory`; the hook the UI layer (or a `logisim-cli` that opts in)
//     installs. Left `nil`, what every headless run sees, a `Telnet` component still
//     simulates: it holds its ring buffer, answers `hasData()`/`data()`, and latches clock
//     edges exactly as it would with a client attached that never happens to send anything.
//
// ── Scoping the listening socket (the original point of care, now stronger) ──────────────────
//
// Upstream's long-standing firewall warning (objectives.md's #747, five years open) exists
// because *loading the `IoLibrary` class* has never opened a socket; `TelnetServer` only binds
// when `Telnet.propagate` first calls `ServerHolder.INSTANCE.getServer(port, …)` for a
// component that is actually simulating. That scoping is preserved and is now enforced by
// construction rather than by care: `TelnetServerHolder.shared` is a lazy singleton over an
// **empty** dictionary, and the single `transportFactory` call lives in `TelnetServer.init`,
// reached solely from `server(port:bufferSize:)`, reached solely from `Telnet.propagate`. With
// no factory installed there is no code in this module that could bind a port even if it were
// called, which is a stronger guarantee than the grep the previous revision asked you to run.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `getInstanceState()`; only ever used to call `fireInvalidated()` from the network
//     callback when data arrives, which is preserved (`dataReceived`); the getter itself
//     has no other caller and is dropped.
//   * Nothing paint-related lives here (this is pure `InstanceData`, matching upstream).

import Foundation
import LogisimKernel

/// One accepted telnet client, as `TelnetServer` needs it: raw bytes in, raw bytes out.
///
/// Upstream this is a `Socket` plus the `ClientThread` reading it. The read loop is the
/// conformer's business, a thread, a `DispatchQueue`, an `NWConnection` completion handler,
/// anything, because that is precisely the platform-shaped part. `onBytes` may be called with
/// arbitrarily-sized chunks and from any thread; `TelnetServer` serialises under its own lock.
///
/// There is no production conformer in this module *by design*: D9 keeps `Network` out of
/// `LogisimStd`, so the socket lands in the UI layer or in a `logisim-cli` that opts in, and
/// `TelnetServer.transportFactory` stays `nil` for every headless run. `FakeConnection` in
/// `TelnetTransportSeamTests` conforms and exercises the whole path; seamcheck scans only
/// `swift/Sources`, so it cannot see that and reports the protocol as unwired.
///
/// **NOT-PORTED in `LogisimStd`, deliberately**, and the marker has to sit within six lines of
/// the declaration, which is the window `tools/seamcheck.py` reads.
public protocol TelnetTransportConnection: AnyObject {
  /// Begin delivering received bytes. Called once.
  func start(onBytes: @escaping ([UInt8]) -> Void)
  /// `ClientThread.send(int)`, batched. A write to a client that has gone away is not an error
  /// upstream cares about (`catch (IOException e) { // not really a problem }`), so this
  /// returns nothing and must not trap.
  func send(_ bytes: [UInt8])
  /// Release the connection. Called when the peer closes or errors.
  func close()
}

/// The listening socket, as `TelnetServer` needs it. Upstream this is `ServerSocket` plus
/// `ServerThread`'s accept loop.
///
/// **NOT-PORTED in `LogisimStd`, deliberately**; same reasoning as
/// `TelnetTransportConnection` above; `FakeTransport` in `TelnetTransportSeamTests` is the
/// conformer, and it lives outside the tree seamcheck scans.
public protocol TelnetTransport: AnyObject {
  /// Begin accepting. `onConnect` fires once per accepted client, from any thread.
  func start(onConnect: @escaping (any TelnetTransportConnection) -> Void)
  /// `TelnetServer.isDead()`; `!serverThread.isAlive()`. A transport whose listener has
  /// failed or been cancelled reports `true`, and `TelnetServerHolder` then rebuilds it.
  var isDead: Bool { get }
}

/// `com.cburch.logisim.std.io.TelnetServer`.
///
/// A `final class` (D3/D4): `InstanceData` is a per-`CircuitState` scratch object, but this one
/// deliberately does *not* behave like most: see `cloneData()` below, which mirrors upstream's
/// `clone()` returning `null`. The live socket is a resource `CircuitState` forking must not
/// duplicate.
public final class TelnetServer: InstanceData {

  public enum TelnetServerError: Error, CustomStringConvertible {
    case invalidPort(Int)
    case listenerFailed(port: Int, underlying: Error)

    public var description: String {
      switch self {
      case .invalidPort(let port): return "invalid TCP port \(port)"
      case .listenerFailed(let port, let underlying):
        return "could not open telnet server on port \(port): \(underlying)"
      }
    }
  }

  /// The D9 seam described in the file header: upstream's `new ServerSocket(port)`, hoisted out
  /// of this module. `nil`, the default and what every headless run sees, means a `Telnet`
  /// component simulates against an empty buffer and never binds anything.
  ///
  /// A factory that cannot bind should throw; `TelnetServerHolder.server(port:bufferSize:)`
  /// propagates it, and `Telnet.propagate` surfaces it as a circuit error, which is exactly
  /// what upstream does with the `IOException` from `new ServerSocket`.
  public nonisolated(unsafe) static var transportFactory: ((_ port: Int) throws -> any TelnetTransport)?

  private let lock = NSLock()
  private let transport: (any TelnetTransport)?
  private let requestedPort: Int
  private var buffer: ByteRingBuffer
  private var telnetEscape = false
  private var client: TelnetClientConnection?
  private var lastClock: Value?
  /// D3: weak. `InstanceState` does not outlive a single `propagate` call in the real
  /// implementation (`InstanceStateImpl` is reused, per D1/D2), so holding this strongly would
  /// pin an arbitrary, possibly stale, scratch object across every future propagation.
  private weak var instanceState: (any InstanceState)?

  fileprivate init(port: Int, bufferSize: Int) throws {
    // `new ServerSocket(port)` rejects anything outside 0…65535 with an
    // `IllegalArgumentException`; the range check belongs to the model, not to the transport,
    // so it stays here and applies even when no transport is installed.
    guard (1...65535).contains(port) else {
      throw TelnetServerError.invalidPort(port)
    }
    self.requestedPort = port
    self.buffer = ByteRingBuffer(capacity: bufferSize)

    guard let factory = TelnetServer.transportFactory else {
      // Headless: the model runs, nothing listens. See the file header.
      self.transport = nil
      return
    }
    do {
      self.transport = try factory(port)
    } catch {
      throw TelnetServerError.listenerFailed(port: port, underlying: error)
    }
    transport?.start { [weak self] connection in
      self?.accept(connection)
    }
  }

  /// `TelnetServer.getPort()`; `serverSocket.getLocalPort()`. `ATTR_PORT` is always a concrete
  /// port in `1...65535` (never the ephemeral `0`), so the requested and bound ports agree.
  public var port: Int { requestedPort }

  /// `TelnetServer.setLastClock(Value)`.
  public func setLastClock(_ newClock: Value) -> Value? {
    lock.lock()
    defer { lock.unlock() }
    let previous = lastClock
    lastClock = newClock
    return previous
  }

  /// `TelnetServer.send(int)`.
  public func send(_ value: Int) {
    lock.lock()
    let target = client
    lock.unlock()
    target?.send(byte: UInt8(truncatingIfNeeded: value))
  }

  /// `TelnetServer.getData()`: `buffer.peek()`, widened exactly as Java widens `byte` to `int`
  /// (sign-extending), so an empty buffer and a genuine `0xFF` byte both read back as `-1`,
  /// preserved verbatim per the file header on `ByteRingBuffer.peek()`.
  public func data() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return Int(buffer.peek())
  }

  /// `TelnetServer.deleteOldest()`.
  public func deleteOldest() {
    lock.lock()
    defer { lock.unlock() }
    buffer.delete()
  }

  /// `TelnetServer.deleteAll()`.
  public func deleteAll() {
    lock.lock()
    defer { lock.unlock() }
    buffer.deleteAll()
  }

  /// `TelnetServer.hasData()`.
  public func hasData() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return buffer.hasData()
  }

  /// `TelnetServer.setTelnetEscape(boolean)`.
  public func setTelnetEscape(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    telnetEscape = enabled
  }

  /// `TelnetServer.getBufferSize()`.
  public func bufferSize() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return buffer.capacity
  }

  /// `TelnetServer.setBufferSize(int)`: replaces the buffer outright, exactly as upstream
  /// (`buffer = new ByteBuffer(bufferSize)`), which is why this discards whatever was queued.
  public func setBufferSize(_ size: Int) {
    lock.lock()
    defer { lock.unlock() }
    buffer = ByteRingBuffer(capacity: size)
  }

  /// `TelnetServer.setInstanceState(InstanceState)`.
  public func setInstanceState(_ state: any InstanceState) {
    lock.lock()
    instanceState = state
    lock.unlock()
  }

  /// `TelnetServer.isDead()`; `!serverThread.isAlive()`.
  ///
  /// With no transport installed this is `false`, and that is deliberate rather than a
  /// degenerate default. `TelnetServerHolder.server` rebuilds any server that reports dead, so
  /// answering `true` headlessly would construct a fresh `TelnetServer` on **every**
  /// propagation: discarding the ring buffer each time, which is observable: `hasData()` would
  /// never stay true across a tick. A server with nothing listening is idle, not dead, and that
  /// keeps the headless path behaviourally identical to a live one whose client is silent.
  public func isDead() -> Bool { transport?.isDead ?? false }

  /// `TelnetServer.clone()`, which upstream deliberately returns `null` from; `InstanceData`
  /// requires a real value here, so the file header's "does not behave like most" is made
  /// explicit: a fork gets a data object that shares the same live socket rather than a
  /// disconnected copy. There is exactly one socket per port regardless of how many
  /// `CircuitState`s reference this component (see `ServerHolder`), so sharing is correct: two
  /// forked states of the same circuit still talk to the same telnet client.
  public func cloneData() -> any InstanceData { self }

  // MARK: Networking

  private func accept(_ connection: any TelnetTransportConnection) {
    lock.lock()
    let escape = telnetEscape
    lock.unlock()
    let handler = TelnetClientConnection(connection: connection, telnetEscape: escape) {
      [weak self] byte in
      self?.dataReceived(byte)
    }
    lock.lock()
    client = handler
    lock.unlock()
    handler.start()
  }

  /// `TelnetServer.dataReceived(int)`.
  private func dataReceived(_ byte: UInt8) {
    lock.lock()
    buffer.put(byte)
    let state = instanceState
    lock.unlock()
    state?.fireInvalidated()
  }
}

/// `TelnetServer.ClientThread`, minus the one-thread-per-connection model: see the file header.
///
/// Reimplements the same three-state IAC (`0xFF`) filter as a byte-at-a-time state machine,
/// because a transport delivers arbitrarily-sized chunks and an `IAC`/command/option triple can
/// straddle two of them: unlike Java's blocking `InputStream.read()`, which upstream gets away
/// with reading one byte at a time regardless of chunking. Keeping the filter on this side of
/// the seam is deliberate: it is telnet protocol semantics, and a transport conformer must not
/// be able to get it subtly wrong.
private final class TelnetClientConnection {
  private static let echo: UInt8 = 1
  private static let suppressGoAhead: UInt8 = 3
  private static let will: UInt8 = 251
  private static let iac: UInt8 = 255

  private enum ReadState {
    case normal
    case sawIac
    case sawIacCommand
  }

  private let connection: any TelnetTransportConnection
  private let telnetEscape: Bool
  private let onByte: (UInt8) -> Void
  private let stateLock = NSLock()
  private var state: ReadState = .normal

  init(
    connection: any TelnetTransportConnection, telnetEscape: Bool,
    onByte: @escaping (UInt8) -> Void
  ) {
    self.connection = connection
    self.telnetEscape = telnetEscape
    self.onByte = onByte
  }

  func start() {
    // Start delivery BEFORE the option negotiation below, so a client that answers immediately
    // cannot have its reply dropped. Upstream's `ClientThread` has the same ordering by
    // accident, the socket's receive buffer is already live when `run()` writes the IAC
    // sequence, and here it has to be arranged deliberately.
    connection.start { [weak self] bytes in
      guard let self else { return }
      for byte in bytes { self.process(byte) }
    }
    if telnetEscape {
      // `IAC WILL SGA, IAC WILL ECHO`: request the client stop local echo and line buffering.
      send(bytes: [Self.iac, Self.will, Self.suppressGoAhead, Self.iac, Self.will, Self.echo])
    }
  }

  /// `ClientThread.run()`'s per-byte branch: strip a 3-byte `IAC command option` sequence when
  /// telnet escaping is on, deliver everything else.
  /// The `IAC` state machine is guarded because a transport may deliver from any thread and is
  /// under no obligation to serialise. Upstream's single `ClientThread` made that free.
  private func process(_ byte: UInt8) {
    guard telnetEscape else {
      onByte(byte)
      return
    }
    stateLock.lock()
    let deliver: Bool
    switch state {
    case .normal:
      if byte == Self.iac {
        state = .sawIac
        deliver = false
      } else {
        deliver = true
      }
    case .sawIac:
      state = .sawIacCommand
      deliver = false
    case .sawIacCommand:
      state = .normal
      deliver = false
    }
    stateLock.unlock()
    // Outside the lock: `onByte` reaches `TelnetServer.dataReceived`, which takes the server's
    // own lock and then calls `fireInvalidated()`. Holding both at once is a lock-ordering
    // hazard for no benefit.
    if deliver { onByte(byte) }
  }

  /// `ClientThread.send(int)`.
  func send(byte: UInt8) {
    send(bytes: [byte])
  }

  private func send(bytes: [UInt8]) {
    // `catch (IOException e) { e.printStackTrace(); // not really a problem }`; a failed write
    // to a client that has gone away is not an error condition upstream cares about, which is
    // why `TelnetTransportConnection.send` cannot fail.
    connection.send(bytes)
  }
}

/// `TelnetServer.ByteBuffer`: a fixed-capacity ring buffer of bytes.
///
/// **`peek()` preserves a genuine upstream ambiguity, deliberately.** An empty buffer and a
/// buffer whose oldest byte is `0xFF` both read back as `-1` once Java widens `byte` to `int`
/// (sign-extending). This never causes an observable bug: `Telnet.propagate` always checks the
/// `AVAIL` port (`hasData()`) before deciding whether to trust `OUT`, so the ambiguous case is
/// exactly the case nothing reads. See `TelnetServer.data()`.
struct ByteRingBuffer {
  private var storage: [UInt8]
  private(set) var capacity: Int
  private var count = 0
  private var newest = 0
  private var oldest = 0

  init(capacity: Int) {
    self.capacity = max(capacity, 0)
    self.storage = Array(repeating: 0, count: self.capacity)
  }

  /// `ByteBuffer.put(byte)`.
  mutating func put(_ value: UInt8) {
    guard capacity > 0, count < capacity else { return }
    storage[newest] = value
    newest = increment(newest)
    count += 1
  }

  /// `ByteBuffer.peek()`, see the struct header.
  func peek() -> Int8 {
    guard count > 0 else { return -1 }
    return Int8(bitPattern: storage[oldest])
  }

  /// `ByteBuffer.delete()`.
  mutating func delete() {
    guard count > 0 else { return }
    oldest = increment(oldest)
    count -= 1
  }

  /// `ByteBuffer.deleteAll()`.
  mutating func deleteAll() {
    oldest = 0
    newest = 0
    count = 0
  }

  /// `ByteBuffer.hasData()`.
  func hasData() -> Bool { count > 0 }

  private func increment(_ index: Int) -> Int {
    let next = index + 1
    return next >= capacity ? 0 : next
  }
}

/// `TelnetServer.ServerHolder`; "Usage of this singleton allows the telnet client to stay
/// connected also if the simulation is not running."
///
/// See the file header for why constructing this: including at first access via `shared`;
/// binds no socket: the dictionary starts empty, and `server(port:bufferSize:)` is the only
/// place a `TelnetServer` (and therefore an `NWListener`) gets created.
public final class TelnetServerHolder {
  public static let shared = TelnetServerHolder()

  private let lock = NSLock()
  private var serversByPort: [Int: TelnetServer] = [:]

  private init() {}

  /// `ServerHolder.getServer(int, int)`.
  public func server(port: Int, bufferSize: Int) throws -> TelnetServer {
    lock.lock()
    defer { lock.unlock() }
    if let existing = serversByPort[port], !existing.isDead() {
      existing.deleteAll()
      existing.setBufferSize(bufferSize)
      return existing
    }
    let created = try TelnetServer(port: port, bufferSize: bufferSize)
    serversByPort[port] = created
    return created
  }
}
