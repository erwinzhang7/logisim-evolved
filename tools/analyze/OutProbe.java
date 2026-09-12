package com.cburch.logisim.analyze.model;
import java.util.*;
public class OutProbe {
  static AnalyzerModel m;
  static String col(int c) {
    TruthTable t = m.getTruthTable();
    StringBuilder s = new StringBuilder();
    for (int i = 0; i < t.getRowCount(); i++) s.append(t.getOutputEntry(i, c).getDescription());
    return s.toString();
  }
  static void show(String label) {
    OutputExpressions oe = m.getOutputExpressions();
    System.out.println(label
      + " | expr=" + oe.getExpression("q")
      + " | str=" + oe.getExpressionString("q")
      + " | min=" + oe.getMinimalExpression("q")
      + " | minimal=" + oe.isExpressionMinimal("q")
      + " | fmt=" + oe.getMinimizedFormat("q")
      + " | col=" + col(0)
      + " | inputs=" + m.getInputs().bits);
  }
  public static void main(String[] a) throws Exception {
    m = new AnalyzerModel();
    m.setVariables(new ArrayList<>(List.of(new Var("a",1), new Var("b",1), new Var("c",1))),
                   new ArrayList<>(List.of(new Var("q",1))));
    TruthTable t = m.getTruthTable();
    Entry[] c = new Entry[8];
    String spec = "00010111";
    for (int i=0;i<8;i++) c[i] = spec.charAt(i)=='1'?Entry.ONE:Entry.ZERO;
    t.setOutputColumn(0, c);
    show("initial");
    m.getOutputExpressions().enableUpdates();
    show("after enableUpdates");
    m.getOutputExpressions().setExpression("q", Parser.parse("a*b", m));
    show("setExpression a*b");
    m.getOutputExpressions().setMinimizedFormat("q", AnalyzerModel.FORMAT_PRODUCT_OF_SUMS);
    show("format=POS");
    m.getOutputExpressions().setExpression("q", Parser.parse("a+b+c", m));
    show("setExpression a+b+c");
    m.getInputs().replace(new Var("b",1), new Var("z",1));
    show("rename b->z");
    m.getInputs().remove(new Var("c",1));
    show("remove c");
    System.exit(0);
  }
}
