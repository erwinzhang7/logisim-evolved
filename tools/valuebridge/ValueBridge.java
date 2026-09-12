// Oracle bridge for property-testing the Swift port of com.cburch.logisim.data.Value.
//
// Reads one operation per line on stdin, writes one result line per input on stdout.
// The Swift side generates the same tuples, runs its own Value, and diffs.
//
// Line formats (whitespace separated, all integers decimal, longs may be negative):
//   U <op> <width> <error> <unknown> <value>                       unary
//   B <op> <width> <e1> <u1> <v1> <width2> <e2> <u2> <v2>          binary
//
// A line that makes Java throw yields "!<ExceptionClass>", which is itself a
// comparable result: the Swift port must fail on exactly the same inputs.
//
// Build:
//   javac -cp <logisim-fat.jar> -d out ValueBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out ValueBridge

import com.cburch.logisim.data.BitWidth;
import com.cburch.logisim.data.Bounds;
import com.cburch.logisim.data.Location;
import com.cburch.logisim.data.Value;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintStream;

public final class ValueBridge {

  // Use create(), NOT create_unsafe().
  //
  // Value.not()/xor() and friends compare by REFERENCE IDENTITY at width <= 1
  // ("if (this == TRUE) ..."), and create() returns the canonical TRUE/FALSE/
  // UNKNOWN/ERROR/NIL singletons for width 1. create_unsafe() only consults the
  // cache, and those singletons are built with `new Value(...)` and never put in
  // it, so create_unsafe can never return them. Building cases through
  // create_unsafe therefore makes every identity branch fall through to ERROR,
  // which looks exactly like a port defect and is not one. That cost 344 false
  // divergences before it was caught.
  // create(int,long,long,long) is PRIVATE, so build canonical values through the
  // public create(Value[]): it is LSB-first, identity-compares the singletons, and
  // routes into the private canonicalising create. Width 1 returns values[0]
  // directly, which is the singleton itself: exactly what the identity branches need.
  private static Value mk(int width, long error, long unknown, long value) {
    if (width <= 0) return Value.NIL;
    final Value[] bits = new Value[width];
    for (int i = 0; i < width; i++) {
      final long m = 1L << i;
      if ((error & m) != 0) bits[i] = Value.ERROR;
      else if ((unknown & m) != 0) bits[i] = Value.UNKNOWN;
      else if ((value & m) != 0) bits[i] = Value.TRUE;
      else bits[i] = Value.FALSE;
    }
    return Value.create(bits);
  }

  /** Deliberate create_unsafe probes: it validates nothing and skips canonicalisation. */
  private static Value mkUnsafe(int width, long error, long unknown, long value) {
    return Value.create_unsafe(width, error, unknown, value);
  }

  /** Everything observable about a Value, in a single stable line. */
  private static String describe(Value v) {
    if (v == null) return "null";
    final StringBuilder sb = new StringBuilder();
    sb.append(v.getWidth()).append(' ');
    sb.append(v.toBinaryString()).append(' ');
    sb.append(v.toHexString()).append(' ');
    sb.append(v.toDecimalString(false)).append(' ');
    sb.append(v.toDecimalString(true)).append(' ');
    sb.append(v.toLongValue()).append(' ');
    sb.append(v.toSignExtendedLongValue()).append(' ');
    sb.append(v.isFullyDefined()).append(' ');
    sb.append(v.isUnknown()).append(' ');
    sb.append(v.isErrorValue());
    return sb.toString();
  }

  private static String unary(String op, Value a) {
    switch (op) {
      case "id":       return describe(a);
      case "not":      return describe(a.not());
      case "all":      { final StringBuilder sb = new StringBuilder();
                         for (final Value b : a.getAll()) sb.append(describe(b)).append(" | ");
                         return sb.toString(); }
      case "binary":   return a.toBinaryString();
      case "hex":      return a.toHexString();
      case "dec":      return a.toDecimalString(true);
      case "decu":     return a.toDecimalString(false);
      case "long":     return Long.toString(a.toLongValue());
      case "slong":    return Long.toString(a.toSignExtendedLongValue());
      case "hash":     return Integer.toString(a.hashCode());
      case "width":    return Integer.toString(a.getWidth());
      case "bw":       return a.getBitWidth().toString();
      case "float":    return Float.toString(a.toFloatValue());
      case "double":   return Double.toString(a.toDoubleValue());
      case "fp16":     return Float.toString(a.toFloatValueFromFP16());
      case "fp8":      return Float.toString(a.toFloatValueFromFP8());
      default:         return "?unknown-op:" + op;
    }
  }

  private static String binary(String op, Value a, Value b) {
    switch (op) {
      case "and":      return describe(a.and(b));
      case "or":       return describe(a.or(b));
      case "xor":      return describe(a.xor(b));
      case "combine":  return describe(a.combine(b));
      case "controls": return describe(a.controls(b));
      case "compat":   return Boolean.toString(a.compatible(b));
      case "equals":   return Boolean.toString(a.equals(b));
      case "extend":   return describe(a.extendWidth(b.getWidth(), b.get(0)));
      case "get":      return describe(a.get((int) b.toLongValue()));
      case "set":      return describe(a.set((int) b.toLongValue(), Value.TRUE));
      default:         return "?unknown-op:" + op;
    }
  }

  /** Line protocol is whitespace-separated, so parse inputs arrive escaped. */
  private static String unescape(String s) {
    return s.replace("\\s", " ").replace("\\n", "\n").replace("\\t", "\t")
            .replace("\\r", "\r").replace("\\e", "");
  }

