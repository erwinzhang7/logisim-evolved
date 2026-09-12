// TelnetNetworkTransport.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.io.TelnetServer's `ServerSocket`,
// `ServerThread` and `ClientThread`, itself "based on code from Digital, Copyright (c) 2021
// Helmut Neemann"), https://github.com/logisim-evolution/logisim-evolution. Copyright by the
// Logisim-evolution developers. This translation is a derivative work and is therefore
// GPL-3.0-only. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ═════════════════════════════════════════════════════════════════════════════════════════════
// THE LISTENING SOCKET A TELNET COMPONENT NEVER OPENED.
//
// `TelnetServer.transportFactory` was declared, read in `TelnetServer.init`, and assigned in
// `Tests/LogisimStdTests/TelnetTransportSeamTests.swift` and NOWHERE ELSE. So the seam's tests
// were green, `FakeTransport` drove every byte path, while the shipped application took the
// documented headless branch on every propagation:
//
// ```swift
// guard let factory = TelnetServer.transportFactory else {
//   // Headless: the model runs, nothing listens.
//   self.transport = nil
//   return
// }
// ```
//
// A `Telnet` component placed in the app therefore held a ring buffer nothing could ever fill,
// answered `AVAIL = 0` forever, and wrote its `IN` port into a socket that did not exist. This
// file is the production conformer, and it lives up here rather than in `LogisimStd` for exactly
// the reason that file's header gives: `logisim-cli` converts a `.circ` headlessly and must not
// link a networking stack to do it. `PlatformFreedomTests` enforces that from CI.
//
// ── THREADING: GCD, NOT SWIFT CONCURRENCY, AND WHY THAT IS THE ONLY OPTION ───────────────────
//
// D1 keeps the simulation kernel off Swift Concurrency: `propagate()` is synchronous, and the
// call chain here is `Telnet.propagate` → `Telnet.data(for:)` → `TelnetServerHolder.server` →
// `TelnetServer.init` → this factory, all on the propagation thread. An `async` transport would
// have to be awaited from inside `propagate`, which would infect all 108 `propagate`
// implementations; the exact outcome D1 exists to prevent.
//
// So the whole file is `DispatchQueue` + `NSLock`, the same discipline `BuzzerAudioEngineSink`
// uses on the other side of the D1 line:
//
//   * One serial `DispatchQueue` per listener, and each accepted `NWConnection` runs on that
//     same queue. Network.framework delivers every state change and every `receive` completion
//     on it, so the accept path and the read path are mutually serialised without a lock of
//     their own.
//   * `onBytes` therefore fires on that queue: a thread the simulation kernel knows nothing
//     about, which is precisely what `TelnetTransportConnection`'s "from any thread" contract
//     permits. The bytes land in `TelnetServer.dataReceived`, which takes the server's `NSLock`
//     before touching the ring buffer, and in `TelnetClientConnection.process`, which takes its
//     own lock around the `IAC` state machine. Both already exist; nothing here needs a lock to
//     protect *them*.
//   * `send(_:)` is called from the propagation thread (`TelnetServer.send` ← `Telnet.propagate`).
//     `NWConnection.send` is thread-safe and enqueues, so the simulation thread never blocks on
//     I/O and never touches this file's mutable state except through `lock`.
//   * Every stored property of both classes is guarded by `lock`; both types are
//     `@unchecked Sendable`, which is what lets a Swift-6 module hand them to a Swift-5 one.
//
// The one place this file DOES block is `init`, deliberately; see below.
//
// ── WHY `init` WAITS FOR THE BIND ────────────────────────────────────────────────────────────
//
// Upstream is `new ServerSocket(port)`: it binds synchronously and throws `IOException` if the
// port is taken, and `Telnet.getData` lets that reach `Simulator` as a circuit error. D13 records
// that shape, and `TelnetServer.transportFactory` is declared `throws` to preserve it.
//
// `NWListener` is asynchronous: it starts in `.setup` and reports success or `EADDRINUSE` later,
// on its queue. Returning a listener that has not bound yet would turn upstream's immediate,
// visible "port already in use" into a component that silently never listens; the same class of
// defect this whole board item is about. So `init` waits on a `DispatchSemaphore` for the first
// terminal state and throws if it is not `.ready`.
//
// The wait is bounded (`bindTimeout`) so a pathological listener cannot wedge the propagation
// thread; a loopback bind resolves in well under a millisecond, and the wait happens once per
// port for the life of the process because `TelnetServerHolder` caches the server.
//
// `.waiting` is treated as failure, not as "not yet". For a TCP listener that state means the
// bind itself could not be satisfied (`EADDRINUSE`, `EACCES`) and Network.framework intends to
// retry; upstream has no such notion and would have thrown. Reporting it as a circuit error is
// the faithful answer.
// ═════════════════════════════════════════════════════════════════════════════════════════════

