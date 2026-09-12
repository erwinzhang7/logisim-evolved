// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Dispatch
import Testing
@testable import LogisimFile

struct WeakListenerConcurrencyTests {
  @Test func concurrentListenerRegistrationAndSnapshots() {
    let listeners = WeakListenerList<NSObject>()
    let permanent = NSObject()
    listeners.add(permanent)
    let group = DispatchGroup()
    for _ in 0..<2 {
      group.enter()
      DispatchQueue.global().async {
        let transient = NSObject()
        for _ in 0..<1000 {
          listeners.add(transient)
          _ = listeners.current()
          listeners.remove(transient)
        }
        group.leave()
      }
    }
    group.wait()
    let snapshot = listeners.current()
    #expect(snapshot.count == 1)
    #expect(snapshot.first === permanent)
    // Delivery uses a snapshot, so callbacks may unsubscribe without reentering a held lock.
    for listener in snapshot { listeners.remove(listener) }
    #expect(listeners.isEmpty)
  }
}
