// Drives upstream 4.1.0's REAL `Circuit.mutatorAdd`/`mutatorRemove`/`mutatorClear` (through
// `CircuitMutation`, exactly as an editing action does) and reports what
// `Circuit.getSocSimulationManager()` holds afterwards.
//
// WHY
//
// Seam #17: the Swift port's three mutators never called `SocSimulationManager`. The fix
// subscribes a manager to the `.add`/`.remove`/`.clear` circuit events. This is the oracle that
// says what upstream actually does at those three points: in particular the ordering question
// the Swift port could not settle by reading: `registerComponent`'s pending-list drain loop sits
// *lexically inside* `if (fact.isSocSlave() || fact.isSocSniffer())`
// (`SocSimulationManager.java:138-156`), so placing a BUS does not appear to adopt slaves that
// were placed before it. Reasoning is not proof; this runs it.
//
// Scenarios printed, one `key=value` line each:
//   busThenMemory.*   bus placed first, then the memory naming its id
//   memoryThenBus.*   the reverse; the pending-list case
//   afterRemove.*     the bus removed again
//   afterClear.*      mutatorClear on a populated circuit
//
// Runs headless (D17). Build:
//   javac -cp <logisim-fat.jar> -d out SocRegistrationBridge.java
// Run:
//   java -Djava.awt.headless=true -cp <logisim-fat.jar>:out SocRegistrationBridge

import com.cburch.logisim.circuit.Circuit;
import com.cburch.logisim.circuit.CircuitMutation;
import com.cburch.logisim.circuit.CircuitState;
import com.cburch.logisim.comp.Component;
import com.cburch.logisim.comp.ComponentFactory;
import com.cburch.logisim.data.AttributeSet;
import com.cburch.logisim.data.Location;
import com.cburch.logisim.file.Loader;
import com.cburch.logisim.file.LogisimFile;
import com.cburch.logisim.proj.Project;
import com.cburch.logisim.soc.bus.SocBus;
import com.cburch.logisim.soc.bus.SocBusAttributes;
import com.cburch.logisim.soc.data.SocBusInfo;
import com.cburch.logisim.soc.data.SocBusStateInfo;
import com.cburch.logisim.soc.data.SocSimulationManager;
import com.cburch.logisim.soc.memory.SocMemory;

import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.LinkedList;

public final class SocRegistrationBridge {

  private static Project project;

  private static Circuit freshCircuit(String name) throws Exception {
    final Loader loader = new Loader(null);
    final LogisimFile file = LogisimFile.createNew(loader, null);
    project = new Project(file);
    final Circuit circuit = file.getMainCircuit();
    circuit.setProject(project);
    CircuitState.createRootState(project, circuit);
    return circuit;
  }

  private static Component make(ComponentFactory factory, AttributeSet attrs, int x) {
    return factory.createComponent(Location.create(x, 100, true), attrs);
  }

  /** `CircuitMutation` is the editing path; it ends in `Circuit.mutatorAdd`. */
  private static void add(Circuit circuit, Component c) {
    final CircuitMutation m = new CircuitMutation(circuit);
    m.add(c);
    m.execute();
  }

  private static void remove(Circuit circuit, Component c) {
    final CircuitMutation m = new CircuitMutation(circuit);
    m.remove(c);
    m.execute();
  }

  private static void clear(Circuit circuit) {
    final CircuitMutation m = new CircuitMutation(circuit);
    m.clear();
    m.execute();
  }

  @SuppressWarnings("unchecked")
  private static HashMap<String, SocBusStateInfo> bussesOf(SocSimulationManager mgr)
      throws Exception {
    final Field f = SocSimulationManager.class.getDeclaredField("socBusses");
    f.setAccessible(true);
    return (HashMap<String, SocBusStateInfo>) f.get(mgr);
  }

  @SuppressWarnings("unchecked")
  private static java.util.List<Component> pendingOf(SocSimulationManager mgr) throws Exception {
    final Field f = SocSimulationManager.class.getDeclaredField("toBeChecked");
    f.setAccessible(true);
    return (java.util.List<Component>) f.get(mgr);
  }

  private static int slaveCount(SocBusStateInfo info) throws Exception {
    if (info == null) return -1;
    return info.getSlaves().size();
  }

