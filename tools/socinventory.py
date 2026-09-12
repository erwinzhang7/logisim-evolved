#!/usr/bin/env python3
"""Class-by-class inventory: every com.cburch.logisim.soc.* Java file vs the Swift port.

'Ported' means a Swift declaration exists whose name maps to the Java class (directly, or via
the port's documented renames). Everything else is listed by name.
"""
import os
import pathlib
import re
import subprocess
import sys

# Upstream's Java for the SoC package. Not in this repository: the port is checked against the
# shipped 4.1.0 release, and D16 explains why a `main` checkout is a hazard rather than a help.
# Point LOGISIM_UPSTREAM_JAVA at a 4.1.0 source tree.
UPSTREAM = os.environ.get("LOGISIM_UPSTREAM_JAVA")
if not UPSTREAM:
    sys.exit("LOGISIM_UPSTREAM_JAVA is unset: point it at a logisim-evolution 4.1.0 source tree")
JAVA = pathlib.Path(UPSTREAM) / "src/main/java/com/cburch/logisim/soc"
if not JAVA.is_dir():
    sys.exit(f"{JAVA} is not a directory; LOGISIM_UPSTREAM_JAVA does not look like a 4.1.0 tree")
SWIFT = pathlib.Path("swift/Sources/LogisimSoc")

# Java class -> the Swift type(s) that carry it. None = deliberately not ported.
MAP = {
    "Soc": "SocLibrary",
    "Strings": None,                       # localisation table; D5/D9
    "bus/SocBus": "SocBus",
    "bus/SocBusAttributes": "SocBusAttributes",
    "bus/SocBusMenuProvider": None,        # JMenuItem/JDialog, D9
    "data/AssemblerHighlighter": "AssemblerLexer + AssemblerDirectives",
    "data/SocBusInfo": "SocBusInfo",
    "data/SocBusMasterInterface": "SocBusMasterInterface",
    "data/SocBusSlaveInterface": "SocBusSlaveInterface",
    "data/SocBusSlaveListener": "SocBusSlaveListener",
    "data/SocBusSnifferInterface": "SocBusSnifferInterface",
    "data/SocBusStateInfo": "SocBusFabric + SocBusTraceLog",
    "data/SocBusTransaction": "SocBusTransaction",
    "data/SocInstanceFactory": "SocInstanceFactory",
    "data/SocMemMapModel": "SocMemoryMap",
    "data/SocProcessorInterface": "SocProcessorInterface",
    "data/SocSimulationManager": "SocSimulationManager",
    "data/SocSupport": "SocSupport",
    "data/SocUpMenuProvider": None,        # right-click menu, D9
    "data/SocUpSimulationState": "SocUpSimulationState",
    "data/SocUpSimulationStateListener": "SocUpSimulationStateListener",
    "data/SocUpStateInterface": "SocUpStateInterface",
    "data/TraceInfo": "TraceInfo",
    "dma/DmaAttributes": "DmaAttributes",
    "dma/DmaState": "DmaState",
    "dma/SocDma": "SocDma",
    "file/ElfHeader": "ElfHeader",
    "file/ElfProgramHeader": "ElfProgramHeader",
    "file/ElfSectionHeader": "ElfSectionHeader",
    "file/ProcessorReadElf": "ProcessorReadElf",
    "file/SectionHeader": "SectionHeaderEntry",
    "file/SymbolTable": "SymbolTableEntry",
    "gui/AssemblerPanel": None,
    "gui/BreakpointPanel": None,
    "gui/BusTransactionInsertionGui": None,
    "gui/CpuDrawSupport": None,
    "gui/ListeningFrame": None,
    "gui/SocCpuShape": None,
    "gui/TraceWindowTableModel": None,
    "jtaguart/JtagUart": "JtagUart",
    "jtaguart/JtagUartAttributes": "JtagUartAttributes",
    "jtaguart/JtagUartState": "JtagUartState",
    "memory/SocMemory": "SocMemory",
    "memory/SocMemoryAttributes": "SocMemoryAttributes",
    "memory/SocMemoryState": "SocMemoryState",
    "nios2/Nios2": "Nios2",
    "nios2/Nios2ArithmeticAndLogicalInstructions": "Nios2ArithmeticAndLogicalInstructions",
    "nios2/Nios2Assembler": "Nios2Assembler",
    "nios2/Nios2Attributes": "Nios2Attributes",
    "nios2/Nios2ComparisonInstructions": "Nios2ComparisonInstructions",
    "nios2/Nios2CustomInstructions": "Nios2CustomInstructions",
    "nios2/Nios2DataTransferInstructions": "Nios2DataTransferInstructions",
    "nios2/Nios2OtherControlInstructions": "Nios2OtherControlInstructions",
    "nios2/Nios2ProgramControlInstructions": "Nios2ProgramControlInstructions",
    "nios2/Nios2ShiftAndRotateInstructions": "Nios2ShiftAndRotateInstructions",
    "nios2/Nios2State": "Nios2Config + Nios2ProcessorState",
    "nios2/Nios2Support": "Nios2Support",
    "nios2/Nios2SyntaxHighlighter": "Nios2SyntaxHighlighter",
    "pio/PioAttributes": "PioAttributes",
    "pio/PioMenu": None,                   # JPopupMenu, D9
    "pio/PioState": "PioState",
    "pio/SocPio": "SocPio",
    "rv32im/RV32im_M_ExtensionInstructions": "Rv32imMExtensionInstructions",
    "rv32im/RV32im_Zicsr_ExtensionInstructions": "Rv32imZicsrExtensionInstructions",
    "rv32im/RV32imAssembler": "Rv32imAssembler",
    "rv32im/RV32imAttributes": "Rv32imAttributes",
    "rv32im/RV32imControlTransferInstructions": "Rv32imControlTransferInstructions",
    "rv32im/RV32imEnvironmentCallAndBreakpoints": "Rv32imEnvironmentCallAndBreakpoints",
    "rv32im/RV32imIntegerRegisterImmediateInstructions": "Rv32imIntegerRegisterImmediateInstructions",
    "rv32im/RV32imIntegerRegisterRegisterOperations": "Rv32imIntegerRegisterRegisterOperations",
    "rv32im/RV32imLoadAndStoreInstructions": "Rv32imLoadAndStoreInstructions",
    "rv32im/Rv32imMemoryOrderingInstructions": "Rv32imMemoryOrderingInstructions",
    "rv32im/Rv32imPlicState": "Rv32imPlicState",
    "rv32im/Rv32imRiscV": "Rv32imRiscV",
    "rv32im/RV32imState": "Rv32imConfig + Rv32imProcessorState",
    "rv32im/RV32imSupport": "Rv32imBits",
    "rv32im/RV32imSyntaxHighlighter": "Rv32imSyntaxHighlighter",
    "util/AbstractAssembler": "AbstractAssembler",
    "util/AbstractExecutionUnitWithLabelSupport": "AssemblerExecutionUnitWithLabelSupport",
    "util/Assembler": "AssemblerRunner",
    "util/AssemblerAsmInstruction": "AssemblerAsmInstruction",
    "util/AssemblerExecutionInterface": "AssemblerExecutionInterface",
    "util/AssemblerInfo": "AssemblerInfo",
    "util/AssemblerInterface": "AssemblerInterface",
    "util/AssemblerMacro": "AssemblerMacro",
    "util/AssemblerToken": "AssemblerToken",
    "vga/SocVga": "SocVga",
    "vga/SocVgaShape": None,               # DynamicElement, D6
    "vga/VgaAttributes": "VgaAttributes",
    "vga/VgaMenu": None,                   # JPopupMenu, D9
    "vga/VgaState": "VgaState",
}

