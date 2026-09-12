// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.LibraryManager: the process-wide cache that maps a
// library descriptor to the single `LoadedLibrary` representing it, and back again.

import Foundation
import LogisimKernel

/// The descriptor of an *external* library; the two forms that name something outside the
/// application. Builtins are not represented here: upstream derives their descriptor straight
/// from `"#" + lib.getName()` and never caches them, because each `Loader` owns its own
/// `Builtin` instance.
struct LibraryDescriptor: Hashable {
  enum Kind: Hashable {
    case logisimProject
    case jar(className: String)
  }

  let kind: Kind
  /// Java keys on `File`, whose `equals` is a plain path-string comparison: no
  /// canonicalisation, no symlink resolution. Keying on the path string reproduces that
  /// exactly, including the consequence that `/a/b.circ` and `/a/./b.circ` are different keys.
  let path: String

  func concernsFile(_ query: URL) -> Bool { path == query.path }

  var url: URL { URL(fileURLWithPath: path) }

  /// Java `toDescriptor(Loader)`.
  func toDescriptor(_ loader: Loader) throws -> String {
    let relative = try LibraryManager.toRelative(loader, url)
    switch kind {
    case .logisimProject:
      return "file#" + relative
    case .jar(let className):
      return "jar#" + relative + String(LibraryManager.descriptorSeparator) + className
    }
  }
}

public final class LibraryManager {
  public static let instance = LibraryManager()

  public static let descriptorSeparator: Character = "#"

  private final class WeakLibrary {
    weak var value: LoadedLibrary?
    init(_ value: LoadedLibrary) { self.value = value }
  }

  private struct InverseEntry {
    let box: WeakLibrary
    let descriptor: LibraryDescriptor
  }

  /// Java's `HashMap<LibraryDescriptor, WeakReference<LoadedLibrary>>`.
  private var fileMap: [LibraryDescriptor: WeakLibrary] = [:]

  /// Java's `WeakHashMap<LoadedLibrary, LibraryDescriptor>`.
  ///
  /// D3 explicitly forbids the mechanical translation to `NSMapTable.weakToStrongObjects()`:
  /// it compiles, looks right, and leaks, because under ARC the keys stay pinned by the very
  /// cycles the weak map exists to escape. Each such site needs a named eviction owner. Here
  /// it is `purge()`, run at the top of every entry point. The map holds a handful of entries
  /// , one per open external library, so the linear scan costs nothing and, unlike a hash on
  /// object identity, it cannot resurrect a deallocated key.
  private var inverseMap: [InverseEntry] = []

  private init() {
    // Java also calls `ProjectsDirty.initialize()` here, which subscribes the manager to
    // project dirty-state changes so an edited library file marks its wrapper dirty. That is
    // Project-layer wiring (M7); `setDirty(file:dirty:)` below is the hook it will call.
  }

  private func purge() {
    inverseMap.removeAll { $0.box.value == nil }
    for (key, box) in fileMap where box.value == nil { fileMap.removeValue(forKey: key) }
  }

  // MARK: - Relative paths

