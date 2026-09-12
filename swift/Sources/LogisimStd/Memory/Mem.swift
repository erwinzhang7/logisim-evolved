// Mem.swift: part of logisim-evolved.
//
// Derived from logisim-evolution (com.cburch.logisim.std.memory.Mem),
// https://github.com/logisim-evolution/logisim-evolution. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore GPL-3.0-only. See LICENSE.md.
//
// Reference tree: upstream-java-4.1.0 (D16).
//
// ── What this file is ────────────────────────────────────────────────────────────────────────
//
// `Mem` is upstream's shared abstract base for `Ram` and `Rom`: the attribute *identities* every
// memory component reads (address/data width, line size, read/write behaviour, byte vs. line
// enables), plus a couple of small shared helpers. It declares no ports and no propagation of its
// own; those are `Ram`/`Rom`'s job, routed through `RamAppearance` (a shared file in this same
// directory, owned by a sibling slice; see its header for the exact API this file promises).
//
// ── Naming ───────────────────────────────────────────────────────────────────────────────────
//
// Java's `ADDR_ATTR`/`DATA_ATTR`/`LINE_ATTR`/`ENABLES_ATTR`/`ALLOW_MISALIGNED`/`READ_ATTR`/
// `ASYNC_READ`/`SEL_HIGH`/`SEL_LOW`/`ATTR_SELECTION` drop their `_ATTR`/`ATTR_` decoration, the
// same convention `RamAppearance.swift` already uses (`getNrAddrPorts` -> `addrPortCount`).
// **These exact names are load-bearing**: `RamAppearance.swift` (already ported) calls `Mem.addr`,
// `Mem.data`, `Mem.line`, `Mem.single`/`.dual`/`.quad`/`.octo`, `Mem.enables`,
// `Mem.useByteEnables`/`.useLineEnables` and `Mem.symbolWidth` verbatim; renaming any of them here
// breaks that file without touching it.
//
// ── Localisation dropped (D5's precedent) ───────────────────────────────────────────────────
//
// Every `S.getter(...)` display-string argument is gone; `Attributes.forOption`/`forBitWidth` in
// this port take no description parameter, exactly as `StdAttr`/`GateAttributes` already do.
//
// ── Not ported ───────────────────────────────────────────────────────────────────────────────
//
//   * `setInstancePoker(MemPoker.class)`, `setKeyConfigurator(...)`: UI key-handling (M6),
//     matches `InstanceFactory.swift`'s "Not ported" list.
//   * (`configureNewInstance`'s `instance.setTextField(StdAttr.LABEL, ...)` WAS listed here as
//     deferred to D6/M6. It is ported now, see `labelPlacement` at the bottom of the class,
//     and `board #78`.)
//   * `getInstanceFeature(MenuExtender.class)` -> `MemMenu`, attribute-table context menu, UI.
//   * `getHexFrame(Project, Instance, CircuitState)`; opens the interactive hex editor window.
//     `Project`/`CircuitState` do not exist below `LogisimUI` yet, and the whole feature is a
//     GUI window (M6). Not declared here; `Ram`/`Rom` do not need it for `propagate`.
import Foundation
import LogisimFile
import LogisimKernel
import LogisimRender

/// `com.cburch.logisim.std.memory.Mem`; shared attribute identities and small helpers for
/// `Ram` and `Rom`.
///
/// Upstream's header comment is preserved because it is still true of this port: the address
/// arithmetic is written to tolerate widths up to 32 bits (`MemContents`/`MemContentsSub`'s
/// paging), but only `Ram`/`Rom`'s own `ADDR_ATTR` bounds it to 2...24 in the ordinary UI path. A
/// hand-edited `.circ` file can still smuggle a wildly different address width through the
/// `contents` attribute's embedded "addr/data:" header (see `MemContents.parseRaw`), which is
/// exactly the "reachable through the address-width attribute" case worth guarding.
open class Mem: InstanceFactoryBase {

  // MARK: - Shared attribute identities (`Mem.ADDR_ATTR`, etc.)

  /// `Mem.SymbolWidth`.
  public static let symbolWidth: Int = 200

  /// `Mem.ADDR_ATTR`, `Attributes.forBitWidth("addrWidth", getter, 2, 24)`.
  public static let addr: Attribute<BitWidth> = Attributes.forBitWidth("addrWidth", min: 2, max: 24)

  /// `Mem.DATA_ATTR`: `Attributes.forBitWidth("dataWidth", getter)`, full 1...64 range.
  public static let data: Attribute<BitWidth> = Attributes.forBitWidth("dataWidth")

