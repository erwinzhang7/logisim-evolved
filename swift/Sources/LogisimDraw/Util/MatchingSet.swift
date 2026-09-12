// MatchingSet.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// com/cburch/draw/util/MatchingSet.java. Copyright by the Logisim-evolution developers. This
// translation is a derivative work and is therefore licensed GPL-3.0-only. See LICENSE.md.
//
// A `Set<CanvasObject>` keyed by `matches`/`matchesHashCode` (structural equality) instead of
// identity; used to diff two shape lists (e.g. an appearance before/after an edit) treating
// two distinct-but-equivalent shapes as "the same". `CanvasObject` cannot itself be `Hashable`
// this way without redefining `==`/`hashValue` to mean "structurally matches", which would be
// exactly the D4-style trap this codebase avoids elsewhere (identity is the correct default
// equality for a reference type); this wraps each element instead.

/// `com.cburch.draw.util.MatchingSet<E extends CanvasObject>`.
public struct MatchingSet<Element: CanvasObject> {
  private struct Member: Hashable {
    let value: Element
    static func == (lhs: Member, rhs: Member) -> Bool { lhs.value.matches(rhs.value) }
    func hash(into hasher: inout Hasher) { hasher.combine(value.matchesHashCode()) }
  }

  private var members: Set<Member> = []

  public init() {}

  public init(_ initialContents: [Element]) {
    members = Set(initialContents.map(Member.init))
  }

  @discardableResult
  public mutating func insert(_ value: Element) -> Bool {
    members.insert(Member(value: value)).inserted
  }

  public func contains(_ value: Element) -> Bool {
    members.contains(Member(value: value))
  }

  @discardableResult
  public mutating func remove(_ value: Element) -> Bool {
    members.remove(Member(value: value)) != nil
  }

  public var count: Int { members.count }
  public var isEmpty: Bool { members.isEmpty }
}

extension MatchingSet: Sequence {
  public func makeIterator() -> AnyIterator<Element> {
    var iterator = members.makeIterator()
    return AnyIterator { iterator.next()?.value }
  }
}