import Foundation
import LogisimStd
import Network

/// `TelnetServer`'s `ServerSocket` + `ServerThread`, as Network.framework.
public final class TelnetNetworkTransport: TelnetTransport, @unchecked Sendable {

  public enum TransportError: Error, CustomStringConvertible {
    case invalidPort(Int)
    case bindFailed(port: Int, underlying: NWError)
    case bindTimedOut(port: Int, seconds: Double)

    public var description: String {
      switch self {
      case .invalidPort(let port):
        return "invalid TCP port \(port)"
      case .bindFailed(let port, let underlying):
        return "could not listen on port \(port): \(underlying)"
      case .bindTimedOut(let port, let seconds):
        return "listener on port \(port) did not become ready within \(seconds)s"
      }
    }
  }

  /// How long `init` will wait for `NWListener` to reach a terminal state. A loopback bind is
  /// immediate; this exists so a wedged listener cannot hold the propagation thread forever.
  public static let bindTimeout: Double = 5

  private let listener: NWListener
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var onConnect: ((any TelnetTransportConnection) -> Void)?
  /// Clients accepted between `init` returning and `start(onConnect:)` being called. In practice
  /// always empty, `TelnetServer.init` calls `start` on the very next line, but a listener is
  /// live the moment it is ready, and dropping a connection that arrived in that window would be
  /// a race that only ever showed up under load.
  private var pending: [TelnetNetworkConnection] = []
  private var failed = false
  private var cancelled = false

  /// `new ServerSocket(port)`. Returns only once the port is genuinely bound.
  public init(port: Int) throws {
    guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0),
      endpointPort.rawValue != 0
    else {
      throw TransportError.invalidPort(port)
    }
    self.queue = DispatchQueue(label: "logisim.telnet.\(port)")

    let parameters = NWParameters.tcp
    // Upstream's `ServerSocket` binds the wildcard address, so a telnet client on another machine
    // on the LAN can reach a running simulation. Preserved rather than narrowed to loopback:
    // narrowing it would be a behaviour change hidden in a port, and objectives.md's #747 (the
    // five-year-old firewall warning) is upstream's own acknowledgement that this socket is
    // externally visible.
    parameters.allowLocalEndpointReuse = false
    self.listener = try NWListener(using: parameters, on: endpointPort)

    // Set BEFORE `start`: `NWListener` requires a new-connection handler at start time, and a
    // client can arrive on the very next scheduling slot after `.ready`.
    let semaphore = DispatchSemaphore(value: 0)
    // `signalled` keeps the semaphore to exactly one signal: a listener passes through several
    // states and `.failed` can follow `.ready` later in the run, when nobody is waiting.
    let signalled = OneShot()
    listener.newConnectionHandler = { [weak self] connection in
      self?.accepted(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if signalled.fire() { semaphore.signal() }
      case .failed(let error), .waiting(let error):
        self?.markFailed()
        if signalled.fire(with: error) { semaphore.signal() }
      case .cancelled:
        self?.markCancelled()
        if signalled.fire() { semaphore.signal() }
      case .setup:
        break
      @unknown default:
        break
      }
    }
    listener.start(queue: queue)

