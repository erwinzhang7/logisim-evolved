// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.LogisimFile: one open `.circ`, presented to the rest of the
// application as a `Library` whose tools are its circuits.
//
// ── What does not come across, and where it went ────────────────────────────────────────────
//
//   * `AutosaveThread`. Upstream starts a background thread per open file that calls
//     `loader.autosave(file)` on a timer, unsynchronised with the EDT, which is a data race on
//     `Loader`'s file bookkeeping that Java's GC and coarse locking merely hide. The *state* it
//     drives, `isAutosaveDirty`, `autosaveLoaded`, `stopAutosaveThread(delete:)`, is ported
//     exactly, and the loop body is `autosaveIfDirty()`. Owning the timer is the app shell's
//     job (M8), which is also the only layer that can serialise it against editing.
//   * `Projects.windowNamed`, `OptionPane`, `AppPreferences`. Project- and UI-layer reach-ins
//     that D9 keeps out of this module. Each has a named seam in `LogisimFileSeams`.
//   * `write(OutputStream, …)`'s five overloads collapse into one; Java's extra arities exist
//     only because Java has no default arguments.

import Foundation
import LogisimKernel

// MARK: - Seams

/// The hooks the layers above install into the file layer.
///
/// Every one of these replaces an upstream call that reaches out of `com.cburch.logisim.file`
/// into `circuit`, `proj`, `gui` or `prefs`. Naming them in one place makes the coupling
/// auditable: if this enum is empty at run time, loading a `.circ` still works completely: the
/// seams only matter for creating new content and for the interactive commands.
public enum LogisimFileSeams {

  /// `new VhdlEntity(content)`. Installed by the VHDL port (M5), which does not exist yet:
  /// unlike `Circuit`, which does, so circuits are handled concretely below.
  public static var makeVhdlEntity: ((any VhdlContentReference) -> any VhdlEntityFactory)?

  /// `Projects.windowNamed(String)`; is some other open project already called this?
  /// Nil means "no other project", which is the correct answer for a headless run.
  public static var projectNameInUse: ((String) -> Bool)?

  /// Serialises clear/restore against readers. See `withCleared`.
  ///
  /// `NSRecursiveLock` for the same reason `BuiltinToolProviders` uses one (D1 names it as a
  /// primitive the kernel may use): every caller here is synchronous and must stay so.
  private static let lock = NSRecursiveLock()

  /// Test support: forget every installed seam.
  ///
  /// **Prefer `withCleared`.** A bare clear leaves the seams nil for every other suite too; see
  /// that function's header for what that costs.
  public static func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    makeVhdlEntity = nil
    projectNameInUse = nil
  }

  /// Run `body` with every seam cleared, then put back exactly what was there: with readers
  /// held off for the whole window.
  ///
  /// ── WHY THE OBVIOUS SNAPSHOT/RESTORE IS NOT ENOUGH ────────────────────────────────────────
  ///
  /// These are process-global and swift-testing runs suites in parallel, so a bare
  /// `removeAll()`, even one that restores afterwards, leaves the seams nil for every
  /// *concurrent* suite for the duration of the window. Measured: `FileModelTests` cleared them
  /// at the top of five tests and never restored, while `StatsVhdlEntityTests` loads a `<vhdl>`
  /// element through `XmlReader` **without** constructing a host, so it never re-asserts the
  /// seam. When the clear landed inside that load, the element took D8's verbatim path and
  /// `file.tool(named: "sig")` came back nil; a full-suite failure in 2 of 5 runs, green under
  /// `--filter`, which is the signature of shared state rather than a defect in either test.
  ///
  /// Holding the lock across clear → body → restore closes the window: a reader either sees the
  /// seams installed or blocks until they are again. That is the same shape as
  /// `BuiltinToolProviders.withRegistryCleared`, which exists because of the identical defect in
  /// the builtin registry, and the fix is deliberately identical so the two cannot drift.
  ///
  /// This is the THIRD instance of one pattern: a test or tool that wipes process-global state
  /// and restores less than it took. The others were the builtin tool registry and the migration
  /// baselines. If you are adding new process-global state, add its `withCleared` at the same
  /// time; retrofitting one has cost a day each time.
  public static func withCleared<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }

    let savedMakeVhdlEntity = makeVhdlEntity
    let savedProjectNameInUse = projectNameInUse
    // Registered second, so it runs FIRST (defers are LIFO): i.e. still under the lock.
    defer {
      makeVhdlEntity = savedMakeVhdlEntity
      projectNameInUse = savedProjectNameInUse
    }

    makeVhdlEntity = nil
    projectNameInUse = nil
    return try body()
  }
}

