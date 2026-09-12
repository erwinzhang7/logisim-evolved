#!/usr/bin/env python3
"""One-off: drive BoardModelTests' synthetic fixtures through the REAL jar reader.

`BoardGateTests` covers the 29 shipped boards; the synthetic fixtures in
`BoardModelTests` exist precisely because those 29 do not exercise the
uncompressed picture encoding, the positional backward-compatibility partition,
the dropped-component paths or an empty pin set. This script builds the same
fixtures on disk and prints what `com.cburch.logisim.fpga.file.BoardReaderClass`
inside the 4.1.0 jar makes of them, so the expectations in that suite are
checked against upstream rather than against a reading of the Java.

Not a checked-in gate: it needs the jar, and its output is transcribed into
`BoardModelTests` once. Re-run it if those fixtures change.
"""

import os
import string
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
FIXTURES = os.path.join(HERE, "out", "synthetic")
JAVA = os.environ.get("LOGISIM_JAVA", "/opt/homebrew/opt/openjdk@21/bin/java")
JAVAC = os.environ.get("LOGISIM_JAVAC", JAVA.replace("/java", "/javac"))
JAR = os.environ.get(
    "LOGISIM_JAR",
    "/Applications/Logisim-evolution.app/Contents/app/logisim-evolution-4.1.0-all.jar")

SINGLES = list(string.ascii_lowercase + string.ascii_uppercase + string.digits + "()")
TABLE = SINGLES + ["+" + c for c in SINGLES] + ["-" + c for c in SINGLES] \
    + ["=" + c for c in SINGLES]
PIXELS = TABLE[10] + TABLE[20] + TABLE[30]

CASES = {
    "basic.xml": '<LED OutputPinSet="P1" Rect_x_y_w_h="1,2,3,4"/>',
    "dropped.xml": (
        '<LED OutputPinSet="P1" Rect_x_y_w_h="4294967295,0,1,1"/>\n'
        '<LED OutputPinSet="P2"/>\n'
        '<Bus OutputPinSet="P3" Rect_x_y_w_h="0,0,1,1"/>\n'
        '<LED OutputPinSet="P4" Rect_x_y_w_h="5,6,7,8"/>'),
    "backcompat.xml": (
        '<SevenSegment NrOfPins="8" '
        + " ".join('FPGAPin_%d="P%d"' % (i, i) for i in range(8))
        + ' Rect_x_y_w_h="0,0,10,10"/>'),
    "pin.xml": '<Pin ActivityLevel="Active low" BiDirPinSet="P9" Rect_x_y_w_h="0,0,1,1"/>',
    "ledarray.xml": (
        '<LedArray LedArrayInfo="2,3,LedRowScanning" OutputPinSet="A,B,C,D,E" '
        'Rect_x_y_w_h="0,0,20,20"/>'),
    "buttons.xml": (
        '<Button ActivityLevel="Active low" FPGAPinIOStandard="LVCMOS33" '
        'FPGAPinPullBehavior="Pull Down" InputPinSet="C6" Label="sw" '
        'Rect_x_y_w_h="1,2,3,4"/>\n'
        '<Button InputPinSet="C7" Rect_x_y_w_h="5,6,7,8"/>'),
    "emptyset.xml": '<LED OutputPinSet="" Rect_x_y_w_h="1,1,1,1"/>',
    "scanning.xml": (
        '<SevenSegmentScanning ScanningSevenSegInfo="3,2,SevenSegScanningActiveLow" '
        'OutputPinSet="A,B,C" rotation="-90" Rect_x_y_w_h="0,0,20,20"/>'),
}


def board(components):
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        "<SYNTHETIC>\n"
        "   <BoardInformation>\n"
        '      <ClockInformation FPGApin="A1" Frequency="50000000" IOStandard="LVCMOS33"'
        ' PullBehavior="Float"/>\n'
        '      <FPGAInformation Family="Fam" FlashName="" FlashPos="2" JTAGPos="1"'
        ' Package="Pkg" Part="Part" Speedgrade="-1" USBTMC="false" Vendor="ALTERA"/>\n'
        '      <UnusedPins PullBehavior="Pull Up"/>\n'
        "   </BoardInformation>\n"
        "   <IOComponents>\n" + components + "\n   </IOComponents>\n"
        "   <BoardPicture>\n"
        '      <PictureDimension Height="1" Width="1"/>\n'
        '      <CompressionCodeTable TableData="' + " ".join(TABLE) + '"/>\n'
        '      <PixelData PixelRGB="' + PIXELS + '"/>\n'
        "   </BoardPicture>\n"
        "</SYNTHETIC>\n")


def main():
    if not os.path.exists(JAR):
        sys.exit("no jar at %s — set LOGISIM_JAR" % JAR)
    os.makedirs(FIXTURES, exist_ok=True)
    paths = []
    for name, components in CASES.items():
        path = os.path.join(FIXTURES, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(board(components))
        paths.append(path)

    subprocess.run(
        [JAVAC, "-cp", JAR, "-d", OUT, os.path.join(HERE, "BoardBridge.java")], check=True)
    proc = subprocess.run(
        [JAVA, "-Djava.awt.headless=true", "-cp", "%s:%s" % (JAR, OUT),
         "com.cburch.logisim.fpga.file.BoardBridge"],
        input="\n".join(paths) + "\n", capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    if proc.stderr.strip():
        sys.stderr.write(proc.stderr)


if __name__ == "__main__":
    main()