  /// `Mem.SEL_HIGH` / `Mem.SEL_LOW`.
  public static let selHigh = AttributeOption(name: "high")
  public static let selLow = AttributeOption(name: "low")

  /// `Mem.ATTR_SELECTION`.
  public static let selection: Attribute<AttributeOption> = Attributes.forOption(
    "Select", choices: [selHigh, selLow])

  /// `Mem.SINGLE` / `Mem.DUAL` / `Mem.QUAD` / `Mem.OCTO`.
  public static let single = AttributeOption(name: "single")
  public static let dual = AttributeOption(name: "dual")
  public static let quad = AttributeOption(name: "quad")
  public static let octo = AttributeOption(name: "octo")

  /// `Mem.LINE_ATTR`.
  public static let line: Attribute<AttributeOption> = Attributes.forOption(
    "line", choices: [single, dual, quad, octo])

  /// `Mem.ALLOW_MISALIGNED`.
  public static let allowMisaligned: Attribute<Bool> = Attributes.forBoolean("misaligned")

  /// `Mem.WRITEAFTERREAD` / `Mem.READAFTERWRITE`.
  public static let writeAfterRead = AttributeOption(name: "war")
  public static let readAfterWrite = AttributeOption(name: "raw")

  /// `Mem.READ_ATTR`.
  public static let readBehavior: Attribute<AttributeOption> = Attributes.forOption(
    "readbehav", choices: [writeAfterRead, readAfterWrite])

  /// `Mem.USEBYTEENABLES` / `Mem.USELINEENABLES`.
  public static let useByteEnables = AttributeOption(name: "byte")
  public static let useLineEnables = AttributeOption(name: "line")

  /// `Mem.ENABLES_ATTR`.
  public static let enables: Attribute<AttributeOption> = Attributes.forOption(
    "enables", choices: [useByteEnables, useLineEnables])

  /// `Mem.ASYNC_READ`.
  public static let asyncRead: Attribute<Bool> = Attributes.forBoolean("asyncread")

  /// `Mem.DELAY`.
  public static let delay: Int = 10

  // MARK: - `Mem.MemListener`

  /// `Mem.MemListener`: forwards a `HexModel` change to a repaint request.
  ///
  /// Upstream's `WeakHashMap<Instance, MemListener>` (`Ram.memListeners` / `Rom.memListeners`)
  /// exists purely to keep this listener alive: `MemContents.addHexModelListener` (see
  /// `MemContents.swift`) stores listeners *weakly*, so nothing else keeps a `MemListener` from
  /// being collected while the component it repaints still lives. `Ram.swift`/`Rom.swift` keep
  /// the same shape, a component-keyed dictionary, since `StdInstanceComponent` (D3) has no
  /// general-purpose per-factory side table the way upstream's `Instance` could grow one ad hoc.
  ///
  /// **Known gap, flagged rather than silently accepted (D3):** that dictionary is never pruned
  /// when a component is removed from its circuit, so it leaks one entry per RAM/ROM ever placed
  /// for the lifetime of the process. Upstream's `WeakHashMap` self-prunes when the `Instance` is
  /// collected; matching that exactly needs a deinit/removal hook on `StdInstanceComponent` that
  /// does not exist yet. Flagged in this port's final report as a change needed outside this
  /// slice's file ownership.
  public final class MemListener: HexModelListener {
    private weak var component: StdInstanceComponent?

    public init(_ component: StdInstanceComponent) {
      self.component = component
    }

    /// `bytesChanged` -> `instance.fireInvalidated()`.
    public func bytesChanged(
      source: any HexModel, start: Int64, numBytes: Int64, oldValues: [Int64]?
    ) {
      component?.fireInvalidated()
    }

    /// `metainfoChanged`; upstream's body is empty.
    public func metainfoChanged(source: any HexModel) {}
  }

  // MARK: - Current-image bookkeeping (`currentInstanceFiles`)

