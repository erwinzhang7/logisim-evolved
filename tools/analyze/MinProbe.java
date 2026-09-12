package com.cburch.logisim.analyze.model;

import java.util.*;
import javax.swing.JTextArea;

public class MinProbe {
  static String run(int n, String spec, int format) {
    AnalyzerModel m = new AnalyzerModel();
    List<Var> in = new ArrayList<>();
    String[] names = {"a", "b", "c", "d", "e"};
    for (int i = 0; i < n; i++) in.add(new Var(names[i], 1));
    m.setVariables(in, List.of(new Var("q", 1)));
    TruthTable t = m.getTruthTable();
    Entry[] col = new Entry[1 << n];
    for (int i = 0; i < (1 << n); i++) {
      char c = spec.charAt(i);
      col[i] = c == '1' ? Entry.ONE : c == '0' ? Entry.ZERO : Entry.DONT_CARE;
    }
    t.setOutputColumn(0, col);
    List<Implicant> imps =
        Implicant.computeMinimal(format, m, "q", new JTextArea());
    Expression e = Implicant.toExpression(format, m, imps);
    List<String> parts = new ArrayList<>();
    for (Implicant i : imps) parts.add(i.values + "/" + i.unknowns);
    return imps.size() + " {" + String.join(",", parts) + "} " + (e == null ? "null" : e.toString());
  }

  public static void main(String[] args) throws Exception {
    Scanner sc = new Scanner(System.in);
    while (sc.hasNextLine()) {
      String line = sc.nextLine().trim();
      if (line.isEmpty()) continue;
      String[] f = line.split("\\s+");
      int n = Integer.parseInt(f[0]);
      String spec = f[1];
      int format = f.length > 2 && f[2].equals("pos") ? AnalyzerModel.FORMAT_PRODUCT_OF_SUMS
                                                      : AnalyzerModel.FORMAT_SUM_OF_PRODUCTS;
      String res;
      try { res = run(n, spec, format); } catch (Throwable e) { res = "EXC " + e; }
      System.out.println(line + " | " + res);
    }
    System.exit(0);
  }
}
