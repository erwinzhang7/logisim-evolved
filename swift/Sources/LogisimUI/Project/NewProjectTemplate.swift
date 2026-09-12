// NewProjectTemplate.swift: part of logisim-evolved.
//
// Contains a verbatim copy of logisim-evolution's `resources/logisim/default.templ` (4.1.0,
// D16). Copyright by the Logisim-evolution developers; this file is therefore GPL-3.0-only, as
// the rest of this port is. See LICENSE.md.
// SPDX-License-Identifier: GPL-3.0-only
//
// ── Why File ▸ New is a template and not `LogisimFile.createNew` ────────────────────────────
//
// `LogisimFile.createNew(Loader, Project)` in 4.1.0 is three lines: a bare `LogisimFile`, one
// circuit called "main", one `AddTool` for it. **It declares no libraries at all**, so a
// document made that way cannot place a gate, cannot show a palette, and, the part that is a
// silent data loss, cannot *save* one either: `XmlWriter.fromTool` resolves a component's
// factory back to a library through `libraryContains`, and a factory belonging to no declared
// library is written as nothing.
//
// That is not upstream's New-project path. `ProjectActions.doNew` loads
// `AppPreferences.getTemplate()`, whose factory default is `resources/logisim/default.templ`;
// the document below. So "new project" is an *open* of a fixed document, and this port does the
// same thing through the same `Loader`, which means one code path is exercised instead of two.
//
// This was found by the verification suite rather than by reading: `serialize()` on a new
// project with one AND gate in it produced a file whose circuit had **zero** components, and the
// explorer's editing-tool row was empty because `#Base` was absent.
//
// ── Faithfulness ────────────────────────────────────────────────────────────────────────────
//
// Byte-for-byte upstream's file, including the `#Soc` declaration. `#Soc`'s factories live in
// `LogisimSoc`, which `LogisimUI` does not link (`StdLibraries.registerAll()` cannot register
// them: the dependency arrow points the wrong way), so the shell resolves with an empty tool
// list rather than failing the load. An executable that calls `SocLibrary.registerBuiltinTools()`
// gets the tools; one that does not gets an empty `#Soc` library and a correct round trip. Both
// are honest; neither drops anything.
//
// When the preferences layer lands, `AppPreferences.getTemplate()`'s three modes (plain, empty,
// custom) belong here, and this constant becomes the "plain" one.

import Foundation

enum NewProjectTemplate {

  /// `resources/logisim/default.templ`, 4.1.0.
  static let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <project version="1.0">

     <lib name="0" desc="#Wiring" />
     <lib name="1" desc="#Gates" />
     <lib name="2" desc="#Plexers" />
     <lib name="3" desc="#Arithmetic" />
     <lib name="D" desc="#FPArithmetic" />
     <lib name="4" desc="#Memory" />
     <lib name="5" desc="#I/O" />
     <lib name="A" desc="#TTL" />
     <lib name="7" desc="#TCL" />
     <lib name="8" desc="#Base" />
     <lib name="9" desc="#BFH-Praktika" />
     <lib name="B" desc="#Input/Output-Extra" />
     <lib name="C" desc="#Soc" />

     <options>
      <a name="showgrid" val="true" />
      <a name="simulate" val="true" />
      <a name="showghosts" val="true" />
      <a name="zoom" val="1.0" />
     </options>

     <mappings>
      <tool lib="8" name="Poke Tool" map="Button2" />
      <tool lib="8" name="Menu Tool" map="Button3" />
      <tool lib="8" name="Menu Tool" map="Ctrl Button1" />
     </mappings>

     <toolbar>
      <tool lib="8" name="Poke Tool" />
      <tool lib="8" name="Edit Tool" />
      <tool lib="8" name="Wiring Tool" />
      <tool lib="8" name="Text Tool"/>
      <sep />
      <tool lib="0" name="Pin">
       <a name="tristate" val="false" />
      </tool>
      <tool lib="0" name="Pin">
       <a name="facing" val="west" />
       <a name="output" val="true" />
      </tool>
      <sep />
      <tool lib="1" name="NOT Gate" />
      <tool lib="1" name="AND Gate" />
      <tool lib="1" name="OR Gate" />
      <tool lib="1" name="XOR Gate" />
      <tool lib="1" name="NAND Gate" />
      <tool lib="1" name="NOR Gate" />
      <sep />
      <tool lib="4" name="D Flip-Flop" />
      <tool lib="4" name="Register" />
     </toolbar>

     <circuit name="main" />
    </project>
    """

  static var data: Data { Data(xml.utf8) }
}