java_files = sorted(
    str(p.relative_to(JAVA)).removesuffix(".java") for p in JAVA.rglob("*.java"))

swift_decls = set()
pattern = re.compile(r"^\s*(?:public |open |final |)*(?:class|struct|enum|protocol) (\w+)", re.M)
for p in SWIFT.rglob("*.swift"):
    swift_decls.update(pattern.findall(p.read_text()))

ported, dropped, missing = [], [], []
for name in java_files:
    if name not in MAP:
        missing.append(f"{name}  (NOT IN THE MAP — inventory is out of date)")
        continue
    target = MAP[name]
    if target is None:
        dropped.append(name)
        continue
    names = [t.strip() for t in target.split("+")]
    if all(n in swift_decls for n in names):
        ported.append(name)
    else:
        absent = [n for n in names if n not in swift_decls]
        missing.append(f"{name}  ->  {target}  (absent: {', '.join(absent)})")

print(f"java files                  : {len(java_files)}")
print(f"  ported                    : {len(ported)}")
print(f"  deliberately not ported   : {len(dropped)}")
print(f"  MISSING                   : {len(missing)}")
print()
print("deliberately not ported (D6/D9 GUI, or localisation):")
for n in dropped:
    print(f"  {n}")
if missing:
    print()
    print("MISSING:")
    for n in missing:
        print(f"  {n}")