/// The HDL-name comparison `LogisimFile` uses for duplicate detection.
///
/// `SyntaxChecker.namesEqualForCurrentHdl` reads `AppPreferences.HdlType`, which D9 keeps out
/// of this layer. The preference's default is VHDL and VHDL identifiers are case-insensitive,
/// so the default here is case-insensitive comparison: **using Java's `equalsIgnoreCase`**,
/// not Swift's full Unicode case folding, since the two disagree for `ß`, `ﬃ` and friends
/// (see `JavaStringSupport.swift`).
public enum HdlNames {
  public enum HdlType: String {
    case vhdl = "VHDL"
    case verilog = "Verilog"
    case none = "None"
  }

  /// `AppPreferences.HdlType`, whose upstream default is `VHDL`.
  public static var current: HdlType = .vhdl

  /// `SyntaxChecker.namesEqual(String, String, String)`.
  public static func namesEqual(_ first: String, _ second: String, hdlType: HdlType) -> Bool {
    hdlType == .vhdl ? javaEqualsIgnoreCase(first, second) : first == second
  }

  /// `SyntaxChecker.namesEqualForCurrentHdl(String, String)`.
  public static func namesEqualForCurrentHdl(_ first: String, _ second: String) -> Bool {
    namesEqual(first, second, hdlType: current)
  }
}

// MARK: - LogisimFile

/// `com.cburch.logisim.file.LogisimFile`.
///
/// `CircuitFileReference` is what `Circuit.getProjName()` reads, and `CircuitListener` is the
/// duplicate-name check: upstream subscribes the file to every circuit it owns purely to answer
/// `ACTION_CHECK_NAME`.
public final class LogisimFile: Library, LibraryEventSource, CircuitFileReference, CircuitListener
{

  /// `LogisimFile` is not a builtin, so it has no `_ID`; upstream's `getName()` returns the
  /// project name and this override follows it.
  public override class var libraryId: String { "LogisimFile" }

  // MARK: State

  private let listeners = WeakListenerList<LibraryListener>()
  private var messageQueue: [String] = []
  private let optionsStorage = Options()

  /// Java's `List<AddTool> tools`. Order is the `<circuit>` order in the file and is
  /// observable; the writer emits circuits in this order and `moveCircuit` exists to change it.
  private var addToolList: [AddTool] = []

  /// D3 ownership, and it is not optional bookkeeping.
  ///
  /// `AddTool` holds its `ComponentFactory` strongly, but `CircuitSubcircuitFactory → Circuit`
  /// is `unowned`, so `addToolList` does **not** keep a circuit alive. Java's GC needs no
  /// equivalent because the whole island is reachable from the file. These two arrays are the
  /// file's strong ownership of its contents; membership is maintained beside `addToolList` and
  /// nothing else reads them.
  private var ownedCircuits: [Circuit] = []
  private var ownedVhdlContents: [any VhdlContentReference] = []

  private var libraryList: [Library] = []

  /// Java's `private Loader loader`. Strong: `Loader` holds no reference back to any file, it
  /// keeps only URLs, its `Builtin`, and the reader/writer seams, so this edge closes no cycle.
  private var loaderRef: Loader

  /// Java's `private Circuit main`. Always also present in `ownedCircuits`, so the strong
  /// reference here is a duplicate rather than a second owner.
  private var mainCircuitRef: Circuit?

  private var fileName: String
  private var dirtyFlag = false
  private var autosaveDirtyFlag = false
  private var autosaveLoadedFlag = false
  private var autosaveStopped = false

  // MARK: Construction

  /// Java's package-private `LogisimFile(Loader)`.
  ///
  /// The autosave thread it starts is not started here (see the file header). The default
  /// project name, including the `_2`, `_3` … disambiguation against other open projects, is
  /// reproduced through `LogisimFileSeams.projectNameInUse`.
  init(loader: Loader) {
    self.loaderRef = loader
    var candidate = FileStrings.defaultProjectName
    if let inUse = LogisimFileSeams.projectNameInUse, inUse(candidate) {
      var index = 2
      while inUse("\(candidate)_\(index)") { index += 1 }
      candidate += "_\(index)"
    }
    self.fileName = candidate
    super.init()
  }

