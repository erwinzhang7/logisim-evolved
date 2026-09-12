package com.cburch.logisim.analyze.model;

import java.util.*;
import com.cburch.logisim.analyze.model.Expression.Notation;

public class ParseProbe {
  static AnalyzerModel model() {
    AnalyzerModel m = new AnalyzerModel();
    m.setVariables(
        List.of(new Var("a", 1), new Var("b", 1), new Var("c", 1), new Var("x", 4)),
        List.of(new Var("q", 1), new Var("r", 1)));
    return m;
  }

  public static void main(String[] args) throws Exception {
    Scanner sc = new Scanner(System.in);
    while (sc.hasNextLine()) {
      String line = sc.nextLine();
      if (line.isEmpty()) continue;
      boolean assign = line.startsWith("A:");
      String in = assign ? line.substring(2) : line;
      String res;
      try {
        Expression e = assign ? Parser.parseMaybeAssignment(in, model()) : Parser.parse(in, model());
        if (e == null) {
          res = "null";
        } else {
          List<String> parts = new ArrayList<>();
          for (Notation n : Notation.values()) parts.add(e.toString(n));
          parts.add("cnf=" + e.isCnf());
          parts.add("circ=" + e.isCircular());
          parts.add("xor=" + e.contains(Expression.Op.XOR) + " and=" + e.contains(Expression.Op.AND)
                    + " not=" + e.contains(Expression.Op.NOT));
          res = String.join(" ¦ ", parts);
        }
      } catch (ParserException e) {
        res = "ERR off=" + e.getOffset() + " len=" + (e.getEndOffset() - e.getOffset()) + " " + e.getMessage();
      } catch (Throwable e) {
        res = "EXC " + e.getClass().getSimpleName() + ": " + e.getMessage();
      }
      System.out.println(line + " || " + res);
    }
    System.exit(0);
  }
}
