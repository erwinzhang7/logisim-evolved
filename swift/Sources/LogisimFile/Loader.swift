// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.Loader and com.cburch.logisim.file.LibraryLoader.

import Foundation
import LogisimKernel

// MARK: - LibraryLoader

/// `com.cburch.logisim.file.LibraryLoader`.
public protocol LibraryLoader: AnyObject {
  /// Java `getDescriptor(Library)`. Throws where Java throws `LoaderException` (D13).
  func descriptor(for library: Library) throws -> String
  /// Java `loadLibrary(String)`.
  func loadLibrary(desc: String) -> Library
  /// Java `showError(String)`.
  func showError(_ description: String)
}

// MARK: - Host seams

/// The kinds of file the loader asks the host to locate. Upstream these are Swing
/// `FileFilter` subclasses; the file layer only ever needs to say *what* it is looking for.
public enum LoaderFileKind {
  case logisim
  case logisimBundle
  case jar
  case text
  case tcl
  case vhdl
  case directory
}

/// What to do about an autosave sitting next to the file being opened.
///
/// Upstream offers "load" and "discard" (and treats a closed dialog as "abandon the open").
/// `ignore` has no upstream counterpart and is a deliberate addition: headless operation has
/// nobody to ask, and both upstream answers are destructive: "discard" deletes the user's
/// autosave, "load" silently opens different bytes than the ones named on the command line.
/// A headless run therefore opens exactly the file it was given and leaves the autosave alone.
public enum AutosaveDisposition {
  case load
  case discard
  case ignore
  case cancel
}

/// Everything `Loader` needs from a human. Upstream these are `OptionPane` and `JFileChooser`
/// calls made directly from `Loader`; D9 keeps AppKit out of this layer, so they are a
/// protocol the app shell implements at M8.
public protocol LoaderUI: AnyObject {
  func showError(_ description: String)
  func showMessage(_ message: String)
  func autosaveDisposition(for file: URL, autosave: URL) -> AutosaveDisposition
  /// Upstream's "the required library file is missing, please pick it" dialog. Returning nil
  /// is the cancel case, which upstream turns into a `LoaderException`.
  func chooseFile(prompt: String, kind: LoaderFileKind, startingAt: URL?) -> URL?
}

/// The headless implementation used by `logisim-cli` and the differential rig.
///
/// It records rather than displays, never deletes an autosave, and cancels every chooser,
/// which reproduces upstream's behaviour when a user dismisses the "locate this library"
/// dialog, i.e. a `LoaderException` naming the file.
public final class HeadlessLoaderUI: LoaderUI {
  public private(set) var errors: [String] = []
  public private(set) var messages: [String] = []

  public init() {}

  public func showError(_ description: String) { errors.append(description) }
  public func showMessage(_ message: String) { messages.append(message) }

  public func autosaveDisposition(for file: URL, autosave: URL) -> AutosaveDisposition {
    .ignore
  }

  public func chooseFile(prompt: String, kind: LoaderFileKind, startingAt: URL?) -> URL? {
    nil
  }

  public func reset() {
    errors.removeAll()
    messages.removeAll()
  }
}

/// The XmlReader seam. `XmlReader` itself, the DOM walk and every `considerRepairs`
/// migration pass, is a separate port; `Loader` only needs to be able to invoke it.
public protocol LogisimFileReading: AnyObject {
  /// Java `XmlReader(loader, file).readLibrary(inputStream, project)`.
  func readLibrary(_ data: Data, loader: Loader, sourceFile: URL?) throws -> LogisimFile
}

/// The XmlWriter seam, likewise.
public protocol LogisimFileWriting: AnyObject {
  /// Java `XmlWriter.write(file, out, loader, dest, mainCircFile, recurse)`.
  func write(
    _ file: LogisimFile,
    loader: any LibraryLoader,
    destination: URL?,
    mainCircFile: String?,
    recurse: Bool
  ) throws -> Data
}

// MARK: - Loader

/// `com.cburch.logisim.file.Loader`.
public final class Loader: LibraryLoader {
  public static let logisimExtension = ".circ"
  public static let logisimProjectBundleExtension = ".lsebdl"
  public static let logisimProjectBundleInfoFile = "LogisimEvolutionBundle.info"
  public static let logisimLibraryDirectory = "library"
  public static let logisimCircuitDirectory = "circuit"
  public static let logisimUnnamedAutosavePrefix = ".logisim-unnamed-autosave_"
  public static let logisimUnnamedAutosaveSuffix = ".circ.autosave"

