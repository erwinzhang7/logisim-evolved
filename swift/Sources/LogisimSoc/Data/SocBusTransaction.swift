// SocBusTransaction.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.SocBusTransaction),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// This is the single object every CPU core, the bus fabric, and every peripheral communicate
// through, so getting its shape and error propagation exactly right is the load-bearing
// contract for the whole subsystem (see the task brief: "a silently-succeeding failed read
// produces a plausible wrong program run").
//
// ── Reference type, on purpose ───────────────────────────────────────────────────────────────
//
// Java's `SocBusTransaction` is mutated in place by whoever handles it: the bus fabric sets the
// error/responder, a slave sets the read data or an error, a CPU core reads the result back out
// of the *same* object it constructed. Making this a Swift `struct` would silently change that
// into copy semantics; the caller's transaction would never see what the bus did to it. `final
// class` preserves upstream's aliasing exactly, matching D4's reasoning for `Component`.
//
// ── What did not come across ─────────────────────────────────────────────────────────────────
//
//   * `paint(...)`, `paintTraceInfo`, `getRealBlockWidth`, `BoxInfo`: the bus-trace-window
//     drawing code (`Graphics2D`, `AppPreferences.getScaled`). D6/D9: this is a MODEL, the UI
//     layer renders traces from `errorCode`/`address`/`readData`/`writeData`/etc. directly.
//   * `getErrorMessage`/`getShortErrorMessage`; localised via `Strings.S.get(...)`. D5/D9: the
//     kernel does not carry display strings. `SocTransactionError.description` below is a
//     stable, non-localised debug string only; the UI owns the localised table.
//   * `BLOCK_SKIP`/`BLOCK_MARKER`/`BLOCK_HEX` layout constants: trace-drawing geometry, UI only.

import Foundation
import LogisimFile
import LogisimKernel

/// `SocBusTransaction.READ_TRANSACTION` / `WRITE_TRANSACTION` / `ATOMIC_TRANSACTION`.
///
/// Java models this as an `int` bit-OR so a transaction can be simultaneously read+write
/// (an atomic read-modify-write). An `OptionSet` reproduces that exactly while giving the
/// three `isXTransaction()` queries a compiler-checked home.
public struct SocTransactionKind: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let read = SocTransactionKind(rawValue: 1)
  public static let write = SocTransactionKind(rawValue: 2)
  public static let atomic = SocTransactionKind(rawValue: 4)
}

/// `SocBusTransaction.BYTE_ACCESS` / `HALF_WORD_ACCESS` / `WORD_ACCESS`.
public enum SocAccessType: Int, Sendable {
  case byte = 1
  case halfWord = 2
  case word = 3
}

/// `SocBusTransaction`'s error codes (`NO_ERROR` … `REGISTER_DOES_NOT_EXIST_ERROR`).
///
/// A closed enum rather than raw `Int` constants so a slave cannot set a code the fabric does
/// not know how to report, and so `hasError` is `self != .none` rather than a separate flag that
/// could disagree with the code (upstream keeps them as one `int`, so there is no such
/// desynchronisation risk there either; this just makes it a type-system guarantee here too).
public enum SocTransactionError: Sendable, CustomStringConvertible {
  case none
  case noResponse
  case noSlaves
  case multipleSlaves
  case nonAtomicReadWrite
  case noSocBusConnected
  case misalignedAddress
  case accessTypeNotSupported
  case readOnlyAccess
  case writeOnlyAccess
  case registerDoesNotExist

  /// Non-localised debug text; the UI owns the localised table (see file header).
  public var description: String {
    switch self {
    case .none: return "transaction successful"
    case .noResponse: return "no response from any slave"
    case .noSlaves: return "no slaves attached to the bus"
    case .multipleSlaves: return "multiple slaves answered the same address"
    case .nonAtomicReadWrite: return "non-atomic read+write transaction"
    case .noSocBusConnected: return "no SoC bus connected"
    case .misalignedAddress: return "misaligned address"
    case .accessTypeNotSupported: return "access type not supported"
    case .readOnlyAccess: return "attempted write to a read-only register"
    case .writeOnlyAccess: return "attempted read from a write-only register"
    case .registerDoesNotExist: return "register does not exist"
    }
  }
}

/// `SocBusTransaction`'s `Object master` field, narrowed to the two kinds upstream actually
/// stores: a plain debug tag (`"elf"`, `"vgadma"`) or the initiating component.
public enum SocTransactionInitiator {
  case named(String)
  case component(any Component)
}

/// `com.cburch.logisim.soc.data.SocBusTransaction`.
public final class SocBusTransaction {

  public let kind: SocTransactionKind
  public let address: Int32
  public let writeData: Int32
  public private(set) var readData: Int32 = 0
  public let accessType: SocAccessType
  public let initiator: SocTransactionInitiator
  public private(set) var responder: (any Component)?
  public private(set) var error: SocTransactionError = .none
  public private(set) var isHidden: Bool = false

  public init(
    kind: SocTransactionKind, address: Int32, writeData: Int32, accessType: SocAccessType,
    initiator: SocTransactionInitiator
  ) {
    self.kind = kind
    self.address = address
    self.writeData = writeData
    self.accessType = accessType
    self.initiator = initiator
  }

  /// Convenience matching the Java call sites that pass a plain string master
  /// (`new SocBusTransaction(type, addr, value, access, "elf")`).
  public convenience init(
    kind: SocTransactionKind, address: Int32, writeData: Int32, accessType: SocAccessType,
    initiator: String
  ) {
    self.init(
      kind: kind, address: address, writeData: writeData, accessType: accessType,
      initiator: .named(initiator))
  }

  /// `setAsHiddenTransaction()`.
  public func setAsHidden() { isHidden = true }

  /// `getAccessType()`.
  public var isReadTransaction: Bool { kind.contains(.read) }
  public var isWriteTransaction: Bool { kind.contains(.write) }
  public var isAtomicTransaction: Bool { kind.contains(.atomic) }

  /// `setError(int)`.
  public func setError(_ value: SocTransactionError) { error = value }

  /// `hasError()`.
  public var hasError: Bool { error != .none }

  /// `setReadData(int)`.
  public func setReadData(_ value: Int32) { readData = value }

  /// `setTransactionResponder(Component)`.
  public func setTransactionResponder(_ component: (any Component)?) { responder = component }
}

extension SocTransactionError: Equatable {}
