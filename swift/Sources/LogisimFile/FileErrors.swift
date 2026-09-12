// logisim-evolved: a native Swift/macOS port of logisim-evolution.
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution),
// which is GPL-3.0-only. This port is a derivative work and is therefore GPL-3.0-only.
// SPDX-License-Identifier: GPL-3.0-only
//
// Port of com.cburch.logisim.file.LoaderException and
// com.cburch.logisim.file.LoadFailedException, plus the English message templates the file
// package uses (src/main/resources/resources/logisim/strings/file/file.properties).

import Foundation

// MARK: - Errors

/// `com.cburch.logisim.file.LoaderException`.
///
/// Java declares this a `RuntimeException` and its own source calls that out as a mistake
/// ("FIXME: this is unchecked exception. We most likely shall convert this to checked one").
/// Under D13 an unchecked Java exception on the file-loading path becomes a Swift `throw`,
/// never a trap: it is raised by ordinary user input; a `<lib desc="file#missing.circ">`
/// whose file does not exist and whose replacement the user declines to pick.
public struct LoaderError: Error, CustomStringConvertible, Equatable {
  public let message: String
  /// Java's `isShown()`: the message has already been put in front of the user, so the
  /// catcher must not show it a second time.
  public let isShown: Bool

  public init(_ message: String, isShown: Bool = false) {
    self.message = message
    self.isShown = isShown
  }

  public var description: String { message }
}

/// `com.cburch.logisim.file.LoadFailedException`: checked in Java, so this is a direct
/// translation with no D13 judgement needed.
public struct LoadFailedError: Error, CustomStringConvertible, Equatable {
  public let message: String
  public let isShown: Bool

  public init(_ message: String, isShown: Bool = false) {
    self.message = message
    self.isShown = isShown
  }

  public var description: String { message }
}

// MARK: - Message templates

/// The English strings the file package formats into its errors.
///
/// Localisation deliberately does not come across (see D5's note on `Attribute`): the kernel
/// and file layers keep raw, stable English text and any presentation layer is free to
/// re-localise. Keeping the exact upstream wording matters because these strings end up in
/// the message list a caller may compare against.
public enum FileStrings {
  public static func fileBuiltinMissingError(_ name: String) -> String {
    "The built-in library \u{201C}\(name)\u{201D} is not available in this version."
  }

  public static func fileDescriptorError(_ desc: String) -> String {
    "Unrecognized library descriptor \(desc)"
  }

  public static func fileDescriptorUnknownError(_ displayName: String) -> String {
    "Descriptor not known for \u{201C}\(displayName)\u{201D}."
  }

  public static func fileTypeError(_ type: String, _ desc: String) -> String {
    "The Logisim library has an unrecognized type \(type) (\(desc))"
  }

  public static func unknownLibraryFileError(_ displayName: String) -> String {
    "No file known corresponding to \(displayName)."
  }

  public static func fileCircularError(_ displayName: String) -> String {
    "Cannot create circular reference. (The file is used by the \(displayName) library.)"
  }

  public static func fileLibraryMissingError(_ name: String) -> String {
    "The required library file \u{2018}\(name)\u{2019} is missing. "
      + "Please select the file from the following dialog."
  }

  public static let fileLoadCanceledError = "User canceled load. [1]"

  public static func jarClassNotFoundError(_ className: String) -> String {
    "The \(className) class was not found in the JAR file."
  }

  public static func logisimCircularError(_ projectName: String) -> String {
    "The file \(projectName) contains within it a reference to itself."
  }

  public static func logisimLoadError(_ projectName: String, _ detail: String) -> String {
    "Error encountered opening \(projectName): \(detail)"
  }

  public static func xmlFormatError(_ detail: String) -> String {
    "XML formatting error: \(detail)"
  }

  public static let defaultProjectName = "Untitled"

  public static let circuitNameExists =
    "This name is already in use in your project and can therefore not be used."

  public static func fileDuplicateError(_ detail: String) -> String {
    "Error duplicating file: \(detail)"
  }

  public static func autosaveError(_ name: String) -> String {
    "Failed to create autosave for file: \u{2018}\(name)\u{2019}. "
      + "Will not try again for this file until after a restart."
  }

  public static func unloadUsedError(_ circuitName: String) -> String {
    "Circuit \u{2018}\(circuitName)\u{2019} uses components from the library."
  }

  public static let unloadToolbarError = "Library includes items currently in the toolbar."

  public static let unloadMappingError = "Library includes items currently mapped to the mouse."

  public static let xmlConversionError = "Internal error while creating XML"

  /// D11: JAR component libraries are a permanent functional gap. Upstream resolves them with
  /// `ZipClassLoader` + `Class.forName` + reflective instantiation, which has no AOT-Swift
  /// equivalent. There is no upstream string for this because upstream never needs one.
  public static func jarLibraryUnsupported(_ file: String, _ className: String) -> String {
    "JAR component libraries are not supported by this port (\(className) in \(file)). "
      + "The library and its components are preserved unchanged when the file is saved."
  }
}