  /// Java `createEmpty(Loader)`.
  public static func createEmpty(loader: Loader) -> LogisimFile {
    LogisimFile(loader: loader)
  }

  /// Java `createNew(Loader, Project)`.
  ///
  /// The `Project` argument is dropped: upstream passes it straight into `new Circuit(...)`,
  /// whose port does not take one (it is only ever used for simulator wiring, which is M3).
  ///
  /// D13: `Circuit.init` throws, it writes the circuit's static attributes, and `setValue`
  /// throws, so this does too, rather than trapping on a failure the caller can report.
  public static func createNew(loader: Loader) throws -> LogisimFile {
    let result = LogisimFile(loader: loader)
    let main = try Circuit(name: "main", file: result)
    // Upstream assigns `ret.main` directly and then adds the tool, so no SET_MAIN and no
    // ADD_TOOL event is fired for a brand-new file, and the circuit gets no listener. Going
    // through `addCircuit` would fire both; the order here reproduces upstream's silence.
    result.mainCircuitRef = main
    result.ownedCircuits.append(main)
    result.addToolList.append(AddTool(factory: main.subcircuitFactory))
    return result
  }

  // MARK: Loading

  /// Java `getFirstLine(BufferedInputStream)`.
  ///
  /// Bug-for-bug: upstream reads into a fixed 512-byte array and ignores the count `read`
  /// returns, so for a file shorter than 512 bytes with no newline the "first line" carries the
  /// array's trailing zero bytes. Reproduced by decoding from a zero-filled buffer: it matters
  /// only for the `"Logisim v1.0"` comparison below, which such a file cannot satisfy either
  /// way, but the shape is kept so the comparison cannot silently change meaning.
  static func firstLine(of data: Data) -> String {
    var buffer = [UInt8](repeating: 0, count: 512)
    let prefix = [UInt8](data.prefix(512))
    if !prefix.isEmpty { buffer.replaceSubrange(0..<prefix.count, with: prefix) }
    var lineBreak = buffer.count
    for index in 0..<lineBreak where buffer[index] == 0x0A {
      lineBreak = index
      break
    }
    return String(decoding: buffer[0..<lineBreak], as: UTF8.self)
  }

  /// Java `loadSub(InputStream, Loader, File)`.
  ///
  /// Upstream also guards `if (firstLine == null) throw new IOException("File is empty")`, and
  /// that branch is **unreachable**: `getFirstLine` builds its result from a zero-filled array
  /// and can only return a `String`, never null. An empty file therefore reaches the parser and
  /// fails there. Not reproduced as a live check, because adding one would change what an empty
  /// `.circ` reports.
  ///
  /// D13: the surviving `IOException` throws. A Logisim 1.0 file is ordinary user input and
  /// upstream's caller catches it.
  public static func loadSub(
    data: Data, loader: Loader, sourceFile: URL? = nil
  ) throws -> LogisimFile {
    let first = firstLine(of: data)
    if first == "Logisim v1.0" {
      throw LoadFailedError("Version 1.0 files no longer supported")
    }
    let result = try loader.readLibrary(data, sourceFile: sourceFile)
    result.loaderRef = loader
    return result
  }

  /// Java `load(InputStream, Loader)`.
  ///
  /// Upstream catches only `SAXException` here and lets `IOException` out; the Swift reader
  /// seam does not distinguish parser failures from I/O failures, so this catches the parse
  /// error and reports it exactly as upstream does, and rethrows nothing else.
  public static func load(data: Data, loader: Loader) throws -> LogisimFile? {
    do {
      return try loadSub(data: data, loader: loader)
    } catch let error as LoadFailedError {
      throw error
    } catch {
      loader.showError(FileStrings.xmlFormatError(String(describing: error)))
      return nil
    }
  }

