// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LogisimFile
import LogisimKernel
import Testing
@testable import LogisimStd

struct WireTopologyBenchmarkTests {
  // Opt-in: uses a local corpus fixture, never copies coursework into the repository.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["LOGISIM_WIRE_BENCHMARK"] != nil))
  func benchmarkLiveMultiplierPropagation() throws {
    StdLibraries.registerAll()
    let path = try #require(ProcessInfo.processInfo.environment["LOGISIM_WIRE_BENCHMARK"])
    let file = try #require(try Loader().openLogisimFile(URL(fileURLWithPath: path)))
    let circuit = try #require(file.circuit(named: "main"))
    let session = SimulationSession(file: file)
    let state = session.createRootState(for: circuit)
    let columns = TruthTableRun.pinColumns(of: circuit)
    let inputs = columns.filter(\.isInput)
    let outputs = columns.filter { !$0.isInput }.sorted { $0.label < $1.label }
    #expect(inputs.count == 6 && outputs.count == 6)
    func drive(_ row: Int) throws -> Int {
      for pin in inputs {
        let bit = Int(String(pin.label.last!))!
        let operand = pin.label.first == "A" ? row & 7 : (row >> 3) & 7
        let component = try #require(pin.component as? any SimComponent)
        let instance = try #require(state.unvalidatedReusableInstanceState(for: component) as? InstanceStateImpl)
        Pin.driveInputPin(instance, (operand & (1 << bit)) == 0 ? .falseValue : .trueValue)
      }
      _ = try state.propagator.propagate()
      var product = 0
      for (bit, pin) in outputs.enumerated() {
        if state.getValue(pin.component.location) == .trueValue { product |= 1 << bit }
      }
      return product
    }
    for row in 0..<64 { #expect(try drive(row) == (row & 7) * (row >> 3)) }
    let count = 20_000
    for sample in 1...7 {
      let start = DispatchTime.now().uptimeNanoseconds
      var checksum = 0
      for row in 0..<count { checksum += try drive(row & 63) }
      let elapsed = DispatchTime.now().uptimeNanoseconds - start
      print("WIRE_BENCH sample=\(sample) propagations=\(count) ns=\(elapsed) checksum=\(checksum)")
    }
    print("WIRE_BENCH components=\(circuit.nonWires.count) wires=\(circuit.wires.count)")
  }
}
