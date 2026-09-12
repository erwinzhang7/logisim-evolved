// FileWriter: part of logisim-evolved.
//
// Derived from logisim-evolution (https://github.com/logisim-evolution/logisim-evolution):
// `com/cburch/logisim/fpga/file/FileWriter.java`. Copyright by the Logisim-evolution
// developers. This translation is a derivative work and is therefore licensed GPL-3.0-only.
// See LICENSE.md.
//
// Unlike the rest of this module, this is genuinely filesystem I/O: Java's own `FileWriter`
// isn't "pure string building" either, it uses `java.io.File`/`FileOutputStream`: so this file
// imports Foundation for `FileManager`/`Data` where the rest of the module does not.
//
// `BuildInfo.name`/`BuildInfo.url` (Java: a generated class stamped at build time) have no
// Swift equivalent yet, so `HdlBuildInfo` is a small settable stand-in with sensible defaults;
// whatever module eventually owns build metadata can point these at the real values without
// this file changing. Localisation (`S.fmt(...)`) does not come across, matching the kernel's
// established practice (D9); messages are plain English.

import Foundation

/// Stand-in for the generated `com.cburch.logisim.generated.BuildInfo` the header remark
/// quotes. Override before generating HDL if the app wants different branding.
public enum HdlBuildInfo {
  public static var name = "logisim-evolved"
  public static var url = "https://github.com/logisim-evolution/logisim-evolution"
}

/// `com.cburch.logisim.fpga.file.FileWriter`.
public enum HdlFileWriter {
  public static let entityExtension = "_entity"
  public static let architectureExtension = "_behavior"

  /// `FileWriter.getFilePointer(String, String, boolean)`.
  ///
  /// Returns the target file path, or `nil` exactly where Java returns `null`: the directory
  /// could not be created, the file already exists, or some other I/O error occurred. All three
  /// are reported through `Reporter`, matching upstream.
  public static func filePointer(
    targetDirectory: String, componentName: String, isEntity: Bool
  ) -> String? {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: targetDirectory, isDirectory: &isDirectory) {
      guard
        (try? fileManager.createDirectory(
          atPath: targetDirectory, withIntermediateDirectories: true)) != nil
      else {
        return nil
      }
    }
    var fileName = targetDirectory
    if !fileName.hasSuffix("/") { fileName += "/" }
    fileName += componentName
    if isEntity && Hdl.isVhdl() { fileName += entityExtension }
    if !isEntity && Hdl.isVhdl() { fileName += architectureExtension }
    fileName += Hdl.isVhdl() ? ".vhd" : ".v"

    Reporter.shared.addInfo("Generating HDL file '\(fileName)'")
    if fileManager.fileExists(atPath: fileName) {
      Reporter.shared.addWarning("HDL file '\(fileName)' already exists; not overwriting")
      return nil
    }
    return fileName
  }

  /// `FileWriter.getFilePointer(String, String)`.
  public static func filePointer(targetDirectory: String, name: String) -> String? {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: targetDirectory, isDirectory: &isDirectory) {
      guard
        (try? fileManager.createDirectory(
          atPath: targetDirectory, withIntermediateDirectories: true)) != nil
      else {
        return nil
      }
    }
    var fileName = targetDirectory
    if !fileName.hasSuffix("/") { fileName += "/" }
    fileName += name

    Reporter.shared.addInfo("Generating script file '\(fileName)'")
    if fileManager.fileExists(atPath: fileName) {
      Reporter.shared.addWarning("Script file '\(fileName)' already exists; not overwriting")
      return nil
    }
    return fileName
  }

  /// `FileWriter.getGenerateRemark(String, String)`.
  public static func generateRemark(componentName: String, projName: String) -> [String] {
    var lines: [String] = []
    let headWidth = 74
    let headText =
      " " + HdlBuildInfo.name + " goes FPGA automatic generated "
      + (Hdl.isVhdl() ? "VHDL" : "Verilog") + " code"
    let headUrl = " " + HdlBuildInfo.url
    let headProj = " Project   : " + projName
    let headComp = " Component : " + componentName

    func padded(_ text: String) -> String {
      text + String(repeating: " ", count: max(0, headWidth - text.count))
    }

    if Hdl.isVhdl() {
      let headOpen = "--=="
      let headClose = "=="
      lines.append(headOpen + String(repeating: "=", count: headWidth) + headClose)
      lines.append(headOpen + padded(headText) + headClose)
      lines.append(headOpen + padded(headUrl) + headClose)
      lines.append(headOpen + String(repeating: " ", count: headWidth) + headClose)
      lines.append(headOpen + String(repeating: " ", count: headWidth) + headClose)
      lines.append(headOpen + padded(headProj) + headClose)
      lines.append(headOpen + padded(headComp) + headClose)
      lines.append(headOpen + String(repeating: " ", count: headWidth) + headClose)
      lines.append(headOpen + String(repeating: "=", count: headWidth) + headClose)
      lines.append("")
    } else if Hdl.isVerilog() {
      let headOpen = " **"
      let headClose = "**"
      lines.append("/**" + String(repeating: "*", count: headWidth) + headClose)
      lines.append(headOpen + padded(headText) + headClose)
      lines.append(headOpen + padded(headUrl) + headClose)
      lines.append(headOpen + String(repeating: " ", count: headWidth) + headClose)
      lines.append(headOpen + padded(headComp) + headClose)
      lines.append(headOpen + String(repeating: " ", count: headWidth) + headClose)
      lines.append(headOpen + String(repeating: "*", count: headWidth) + "*/")
      lines.append("")
    }
    return lines
  }

  /// `FileWriter.writeContents(File, List<String>)`.
  public static func writeContents(path: String, contents: [String]) -> Bool {
    var text = ""
    for line in contents {
      text += line
      text += "\n"
    }
    guard let data = text.data(using: .utf8) else {
      Reporter.shared.addFatalError("Unable to write file '\(path)'")
      return false
    }
    do {
      try data.write(to: URL(fileURLWithPath: path))
      return true
    } catch {
      Reporter.shared.addFatalError("Unable to write file '\(path)'")
      return false
    }
  }
}