  /// Java `load(File, Loader)`: the autosave prompt, then the two-pass decode.
  ///
  /// The prompt is asked through `LoaderUI.autosaveDisposition`, which adds an `ignore` answer
  /// upstream does not have: both of upstream's answers destroy something (discard deletes the
  /// user's autosave, load silently opens different bytes than the file named on the command
  /// line), and a headless run has nobody to ask. `HeadlessLoaderUI` answers `ignore`.
  public static func load(_ file: URL, loader: Loader) throws -> LogisimFile? {
    var loadFile = file
    var autosaveLoading = false

    if let autosave = Loader.findAutosaveFile(file) {
      switch loader.ui.autosaveDisposition(for: file, autosave: autosave) {
      case .cancel:
        // Java: `JOptionPane.CLOSED_OPTION` → do nothing and fail.
        return nil
      case .load:
        loadFile = autosave
        loader.setAutosavePath(autosave)
        autosaveLoading = true
      case .discard:
        try? FileManager.default.removeItem(at: autosave)
      case .ignore:
        break
      }
    }

    // Java: `new FileInputStream(loadFile)`, *outside* the try that catches the parse failure.
    // A missing or unreadable file is therefore an `IOException` out of `load`, which
    // `Loader.loadLogisimFile` turns into `logisimLoadError(projectName, detail)`. Letting the
    // error propagate here reproduces that path exactly; catching it would replace the message
    // with an XML-formatting complaint about a file that was never parsed.
    let data = try Data(contentsOf: loadFile)

    var result: LogisimFile?
    var firstError: Error?
    do {
      result = try loadSub(data: data, loader: loader, sourceFile: file)
    } catch {
      firstError = error
    }

    // Upstream's second attempt: re-read through a `FileReader`, which decodes with a
    // CharsetDecoder set to REPLACE malformed input, and re-encode as UTF-8. Its stated purpose
    // is Logisim before 2.5.1, which wrote files in the platform charset while declaring UTF-8.
    // Since JEP 400 (Java 18) the platform charset *is* UTF-8, so the only remaining difference
    // between the two passes is that this one substitutes U+FFFD for invalid byte sequences
    // instead of failing. `String(decoding:as:)` has exactly that behaviour.
    if let firstError {
      let replaced = Data(String(decoding: data, as: UTF8.self).utf8)
      do {
        result = try loadSub(data: replaced, loader: loader, sourceFile: file)
      } catch {
        loader.showError(FileStrings.xmlFormatError(String(describing: firstError)))
      }
    }

    result?.autosaveLoadedFlag = autosaveLoading
    return result
  }

  /// Java `cloneLogisimFile(Loader)`.
  ///
  /// Upstream connects a `PipedOutputStream` to a `PipedInputStream`, writes on a second thread
  /// and reads on this one; a thread purely to avoid buffering the document in memory. A
  /// `.circ` is a few hundred kilobytes, so this writes to `Data` and reads it back. Same
  /// result, no thread, and the pipe's deadlock-on-writer-death failure mode disappears.
  ///
  /// Note the asymmetry upstream has and this keeps: the document is *written* through this
  /// file's own loader (so descriptors resolve relative to where it came from) and *read* with
  /// the new one.
  public func cloneLogisimFile(_ newLoader: Loader) -> LogisimFile? {
    do {
      let data = try loaderRef.write(self, destination: nil, mainCircFile: nil)
      return try LogisimFile.load(data: data, loader: newLoader)
    } catch {
      newLoader.showError(FileStrings.fileDuplicateError(String(describing: error)))
      return nil
    }
  }

  // MARK: Library overrides

  public override var name: String { fileName }

  public override var displayName: String { fileName }

  public override var libraries: [Library] { libraryList }

  /// Java `getTools()` returns `List<AddTool>`; `addTools` is the typed form.
  public override var tools: [Tool] { addToolList }

  public var addTools: [AddTool] { addToolList }

  public override var isDirty: Bool { dirtyFlag }

  /// Java `removeLibrary(String)`.
  ///
  /// Bug-for-bug: it fires no `REMOVE_LIBRARY` event, unlike `removeLibrary(Library)`. And its
  /// loop keeps assigning `index` for every match rather than stopping at the first, so with
  /// duplicate names the *last* match wins, reproduced here.
  @discardableResult
  public override func removeLibrary(named name: String) -> Bool {
    var index = -1
    for (position, library) in libraryList.enumerated() where library.name == name {
      index = position
    }
    guard index >= 0 else { return false }
    libraryList.remove(at: index)
    return true
  }

  // MARK: Accessors

  public var loader: Loader { loaderRef }

