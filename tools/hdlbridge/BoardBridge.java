/*
 * BoardBridge: drives the REAL BoardReaderClass inside the shipped logisim-evolution
 * 4.1.0 jar and prints a canonical, line-oriented description of every board it parses.
 *
 * This is the same trick NetlistBridge.java plays for the netlist: rather than reading
 * the Java and hoping the Swift transcription agrees, we run the Java on the same input
 * and diff. `tools/hdlbridge/gen_board_oracle.py` turns this into
 * `tools/hdlbridge/boards-4.1.0.oracle`, and `LogisimHdlTests/BoardGateTests` compares
 * the Swift `BoardReader` against it board by board, field by field.
 *
 * It lives in package com.cburch.logisim.fpga.file only so that it could reach package
 * private members if it ever needed to; today it uses public API only.
 *
 * Usage: java -cp <jar>:out com.cburch.logisim.fpga.file.BoardBridge <resource-name>...
 *   e.g. resources/logisim/boards/TERASIC_DE0.xml
 * With no arguments it reads resource names from stdin, one per line.
 *
 * GPL-3.0-only, like the rest of the port. See LICENSE.md.
 */
package com.cburch.logisim.fpga.file;

import com.cburch.logisim.fpga.data.BoardInformation;
import com.cburch.logisim.fpga.data.FpgaIoInformationContainer;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Set;

public class BoardBridge {

  private static String esc(String s) {
    if (s == null) return "<null>";
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace(" ", "\\s");
  }

  private static String sortedSet(Set<Integer> set) {
    if (set == null) return "<null>";
    final var list = new ArrayList<Integer>(set);
    Collections.sort(list);
    final var sb = new StringBuilder("[");
    for (var i = 0; i < list.size(); i++) {
      if (i != 0) sb.append(",");
      sb.append(list.get(i));
    }
    return sb.append("]").toString();
  }

  private static void dump(String name, BoardInformation board) {
    System.out.println("BOARD " + esc(name));
    if (board == null) {
      System.out.println("FAIL null");
      System.out.println("END");
      return;
    }
    System.out.println("NAME " + esc(board.getBoardName()));
    final var fpga = board.fpga;
    System.out.println(
        "FPGA present="
            + fpga.isFpgaInfoPresent()
            + " freq="
            + fpga.getClockFrequency()
            + " clkpin="
            + esc(fpga.getClockPinLocation())
            + " clkpull="
            + (int) fpga.getClockPull()
            + " clkstd="
            + (int) fpga.getClockStandard()
            + " tech="
            + esc(fpga.getTechnology())
            + " part="
            + esc(fpga.getPart())
            + " pkg="
            + esc(fpga.getPackage())
            + " speed="
            + esc(fpga.getSpeedGrade())
            + " vendor="
            + (int) fpga.getVendor()
            + " unused="
            + (int) fpga.getUnusedPinsBehavior()
            + " usbtmc="
            + fpga.isUsbTmcDownloadRequired()
            + " jtag="
            + fpga.getFpgaJTAGChainPosition()
            + " flashname="
            + esc(fpga.getFlashName())
            + " flashpos="
            + fpga.getFlashJTAGChainPosition()
            + " flashdef="
            + fpga.isFlashDefined());
    final var image = board.getImage();
    if (image == null) {
      System.out.println("IMAGE none");
    } else {
      System.out.println("IMAGE " + image.getWidth() + "x" + image.getHeight());
    }
    final List<FpgaIoInformationContainer> comps = board.getAllComponents();
    System.out.println("NCOMP " + comps.size());
    var idx = 0;
    for (final var comp : comps) {
      final var rect = comp.getRectangle();
      final var sb = new StringBuilder();
      sb.append("COMP ").append(idx++);
      sb.append(" type=").append(comp.getType().name());
      sb.append(" rect=")
          .append(rect == null
              ? "<null>"
              : rect.getXpos() + "," + rect.getYpos() + "," + rect.getWidth() + ","
                  + rect.getHeight());
      sb.append(" npins=").append(comp.getNrOfPins());
      sb.append(" ext=").append(comp.getExternalPinCount());
      sb.append(" rot=").append(comp.getMapRotation());
      sb.append(" rows=").append(comp.getNrOfRows());
      sb.append(" cols=").append(comp.getNrOfColumns());
      sb.append(" driving=").append((int) comp.getArrayDriveMode());
      sb.append(" label=").append(esc(comp.getLabel()));
      sb.append(" pull=").append((int) comp.getPullBehavior());
      sb.append(" act=").append((int) comp.getActivityLevel());
      sb.append(" std=").append((int) comp.getIoStandard());
      sb.append(" drive=").append((int) comp.getDrive());
      sb.append(" in=").append(sortedSet(comp.getInputs()));
      sb.append(" out=").append(sortedSet(comp.getOutputs()));
      sb.append(" io=").append(sortedSet(comp.getIos()));
      sb.append(" locs=[");
      for (var pin = 0; pin < comp.getNrOfPins(); pin++) {
        if (pin != 0) sb.append(",");
        sb.append(esc(comp.getPinLocation(pin)));
      }
      sb.append("]");
      System.out.println(sb);
    }
    System.out.println("END");
  }

  public static void main(String[] args) throws Exception {
    final var names = new ArrayList<String>();
    if (args.length > 0) {
      Collections.addAll(names, args);
    } else {
      try (final var reader = new BufferedReader(new InputStreamReader(System.in))) {
        String line;
        while ((line = reader.readLine()) != null) {
          final var trimmed = line.trim();
          if (!trimmed.isEmpty()) names.add(trimmed);
        }
      }
    }
    for (final var name : names) {
      // A bare resource path is read out of the jar; anything absolute or already carrying a
      // scheme is passed to BoardReaderClass untouched, so a synthetic fixture on disk can be
      // driven through the same real reader.
      final var target =
          (name.startsWith("/") || name.startsWith("file:") || name.startsWith("url:"))
              ? name
              : "url:" + name;
      final var reader = new BoardReaderClass(target);
      dump(name, reader.getBoardInformation());
    }
  }
}
