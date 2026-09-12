// JavaPriorityQueue.swift: part of logisim-evolved.
//
// A faithful reimplementation of `java.util.PriorityQueue`'s heap layout, for the one place in
// this port where the queue's behaviour on *equal* elements is observable in the output.
// GPL-3.0-only, as the rest of this port is. See LICENSE.md.
//
// ── Why this exists ─────────────────────────────────────────────────────────────────────────
//
// `Connector.findShortestPath` runs A* out of a `PriorityQueue<SearchNode>`. Two search nodes
// compare equal only when their heuristics *and* their hash codes match, which is rare, but
// "rare" is not "never", and more importantly the heap's internal layout decides which of several
// equally-ranked nodes is expanded first, and that decision propagates into which wires the move
// engine emits. Wires are the file. So the queue is not an interchangeable container here: swapping
// in a different (equally correct) heap silently changes the geometry a drag produces.
//
// A binary heap is not canonical: siftUp and siftDown admit many valid arrangements, and Swift
// has no standard heap to accidentally agree with anyway. What follows is OpenJDK's exact
// arithmetic: `(k - 1) >>> 1` for the parent, `(k << 1) + 1` for the left child, `size >>> 1` as
// the sift-down bound, the "prefer the right child when it compares strictly smaller" rule, and
// `heapify` walking `(size >>> 1) - 1` down to `0`.
//
// This is deliberately *not* generalised into a reusable collection. It is a compatibility
// shim with one client, and presenting it as a general-purpose heap would invite its use where
// ordinary Swift ordering is wanted and Java compatibility is not.

import Foundation

/// `java.util.PriorityQueue`, restricted to the operations `Connector` uses: build from a
/// collection, `add`, `remove`/`poll`, `isEmpty`.
///
/// `comparator` returns Java's three-way `int`, not a `Bool`, because the client's comparator
/// (`SearchNode.javaCompare`) is defined in terms of a wrapped subtraction and the sign is what
/// the heap reads.
struct JavaPriorityQueue<Element> {
  private var storage: [Element] = []
  private let comparator: (Element, Element) -> Int

  /// `new PriorityQueue<>(Collection)` for a plain collection: copy, then `heapify()`.
  init(_ elements: [Element], comparator: @escaping (Element, Element) -> Int) {
    self.comparator = comparator
    self.storage = elements
    heapify()
  }

  var isEmpty: Bool { storage.isEmpty }
  var count: Int { storage.count }

  /// `heapify()`, `for (int i = (size >>> 1) - 1; i >= 0; i--) siftDown(i, queue[i]);`
  private mutating func heapify() {
    guard storage.count > 1 else { return }
    var index = (storage.count >> 1) - 1
    while index >= 0 {
      siftDown(index, storage[index])
      index -= 1
    }
  }

  /// `offer(E)`: append, then sift up from the new last slot.
  mutating func add(_ element: Element) {
    storage.append(element)
    siftUp(storage.count - 1, element)
  }

  /// `poll()`: take the root, move the last element to the root, sift it down.
  mutating func removeFirst() -> Element? {
    guard let result = storage.first else { return nil }
    let last = storage.removeLast()
    if !storage.isEmpty {
      siftDown(0, last)
    }
    return result
  }

  /// `siftUpUsingComparator(int, E)`.
  private mutating func siftUp(_ start: Int, _ element: Element) {
    var k = start
    while k > 0 {
      let parent = (k - 1) >> 1
      let existing = storage[parent]
      if comparator(element, existing) >= 0 { break }
      storage[k] = existing
      k = parent
    }
    storage[k] = element
  }

  /// `siftDownUsingComparator(int, E)`.
  ///
  /// The `half` bound and the right-child preference are OpenJDK's: the right child is chosen
  /// only when the left compares **strictly greater** than it, so a tie between siblings keeps
  /// the left one, which is one of the arrangements a different heap would get wrong.
  private mutating func siftDown(_ start: Int, _ element: Element) {
    var k = start
    let size = storage.count
    let half = size >> 1
    while k < half {
      var child = (k << 1) + 1
      var candidate = storage[child]
      let right = child + 1
      if right < size && comparator(candidate, storage[right]) > 0 {
        child = right
        candidate = storage[child]
      }
      if comparator(element, candidate) <= 0 { break }
      storage[k] = candidate
      k = child
    }
    storage[k] = element
  }
}