  /// Java's `Component parent`: the dialog owner. Replaced by the `LoaderUI` seam.
  public var ui: LoaderUI

  /// Java's `private final Builtin builtin = new Builtin()`: one per loader, so two loaders
  /// never share builtin library object identity. Preserved, because `getDescriptor` decides
  /// "is this a builtin" by reference identity against this instance's list.
  public let builtin = Builtin()

  /// The reader/writer seams, defaulted to the real implementations.
  ///
  /// These stay injectable (upstream has no such seam; it calls `XmlReader`/`XmlWriter`
  /// directly), but they default to `XmlFileReader`/`XmlFileWriter` because a `Loader` that
  /// cannot read a `.circ` is not a useful default; leaving them nil made every load fail
  /// with "no .circ reader is installed on this loader", which reads like a corrupt file
  /// rather than an unwired object.
  public var fileReader: (any LogisimFileReading)? = XmlFileReader()
  public var fileWriter: (any LogisimFileWriting)? = XmlFileWriter()

  private var mainFileURL: URL?
  private var autosaveFileURL: URL?
  /// Java's `Stack<File> filesOpening`: the cycle detector and the error-message prefix.
  private var filesOpening: [URL] = []
  private var substitutions: [String: URL] = [:]

  public init(ui: LoaderUI = HeadlessLoaderUI()) {
    self.ui = ui
    clear()
  }

  // MARK: State

  /// Java `clear()`.
  public func clear() {
    filesOpening.removeAll()
    mainFileURL = nil
  }

  public var mainFile: URL? { mainFileURL }

  /// Java `getCurrentDirectory()`: the directory relative paths resolve against.
  public var currentDirectory: URL? {
    let reference = filesOpening.last ?? mainFileURL
    guard let reference else { return nil }
    let parent = reference.deletingLastPathComponent()
    // Java `getParentFile()` returns null when there is no parent; a URL always has one, so
    // the degenerate "/" case is normalised back to nil to match.
    return parent.path == reference.path ? nil : parent
  }

  /// Java `private void setMainFile(File)`; internal rather than private only so the D16
  /// `toRelative` suite can position a loader without opening a real project. Upstream's own
  /// oracle harness (`tools/m2audit/RelativeBridge.java`) reaches it reflectively for exactly
  /// the same reason; there is no other way to set a current directory.
  ///
  /// **The stored URL must stay raw.** `toRelative` compares the *unresolved*
  /// `currentDirectory` against a canonicalised file path, which is 4.1.0's behaviour and the
  /// whole point of that method; normalising here would undo it one layer down.
  func setMainFile(_ value: URL?) { mainFileURL = value }

  // MARK: Name helpers

  /// Java `toProjectName(File)`; the file name with `.circ` stripped.
  ///
  /// **`precomposedStringWithCanonicalMapping` is not cosmetic; it is what makes this match the
  /// jar on macOS.** APFS returns filenames DECOMPOSED (NFD): `й` comes back as `и` + U+0306,
  /// not as U+0439. Java's macOS `sun.nio.fs` provider composes to NFC when it turns a path into
  /// a `String`; Foundation hands back the raw bytes. So for any file whose name carries a
  /// composable character, the port's project name was byte-different from Java's while being
  /// visually identical; the two strings render the same and compare unequal.
  ///
  /// That was six of the `-tty stats` gate's failures, in two files, and they read as a diff with
  /// no visible change:
  ///
  ///     - 8   8  sum   Цифровой проект 8b
  ///     + 8   8  sum   Цифровой проект 8b
  ///
  /// Measured: the two lines compare unequal as-is and equal after normalising both to NFC. The
  /// counts and the column formatting were right all along; only the name's encoding differed.
  ///
  /// Normalising HERE rather than at the comparison is deliberate. This function is where a
  /// filesystem name becomes a *model* string: it feeds the project name, the statistics table's
  /// library column, and anything else that displays or serialises it. Fixing it in the gate would
  /// have left the app itself writing NFD into files that Java reads back as something else.
  public static func projectName(of file: URL) -> String {
    let name = file.lastPathComponent.precomposedStringWithCanonicalMapping
    guard name.hasSuffix(logisimExtension) else { return name }
    return String(name.dropLast(logisimExtension.count))
  }

