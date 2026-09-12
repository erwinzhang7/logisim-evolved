package com.cburch.logisim.analyze.model;

import java.util.*;

public class EvalProbe {
  static AnalyzerModel model() {
    AnalyzerModel m = new AnalyzerModel();
    m.setVariables(List.of(new Var("a", 1), new Var("b", 1), new Var("c", 1)),
                   List.of(new Var("q", 1)));
    return m;
  }

  public static void main(String[] args) throws Exception {
    Scanner sc = new Scanner(System.in);
    while (sc.hasNextLine()) {
      String in = sc.nextLine();
      if (in.isEmpty()) continue;
      Expression e = Parser.parse(in, model());
      StringBuilder tt = new StringBuilder();
      for (int i = 0; i < 8; i++) {
        Assignments as = new Assignments();
        as.put("a", (i & 4) != 0);
        as.put("b", (i & 2) != 0);
        as.put("c", (i & 1) != 0);
        tt.append(e.evaluate(as) ? "1" : "0");
      }
      Expression rmB = e.removeVariable("b");
      Expression rep = e.replaceVariable("b", "z");
      System.out.println(in + " || " + tt + " || " + (rmB == null ? "null" : rmB.toString())
          + " || " + rep.toString());
    }
    System.exit(0);
  }
}