  /// Java `toRelative(Loader, File)`: expresses `file` relative to the loader's current
  /// directory, so a saved `.circ` refers to its libraries portably.
  ///
  /// Faithful to upstream including its edge cases: the comparison walks path components and
  /// stops one short on the file side (the last component is the file name), and the result is
  /// joined with the platform separator.
  ///
  /// **D16: this method canonicalises ONE side, deliberately.** 4.1.0 reads:
  ///
  /// ```java
  /// var fileName = file.toString();
  /// try { fileName = file.getCanonicalPath(); } catch (IOException e) { }
  /// if (currentDirectory != null) {
  ///   final var currentParts = currentDirectory.toString().split(Pattern.quote(File.separator));
  ///   //                       ^^^^^^^^^^^^^^^^^^^^^^^^^^ RAW, not canonical
  /// ```
  ///
  /// 4.2.0-dev changed the directory side to `getCanonicalPath()`. An earlier revision of this
  /// port followed main and resolved **both** sides, which is neither version's behaviour and
  /// rewrites `<lib desc="file#…">` whenever the project is reached through a symlink. On macOS
  /// `/tmp`, `/var` and therefore every `$TMPDIR` are symlinks into `/private`, so that is the
  /// common case rather than an edge case. Driven through the shipped jar's own private
  /// `toRelative` (`tools/m2audit/RelativeBridge.java`), with `<current dir>` / `<library file>`:
  ///
  /// | current directory | 4.1.0 jar | both-sides-resolved |
  /// |---|---|---|
  /// | `/tmp/m2audit/proj` | `../../../private/tmp/m2audit/proj/libs/helper.circ` | `libs/helper.circ` |
  /// | `/private/tmp/m2audit/proj` | `libs/helper.circ` | `libs/helper.circ` |
  /// | `/Users/me/link/proj` (symlink) | `../../m2audit_real/proj/libs/helper.circ` | `libs/helper.circ` |
  ///
  /// The string is written verbatim into `<lib desc="file#…">`, so it is codec output.
  /// `Loader.currentDirectory` must stay raw for the same reason: normalising it there undoes
  /// this one layer down.
  static func toRelative(_ loader: Loader, _ file: URL) throws -> String {
    // Java's `getCanonicalPath` throws IOException, and upstream keeps `file.toString()` when
    // it does; `javaCanonicalPath` returns nil in exactly that case.
    let fileName = javaCanonicalPath(file.path) ?? file.path

    if let currentDirectory = loader.currentDirectory {
      let currentDirectoryPath = currentDirectory.path

      let currentParts = javaSplitOnLiteral(currentDirectoryPath, separator: "/")
      let newParts = javaSplitOnLiteral(fileName, separator: "/")
      let newPartCount = newParts.count

      // Note the file side includes the file name while the directory side does not, hence the
      // `newPartCount - 1` bound.
      var equalParts = 0
      while equalParts < currentParts.count, equalParts < newPartCount - 1,
        currentParts[equalParts] == newParts[equalParts]
      {
        equalParts += 1
      }

      let levelsDown = currentParts.count - equalParts
      var relative = String(repeating: "../", count: max(0, levelsDown))
      for index in equalParts..<newPartCount {
        relative += newParts[index]
        if index < newPartCount - 1 { relative += "/" }
      }
      return relative
    }
    return fileName
  }

  // MARK: - `File.getCanonicalPath()`

