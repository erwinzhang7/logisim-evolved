// SocUpSimulationState.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.soc.data.{SocUpSimulationState,
// SocUpSimulationStateListener}), https://github.com/logisim-evolution/logisim-evolution.
// Copyright by the Logisim-evolution developers. This translation is a derivative work and is
// therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// A tiny four-state machine (running / halted-by-error / halted-by-breakpoint / halted-by-stop)
// shared by both CPU cores' debug windows, plus the one piece of non-trivial logic it carries:
// `breakPointReached()`'s "step past the breakpoint we are already sitting on" latch. Kept here
// (not Rv32im/Nios2-specific) because both cores use the same state machine verbatim.
//
// Not ported: `paint`/`paintState`/`getButtonLocation`/`getStateLocation`/`getLabelLocation`:
// the run/stop button and status-light widget, all `Graphics`/`Bounds` layout (D6/D9). The UI
// renders the button/light from `simulationState`/`stateDescription` directly.
// `getStateString()`'s localised text is likewise UI (D5's precedent); `stateDescription` below
// is a stable, non-localised debug label only.

import Foundation

public enum SocSimulationRunState: Sendable {
  case running
  case haltedByError
  case haltedByBreakpoint
  case haltedByStop

  /// Non-localised debug text; the UI owns the localised table (see file header).
  public var description: String {
    switch self {
    case .running: return "running"
    case .haltedByError: return "halted (error)"
    case .haltedByBreakpoint: return "halted (breakpoint)"
    case .haltedByStop: return "halted"
    }
  }
}

/// `com.cburch.logisim.soc.data.SocUpSimulationStateListener`.
public protocol SocUpSimulationStateListener: AnyObject {
  func simulationStateChanged()
}

/// `com.cburch.logisim.soc.data.SocUpSimulationState`.
public final class SocUpSimulationState {
  public private(set) var simulationState: SocSimulationRunState = .running
  private var canContinueAfterBreak = false
  private var listeners: [SocUpSimulationStateListener] = []

  public init() {}

  /// `registerListener(SocUpSimulationStateListener)`.
  public func registerListener(_ listener: SocUpSimulationStateListener) {
    listeners.append(listener)
  }

  /// `reset()`.
  public func reset() {
    canContinueAfterBreak = false
    simulationState = .haltedByStop
    fireChange()
  }

  /// `canExecute()`.
  public var canExecute: Bool { simulationState == .running }

  /// `errorInExecution()`.
  public func errorInExecution() {
    simulationState = .haltedByError
    fireChange()
  }

  /// `breakPointReached()`.
  ///
  /// Java's latch: the *first* call after a breakpoint fires halts and returns `true`; if the
  /// user then resumes ("continue"), `buttonPressed()` sets `canContinueAfterBreak`, and the
  /// *next* call to this method (still sitting on the same breakpoint address, before the PC has
  /// moved past it) consumes that flag and returns `false` instead of halting again. Preserved
  /// exactly, including that nothing here inspects the PC; the one-shot flag is the whole
  /// mechanism, so a core that calls this twice at the same address without an intervening
  /// `buttonPressed()` halts every time.
  @discardableResult
  public func breakPointReached() -> Bool {
    if canContinueAfterBreak {
      canContinueAfterBreak = false
      return false
    }
    simulationState = .haltedByBreakpoint
    fireChange()
    return true
  }

  /// `buttonPressed()`.
  public func buttonPressed() {
    if simulationState == .running {
      simulationState = .haltedByStop
    } else {
      if simulationState == .haltedByBreakpoint {
        canContinueAfterBreak = true
      }
      simulationState = .running
    }
    fireChange()
  }

  private func fireChange() {
    for listener in listeners {
      listener.simulationStateChanged()
    }
  }
}

extension SocSimulationRunState: Equatable {}
