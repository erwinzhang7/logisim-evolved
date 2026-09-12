package com.cburch.logisim.analyze.model;

import java.util.*;

public class TableProbe {
  static AnalyzerModel m;

  static String col() {
    TruthTable t = m.getTruthTable();
    StringBuilder s = new StringBuilder();
    for (int i = 0; i < t.getRowCount(); i++) s.append(t.getOutputEntry(i, 0).getDescription());
    return s.toString();
  }

  static String rows() {
    TruthTable t = m.getTruthTable();
    StringBuilder s = new StringBuilder();
    for (int r = 0; r < t.getVisibleRowCount(); r++) {
      if (r > 0) s.append(",");
      for (int c = 0; c < t.getInputColumnCount(); c++) {
        s.append(t.getVisibleInputEntry(r, c).getDescription());
      }
      s.append("=").append(t.getVisibleOutputEntry(r, 0).getDescription());
    }
    return s.toString();
  }

  static void show(String label) {
    System.out.println(label + " | bits=" + m.getInputs().bits + " | col=" + col() + " | rows=" + rows());
  }

  public static void main(String[] args) throws Exception {
    m = new AnalyzerModel();
    m.setVariables(new ArrayList<>(List.of(new Var("a", 1), new Var("b", 1), new Var("c", 1))),
                   new ArrayList<>(List.of(new Var("q", 1))));
    TruthTable t = m.getTruthTable();
    Entry[] c = new Entry[8];
    String spec = "01101001";
    for (int i = 0; i < 8; i++) c[i] = spec.charAt(i) == '1' ? Entry.ONE : Entry.ZERO;
    t.setOutputColumn(0, c);
    show("initial");

    m.getInputs().add(new Var("d", 1));
    show("add d");

    m.getInputs().remove(new Var("b", 1));
    show("remove b");

    m.getInputs().move(new Var("a", 1), 1);
    show("move a +1");

    m.getInputs().replace(new Var("c", 1), new Var("c", 2));
    show("replace c 1->2");

    m.getInputs().replace(new Var("c", 2), new Var("c", 1));
    show("replace c 2->1");

    t.compactVisibleRows();
    show("compact");

    t.expandVisibleRows();
    show("expand");

    // don't-care handling on visible rows
    m = new AnalyzerModel();
    m.setVariables(new ArrayList<>(List.of(new Var("a", 1), new Var("b", 1), new Var("c", 1))),
                   new ArrayList<>(List.of(new Var("q", 1))));
    t = m.getTruthTable();
    Entry[] c2 = new Entry[8];
    String spec2 = "00110011";
    for (int i = 0; i < 8; i++) c2[i] = spec2.charAt(i) == '1' ? Entry.ONE : Entry.ZERO;
    t.setOutputColumn(0, c2);
    show("t2 initial");
    t.compactVisibleRows();
    show("t2 compact");
    t.setVisibleOutputEntry(0, 0, Entry.ONE);
    show("t2 set row0=1");
    t.setOutputEntry(3, 0, Entry.ZERO);
    show("t2 set idx3=0");
    System.out.println("t2 dcmask row0=" + t.getVisibleRowDcMask(0) + " idx=" + t.getVisibleRowIndex(0)
        + " indexes=" + join(t.getVisibleRowIndexes(0)));
    System.exit(0);
  }

  static String join(Iterable<Integer> it) {
    StringBuilder s = new StringBuilder();
    for (Integer i : it) { if (s.length() > 0) s.append("/"); s.append(i); }
    return s.toString();
  }
}