  /// Java `determineBackupName(File)`: `name.bak`, then `.bak2` … `.bak20`, or nil if all
  /// twenty are taken.
  static func determineBackupName(_ base: URL) -> URL? {
    let directory = base.deletingLastPathComponent()
    var name = base.lastPathComponent
    if name.hasSuffix(logisimExtension) {
      name = String(name.dropLast(logisimExtension.count))
    }
    for index in 1...20 {
      let ext = index == 1 ? ".bak" : ".bak\(index)"
      let candidate = directory.appendingPathComponent(name + ext)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// Java `determineAutosaveName(File)`: `.<name>.circ.autosave` beside the file, or a
  /// timestamped file in the home directory when there is no file yet.
  static func determineAutosaveName(_ base: URL?) -> URL? {
    guard let base else {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone.current
      formatter.dateFormat = "yyyyMMddHHmmss"
      let timestamp = formatter.string(from: Date())
      let candidate = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(
          logisimUnnamedAutosavePrefix + timestamp + logisimUnnamedAutosaveSuffix)
      return FileManager.default.fileExists(atPath: candidate.path) ? nil : candidate
    }
    let ext = base.lastPathComponent.hasSuffix(logisimExtension) ? ".autosave" : ".circ.autosave"
    return base.deletingLastPathComponent()
      .appendingPathComponent("." + base.lastPathComponent + ext)
  }

  /// Java `findAutosaveFile(File)`.
  public static func findAutosaveFile(_ base: URL) -> URL? {
    guard let candidate = determineAutosaveName(base) else { return nil }
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
  }

  public func setAutosavePath(_ file: URL) { autosaveFileURL = file }

  // MARK: Substitutions

  private func substitution(for source: URL) -> URL {
    substitutions[source.path] ?? source
  }

  // MARK: File resolution

  /// Java `getFileFor(String, FileFilter)`.
  ///
  /// Loops asking the user to locate the file until one is readable, exactly as upstream;
  /// declining throws, which is upstream's `LoaderException(fileLoadCanceledError)`.
  public func fileFor(_ name: String, kind: LoaderFileKind) throws -> URL {
    // Java `ProjectBundlePaths.normalizeLibraryDescriptorPath`: descriptors written on Windows
    // carry backslashes, which are ordinary characters in a POSIX path.
    let normalized = name.replacingOccurrences(of: "\\", with: "/")
    var file: URL
    if normalized.hasPrefix("/") {
      file = URL(fileURLWithPath: normalized)
    } else if let currentDirectory {
      file = currentDirectory.appendingPathComponent(normalized)
    } else {
      file = URL(fileURLWithPath: normalized)
    }

    while !FileManager.default.isReadableFile(atPath: file.path) {
      ui.showMessage(FileStrings.fileLibraryMissingError(file.lastPathComponent))
      guard
        let chosen = ui.chooseFile(
          prompt: FileStrings.fileLibraryMissingError(file.lastPathComponent),
          kind: kind,
          startingAt: currentDirectory)
      else {
        throw LoaderError(FileStrings.fileLoadCanceledError)
      }
      file = chosen
    }
    return file
  }

  // MARK: LibraryLoader

  public func descriptor(for library: Library) throws -> String {
    try LibraryManager.instance.descriptor(self, for: library)
  }

  public func loadLibrary(desc: String) -> Library {
    LibraryManager.instance.loadLibrary(self, desc: desc)
  }

  /// Java `showError(String)`.
  ///
  /// The message is prefixed with the project currently being opened, which is how a user
  /// finds out *which* nested library file the complaint is about. The Swing half; the
  /// scrolling text area for long messages and the "copy to clipboard" button; belongs to the
  /// app shell and is reached through `LoaderUI`.
  public func showError(_ description: String) {
    var text = description
    if let top = filesOpening.last {
      let prefix = Loader.projectName(of: top) + ":"
      let separator = description.contains("\n") ? "\n" : " "
      text = prefix + separator + description
    }
    ui.showError(text)
  }

  private func showMessages(_ source: LogisimFile?) {
    guard let source else { return }
    while let message = source.takeMessage() {
      ui.showMessage(message)
    }
  }

  // MARK: Loading

  /// Java `loadLogisimFile(File)`; the entry point `LibraryManager` uses, with the
  /// self-reference check.
  func loadLogisimFile(_ request: URL) throws -> LogisimFile? {
    let actual = substitution(for: request)
    for opening in filesOpening where opening.path == actual.path {
      throw LoadFailedError(FileStrings.logisimCircularError(Loader.projectName(of: actual)))
    }

    filesOpening.append(actual)
    var result: LogisimFile?
    do {
      result = try LogisimFile.load(actual, loader: self)
    } catch {
      filesOpening.removeLast()
      throw LoadFailedError(
        FileStrings.logisimLoadError(
          Loader.projectName(of: actual), String(describing: error)))
    }
    filesOpening.removeLast()
    result?.setName(Loader.projectName(of: actual))
    return result
  }

  /// Java `loadLogisimLibrary(File)`.
  @discardableResult
  public func loadLogisimLibrary(_ file: URL) -> Library? {
    let actual = substitution(for: file)
    guard let result = LibraryManager.instance.loadLogisimLibrary(self, file: actual) else {
      return nil
    }
    showMessages(result.base as? LogisimFile)
    return result
  }

  /// Java `loadJarLibrary(File, String)`. D11: reports the gap and returns nil.
  public func loadJarLibrary(_ file: URL, className: String) -> Library? {
    LibraryManager.instance.loadJarLibrary(
      self, file: substitution(for: file), className: className)
  }

  /// Java `openLogisimFile(File)`.
  public func openLogisimFile(_ file: URL) throws -> LogisimFile {
    do {
      guard let result = try loadLogisimFile(file) else {
        throw LoadFailedError("File could not be opened")
      }
      setMainFile(file)
      showMessages(result)
      return result
    } catch let error as LoaderError {
      throw LoadFailedError(error.message, isShown: error.isShown)
    }
  }

  /// Java `openLogisimFile(File, Map<File, File>)`.
  public func openLogisimFile(_ file: URL, substitutions: [URL: URL]) throws -> LogisimFile {
    self.substitutions = Dictionary(
      uniqueKeysWithValues: substitutions.map { ($0.key.path, $0.value) })
    defer { self.substitutions = [:] }
    return try openLogisimFile(file)
  }

  /// Java `openLogisimFile(InputStream)`.
  public func openLogisimFile(data: Data) throws -> LogisimFile? {
    let result: LogisimFile?
    do {
      result = try LogisimFile.load(data: data, loader: self)
    } catch is LoaderError {
      return nil
    }
    showMessages(result)
    return result
  }

  /// Java `loadCustomStartupLibraries(String)`; every `.circ` in a directory of user
  /// libraries. Upstream keeps only libraries that themselves declare sub-libraries, and
  /// swallows a `NullPointerException` per file; the null check is explicit here.
  public func loadCustomStartupLibraries(directory path: String) -> [Library] {
    let directory = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return []
    }
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else {
      return []
    }
    var loaded: [Library] = []
    for entry in entries where entry.lastPathComponent.hasSuffix(Loader.logisimExtension) {
      if let library = loadLogisimLibrary(entry), !library.libraries.isEmpty {
        loaded.append(library)
      }
    }
    return loaded
  }

  /// Java `reload(LoadedLibrary)`.
  public func reload(_ library: LoadedLibrary) {
    LibraryManager.instance.reload(self, library: library)
  }

  // MARK: Saving

  /// Java `save(LogisimFile, File)`: backup rotation, circular-reference refusal, and the
  /// zero-length-result recovery.
  ///
  /// Upstream's `finally` block closes the stream and reports a close failure separately;
  /// `Data.write(to:)` has no separate close step, so the two error paths collapse into one.
  @discardableResult
  public func save(_ file: LogisimFile, to destination: URL) -> Bool {
    if let reference = LibraryManager.instance.findReference(in: file, query: destination) {
      ui.showError(FileStrings.fileCircularError(reference.displayName))
      return false
    }

    let backup = Loader.determineBackupName(destination)
    var backupCreated = false
    if let backup, FileManager.default.fileExists(atPath: destination.path) {
      backupCreated = (try? FileManager.default.moveItem(at: destination, to: backup)) != nil
    }

    let oldFile = mainFile
    do {
      setMainFile(destination)
      let data = try write(file, destination: destination, mainCircFile: nil)
      try data.write(to: destination, options: .atomic)
      file.setName(Loader.projectName(of: destination))
      LibraryManager.instance.fileSaved(
        self, destination: destination, oldFile: oldFile, file: file)
    } catch {
      setMainFile(oldFile)
      if backupCreated, let backup { Loader.recoverBackup(backup, to: destination) }
      if Loader.isEmptyFile(destination) { try? FileManager.default.removeItem(at: destination) }
      ui.showError("Error while saving file: \(error)")
      return false
    }

    if Loader.isEmptyFile(destination)
      || !FileManager.default.fileExists(atPath: destination.path)
    {
      if backupCreated, let backup, FileManager.default.fileExists(atPath: backup.path) {
        Loader.recoverBackup(backup, to: destination)
      } else {
        try? FileManager.default.removeItem(at: destination)
      }
      ui.showError("Error while saving file: the file written was empty.")
      return false
    }

    if backupCreated, let backup, FileManager.default.fileExists(atPath: backup.path) {
      try? FileManager.default.removeItem(at: backup)
    }
    if let autosaveFileURL, FileManager.default.fileExists(atPath: autosaveFileURL.path) {
      deleteAutosave()
    }
    return true
  }

  /// Java `autosave(LogisimFile)`; deliberately without the failsafes `save` has.
  @discardableResult
  public func autosave(_ file: LogisimFile) -> Bool {
    let oldAutosave = autosaveFileURL
    guard let target = Loader.determineAutosaveName(mainFileURL) else { return false }
    autosaveFileURL = target
    do {
      let data = try write(file, destination: target, mainCircFile: nil)
      try data.write(to: target, options: .atomic)
    } catch {
      return false
    }
    if let oldAutosave, oldAutosave.path != target.path {
      try? FileManager.default.removeItem(at: oldAutosave)
    }
    return true
  }

  /// Java `deleteAutosave()`.
  @discardableResult
  public func deleteAutosave() -> Bool {
    guard let autosaveFileURL else { return false }
    return (try? FileManager.default.removeItem(at: autosaveFileURL)) != nil
  }

  /// Java `export(LogisimFile, String homeDirectory)`.
  @discardableResult
  public func export(_ file: LogisimFile, homeDirectory: String) -> Bool {
    guard let mainFile else { return false }
    let target = URL(fileURLWithPath: homeDirectory)
      .appendingPathComponent(Loader.logisimCircuitDirectory)
      .appendingPathComponent(mainFile.lastPathComponent)
    let libraryHome = URL(fileURLWithPath: homeDirectory)
      .appendingPathComponent(Loader.logisimLibraryDirectory).path
    do {
      let data = try write(file, destination: nil, mainCircFile: libraryHome)
      try data.write(to: target, options: .atomic)
    } catch {
      ui.showError("Unable to export file")
      return false
    }
    return true
  }

  /// Java's `LogisimFile.write(...)` funnel, on this side of the reader/writer seam.
  public func write(
    _ file: LogisimFile, destination: URL?, mainCircFile: String?, recurse: Bool = false
  ) throws -> Data {
    guard let fileWriter else {
      throw LoaderError("no .circ writer is installed on this loader")
    }
    return try fileWriter.write(
      file, loader: self, destination: destination, mainCircFile: mainCircFile, recurse: recurse)
  }

  /// Java `recoverBackup(File, File)`. Upstream flags both failure modes with FIXMEs; the
  /// behaviour is unchanged here, only the comments are honest about it.
  private static func recoverBackup(_ backup: URL, to destination: URL) {
    guard FileManager.default.fileExists(atPath: backup.path) else { return }
    if FileManager.default.fileExists(atPath: destination.path) {
      try? FileManager.default.removeItem(at: destination)
    }
    try? FileManager.default.moveItem(at: backup, to: destination)
  }

  private static func isEmptyFile(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else {
      return false
    }
    return size.intValue == 0
  }

  // MARK: Reading, internal

  /// Invoked by `LogisimFile.loadSub`. Kept here so the reader seam has exactly one owner.
  func readLibrary(_ data: Data, sourceFile: URL?) throws -> LogisimFile {
    guard let fileReader else {
      throw LoaderError("no .circ reader is installed on this loader")
    }
    return try fileReader.readLibrary(data, loader: self, sourceFile: sourceFile)
  }
}