  /// Java `File.getCanonicalPath()`, reproduced. Returns nil where Java throws `IOException`.
  ///
  /// **Do not replace this with `resolvingSymlinksInPath()`.** Foundation's method deliberately
  /// declines to resolve `/tmp` and `/var`, Apple treats them as stable aliases, and those are
  /// precisely the paths that make the D16 `toRelative` divergence visible. It is also not
  /// `realpath(3)` alone: `realpath` fails outright on a path whose leaf does not exist yet,
  /// which is every *save-as* target.
  ///
  /// The JDK's `canonicalize()` (`canonicalize_md.c`, reached from `UnixFileSystem`) is:
  ///
  /// 1. `File.normalize`; collapse duplicate separators and drop a trailing one. This happens
  ///    in the `File` constructor, before `getCanonicalPath` is ever called.
  /// 2. `fs.resolve`; make absolute against `user.dir` if the path is relative.
  /// 3. `realpath(3)` on the whole path. If that succeeds, done.
  /// 4. Otherwise strip trailing components one at a time and `realpath` each prefix; on the
  ///    first that resolves, re-append the untouched remainder, taking care not to double the
  ///    separator when the resolved prefix is `/`. The root is never itself `realpath`ed; the
  ///    loop stops one component short.
  /// 5. `collapse()` the result: remove `.`, and remove each `..` together with the nearest
  ///    surviving name before it. A `..` with no name before it is left in place, and a path of
  ///    fewer than two name components is not collapsed at all.
  ///
  /// So symlinks resolve for the components that exist and the rest is normalised lexically.
  ///
  /// **Every branch here is pinned to measured jar output**, not to a reading of the C. Two
  /// derivations from the source were wrong on first attempt and the oracle caught both:
  /// `/..` canonicalises to `/` (because `realpath` succeeds on it outright, so `collapse`
  /// never sees the `..`), and `/../nonexistent` gives `/nonexistent` rather than
  /// `//nonexistent` (step 4's duplicate-separator guard). Regenerate the rows with
  /// `tools/m2audit/canonprobe.sh`.
  static func javaCanonicalPath(_ rawPath: String) -> String? {
    // 1 + 2. `new File(path)` normalises, then `fs.resolve` absolutises against `user.dir`,
    //        which is initialised from the process working directory.
    //
    // NB `XmlWriter.javaAbsolutePath` is the *other* Java method, `getAbsolutePath`, and stops
    // right here on purpose: it does no realpath and no `.`/`..` collapse, because the
    // `filePath` attribute it feeds must not be normalised. The two are deliberately
    // different, not a duplicated helper that drifted.
    var path = javaFileNormalize(rawPath)
    if !path.hasPrefix("/") {
      let cwd = FileManager.default.currentDirectoryPath
      path = cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
    }

    // 3. The whole path.
    if let resolved = realpathOrNil(path).resolved { return collapseDotSegments(resolved) }

    // 4. The longest resolvable prefix, then the untouched remainder.
    let bytes = Array(path.utf8)
    let slash = UInt8(ascii: "/")
    var end = bytes.count
    while end > 0 {
      var cut = end - 1
      while cut > 0, bytes[cut] != slash { cut -= 1 }
      // `cut == 0` means only the root is left. The C loop breaks here rather than calling
      // realpath(""), so a path whose very first component does not exist stays as written.
      if cut == 0 { break }
      let attempt = realpathOrNil(String(decoding: bytes[0..<cut], as: UTF8.self))
      if let resolved = attempt.resolved {
        var tail = String(decoding: bytes[cut...], as: UTF8.self)
        // "Avoid duplicate slashes": only reachable when the prefix resolved to `/` itself.
        if resolved.hasSuffix("/"), tail.hasPrefix("/") { tail.removeFirst() }
        return collapseDotSegments(resolved + tail)
      }
      if let code = attempt.errorCode, code != ENOENT, code != ENOTDIR, code != EACCES {
        // Anything else is the `return -1` branch, which surfaces as IOException, which
        // `toRelative` catches and answers with the raw `file.toString()`.
        return nil
      }
      end = cut
    }

    // 5. Nothing resolved; Java keeps the (absolute, un-resolved) path and collapses it.
    return collapseDotSegments(path)
  }

  /// Java `UnixFileSystem.normalize(String)`, applied by the `File` constructor: duplicate
  /// separators collapse, a trailing separator is dropped, and nothing else changes, in
  /// particular `.` and `..` survive this step untouched.
  private static func javaFileNormalize(_ path: String) -> String {
    guard path.contains("//") || (path.count > 1 && path.hasSuffix("/")) else { return path }
    var out = ""
    var previousWasSlash = false
    for character in path {
      if character == "/" {
        if previousWasSlash { continue }
        previousWasSlash = true
      } else {
        previousWasSlash = false
      }
      out.append(character)
    }
    if out.count > 1, out.hasSuffix("/") { out.removeLast() }
    return out
  }

  /// `realpath(3)`, with the `errno` the caller needs to tell "this component does not exist"
  /// (keep walking) from a real I/O failure (give up, which Java reports as `IOException`).
  /// Returned rather than stashed in a static: `LibraryManager` is a process-wide singleton, so
  /// a shared `lastErrno` would be a data race the moment two loaders save at once.
  private static func realpathOrNil(_ path: String) -> (resolved: String?, errorCode: Int32?) {
    errno = 0
    guard let buffer = realpath(path, nil) else { return (nil, errno) }
    defer { free(buffer) }
    return (String(cString: buffer), nil)
  }