  /// `Mem.currentInstanceFiles` (`WeakHashMap<Instance, File>`), keyed by component identity.
  ///
  /// Backs `getCurrentImage`/`setCurrentImage`, which upstream's interactive hex-file open/save
  /// dialogs (`HexFile.open`/`HexFile.save`, both UI/M6) use to remember the last file an
  /// instance was loaded from or saved to. Not exercised by anything ported in this slice
  /// (`propagate`, attributes, serialisation), but kept so the surface exists for M6 to wire up.
  ///
  /// **Known gap (D3):** a plain dictionary keyed by `ObjectIdentifier` has no weak-key story in
  /// Swift the way `WeakHashMap` does, so an entry here outlives the component it describes.
  /// Bounded in practice (one entry per RAM/ROM ever given a "load image" file), but not
  /// self-pruning. Needs an explicit eviction hook once M6 wires the hex-file UI; flagged in this
  /// port's final report.
  private var currentInstanceFiles: [ObjectIdentifier: URL] = [:]

  /// `Mem.getCurrentImage(Instance)`.
  public func currentImage(for component: StdInstanceComponent) -> URL? {
    currentInstanceFiles[ObjectIdentifier(component)]
  }

  /// `Mem.setCurrentImage(Instance, File)`.
  public func setCurrentImage(_ value: URL?, for component: StdInstanceComponent) {
    currentInstanceFiles[ObjectIdentifier(component)] = value
  }

  // MARK: - Construction

  /// `Mem(String, StringGetter, int extraPorts, HdlGeneratorFactory, boolean needsLabel)`.
  ///
  /// `extraPorts` is dropped: upstream's constructor accepts it but never stores or reads it
  /// anywhere in `Mem.java`: a dead parameter, not dead behaviour. `desc` (display string) is
  /// dropped per D5; `generator` (HDL) is stripped per the port's HDL policy; `RamHdlGenerator
  /// Factory`/`RomHdlGeneratorFactory` are not ported.
  /// `Mem(String name, StringGetter title, int extraPorts, HdlGeneratorFactory, boolean isRam)`,
  /// reduced to the two arguments this port's chassis needs. `displayName` is upstream's
  /// `title`: `Ram` and `Rom` pass getters that resolve to their own `_ID` ("RAM" / "ROM"), so
  /// they omit it; `DualRam` passes one that resolves to "Dual Port RAM", so it does not.
  public init(_ name: String, displayName: String? = nil, requiresLabel: Bool) {
    super.init(name, displayName: displayName, requiresLabel: requiresLabel)
    setOffsetBounds(Bounds.create(-140, -40, 140, 80))
  }

  // MARK: - Label placement (`Mem.configureNewInstance`, Mem.java:135-143)

  /// `instance.setTextField(StdAttr.LABEL, StdAttr.LABEL_FONT, bds.getX() + bds.getWidth() / 2,
  /// bds.getY() - 2, GraphicsUtil.H_CENTER, GraphicsUtil.V_BOTTOM)`: Mem.java:137-142.
  ///
  /// **`-2` and `V_BOTTOM`, not the `-3`/`V_BASELINE` the other four memory factories use.**
  /// The difference is upstream's and is one pixel plus a different baseline resolution, so it
  /// is raster-observable; it is transcribed rather than unified deliberately.
  ///
  /// `Ram`, `Rom` and `DualRam` all call `super.configureNewInstance(instance)` and install no
  /// field of their own (Ram.java:107, Rom.java:132, DualRam.java:108), so inheriting this
  /// through the class hierarchy is exactly upstream's arrangement.
  ///
  /// One divergence from upstream, in the port's favour and inherent to the mechanism: upstream
  /// freezes these coordinates at `configureNewInstance` and never recomputes them, so a RAM
  /// whose bounds change (the address/data width attributes resize the body) keeps a label
  /// pinned to the *old* top edge. This is a pure function of the current bounds, so it follows.
  public func labelPlacement(_ painter: InstancePainter) -> LabelPlacement? {
    let bds = painter.bounds
    return LabelPlacement(
      x: bds.x + bds.width / 2, y: bds.y - 2, halign: .center, valign: .bottom)
  }

  // MARK: - Shared helpers

  /// `Mem.getSizeLabel(int)`.
  public static func sizeLabel(addressBits: Int) -> String {
    let labels = ["", "K", "M", "G", "T", "P", "E"]
    var pass = 0
    var bits = addressBits
    while bits > 9 {
      pass += 1
      bits -= 10
    }
    let size = 1 << bits
    // Upstream indexes `labels[pass]` unguarded; `pass` only grows past 6 for an address width
    // beyond 70 bits, which no `BitWidth` (max 64) can produce, so the array is never
    // out-of-bounds in practice: the same "internal invariant, no `.circ` file can violate it"
    // shape as the rest of this port's traps (D13).
    return "\(size)\(labels[pass])"
  }
}

extension Mem: InstanceLabelProvider {}
