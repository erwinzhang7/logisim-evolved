//
//  PropagationHeap.swift: part of logisim-evolved.
//
//  Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution).
//  logisim-evolution is free software released under the GNU GPLv3; this translation is
//  therefore GPL-3.0-only. See LICENSE.md.
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Port target is **4.1.0** (D16).
//
//  ---------------------------------------------------------------------------------------
//  Swift has no priority queue, so this is a hand-rolled binary heap. It is NOT a "clean-room"
//  heap: **event order is simulation output**, and the M3 gate compares
//  `logisim-cli --tty table` byte for byte against the Java, so the heap must reproduce
//  `java.util.PriorityQueue`'s array layout and sift algorithms move for move.
//
//  Which Java queue is being reproduced
//  ------------------------------------
//  4.1.0 lets the user pick one of five queue implementations from the Experimental
//  preferences panel (`Propagator.java:139-147`):
//
//      SIM_QUEUE_LIST_OF_QUEUES / SIM_QUEUE_TREE_OF_QUEUES  -> QueueOfQueues
//      SIM_QUEUE_LINKED                                     -> LinkedQueue
//      SIM_QUEUE_SPLAY                                      -> SplayQueue
//      default (incl. SIM_QUEUE_DEFAULT and SIM_QUEUE_PRIORITY) -> PriorityEventQueue
//
//  `AppPreferences.SIMULATION_QUEUE`'s default is `SIM_QUEUE_DEFAULT`
//  (`prefs/AppPreferences.java:825-830`), which lands on the `default` arm; i.e.
//  `PriorityEventQueue extends java.util.PriorityQueue`. That is the queue the oracle jar runs
//  and therefore the queue this port implements. The other four are a preferences-only
//  performance experiment; they are not ported, and `Propagator` has no switch for them.
//
//  Why the comparator forces an exact algorithmic copy
//  ---------------------------------------------------
//  `QNode.compareTo` subtracts `int`s and lets them **wrap** (its own comment says the overflow
//  is intentional). A wrapping difference is not a transitive order over the full `Int32` range:
//  with keys 0, 2^30 and 2^31-1, `compare` reports 0 < 2^30 and 2^30 < 2^31-1 but *also*
//  2^31-1 < 0. Any implementation that assumes a total order: a sorted array, `Array.sort`,
//  a "cleaner" heap with different sift rules; may legitimately produce a different pop order
//  from Java's for the same inserts. Copying `siftUp`/`siftDown` exactly removes that whole
//  class of divergence.
//
//  Ties: what `PriorityQueue` actually yields
//  ------------------------------------------
//  `java.util.PriorityQueue` is explicitly **not stable**, so a tie would be resolved by
//  whatever the sift path happens to do. Investigated rather than assumed, the conclusion is:
//
//    * `compare` returns 0 only when `timeKey` **and** `serialNumber` are congruent mod 2^32.
//    * Every event that reaches this queue is minted by `setValueWithPropThread`
//      (`Propagator.java:283-284`), which stamps it with `eventSerialNumber` and then
//      increments: a per-propagator counter, so serial numbers are pairwise distinct until it
//      wraps after 2^32 events on one propagator.
//    * The only other constructor path, `setValue` from a non-propagation thread
//      (`Propagator.java:261`), mints its events with serial number **0**, but those objects
//      are never enqueued: `moveNonPropThreadEvents` re-submits them through
//      `setValueWithPropThread`, which builds a fresh event with a real serial number
//      (`Propagator.java:243`).
//
//  So ties are unreachable short of a 2^32-event wrap, and the pop order is fully determined by
//  the comparator. The exact-copy sift code below therefore matches Java for reasons that do not
//  depend on that argument holding, but the argument is why the M3 gate cannot be tripped by
//  tie-breaking, and it is recorded here so a future reader does not go looking for a stability
//  guarantee that neither implementation has.
//  ---------------------------------------------------------------------------------------
//

import Foundation

/// `com.cburch.logisim.util.QNodeQueue` (`util/QNodeQueue.java`), specialised to
/// `PropagationEvent`.
///
/// Kept as a protocol for the same reason Java keeps the interface: it is the seam the four
/// unported experimental queue implementations plug into, and it makes the heap swappable in a
/// differential test without touching `Propagator`.
public protocol PropagationEventQueue: AnyObject {
  /// `boolean add(T item)`; returns `true` if added, as Java's does unconditionally.
  @discardableResult
  func add(_ item: PropagationEvent) -> Bool

  /// `void clear()`.
  func clear()

  /// `boolean isEmpty()`.
  var isEmpty: Bool { get }

  /// `T peek()`: the smallest node, or `nil` if empty.
  func peek() -> PropagationEvent?

  /// `T remove()`; removes and returns the smallest node, or `nil` if empty.
  ///
  /// Java's `PriorityEventQueue` inherits `AbstractQueue.remove()`, which throws
  /// `NoSuchElementException` on an empty queue rather than returning `null` as the
  /// `QNodeQueue` doc comment claims. The discrepancy is unobservable: the one call site
  /// (`Propagator.java:319`) has already checked `peek() != null`. Returning an Optional keeps
  /// the documented contract and avoids inventing a throw for an unreachable state (D13 cuts
  /// the other way here; this is not reachable from a `.circ`).
  @discardableResult
  func remove() -> PropagationEvent?

  /// `int size()`.
  var count: Int { get }
}

/// A binary min-heap that reproduces `java.util.PriorityQueue`'s layout and sift algorithms
/// exactly, ordered by `PropagationEvent.compare`.
///
/// Not thread-safe, exactly like Java's. `Propagator` confines it to the propagation thread and
/// enforces that with the same `Thread.currentThread() != propagatorThread` checks the Java uses
/// (D1).
public final class PropagationHeap: PropagationEventQueue {