    if semaphore.wait(timeout: .now() + Self.bindTimeout) == .timedOut {
      listener.cancel()
      throw TransportError.bindTimedOut(port: port, seconds: Self.bindTimeout)
    }
    if let error = signalled.error {
      listener.cancel()
      throw TransportError.bindFailed(port: port, underlying: error)
    }
  }

  deinit {
    listener.cancel()
  }

  /// `ServerThread.run()`'s `while (true) { accept(); }`, inverted: Network.framework pushes.
  public func start(onConnect: @escaping (any TelnetTransportConnection) -> Void) {
    lock.lock()
    self.onConnect = onConnect
    let backlog = pending
    pending.removeAll()
    lock.unlock()
    for connection in backlog { onConnect(connection) }
  }

  /// `TelnetServer.isDead()`; `!serverThread.isAlive()`.
  ///
  /// True only once the listener has actually stopped. A listener that is bound with no client
  /// attached is idle, not dead; answering `true` there would make `TelnetServerHolder.server`
  /// rebuild the server (and rebind the port) on every single propagation, discarding the ring
  /// buffer each time.
  public var isDead: Bool {
    lock.lock()
    defer { lock.unlock() }
    return failed || cancelled
  }

  /// Stop listening. Not part of `TelnetTransport`; `TelnetServer` has no teardown path of its
  /// own (see the note in that file about `close()` never being called), so this exists for the
  /// owner of the process and for tests that must not leak a bound port.
  public func stop() {
    listener.cancel()
  }

  private func accepted(_ connection: NWConnection) {
    let wrapped = TelnetNetworkConnection(connection: connection, queue: queue)
    lock.lock()
    let handler = onConnect
    if handler == nil { pending.append(wrapped) }
    lock.unlock()
    handler?(wrapped)
  }

  private func markFailed() {
    lock.lock()
    failed = true
    lock.unlock()
  }

  private func markCancelled() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

/// `TelnetServer.ClientThread`'s socket half; the read loop and the writes, with the telnet
/// `IAC` filtering left where it belongs, on the `LogisimStd` side of the seam.
final class TelnetNetworkConnection: TelnetTransportConnection, @unchecked Sendable {

  /// `ClientThread.run()` reads into a 1-byte-at-a-time blocking `InputStream`; there is no
  /// upstream constant to match here, so this is simply a sane chunk. The receiving side is a
  /// byte-at-a-time state machine either way.
  private static let maximumReceive = 4096

  private let connection: NWConnection
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var onBytes: (([UInt8]) -> Void)?
  private var closed = false

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  /// Begin delivering. Called exactly once, by `TelnetClientConnection.start()`.
  ///
  /// The `NWConnection` is deliberately NOT started until here. `newConnectionHandler` hands over
  /// an unstarted connection, so nothing can be received before the handler is in place, which
  /// is the ordering `TelnetClientConnection.start()`'s own comment says it needs and gets "by
  /// accident" in Java (the kernel socket buffer is already live there). Here it is arranged.
  func start(onBytes: @escaping ([UInt8]) -> Void) {
    lock.lock()
    self.onBytes = onBytes
    lock.unlock()

    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.close()
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveNext()
  }

  /// `ClientThread.send(int)`, batched.
  ///
  /// Cannot fail and must not trap: upstream is
  /// `catch (IOException e) { e.printStackTrace(); // not really a problem }`, i.e. a write to a
  /// client that has gone away is an ordinary outcome. The completion handler discards its error
  /// for that reason, and it is a handler rather than `.idempotent` so the send is actually
  /// flushed rather than coalesced away.
  func send(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }
    lock.lock()
    let isClosed = closed
    lock.unlock()
    guard !isClosed else { return }
    connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
  }

  func close() {
    lock.lock()
    let alreadyClosed = closed
    closed = true
    onBytes = nil
    lock.unlock()
    guard !alreadyClosed else { return }
    connection.cancel()
  }

  /// The read loop. Re-arms itself; `receive` delivers at most once per call.
  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumReceive) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.lock.lock()
        let handler = self.onBytes
        self.lock.unlock()
        handler?([UInt8](data))
      }
      // `isComplete` is the peer's FIN: upstream's `read() == -1`, which ends `ClientThread.run`
      // and lets the accept loop take the next client.
      if isComplete || error != nil {
        self.close()
        return
      }
      self.receiveNext()
    }
  }
}

/// One-shot latch for the bind handshake: records the first terminal listener state and reports
/// whether this caller is the one that must signal the semaphore.
///
/// A tiny lock rather than an atomic because the rest of this file is already `NSLock`-shaped and
/// D1 rules out the Swift Concurrency primitives that would otherwise fit.
private final class OneShot: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var storedError: NWError?

  /// Returns `true` for the first caller only.
  @discardableResult
  func fire(with error: NWError? = nil) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !fired else { return false }
    fired = true
    storedError = error
    return true
  }

  var error: NWError? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }
}