  public var options: Options { optionsStorage }

  public var mainCircuit: Circuit? { mainCircuitRef }

  public var isAutosaveLoaded: Bool { autosaveLoadedFlag }

  public var isAutosaveDirty: Bool { autosaveDirtyFlag }

  /// Java `getCircuits()`: derived from the tool list, in tool order.
  ///
  /// `SubcircuitFactory.subcircuit` is typed `any CircuitReference` so that the protocol can be
  /// declared without a dependency on `Circuit`; the only conformer is
  /// `CircuitSubcircuitFactory`, whose source *is* a `Circuit`, so the downcast is total.
  public var circuits: [Circuit] {
    addToolList.compactMap { ($0.factory as? any SubcircuitFactory)?.subcircuit as? Circuit }
  }

  /// Java `getCircuitCount()`.
  public var circuitCount: Int { circuits.count }

  /// Java `getVhdlContents()`.
  public var vhdlContents: [any VhdlContentReference] {
    addToolList.compactMap { ($0.factory as? any VhdlEntityFactory)?.content }
  }

  /// Java `getCircuit(String)`. Matches on the *factory* name, which for a subcircuit is the
  /// circuit's name.
  ///
  /// Note this returns the **first** match, which is how upstream resolves a file that declares
  /// two `<circuit name="decoder">`: the corpus contains one. Nothing rejects the duplicate at
  /// load time; the second circuit is simply unreachable by name.
  public func circuit(named name: String) -> Circuit? {
    for tool in addToolList {
      if let factory = tool.factory as? any SubcircuitFactory, factory.name == name {
        return factory.subcircuit as? Circuit
      }
    }
    return nil
  }

  /// Java `getVhdlContent(String)`.
  public func vhdlContent(named name: String) -> (any VhdlContentReference)? {
    for tool in addToolList {
      if let factory = tool.factory as? any VhdlEntityFactory, factory.name == name {
        return factory.content
      }
    }
    return nil
  }

  /// Java `indexOfCircuit(Circuit)`: an index into the *tool* list, not into `getCircuits()`.
  public func indexOfCircuit(_ circuit: Circuit) -> Int {
    for (index, tool) in addToolList.enumerated() {
      if let factory = tool.factory as? any SubcircuitFactory, factory.subcircuit === circuit {
        return index
      }
    }
    return -1
  }

  /// Java `indexOfVhdl(VhdlContent)`.
  public func indexOfVhdl(_ content: any VhdlContentReference) -> Int {
    for (index, tool) in addToolList.enumerated() {
      if let factory = tool.factory as? any VhdlEntityFactory, factory.content === content {
        return index
      }
    }
    return -1
  }

  /// Java `contains(Circuit)`. D4: reference identity.
  public func contains(circuit: Circuit) -> Bool {
    indexOfCircuit(circuit) >= 0
  }

  /// Java `contains(VhdlContent)`.
  public func contains(vhdl: any VhdlContentReference) -> Bool {
    indexOfVhdl(vhdl) >= 0
  }

  /// Java `containsFactory(String)`.
  public func containsFactory(named name: String) -> Bool {
    for tool in addToolList {
      if let factory = tool.factory as? any VhdlEntityFactory {
        if factory.content.name == name { return true }
      } else if let factory = tool.factory as? any SubcircuitFactory {
        if factory.subcircuit.name == name { return true }
      }
    }
    return false
  }

  /// Java `getAddTool(Circuit)`.
  public func addTool(for circuit: Circuit) -> AddTool? {
    let index = indexOfCircuit(circuit)
    return index >= 0 ? addToolList[index] : nil
  }

  /// Java `getAddTool(VhdlContent)`.
  public func addTool(for content: any VhdlContentReference) -> AddTool? {
    let index = indexOfVhdl(content)
    return index >= 0 ? addToolList[index] : nil
  }

  /// Java's package-private `findTool(Tool)`: the same tool, found in *this* file's libraries.
  ///
  /// `Tool` has no `equals` override upstream, so `tool.equals(query)` is reference identity;
  /// D4 says the port must keep it that way.
  func findTool(_ query: Tool) -> Tool? {
    for library in libraryList {
      if let found = LogisimFile.findTool(in: library, query: query) { return found }
    }
    return nil
  }

  private static func findTool(in library: Library, query: Tool) -> Tool? {
    library.tools.first { $0 === query }
  }