  /// `PriorityQueue.queue`, the array-embedded complete binary tree.
  ///
  /// Java keeps a separate `size` and a possibly larger `Object[]` with trailing `null`s; a
  /// Swift `Array` carries its own count, so `storage.count` **is** Java's `size` and
  /// `grow(...)` collapses into `append`. Capacity has no effect on ordering, so nothing
  /// observable is lost. Java's initial capacity of 11 is likewise unobservable, but is
  /// reserved anyway so the first eleven inserts allocate the same number of times.
  private var storage: [PropagationEvent] = []

  public init() {
    storage.reserveCapacity(11)
  }

  // MARK: - QNodeQueue

  public var isEmpty: Bool { storage.isEmpty }

  public var count: Int { storage.count }

  public func peek() -> PropagationEvent? {
    // `PriorityQueue.peek()`: `size == 0 ? null : (E) queue[0]`.
    storage.isEmpty ? nil : storage[0]
  }

  public func clear() {
    // `PriorityQueue.clear()` nulls every slot and sets `size = 0`. Capacity is kept, matching
    // Java, because `clear()` runs on every `Propagator.reset()` and the queue is immediately
    // refilled.
    storage.removeAll(keepingCapacity: true)
  }

  /// `PriorityQueue.offer(E)`:
  ///
  /// ```java
  /// int i = size;
  /// if (i >= queue.length) grow(i + 1);
  /// siftUp(i, e);
  /// size = i + 1;
  /// ```
  ///
  /// `siftUp` writes only into indices `<= i`, so appending first and sifting from the last
  /// index is the same sequence of writes.
  @discardableResult
  public func add(_ item: PropagationEvent) -> Bool {
    let i = storage.count
    storage.append(item)
    if i != 0 {
      siftUp(i, item)
    }
    return true
  }

  /// `PriorityQueue.poll()`:
  ///
  /// ```java
  /// final E result = (E) es[0];
  /// final int n = --size;
  /// final E x = (E) es[n];
  /// es[n] = null;
  /// if (n > 0) siftDownComparable(0, x, es, n);
  /// return result;
  /// ```
  ///
  /// Note the ordering: the last element is *removed* before the sift, and the sift's view of
  /// the array is the first `n` slots: with slot 0 still holding the stale minimum until the
  /// final write lands. Reproduced literally; getting this wrong changes the pop order only in
  /// the presence of ties, but it also changes nothing about the cost of being faithful.
  @discardableResult
  public func remove() -> PropagationEvent? {
    guard let result = storage.first else { return nil }
    let n = storage.count - 1
    let x = storage[n]
    storage.removeLast()
    if n > 0 {
      siftDown(0, x, n)
    }
    return result
  }

  // MARK: - Sift, copied from java.util.PriorityQueue

  /// `PriorityQueue.siftUpComparable(int k, E x)`:
  ///
  /// ```java
  /// while (k > 0) {
  ///     int parent = (k - 1) >>> 1;
  ///     Object e = queue[parent];
  ///     if (key.compareTo((E) e) >= 0) break;
  ///     queue[k] = e;
  ///     k = parent;
  /// }
  /// queue[k] = key;
  /// ```
  ///
  /// The `>= 0` break is what makes an equal element settle *at* its insertion depth rather than
  /// continuing past equal ancestors.
  private func siftUp(_ start: Int, _ key: PropagationEvent) {
    var k = start
    while k > 0 {
      let parent = (k - 1) >> 1  // `>>> 1` on a non-negative int is `>> 1`.
      let e = storage[parent]
      if PropagationEvent.compare(key, e) >= 0 { break }
      storage[k] = e
      k = parent
    }
    storage[k] = key
  }

  /// `PriorityQueue.siftDownComparable(int k, E x, Object[] es, int n)`:
  ///
  /// ```java
  /// int half = n >>> 1;           // loop while a non-leaf
  /// while (k < half) {
  ///     int child = (k << 1) + 1; // assume left child is least
  ///     Object c = es[child];
  ///     int right = child + 1;
  ///     if (right < n && ((Comparable<? super E>) c).compareTo((E) es[right]) > 0)
  ///         c = es[child = right];
  ///     if (key.compareTo((E) c) <= 0) break;
  ///     es[k] = c;
  ///     k = child;
  /// }
  /// es[k] = key;
  /// ```
  ///
  /// Two details that matter and are easy to "improve" away: the right child is taken only on a
  /// **strict** `> 0`, so a tie keeps the left child; and the loop breaks on `<= 0`, so a key
  /// equal to the smaller child stops immediately.
  private func siftDown(_ start: Int, _ key: PropagationEvent, _ n: Int) {
    var k = start
    let half = n >> 1
    while k < half {
      var child = (k << 1) + 1
      var c = storage[child]
      let right = child + 1
      if right < n && PropagationEvent.compare(c, storage[right]) > 0 {
        child = right
        c = storage[child]
      }
      if PropagationEvent.compare(key, c) <= 0 { break }
      storage[k] = c
      k = child
    }
    storage[k] = key
  }

  // MARK: - Test support

  /// The heap array in storage order; the same thing `PriorityQueue.toArray()` yields.
  ///
  /// Exists so a differential test can compare the *layout* against the Java, not just the pop
  /// sequence. Two heaps can agree on every pop and still disagree internally, and if they do,
  /// the next insert diverges; catching that at the layout level is much cheaper than catching
  /// it as a truth-table mismatch fifty thousand rows later.
  public var storageOrder: [PropagationEvent] { storage }
}
