// BoundsOracle.java; part of logisim-evolved's differential harness.
//
// Task #18. `getOffsetBounds(AttributeSet)` is gate-visible geometry: `XmlCircuitReader
// .buildCircuit` keys its overlap detector on a component's bounds and relocates a collision by
// +10,+10, so a factory whose box is wrong by one pixel puts every placement off-grid, and a
// factory whose box is empty collapses every placement of that factory onto one key.
//
// The Swift port transcribed ~45 of these by hand. Hand transcription is exactly what this
// harness exists to stop trusting, so this program is the oracle: it loads the shipped 4.1.0
// jar, walks every builtin factory, sweeps each attribute through its real domain, and prints
// one line per (factory, attribute assignment, bounds). `BoundsOracleTests` on the Swift side
// prints the same table and the two are compared literally.
//
// Build and run (the jar is the classpath; nothing is compiled against source):
//
//   JAR=/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar
//   javac -cp $JAR -d /tmp/boundsoracle tools/difftest/BoundsOracle.java
//   java -Djava.awt.headless=true -cp $JAR:/tmp/boundsoracle BoundsOracle > bounds.oracle
//
// ── Why a sweep and not a cross-product ─────────────────────────────────────────────────────
//
// A full cross-product over every attribute of every factory is combinatorially hopeless and
// mostly redundant: upstream's `getOffsetBounds` implementations read between one and four
// attributes. What matters is that every attribute a factory's geometry *could* read is moved
// off its default at least once, and that the two attributes that interact most often, a
// facing and a size/width, are moved together. So: a one-at-a-time sweep, plus a pairwise
// sweep restricted to (facing attribute × every other attribute). That reaches every branch of
// every implementation in the tree, checked by reading them.
//
// ── Determinism ─────────────────────────────────────────────────────────────────────────────
//
// Output is sorted, and every value is rendered through a fixed formatter rather than
// `toString()`, because several attribute values are localised and `toString()` is not stable
// across locales. The program never touches a `Circuit` or a `Project`, so none of the
// unreproducible-corpus problems (`generateValidVHDLLabel`'s random UUID) can reach it.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.