  /// The JDK's `collapse()`. Two quirks, both reproduced: a leading `..` that has no name to
  /// consume survives, and a path with fewer than two name components is returned untouched.
  ///
  /// Neither is observable through `javaCanonicalPath` on a path whose prefix exists, because
  /// `realpath` has already resolved the `..` by the time this runs: `/..` canonicalises to
  /// `/`, not to `/..`. They matter only on the step-5 fallback, where nothing resolved.
  private static func collapseDotSegments(_ path: String) -> String {
    let absolute = path.hasPrefix("/")
    let body = absolute ? String(path.dropFirst()) : path
    var names = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // `realpath` output and `File.normalize`d input both lack duplicate and trailing
    // separators; a trailing one would otherwise show up here as an empty final name.
    while let last = names.last, last.isEmpty, names.count > 1 { names.removeLast() }

    guard names.count >= 2, names.contains(where: { $0 == "." || $0 == ".." }) else {
      return path
    }

    var kept: [String?] = names
    var index = 0
    while index < kept.count {
      guard let name = kept[index] else { index += 1; continue }
      if name == "." {
        kept[index] = nil
      } else if name == ".." {
        var previous = index - 1
        while previous >= 0, kept[previous] == nil { previous -= 1 }
        if previous >= 0 {
          kept[previous] = nil
          kept[index] = nil
        }
        // else: no preceding name, so the `..` is left exactly as it is.
      }
      index += 1
    }

    let joined = kept.compactMap { $0 }.joined(separator: "/")
    if absolute { return "/" + joined }
    return joined
  }

  // D15a: the local `javaSplit` that used to live here was a hand-rolled sixth copy of Java's
  // `String.split` and, like the others, it was missing the empty-input case (Java returns
  // `[""]`, because the pattern never matches, while a bare trailing-empty trim returns `[]`).
  // `toRelative` never sees an empty path so nothing observable changed, but two
  // implementations of one semantic disagreeing is the defect pattern D15a exists to stop, so
  // it now calls `javaSplitOnLiteral` (XmlReaderSupport.swift), which is pinned by
  // JavaSplitOnLiteralTests against the jar's measured output.

  // MARK: - Lookup

  private func findKnown(_ descriptor: LibraryDescriptor) -> LoadedLibrary? {
    guard let box = fileMap[descriptor] else { return nil }
    guard let library = box.value else {
      fileMap.removeValue(forKey: descriptor)
      return nil
    }
    return library
  }

  private func findKnown(file: URL) -> LoadedLibrary? {
    // Java 4.1.0 passes a File to a map keyed by LibraryDescriptor, so this always misses.
    nil
  }

  private func descriptor(of library: LoadedLibrary) -> LibraryDescriptor? {
    inverseMap.first { $0.box.value === library }?.descriptor
  }

  private func remember(_ library: LoadedLibrary, as descriptor: LibraryDescriptor) {
    let box = WeakLibrary(library)
    fileMap[descriptor] = box
    inverseMap.append(InverseEntry(box: box, descriptor: descriptor))
  }

  // MARK: - Descriptors

  /// Java `getDescriptor(Loader, Library)`, reached through `Loader.getDescriptor`.
  ///
  /// Throws where Java throws `LoaderException`; a library the manager has never seen. D13:
  /// the writer catches it and reports "library location unknown" rather than dying.
  public func descriptor(_ loader: Loader, for library: Library) throws -> String {
    purge()
    // D8: a library we could not resolve reports the descriptor it arrived with, verbatim.
    // No path recomputation, no canonicalisation; that is the whole round-trip guarantee.
    if let missing = library as? MissingLibrary { return missing.descriptorText }
    if loader.builtin.containsLibrary(library) {
      return String(LibraryManager.descriptorSeparator) + library.name
    }
    guard let loaded = library as? LoadedLibrary, let descriptor = descriptor(of: loaded) else {
      throw LoaderError(FileStrings.fileDescriptorUnknownError(library.displayName))
    }
    return try descriptor.toDescriptor(loader)
  }