  private static void report(String prefix, Circuit circuit, String busId) throws Exception {
    final SocSimulationManager mgr = circuit.getSocSimulationManager();
    final HashMap<String, SocBusStateInfo> busses = bussesOf(mgr);
    final SocBusStateInfo info = busses.get(busId);
    System.out.println(prefix + ".busCount=" + mgr.nrOfSocBusses());
    System.out.println(prefix + ".hasBusses=" + mgr.hasSocBusses());
    System.out.println(prefix + ".fabricExists=" + (info != null));
    System.out.println(
        prefix + ".fabricComponentIsBus=" + (info != null && info.getComponent() != null));
    System.out.println(prefix + ".slaveCount=" + slaveCount(info));
    System.out.println(prefix + ".pending=" + pendingOf(mgr).size());
  }

  public static void main(String[] args) throws Exception {
    com.cburch.logisim.Main.headless = true;

    // ── Scenario 1: bus first, then the memory naming its id ─────────────────────────────────
    {
      final Circuit circuit = freshCircuit("s1");
      final SocBus busFactory = new SocBus();
      final AttributeSet busAttrs = busFactory.createAttributeSet();
      final Component bus = make(busFactory, busAttrs, 100);
      final String busId =
          ((SocBusInfo) busAttrs.getValue(SocBusAttributes.SOC_BUS_ID)).getBusId();
      System.out.println("busThenMemory.busIdNonEmpty=" + (busId != null && !busId.isEmpty()));

      final SocMemory memFactory = new SocMemory();
      final AttributeSet memAttrs = memFactory.createAttributeSet();
      memAttrs.setValue(SocSimulationManager.SOC_BUS_SELECT, new SocBusInfo(busId));
      final Component memory = make(memFactory, memAttrs, 400);

      report("busThenMemory.empty", circuit, busId);
      add(circuit, bus);
      report("busThenMemory.afterBus", circuit, busId);
      add(circuit, memory);
      report("busThenMemory.afterMemory", circuit, busId);

      // Does mutatorAdd attach the manager to the component's LIVE SocBusInfo?
      final SocBusInfo liveMem =
          (SocBusInfo) memory.getAttributeSet().getValue(SocSimulationManager.SOC_BUS_SELECT);
      System.out.println(
          "busThenMemory.memoryInfoHasManager=" + (liveMem.getSocSimulationManager() != null));
      System.out.println("busThenMemory.memoryInfoComponentIsMemory=" + (liveMem.getComponent() == memory));

      remove(circuit, bus);
      report("afterRemove", circuit, busId);

      clear(circuit);
      report("afterClear", circuit, busId);
    }

    // ── Scenario 2: the memory FIRST, then its bus, the pending-list case ────────────────────
    {
      final Circuit circuit = freshCircuit("s2");
      final SocBus busFactory = new SocBus();
      final AttributeSet busAttrs = busFactory.createAttributeSet();
      final Component bus = make(busFactory, busAttrs, 100);
      final String busId =
          ((SocBusInfo) busAttrs.getValue(SocBusAttributes.SOC_BUS_ID)).getBusId();

      final SocMemory memFactory = new SocMemory();
      final AttributeSet memAttrs = memFactory.createAttributeSet();
      memAttrs.setValue(SocSimulationManager.SOC_BUS_SELECT, new SocBusInfo(busId));
      final Component memory = make(memFactory, memAttrs, 400);

      add(circuit, memory);
      report("memoryThenBus.afterMemory", circuit, busId);
      add(circuit, bus);
      report("memoryThenBus.afterBus", circuit, busId);

      // The other drain loop: `initializeTransaction`'s. If the bus arriving does NOT adopt the
      // pending slave, the first transaction must, or a slaves-before-bus `.circ` would never
      // work at all.
      final com.cburch.logisim.soc.data.SocBusTransaction t =
          new com.cburch.logisim.soc.data.SocBusTransaction(
              com.cburch.logisim.soc.data.SocBusTransaction.READ_TRANSACTION,
              0,
              0,
              com.cburch.logisim.soc.data.SocBusTransaction.WORD_ACCESS,
              bus);
      circuit.getSocSimulationManager().initializeTransaction(t, busId, project.getCircuitState());
      report("memoryThenBus.afterTransaction", circuit, busId);
    }

    System.out.println("done=true");
    System.out.flush();
    System.exit(0);
  }
}
