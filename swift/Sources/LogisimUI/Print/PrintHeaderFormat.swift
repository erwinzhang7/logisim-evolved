// LogisimUI: part of logisim-evolved.
// Derived from logisim-evolution (com.cburch.logisim.gui.main.Print), GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// `Print.java:85-106`: the page-header template. `ParmsPanel` seeds the field with
// `"%n (%p of %P)"` and `MyPrintable.print` calls this once per page.
//
// Ported verbatim rather than "cleaned up", because the loop has three behaviours a rewrite
// gets wrong, and all three are reachable from a text field the user types into:
//
//   1. A `%` as the LAST character terminates the loop without consuming anything
//      (`mark + 1 < header.length()` fails), and the trailing remainder, including that `%`,
//      is appended by the `start < length` tail. So `"page %"` formats to `"page %"`.
//   2. An unrecognised escape is passed through with its `%` intact (`default -> ret.append("%")
//      .append(c)`), so `"%q"` formats to `"%q"` and not to the empty string.
//   3. `header.indexOf('%')` is consulted BEFORE the loop and the early `return header` for
//      `mark < 0` means a template with no `%` is returned by identity, never rebuilt.
//
// Not ported: the `JTextField` the template is typed into, and `S.get("labelHeader")`, D9/D11.

import Foundation

/// `Print.format(String, int, int, String)`.
enum PrintHeaderFormat {

  /// `ParmsPanel`'s seeded value: `header.setText("%n (%p of %P)")` (`Print.java:216`).
  static let defaultTemplate = "%n (%p of %P)"

  /// Substitutes `%n` (circuit name), `%p` (1-based page), `%P` (page count) and `%%`.
  ///
  /// `index` and `max` are passed already 1-based, matching `format(header, pageIndex + 1,
  /// circuits.size(), circ.getName())` at the one call site.
  static func format(_ header: String, index: Int, max: Int, circuitName: String) -> String {
    let chars = Array(header)

    func indexOfPercent(from start: Int) -> Int {
      var i = start
      while i < chars.count {
        if chars[i] == "%" { return i }
        i += 1
      }
      return -1
    }

    var mark = indexOfPercent(from: 0)
    if mark < 0 { return header }

    var out = ""
    var start = 0
    while mark >= 0 && mark + 1 < chars.count {
      out.append(contentsOf: chars[start..<mark])
      switch chars[mark + 1] {
      case "n": out.append(circuitName)
      case "p": out.append(String(index))
      case "P": out.append(String(max))
      case "%": out.append("%")
      default:
        out.append("%")
        out.append(chars[mark + 1])
      }
      start = mark + 2
      mark = indexOfPercent(from: start)
    }
    if start < chars.count {
      out.append(contentsOf: chars[start...])
    }
    return out
  }
}