  /// Java `getBuildinNames(Loader)` (upstream's spelling).
  public static func builtinNames(_ loader: Loader) -> Set<String> {
    loader.builtin.libraryNames
  }

  /// Java `isJarLibrary(Loader, String)`.
  public static func isJarLibrary(_ loader: Loader, desc: String) -> Bool {
    guard let separator = desc.firstIndex(of: descriptorSeparator) else {
      loader.showError(FileStrings.fileDescriptorError(desc))
      return false
    }
    return desc[..<separator] == "jar"
  }

  /// Java `getLibraryFilePath(Loader, String)`.
  public static func libraryFilePath(_ loader: Loader, desc: String) throws -> String? {
    guard let separator = desc.firstIndex(of: descriptorSeparator) else {
      loader.showError(FileStrings.fileDescriptorError(desc))
      return nil
    }
    let type = String(desc[..<separator])
    let name = String(desc[desc.index(after: separator)...])
    switch type {
    case "file":
      return try loader.fileFor(name, kind: .logisim).path
    case "jar":
      guard let jarSeparator = name.lastIndex(of: descriptorSeparator) else { return nil }
      return try loader.fileFor(String(name[..<jarSeparator]), kind: .jar).path
    default:
      return nil
    }
  }

  /// Java `getReplacementDescriptor(Loader, String, String)`; used when exporting a project
  /// bundle, to point a descriptor at the copy inside the archive.
  public static func replacementDescriptor(
    _ loader: Loader, desc: String, fileName: String
  ) -> String? {
    guard let separator = desc.firstIndex(of: descriptorSeparator) else {
      loader.showError(FileStrings.fileDescriptorError(desc))
      return nil
    }
    let type = String(desc[..<separator])
    let name = String(desc[desc.index(after: separator)...])
    switch type {
    case "file":
      return "file#\(fileName)"
    case "jar":
      guard let jarSeparator = name.lastIndex(of: descriptorSeparator) else { return nil }
      let className = String(name[name.index(after: jarSeparator)...])
      return "jar#\(fileName)#\(className)"
    default:
      return nil
    }
  }

  // MARK: - Loading