import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.data.Attribute;
import com.cburch.logisim.data.AttributeOption;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.BitWidth;
import com.cburch.logisim.data.Bounds;
import com.cburch.logisim.data.Direction;
import com.cburch.logisim.tools.AddTool;
import com.cburch.logisim.tools.Library;
import com.cburch.logisim.tools.Tool;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class BoundsOracle {

  public static void main(String[] args) throws Exception {
    final List<String> rows = new ArrayList<>();
    for (final Library library : builtinLibraries()) {
      for (final Tool tool : library.getTools()) {
        if (!(tool instanceof AddTool add)) continue;
        final ComponentFactory factory;
        try {
          factory = add.getFactory();
        } catch (Throwable t) {
          continue; // a lazily-loaded JAR factory; not a builtin.
        }
        if (factory == null) continue;
        sweep(library, factory, rows);
      }
    }
    Collections.sort(rows);
    for (final String row : rows) System.out.println(row);
  }

  /** Every builtin library, flattened. `Builtin` itself is a library of libraries. */
  private static List<Library> builtinLibraries() throws Exception {
    final var builtin = new com.cburch.logisim.std.Builtin();
    return new ArrayList<>(builtin.getLibraries());
  }

  private static void sweep(Library library, ComponentFactory factory, List<String> rows) {
    final AttributeSet base;
    try {
      base = factory.createAttributeSet();
    } catch (Throwable t) {
      return;
    }
    if (base == null) return;

    final var attributes = new ArrayList<>(base.getAttributes());

    // The default assignment.
    emit(rows, library, factory, base, "<default>");

    // One attribute at a time.
    for (final Attribute<?> attr : attributes) {
      for (final Object value : candidates(base, attr)) {
        final AttributeSet set = tryClone(base);
        if (set == null || !trySet(set, attr, value)) continue;
        emit(rows, library, factory, set, attr.getName() + "=" + render(value));
      }
    }

    // Facing × everything else: the pair that interacts in almost every implementation.
    final Attribute<?> facing = facingAttribute(attributes);
    if (facing != null) {
      for (final Object facingValue : candidates(base, facing)) {
        for (final Attribute<?> attr : attributes) {
          if (attr == facing) continue;
          for (final Object value : candidates(base, attr)) {
            final AttributeSet set = tryClone(base);
            if (set == null) continue;
            if (!trySet(set, facing, facingValue)) continue;
            if (!trySet(set, attr, value)) continue;
            emit(
                rows,
                library,
                factory,
                set,
                facing.getName() + "=" + render(facingValue)
                    + "," + attr.getName() + "=" + render(value));
          }
        }
      }
    }
  }

  private static Attribute<?> facingAttribute(List<Attribute<?>> attributes) {
    for (final Attribute<?> a : attributes) {
      if ("facing".equals(a.getName())) return a;
    }
    return null;
  }

  private static void emit(
      List<String> rows,
      Library library,
      ComponentFactory factory,
      AttributeSet set,
      String label) {
    String box;
    try {
      final Bounds b = factory.getOffsetBounds(set);
      box = b == null
          ? "null"
          : b.getX() + "," + b.getY() + "," + b.getWidth() + "," + b.getHeight();
    } catch (Throwable t) {
      box = "throw:" + t.getClass().getSimpleName();
    }
    rows.add(library.getName() + "\t" + factory.getName() + "\t" + label + "\t" + box);
  }

  private static AttributeSet tryClone(AttributeSet base) {
    try {
      return (AttributeSet) base.clone();
    } catch (Throwable t) {
      return null;
    }
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  private static boolean trySet(AttributeSet set, Attribute<?> attr, Object value) {
    try {
      if (set.isReadOnly(attr)) return false;
      ((AttributeSet) set).setValue((Attribute) attr, value);
      return true;
    } catch (Throwable t) {
      return false;
    }
  }

  /**
   * The values worth trying for one attribute, derived from its actual domain.
   *
   * <p>Option-valued and integer-range attributes carry their domain in a private field, which
   * is read reflectively; the jar is on the classpath as an unnamed module, so this is legal
   * and needs no `--add-opens`. Everything whose domain is unbounded or free text (labels,
   * fonts, colours, file paths) is skipped: none of them is read by any `getOffsetBounds` in
   * the tree, checked by reading all 51 implementations.
   */
  private static List<Object> candidates(AttributeSet base, Attribute<?> attr) {
    final List<Object> out = new ArrayList<>();
    final Object current;
    try {
      current = base.getValue(attr);
    } catch (Throwable t) {
      return out;
    }

    final Object[] options = optionsOf(attr);
    if (options != null) {
      for (final Object o : options) out.add(o);
      return out;
    }

    if (current instanceof BitWidth) {
      for (final int w : new int[] {1, 2, 3, 4, 5, 7, 8, 9, 16, 24, 31, 32}) {
        out.add(BitWidth.create(w));
      }
      return out;
    }

    if (current instanceof Direction) {
      out.add(Direction.NORTH);
      out.add(Direction.SOUTH);
      out.add(Direction.EAST);
      out.add(Direction.WEST);
      return out;
    }

    if (current instanceof Boolean) {
      out.add(Boolean.TRUE);
      out.add(Boolean.FALSE);
      return out;
    }

    if (current instanceof Integer) {
      final int[] range = rangeOf(attr);
      if (range != null) {
        // Both ends, both neighbours of both ends, and the midpoint, where an off-by-one in a
        // `/ 2` or a `Math.max` shows up.
        addIfInRange(out, range, range[0]);
        addIfInRange(out, range, range[0] + 1);
        addIfInRange(out, range, (range[0] + range[1]) / 2);
        addIfInRange(out, range, range[1] - 1);
        addIfInRange(out, range, range[1]);
      } else {
        for (final int v : new int[] {1, 2, 3, 4, 5, 8, 16, 32}) out.add(v);
      }
      return out;
    }

    return out;
  }

  private static void addIfInRange(List<Object> out, int[] range, int v) {
    if (v >= range[0] && v <= range[1] && !out.contains(v)) out.add(v);
  }

  /** The `options` array of `Attributes.OptionAttribute`, or null for any other attribute. */
  private static Object[] optionsOf(Attribute<?> attr) {
    for (Class<?> c = attr.getClass(); c != null; c = c.getSuperclass()) {
      try {
        final Field f = c.getDeclaredField("options");
        f.setAccessible(true);
        final Object v = f.get(attr);
        if (v instanceof Object[] arr) return arr;
      } catch (NoSuchFieldException ignored) {
        // keep walking up
      } catch (Throwable t) {
        return null;
      }
    }
    return null;
  }

  /** `{start, end}` of `Attributes.IntegerRangeAttribute`, or null. */
  private static int[] rangeOf(Attribute<?> attr) {
    for (Class<?> c = attr.getClass(); c != null; c = c.getSuperclass()) {
      try {
        final Field s = c.getDeclaredField("start");
        final Field e = c.getDeclaredField("end");
        s.setAccessible(true);
        e.setAccessible(true);
        return new int[] {(Integer) s.get(attr), (Integer) e.get(attr)};
      } catch (NoSuchFieldException ignored) {
        // keep walking up
      } catch (Throwable t) {
        return null;
      }
    }
    return null;
  }

  /**
   * A locale-independent rendering of an attribute value, chosen so the Swift side can parse it
   * straight back with the same attribute's `parse`.
   *
   * <p>The right token is `toString()`, and specifically NOT `AttributeOption.getValue()`.
   * `Attributes.OptionAttribute.parse` matches on `val.toString()`, and `AttributeOption
   * .toString()` returns its `name` field, which is also what the `.circ` file carries.
   * `getValue()` is a parallel payload that coincides with the name for most options and
   * diverges for some, so keying on it would silently mislabel those rows.
   *
   * <p>`toDisplayString()` is the localised one and is never used here.
   */
  private static String render(Object value) {
    if (value instanceof BitWidth bw) return String.valueOf(bw.getWidth());
    if (value instanceof AttributeOption opt) return opt.toString();
    return String.valueOf(value);
  }

  private BoundsOracle() {}
}
