// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Dispatch
import LogisimFile
import LogisimKernel
import Testing
@testable import LogisimStd

struct LiveWireMapConcurrencyTests {
  @Test func wireMapReplacementCanOverlapReaders() throws {
    let circuit = try Circuit(name: "clear-race")
    let wrapper = SimulatedCircuit(circuit)
    let point = Location.create(20, 20, hasToSnap: false)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      for _ in 0..<2000 {
        circuit.mutatorClear()
        wrapper.applyPendingEdits()
      }
      group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
      for _ in 0..<2000 { _ = wrapper.width(at: point) }
      group.leave()
    }
    group.wait()
    #expect(wrapper.wireStore.getComponents().isEmpty)
  }
}