  /// Java `loadLibrary(Loader, String)`: the entry point for every `<lib desc="…">`.
  ///
  /// D8 deviation, and the reason it matters: upstream returns null from every failure branch
  /// below, after which XmlReader drops every component that referenced the library and the
  /// next save writes the file back without them. Here each failure produces a `MissingLibrary`
  /// that remembers the descriptor verbatim, so the declaration and its components survive
  /// load → save. The error is still reported through `showError`, exactly as upstream: the
  /// user learns the same thing, they just do not lose the data.
  public func loadLibrary(_ loader: Loader, desc: String) -> Library {
    purge()
    guard let separator = desc.firstIndex(of: LibraryManager.descriptorSeparator) else {
      loader.showError(FileStrings.fileDescriptorError(desc))
      return MissingLibrary(descriptor: desc, reason: .malformedDescriptor)
    }
    let type = String(desc[..<separator])
    let name = String(desc[desc.index(after: separator)...])

    switch type {
    case "":
      if let builtin = loader.builtin.library(named: name) { return builtin }
      loader.showError(FileStrings.fileBuiltinMissingError(name))
      return MissingLibrary(descriptor: desc, reason: .builtinUnavailable(name: name))

    case "file":
      do {
        let toRead = try loader.fileFor(name, kind: .logisim)
        if let loaded = loadLogisimLibrary(loader, file: toRead) { return loaded }
        return MissingLibrary(
          descriptor: desc,
          reason: .fileUnavailable(path: name, detail: "library could not be loaded"))
      } catch let error as LoaderError {
        if !error.isShown { loader.showError(error.message) }
        return MissingLibrary(
          descriptor: desc, reason: .fileUnavailable(path: name, detail: error.message))
      } catch {
        loader.showError(String(describing: error))
        return MissingLibrary(
          descriptor: desc,
          reason: .fileUnavailable(path: name, detail: String(describing: error)))
      }

    case "jar":
      // D11: a permanent functional gap. Upstream resolves this with `ZipClassLoader` +
      // `Class.forName` + reflective instantiation; no AOT-Swift equivalent exists, and none
      // is going to appear. Note we do not even ask for the JAR file: prompting the user to
      // locate a file we could not use either way would be theatre. Route straight to D8's
      // opaque path so the components survive.
      let jarSeparator = name.lastIndex(of: LibraryManager.descriptorSeparator)
      let fileName = jarSeparator.map { String(name[..<$0]) } ?? name
      let className = jarSeparator.map { String(name[name.index(after: $0)...]) } ?? ""
      loader.showError(FileStrings.jarLibraryUnsupported(fileName, className))
      return MissingLibrary(
        descriptor: desc, reason: .jarUnsupported(file: fileName, className: className))

    default:
      loader.showError(FileStrings.fileTypeError(type, desc))
      return MissingLibrary(descriptor: desc, reason: .unrecognizedType(type))
    }
  }

  /// Java `loadLogisimLibrary(Loader, File)`.
  public func loadLogisimLibrary(_ loader: Loader, file toRead: URL) -> LoadedLibrary? {
    purge()
    let descriptor = LibraryDescriptor(kind: .logisimProject, path: toRead.path)
    if let known = findKnown(file: toRead) { return known }

    let loaded: LoadedLibrary
    do {
      guard let base = try loader.loadLogisimFile(toRead) else {
        loader.showError(
          FileStrings.logisimLoadError(
            Loader.projectName(of: toRead), "file could not be opened"))
        return nil
      }
      loaded = LoadedLibrary(base: base)
    } catch let error as LoadFailedError {
      if !error.isShown { loader.showError(error.message) }
      return nil
    } catch let error as LoaderError {
      if !error.isShown { loader.showError(error.message) }
      return nil
    } catch {
      loader.showError(String(describing: error))
      return nil
    }

    remember(loaded, as: descriptor)
    return loaded
  }

  /// Java `loadJarLibrary(Loader, File, String)`.
  ///
  /// D11: kept so the call site exists and is honestly answered, but it can only ever report
  /// the gap. `loadLibrary` does not route through here, it goes straight to the D8
  /// placeholder, so this is reachable only from an explicit "load JAR library" command.
  public func loadJarLibrary(
    _ loader: Loader, file toRead: URL, className: String
  ) -> LoadedLibrary? {
    purge()
    loader.showError(FileStrings.jarLibraryUnsupported(toRead.lastPathComponent, className))
    return nil
  }

  /// Java `reload(Loader, LoadedLibrary)`.
  public func reload(_ loader: Loader, library: LoadedLibrary) {
    purge()
    guard let descriptor = descriptor(of: library) else {
      loader.showError(FileStrings.unknownLibraryFileError(library.displayName))
      return
    }
    do {
      switch descriptor.kind {
      case .logisimProject:
        guard let base = try loader.loadLogisimFile(descriptor.url) else {
          throw LoadFailedError(
            FileStrings.logisimLoadError(
              Loader.projectName(of: descriptor.url), "file could not be opened"))
        }
        library.setBase(base)
      case .jar(let className):
        // D11 again: there is no way to rebuild a JAR-backed library.
        throw LoadFailedError(
          FileStrings.jarLibraryUnsupported(descriptor.url.lastPathComponent, className))
      }
    } catch let error as LoadFailedError {
      if !error.isShown { loader.showError(error.message) }
    } catch let error as LoaderError {
      if !error.isShown { loader.showError(error.message) }
    } catch {
      loader.showError(String(describing: error))
    }
  }

