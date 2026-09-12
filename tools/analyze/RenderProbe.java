package com.cburch.logisim.analyze.model;

import java.util.*;
import com.cburch.logisim.analyze.data.Range;
import com.cburch.logisim.analyze.model.Expression.Notation;

public class RenderProbe {
  static AnalyzerModel model() {
    AnalyzerModel m = new AnalyzerModel();
    m.setVariables(List.of(new Var("a", 1), new Var("b", 1), new Var("x", 4)),
                   List.of(new Var("q", 1)));
    return m;
  }

  static String ranges(List<Range> rs) {
    StringBuilder s = new StringBuilder();
    for (Range r : rs) { if (s.length() > 0) s.append("/"); s.append(r.startIndex).append("-").append(r.stopIndex); }
    return s.toString();
  }

  public static void main(String[] args) throws Exception {
    Scanner sc = new Scanner(System.in);
    while (sc.hasNextLine()) {
      String in = sc.nextLine();
      if (in.isEmpty()) continue;
      Expression e = Parser.parse(in, model());
      String text = e.toString(Notation.MATHEMATICAL, true);
      StringBuilder bad = new StringBuilder();
      for (Integer b : e.getBadness()) { if (bad.length() > 0) bad.append(","); bad.append(b); }
      System.out.println(in + " || " + text + " || nots=" + ranges(e.nots)
          + " || subs=" + ranges(e.subscripts) + " || badness=" + bad);
    }
    System.exit(0);
  }
}