  public static void main(String[] args) throws Exception {
    // Value's static initialiser reads AppPreferences for display characters and
    // colours. If that cannot run headlessly the whole bridge is unusable, so touch
    // the class up front and report clearly rather than failing mid-stream.
    try {
      mk(1, 0, 0, 1);
    } catch (Throwable t) {
      System.out.println("!BRIDGE-INIT-FAILED " + t.getClass().getName() + " " + t.getMessage());
      System.out.flush();
      return;
    }

    final BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
    final PrintStream out = System.out;
    String line;
    while ((line = in.readLine()) != null) {
      line = line.trim();
      if (line.isEmpty()) continue;
      if (line.equals("PING")) { out.println("PONG"); out.flush(); continue; }
      final String[] f = line.split("\\s+");
      try {
        if (f[0].equals("U")) {
          final Value a = mk(Integer.parseInt(f[2]), Long.parseLong(f[3]),
                             Long.parseLong(f[4]), Long.parseLong(f[5]));
          out.println(unary(f[1], a));
        } else if (f[0].equals("B")) {
          final Value a = mk(Integer.parseInt(f[2]), Long.parseLong(f[3]),
                             Long.parseLong(f[4]), Long.parseLong(f[5]));
          final Value b = mk(Integer.parseInt(f[6]), Long.parseLong(f[7]),
                             Long.parseLong(f[8]), Long.parseLong(f[9]));
          out.println(binary(f[1], a, b));
        } else if (f[0].equals("P")) {
          // Location ops. Java's int is 32-bit and wraps; Integer.parseInt is 32-bit and
          // accepts any Unicode decimal digit; String.trim() strips everything <= U+0020.
          switch (f[1]) {
            case "parse":
              out.println(Location.parse(unescape(f[2])).toString());
              break;
            case "create":
              out.println(Location.create(Integer.parseInt(f[2]), Integer.parseInt(f[3]),
                                          Boolean.parseBoolean(f[4])).toString());
              break;
            case "translate": {
              final Location p = Location.create(Integer.parseInt(f[2]), Integer.parseInt(f[3]),
                                                 Boolean.parseBoolean(f[4]));
              out.println(p.translate(Integer.parseInt(f[5]), Integer.parseInt(f[6])).toString());
              break;
            }
            case "manhattan": {
              final Location p = Location.create(Integer.parseInt(f[2]), Integer.parseInt(f[3]), false);
              out.println(Integer.toString(
                  p.manhattanDistanceTo(Integer.parseInt(f[4]), Integer.parseInt(f[5]))));
              break;
            }
            default: out.println("?unknown-op:" + f[1]);
          }
        } else if (f[0].equals("R")) {
          // Bounds ops.
          final Bounds a = Bounds.create(Integer.parseInt(f[2]), Integer.parseInt(f[3]),
                                         Integer.parseInt(f[4]), Integer.parseInt(f[5]));
          switch (f[1]) {
            case "create": out.println(a.toString()); break;
            case "add":
              out.println(a.add(Bounds.create(Integer.parseInt(f[6]), Integer.parseInt(f[7]),
                                              Integer.parseInt(f[8]), Integer.parseInt(f[9])))
                           .toString());
              break;
            case "addpt":
              out.println(a.add(Integer.parseInt(f[6]), Integer.parseInt(f[7])).toString());
              break;
            case "contains":
              out.println(Boolean.toString(
                  a.contains(Integer.parseInt(f[6]), Integer.parseInt(f[7]))));
              break;
            default: out.println("?unknown-op:" + f[1]);
          }
        } else if (f[0].equals("F")) {
          // java.awt.Font.decode, which .circ font= attributes round-trip through. The port
          // had an off-by-one in the unrecognised-style fallback that truncated family names.
          final java.awt.Font fo = java.awt.Font.decode(unescape(f[2]));
          out.println(fo.getName() + "|" + fo.getStyle() + "|" + fo.getSize());
        } else if (f[0].equals("D")) {
          // Double.toString / Double.valueOf, the exact text formats a .circ carries.
          switch (f[1]) {
            case "str":   out.println(Double.toString(Double.longBitsToDouble(Long.parseLong(f[2])))); break;
            case "parse": out.println(Double.toString(Double.valueOf(unescape(f[2])))); break;
            default:      out.println("?unknown-op:" + f[1]);
          }
        } else if (f[0].equals("W")) {
          // BitWidth ops. getMask() was not covered before, and a width-63 mask crash
          // slipped past 32,929 Value cases because of it.
          final int w = Integer.parseInt(f[2]);
          final BitWidth bw = BitWidth.create(w);
          switch (f[1]) {
            case "mask":  out.println(Long.toString(bw.getMask())); break;
            case "width": out.println(Integer.toString(bw.getWidth())); break;
            case "str":   out.println(bw.toString()); break;
            case "parse": out.println(BitWidth.parse(f[3]).toString()); break;
            default:      out.println("?unknown-op:" + f[1]);
          }
        } else if (f[0].equals("X")) {
          // create_unsafe probe: bypasses masking and canonicalisation entirely.
          final Value a = mkUnsafe(Integer.parseInt(f[2]), Long.parseLong(f[3]),
                                   Long.parseLong(f[4]), Long.parseLong(f[5]));
          out.println(unary(f[1], a));
        } else {
          out.println("?bad-line-kind:" + f[0]);
        }
      } catch (Throwable t) {
        // A throw is a legitimate comparable outcome, not a bridge failure.
        out.println("!" + t.getClass().getSimpleName());
      }
      out.flush();
    }
  }
}