  // MARK: Mutation

  /// Java `addCircuit(Circuit)`.
  public func addCircuit(_ circuit: Circuit) {
    addCircuit(circuit, at: addToolList.count)
  }

  /// Java `addCircuit(Circuit, int)`.
  ///
  /// D3: `Circuit`'s listener list is weak on both sides (`WeakListenerList`), exactly as
  /// upstream's `EventSourceWeakSupport` is, so subscribing the file here creates no cycle.
  public func addCircuit(_ circuit: Circuit, at index: Int) {
    circuit.addCircuitListener(self)
    let tool = AddTool(factory: circuit.subcircuitFactory)
    addToolList.insert(tool, at: index)
    ownedCircuits.append(circuit)
    if addToolList.count == 1 { setMainCircuit(circuit) }
    fireEvent(.addTool, .tool(tool))
  }

  /// Java `addVhdlContent(VhdlContent)`.
  ///
  /// A no-op when the VHDL port has not installed `makeVhdlEntity`; upstream cannot reach that
  /// state because `VhdlEntity` is a compile-time dependency.
  public func addVhdlContent(_ content: any VhdlContentReference) {
    addVhdlContent(content, at: addToolList.count)
  }

  /// Java `addVhdlContent(VhdlContent, int)`.
  public func addVhdlContent(_ content: any VhdlContentReference, at index: Int) {
    guard let make = LogisimFileSeams.makeVhdlEntity else { return }
    let tool = AddTool(factory: make(content))
    addToolList.insert(tool, at: index)
    ownedVhdlContents.append(content)
    fireEvent(.addTool, .tool(tool))
  }

  /// Java `addLibrary(Library)`.
  ///
  /// The read-only pass matters at load time: a sub-library's circuits must not have their
  /// names edited through the containing project, so every `AddTool` from a non-`Base` library
  /// gets `CircuitAttributes.NAME_ATTR` frozen.
  ///
  /// Upstream compares `attr == CircuitAttributes.NAME_ATTR`, i.e. by reference, and so does
  /// this (D4). The identity is the same singleton in both directions because
  /// `CircuitAttributes.nameAttribute` is a `static let`.
  public func addLibrary(_ library: Library) {
    if library.name != BaseLibrary.libraryId {
      for tool in library.tools {
        guard let addTool = tool as? AddTool, let attributes = addTool.attributeSet else {
          continue
        }
        for attribute in attributes.attributes
        where attribute === CircuitAttributes.nameAttribute {
          attributes.setReadOnly(attribute, true)
        }
      }
    }
    libraryList.append(library)
    fireEvent(.addLibrary, .library(library))
  }

  /// Java `removeLibrary(Library)`. Reference identity, and it *does* fire an event.
  public func removeLibrary(_ library: Library) {
    if let index = libraryList.firstIndex(where: { $0 === library }) {
      libraryList.remove(at: index)
    }
    fireEvent(.removeLibrary, .library(library))
  }

  /// Java `moveCircuit(AddTool, int)`.
  public func moveCircuit(_ tool: AddTool, to index: Int) {
    guard let oldIndex = addToolList.firstIndex(where: { $0 === tool }) else {
      addToolList.insert(tool, at: index)
      fireEvent(.addTool, .tool(tool))
      return
    }
    let value = addToolList.remove(at: oldIndex)
    addToolList.insert(value, at: index)
    fireEvent(.moveTool, .tool(tool))
  }

  /// Java `removeCircuit(Circuit)`.
  ///
  /// D13: upstream throws `RuntimeException("Cannot remove last circuit")`, which the Project
  /// layer catches; a trap would take the user's unsaved work with it.
  public func removeCircuit(_ circuit: Circuit) throws {
    if circuitCount <= 1 {
      throw LoadFailedError("Cannot remove last circuit")
    }
    let index = indexOfCircuit(circuit)
    guard index >= 0 else { return }
    let circuitTool = addToolList.remove(at: index)
    ownedCircuits.removeAll { $0 === circuit }
    if mainCircuitRef === circuit,
      let replacement = (addToolList[0].factory as? any SubcircuitFactory)?.subcircuit as? Circuit
    {
      setMainCircuit(replacement)
    }
    fireEvent(.removeTool, .tool(circuitTool))
  }

