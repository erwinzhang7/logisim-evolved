// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Dispatch
import Testing
@testable import LogisimKernel

private final class PausedWireComponent: WireComponent {
  let wireRole = WireComponentRole.plain
  let wireLocation = Location.create(20, 20, hasToSnap: false)
  let entered = DispatchSemaphore(value: 0)
  let resume = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var first = true
  var wireEnds: [WireEndInfo] {
    lock.lock()
    let pause = first
    first = false
    lock.unlock()
    if pause {
      entered.signal()
      resume.wait()
    }
    return [WireEndInfo(location: wireLocation, width: .one, type: .outputOnly)]
  }
}

struct CircuitWiresConcurrencyTests {
  @Test func connectivityWaitsForCompleteMutation() {
    let wires = CircuitWires()
    let component = PausedWireComponent()
    let writerDone = DispatchSemaphore(value: 0)
    let readerStarted = DispatchSemaphore(value: 0)
    let readerDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      wires.add(component)
      writerDone.signal()
    }
    component.entered.wait()
    DispatchQueue.global().async {
      readerStarted.signal()
      _ = wires.getConnectivity()
      readerDone.signal()
    }
    readerStarted.wait()
    let early = readerDone.wait(timeout: .now() + 0.2)
    component.resume.signal()
    writerDone.wait()
    if early == .timedOut { readerDone.wait() }
    #expect(early == .timedOut, "connectivity read a component before add completed its point index")
    #expect(wires.getWidth(component.wireLocation) == .one)
  }
}

private final class ConcurrentWire: WireSegmentComponent {
  let wireRole = WireComponentRole.wire
  let wireEnd0 = Location.create(10, 10, hasToSnap: false)
  let wireEnd1 = Location.create(30, 10, hasToSnap: false)
  var wireLocation: Location { wireEnd0 }
  var wireEnds: [WireEndInfo] { [] }
}

extension CircuitWiresConcurrencyTests {
  @Test func concurrentTopologyReadersAndWriter() {
    let wires = CircuitWires()
    let wire = ConcurrentWire()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      for _ in 0..<2000 {
        wires.add(wire)
        wires.remove(wire)
      }
      group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
      for _ in 0..<2000 {
        _ = wires.getComponents()
        _ = wires.getWires()
        _ = wires.getWireBounds()
        _ = wires.pointStore.getComponents(wire.wireEnd0)
        _ = wires.getWidth(wire.wireEnd0)
        _ = wires.getWireSet(wire)
      }
      group.leave()
    }
    group.wait()
    #expect(wires.getWires().isEmpty)
    #expect(wires.pointStore.getAllLocations().isEmpty)
  }
}
