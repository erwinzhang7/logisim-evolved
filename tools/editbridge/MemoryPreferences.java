// An in-memory java.util.prefs backing store, so the edit oracle does not read, or write, the
// preferences of whoever runs it.
//
// WHY THIS EXISTS, AND WHY IT IS NOT OPTIONAL
//
// `AppPreferences.getPrefs()` is `Preferences.userNodeForPackage(Main.class)`, i.e. the *user's
// real* Logisim preferences. Two separate problems follow, and each one alone would sink the gate:
//
//  1. READING them makes the oracle a function of the host. `AppPreferences.ADD_AFTER`,
//     `DEFAULT_APPEARANCE` and `GATE_SHAPE` are all consulted on editing paths, and a machine
//     where someone once changed one in the GUI would produce different baseline bytes from a
//     machine where nobody had. That is the same shape as the font-family divergence that cost
//     this project a whole investigation (`docs/experiments/font-family.md`): an oracle that
//     silently depends on machine state.
//  2. WRITING them is worse. `EditBridge` needs `ADD_AFTER = unchanged` (see its header), and the
//     obvious way to get it, `AppPreferences.ADD_AFTER.set(...)`, is a *persistent* change to
//     the developer's own Logisim install that survives the JVM.
//
// So the whole preferences tree is redirected into a HashMap for the life of the bridge JVM, via
// `-Djava.util.prefs.PreferencesFactory=MemoryPreferences$Factory`. Every monitor then reports its
// compiled-in default, which is the only value that is the same on every machine.
//
// Derived from logisim-evolution's needs, not its code; this file is original. GPL-3.0-only to
// match the tree. See LICENSE.md.

import java.util.HashMap;
import java.util.Map;
import java.util.prefs.AbstractPreferences;
import java.util.prefs.BackingStoreException;
import java.util.prefs.Preferences;
import java.util.prefs.PreferencesFactory;

public final class MemoryPreferences extends AbstractPreferences {

  private final Map<String, String> values = new HashMap<>();
  private final Map<String, MemoryPreferences> children = new HashMap<>();

  private MemoryPreferences(MemoryPreferences parent, String name) {
    super(parent, name);
  }

  @Override
  protected void putSpi(String key, String value) {
    values.put(key, value);
  }

  @Override
  protected String getSpi(String key) {
    return values.get(key);
  }

  @Override
  protected void removeSpi(String key) {
    values.remove(key);
  }

  @Override
  protected void removeNodeSpi() {
    values.clear();
    children.clear();
  }

  @Override
  protected String[] keysSpi() {
    return values.keySet().toArray(new String[0]);
  }

  @Override
  protected String[] childrenNamesSpi() {
    return children.keySet().toArray(new String[0]);
  }

  @Override
  protected AbstractPreferences childSpi(String name) {
    return children.computeIfAbsent(name, n -> new MemoryPreferences(this, n));
  }

  @Override
  protected void syncSpi() throws BackingStoreException {
    // Nothing to sync: the map IS the store.
  }

  @Override
  protected void flushSpi() throws BackingStoreException {
    // `AppPreferences` flushes on shutdown. A no-op here is what keeps the developer's real
    // preferences untouched.
  }

  /** Named in `-Djava.util.prefs.PreferencesFactory`. */
  public static final class Factory implements PreferencesFactory {
    private static final MemoryPreferences USER = new MemoryPreferences(null, "");
    private static final MemoryPreferences SYSTEM = new MemoryPreferences(null, "");

    @Override
    public Preferences userRoot() {
      return USER;
    }

    @Override
    public Preferences systemRoot() {
      return SYSTEM;
    }
  }
}