  // MARK: - Save-time bookkeeping

  /// Java `fileSaved(Loader, File dest, File oldFile, LogisimFile file)`.
  public func fileSaved(
    _ loader: Loader, destination: URL, oldFile: URL?, file: LogisimFile
  ) {
    purge()
    if let oldFile, let old = findKnown(file: oldFile) {
      old.setDirty(false)
    }
    guard let library = findKnown(file: destination) else { return }
    guard let clone = file.cloneLogisimFile(loader) else { return }
    clone.setName(file.name)
    clone.setDirty(false)
    library.setBase(clone)
  }

  /// Java `findReference(LogisimFile, File)`; refuses a save that would make a file include
  /// itself through some chain of `file#` libraries.
  public func findReference(in file: LogisimFile, query: URL) -> Library? {
    purge()
    for library in file.libraries {
      if let loaded = library as? LoadedLibrary,
        let descriptor = descriptor(of: loaded),
        descriptor.concernsFile(query)
      {
        return library
      }
      if let loaded = library as? LoadedLibrary,
        let nested = loaded.base as? LogisimFile,
        findReference(in: nested, query: query) != nil
      {
        return library
      }
    }
    return nil
  }

  /// Java's package-private `setDirty(File, boolean)`; the hook `ProjectsDirty` drives.
  public func setDirty(file: URL, dirty: Bool) {
    purge()
    findKnown(file: file)?.setDirty(dirty)
  }

  /// Java `getLogisimLibraries()`.
  public func logisimLibraries() -> [LogisimFile] {
    purge()
    return inverseMap.compactMap { $0.box.value?.base as? LogisimFile }
  }

  // MARK: - Library pruning

  /// Java `removeUnusedLibraries(Library)`; drops declared-but-unused libraries before an
  /// export.
  ///
  /// Requires walking each circuit's components, which is Circuit-layer state this milestone
  /// does not model; the walk is expressed through `LogisimFile.usedFactories`, which the
  /// Circuit port supplies. With no supplier installed it reports nothing used, so this
  /// method would remove everything, which is why it refuses to run at all in that case
  /// rather than quietly destroying a file's library list.
  public static func removeUnusedLibraries(_ library: Library) {
    var logisimLibrary: LogisimFile?
    if let loaded = library as? LoadedLibrary, let file = loaded.base as? LogisimFile {
      logisimLibrary = file
    } else if let file = library as? LogisimFile {
      logisimLibrary = file
    }
    guard let file = logisimLibrary else { return }
    guard let used = file.usedFactories else { return }

    var toRemove: [String] = []
    for candidate in file.libraries {
      let isUsed = used.contains { candidate.contains($0) }
      if isUsed {
        removeUnusedLibraries(candidate)
      } else {
        toRemove.append(candidate.name)
      }
    }
    for name in toRemove { library.removeLibrary(named: name) }
  }

  /// Java `getUsedBaseLibraries(Library)`.
  public static func usedBaseLibraries(_ library: Library) -> Set<String> {
    var result = Set<String>()
    for sub in library.libraries {
      result.formUnion(usedBaseLibraries(sub))
      if !(sub is LoadedLibrary) && !(sub is LogisimFile) {
        result.insert(sub.name)
      }
    }
    return result
  }

  /// Java `removeBaseLibraries(Library, Set<String>)`.
  public static func removeBaseLibraries(_ library: Library, baseLibraries: Set<String>) {
    for sub in library.libraries {
      if baseLibraries.contains(sub.name) {
        library.removeLibrary(named: sub.name)
      } else {
        removeBaseLibraries(sub, baseLibraries: baseLibraries)
      }
    }
  }
}