  /// Java `removeVhdl(VhdlContent)`.
  public func removeVhdl(_ content: any VhdlContentReference) {
    let index = indexOfVhdl(content)
    guard index >= 0 else { return }
    let vhdlTool = addToolList.remove(at: index)
    ownedVhdlContents.removeAll { $0 === content }
    fireEvent(.removeTool, .tool(vhdlTool))
  }

  /// Java `setMainCircuit(Circuit)`.
  public func setMainCircuit(_ circuit: Circuit?) {
    guard let circuit else { return }
    mainCircuitRef = circuit
    fireEvent(.setMain, .circuit(circuit))
  }

  /// Java `setName(String)`.
  public func setName(_ value: String) {
    fileName = value
    fireEvent(.setName, .name(value))
  }

  /// Java `setDirty(boolean)`.
  ///
  /// Note upstream's comment and the deliberate asymmetry: the autosave-dirty flag tracks the
  /// same transitions but has its own `if`, so a save clears both.
  public func setDirty(_ value: Bool) {
    if dirtyFlag != value {
      dirtyFlag = value
      fireEvent(.dirtyState, .dirty(value))
    }
    if autosaveDirtyFlag != value {
      autosaveDirtyFlag = value
    }
  }

  // MARK: Messages

  /// Java `addMessage(String)`.
  public func addMessage(_ message: String) {
    messageQueue.append(message)
  }

  /// Java `getMessage()`; destructive: it removes the message it returns. Named `takeMessage`
  /// so the destruction is visible at the call site; `Loader.showMessages` drains it in a loop.
  public func takeMessage() -> String? {
    messageQueue.isEmpty ? nil : messageQueue.removeFirst()
  }

  // MARK: Name checking

  /// `circuitChanged(CircuitEvent)`: upstream's `CircuitListener` implementation, which exists
  /// solely to answer `ACTION_CHECK_NAME`.
  ///
  /// The event's payload is the *old* name and `event.getCircuit().getName()` is the new one;
  /// `CircuitStaticAttributeListener` fires it after the rename has already been written, so
  /// rejecting means writing the old name back. That revert is model behaviour and is kept.
  ///
  /// The dialog is not: upstream calls `OptionPane.showMessageDialog`, and D9 keeps AppKit out
  /// of this layer, so the same text goes to `LoaderUI.showError`; the module's one seam for
  /// telling a human something. `HeadlessLoaderUI` records it.
  public func circuitChanged(_ event: CircuitEvent) {
    guard event.action == .checkName, case let .name(oldName) = event.data else { return }
    let newName = event.circuit.name
    guard circuitNameConflicts(newName, changed: event.circuit) else { return }
    loaderRef.ui.showError("\"\(newName)\": " + FileStrings.circuitNameExists)
    do {
      try event.circuit.staticAttributes.setValue(CircuitAttributes.nameAttribute, oldName)
    } catch {
      // D5/D13: `setValue` throws where Java's would raise `IllegalArgumentException` out of
      // the same call. `circuitChanged` cannot throw, it is a listener callback on both
      // sides, so the failure is reported rather than swallowed.
      loaderRef.ui.showError(String(describing: error))
    }
  }

  /// Java's private `isNameInUse(String, Circuit)`, made public because the revert above is not
  /// the only caller that wants it: the rename UI asks before proposing a name, too.
  public func circuitNameConflicts(_ name: String, changed: Circuit?) -> Bool {
    if name.isEmpty { return false }
    for library in libraryList where LogisimFile.isNameInLibraries(library, name) {
      return true
    }
    for circuit in circuits {
      if HdlNames.namesEqualForCurrentHdl(name, circuit.name), !(circuit === changed) {
        return true
      }
    }
    return false
  }

  /// Java's private `isNameInLibraries(Library, String)`.
  private static func isNameInLibraries(_ library: Library, _ name: String) -> Bool {
    if name.isEmpty { return false }
    for sub in library.libraries where isNameInLibraries(sub, name) { return true }
    for tool in library.tools
    where HdlNames.namesEqualForCurrentHdl(name, tool.name) {
      return true
    }
    return false
  }

  // MARK: Unloading

  /// Java `getUnloadLibraryMessage(Library)`; nil when the library can be unloaded safely.
  public func unloadLibraryMessage(_ library: Library) -> String? {
    var factories: [any ComponentFactory] = []
    for tool in library.tools {
      if let addTool = tool as? AddTool { factories.append(addTool.factory) }
    }

    for circuit in circuits {
      for component in circuit.nonWires {
        if factories.contains(where: { $0 === component.factory }) {
          return FileStrings.unloadUsedError(circuit.name)
        }
      }
    }

    let toolbar = optionsStorage.toolbarData
    let mappings = optionsStorage.mouseMappings
    for tool in library.tools {
      if toolbar.usesToolFromSource(tool) { return FileStrings.unloadToolbarError }
      if mappings.usesToolFromSource(tool) { return FileStrings.unloadMappingError }
    }

    return nil
  }

  /// The factory-usage query `LibraryManager.removeUnusedLibraries` needs: every factory
  /// actually placed in some circuit of this file.
  ///
  /// Upstream computes this inline in `removeUnusedLibraries` as `circ.getNonWires()` per
  /// circuit. It is a property here because `LibraryManager` treats nil as "I cannot tell" and
  /// refuses to run rather than deleting every library declaration; a file with no circuits at
  /// all is the one case where "nothing used" and "nothing known" are indistinguishable, and a
  /// `.circ` without a circuit is not a thing the writer can produce.
  public var usedFactories: [any ComponentFactory]? {
    var result: [any ComponentFactory] = []
    for circuit in circuits {
      for component in circuit.nonWires {
        if !result.contains(where: { $0 === component.factory }) {
          result.append(component.factory)
        }
      }
    }
    return circuits.isEmpty ? nil : result
  }

  // MARK: Autosave

  /// The body of upstream's `AutosaveThread.run()` loop, without the thread.
  ///
  /// Returns true when an autosave was written. `false` with `isAutosaveDirty` still set means
  /// the write failed, which upstream reports and then stops trying for the rest of the
  /// session: `autosaveStopped` records that.
  @discardableResult
  public func autosaveIfDirty() -> Bool {
    guard !autosaveStopped, autosaveDirtyFlag else { return false }
    if loaderRef.autosave(self) {
      autosaveDirtyFlag = false
      return true
    }
    loaderRef.showError(FileStrings.autosaveError(fileName))
    autosaveStopped = true
    return false
  }

  /// Java `interruptAutosaveThread()`; wakes the sleeping thread so it re-checks immediately.
  /// With no thread there is nothing to wake, and the next `autosaveIfDirty()` is the re-check.
  public func interruptAutosaveThread() {}

  /// Java `stopAutosaveThread(boolean delete)`.
  public func stopAutosaveThread(delete: Bool) {
    autosaveStopped = true
    if delete { loaderRef.deleteAutosave() }
  }

  // MARK: Writing

  /// Java's `write(OutputStream, LibraryLoader, File, String, boolean)` funnel.
  ///
  /// Upstream swallows every failure into `loader.showError` and returns void, so the caller
  /// cannot tell a written file from an unwritten one, which is the direct cause of the
  /// zero-length-file recovery dance in `Loader.save`. This returns nil on failure *and* still
  /// reports through `showError`, so the existing behaviour is intact and the caller gains the
  /// information it was missing.
  public func write(
    loader: any LibraryLoader,
    destination: URL? = nil,
    mainCircFile: String? = nil,
    recurse: Bool = false
  ) -> Data? {
    guard let writer = loaderRef.fileWriter else {
      loader.showError(FileStrings.xmlConversionError)
      return nil
    }
    do {
      return try writer.write(
        self, loader: loader, destination: destination, mainCircFile: mainCircFile,
        recurse: recurse)
    } catch {
      loader.showError(FileStrings.xmlConversionError + ": " + String(describing: error))
      return nil
    }
  }

  // MARK: Events

  public func addLibraryListener(_ listener: LibraryListener) {
    listeners.add(listener)
  }

  public func removeLibraryListener(_ listener: LibraryListener) {
    listeners.remove(listener)
  }

  private func fireEvent(_ action: LibraryEventAction, _ data: LibraryEventData) {
    let event = LibraryEvent(source: self, action: action, data: data)
    for listener in listeners.current() { listener.libraryChanged(event) }
  }
}

/// Placeholder kept from the M0 module skeleton so its smoke test still means something.
public enum LogisimFileModule {
  public static let name = "LogisimFile"
}
